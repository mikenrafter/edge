// Callers own reads and retained values. This module owns pending presentation:
// the final layout is built before paint, with no readable values or actions.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'placeholder_paint.dart';
import '../grammar.dart' show Surface, ChartFrame;
import '../theme.dart';
import 'guide_plot.dart';
import 'skeleton.dart' show SkeletonBar;

/// A section's pending, retained and settled layouts. A settled empty value is
/// passed to [builder]; it must never turn back into an endless placeholder.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    super.key,
    required this.pending,
    required this.value,
    required this.pendingBuilder,
    required this.builder,
    this.emptyBuilder,
    this.failureBuilder,
    this.failed = false,
  });
  final bool pending, failed;
  final WidgetBuilder? emptyBuilder, failureBuilder;
  final T? value;
  final WidgetBuilder pendingBuilder;
  final Widget Function(BuildContext, T) builder;

  @override
  Widget build(BuildContext context) {
    final shown = value;
    if (shown != null) return builder(context, shown);
    if (failed) return failureBuilder?.call(context) ?? const SizedBox.shrink();
    if (!pending) return emptyBuilder?.call(context) ?? const SizedBox.shrink();
    return PendingContent(pending: true, child: pendingBuilder(context));
  }
}

/// Paint bars and neutral plots on the real layout. Unlike opacity or an
/// overlay, this preserves decorations, icons and images without filling the
/// background. Pending values cannot be announced, focused or activated.
class PendingContent extends StatelessWidget {
  const PendingContent({super.key, required this.pending, required this.child});
  final bool pending;
  final Widget child;
  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    descendantsAreFocusable: !pending,
    descendantsAreTraversable: !pending,
    child: ExcludeSemantics(
      excluding: pending,
      child: IgnorePointer(
        ignoring: pending,
        child: _PendingPaint(pending: pending, child: child),
      ),
    ),
  );
}

class _PendingPaint extends SingleChildRenderObjectWidget {
  const _PendingPaint({required this.pending, required super.child});
  final bool pending;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPending(context as Element, pending);
  @override
  void updateRenderObject(BuildContext context, _RenderPending renderObject) {
    renderObject.pending = pending;
  }
}

class _RenderPending extends RenderProxyBox {
  _RenderPending(this.element, this._pending);
  final Element element;
  bool _pending;
  set pending(bool value) {
    if (_pending == value) return;
    _pending = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final content = child;
    if (!_pending || content == null) {
      super.paint(context, offset);
      return;
    }
    GuidePlaceholderPaint.of(
      element,
      fade: 1,
      pulse: 1,
    ).paint(context, content, offset, size);
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
class PendingChart extends StatelessWidget {
  const PendingChart({
    super.key,
    required this.title,
    this.height = 150,
    this.footnote,
    this.unit = '',
  });
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
        child: const PendingPlot(),
      ),
    ),
  );
}

/// A neutral plot inside an existing ChartFrame, without invented points.
class PendingPlot extends StatelessWidget {
  const PendingPlot({super.key});
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _PendingWave(P.of(context).ink3),
    child: const SizedBox.expand(),
  );
}

class _PendingWave extends CustomPainter implements GuidePlot {
  const _PendingWave(this.guideLineColor);
  @override
  final Color guideLineColor;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (var i = 0; i <= 80; i++) {
      final x = size.width * i / 80;
      final y = size.height * (.5 - .28 * math.sin(i / 80 * 2 * math.pi));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = guideLineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_PendingWave oldDelegate) =>
      oldDelegate.guideLineColor != guideLineColor;
}

/// An unknown count gets a bounded list viewport. Pending rows and settled
/// results share that viewport, so lower sections and scroll anchors stay put.
class AsyncListSection<T> extends StatelessWidget {
  const AsyncListSection({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.emptyBuilder,
    this.visibleRows = 3,
    this.rowHeight = 72,
  });
  final List<T>? items;
  final Widget Function(BuildContext, T) itemBuilder;
  final WidgetBuilder emptyBuilder;
  final int visibleRows;
  final double rowHeight;
  @override
  Widget build(BuildContext context) {
    final rows = items;
    return SizedBox(
      width: double.infinity,
      height:
          rowHeight * visibleRows * MediaQuery.textScalerOf(context).scale(1),
      child: rows == null
          ? PendingContent(
              pending: true,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: PendingRows(
                  count: visibleRows,
                  rowHeight:
                      rowHeight * MediaQuery.textScalerOf(context).scale(1),
                ),
              ),
            )
          : SingleChildScrollView(
              child: rows.isEmpty
                  ? emptyBuilder(context)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final row in rows) itemBuilder(context, row),
                      ],
                    ),
            ),
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
