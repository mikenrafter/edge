// Shared fakes for the Natural Wake / Gradual Wake tests. Nothing here touches
// BLE, SQLite or an isolate: the orchestrator is driven through its injected
// seams (WakeEnv, NaturalStageObserver, WakeStateStore, WakeTraceStore).

import 'package:openstrap_edge/state/control_operations.dart'
    show ExpectedSleepSchedule;
import 'package:openstrap_edge/wake/natural_wake.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

/// A mutable clock the orchestrator reads.
class TestClock {
  TestClock(this.now);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
  void at(DateTime d) => now = d;
}

NaturalObservation remObs({
  double runSec = 150,
  double confidence = 0.5,
  double evidenceAgeMs = 30000,
}) =>
    NaturalObservation(
      stage: 'rem',
      confidence: confidence,
      evidenceAgeMs: evidenceAgeMs,
      abstention: null,
      runSec: runSec,
      epochStartMs: 1.0,
      note: null,
    );

NaturalObservation stageObs(String stage,
        {double runSec = 600, double confidence = 0.5}) =>
    NaturalObservation(
      stage: stage,
      confidence: confidence,
      evidenceAgeMs: 30000,
      abstention: null,
      runSec: runSec,
      epochStartMs: 1.0,
      note: null,
    );

NaturalObservation absentObs(String reason, {double? evidenceAgeMs = 30000}) =>
    NaturalObservation(
      stage: 'absent',
      confidence: 0,
      evidenceAgeMs: evidenceAgeMs,
      abstention: reason,
      runSec: 0,
      epochStartMs: null,
      note: null,
    );

/// Returns whatever [next] holds, records every request, and can be told to
/// fail. Its `nextState` embeds the call number so tests can prove the prior
/// state really round-trips through the state store.
class ScriptedObserver implements NaturalStageObserver {
  NaturalObservation next = remObs();
  Object? failWith;
  final List<NaturalObserveRequest> requests = [];

  /// Runs inside [observe], so a test can hold a tick mid-flight.
  Future<void> Function()? onObserve;

  @override
  Future<NaturalObserveResult> observe(NaturalObserveRequest r) async {
    requests.add(r);
    await onObserve?.call();
    if (failWith != null) throw failWith!;
    return NaturalObserveResult(
      observation: next,
      nextState: {'v': 1, 'calls': requests.length},
    );
  }
}

class FakeWakeEnv implements WakeEnv {
  @override
  bool connected = true;

  /// Foreground touches the app reports (oldest first).
  @override
  List<DateTime> recentInteractions = [];

  /// The epoch (unix s) the fake band currently holds, or null.
  int? armedEpochSec;
  bool confirmed = true;
  bool armSucceeds = true;
  bool cancelResult = true;
  bool cancelThrows = false;

  final List<int> armCalls = [];
  final List<int> cancelCalls = [];
  final List<WakeHapticRequest> haptics = [];
  final List<(DateTime, DateTime)> sampleRanges = [];

  WakeHapticResult hapticResult = const WakeHapticResult(delivered: ['band']);
  Object? hapticThrows;

  /// What the database holds. [samples] answers from these and HONORS the
  /// requested bounds exactly as `loadWakeSamples` does (seconds floor on
  /// `from`, ceiling on `to`, half open), so a test can land data late.
  final List<List<double>> storedHr = [], storedAccel = [], storedRr = [];

  /// Add one second of 1 Hz data at [tsMs] (absolute epoch ms).
  void store(double tsMs,
      {double hr = 55, bool accel = true, double? rr = 1000, double ax = 0}) {
    storedHr.add([tsMs, hr]);
    if (accel) storedAccel.add([tsMs, ax, 0, 1]);
    if (rr != null) storedRr.add([tsMs, rr]);
  }

  /// Run before [samples] answers; lets a test interleave another call.
  Future<void> Function()? onSamples;

  @override
  Future<WakeSamples> samples(DateTime from, DateTime to) async {
    sampleRanges.add((from, to));
    await onSamples?.call();
    final lo = (from.millisecondsSinceEpoch ~/ 1000) * 1000;
    final hi = ((to.millisecondsSinceEpoch + 999) ~/ 1000) * 1000;
    List<List<double>> within(List<List<double>> rows) =>
        [for (final r in rows) if (r[0] >= lo && r[0] < hi) r];
    return WakeSamples(
      hr: within(storedHr),
      accel: within(storedAccel),
      rr: within(storedRr),
    );
  }

  FallbackStatus _status(DateTime wakeAt) => FallbackStatus(
        armedForWake: armedEpochSec == wakeAt.millisecondsSinceEpoch ~/ 1000,
        confirmed: confirmed,
      );

  /// Runs inside [fallbackStatus], so a test can hold a tick mid-flight.
  Future<void> Function()? onFallbackStatus;

  @override
  Future<FallbackStatus> fallbackStatus(DateTime wakeAt) async {
    await onFallbackStatus?.call();
    return _status(wakeAt);
  }

  @override
  Future<FallbackStatus> ensureFallbackArmed(DateTime wakeAt) async {
    final sec = wakeAt.millisecondsSinceEpoch ~/ 1000;
    armCalls.add(sec);
    if (armSucceeds) armedEpochSec = sec;
    return _status(wakeAt);
  }

  @override
  Future<bool> cancelNativeAlarm(DateTime wakeAt) async {
    cancelCalls.add(wakeAt.millisecondsSinceEpoch ~/ 1000);
    if (cancelThrows) throw StateError('cancel write failed');
    if (cancelResult) armedEpochSec = null;
    return cancelResult;
  }

  @override
  Future<WakeHapticResult> haptic(WakeHapticRequest r) async {
    haptics.add(r);
    if (hapticThrows != null) throw hapticThrows!;
    return hapticResult;
  }
}

WakePlanInput planFor(
  DateTime wakeAt, {
  int natural = 0,
  int gradual = 0,
  GradualPattern pattern = GradualPattern.ramp,
  int cadenceSec = 180,
  ExpectedSleepSchedule? expected,
  DateTime? sleepOnset,
  bool upgradePending = false,
}) =>
    WakePlanInput(
      wakeAt: wakeAt,
      naturalMinutes: natural,
      gradualMinutes: gradual,
      gradualPattern: pattern,
      gradualCadenceSec: cadenceSec,
      expectedSchedule: expected ??
          const ExpectedSleepSchedule(onsetMinute: 23 * 60, wakeMinute: 7 * 60),
      sleepOnset: sleepOnset,
      upgradePending: upgradePending,
    );
