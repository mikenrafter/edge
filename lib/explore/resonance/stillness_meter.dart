// How still the wrist was, second by second, from live accelerometer samples.
//
// PROTOTYPE. This is a metric, so like the rest of lib/explore/resonance it
// moves to the analytics repo before any merge to edge (AGENTS.md section 1).
//
// Input is acceleration in g (1 LSB = 1/4096 g on both band families; the
// IMU packet adapter already hands samples over in g). Time is session-relative
// (the same clock as `ResonanceSweepPlan`).
//
// A second is "still" when the standard deviation of the acceleration
// MAGNITUDE inside that second is below [kStillSdG]. Magnitude, not per-axis:
// a slow change of wrist orientation moves gravity between the axes but not
// the magnitude, so it does not make a second "moving". Only samples that
// arrive count. A second with fewer than [kMinSamplesPerSecond] samples is
// unknown, never still.
//
// RAM only (AGENTS.md 3.14): only a per-second summary is kept, never the raw
// samples, and the number of summaries is capped.
import 'dart:math' as math;

/// Proposed engineering gate, not a published threshold: a second is still
/// when the SD of the acceleration magnitude is below 0.02 g (20 mg). A band
/// at rest reads well under 5 mg (1 LSB is 0.24 mg); fidgeting and arm
/// movement read from tens of mg upward.
const double kStillSdG = 0.02;

/// Proposed engineering gate: samples a second needs to be judged at all.
/// The live stream is nominally 100 Hz; half of that tolerates a lost packet
/// edge but not a hole.
const int kMinSamplesPerSecond = 50;

/// Proposed engineering gate: share of the asked span whose seconds must be
/// known before any fraction is given.
const double kMinKnownShare = 0.8;

class StillnessMeter {
  /// [maxSeconds] caps how many per-second summaries are kept; the oldest
  /// seconds are dropped first and then read as unknown.
  StillnessMeter({this.maxSeconds = 1800});

  final int maxSeconds;

  // Second index -> running summary (Welford: count, mean, sum of squared
  // deviations of the magnitude). Never the samples themselves.
  final Map<int, _Second> _seconds = {};

  // Seconds at or below this index have been dropped; samples for them are
  // refused so an old second cannot reappear half-filled.
  int _droppedThrough = -1;

  /// One accelerometer sample [x], [y], [z] in g at session time [t].
  /// Ignored when [t] is negative, when any component is not finite, or when
  /// the second it belongs to has already been dropped. Order does not matter.
  void add(Duration t, double x, double y, double z) {
    if (t.isNegative) return;
    final magnitude = math.sqrt(x * x + y * y + z * z);
    if (!magnitude.isFinite) return;
    final second = t.inMicroseconds ~/ Duration.microsecondsPerSecond;
    if (second <= _droppedThrough) return;
    _seconds.putIfAbsent(second, _Second.new).add(magnitude);
    if (_seconds.length > maxSeconds) _dropOldest();
  }

  void _dropOldest() {
    // Out-of-order arrival can leave the oldest key anywhere in the map, so
    // find it; the map never holds more than maxSeconds + 1 entries.
    while (_seconds.length > maxSeconds) {
      final oldest = _seconds.keys.reduce((a, b) => a < b ? a : b);
      _seconds.remove(oldest);
      if (oldest > _droppedThrough) _droppedThrough = oldest;
    }
  }

  /// Share of the whole seconds in [from]..[to) (a second counts when it lies
  /// fully inside; [to] is exclusive) that were still, over the KNOWN seconds
  /// only. Null when the span has no whole second, or when fewer than
  /// [kMinKnownShare] of its seconds are known.
  double? stillFraction(Duration from, Duration to) {
    const micros = Duration.microsecondsPerSecond;
    final first = (from.inMicroseconds + micros - 1) ~/ micros; // ceil
    final end = to.inMicroseconds ~/ micros; // floor, exclusive
    final span = end - first;
    if (first < 0 || span <= 0) return null;
    var known = 0;
    var still = 0;
    for (var s = first; s < end; s++) {
      final summary = _seconds[s];
      if (summary == null || summary.count < kMinSamplesPerSecond) continue;
      known++;
      if (summary.sd < kStillSdG) still++;
    }
    if (known == 0 || known < kMinKnownShare * span) return null;
    return still / known;
  }

  /// How many per-second summaries are held (never raw samples).
  int get summaryCount => _seconds.length;
}

class _Second {
  int count = 0;
  double _mean = 0;
  double _m2 = 0;

  void add(double value) {
    count++;
    final delta = value - _mean;
    _mean += delta / count;
    _m2 += delta * (value - _mean);
  }

  /// Population standard deviation of the magnitude in this second.
  double get sd => count == 0 ? 0 : math.sqrt(_m2 / count);
}
