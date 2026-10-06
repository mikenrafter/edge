// natural_wake.dart — Natural Wake's decision and its off-UI-isolate observer.
//
// Natural Wake tries to send ONE early haptic while the sleeper is NOT in light
// or deep sleep (estimated REM, or awake), inside the window [T-N, T) before
// the must-be-up-by time T, and otherwise abstains with a named reason. It can only ever add an early buzz: the fixed native band
// alarm at T is untouched by anything in this file.
//
// Two halves, kept apart on purpose:
//   * [NaturalWakePlanner] — PURE. Given an observation and the situation, say
//     fire or abstain, and why. No clock, no I/O, no state.
//   * [IsolateNaturalStageObserver] — runs analytics' causal stager
//     (`CausalStager.observe`) inside `Isolate.run`. The stager is pure and
//     deterministic, so there is no ambient global to re-arm in the closure;
//     the request is plain data and the answer is plain data. This is the ONLY
//     place in lib/ that calls the causal stager (a source-guard test holds it
//     there), so inference can never land on the UI isolate by accident.
//
// What the trigger means. The stager reports the stage of the newest closed
// 30 s epoch, trailing, so it lags real REM onset by about two minutes, and
// `runSec` is how long that stage has held. The stager has three real stages:
// wake, nrem (light and deep together, it cannot tell them apart) and rem. The
// owner's rule is "wake early as long as they are NOT in light or deep sleep",
// so REM and wake both qualify and nrem never does; absent (no data, an
// abstention) is never a stage and never qualifies.
//
// The rule first validated on one recorded night was `stage == rem &&
// runSec >= 120`: 11 of 16 REM bouts caught, a median 1.5 min late, and it
// fired in 38% of 15-minute windows, 56% of 30-minute and 80% of 60-minute
// ones. That figure is for REM alone; admitting wake only adds firing
// opportunities and is not separately validated. It is an estimate from one
// night, not polysomnography, and the UI must not present it as sleep staging.
//
// A second, independent way to be awake: the user is actively using the app
// (a touch in the foreground) AND the band shows movement that correlates in
// time with that touch. Either signal alone never counts. See
// [NaturalWakePlanner.userAwakeFromInteraction].

import 'dart:isolate';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

import '../state/control_operations.dart' show ExpectedSleepSchedule;

// ── constants ───────────────────────────────────────────────────────────────

/// The stage (REM, or awake) must have held this long (seconds) before the
/// haptic may fire. The validated default for REM; the causal stager does not
/// bridge a wake the way the offline one does, so wake is held to the same bar.
const int kNaturalRemTriggerRunSec = 120;

/// Stager stages that may trigger the early haptic: anything that is not light
/// or deep sleep. `nrem` and `absent` are deliberately missing.
const Set<String> kNaturalEligibleStages = {'rem', 'wake'};

/// A touch older than this no longer says anything about now.
const Duration kUserInteractionFreshness = Duration(minutes: 5);

/// Band motion counts when it falls within this of the touch, either side.
const Duration kUserMotionHalfWindow = Duration(seconds: 45);

/// A 1 Hz step in the gravity vector (g) that counts as the wrist moving. A
/// still wrist, on a nightstand or asleep, steps by about 0.005 g. CALIBRATION
/// KNOB, not validated against labelled data.
const double kUserMotionStepG = 0.05;

/// Moving steps needed inside the window for the touch to correlate.
const int kUserMotionMinSteps = 3;

/// Evidence-quality floor. The stager's confidence is bounded to [0.15, 0.6];
/// it is NOT a probability of being right. Not calibrated against outcomes
/// yet (the validation rule had no confidence term) — conservative on purpose.
const double kNaturalMinConfidence = 0.3;

/// Evidence older than this (ms) is stale. The stager abstains on its own at
/// 120 s with nothing received; the newest closed epoch is itself up to 30 s
/// behind, hence the slack.
const int kNaturalMaxEvidenceAgeMs = 150000;

/// A tick the OS ran later than it promised, beyond this, does not fire.
const Duration kNaturalMaxTickLateness = Duration(minutes: 3);

/// A sleep must span at least this to count as the main sleep.
const Duration kMainSleepMinSpan = Duration(hours: 4);

/// The alarm must fall within this of the configured main-sleep wake time.
const Duration kMainSleepWakeTolerance = Duration(hours: 3);

// ── observation ─────────────────────────────────────────────────────────────

/// The stager's answer as plain data (crosses the isolate boundary).
class NaturalObservation {
  const NaturalObservation({
    required this.stage,
    required this.confidence,
    required this.evidenceAgeMs,
    required this.abstention,
    required this.runSec,
    required this.epochStartMs,
    required this.note,
  });

  /// wake | nrem | rem | absent
  final String stage;
  final double confidence;
  final double? evidenceAgeMs;

  /// The analytics abstention name when [stage] is absent.
  final String? abstention;
  final double runSec;
  final double? epochStartMs;
  final String? note;

  factory NaturalObservation.fromStager(CausalStageObservation o) =>
      NaturalObservation(
        stage: o.stage.name,
        confidence: o.confidence,
        evidenceAgeMs: o.evidenceAgeMs,
        abstention: o.abstentionReason?.name,
        runSec: o.runSec,
        epochStartMs: o.epochStartMs,
        note: o.note,
      );

  Map<String, Object?> toJson() => {
        'stage': stage,
        'confidence': confidence,
        'evidenceAgeMs': evidenceAgeMs,
        'abstention': abstention,
        'runSec': runSec,
        'epochStartMs': epochStartMs,
        'note': note,
      };
}

// ── decision ────────────────────────────────────────────────────────────────

enum SleepEligibility { mainSleep, nap, unknown }

/// Why a Natural Wake tick did or did not fire. Stored by name in the trace.
enum NaturalReason {
  fire,
  off,
  upgradePending,
  beforeWindow,
  windowClosed,
  ineligibleNap,
  ineligibleUnknown,
  acknowledged,
  alreadyFired,
  disconnected,
  lateExecution,
  observerFailed,
  samplesUnavailable,
  abstained,
  offWrist,
  missingHr,
  missingAccel,
  lowCoverage,
  warmup,
  noEvidence,
  clockRegressed,
  samplesStale,
  noRemCandidate,
  remNotStable,
  lowConfidence,
}

class NaturalDecisionInput {
  const NaturalDecisionInput({
    required this.now,
    required this.wakeAt,
    required this.windowMinutes,
    required this.eligibility,
    required this.observation,
    required this.connected,
    required this.alreadyFired,
    required this.acknowledged,
    required this.lateness,
    this.userActive = false,
  });

  final DateTime now;
  final DateTime wakeAt;
  final int windowMinutes;
  final SleepEligibility eligibility;
  final NaturalObservation? observation;
  final bool connected;
  final bool alreadyFired;
  final bool acknowledged;

  /// How much later than scheduled this tick actually ran (zero if unknown or
  /// on time).
  final Duration lateness;

  /// The user is using the app now AND the band moved with it (see
  /// [NaturalWakePlanner.userAwakeFromInteraction]). Counts as awake.
  final bool userActive;
}

class NaturalDecision {
  const NaturalDecision(this.reason,
      {this.samplesCurrent, this.viaUserActivity = false});
  final NaturalReason reason;

  /// The fire came from the user's own activity, not from a stage.
  final bool viaUserActivity;

  /// Whether the evidence behind the observation is fresh; null when there is
  /// no observation to judge.
  final bool? samplesCurrent;
  bool get fire => reason == NaturalReason.fire;
}

abstract final class NaturalWakePlanner {
  /// T-N as an absolute instant: N ELAPSED minutes before T (a window that
  /// spans a DST change is still N real minutes).
  static DateTime windowStart(DateTime wakeAt, int windowMinutes) =>
      wakeAt.subtract(Duration(minutes: windowMinutes));

  /// Whether the alarm at [wakeAt] is the configured main sleep. Naps are
  /// ineligible. Never guesses: with neither a configured schedule nor a known
  /// onset the answer is [SleepEligibility.unknown].
  ///
  /// The alarm must fall near the configured wake time (the schedule is local
  /// wall-clock, so this follows the zone the alarm was armed in), and the
  /// sleep behind it must span at least [kMainSleepMinSpan].
  static SleepEligibility classify({
    required DateTime wakeAt,
    ExpectedSleepSchedule? expected,
    DateTime? sleepOnset,
  }) {
    if (expected == null && sleepOnset == null) return SleepEligibility.unknown;
    var onset = sleepOnset;
    if (expected != null) {
      final local = wakeAt.toLocal();
      (DateTime, DateTime)? nearest;
      for (final d in [-1, 0, 1]) {
        final w = expected.windowFor(DateTime(local.year, local.month, local.day + d));
        if (nearest == null ||
            wakeAt.difference(w.$2).abs() < wakeAt.difference(nearest.$2).abs()) {
          nearest = w;
        }
      }
      if (wakeAt.difference(nearest!.$2).abs() > kMainSleepWakeTolerance) {
        return SleepEligibility.nap;
      }
      onset ??= nearest.$1;
    }
    return wakeAt.difference(onset!) >= kMainSleepMinSpan
        ? SleepEligibility.mainSleep
        : SleepEligibility.nap;
  }

  static NaturalDecision decide(NaturalDecisionInput i) {
    NaturalDecision no(NaturalReason r, {bool? current}) =>
        NaturalDecision(r, samplesCurrent: current);

    if (i.windowMinutes <= 0) return no(NaturalReason.off);
    if (!i.now.isBefore(i.wakeAt)) return no(NaturalReason.windowClosed);
    if (i.now.isBefore(windowStart(i.wakeAt, i.windowMinutes))) {
      return no(NaturalReason.beforeWindow);
    }
    if (i.eligibility == SleepEligibility.nap) {
      return no(NaturalReason.ineligibleNap);
    }
    if (i.eligibility == SleepEligibility.unknown) {
      return no(NaturalReason.ineligibleUnknown);
    }
    if (i.acknowledged) return no(NaturalReason.acknowledged);
    if (i.alreadyFired) return no(NaturalReason.alreadyFired);
    // The haptic is live-only (phone -> band). Without a link there is nothing
    // to send, and the stager's inputs are not arriving either.
    if (!i.connected) return no(NaturalReason.disconnected);
    if (i.lateness > kNaturalMaxTickLateness) {
      return no(NaturalReason.lateExecution);
    }
    // Awake because they are using the phone and the wrist moved with it. This
    // needs no stage, so an observer that abstained or failed cannot hide it.
    if (i.userActive) {
      return const NaturalDecision(NaturalReason.fire, viaUserActivity: true);
    }
    final o = i.observation;
    if (o == null) return no(NaturalReason.observerFailed);

    final age = o.evidenceAgeMs;
    final current = o.abstention != 'staleEvidence' &&
        o.abstention != 'noEvidence' &&
        age != null &&
        age <= kNaturalMaxEvidenceAgeMs;

    if (o.stage == 'absent') {
      return no(
        switch (o.abstention) {
          'staleEvidence' => NaturalReason.samplesStale,
          'noEvidence' => NaturalReason.noEvidence,
          'offWrist' => NaturalReason.offWrist,
          'missingHr' => NaturalReason.missingHr,
          'missingAccel' => NaturalReason.missingAccel,
          'lowCoverage' => NaturalReason.lowCoverage,
          'warmup' => NaturalReason.warmup,
          'clockRegressed' => NaturalReason.clockRegressed,
          _ => NaturalReason.abstained,
        },
        current: current,
      );
    }
    if (!current) return no(NaturalReason.samplesStale, current: false);
    // Light or deep sleep (the stager's nrem) is the only thing that holds the
    // haptic back; REM and awake both qualify. (The enum value keeps its old
    // name: stored traces carry it.)
    if (!kNaturalEligibleStages.contains(o.stage)) {
      return no(NaturalReason.noRemCandidate, current: true);
    }
    if (o.runSec < kNaturalRemTriggerRunSec) {
      return no(NaturalReason.remNotStable, current: true);
    }
    if (o.confidence < kNaturalMinConfidence) {
      return no(NaturalReason.lowConfidence, current: true);
    }
    return const NaturalDecision(NaturalReason.fire, samplesCurrent: true);
  }

  /// Whether the user is awake because they are actively using the app AND the
  /// band moved at the same time. BOTH are required:
  ///   * a touch alone proves nothing (the phone may sit on a nightstand with
  ///     the screen on) and
  ///   * band motion alone is the stager's business, not this function's.
  ///
  /// [interactions] are instants of a touch in the foreground app; [accel] is
  /// the band's 1 Hz accelerometer rows `[tsMs, x, y, z]` (g) around them. A
  /// touch counts when, within [kUserMotionHalfWindow] either side of it, at
  /// least [kUserMotionMinSteps] consecutive-second steps of the gravity vector
  /// reach [kUserMotionStepG]. A touch older than [kUserInteractionFreshness]
  /// is ignored. No accel rows (none stored yet, a null axis) means no
  /// inference: the answer is false, never a guess.
  static bool userAwakeFromInteraction({
    required DateTime now,
    required Iterable<DateTime> interactions,
    required List<List<double>> accel,
  }) {
    if (accel.length < 2) return false;
    final rows = [...accel]..sort((a, b) => a[0].compareTo(b[0]));
    final half = kUserMotionHalfWindow.inMilliseconds;
    for (final t in interactions) {
      if (t.isAfter(now) || now.difference(t) > kUserInteractionFreshness) continue;
      final at = t.millisecondsSinceEpoch;
      var steps = 0;
      for (var k = 1; k < rows.length; k++) {
        final a = rows[k - 1], b = rows[k];
        if (b[0] < at - half || b[0] > at + half) continue;
        if (b[0] - a[0] > 2000) continue; // a gap is not a step
        final dx = b[1] - a[1], dy = b[2] - a[2], dz = b[3] - a[3];
        if (math.sqrt(dx * dx + dy * dy + dz * dz) >= kUserMotionStepG) steps++;
      }
      if (steps >= kUserMotionMinSteps) return true;
    }
    return false;
  }
}

// ── observer (off the UI isolate) ───────────────────────────────────────────

/// Plain-data input to one observation. Columns:
///   hr [tsMs, bpm]   accel [tsMs, x, y, z]   rr [tsMs, rrMs]
/// Timestamps are absolute epoch ms. [priorState] is the previous result's
/// `nextState` (null at the start of a night).
class NaturalObserveRequest {
  const NaturalObserveRequest({
    required this.nowMs,
    required this.hr,
    required this.accel,
    required this.rr,
    this.priorState,
    this.chunkSec = 600,
  });

  final double nowMs;
  final List<List<double>> hr;
  final List<List<double>> accel;
  final List<List<double>> rr;
  final Map<String, Object?>? priorState;

  /// A long catch-up (after a restart or a gap) is fed in slices this long so
  /// the stager sees the incremental windows it is designed for.
  final int chunkSec;
}

class NaturalObserveResult {
  const NaturalObserveResult({required this.observation, required this.nextState});
  final NaturalObservation observation;

  /// JSON-ready `CausalStagerState`; pass back as the next `priorState`.
  final Map<String, Object?> nextState;
}

abstract interface class NaturalStageObserver {
  Future<NaturalObserveResult> observe(NaturalObserveRequest request);
}

/// Runs [observeNaturalSync] in a short-lived isolate.
class IsolateNaturalStageObserver implements NaturalStageObserver {
  const IsolateNaturalStageObserver();

  @override
  Future<NaturalObserveResult> observe(NaturalObserveRequest request) =>
      Isolate.run(() => observeNaturalSync(request));
}

/// The pure body of an observation. Public so tests can compare it with the
/// isolate's answer; production reaches it only through
/// [IsolateNaturalStageObserver].
NaturalObserveResult observeNaturalSync(NaturalObserveRequest r) {
  // A state this analytics version did not write reads as null: start fresh
  // (costs a warm-up) rather than trust a guess.
  var state = CausalStagerState.fromJson(r.priorState);

  final hr = [for (final s in r.hr) HrSample(s[0], s[1])]
    ..sort((a, b) => a.tsMs.compareTo(b.tsMs));
  final accel = [
    for (final s in r.accel) AccelSample(s[0], s[1], s[2], s[3]),
  ]..sort((a, b) => a.tsMs.compareTo(b.tsMs));
  final rrOrder = [for (var i = 0; i < r.rr.length; i++) i]
    ..sort((a, b) => r.rr[a][0].compareTo(r.rr[b][0]));
  final rrTs = [for (final i in rrOrder) r.rr[i][0]];
  final rrMs = [for (final i in rrOrder) r.rr[i][1]];

  double? first;
  void lowest(double? t) {
    if (t != null && (first == null || t < first!)) first = t;
  }

  lowest(hr.isEmpty ? null : hr.first.tsMs);
  lowest(accel.isEmpty ? null : accel.first.tsMs);
  lowest(rrTs.isEmpty ? null : rrTs.first);

  final chunkMs = r.chunkSec * 1000.0;
  var from = first ?? r.nowMs;
  var ih = 0, ia = 0, ir = 0;
  CausalStageObservation? last;
  while (true) {
    var end = math.min(from + chunkMs, r.nowMs);
    final floor = state?.lastNowMs;
    if (floor != null && end < floor) end = math.min(floor, r.nowMs);
    final isLast = end >= r.nowMs;
    final h = <HrSample>[];
    while (ih < hr.length && (isLast || hr[ih].tsMs < end)) {
      h.add(hr[ih++]);
    }
    final a = <AccelSample>[];
    while (ia < accel.length && (isLast || accel[ia].tsMs < end)) {
      a.add(accel[ia++]);
    }
    final tsSlice = <double>[], msSlice = <double>[];
    while (ir < rrTs.length && (isLast || rrTs[ir] < end)) {
      tsSlice.add(rrTs[ir]);
      msSlice.add(rrMs[ir]);
      ir++;
    }
    last = CausalStager.observe(
      CausalSampleWindow(
        nowMs: end,
        hr: h,
        accel: a,
        rr: RrSeries(tsSlice, msSlice),
      ),
      state,
    );
    state = last.nextState;
    if (isLast) break;
    from = end;
  }
  return NaturalObserveResult(
    observation: NaturalObservation.fromStager(last),
    nextState: Map<String, Object?>.from(state.toJson()),
  );
}
