// Callers own reads and retained values. This module owns pending presentation:
// the final layout is built before paint, with no readable values or actions.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'placeholder_paint.dart';
import 'load_memory.dart';
import 'settling_height.dart';
export 'settling_height.dart';
export 'pending_scope.dart';
import '../grammar.dart' show Surface, ChartFrame;
import '../theme.dart';
import '../../l10n/app_localizations.dart';
import 'pending_scope.dart';
import 'guide_plot.dart';
import 'skeleton.dart' show SkeletonBar, paintSkeletonShapes, SkeletonShape, skeletonKindOfPlot;

/// Named render effects for the reusable section. No hidden callback dispatch.
abstract interface class AsyncSectionContent<T> {
  Widget loaded(BuildContext context, T value);
  Widget pending(BuildContext context);
  Widget empty(BuildContext context);
  Widget failed(BuildContext context);
}

/// A section's pending, retained and settled layouts. A settled empty value is
/// passed to [AsyncSectionContent.loaded]; it must never turn back into an endless placeholder.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    super.key,
    required this.pending,
    required this.value,
    required this.content,
    this.failed = false,
  });
  final bool pending, failed;
  final T? value;
  final AsyncSectionContent<T> content;

  @override
  Widget build(BuildContext context) {
    final shown = value;
    if (failed) return content.failed(context);
    final Widget child;
    if (shown != null) {
      child = content.loaded(context, shown);
    } else if (pending) {
      child = content.pending(context);
    } else {
      child = content.empty(context);
    }
    // Keep the pending owner mounted across settlement, so it can announce a
    // user-started completion. Failed/cancelled sections never announce loaded.
    return PendingContent(pending: pending && shown == null, child: child);
  }
}

/// Paint bars and neutral plots on the real layout. Unlike opacity or an
/// overlay, this preserves decorations, icons and images without filling the
/// background. Pending values cannot be announced, focused or activated.
class PendingContent extends StatefulWidget {
  const PendingContent({super.key, required this.pending, required this.child,
    this.memoryKey,
    this.knownShape = true,
  });
  final bool knownShape;
  final String? memoryKey;
  final bool pending;
  final Widget child;
  @override
  State<PendingContent> createState() => _PendingContentState();
}

// One clock while any visible pending region exists. Render objects listen
// directly: pulse frames repaint their own layer without rebuilding the page.
class _PendingPulse extends ChangeNotifier {
  static final shared = _PendingPulse();
  late final Ticker _ticker = Ticker((elapsed) {
    final phase = elapsed.inMicroseconds / 1100000 % 2;
    value = .78 + .22 * (phase <= 1 ? phase : 2 - phase);
    notifyListeners();
  });
  double value = .78;
  int users = 0;
  void join(VoidCallback listener) {
    addListener(listener);
    if (users++ == 0) _ticker.start();
  }
  void leave(VoidCallback listener) {
    removeListener(listener);
    if (--users == 0) _ticker.stop();
  }
}

class _PendingContentState extends State<PendingContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this,
    duration: const Duration(milliseconds: 250));
  Timer? _delay;
  final _elapsed = Stopwatch();
  bool _visible = false;
  bool _userStarted = false, _announceComplete = false;

  String _sectionName(BuildContext context, AppLocalizations l) {
    final child = widget.child;
    String? name = child is PendingSectionLabel ? (child as PendingSectionLabel).pendingSectionName : null;
    if (name == null) {
      context.visitAncestorElements((ancestor) {
        final section = ancestor.widget;
        if (section is PendingSectionLabel) name = (section as PendingSectionLabel).pendingSectionName;
        return name == null;
      });
    }
    return name ?? l.pendingSectionContent;
  }
  @override
  void initState() {
    super.initState();
    if (!widget.pending) _fade.value = 1;
    _start();
  }

  void _start() {
    if (!widget.pending) return;
    _userStarted = PendingUserAction.active;
    _elapsed
      ..reset()
      ..start();
    _delay = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || !widget.pending) return;
      setState(() => _visible = true);
      _play(from: 0);
    });
  }

  /// Reduced motion shows the finished state at once (the ui2 token rule).
  void _play({double? from}) {
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _fade.value = 1;
      return;
    }
    _fade.forward(from: from);
  }
  @override
  void didUpdateWidget(PendingContent old) {
    super.didUpdateWidget(old);
    if (old.pending == widget.pending) return;
    if (!widget.pending && widget.memoryKey != null && _elapsed.isRunning) {
      _elapsed.stop();
      LoadMemory.local.record(
        '${widget.memoryKey}:milliseconds',
        _elapsed.elapsedMilliseconds.toDouble(),
      );
    }
    _delay?.cancel();
    _fade.reset();
    _visible = false;
    if (widget.pending) {
      _announceComplete = false;
      _start();
    } else {
      _announceComplete = _userStarted;
      _userStarted = false;
      if (_announceComplete) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _announceComplete) setState(() => _announceComplete = false);
        });
      }
      _play();
    }
  }
  @override
  void dispose() { _delay?.cancel(); _fade.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
    final name = _sectionName(context, l);
    final parentOwns = context.dependOnInheritedWidgetOfExactType<_PendingSemanticsOwner>()?.active ?? false;
    final announce = _announceComplete && !parentOwns;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: widget.pending ? l.pendingSectionLoading(name)
          : announce ? l.pendingSectionLoaded(name) : null,
      // Flutter's live-region flag uses polite announcements. A completion is
      // exposed for one build only, so later data/pulse changes stay quiet.
      liveRegion: announce,
      child: _PendingSemanticsOwner(active: widget.pending || announce,
        child: Focus(
          canRequestFocus: false, skipTraversal: true,
          descendantsAreFocusable: !widget.pending,
          descendantsAreTraversable: !widget.pending,
          child: ExcludeSemantics(excluding: widget.pending,
            child: IgnorePointer(ignoring: widget.pending,
              child: AnimatedBuilder(animation: _fade, child: SettlingHeight(child: widget.memoryKey == null
                    ? widget.child
                    : RememberedLayout(
                        id: widget.memoryKey!,
                        knownShape: widget.knownShape,
                        pending: widget.pending,
                        child: widget.child,
                      )),
                builder: (_, child) => PendingTone(pulse: _PendingPulse.shared.value,
                  fade: _fade.value, child: _PendingPaint(pending: widget.pending,
                    visible: _visible, fade: _fade.value, child: child!))))))));
  }
}

class _PendingSemanticsOwner extends InheritedWidget {
  const _PendingSemanticsOwner({required this.active, required super.child});
  final bool active;
  @override
  bool updateShouldNotify(_PendingSemanticsOwner old) => active != old.active;

}

class _PendingPaint extends SingleChildRenderObjectWidget {
  const _PendingPaint({required this.pending, required this.visible, required this.fade, required super.child});
  final bool pending, visible;
  final double fade;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPending(context as Element, pending, visible, fade, child);
  @override
  void updateRenderObject(BuildContext context, _RenderPending renderObject) {
    renderObject..pending = pending..visible = visible..fade = fade;
    renderObject.updateChildIdentity(child);
  }
}

class _RenderPending extends RenderProxyBox {
  _RenderPending(
    this.element,
    this._pending,
    this._visible,
    this._fade,
    this._widgetChild,
  );
  final Element element;
  bool _pending, _visible, _listening = false;
  double _fade;
  GuidePlaceholderPaint? _plan;
  Widget? _widgetChild;
  void updateChildIdentity(Widget? child) {
    if (identical(_widgetChild, child)) return;
    _widgetChild = child;
    _plan = null;
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;
  set fade(double value) { if (_fade == value) return; _fade = value; markNeedsPaint(); }
  set visible(bool value) { if (_visible == value) return; _visible = value; _listen(); markNeedsPaint(); }
  set pending(bool value) { if (_pending == value) return; _pending = value; _listen(); markNeedsPaint(); }
  void _listen() {
    final wanted = attached && _pending && _visible;
    if (wanted == _listening) return;
    _listening = wanted;
    if (wanted) { _PendingPulse.shared.join(markNeedsPaint); }
    else { _PendingPulse.shared.leave(markNeedsPaint); }
  }
  @override
  void attach(PipelineOwner owner) { super.attach(owner); _listen(); }
  @override
  void detach() {
    if (_listening) { _PendingPulse.shared.leave(markNeedsPaint); _listening = false; }
    super.detach();
  }
  @override
  void performLayout() { super.performLayout(); _plan = null; }
  @override
  void paint(PaintingContext context, Offset offset) {
    final content = child;
    if (content == null || !_pending && _fade >= 1) {
      super.paint(context, offset);
      return;
    }
    if (_plan?.stale ?? false) _plan = null;
    final plan = _plan ??= GuidePlaceholderPaint.of(
      element,
      fade: 1,
      pulse: 1,
      includeChartReadout: true,
      preserveChrome: true,
    );
    plan.pulse = _PendingPulse.shared.value;
    // Card chrome and known labels always paint. Only data leaves share the
    // debounced fade; guides retain their separate immediate-ink policy.
    plan.substitute = _pending;
    plan.inkFade = !_pending || _visible ? _fade : 0;
    plan.paint(context, content, offset, size);
  }
}

/// Known row slots, or the initial visible rows of a bounded async list. Rows
/// contain no invented readings. Use the same height for their loaded forms.
class PendingRows extends StatelessWidget {
  const PendingRows({super.key, this.count = 3, this.rowHeight = 64});
  final int count;
  final double rowHeight;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          SizedBox(
            height: rowHeight,
            child: const Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SkeletonBar(height: 14),
                  ),
                ),
                SkeletonBar(width: 48, height: 14),
              ],
            ),
          ),
      ],
    ),
  );
}

/// A chart's normal frame while its points are being read. The plot carries
/// no sample values; its neutral wave is a placeholder, never a measurement.
enum PendingChartShape { line, bars, stages, ring, scatter, band }

class PendingChart extends StatelessWidget {
  const PendingChart({
    super.key,
    required this.title,
    this.height = 150,
    this.footnote,
    this.unit = '',
    this.shape = PendingChartShape.line,
  });
  final PendingChartShape shape;
  final String title, unit;
  final String? footnote;
  final double height;
  @override
  Widget build(BuildContext context) => PendingContent(
    pending: true,
    child: Surface(
      child: ChartFrame(
        title: title,
        unit: unit,
        height: height,
        footnote: footnote,
        child: PendingPlot(shape: shape),
      ),
    ),
  );
}

/// A neutral plot inside an existing ChartFrame, without invented points.
class PendingPlot extends StatelessWidget {
  const PendingPlot({super.key, this.shape = PendingChartShape.line});
  final PendingChartShape shape;
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: switch(shape) {
      PendingChartShape.line => _PendingWave(P.of(context).ink3),
      PendingChartShape.bars => _PendingBars(P.of(context).ink3),
      PendingChartShape.stages => _PendingSteps(P.of(context).ink3),
      PendingChartShape.ring => _PendingRing(P.of(context).ink3),
      PendingChartShape.scatter => _PendingDots(P.of(context).ink3),
      PendingChartShape.band => _PendingBand(P.of(context).ink3),
    },
    child: const SizedBox.expand(),
  );
}

class _PendingWave extends CustomPainter implements GuidePlot {
  const _PendingWave(this.guideLineColor);
  @override
  final Color guideLineColor;
  @override
  void paint(Canvas canvas, Size size) {
    paintSkeletonShapes(canvas, [SkeletonShape(kind: skeletonKindOfPlot(this),
      rect: Offset.zero & size, section: 0, color: guideLineColor)],
      // Only the supplied pigment is used by these shape families.
      const P(true));
  }

  @override
  bool shouldRepaint(_PendingWave oldDelegate) =>
      oldDelegate.guideLineColor != guideLineColor;
}

class _PendingBars extends _PendingWave implements GuideBars { const _PendingBars(super.guideLineColor); }
class _PendingSteps extends _PendingWave implements GuideSteps { const _PendingSteps(super.guideLineColor); }
class _PendingRing extends _PendingWave implements GuideRing { const _PendingRing(super.guideLineColor); }
class _PendingDots extends _PendingWave implements GuideScatter { const _PendingDots(super.guideLineColor); }
class _PendingBand extends _PendingWave implements GuideBand { const _PendingBand(super.guideLineColor); }

/// Content-sized asynchronous rows. The stable storage id owns remembered
/// geometry; unknown row templates may fit that estimate, while loaded content
/// always keeps its natural height and never gets another scrollable.
class AsyncListSection<T> extends StatelessWidget {
  const AsyncListSection({super.key, required this.memoryKey, required this.items,
    required this.itemBuilder, required this.emptyBuilder,
    this.visibleRows = 3, this.rowHeight = 72});
  final String memoryKey;
  final List<T>? items;
  final Widget Function(BuildContext, T) itemBuilder;
  final WidgetBuilder emptyBuilder;
  final int visibleRows;
  final double rowHeight;
  @override
  Widget build(BuildContext context) {
    final rows = items;
    return PendingContent(
      memoryKey: 'async-list:$memoryKey',
      knownShape: false,
      pending: rows == null,
      child: rows == null
        ? PendingRows(count: visibleRows, rowHeight: rowHeight)
        : rows.isEmpty ? emptyBuilder(context)
        : Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final row in rows) itemBuilder(context, row)]),
    );
  }
}

/// Reserve the scaled, wrapped height of known copy before a capability read
/// decides whether to show it. The sizing copy is never a visible value.
class TextSlot extends StatelessWidget {
  const TextSlot({
    super.key,
    required this.sizingText,
    required this.style,
    this.child,
  });
  final String sizingText;
  final TextStyle style;
  final Widget? child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final painter = TextPainter(
        text: TextSpan(text: sizingText, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      );
      try {
        painter.layout(maxWidth: box.maxWidth);
        return SizedBox(
          width: double.infinity,
          height: painter.height,
          child: child,
        );
      } finally {
        painter.dispose();
      }
    },
  );
}

/// A compact pending slot for controls whose label already names the action.
class PendingMark extends StatelessWidget {
  const PendingMark({super.key});
  @override
  Widget build(BuildContext context) => const PendingContent(pending: true,
    child: SizedBox(width: 18, height: 18,
      child: Center(child: SkeletonBar(width: 16, height: 6))));
}

/// Tone of explicit skeleton bars; real decorations keep their own colour.
class PendingTone extends InheritedWidget {
  const PendingTone({super.key, required this.pulse, required this.fade, required super.child});
  final double pulse, fade;
  static Color colorOf(BuildContext context, Color color) {
    final tone = context.dependOnInheritedWidgetOfExactType<PendingTone>();
    if (tone == null) return color;
    return Color.from(alpha: color.a,
      red: color.r * tone.pulse, green: color.g * tone.pulse,
      blue: color.b * tone.pulse);
  }
  @override
  bool updateShouldNotify(PendingTone old) => pulse != old.pulse || fade != old.fade;
}
