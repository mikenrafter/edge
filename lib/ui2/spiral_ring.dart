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

  /// Centre-line radius at [s]. Floored at 1.5 x stroke so a small ring at a
  /// high ratio (a 20 px ring at 500%) keeps its laps on the dial instead of
  /// running through the centre; beyond that laps overlap at the innermost
  /// radius and the value label carries the number.
  double radiusAt(double s, double r0) =>
      max(r0 - inset(s), min(r0, 1.5 * stroke));
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
///
/// Every piece is a FILLED band whose radius follows [SpiralGeometry.radiusAt]
/// along its whole sweep, so the eased inset is drawn, not sampled once per
/// piece. Caps are separate discs: ends and starts are decided independently
/// by [SpiralPiece.capEnd] / [SpiralPiece.capStart]. [background] is the
/// surface under the ring (the lap separator); it falls back to [track].
void paintSpiral(Canvas canvas, Size size,
    {required double stroke,
    required Color track,
    required List<Color> colors,
    required List<double> fractions,
    required double t,
    bool solid = true,
    Color? background}) {
  final center = Offset(size.width / 2, size.height / 2);
  final r0 = min(size.width, size.height) / 2 - stroke / 2;
  if (r0 <= 0) return;
  final half = stroke / 2;
  canvas.drawCircle(
      center,
      r0,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track);
  final progress = t.clamp(0.0, 1.0);
  final scaled = [
    for (final f in fractions) f.isFinite && f > 0 ? f * progress : 0.0
  ];
  final geometry = SpiralGeometry(stroke);
  final total = scaled.fold<double>(0, (a, b) => a + b);
  final pieces = geometry.pieces(scaled);
  if (pieces.isEmpty) return;

  Offset pt(double s, double radius) {
    final a = -pi / 2 + 2 * pi * s;
    return center + Offset(cos(a), sin(a)) * radius;
  }

  // A closed band from lap position [a] to [b], [grow] px wider each side.
  Path band(double a, double b, double grow) {
    final n = max(2, ((b - a) * 360).ceil());
    final path = Path();
    for (var i = 0; i <= n; i++) {
      final s = a + (b - a) * i / n;
      final o = pt(s, geometry.radiusAt(s, r0) + half + grow);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    for (var i = n; i >= 0; i--) {
      final s = a + (b - a) * i / n;
      final o = pt(s, geometry.radiusAt(s, r0) - half - grow);
      path.lineTo(o.dx, o.dy);
    }
    return path..close();
  }

  Color colourAt(SpiralPiece p, double s) {
    final c = colors[p.seg];
    return solid
        ? c
        : Color.lerp(c.withValues(alpha: .55), c, gradientAt(s, total))!;
  }

  final sepColour = background ?? track;
  canvas.save();
  // The outer edge never leaves the lap-0 circle.
  canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: r0 + half)));
  for (final p in pieces) {
    if (p.lap >= 1) {
      // Just before the lap that overlaps it, along that lap's own sweep.
      final from = max(p.from, geometry.separatorFrom(p.lap)!);
      final fill = Paint()..color = sepColour;
      if (from < p.to) canvas.drawPath(band(from, p.to, kSpiralSeparator), fill);
      if (p.capEnd && p.to > from) {
        canvas.drawCircle(pt(p.to, geometry.radiusAt(p.to, r0)),
            half + kSpiralSeparator, fill);
      }
    }
    // A lap cut overlaps the next lap's start slightly: no hairline seam.
    final to = p.capEnd ? p.to : p.to + .003;
    final paint = Paint()..style = PaintingStyle.fill;
    final ua = p.from - p.lap, ub = p.to - p.lap;
    if (solid || ub - ua < 1e-6) {
      paint.color = colourAt(p, (p.from + p.to) / 2);
    } else {
      paint
        ..color = const Color(0xFF000000)
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: 2 * pi,
          colors: [colourAt(p, p.from), colourAt(p, p.to)],
          stops: [ua, ub],
          transform: const GradientRotation(-pi / 2),
        ).createShader(Rect.fromCircle(center: center, radius: r0));
    }
    canvas.drawPath(band(p.from, to, 0), paint);
    if (p.capEnd) {
      canvas.drawCircle(pt(p.to, geometry.radiusAt(p.to, r0)), half,
          Paint()..color = colourAt(p, p.to));
    }
    if (p.capStart) {
      canvas.drawCircle(pt(p.from, geometry.radiusAt(p.from, r0)), half,
          Paint()..color = colourAt(p, p.from));
    }
  }
  canvas.restore();
}

double gradientAt(double s, double total) => SpiralGeometry.gradientAt(s, total);
