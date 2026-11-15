// Callers own reads and retained values. This module owns pending presentation:
// the final layout is built before paint, with no readable values or actions.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'placeholder_paint.dart';
import '../grammar.dart' show Surface, ChartFrame;
import '../theme.dart';
import 'guide_plot.dart';
import 'skeleton.dart' show SkeletonBar, paintSkeletonShapes, SkeletonShape, skeletonKindOfPlot;

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
class PendingContent extends StatefulWidget {
  const PendingContent({super.key, required this.pending, required this.child});
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
  bool _visible = false;
  @override
  void initState() { super.initState(); _start(); }
  void _start() {
    if (!widget.pending) return;
    _delay = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || !widget.pending) return;
      setState(() => _visible = true);
      _fade.forward(from: 0);
    });
  }
  @override
  void didUpdateWidget(PendingContent old) {
    super.didUpdateWidget(old);
    if (old.pending == widget.pending) return;
    _delay?.cancel(); _fade.reset(); _visible = false; _start();
  }
  @override
  void dispose() { _delay?.cancel(); _fade.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false, skipTraversal: true,
    descendantsAreFocusable: !widget.pending,
    descendantsAreTraversable: !widget.pending,
    child: ExcludeSemantics(excluding: widget.pending,
      child: IgnorePointer(ignoring: widget.pending,
        child: AnimatedBuilder(animation: _fade, child: widget.child,
          builder: (_, child) => PendingTone(pulse: _PendingPulse.shared.value,
            fade: _fade.value, child: _PendingPaint(pending: widget.pending,
              visible: _visible, fade: _fade.value, child: child!))))));
}

class _PendingPaint extends SingleChildRenderObjectWidget {
  const _PendingPaint({required this.pending, required this.visible, required this.fade, required super.child});
  final bool pending, visible;
  final double fade;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPending(context as Element, pending, visible, fade);
  @override
  void updateRenderObject(BuildContext context, _RenderPending renderObject) {
    renderObject..pending = pending..visible = visible..fade = fade;
  }
}

class _RenderPending extends RenderProxyBox {
  _RenderPending(this.element, this._pending, this._visible, this._fade);
  final Element element;
  bool _pending, _visible, _listening = false;
  double _fade;
  GuidePlaceholderPaint? _plan;
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
    if (!_pending || content == null) { super.paint(context, offset); return; }
    if (!_visible || _fade <= 0) return;
    final plan = _plan ??= GuidePlaceholderPaint.of(element,
      fade: 1, pulse: 1, includeChartReadout: true);
    plan.pulse = _PendingPulse.shared.value;
    // Fade the entire placeholder, including backgrounds, dividers and icons.
    // Guide dimming remains separate and its placeholder ink never fades.
    context.pushOpacity(offset, (255 * _fade).round(), (context, offset) {
      plan.paint(context, content, offset, size);
    });
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

/// Content-sized rows. Put secondary asynchronous lists inside a collapsed
/// accordion; an unknown result count must never create an empty viewport.
class AsyncListSection<T> extends StatelessWidget {
  const AsyncListSection({super.key, required this.items,
    required this.itemBuilder, required this.emptyBuilder,
    this.visibleRows = 3, this.rowHeight = 72});
  final List<T>? items;
  final Widget Function(BuildContext, T) itemBuilder;
  final WidgetBuilder emptyBuilder;
  final int visibleRows;
  final double rowHeight;
  @override
  Widget build(BuildContext context) {
    final rows = items;
    if (rows == null) {
      return PendingContent(pending: true,
        child: PendingRows(count: visibleRows, rowHeight: rowHeight));
    }
    if (rows.isEmpty) return emptyBuilder(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final row in rows) itemBuilder(context, row)]);
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
