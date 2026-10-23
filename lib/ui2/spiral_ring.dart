import 'dart:math';

import 'package:flutter/material.dart';

const double kSpiralSeparator = 1.5;

class SpiralPiece {
  final int seg, lap;
  final double from, to;
  final bool capEnd, capStart;
  const SpiralPiece(this.seg, this.lap, this.from, this.to,
      {this.capEnd = false, this.capStart = false});
}

class SpiralGeometry {
  final double stroke, ramp, insetPerStroke;
  const SpiralGeometry(this.stroke, {this.ramp = .3, this.insetPerStroke = .75});

  double inset(double s) {
    if (!s.isFinite || s <= 1 || ramp <= 0) return 0;
    final lap = s.floor();
    final x = ((s - lap) / ramp).clamp(0.0, 1.0);
    if (x < .002) return insetPerStroke * stroke * (lap - 1).clamp(0, 1000000);
    if (1 - x < .002) return insetPerStroke * stroke * lap;
    return insetPerStroke * stroke * ((lap - 1) + (1 - cos(pi * x)) / 2);
  }

  double radiusAt(double s, double r0) => r0 - inset(s);
  static int lapsFor(double fraction) =>
      !fraction.isFinite || fraction <= 0 ? 0 : fraction.ceil();

  List<SpiralPiece> pieces(List<double> fractions) {
    final valid = <(int, double)>[];
    for (var i = 0; i < fractions.length; i++) {
      final f = fractions[i];
      if (f.isFinite && f > 0) valid.add((i, f));
    }
    final total = valid.fold<double>(0, (a, b) => a + b.$2);
    if (!total.isFinite || total <= 0) return const [];
    final result = <SpiralPiece>[];
    var at = 0.0;
    final starts = <double>[];
    for (final e in valid) {
      starts.add(at);
      at += e.$2;
    }
    for (var lap = 0; lap < lapsFor(total); lap++) {
      final pieces = <SpiralPiece>[];
      for (var i = 0; i < valid.length; i++) {
        final start = starts[i], end = start + valid[i].$2;
        final from = max(start, lap.toDouble()), to = min(end, min(total, lap + 1.0));
        if (to <= from) continue;
        final trueStart = from == start, trueEnd = to == end;
        pieces.add(SpiralPiece(valid[i].$1, lap, from, to,
          capStart: trueStart && start == 0 && total < 1,
          capEnd: trueEnd && (to != lap + 1 || to == total)));
      }
      result.addAll(pieces.reversed);
    }
    if (valid.length == 1 && total < 1 && result.isNotEmpty) {
      final p = result.single;
      result[0] = SpiralPiece(p.seg, p.lap, p.from, p.to, capStart: true, capEnd: true);
    }
    return result;
  }

  double? separatorFrom(int lap) {
    if (lap <= 0) return null;
    if (lap > 1) return lap.toDouble();
    final target = .5 / (insetPerStroke * stroke);
    return 1 + ramp * acos(1 - 2 * target.clamp(0.0, 1.0)) / pi;
  }
  static double gradientAt(double s, double total) =>
      total <= 0 || !total.isFinite ? 0 : (s / total).clamp(0.0, 1.0);
}

/// Shared rendering path for score and stage rings.
void paintSpiral(Canvas canvas, Size size, {required double stroke, required Color track,
  required List<Color> colors, required List<double> fractions, required double t,
  bool solid = true}) {
  final center = Offset(size.width / 2, size.height / 2);
  final r0 = min(size.width, size.height) / 2 - stroke / 2;
  if (r0 <= 0) return;
  canvas.drawCircle(center, r0, Paint()..style = PaintingStyle.stroke..strokeWidth = stroke..color = track);
  final progress = t.clamp(0.0, 1.0);
  final scaled = fractions.map((f) => f.isFinite && f > 0 ? f * progress : 0.0).toList();
  final geometry = SpiralGeometry(stroke), total = scaled.fold<double>(0, (a, b) => a + b);
  final pieces = geometry.pieces(scaled);
  for (var lap = 1; lap < SpiralGeometry.lapsFor(total); lap++) {
    final from = geometry.separatorFrom(lap)!;
    canvas.drawArc(Rect.fromCircle(center: center, radius: geometry.radiusAt(from, r0)),
      -pi / 2 + 2 * pi * from, 2 * pi * (lap + 1 - from), false,
      Paint()..style = PaintingStyle.stroke..strokeWidth = kSpiralSeparator..color = track);
  }
  for (final p in pieces) {
    final radius = geometry.radiusAt((p.from + p.to) / 2, r0);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final color = colors[p.seg];
    final shader = solid ? null : SweepGradient(
      startAngle: -pi / 2, endAngle: 3 * pi / 2,
      colors: [color.withValues(alpha: .55), color],
      stops: [gradientAt(p.from, total), gradientAt(p.to, total)],
    ).createShader(rect);
    canvas.drawArc(rect, -pi / 2 + 2 * pi * p.from, 2 * pi * (p.to - p.from), false,
      Paint()..style = PaintingStyle.stroke..strokeWidth = stroke
        ..strokeCap = p.capEnd || p.capStart ? StrokeCap.round : StrokeCap.butt
        ..color = solid ? color : const Color(0x00000000)..shader = shader);
  }
}

double gradientAt(double s, double total) => SpiralGeometry.gradientAt(s, total);
