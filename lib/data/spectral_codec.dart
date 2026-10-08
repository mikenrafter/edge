// spectral_codec.dart — EXPERIMENT (branch explore/spectral-archive): a lossy,
// error-bounded block-DCT codec for the 1 Hz `decoded_onehz` signals, so a long
// record can outlive `rawRetentionDays` at much higher fidelity than the daily
// scalars alone.
//
// RED PHASE: every method below is a throwing stub. The doc comments pin the
// contract the tests in test/spectral/ hold the green phase to.
//
// DESIGN (pinned by the tests, challenged in the report):
//   * SEGMENT transform, not a whole-day Fourier series: DCT-II per segment (no
//     periodicity assumption, so a step costs one segment, not the day). Two
//     segmentations, both emitted by the same codec:
//       - [SpectralMode.adaptive] (default): a segment grows in 1-minute
//         extensions while it still fits BOTH [SpectralSignalSpec
//         .maxCoefficients] and the error allowance (maxRms / maxAbs); when the
//         next minute would not fit, the segment closes and a new one starts.
//         Segments are variable-length, never span a gap, and are multiples of
//         60 s except the last segment of a valid run (a run's tail).
//       - [SpectralMode.staticBlocks]: fixed [SpectralSignalSpec.blockSeconds]
//         (240 s) windows over the day index, clipped to valid runs. The
//         comparison baseline for the experiment harness.
//   * The encoder keeps the FEWEST coefficients per segment that still meet the
//     signal's error bound ([SpectralSignalSpec.maxRms] / [maxAbs]), then
//     quantizes with [SpectralSignalSpec.quantum]. The bound is a HARD
//     contract: on a signal the transform cannot compress (white noise) the
//     encoder spends bytes until the bound holds, it never returns a blob that
//     violates it.
//   * LOD for long-range charts. The blob stores (a) a SUMMARY PYRAMID of
//     per-cell count/min/mean/max over 60 s, 900 s, 3600 s and the whole series,
//     computed from the RAW samples at encode time (never from the
//     reconstruction), gaps honoured (count 0 => no stats), readable without
//     touching a coefficient; and (b) coefficients ordered low-order first, so
//     a reader can stop early ([SpectralCodec.decodeCoarse]). Layout order:
//     header, pyramid, segment table, coefficients (see
//     [SpectralHeader.coefficientOffset]).
//   * Absence is never interpolated or imputed (AGENTS invariant 3). Missing
//     seconds are stored as a run-length validity mask; only valid runs are
//     transformed; decode returns null exactly where the input had null.
//   * The reported [SpectralStats] error is MEASURED by decoding, not estimated.
//   * Deterministic (same input, same bytes, on any isolate) and PURE: no I/O
//     beyond dart:typed_data / dart:convert / dart:io zlib, no plugins, no
//     clock. Safe on any isolate.
//   * A reconstruction is an approximation. Nothing derived may read it
//     (invariant 3) — `lib/compute` must never reference this file.

import 'dart:typed_data';

/// One signal's tolerances. [quantum] is the coefficient quantizer step (stored
/// in the blob header so a future build can still read an old blob).
class SpectralSignalSpec {
  const SpectralSignalSpec({
    required this.id,
    required this.quantum,
    required this.maxRms,
    required this.maxAbs,
    this.blockSeconds = 240,
    this.maxCoefficients = 48,
  });

  final String id;
  final double quantum;

  /// RMS error bound over a day's valid samples, in the signal's own unit.
  final double maxRms;

  /// Per-sample absolute error bound, in the signal's own unit.
  final double maxAbs;

  /// Static-mode window; a multiple of 60.
  final int blockSeconds;

  /// Adaptive mode: the most coefficients one segment may hold. Must be >= 60
  /// (a one-minute segment always fits losslessly-to-quantum), which is what
  /// guarantees the error bound is reachable on any input.
  final int maxCoefficients;
}

enum SpectralMode { adaptive, staticBlocks }

/// What an encode measured about itself. All errors are in the signal's unit
/// and are measured against the decoded blob, over valid samples only.
class SpectralStats {
  const SpectralStats({
    required this.nSamples,
    required this.nValid,
    required this.coefficientCount,
    required this.segmentCount,
    required this.summaryBytes,
    required this.bytes,
    required this.rmsErr,
    required this.maxErr,
  });

  final int nSamples;
  final int nValid;

  /// Non-zero quantized coefficients actually stored.
  final int coefficientCount;

  final int segmentCount;

  /// Bytes the summary pyramid occupies inside [bytes].
  final int summaryBytes;

  /// Length of the blob.
  final int bytes;
  final double rmsErr;
  final double maxErr;
}

class SpectralEncoding {
  const SpectralEncoding(this.blob, this.stats);
  final Uint8List blob;
  final SpectralStats stats;
}

/// The versioned header every blob starts with (readable without decoding).
class SpectralHeader {
  const SpectralHeader({
    required this.codecVersion,
    required this.signal,
    required this.mode,
    required this.blockSeconds,
    required this.quantum,
    required this.length,
    required this.nValid,
    required this.segmentCount,
    required this.coefficientOffset,
  });

  final int codecVersion;
  final String signal;
  final SpectralMode mode;

  /// The static window the blob was written with (informational in adaptive
  /// mode; kept so the header is self-describing).
  final int blockSeconds;
  final double quantum;

  /// Sample slots in the series (seconds in the local day: 82800 / 86400 /
  /// 90000 on a DST day — never assume 86400).
  final int length;
  final int nValid;
  final int segmentCount;

  /// Bytes before the first coefficient (header + pyramid + segment table).
  /// A reader that only draws summaries needs no more than this prefix.
  final int coefficientOffset;
}

/// One transform segment: slots [start, start + length) of the series.
class SpectralSegment {
  const SpectralSegment(this.start, this.length, this.coefficientCount);
  final int start, length;

  /// Non-zero quantized coefficients stored for this segment.
  final int coefficientCount;
}

/// One pyramid cell. [count] is the number of VALID seconds in the cell; with
/// count 0 the stats are null (a gap is never summarised as a number).
class LodCell {
  const LodCell(this.count, this.min, this.mean, this.max);
  final int count;
  final double? min, mean, max;
}

/// One pyramid level. Cell i covers slots [i*cellSeconds, (i+1)*cellSeconds)
/// (the last cell may be partial). The top level has ONE cell covering the
/// whole series, so its [cellSeconds] equals the series length.
class SpectralLevel {
  const SpectralLevel(this.cellSeconds, this.cells);
  final int cellSeconds;
  final List<LodCell> cells;
}

/// One step of progressive decoding: every segment decoded with orders
/// 0..[maxOrder] only. [isFull] marks the last step, which equals [decode].
class SpectralRefinement {
  const SpectralRefinement(this.maxOrder, this.isFull, this.samples);
  final int maxOrder;
  final bool isFull;

  /// Null exactly where the input was null, at every step.
  final List<double?> samples;
}

class SpectralCodec {
  SpectralCodec._();

  /// Bumped whenever the byte layout or the reconstruction changes. A blob of
  /// any other version is refused by [decode], never guessed at.
  static const int codecVersion = 1;

  /// Signals the archive covers and their bounds. Justification:
  ///  * `hr` (bpm): the owner's bound, RMS <= 1 and max <= 3. Inside a zone
  ///    width and well under a night's beat-to-beat spread.
  ///  * `ax`/`ay`/`az` (g, gravity vector): stillness jitter is ~0.01 g and a
  ///    posture change is ~0.3 g; RMS <= 0.02 g, max <= 0.10 g keeps "still vs
  ///    moving" and posture intact.
  ///  * `skin_temp_c` (deg C): the nightly deviation the app reports is a
  ///    few tenths of a degree; RMS <= 0.05, max <= 0.15 keeps it.
  /// Raw spo2 red/ir and the counters (`step_count`, `activity_class`) are
  /// deliberately NOT here: ratios of raw ADC channels and monotone counters
  /// are not what a smoothness transform is for (see the report).
  static const Map<String, SpectralSignalSpec> specs = {
    'hr': SpectralSignalSpec(
        id: 'hr', quantum: 0.5, maxRms: 1.0, maxAbs: 3.0),
    'ax': SpectralSignalSpec(
        id: 'ax', quantum: 0.004, maxRms: 0.02, maxAbs: 0.10),
    'ay': SpectralSignalSpec(
        id: 'ay', quantum: 0.004, maxRms: 0.02, maxAbs: 0.10),
    'az': SpectralSignalSpec(
        id: 'az', quantum: 0.004, maxRms: 0.02, maxAbs: 0.10),
    'skin_temp_c': SpectralSignalSpec(
        id: 'skin_temp_c', quantum: 0.01, maxRms: 0.05, maxAbs: 0.15),
  };

  /// Encode [samples] (index = second slot of the local day, null = absent).
  /// Throws [ArgumentError] for an unknown [signal] or a non-finite value
  /// (NaN is not "absent"; null is).
  static SpectralEncoding encode(String signal, List<double?> samples,
          {SpectralMode mode = SpectralMode.adaptive}) =>
      throw UnimplementedError('SpectralCodec.encode');

  /// Inverse of [encode]. Same length as the input; null exactly where the
  /// input was null. Throws [FormatException] on bad magic, an unknown
  /// [codecVersion], or a truncated/corrupt body.
  static List<double?> decode(Uint8List blob) =>
      throw UnimplementedError('SpectralCodec.decode');

  /// Decode using only the first [maxOrder]+1 coefficients (orders
  /// 0..maxOrder) of every segment: order 0 is the segment's DC term, a
  /// piecewise-constant coarse view; larger orders refine it. Null exactly
  /// where the input was null, like [decode] (a coarse view never invents a
  /// value in a gap). With [maxOrder] >= the largest order stored it equals
  /// [decode].
  static List<double?> decodeCoarse(Uint8List blob, {required int maxOrder}) =>
      throw UnimplementedError('SpectralCodec.decodeCoarse');

  /// Successive refinements for progressive loading: one step per entry of
  /// [orders] (strictly increasing, each below the largest order stored), then
  /// a final full-detail step ([SpectralRefinement.isFull]) whose samples equal
  /// [decode] exactly. Lazy: nothing is decoded until the next step is pulled,
  /// so a caller can pull one step per frame or per isolate hop. Step k equals
  /// `decodeCoarse(blob, maxOrder: orders[k])`. Throws [ArgumentError] for
  /// non-increasing [orders].
  static Iterable<SpectralRefinement> progressive(Uint8List blob,
          {List<int> orders = const [0, 2, 8, 32]}) =>
      throw UnimplementedError('SpectralCodec.progressive');

  /// The summary pyramid, levels ordered 60 s, 900 s, 3600 s, whole series.
  /// Reads only the prefix up to [SpectralHeader.coefficientOffset]. Count,
  /// min, mean, max are from the RAW samples, stored at [quantum] resolution
  /// (so mean is within quantum/2 of the true mean, and min/max equal the true
  /// extremes rounded to the quantum — never taken from the reconstruction).
  static List<SpectralLevel> summary(Uint8List blob) =>
      throw UnimplementedError('SpectralCodec.summary');

  /// The segment table, in slot order. Same [FormatException] rules.
  static List<SpectralSegment> segments(Uint8List blob) =>
      throw UnimplementedError('SpectralCodec.segments');

  /// The header alone, with the same [FormatException] rules as [decode].
  static SpectralHeader readHeader(Uint8List blob) =>
      throw UnimplementedError('SpectralCodec.readHeader');
}
