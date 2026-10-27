import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';
import 'package:openstrap_edge/wake/natural_wake_tuning.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';
import 'support/wake_fakes.dart';

void main() {
  final t = DateTime.utc(2026, 10, 27, 7);
  NaturalDecision decide({
    NaturalGateEvidence? evidence = const NaturalGateEvidence(
      baseline: 50,
      recentHr: 56,
      motion: .01,
      trending: false,
    ),
    ConfounderProfile profile = const ConfounderProfile(),
    bool interaction = false,
    String stage = 'rem',
    int minutes = 20,
  }) => NaturalWakePlanner.decide(
    NaturalDecisionInput(
      now: t.subtract(Duration(minutes: minutes)),
      wakeAt: t,
      windowMinutes: 60,
      observation: stageObs(stage),
      connected: true,
      alreadyFired: false,
      acknowledged: false,
      lateness: Duration.zero,
      evidence: evidence,
      profile: profile,
      userActive: interaction,
      tuning: const NaturalWakeParameters(
        triggerRunOffsetSec: -60,
        windowLeadMinutes: 10,
      ),
    ),
  );
  test(
    'each physiological gate vetoes eligible REM and wake despite permissive tuning',
    () {
      for (final stage in ['rem', 'wake']) {
        expect(decide(stage: stage).fire, isTrue);
        expect(
          decide(stage: stage, evidence: null).reason,
          NaturalReason.physiologyUnavailable,
        );
        expect(
          decide(
            stage: stage,
            evidence: const NaturalGateEvidence(
              baseline: 50,
              recentHr: 53,
              motion: .01,
              trending: false,
            ),
          ).reason,
          NaturalReason.hrArousalHold,
        );
        expect(
          decide(
            stage: stage,
            evidence: const NaturalGateEvidence(
              baseline: 50,
              recentHr: 56,
              motion: .08,
              trending: false,
            ),
          ).reason,
          NaturalReason.motionCeilingHold,
        );
        expect(
          decide(
            stage: stage,
            evidence: const NaturalGateEvidence(
              baseline: 50,
              recentHr: 56,
              motion: .01,
              trending: true,
            ),
          ).reason,
          NaturalReason.motionTrendHold,
        );
        expect(
          decide(
            stage: stage,
            evidence: const NaturalGateEvidence(
              baseline: 50,
              recentHr: 56,
              motion: .01,
            ),
          ).reason,
          NaturalReason.physiologyUnavailable,
        );
      }
    },
  );
  test('profile thresholds and late-window hold apply explicitly', () {
    expect(
      decide(
        profile: const ConfounderProfile(hrArousalBpm: 6),
        evidence: const NaturalGateEvidence(
          baseline: 50,
          recentHr: 55,
          motion: .01,
          trending: false,
        ),
      ).reason,
      NaturalReason.hrArousalHold,
    );
    expect(
      decide(
        profile: const ConfounderProfile(stress: true, motionCeilingG: .06),
        evidence: const NaturalGateEvidence(
          baseline: 50,
          recentHr: 56,
          motion: .06,
          trending: false,
        ),
      ).reason,
      NaturalReason.motionCeilingHold,
    );
    expect(
      decide(
        minutes: 10,
        profile: const ConfounderProfile(workout: true, protectionMinutes: 10),
        evidence: const NaturalGateEvidence(
          baseline: 50,
          recentHr: 52,
          motion: .01,
          trending: false,
        ),
      ).reason,
      NaturalReason.lateWindowHold,
    );
  });
  test(
    'HR never promotes NREM; interaction bypasses physiology after disable',
    () {
      expect(decide(stage: 'nrem').reason, NaturalReason.noRemCandidate);
      expect(
        decide(
          stage: 'nrem',
          interaction: true,
          evidence: null,
        ).viaUserActivity,
        isTrue,
      );
      expect(
        decide(
          interaction: true,
          profile: const ConfounderProfile(alcohol: true, stress: true),
        ).reason,
        NaturalReason.policyHold,
      );
    },
  );
  test(
    'real worker computes shared evidence independently of causal warm-up',
    () async {
      final now = t.millisecondsSinceEpoch.toDouble();
      final hr = <List<double>>[], accel = <List<double>>[];
      for (var sec = 10800; sec > 0; sec--) {
        hr.add([now - sec * 1000, sec <= 180 ? 56 : 50]);
        accel.add([now - sec * 1000, 0, 0, 1.01]);
      }
      final r = await const IsolateNaturalStageObserver().observe(
        NaturalObserveRequest(
          nowMs: now,
          hr: const [],
          accel: const [],
          rr: const [],
          gateHr: hr,
          gateAccel: accel,
        ),
      );
      expect(r.evidence!.baseline, 50);
      expect(r.evidence!.recentHr, 56);
      expect(r.evidence!.motion, closeTo(.01, 1e-9));
      expect(r.evidence!.trending, isFalse);
    },
  );
}
