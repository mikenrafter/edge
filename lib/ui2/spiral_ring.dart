// Spiral ring geometry (RED STUBS). The implementer replaces every body; the
// signatures are what test/ui2_spiral_ring_test.dart pins. Positions `s` are
// in laps along the bar: 0 = 12 o'clock at the start, 1 = one full lap.
/// Pixel width of the card-coloured line between overlapping laps.
const double kSpiralSeparator = 1.5;

/// One drawable piece: part of segment [seg] within lap [lap], from lap
/// position [from] to [to] (never crosses a lap boundary).
class SpiralPiece {
  final int seg, lap;
  final double from, to;

  /// Round cap at the clockwise end / at the start.
  final bool capEnd, capStart;
  const SpiralPiece(this.seg, this.lap, this.from, this.to,
      {this.capEnd = false, this.capStart = false});
}

class SpiralGeometry {
  /// Transition arc as a fraction of a lap, and inset per lap in strokes.
  final double stroke, ramp, insetPerStroke;
  const SpiralGeometry(this.stroke, {this.ramp = .3, this.insetPerStroke = .75});

  /// Inward travel of the centre line, in px, at lap position [s].
  double inset(double s) => 0;

  /// Centre-line radius at [s] for a lap-0 centre-line radius [r0].
  double radiusAt(double s, double r0) => 0;

  /// Laps a bar of [fraction] laps touches: 0 for <= 0 / NaN, else ceil.
  static int lapsFor(double fraction) => -1;

  /// Pieces for segments given as (colour-agnostic) fractions of a lap, IN
  /// PAINT ORDER: lowest lap first; within a lap the last segment first, so
  /// each segment paints on top of its clockwise neighbour.
  List<SpiralPiece> pieces(List<double> fractions) => const [];

  /// Where the separator for [lap] starts (null for lap 0): lap 1 where the
  /// inset first reaches half a pixel, later laps at their own start.
  double? separatorFrom(int lap) => -1;

  /// Position along the WHOLE bar, 0..1, for the gradient at [s].
  static double gradientAt(double s, double total) => -1;
}
