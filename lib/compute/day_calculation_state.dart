import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

import 'day_activity_state.dart';
import 'day_resume_state.dart';
import 'minute_bills.dart';
import 'state_fingerprint.dart';

typedef NightRr = ({
  List<double> nn,
  List<double> nnTimesMs,
  double cleanFraction,
  int droppedCount,
  int correctedCount,
});

/// The night's corrected RR in one batch call (what [DayCalculationState.nightRr]
/// reproduces incrementally).
NightRr nightRrBatch(List<double> rrMs, List<double> rrTsMs) {
  final r = correctRr(rrMs, rrTsMs: rrTsMs);
  return (
    nn: r.nn,
    nnTimesMs: r.nnTimesMs,
    cleanFraction: r.cleanFraction,
    droppedCount: r.droppedCount,
    correctedCount: r.correctedCount,
  );
}

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

  // ── Night RR correction, streamed ──────────────────────────────────────────
  // RAM-only like the rest of this state (not in DayResumeState): the night
  // slice depends on the sleep window, which a checkpoint does not hold.
  RrCorrector? _nightCorrector;

  /// The beats (and their timestamps) the corrector above has folded, kept to
  /// prove the next slice extends them; compared bit for bit.
  final List<double> _nightRr = [], _nightTs = [];

  /// Final output of the folded beats, in order. The corrector hands each part
  /// out once, so it is kept here.
  final List<double> _nightNn = [], _nightNnTimes = [];
  int _nightProcessed = 0, _nightRebuilds = 0;

  /// Beats pushed through a corrector so far (a rebuild counts its whole slice).
  int get processedNightBeats => _nightProcessed;

  /// Times a corrector was started from scratch, the first included.
  int get nightRebuilds => _nightRebuilds;

  void _resetNight() {
    _nightCorrector = null;
    _nightRr.clear();
    _nightTs.clear();
    _nightNn.clear();
    _nightNnTimes.clear();
  }

  /// The corrected night for this slice: `correctRr(rrMs, rrTsMs: rrTsMs)`, bit
  /// for bit, folding only the beats past those already folded. A slice that
  /// does not extend them (moved start, any earlier beat or timestamp changed,
  /// shorter, empty) starts over.
  NightRr nightRr(List<double> rrMs, List<double> rrTsMs) {
    NightRr batch() => nightRrBatch(rrMs, rrTsMs);

    final n = rrMs.length;
    var held = _nightRr.length;
    var extends_ = n >= held && rrTsMs.length == n;
    for (var i = 0; extends_ && i < held; i++) {
      extends_ = identical(rrMs[i], _nightRr[i]) &&
          identical(rrTsMs[i], _nightTs[i]);
    }
    if (!extends_) {
      // A non-empty slice counts below, as the fresh corrector it gets.
      if (n == 0 && _nightCorrector != null) _nightRebuilds++;
      _resetNight();
      held = 0;
    }
    if (n == 0 || rrTsMs.length != n) return batch();
    final fresh = _nightCorrector == null;
    final corrector = _nightCorrector ??= RrCorrector();
    if (fresh) _nightRebuilds++;
    if (n > held) {
      final addRr = held == 0 ? rrMs : rrMs.sublist(held);
      final addTs = held == 0 ? rrTsMs : rrTsMs.sublist(held);
      final RrSettled settled;
      try {
        settled = corrector.fold(addRr, tsMs: addTs);
      } on ArgumentError {
        // A non-finite beat: the corrector refuses it before changing anything,
        // but this state no longer matches it. Let the batch path decide.
        _resetNight();
        return batch();
      }
      _nightProcessed += addRr.length;
      _nightRr.addAll(addRr);
      _nightTs.addAll(addTs);
      _nightNn.addAll(settled.nn);
      _nightNnTimes.addAll(settled.nnTimes);
    }
    final snap = corrector.snapshot();
    return (
      nn: [..._nightNn, ...snap.tailNn],
      nnTimesMs: [..._nightNnTimes, ...snap.tailNnTimes],
      cleanFraction: snap.cleanFraction,
      droppedCount: snap.droppedCount,
      correctedCount: snap.correctedCount,
    );
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
