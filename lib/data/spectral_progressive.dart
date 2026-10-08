// spectral_progressive.dart — EXPERIMENT (branch explore/spectral-archive): the
// pure parts of progressive loading for long chart views.
//
//   [refineStream]   successive refinements, decoded OFF the UI isolate
//   [SpectralLerp]   sample-by-sample animation between two decoded curves
//   [SpectralDetail] what the chart may claim at the current level
//
// A reconstruction is an approximation (invariant 3). While it is not the full
// level the chart says so and shows no precise number readout.

import 'dart:isolate';
import 'dart:typed_data';

import 'spectral_codec.dart' show SpectralCodec, SpectralRefinement;

/// Refinements of [blob], each produced off the UI isolate (one `Isolate.run`
/// hop per step). Emits exactly the steps of
/// `SpectralCodec.progressive(blob, orders: orders)`, in order, then closes.
/// Cancelling the subscription stops further steps.
Stream<SpectralRefinement> refineStream(Uint8List blob,
    {List<int> orders = const [0, 2, 8, 32]}) async* {
  for (var k = 0;; k++) {
    final r = await Isolate.run(
        () => SpectralCodec.refinementAt(blob, orders: orders, step: k));
    if (r == null) return;
    yield r;
    if (r.isFull) return;
  }
}

class SpectralLerp {
  SpectralLerp._();

  /// The animation frame between two decoded curves of one series.
  ///
  ///  * sample-by-sample only: `(1-t)*from[i] + t*to[i]`;
  ///  * a slot that is null in EITHER curve is null (never interpolated across
  ///    or into a gap) - except that t == 1 returns [to] exactly, nulls and all;
  ///  * t must be in [0, 1]: anything else (and NaN) throws [ArgumentError], so
  ///    nothing is ever extrapolated;
  ///  * the curves must be the same length ([ArgumentError] otherwise).
  static List<double?> between(
      List<double?> from, List<double?> to, double t) {
    if (!(t >= 0 && t <= 1)) {
      throw ArgumentError.value(t, 't', 'must be in [0, 1]');
    }
    if (from.length != to.length) {
      throw ArgumentError('curves differ in length: '
          '${from.length} vs ${to.length}');
    }
    if (t == 1) return List<double?>.of(to);
    final out = List<double?>.filled(from.length, null);
    for (var i = 0; i < from.length; i++) {
      final a = from[i], b = to[i];
      if (a == null || b == null) continue;
      out[i] = (1 - t) * a + t * b;
    }
    return out;
  }
}

/// What the chart may say at a given refinement level.
class SpectralDetail {
  const SpectralDetail(this.step, {required this.isFull, this.exact = false});

  /// A lossless-at-quantum archive part: not an approximation.
  final bool exact;

  /// Wraps a refinement. [exact] marks a LOSSLESS-at-quantum archive part: it
  /// is not an approximation and carries no approximation label.
  factory SpectralDetail.of(SpectralRefinement r, {bool exact = false}) =>
      SpectralDetail(r, isFull: r.isFull, exact: exact);

  final SpectralRefinement? step;
  final bool isFull;

  /// True until the full level has arrived: the chart shows a "loading detail"
  /// label (l10n key `spectralLoadingDetail`).
  bool get isLoadingDetail => !isFull;

  /// True for every LOSSY reconstruction at ANY refinement: full detail removes
  /// the "loading" caveat, not the "approximate" one. False only for a
  /// lossless-at-quantum part ([exact]).
  bool get isApproximation => !exact;

  /// The l10n key of the label the chart must show: `spectralLoadingDetail`
  /// until the full level has arrived, `spectralApproximation` after; null for
  /// an exact part, which needs no label.
  String? get labelKey => exact
      ? null
      : (isFull ? 'spectralApproximation' : 'spectralLoadingDetail');

  /// The numeric readout for slot [i] (e.g. a scrub tooltip), or null when the
  /// chart may not claim a number: null while loading detail, null in a gap,
  /// otherwise the full-level value.
  double? readout(int i) {
    final s = step;
    if (!isFull || s == null || i < 0 || i >= s.samples.length) return null;
    return s.samples[i];
  }
}
