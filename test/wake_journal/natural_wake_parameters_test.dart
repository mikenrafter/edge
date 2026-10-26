import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';
import 'package:openstrap_edge/wake/natural_wake_tuning.dart';
import 'fixtures.dart';

NaturalDecision decide({
  NaturalWakeParameters tuning = const NaturalWakeParameters(),
  double run = 120,
  String stage = 'rem',
  int minute = -10,
  int window = 30,
  bool connected = true,
  bool ack = false,
  bool fired = false,
  int? sleepMinutes,
  double confidence = .5,
  double age = 30000,
  Duration late = Duration.zero,
}) => NaturalWakePlanner.decide(
  NaturalDecisionInput(
    now: atMinute(minute),
    wakeAt: alarmAt,
    windowMinutes: window,
    observation: NaturalObservation(
      stage: stage,
      runSec: run,
      confidence: confidence,
      evidenceAgeMs: age,
      abstention: stage == 'absent' ? 'missingHr' : null,
      epochStartMs: 1,
      note: null,
    ),
    connected: connected,
    alreadyFired: fired,
    acknowledged: ack,
    lateness: late,
    tuning: tuning,
    sleepOnset: sleepMinutes == null ? null : atMinute(minute - sleepMinutes),
  ),
);

void main() {
  test(
    'tuned -15 s trigger permits a 105 s eligible run; 104 s stays quiet',
    () {
      const tune = NaturalWakeParameters(triggerRunOffsetSec: -15);
      expect(decide(tuning: tune, run: 104).reason, NaturalReason.remNotStable);
      expect(decide(tuning: tune, run: 105).reason, NaturalReason.fire);
      expect(decide(run: 105).reason, NaturalReason.remNotStable);
    },
  );

  test('tuned +15 s trigger holds 134 s; 135 s fires', () {
    const tune = NaturalWakeParameters(triggerRunOffsetSec: 15);
    expect(decide(tuning: tune, run: 134).reason, NaturalReason.remNotStable);
    expect(decide(tuning: tune, run: 135).reason, NaturalReason.fire);
  });

  test('lead +1 opens at T-31 and lead -1 holds until T-29', () {
    expect(
      decide(
        tuning: const NaturalWakeParameters(windowLeadMinutes: 1),
        minute: -31,
      ).reason,
      NaturalReason.fire,
    );
    expect(
      decide(
        tuning: const NaturalWakeParameters(windowLeadMinutes: -1),
        minute: -30,
      ).reason,
      NaturalReason.beforeWindow,
    );
  });

  test(
    'tuning keeps every per-night safety gate and never enables a disabled window',
    () {
      const tune = NaturalWakeParameters(
        triggerRunOffsetSec: -60,
        windowLeadMinutes: 10,
      );
      expect(decide(tuning: tune, window: 0).reason, NaturalReason.off);
      expect(
        decide(tuning: tune, minute: 0).reason,
        NaturalReason.windowClosed,
      );
      expect(
        decide(tuning: tune, connected: false).reason,
        NaturalReason.disconnected,
      );
      expect(
        decide(tuning: tune, ack: true).reason,
        NaturalReason.acknowledged,
      );
      expect(
        decide(tuning: tune, fired: true).reason,
        NaturalReason.alreadyFired,
      );
      expect(
        decide(tuning: tune, stage: 'nrem').reason,
        NaturalReason.noRemCandidate,
      );
      expect(
        decide(tuning: tune, stage: 'absent').reason,
        NaturalReason.missingHr,
      );
      expect(
        decide(tuning: tune, confidence: .29).reason,
        NaturalReason.lowConfidence,
      );
      expect(
        decide(tuning: tune, age: 150001).reason,
        NaturalReason.samplesStale,
      );
      expect(
        decide(tuning: tune, sleepMinutes: 44).reason,
        NaturalReason.tooSoonAfterOnset,
      );
      expect(
        decide(tuning: tune, late: const Duration(minutes: 4)).reason,
        NaturalReason.lateExecution,
      );
      expect(
        decide(tuning: tune, stage: 'wake', run: 60, sleepMinutes: 45).reason,
        NaturalReason.fire,
      );
    },
  );

  test(
    'default detector retains 120 s REM/wake bar with 45 min minimum sleep',
    () {
      expect(decide(run: 119).reason, NaturalReason.remNotStable);
      expect(decide(run: 120, sleepMinutes: 45).reason, NaturalReason.fire);
      expect(
        decide(run: 120, stage: 'wake', sleepMinutes: 45).reason,
        NaturalReason.fire,
      );
      expect(
        decide(run: 1000, stage: 'nrem').reason,
        NaturalReason.noRemCandidate,
      );
    },
  );
}
