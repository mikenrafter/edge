// spectral_codec.dart — EXPERIMENT (branch explore/spectral-archive): a lossy,
// error-bounded block-DCT codec for the 1 Hz `decoded_onehz` signals, so a long
// record can outlive `rawRetentionDays` at much higher fidelity than the daily
// scalars alone.
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
//     signal's error bound ([SpectralSignalSpec.maxRms] / [maxAbs]). The DCT is
//     orthonormal, so the coefficients are chosen by the squared error each
//     removes once quantized (a SPARSE choice, not a low-pass prefix: a signal
//     with a fast periodic component costs a couple of coefficients, not all of
//     them), the DC term always first. Coefficients are quantized with
//     [SpectralSignalSpec.quantum]. The bound is a HARD
//     contract: on a signal the transform cannot compress (white noise) the
//     encoder spends bytes until the bound holds, it never returns a blob that
//     violates it.
//   * LOD for long-range charts. The blob stores (a) a SUMMARY PYRAMID of
//     per-cell count/min/mean/max over 60 s, 900 s, 3600 s and the whole series,
//     computed from the RAW samples at encode time (never from the
//     reconstruction), gaps honoured (count 0 => no stats), readable without
//     touching a coefficient; and (b) each segment's coefficients stored in
//     ascending order, so a reader can stop at any order
//     ([SpectralCodec.decodeCoarse], [SpectralCodec.progressive]). Layout:
//     header, validity mask, pyramid, segment table (each section raw-deflate),
//     then the coefficient section (see [SpectralHeader.coefficientOffset]);
//     everything before the coefficients is readable from that prefix alone.
//   * Two NON-DCT modes exist for signals that do not compress under a
//     smoothness transform (the accelerometer axes, ~1.0x vs lossless on real
//     data): [SpectralMode.losslessAtQuantum] (round to the header's quantum,
//     then first/second differences + deflate; EXACT relative to that quantum,
//     max error quantum / 2, so a reader may show it without the approximation
//     label) and [SpectralMode.pyramidOnly] (the validity mask and the true
//     summary pyramid, no samples; `decode` refuses it). Same container, same
//     version: the mode byte of the header says which.
//   * Absence is never interpolated or imputed (AGENTS invariant 3). Missing
//     seconds are stored as a run-length validity mask; only valid runs are
//     transformed; decode returns null exactly where the input had null.
//   * The reported [SpectralStats] error is MEASURED by decoding, not estimated.
//   * Deterministic (same input, same bytes, on any isolate) and PURE: no I/O
//     beyond dart:typed_data and dart:io's in-memory zlib, no plugins, no
//     clock. Safe on any isolate. The encoder's fit check and the decoder run
//     the SAME synthesis function, so the error it certifies is the error a
//     reader gets, bit for bit.
//   * A reconstruction is an approximation. Nothing derived may read it
//     (invariant 3) — `lib/compute` must never reference this file.

import 'dart:io' show ZLibCodec;
import 'dart:math' as math;
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
    this.maxCoefficients = 64,
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

enum SpectralMode {
  /// Lossy DCT, adaptive segments (the default).
  adaptive,

  /// Lossy DCT, fixed 240 s blocks (comparison baseline).
  staticBlocks,

  /// LOSSLESS RELATIVE TO THE STORED QUANTUM (`SpectralHeader.quantum`): every
  /// valid sample is rounded to the nearest multiple of the quantum and stored
  /// exactly (first/second differences + deflate). The reconstruction error is
  /// at most quantum / 2 and the stored value is exactly `round(v / q) * q`.
  losslessAtQuantum,

  /// The validity mask and the true summary pyramid only: NO samples. Nothing
  /// can be reconstructed from it.
  pyramidOnly,
}

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

  /// Coefficients actually stored, over all segments.
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

  /// Coefficients stored for this segment (DC included).
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

/// One part's pyramid together with the absolute second its slot 0 is.
class SpectralPartSummary {
  const SpectralPartSummary(this.originSec, this.levels);
  final int originSec;
  final List<SpectralLevel> levels;
}

class SpectralCodec {
  SpectralCodec._();

  /// Bumped whenever the byte layout or the reconstruction changes. A blob of
  /// any other version is refused by [decode], never guessed at.
  static const int codecVersion = 1;

  /// Longest adaptive segment, in 60 s extensions (30 x 60 = 30 min).
  static const int _maxExtensions = 30;

  static const List<int> _magic = [0x4f, 0x53, 0x50, 0x58]; // "OSPX"

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
  /// are not what a smoothness transform is for (a lossless / run-length
  /// archive could cover them later).
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

  // ── encode ─────────────────────────────────────────────────────────────────

  /// Encode [samples] (index = second slot of the local day, null = absent).
  /// Throws [ArgumentError] for an unknown [signal] or a non-finite value
  /// (NaN is not "absent"; null is).
  static SpectralEncoding encode(String signal, List<double?> samples,
          {SpectralMode mode = SpectralMode.adaptive}) =>
      _encode(signal, samples, mode);

  static SpectralEncoding _encode(
      String signal, List<double?> samples, SpectralMode mode,
      {Uint8List? pyramid}) {
    final spec = specs[signal];
    if (spec == null) throw ArgumentError.value(signal, 'signal', 'unknown');
    final n = samples.length;
    var nValid = 0;
    for (final v in samples) {
      if (v == null) continue;
      if (!v.isFinite) {
        throw ArgumentError.value(v, 'samples', 'non-finite; use null for absent');
      }
      nValid++;
    }

    // Valid runs [start, end).
    final runs = <(int, int)>[];
    for (var i = 0; i < n;) {
      if (samples[i] == null) {
        i++;
        continue;
      }
      var j = i;
      while (j < n && samples[j] != null) {
        j++;
      }
      runs.add((i, j));
      i = j;
    }

    final tables = _Tables();
    final segs = <_Seg>[];
    final lossy =
        mode == SpectralMode.adaptive || mode == SpectralMode.staticBlocks;
    if (lossy) {
      for (final (a, b) in runs) {
        if (mode == SpectralMode.adaptive) {
          _segmentRunAdaptive(samples, a, b, spec, tables, segs);
        } else {
          _segmentRunStatic(samples, a, b, spec, tables, segs);
        }
      }
    }

    final mask = _W();
    {
      var cur = false;
      var run = 0;
      for (final v in samples) {
        if ((v != null) == cur) {
          run++;
        } else {
          mask.varint(run);
          cur = !cur;
          run = 1;
        }
      }
      mask.varint(run);
    }

    pyramid ??= _pyramidBytes(samples, spec.quantum);

    final segTab = _W();
    for (final g in segs) {
      segTab.varint(g.length);
      segTab.varint(g.idx.length);
    }

    final gaps = _W(), vals = _W();
    for (final g in segs) {
      var prev = -1;
      for (var e = 0; e < g.idx.length; e++) {
        gaps.varint(g.idx[e] - prev - 1);
        prev = g.idx[e];
        vals.zigzag(g.val[e]);
      }
    }
    final gapBytes = gaps.take();
    final coef = _W();
    if (lossy) {
      coef
        ..varint(gapBytes.length)
        ..bytes(gapBytes)
        ..bytes(vals.take());
    } else if (mode == SpectralMode.losslessAtQuantum) {
      coef.bytes(_losslessPayload(samples, spec.quantum));
    }

    final maskZ = _deflate(mask.take());
    final pyrZ = _deflate(pyramid);
    final segZ = _deflate(segTab.take());
    final coefZ = _deflate(coef.take());

    final out = _W()
      ..bytes(_magic)
      ..byte(codecVersion)
      ..byte(mode.index)
      ..byte(signal.length)
      ..bytes(signal.codeUnits)
      ..varint(spec.blockSeconds)
      ..f64(spec.quantum)
      ..varint(n)
      ..varint(nValid)
      ..varint(segs.length)
      ..varint(maskZ.length)
      ..varint(pyrZ.length)
      ..varint(segZ.length)
      ..varint(coefZ.length)
      ..bytes(maskZ)
      ..bytes(pyrZ)
      ..bytes(segZ)
      ..bytes(coefZ);
    final blob = out.take();

    // Measure, don't estimate: decode what was just written. A pyramid-only
    // blob has no reconstruction, hence no error to measure (reported as 0).
    var sq = 0.0, mx = 0.0;
    if (mode != SpectralMode.pyramidOnly) {
      final back = decode(blob);
      for (var i = 0; i < n; i++) {
        final o = samples[i];
        if (o == null) continue;
        final d = (back[i]! - o).abs();
        sq += d * d;
        if (d > mx) mx = d;
      }
    }
    return SpectralEncoding(
      blob,
      SpectralStats(
        nSamples: n,
        nValid: nValid,
        coefficientCount: segs.fold<int>(0, (a, g) => a + g.idx.length),
        segmentCount: segs.length,
        summaryBytes: pyrZ.length,
        bytes: blob.length,
        rmsErr: nValid == 0 ? 0 : math.sqrt(sq / nValid),
        maxErr: mx,
      ),
    );
  }

  static void _segmentRunAdaptive(List<double?> s, int a, int b,
      SpectralSignalSpec spec, _Tables t, List<_Seg> out) {
    var pos = a;
    while (pos < b) {
      final rem = b - pos;
      final jmax = math.min(_maxExtensions, (rem + 59) ~/ 60);
      int lenOf(int j) => math.min(j * 60, rem);
      final tried = <int, _Seg?>{};
      _Seg? fits(int j) => tried.putIfAbsent(
          j, () => _fit(s, pos, lenOf(j), spec, spec.maxCoefficients, t));

      var lo = 1;
      var hi = -1;
      if (fits(1) == null) {
        // Cannot happen (a one-minute segment holds up to 64 coefficients and
        // the quantizer alone is inside the bound), but never emit a blob that
        // violates the contract.
        throw StateError('spectral: even a 1-minute segment misses the bound');
      }
      while (lo < jmax) {
        final next = math.min(lo * 2, jmax);
        if (fits(next) != null) {
          lo = next;
        } else {
          hi = next;
          break;
        }
      }
      while (hi > 0 && hi - lo > 1) {
        final mid = (lo + hi) ~/ 2;
        if (fits(mid) != null) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      final seg = tried[lo]!;
      out.add(seg);
      pos += seg.length;
    }
  }

  static void _segmentRunStatic(List<double?> s, int a, int b,
      SpectralSignalSpec spec, _Tables t, List<_Seg> out) {
    final w = spec.blockSeconds;
    var pos = a;
    while (pos < b) {
      final end = math.min(b, (pos ~/ w + 1) * w);
      final seg = _fit(s, pos, end - pos, spec, 1 << 30, t);
      if (seg == null) {
        throw StateError('spectral: static block misses the bound');
      }
      out.add(seg);
      pos = end;
    }
  }

  /// The fewest coefficients (<= [cap]) that bring slots [start, start+n) of
  /// [s] inside the spec's bounds, or null when none do.
  static _Seg? _fit(List<double?> s, int start, int n, SpectralSignalSpec spec,
      int cap, _Tables t) {
    final q = spec.quantum;
    final x = Float64List(n);
    for (var i = 0; i < n; i++) {
      x[i] = s[start + i]!;
    }
    final c = _dct(x, t);
    var total = 0.0;
    final qv = List<int>.filled(n, 0);
    final gain = Float64List(n);
    final cand = <int>[];
    for (var k = 0; k < n; k++) {
      total += c[k] * c[k];
      final v = (c[k] / q).round();
      qv[k] = v;
      final e = c[k] - v * q;
      gain[k] = c[k] * c[k] - e * e;
      if (k != 0 && v != 0) cand.add(k);
    }
    // DC first (always stored), the rest by the error each removes.
    cand.sort((p, r) {
      final d = gain[r].compareTo(gain[p]);
      return d != 0 ? d : p.compareTo(r);
    });
    final order = [0, ...cand];
    final budget = n * spec.maxRms * spec.maxRms;

    var m = 1;
    var drop = total - gain[0];
    while (m < order.length && drop > budget) {
      drop -= gain[order[m]];
      m++;
    }
    final limit = math.max(cap, n < 60 ? n : 0);
    while (true) {
      if (m > limit) return null;
      final pick = order.sublist(0, m)..sort();
      final val = [for (final k in pick) qv[k]];
      final r = _synth(n, pick, val, q, t);
      var sq = 0.0, mx = 0.0;
      for (var i = 0; i < n; i++) {
        final d = (r[i] - x[i]).abs();
        sq += d * d;
        if (d > mx) mx = d;
      }
      if (math.sqrt(sq / n) <= spec.maxRms && mx <= spec.maxAbs) {
        return _Seg(start, n, pick, val);
      }
      if (m >= order.length) return null;
      m = math.min(order.length, m + math.max(1, m ~/ 4));
    }
  }

  // ── decode ─────────────────────────────────────────────────────────────────

  /// Inverse of [encode]. Same length as the input; null exactly where the
  /// input was null. Throws [FormatException] on bad magic, an unknown
  /// [codecVersion], or a truncated/corrupt body.
  static List<double?> decode(Uint8List blob) =>
      _decode(_parse(blob), 1 << 30);

  /// Decode using only the coefficients of order <= [maxOrder] in every segment
  /// (order = DCT index; 0 is the segment's DC term, a piecewise-constant
  /// coarse view; larger orders refine it). Null exactly where the input was
  /// null, like [decode] (a coarse view never invents a value in a gap). With
  /// [maxOrder] >= the largest order stored it equals [decode].
  static List<double?> decodeCoarse(Uint8List blob, {required int maxOrder}) =>
      _decode(_parse(blob), maxOrder);

  /// Successive refinements for progressive loading: one step per entry of
  /// [orders] (strictly increasing; entries at or above the largest order
  /// stored fold into the final step), then a final full-detail step
  /// ([SpectralRefinement.isFull]) whose samples equal [decode] exactly. Lazy:
  /// nothing is decoded until the next step is pulled, so a caller can pull one
  /// step per frame or per isolate hop. Step k equals
  /// `decodeCoarse(blob, maxOrder: orders[k])`. Throws [ArgumentError] for
  /// negative or non-increasing [orders].
  static Iterable<SpectralRefinement> progressive(Uint8List blob,
      {List<int> orders = const [0, 2, 8, 32]}) sync* {
    for (var i = 0; i < orders.length; i++) {
      if (orders[i] < 0 || (i > 0 && orders[i] <= orders[i - 1])) {
        throw ArgumentError.value(orders, 'orders', 'must be increasing, >= 0');
      }
    }
    final p = _parse(blob);
    var top = 0;
    for (final g in p.segs) {
      top = math.max(top, g.idx.last);
    }
    for (final o in orders) {
      if (o >= top) break;
      yield SpectralRefinement(o, false, _decode(p, o));
    }
    yield SpectralRefinement(top, true, _decode(p, 1 << 30));
  }

  /// Exactly step [step] of [progressive] (0-based), decoding only that step,
  /// or null when [step] is past the final one. For callers that run each
  /// refinement in its own isolate hop (a generator cannot cross isolates).
  static SpectralRefinement? refinementAt(Uint8List blob,
      {List<int> orders = const [0, 2, 8, 32], required int step}) {
    for (var i = 0; i < orders.length; i++) {
      if (orders[i] < 0 || (i > 0 && orders[i] <= orders[i - 1])) {
        throw ArgumentError.value(orders, 'orders', 'must be increasing, >= 0');
      }
    }
    final p = _parse(blob);
    var top = 0;
    for (final g in p.segs) {
      top = math.max(top, g.idx.last);
    }
    final partial = [for (final o in orders) if (o < top) o];
    if (step < 0 || step > partial.length) return null;
    if (step < partial.length) {
      return SpectralRefinement(partial[step], false, _decode(p, partial[step]));
    }
    return SpectralRefinement(top, true, _decode(p, 1 << 30));
  }

  /// The summary pyramid, levels ordered 60 s, 900 s, 3600 s, whole series.
  /// Reads only the prefix up to [SpectralHeader.coefficientOffset]. Count,
  /// min, mean, max are from the RAW samples, stored at [quantum] resolution
  /// (so mean is within quantum/2 of the true mean, and min/max equal the true
  /// extremes rounded to the quantum — never taken from the reconstruction).
  static List<SpectralLevel> summary(Uint8List blob) {
    final h = _head(blob);
    final r = _R(_inflate(blob, h.pyrAt, h.pyrLen));
    final q = h.header.quantum;
    final out = <SpectralLevel>[];
    try {
      var prevMean = 0;
      for (final cs in _levelSeconds(h.header.length)) {
        final cells = <LodCell>[];
        final nCells = _cellCount(h.header.length, cs);
        for (var i = 0; i < nCells; i++) {
          final count = r.varint();
          if (count == 0) {
            cells.add(const LodCell(0, null, null, null));
            continue;
          }
          final mean = prevMean + r.zigzag();
          prevMean = mean;
          final lo = mean - r.varint();
          final hi = mean + r.varint();
          cells.add(LodCell(count, lo * q, mean * q, hi * q));
        }
        out.add(SpectralLevel(cs, cells));
      }
    } on RangeError {
      throw const FormatException('spectral: truncated pyramid');
    }
    return out;
  }

  /// The segment table, in slot order. Same [FormatException] rules.
  static List<SpectralSegment> segments(Uint8List blob) {
    final h = _head(blob);
    if (h.header.mode == SpectralMode.losslessAtQuantum ||
        h.header.mode == SpectralMode.pyramidOnly) {
      return const [];
    }
    final raw = _segTable(blob, h);
    final starts = _segmentStarts(blob, h, raw);
    return [
      for (var i = 0; i < raw.length; i++)
        SpectralSegment(starts[i], raw[i].$1, raw[i].$2)
    ];
  }

  /// The valid runs `[start, end)` of the series the blob describes (the
  /// slots it holds samples for), from the prefix alone.
  static List<(int, int)> validRuns(Uint8List blob) =>
      _validRuns(blob, _head(blob));

  /// False for a [SpectralMode.pyramidOnly] blob (no samples to decode).
  static bool hasSamples(Uint8List blob) =>
      _head(blob).header.mode != SpectralMode.pyramidOnly;

  /// The header alone. It reports whatever codec version the bytes carry (only
  /// [decode] and friends refuse a version they do not know) and throws
  /// [FormatException] for bad magic or a prefix shorter than it declares.
  static SpectralHeader readHeader(Uint8List blob) => _head(blob).header;

  // ── internals ──────────────────────────────────────────────────────────────

  static List<int> _levelSeconds(int length) => [60, 900, 3600, length];

  static int _cellCount(int length, int cellSeconds) =>
      cellSeconds == length ? 1 : (length + cellSeconds - 1) ~/ cellSeconds;

  static Uint8List _deflate(Uint8List raw) =>
      Uint8List.fromList(ZLibCodec(level: 9, raw: true).encode(raw));

  static Uint8List _inflate(Uint8List blob, int at, int len) {
    try {
      return Uint8List.fromList(ZLibCodec(raw: true)
          .decode(Uint8List.sublistView(blob, at, at + len)));
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('spectral: corrupt section ($e)');
    }
  }

  static _Head _head(Uint8List blob) {
    try {
      final r = _R(blob);
      for (final m in _magic) {
        if (r.byte() != m) throw const FormatException('spectral: bad magic');
      }
      final version = r.byte();
      final modeByte = r.byte();
      if (modeByte >= SpectralMode.values.length) {
        throw const FormatException('spectral: bad mode');
      }
      final sig = String.fromCharCodes(r.take(r.byte()));
      final blockSeconds = r.varint();
      final quantum = r.f64();
      final length = r.varint();
      final nValid = r.varint();
      final segCount = r.varint();
      final maskLen = r.varint();
      final pyrLen = r.varint();
      final segLen = r.varint();
      final coefLen = r.varint();
      final maskAt = r.pos;
      final pyrAt = maskAt + maskLen;
      final segAt = pyrAt + pyrLen;
      final coefAt = segAt + segLen;
      if (coefAt > blob.length) {
        throw const FormatException('spectral: truncated header sections');
      }
      return _Head(
        SpectralHeader(
          codecVersion: version,
          signal: sig,
          mode: SpectralMode.values[modeByte],
          blockSeconds: blockSeconds,
          quantum: quantum,
          length: length,
          nValid: nValid,
          segmentCount: segCount,
          coefficientOffset: coefAt,
        ),
        maskAt, maskLen, pyrAt, pyrLen, segAt, segLen, coefAt, coefLen,
      );
    } on RangeError {
      throw const FormatException('spectral: truncated header');
    }
  }

  static List<(int, int)> _segTable(Uint8List blob, _Head h) {
    final r = _R(_inflate(blob, h.segAt, h.segLen));
    try {
      return [
        for (var i = 0; i < h.header.segmentCount; i++) (r.varint(), r.varint())
      ];
    } on RangeError {
      throw const FormatException('spectral: truncated segment table');
    }
  }

  static List<(int, int)> _validRuns(Uint8List blob, _Head h) {
    final r = _R(_inflate(blob, h.maskAt, h.maskLen));
    final runs = <(int, int)>[];
    var pos = 0;
    var valid = false;
    try {
      while (r.hasMore) {
        final len = r.varint();
        if (valid && len > 0) runs.add((pos, pos + len));
        pos += len;
        valid = !valid;
      }
    } on RangeError {
      throw const FormatException('spectral: truncated mask');
    }
    if (pos != h.header.length) {
      throw const FormatException('spectral: mask does not cover the series');
    }
    return runs;
  }

  static List<int> _segmentStarts(
      Uint8List blob, _Head h, List<(int, int)> raw) {
    final runs = _validRuns(blob, h);
    final starts = <int>[];
    var si = 0;
    for (final (a, b) in runs) {
      var pos = a;
      while (pos < b) {
        if (si >= raw.length) {
          throw const FormatException('spectral: segments end early');
        }
        starts.add(pos);
        pos += raw[si].$1;
        si++;
      }
      if (pos != b) {
        throw const FormatException('spectral: segment crosses a gap');
      }
    }
    if (si != raw.length) {
      throw const FormatException('spectral: surplus segments');
    }
    return starts;
  }

  static _Parsed _parse(Uint8List blob) {
    final h = _head(blob);
    if (h.header.codecVersion != codecVersion) {
      throw FormatException(
          'spectral: unsupported codec version ${h.header.codecVersion}');
    }
    if (blob.length != h.coefAt + h.coefLen) {
      throw const FormatException('spectral: truncated or trailing bytes');
    }
    final mode = h.header.mode;
    if (mode == SpectralMode.pyramidOnly) return _Parsed(h, const [], null);
    if (mode == SpectralMode.losslessAtQuantum) {
      return _Parsed(h, const [], _losslessInts(blob, h), _validRuns(blob, h));
    }
    final raw = _segTable(blob, h);
    final starts = _segmentStarts(blob, h, raw);
    final r = _R(_inflate(blob, h.coefAt, h.coefLen));
    final segs = <_Seg>[];
    try {
      final gapLen = r.varint();
      final gr = _R(Uint8List.sublistView(r.data, r.pos, r.pos + gapLen));
      final vr = _R(Uint8List.sublistView(r.data, r.pos + gapLen));
      for (var i = 0; i < raw.length; i++) {
        final n = raw[i].$1;
        if (raw[i].$2 < 1) throw const FormatException('spectral: empty segment');
        final idx = <int>[], val = <int>[];
        var prev = -1;
        for (var e = 0; e < raw[i].$2; e++) {
          final k = prev + 1 + gr.varint();
          if (k >= n) throw const FormatException('spectral: bad coefficient');
          idx.add(k);
          val.add(vr.zigzag());
          prev = k;
        }
        segs.add(_Seg(starts[i], n, idx, val));
      }
    } on RangeError {
      throw const FormatException('spectral: truncated coefficients');
    }
    return _Parsed(h, segs, null);
  }

  static List<double?> _decode(_Parsed p, int maxOrder) {
    final q = p.head.header.quantum;
    if (p.head.header.mode == SpectralMode.pyramidOnly) {
      throw const FormatException(
          'spectral: a pyramid-only blob holds no samples');
    }
    final out = List<double?>.filled(p.head.header.length, null);
    final ks = p.ints;
    if (ks != null) {
      var k = 0;
      for (final (a, b) in p.runs) {
        for (var i = a; i < b; i++) {
          out[i] = ks[k++] * q;
        }
      }
      return out;
    }
    final t = _Tables();
    for (final g in p.segs) {
      var take = 0;
      while (take < g.idx.length && g.idx[take] <= maxOrder) {
        take++;
      }
      final r = _synth(g.length, g.idx.sublist(0, take),
          g.val.sublist(0, take), q, t);
      for (var i = 0; i < g.length; i++) {
        out[g.start + i] = r[i];
      }
    }
    return out;
  }

  /// The one synthesis routine: encoder fit checks and the decoder both call
  /// this, with entries in ascending index, so they agree bit for bit.
  static Float64List _synth(
      int n, List<int> idx, List<int> val, double q, _Tables t) {
    final out = Float64List(n);
    if (idx.isEmpty) return out;
    final tab = t.cos(n);
    final m4 = 4 * n;
    final s0 = math.sqrt(1.0 / n), sk = math.sqrt(2.0 / n);
    for (var e = 0; e < idx.length; e++) {
      final k = idx[e];
      final amp = val[e] * q * (k == 0 ? s0 : sk);
      var j = k % m4;
      final step = (2 * k) % m4;
      for (var i = 0; i < n; i++) {
        out[i] += amp * tab[j];
        j += step;
        if (j >= m4) j -= m4;
      }
    }
    return out;
  }

  /// Orthonormal DCT-II of [x] via an N-point mixed-radix FFT.
  static Float64List _dct(Float64List x, _Tables t) {
    final n = x.length;
    if (n == 1) return Float64List.fromList([x[0]]);
    final vr = Float64List(n), vi = Float64List(n);
    for (var i = 0; 2 * i < n; i++) {
      vr[i] = x[2 * i];
    }
    for (var i = 0; 2 * i + 1 < n; i++) {
      vr[n - 1 - i] = x[2 * i + 1];
    }
    final (fr, fi) = _fft(vr, vi, n, t.twiddle(n));
    final out = Float64List(n);
    final tab = t.cos(n);
    final s0 = math.sqrt(1.0 / n), sk = math.sqrt(2.0 / n);
    for (var k = 0; k < n; k++) {
      // cos(pi k / 2n) = tab[k]; sin(pi k / 2n) = cos(pi (k - n) / 2n).
      final cs = tab[k];
      final sn = tab[(k + 3 * n) % (4 * n)];
      out[k] = (fr[k] * cs + fi[k] * sn) * (k == 0 ? s0 : sk);
    }
    return out;
  }

  /// Recursive mixed-radix DFT of length n (n0 == n at the root); [tw] holds
  /// cos/sin(2 pi j / n0).
  static (Float64List, Float64List) _fft(
      Float64List xr, Float64List xi, int n0, (Float64List, Float64List) tw) {
    final n = xr.length;
    if (n == 1) return (xr, xi);
    var p = n;
    for (var f = 2; f * f <= n; f++) {
      if (n % f == 0) {
        p = f;
        break;
      }
    }
    final m = n ~/ p;
    final stride = n0 ~/ n;
    final (ct, st) = tw;
    final yr = Float64List(n), yi = Float64List(n);
    if (m == 1) {
      for (var k = 0; k < n; k++) {
        var sr = 0.0, si = 0.0;
        for (var j = 0; j < n; j++) {
          final e = ((j * k) % n) * stride;
          final c = ct[e], s = st[e];
          sr += xr[j] * c + xi[j] * s;
          si += xi[j] * c - xr[j] * s;
        }
        yr[k] = sr;
        yi[k] = si;
      }
      return (yr, yi);
    }
    final subR = <Float64List>[], subI = <Float64List>[];
    for (var s = 0; s < p; s++) {
      final ar = Float64List(m), ai = Float64List(m);
      for (var t = 0; t < m; t++) {
        ar[t] = xr[s + p * t];
        ai[t] = xi[s + p * t];
      }
      final (br, bi) = _fft(ar, ai, n0, tw);
      subR.add(br);
      subI.add(bi);
    }
    for (var k = 0; k < m; k++) {
      for (var r = 0; r < p; r++) {
        final idx = k + m * r;
        var sr = 0.0, si = 0.0;
        for (var s = 0; s < p; s++) {
          final e = ((s * idx) % n) * stride;
          final c = ct[e], sn = st[e];
          final a = subR[s][k], b = subI[s][k];
          sr += a * c + b * sn;
          si += b * c - a * sn;
        }
        yr[idx] = sr;
        yi[idx] = si;
      }
    }
    return (yr, yi);
  }

  // ── lossless at the quantum ────────────────────────────────────────────────

  /// First byte: predictor order (1 or 2); then one zigzag varint residual per
  /// valid slot, in slot order, over the quantized integers round(v / q).
  /// Whichever order deflates smaller wins (ties: 1).
  static Uint8List _losslessPayload(List<double?> s, double q) {
    final ks = <int>[
      for (final v in s)
        if (v != null) (v / q).round()
    ];
    Uint8List build(int order) {
      final w = _W()..byte(order);
      var p1 = 0, p2 = 0;
      for (final k in ks) {
        final pred = order == 1 ? p1 : 2 * p1 - p2;
        w.zigzag(k - pred);
        p2 = p1;
        p1 = k;
      }
      return w.take();
    }

    final a = build(1), b = build(2);
    return _deflate(b).length < _deflate(a).length ? b : a;
  }

  static List<int> _losslessInts(Uint8List blob, _Head h) {
    final r = _R(_inflate(blob, h.coefAt, h.coefLen));
    final n = h.header.nValid;
    final ks = List<int>.filled(n, 0);
    try {
      final order = r.byte();
      if (order != 1 && order != 2) {
        throw const FormatException('spectral: bad predictor');
      }
      var p1 = 0, p2 = 0;
      for (var i = 0; i < n; i++) {
        final pred = order == 1 ? p1 : 2 * p1 - p2;
        final k = pred + r.zigzag();
        ks[i] = k;
        p2 = p1;
        p1 = k;
      }
    } on RangeError {
      throw const FormatException('spectral: truncated samples');
    }
    if (r.hasMore) throw const FormatException('spectral: trailing samples');
    return ks;
  }

  // ── pyramid ────────────────────────────────────────────────────────────────

  static Uint8List _pyramidBytes(List<double?> s, double q) {
    final len = s.length;
    final levels = <List<_Cell?>>[];
    for (final cs in _levelSeconds(len)) {
      final nCells = _cellCount(len, cs);
      final cells = <_Cell?>[];
      for (var ci = 0; ci < nCells; ci++) {
        final from = ci * cs;
        final to = cs == len ? len : math.min(len, from + cs);
        var count = 0;
        var sum = 0.0;
        var lo = double.infinity, hi = double.negativeInfinity;
        for (var i = from; i < to; i++) {
          final v = s[i];
          if (v == null) continue;
          count++;
          sum += v;
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
        if (count == 0) {
          cells.add(null);
          continue;
        }
        final loQ = (lo / q).round(), hiQ = (hi / q).round();
        final meanQ = math.min(hiQ, math.max(loQ, (sum / count / q).round()));
        cells.add(_Cell(count, loQ, meanQ, hiQ));
      }
      levels.add(cells);
    }
    return _writePyramid(levels);
  }

  static Uint8List _writePyramid(List<List<_Cell?>> levels) {
    final w = _W();
    var prevMean = 0;
    for (final cells in levels) {
      for (final c in cells) {
        if (c == null) {
          w.varint(0);
          continue;
        }
        w.varint(c.count);
        w.zigzag(c.meanQ - prevMean);
        prevMean = c.meanQ;
        w.varint(c.meanQ - c.loQ);
        w.varint(c.hiQ - c.meanQ);
      }
    }
    return w.take();
  }

  /// The four pyramid levels rebuilt from the kept 60 s cells alone (quantized
  /// cells in, coarser levels aggregated from them).
  static Uint8List _pyramidFromMinutes(
      List<_Cell?> minutes, int length, double q) {
    _Cell? agg(Iterable<_Cell?> cs) {
      var count = 0;
      var lo = 1 << 62, hi = -(1 << 62);
      var sum = 0.0;
      for (final c in cs) {
        if (c == null) continue;
        count += c.count;
        sum += c.meanQ * c.count;
        if (c.loQ < lo) lo = c.loQ;
        if (c.hiQ > hi) hi = c.hiQ;
      }
      if (count == 0) return null;
      final mean = math.min(hi, math.max(lo, (sum / count).round()));
      return _Cell(count, lo, mean, hi);
    }

    final levels = <List<_Cell?>>[];
    for (final cs in _levelSeconds(length)) {
      final nCells = _cellCount(length, cs);
      if (cs == 60) {
        levels.add([for (var i = 0; i < nCells; i++) i < minutes.length ? minutes[i] : null]);
      } else {
        final per = cs == length ? minutes.length : cs ~/ 60;
        levels.add([
          for (var i = 0; i < nCells; i++)
            agg(minutes.skip(i * per).take(per)),
        ]);
      }
    }
    return _writePyramid(levels);
  }

  // ── carve / merge ──────────────────────────────────────────────────────────

  /// Carve [blob]: keep only the 60 s pyramid cells (cell j = slots
  /// [60j, 60j+60) of the part) for which [keepMinute] is true, as a new blob
  /// of the same mode and quantum. The kept cells keep their TRUE raw
  /// statistics; samples (if the mode has any) are the decoded samples of the
  /// kept cells, re-encoded. A lossless part stays exact; a lossy part is
  /// re-encoded from its own reconstruction, so the result is a second
  /// generation (its error vs the original raw is at most the original's plus
  /// the returned stats' error). Null when nothing is kept.
  static SpectralEncoding? restrict(
      Uint8List blob, bool Function(int minute) keepMinute) {
    final h = _head(blob);
    if (h.header.codecVersion != codecVersion) {
      throw FormatException(
          'spectral: unsupported codec version ${h.header.codecVersion}');
    }
    final head = h.header;
    final q = head.quantum;
    final minute = summary(blob).first.cells;
    final kept = List<bool>.generate(
        minute.length, (j) => minute[j].count > 0 && keepMinute(j));
    if (!kept.any((k) => k)) return null;
    final mode = head.mode;
    final decoded = mode == SpectralMode.pyramidOnly ? null : decode(blob);
    final samples = List<double?>.filled(head.length, null);
    for (final (a, b) in _validRuns(blob, h)) {
      for (var i = a; i < b; i++) {
        if (!kept[i ~/ 60]) continue;
        samples[i] = decoded == null ? 0.0 : decoded[i];
      }
    }
    final cells = <_Cell?>[
      for (var j = 0; j < minute.length; j++)
        if (kept[j])
          _Cell(minute[j].count, (minute[j].min! / q).round(),
              (minute[j].mean! / q).round(), (minute[j].max! / q).round())
        else
          null
    ];
    return _encode(head.signal, samples, mode,
        pyramid: _pyramidFromMinutes(cells, head.length, q));
  }

  /// Merge the pyramids of parts with DISJOINT coverage onto one absolute grid
  /// anchored at the earliest origin. Every origin must sit a whole number of
  /// minutes from it (zone offsets always do). Counts add, min/max are the
  /// extremes, the mean is count-weighted; the 900 s / 3600 s / whole-series
  /// levels are aggregated from the merged 60 s cells, so a part whose own
  /// hour grid was shifted still lands correctly. One part passes through.
  static List<SpectralLevel> mergeSummaries(List<SpectralPartSummary> parts) {
    if (parts.isEmpty) throw ArgumentError('no parts');
    if (parts.length == 1) return parts.single.levels;
    final o0 = parts.map((p) => p.originSec).reduce(math.min);
    var end = o0;
    for (final p in parts) {
      end = math.max(end, p.originSec + p.levels.last.cellSeconds);
      if ((p.originSec - o0) % 60 != 0) {
        throw StateError('spectral: part origins are not minute-aligned');
      }
    }
    final total = end - o0;
    final nMin = (total + 59) ~/ 60;
    final count = List<int>.filled(nMin, 0);
    final lo = List<double>.filled(nMin, double.infinity);
    final hi = List<double>.filled(nMin, double.negativeInfinity);
    final sum = List<double>.filled(nMin, 0);
    for (final p in parts) {
      final base = (p.originSec - o0) ~/ 60;
      final cells = p.levels.first.cells;
      for (var j = 0; j < cells.length; j++) {
        final c = cells[j];
        if (c.count == 0) continue;
        final g = base + j;
        count[g] += c.count;
        sum[g] += c.mean! * c.count;
        lo[g] = math.min(lo[g], c.min!);
        hi[g] = math.max(hi[g], c.max!);
      }
    }
    LodCell cell(Iterable<int> idx) {
      var n = 0;
      var s = 0.0, a = double.infinity, b = double.negativeInfinity;
      for (final g in idx) {
        if (count[g] == 0) continue;
        n += count[g];
        s += sum[g];
        a = math.min(a, lo[g]);
        b = math.max(b, hi[g]);
      }
      return n == 0 ? const LodCell(0, null, null, null) : LodCell(n, a, s / n, b);
    }

    final out = <SpectralLevel>[];
    for (final cs in _levelSeconds(total)) {
      final nCells = _cellCount(total, cs);
      final per = cs == total ? nMin : cs ~/ 60;
      out.add(SpectralLevel(cs, [
        for (var i = 0; i < nCells; i++)
          cell(Iterable<int>.generate(
              math.max(0, math.min(per, nMin - i * per)), (k) => i * per + k)),
      ]));
    }
    return out;
  }
}

// ── private helpers ──────────────────────────────────────────────────────────

/// One quantized pyramid cell (integers in units of the quantum).
class _Cell {
  const _Cell(this.count, this.loQ, this.meanQ, this.hiQ);
  final int count, loQ, meanQ, hiQ;
}

class _Seg {
  _Seg(this.start, this.length, this.idx, this.val);
  final int start, length;
  final List<int> idx, val;
}

class _Head {
  _Head(this.header, this.maskAt, this.maskLen, this.pyrAt, this.pyrLen,
      this.segAt, this.segLen, this.coefAt, this.coefLen);
  final SpectralHeader header;
  final int maskAt, maskLen, pyrAt, pyrLen, segAt, segLen, coefAt, coefLen;
}

class _Parsed {
  _Parsed(this.head, this.segs, this.ints, [this.runs = const []]);
  final _Head head;
  final List<_Seg> segs;

  /// Lossless blobs: the quantized integer of every valid slot, in slot order.
  final List<int>? ints;

  /// Lossless blobs: the valid runs the integers fill.
  final List<(int, int)> runs;
}

/// Per-length trig tables, built once per encode/decode call.
class _Tables {
  final Map<int, Float64List> _cos = {};
  final Map<int, (Float64List, Float64List)> _tw = {};

  /// cos(pi j / 2n) for j in [0, 4n).
  Float64List cos(int n) => _cos.putIfAbsent(n, () {
        final t = Float64List(4 * n);
        for (var j = 0; j < 4 * n; j++) {
          t[j] = math.cos(math.pi * j / (2 * n));
        }
        return t;
      });

  /// cos / sin(2 pi j / n) for j in [0, n).
  (Float64List, Float64List) twiddle(int n) => _tw.putIfAbsent(n, () {
        final c = Float64List(n), s = Float64List(n);
        for (var j = 0; j < n; j++) {
          c[j] = math.cos(2 * math.pi * j / n);
          s[j] = math.sin(2 * math.pi * j / n);
        }
        return (c, s);
      });
}

class _W {
  final BytesBuilder _b = BytesBuilder(copy: false);
  int get length => _b.length;
  void byte(int v) => _b.addByte(v);
  void bytes(List<int> v) => _b.add(v);
  void varint(int v) {
    assert(v >= 0);
    while (v >= 0x80) {
      _b.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _b.addByte(v);
  }

  void zigzag(int v) => varint(v >= 0 ? v << 1 : ((-v) << 1) - 1);
  void f64(double v) {
    final d = ByteData(8)..setFloat64(0, v, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  Uint8List take() => _b.takeBytes();
}

class _R {
  _R(this.data);
  final Uint8List data;
  int pos = 0;
  bool get hasMore => pos < data.length;
  int byte() => data[pos++]; // RangeError on overrun, mapped by callers
  Uint8List take(int n) {
    final v = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return v;
  }

  int varint() {
    var shift = 0, v = 0;
    while (true) {
      final b = data[pos++];
      v |= (b & 0x7f) << shift;
      if (b < 0x80) return v;
      shift += 7;
      if (shift > 56) throw const FormatException('spectral: bad varint');
    }
  }

  int zigzag() {
    final z = varint();
    return (z & 1) == 0 ? z >> 1 : -((z + 1) >> 1);
  }

  double f64() {
    final v = ByteData.sublistView(data, pos, pos + 8).getFloat64(0, Endian.little);
    pos += 8;
    return v;
  }
}
