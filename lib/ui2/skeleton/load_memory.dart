// Owner: LoadMemory owns bounded, local presentation estimates. Sizes, line
// counts and elapsed milliseconds never enter analytics or health backups.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../state/prefs.dart';
import '../theme.dart';
import 'pending_scope.dart';

class LoadEstimate {
  LoadEstimate({this.tolerance = 3});
  final double tolerance;
  final samples = <double>[];
  double? _average;
  double? get value {
    if (samples.isEmpty) return null;
    List<double> best = const [];
    for (final candidate in samples) {
      final group =
          samples.where((v) => (v - candidate).abs() <= tolerance).toList()
            ..sort();
      if (group.length > best.length) best = group;
    }
    return best.length >= 3 ? best[best.length ~/ 2] : _average;
  }

  void add(double sample) {
    if (!sample.isFinite || sample < 0) return;
    final previous = _average;
    _average = previous == null
        ? sample
        : previous +
              ((sample - previous) * .2).clamp(
                -math.max(.05, previous * .05),
                math.max(.05, previous * .05),
              );
    samples.add(sample);
    if (samples.length > 8) samples.removeAt(0);
  }

  Map<String, Object?> toJson() => {
    'samples': samples,
    'average': _average,
    'tolerance': tolerance,
  };
  factory LoadEstimate.fromJson(Map value) {
    final estimate = LoadEstimate(
      tolerance: (value['tolerance'] as num?)?.toDouble() ?? 3,
    );
    for (final sample
        in (value['samples'] as List? ?? []).whereType<num>().take(8)) {
      estimate.add(sample.toDouble());
    }
    final average = value['average'];
    if (average is num && average.isFinite && average >= 0) {
      estimate._average = average.toDouble();
    }
    return estimate;
  }
}

class LoadMemory {
  LoadMemory({required this.userKey, this.limit = 96});
  static final local = LoadMemory(
    userKey: () => Prefs.getString('install_device_id', 'local-profile'),
  );
  static const prefKey = 'ui.load_memory.v1';
  final String Function() userKey;
  final int limit;
  final _entries = <String, LoadEstimate>{};
  String? _restored;
  bool _saveScheduled = false;
  void _restore() {
    final encoded = Prefs.getString(prefKey, '');
    if (_restored != null) return;
    _restored = encoded;
    _entries.clear();
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map) {
        for (final e in decoded.entries.take(limit)) {
          if (e.key is String && e.value is Map) {
            _entries[e.key as String] = LoadEstimate.fromJson(e.value as Map);
          }
        }
      }
    } catch (_) {
      /* A damaged cache only loses presentation estimates. */
    }
  }

  String _key(String key) => '${userKey()}:$key';
  double? estimate(String key) {
    _restore();
    return _entries[_key(key)]?.value;
  }

  void record(String key, double value) {
    if (!value.isFinite || value < 0) return;
    _restore();
    final scoped = _key(key),
        estimate =
            _entries.remove(_key(key)) ??
            LoadEstimate(
              tolerance: key.endsWith(':lines')
                  ? .1
                  : key.endsWith(':line-width')
                  ? .01
                  : 3,
            );
    estimate.add(value);
    _entries[scoped] = estimate;
    while (_entries.length > limit) {
      _entries.remove(_entries.keys.first);
    }
    // Coalesce the many sections that settle in one frame into one durable
    // write through the existing settings owner. No write on pulse frames.
    if (_saveScheduled) return;
    _saveScheduled = true;
    scheduleMicrotask(() {
      _saveScheduled = false;
      final encoded = jsonEncode({
        for (final e in _entries.entries) e.key: e.value.toJson(),
      });
      try {
        Prefs.setString(prefKey, encoded);
      } catch (_) {
        /* Best-effort UI cache; the loaded layout remains usable. */
      }
    });
  }
}

/// Only loading uses the estimate. Settled content always fits its real size.
/// The cache identity includes width, text scale and locale; sizes from another
/// layout cannot truncate this one. Unknown extra space paints text bars.
class RememberedLayout extends StatelessWidget {
  const RememberedLayout({
    super.key,
    required this.id,
    required this.pending,
    this.knownShape = true,
    required this.child,
  });
  final String id;
  final bool pending;
  final bool knownShape;
  final Widget child;
  @override
  Widget build(BuildContext c) => LayoutBuilder(
    builder: (c, box) {
      final scope =
          '$id:${box.maxWidth.round()}:${MediaQuery.textScalerOf(c).scale(100).round()}:${Localizations.maybeLocaleOf(c)}';
      return _RememberSize(
        id: scope,
        pending: pending,
        knownShape: knownShape,
        height: LoadMemory.local.estimate('$scope:height'),
        lineWidth: LoadMemory.local.estimate('$scope:line-width') ?? .7,
        lines: LoadMemory.local.estimate('$scope:lines'),
        color: P.of(c).ink3.withValues(alpha: .2),
        child: child,
      );
    },
  );
}

class _RememberSize extends SingleChildRenderObjectWidget {
  const _RememberSize({
    required this.id,
    required this.pending,
    required this.knownShape,
    required this.height,
    required this.lineWidth,
    required this.lines,
    required this.color,
    required super.child,
  });
  final String id;
  final bool pending, knownShape;
  final double? height;
  final double lineWidth;
  final double? lines;
  final Color color;
  @override
  RenderObject createRenderObject(BuildContext c) => _SizeMemory(this);
  @override
  void updateRenderObject(BuildContext c, _SizeMemory r) {
    if (r.config.pending && !pending) r._last = null;
    r.config = this;
    r.markNeedsLayout();
  }
}

class _SizeMemory extends RenderProxyBox implements PendingFillRender {
  _SizeMemory(this.config);
  _RememberSize config;
  Size? _last;
  String? _lastId;
  @override
  void performLayout() {
    super.performLayout();
    final actual = size;
    if (config.pending) {
      if (config.height case final height?) {
        // A remembered tail cannot clip rows or labels already known now.
        size = constraints.constrain(
          Size(size.width, config.knownShape ? math.max(size.height, height) : height),
        );
      }
    } else if (_last != actual || _lastId != config.id) {
      _last = actual;
      _lastId = config.id;
      final id = config.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!attached || config.pending || config.id != id) return;
        var lines = 0, fraction = 0.0;
        void visit(RenderObject r) {
          if (r is RenderParagraph && r.hasSize && r.size.width > 0) {
            final boxes = r.getBoxesForSelection(
              TextSelection(
                baseOffset: 0,
                extentOffset: r.text.toPlainText().length,
              ),
            );
            lines += boxes.map((b) => b.top.round()).toSet().length;
            for (final b in boxes) {
              fraction = math.max(fraction, b.toRect().width / actual.width);
            }
          }
          r.visitChildren(visit);
        }

        if (child != null) visit(child!);
        LoadMemory.local.record('$id:height', actual.height);
        LoadMemory.local.record('$id:lines', lines.toDouble());
        if (fraction > 0) LoadMemory.local.record('$id:line-width', fraction);
      });
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!config.pending) {
      super.paint(context, offset);
      return;
    }
    context.pushClipRect(needsCompositing, offset, Offset.zero & size, (
      context,
      offset,
    ) {
      super.paint(context, offset);
    });
  }

  @override
  void paintPendingFill(PaintingContext context, Offset offset, double pulse) {
    if (!config.pending) return;
    final bottom = child?.size.height ?? 0;
    final step = config.lines == null || config.lines! <= 0
        ? 24.0
        : math.max(16.0, size.height / config.lines!);
    final color = config.color;
    for (var y = bottom + 8; y + 8 < size.height; y += step) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            offset.dx,
            offset.dy + y,
            size.width * config.lineWidth.clamp(.2, 1),
            8,
          ),
          const Radius.circular(4),
        ),
        Paint()
          ..color = Color.from(
            alpha: color.a,
            red: color.r * pulse,
            green: color.g * pulse,
            blue: color.b * pulse,
          ),
      );
    }
  }
}
