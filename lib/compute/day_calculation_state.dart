import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

import 'day_activity_state.dart';
import 'day_resume_state.dart';
import 'minute_bills.dart';
import 'state_fingerprint.dart';

/// RAM-only calculation data copied into workers and published after persistence.
/// Callbacks passed to [evaluate] are evaluated synchronously, never retained.
///
/// The state is kept small on purpose: results and running sums stay, but the
/// inputs they came from do not. Cached calculations are matched on a
/// fingerprint of their dependencies ([dependencyFingerprint]) instead of a
/// copy, and the per-second summaries fingerprint the samples they folded in.
class DayCalculationState {
  final CalculationCache _cache = CalculationCache(maxEntries: 2048);
  IncrementalMinuteMetrics _minutes = IncrementalMinuteMetrics();

  /// Minutes the state above already held when it was read back from storage:
  /// not work this process did, so [processedMinutes] leaves them out.
  int _minutesBase = 0;
  // One per isolate half: the pipeline and the activity pass each read the day
  // with their own sleep bounds, so sharing one would rebuild on any mismatch.
  final Map<String, DayHrSummary> _hr = {};
  DayMotionSummary _motion = DayMotionSummary();
  StepCounterFold _steps = StepCounterFold();
  DayDynMinutes _dyn = DayDynMinutes();
  IncrementalEnmoSeries _enmo = IncrementalEnmoSeries();

  /// Valid samples the motion series above holds a copy of.
  int _enmoHeld = 0;

  /// The gravity reference of the last full motion calculation. Periodic awake
  /// passes reuse it; see [motionMinutes].
  double? _gRef;

  /// True when the per-second summaries were seeded from a stored checkpoint
  /// ([seedFrom]). Summaries are always reused only when the samples they
  /// folded are still the ones handed in (a fingerprint decides), so seeding
  /// lets them append in any mode, including a full pass in a fresh process,
  /// which has no earlier pass to carry them over.
  bool _seeded = false;

  /// Starts this (empty) state from a stored checkpoint's folded summaries.
  /// The state takes ownership of [resume]'s parts.
  ///
  /// Its priced minutes come too when the package accepts them; otherwise the
  /// first pass prices the day's minutes again, which gives the same figures.
  void seedFrom(DayResumeState resume) {
    _hr['pipeline'] = resume.hrPipeline;
    _hr['activity'] = resume.hrActivity;
    _motion = resume.motion;
    _steps = resume.steps;
    _dyn = resume.dyn;
    final minutes = resume.bills?.toMetrics();
    if (minutes != null) {
      _minutes = minutes;
      _minutesBase = minutes.processedMinutes;
    }
    _seeded = true;
  }

  /// The wake minutes priced so far, those before epoch minute [beforeMinute],
  /// for the checkpoint; null when there are none to keep.
  MinuteBills? minuteBills({required int beforeMinute}) {
    final json = _minutes.toJson();
    return MinuteBills.fromMetricsJson(json, beforeMinute: beforeMinute);
  }

  bool _forceSummaries(CalculationMode mode) =>
      mode != CalculationMode.periodicAwake && !_seeded;

  int get computations => _cache.computations;
  int get hits => _cache.hits;
  int get processedMinutes => _minutes.processedMinutes - _minutesBase;
  int get processedMotionPoints => _enmo.processedPoints + _dyn.processedSamples;
  int get processedHrSamples =>
      _hr.values.fold(0, (n, h) => n + h.processedSamples);
  int get processedOrientationSamples => _motion.processedSamples;
  int get processedStepSamples => _steps.processedSamples;

  /// Samples of the day held in memory by this state, across every part.
  int get retainedSamples =>
      _hr.values.fold(0, (n, h) => n + h.retainedSamples) +
      _motion.retainedSamples +
      _dyn.retainedSamples +
      _enmoHeld;

  /// Drops the one part that keeps day samples, the motion series. The next
  /// pass rebuilds it from the day it is handed, which gives the same minutes
  /// an appended one does; every other part is already compact.
  void compact() {
    _enmo = IncrementalEnmoSeries();
    _enmoHeld = 0;
  }

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
        dependencyFingerprint(dependencies),
        calculate,
        full: mode != CalculationMode.periodicAwake,
      );
    }
    final before = _cache.hits;
    final watch = Stopwatch()..start();
    final result = _cache.evaluate(
      key,
      dependencyFingerprint(dependencies),
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
    // A state read back from storage trusts the minutes it holds only as far as
    // the sync can prove them (it compares every minute's HR and cadence and
    // the anchors), so it never reprices what has not changed.
    force: _forceSummaries(mode),
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
      force: _forceSummaries(mode),
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
      force: _forceSummaries(mode),
    );
    return _motion;
  });

  /// Per-minute motion over the whole calendar day from the folded per-minute
  /// buckets ([DayDynMinutes]): the day's seconds are folded in once and only
  /// new ones afterwards, in any mode, with no `AccelSample` copy of the day.
  /// Every field the app reads is the batch value (`enmoSeries`); `enmo`, `mad`
  /// and `meanMag` are NaN, not computed.
  List<MotionMinute> dynMinutes(
    List<int> ts,
    List<int> hr,
    List<double> ax,
    List<double> ay,
    List<double> az,
    CalculationMode mode,
  ) => timed('motion_minutes', () {
    _dyn.sync(ts, hr, ax, ay, az, force: _forceSummaries(mode));
    return _dyn.minutes();
  });

  /// The strap's own credited steps for the day (see [StepCounterFold]); null
  /// when the strap has no counter. Same figure `hardwareStepsFromCounter`
  /// gives over the same seconds.
  int? bandSteps(
    List<int> ts,
    List<int> counter, {
    required int? modulus,
    required CalculationMode mode,
  }) => timed('step_fold', () {
    _steps.sync(ts, counter, modulus: modulus, force: _forceSummaries(mode));
    return _steps.steps;
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
    final result =
        _enmo.sync(samples, gRef: g, expectedMinutes: 1440, force: full);
    _enmoHeld = samples.where((s) => s.valid).length;
    return result.minutes;
  });
}
