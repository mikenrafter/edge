// How still the wrist was, second by second, from live accelerometer samples.
//
// PROTOTYPE, RED STUB: the behaviour is not written yet; every method throws
// UnimplementedError. The doc comments are the contract the tests pin.
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

  /// One accelerometer sample [x], [y], [z] in g at session time [t].
  /// Ignored when [t] is negative, when any component is not finite, or when
  /// the second it belongs to has already been dropped. Order does not matter.
  void add(Duration t, double x, double y, double z) {
    throw UnimplementedError('StillnessMeter.add');
  }

  /// Share of the whole seconds in [from]..[to) (a second counts when it lies
  /// fully inside; [to] is exclusive) that were still, over the KNOWN seconds
  /// only. Null when the span has no whole second, or when fewer than
  /// [kMinKnownShare] of its seconds are known.
  double? stillFraction(Duration from, Duration to) =>
      throw UnimplementedError('StillnessMeter.stillFraction');

  /// How many per-second summaries are held (never raw samples).
  int get summaryCount =>
      throw UnimplementedError('StillnessMeter.summaryCount');
}
