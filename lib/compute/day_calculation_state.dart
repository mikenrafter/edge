import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

import 'day_activity_state.dart';

/// RAM-only calculation data copied into workers and published after persistence.
/// Callbacks passed to [evaluate] are evaluated synchronously, never retained.
class DayCalculationState {
  final CalculationCache _cache = CalculationCache(maxEntries: 2048);
  final IncrementalMinuteMetrics _minutes = IncrementalMinuteMetrics();
  // One per isolate half: the pipeline and the activity pass each read the day
  // with their own sleep bounds, so sharing one would rebuild on any mismatch.
  final Map<String, DayHrSummary> _hr = {};
  final DayMotionSummary _motion = DayMotionSummary();
  final IncrementalEnmoSeries _enmo = IncrementalEnmoSeries();

  /// The gravity reference of the last full motion calculation. Periodic awake
  /// passes reuse it; see [motionMinutes].
  double? _gRef;

  int get computations => _cache.computations;
  int get hits => _cache.hits;
  int get processedMinutes => _minutes.processedMinutes;
  int get processedMotionPoints => _enmo.processedPoints;
  int get processedHrSamples =>
      _hr.values.fold(0, (n, h) => n + h.processedSamples);
  int get processedOrientationSamples => _motion.processedSamples;

  /// Per-key reuse and cost, collected only when [debugStats] is set (for the
  /// cache benchmark). Keys of per-window entries are collapsed to their prefix.
  Map<String, ({int hits, int misses, int micros})>? debugStats;

  T evaluate<T>(
    String key,
    Object? dependencies,
    T Function() calculate,
    CalculationMode mode,
  ) {
    final stats = debugStats;
    if (stats == null) {
      return _cache.evaluate(
        key,
        dependencies,
        calculate,
        full: mode != CalculationMode.periodicAwake,
      );
    }
    final before = _cache.hits;
    final watch = Stopwatch()..start();
    final result = _cache.evaluate(
      key,
      dependencies,
      calculate,
      full: mode != CalculationMode.periodicAwake,
    );
    final name = key.replaceFirst(RegExp(r'_-?[\d.]+$'), '_*');
    final hit = _cache.hits > before;
    final old = stats[name] ?? (hits: 0, misses: 0, micros: 0);
    stats[name] = (
      hits: old.hits + (hit ? 1 : 0),
      misses: old.misses + (hit ? 0 : 1),
      micros: old.micros + watch.elapsedMicroseconds,
    );
    return result;
  }

  MinuteMetrics minutes(
    List<int> keys,
    List<double> hr, {
    List<double?>? cadence,
    double? restingHr,
    double? maxHr,
    required Sex sex,
    WorkoutUserProfile? profile,
    int dayMinutes = 1440,
    required CalculationMode mode,
  }) => _minutes.sync(
    keys,
    hr,
    cadenceSpm: cadence,
    restingHr: restingHr,
    maxHr: maxHr,
    sex: sex,
    profile: profile,
    dayMinutes: dayMinutes,
    quietHrr: quietWakingHrr,
    force: mode != CalculationMode.periodicAwake,
    includeMinuteSeries: false,
  );

  /// Times [calculate] under [name] in [debugStats], when collecting.
  T timed<T>(String name, T Function() calculate) {
    final stats = debugStats;
    if (stats == null) return calculate();
    final watch = Stopwatch()..start();
    final result = calculate();
    final old = stats[name] ?? (hits: 0, misses: 0, micros: 0);
    stats[name] = (
      hits: old.hits,
      misses: old.misses + 1,
      micros: old.micros + watch.elapsedMicroseconds,
    );
    return result;
  }

  /// The day's heart-rate summary for [slot], brought up to date with
  /// [ts]/[hr].
  DayHrSummary hrSummary(
    String slot,
    List<int> ts,
    List<int> hr, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required int? age,
    required CalculationMode mode,
  }) => timed('hr_summary_$slot', () {
    final summary = _hr[slot] ??= DayHrSummary();
    summary.sync(
      ts,
      hr,
      sleepOnsetSec: sleepOnsetSec,
      sleepOffsetSec: sleepOffsetSec,
      age: age,
      force: mode != CalculationMode.periodicAwake,
    );
    return summary;
  });

  /// The day's orientation/presence summary, brought up to date.
  DayMotionSummary motionSummary(
    List<int> ts,
    List<double> ax,
    List<double> ay,
    List<double> az, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required CalculationMode mode,
  }) => timed('motion_summary', () {
    _motion.sync(
      ts,
      ax,
      ay,
      az,
      sleepOnsetSec: sleepOnsetSec,
      sleepOffsetSec: sleepOffsetSec,
      force: mode != CalculationMode.periodicAwake,
    );
    return _motion;
  });

  /// Per-minute motion over the whole calendar day (`expectedMinutes` 1440).
  ///
  /// A full mode calibrates the gravity reference exactly as
  /// `enmoSeries(samples)` does, so its result is the batch result. A periodic
  /// awake pass keeps the last full pass's reference and appends: every field
  /// except [MotionMinute.enmo] is still the batch value (they do not depend on
  /// the reference), and `enmo` is the batch value at that reference. Nothing
  /// in the app reads `enmo`. With no earlier full pass, awake runs as full.
  List<MotionMinute> motionMinutes(
    List<AccelSample> samples,
    CalculationMode mode,
  ) => timed('motion_minutes', () {
    final full = mode != CalculationMode.periodicAwake || _gRef == null;
    var g = _gRef;
    if (full) {
      final valid = samples.where((s) => s.valid).toList()
        ..sort((a, b) => a.tsMs.compareTo(b.tsMs));
      if (valid.isEmpty) return const <MotionMinute>[];
      g = calibrateGRef([
        for (final s in valid) math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z),
      ]);
      _gRef = g;
    }
    return _enmo
        .sync(samples, gRef: g, expectedMinutes: 1440, force: full)
        .minutes;
  });
}
