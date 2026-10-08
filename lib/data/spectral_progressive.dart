// spectral_progressive.dart — EXPERIMENT (branch explore/spectral-archive): the
// pure parts of progressive loading for long chart views.
//
// RED PHASE: throwing stubs; test/spectral/spectral_progressive_test.dart pins
// the contract. The chart widget itself is a thin GREEN-phase prototype on
// these three pieces:
//
//   [refineStream]   successive refinements, decoded OFF the UI isolate
//   [SpectralLerp]   sample-by-sample animation between two decoded curves
//   [SpectralDetail] what the chart may claim at the current level
//
// A reconstruction is an approximation (invariant 3). While it is not the full
// level the chart says so and shows no precise number readout.

import 'dart:typed_data';

import 'spectral_codec.dart' show SpectralRefinement;

/// Refinements of [blob], each produced off the UI isolate (one `Isolate.run`
/// hop per step, or small chunks yielded between steps). Emits exactly the
/// steps of `SpectralCodec.progressive(blob, orders: orders)`, in order, then
/// closes. Cancelling the subscription stops further steps.
Stream<SpectralRefinement> refineStream(Uint8List blob,
        {List<int> orders = const [0, 2, 8, 32]}) =>
    throw UnimplementedError('refineStream');

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
          List<double?> from, List<double?> to, double t) =>
      throw UnimplementedError('SpectralLerp.between');
}

/// What the chart may say at a given refinement level.
class SpectralDetail {
  const SpectralDetail(this.step, {required this.isFull});

  /// Wraps a refinement.
  factory SpectralDetail.of(SpectralRefinement r) =>
      throw UnimplementedError('SpectralDetail.of');

  final SpectralRefinement? step;
  final bool isFull;

  /// True until the full level has arrived: the chart shows a "loading detail"
  /// label (l10n key `spectralLoadingDetail`).
  bool get isLoadingDetail => throw UnimplementedError('isLoadingDetail');

  /// The numeric readout for slot [i] (e.g. a scrub tooltip), or null when the
  /// chart may not claim a number: null while loading detail, null in a gap,
  /// otherwise the full-level value.
  double? readout(int i) => throw UnimplementedError('readout');
}
