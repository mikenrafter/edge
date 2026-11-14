// Replaces content at paint time. Decorations keep their own paint; there is
// no erase/fill over the card, so gradients, images and icon controls survive.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../grammar.dart' show ChartFrame;
import '../theme.dart';
import 'guide_plot.dart';
import 'skeleton.dart';

class GuidePlaceholderPaint {
  final Set<RenderParagraph> paragraphs;
  final Set<RenderParagraph> hidden;
  final Set<RenderCustomPaint> plots;
  final Set<RenderCustomPaint> framePaint;
  final RenderParagraph? title;
  final P palette;
  final double fade, pulse;
  GuidePlaceholderPaint._(
    this.paragraphs,
    this.hidden,
    this.plots,
    this.framePaint,
    this.title,
    this.palette,
    this.fade,
    this.pulse,
  );

  factory GuidePlaceholderPaint.of(
    Element unit, {
    required double fade,
    required double pulse,
  }) {
    final paragraphs = <RenderParagraph>{};
    final hidden = <RenderParagraph>{};
    final plots = <RenderCustomPaint>{};
    final framePaint = <RenderCustomPaint>{};
    var card = isGuideCard(unit.widget);
    void visit(Element e) {
      final w = e.widget;
      if (w is Icon || w is ImageIcon || w is Image || w is RawImage) return;
      if (isGuideCard(w)) card = true;
      final ro = e is RenderObjectElement ? e.renderObject : null;
      if (ro is RenderCustomPaint &&
          (ro.painter is GuidePlot || ro.foregroundPainter is GuidePlot)) {
        plots.add(ro);
        return; // axes/labels belong to the plot too
      }
      if (ro is RenderCustomPaint &&
          e.findAncestorWidgetOfExactType<ChartFrame>() != null)
        framePaint.add(ro);
      if (ro is RenderParagraph) {
        final frame = e.findAncestorWidgetOfExactType<ChartFrame>();
        if (frame != null && ro.text.toPlainText() != frame.title) {
          hidden.add(ro);
          return;
        }
        paragraphs.add(ro);
        return;
      }
      e.debugVisitOnstageChildren(visit);
    }

    visit(unit);
    return GuidePlaceholderPaint._(
      paragraphs,
      hidden,
      plots,
      framePaint,
      card ? paragraphs.firstOrNull : null,
      paletteOf(unit),
      fade,
      pulse,
    );
  }

  factory GuidePlaceholderPaint.paragraphs(
    Set<RenderParagraph> paragraphs,
    P palette, {
    required double fade,
    required double pulse,
  }) => GuidePlaceholderPaint._(
    paragraphs,
    {},
    {},
    {},
    null,
    palette,
    fade,
    pulse,
  );

  void paint(
    PaintingContext context,
    RenderBox child,
    Offset offset,
    Size size,
  ) {
    final layer = OffsetLayer();
    context.pushLayer(layer, (_, at) {
      final content = _PlaceholderContext(layer, at & size, this);
      content.paintChild(child, at);
      content.stopRecordingIfNeeded();
    }, offset);
  }
}

/// A paint context is propagated through clips, opacity and transforms. Nested
/// repaint boundaries are painted here while a guide replaces their leaves;
/// their cached original pictures must not reintroduce hidden data/axes.
class _PlaceholderContext extends PaintingContext {
  final GuidePlaceholderPaint treatment;
  _PlaceholderContext(
    super.containerLayer,
    super.estimatedBounds,
    this.treatment,
  );

  @override
  PaintingContext createChildContext(ContainerLayer childLayer, Rect bounds) =>
      _PlaceholderContext(childLayer, bounds, treatment);

  @override
  void paintChild(RenderObject child, Offset offset) {
    final t = treatment;
    if (child is RenderParagraph && t.hidden.contains(child)) return;
    if (child is RenderParagraph && t.paragraphs.contains(child)) {
      if (identical(child, t.title)) {
        // Tint the title's glyphs, not the rectangle behind them. A placeholder
        // cannot replace or darken a patch of the card's own surface.
        canvas.saveLayer(offset & child.size, Paint()..colorFilter = ColorFilter.mode(
          t.palette.bg.withValues(alpha: kDimOpacity * t.fade), BlendMode.srcATop));
        super.paintChild(child, offset);
        canvas.restore();
      } else {
        final textColor = HSVColor.fromColor(child.text.style?.color ?? t.palette.ink3);
        final pigment = textColor.withValue(textColor.value * .6).toColor();
        final shapes = skeletonOfParagraph(child, t.palette.bg);
        canvas.save();
        canvas.translate(offset.dx, offset.dy);
        paintSkeletonShapes(
          canvas,
          [
            for (final s in shapes)
              SkeletonShape(
                kind: s.kind,
                rect: s.rect,
                section: s.section,
                color: pigment,
              ),
          ],
          t.palette,
          fade: t.fade,
          pulse: t.pulse,
        );
        canvas.restore();
      }
      return;
    }
    if (child is RenderCustomPaint && t.plots.contains(child)) {
      final plot =
          (child.painter is GuidePlot ? child.painter : child.foregroundPainter)
              as GuidePlot;
      final hsv = HSVColor.fromColor(plot.guideLineColor);
      final color = hsv
          .withSaturation(hsv.saturation * .45)
          .withValue(hsv.value * .8)
          .toColor();
      paintSkeletonShapes(
        canvas,
        [
          SkeletonShape(
            kind: SkeletonKind.sine,
            rect: offset & child.size,
            section: 0,
            color: color,
          ),
        ],
        t.palette,
        pulse: t.pulse,
      );
      return;
    }
    if (child is RenderCustomPaint && t.framePaint.contains(child)) {
      final content = child.child;
      if (content != null) paintChild(content, offset);
      return;
    }
    if (child.isRepaintBoundary) {
      child.paint(this, offset);
    } else {
      super.paintChild(child, offset);
    }
  }
}
