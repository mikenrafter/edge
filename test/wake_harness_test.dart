// Wake dev harness config: parse-on-read, bounds, composition with the journal
// policy, developer-mode gate (S3, S4) and backup exclusion.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';
import 'package:openstrap_edge/wake/wake_harness.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';

void main() {
  WakeHarnessConfig parse(Map<String, Object?> j, [List<String>? errors]) =>
      WakeHarnessConfig.parse(jsonEncode(j), errors: errors);

  group('parse (S3)', () {
    test('a full valid config round-trips', () {
      const c = WakeHarnessConfig(
        rule: WakeRule.hybrid,
        triggerRunSec: 180,
        minConfidence: 0.45,
        remOnly: true,
        evidenceAgeCapSec: 300,
        hrRiseBpm: 7,
        motionCeilingG: 0.05,
        vetoMinConfidence: 0.4,
        requireRemOrWake: true,
      );
      final back = WakeHarnessConfig.parse(c.encode());
      expect(back.rule, WakeRule.hybrid);
      expect(back.triggerRunSec, 180);
      expect(back.minConfidence, 0.45);
      expect(back.remOnly, isTrue);
      expect(back.evidenceAgeCapSec, 300);
      expect(back.hrRiseBpm, 7);
      expect(back.motionCeilingG, 0.05);
      expect(back.vetoMinConfidence, 0.4);
      expect(back.requireRemOrWake, isTrue);
      expect(back.isDefault, isFalse);
    });

    test('missing, empty and corrupt JSON give the defaults and report it',
        () {
      for (final raw in [null, '', 'not json', '[1,2]', '42']) {
        final errors = <String>[];
        final c = WakeHarnessConfig.parse(raw, errors: errors);
        expect(c.isDefault, isTrue, reason: '$raw');
        if (raw != null && raw.isNotEmpty) {
          expect(errors, hasLength(1), reason: raw);
        }
      }
    });

    test('out-of-range values clamp to the bounds', () {
      final lo = parse({
        'rule': 'natural',
        'triggerRunSec': 0,
        'minConfidence': -1,
        'evidenceAgeCapSec': 1,
        'hrRiseBpm': 0,
        'motionCeilingG': 0.5,
        'vetoMinConfidence': -3,
      });
      expect(lo.triggerRunSec, 30);
      expect(lo.minConfidence, 0.0);
      expect(lo.evidenceAgeCapSec, 60);
      expect(lo.hrRiseBpm, 4, reason: 'ConfounderProfile asserts hr >= 4');
      expect(lo.motionCeilingG, 0.08,
          reason: 'ConfounderProfile asserts motion <= 0.08');
      expect(lo.vetoMinConfidence, 0.0);
      final hi = parse({
        'triggerRunSec': 9999,
        'minConfidence': 5,
        'evidenceAgeCapSec': 9999,
        'hrRiseBpm': 99,
        'motionCeilingG': 0.0,
        'vetoMinConfidence': 5,
      });
      expect(hi.triggerRunSec, 300);
      expect(hi.minConfidence, 0.9);
      expect(hi.evidenceAgeCapSec, 600);
      expect(hi.hrRiseBpm, 15);
      expect(hi.motionCeilingG, 0.0, reason: 'r2: motion bounds 0..0.08');
      expect(hi.vetoMinConfidence, 0.9);
    });

    test('wrong types and an unknown rule fall back per field', () {
      final errors = <String>[];
      final c = parse({
        'rule': 'pr630',
        'triggerRunSec': 'fast',
        'minConfidence': 0.6,
        'remOnly': 'yes',
        'hrRiseBpm': 8,
      }, errors);
      expect(c.rule, WakeRule.natural);
      expect(c.triggerRunSec, 120);
      expect(c.remOnly, isFalse);
      expect(c.minConfidence, 0.6, reason: 'valid fields are kept');
      expect(c.hrRiseBpm, 8);
      expect(errors, isNotEmpty);
    });

    test('a rule name alone selects it with default coefficients', () {
      final c = parse({'rule': 'legacy'});
      expect(c.rule, WakeRule.legacy);
      expect(c.isDefault, isFalse);
      expect(c.hrRiseBpm, 4);
    });
  });

  group('effective values', () {
    test('trigger run adds the learned offset (clamped ±60) and stays >= 30',
        () {
      const c = WakeHarnessConfig(triggerRunSec: 30);
      expect(c.effectiveTriggerRunSec(-60), 30);
      expect(c.effectiveTriggerRunSec(-200), 30);
      expect(const WakeHarnessConfig().effectiveTriggerRunSec(-15), 105);
      expect(const WakeHarnessConfig(triggerRunSec: 300)
          .effectiveTriggerRunSec(500), 360);
    });

    test('remOnly drops wake from the eligible stages', () {
      expect(const WakeHarnessConfig().eligibleStages, {'rem', 'wake'});
      expect(const WakeHarnessConfig(remOnly: true).eligibleStages, {'rem'});
    });

    test('legacy coefficients override the base and keep journal adjustments',
        () {
      const journal = ConfounderProfile(
        hrArousalBpm: 6,
        motionCeilingG: 0.06,
        caffeine: true,
        adjustedFor: {'caffeine'},
      );
      const c = WakeHarnessConfig(
          rule: WakeRule.legacy, hrRiseBpm: 9, motionCeilingG: 0.07);
      final p = c.compose(journal);
      expect(p.hrArousalBpm, 9);
      expect(p.motionCeilingG, 0.06, reason: 'journal tightening kept');
      expect(p.caffeine, isTrue);
      expect(p.adjustedFor, {'caffeine'});
      // The default rule never touches the profile.
      expect(
          const WakeHarnessConfig(hrRiseBpm: 9).compose(journal), journal);
    });

    test('provenance carries rule, effective values and a stable digest', () {
      const c = WakeHarnessConfig(rule: WakeRule.hybrid, hrRiseBpm: 9);
      final p = c.compose(const ConfounderProfile(motionCeilingG: 0.05));
      final rec = c.provenance(learnedOffsetSec: -15, composed: p);
      expect(rec['version'], 1);
      expect(rec['rule'], 'hybrid');
      final eff = rec['effective'] as Map;
      expect(eff['hrRiseBpm'], 9);
      expect(eff['motionCeilingG'], 0.05, reason: 'after journal composition');
      expect(eff['vetoMinConfidence'], 0.5);
      expect(rec['digest'], isA<String>());
      expect(c.provenance(learnedOffsetSec: -15, composed: p)['digest'],
          rec['digest']);
      expect(
          c.provenance(learnedOffsetSec: -15, composed: c.compose(
              const ConfounderProfile()))['digest'],
          isNot(rec['digest']),
          reason: 'a journal change is a new effective snapshot');
      const n = WakeHarnessConfig(triggerRunSec: 150);
      final nr = n.provenance(
          learnedOffsetSec: -15, composed: const ConfounderProfile());
      expect((nr['effective'] as Map)['triggerRunSec'], 135,
          reason: 'after the learned offset');
      expect(
          n.provenance(learnedOffsetSec: 0, composed: const ConfounderProfile())
              ['digest'],
          isNot(nr['digest']));
    });
  });

  group('developer mode gate (S4)', () {
    final stored = jsonEncode({'rule': 'legacy', 'hrRiseBpm': 10});
    test('developer mode on applies the stored config', () {
      final c = effectiveWakeHarness(developerMode: true, stored: stored);
      expect(c.rule, WakeRule.legacy);
      expect(c.hrRiseBpm, 10);
    });
    test('developer mode off ignores it', () {
      final c = effectiveWakeHarness(developerMode: false, stored: stored);
      expect(c.isDefault, isTrue);
    });
  });

  group('snapshot covers every decision-affecting field (Sol code r1 #6)', () {
    test('composed policy, window, lead and the routed rule are recorded', () {
      const c = WakeHarnessConfig(rule: WakeRule.legacy, hrRiseBpm: 6);
      const journal = ConfounderProfile(
        protectionMinutes: 10,
        trendWindowMinutes: 5,
        stress: true,
        alcohol: true,
      );
      final eff = c.provenance(
        learnedOffsetSec: 0,
        composed: c.compose(journal),
        windowLeadMinutes: 3,
        windowMinutes: 45,
      )['effective'] as Map;
      expect(eff['protectionMinutes'], 10);
      expect(eff['trendWindowMinutes'], 5);
      expect(eff['trendThresholdFactor'], 0.5);
      expect(eff['disableEarlyDelivery'], isTrue);
      expect(eff['windowLeadMinutes'], 3);
      expect(eff['windowMinutes'], 45);
      // The default config on the legacy route records what ran: legacy.
      final ran = WakeHarnessConfig.defaults.provenance(
        learnedOffsetSec: 0,
        composed: const ConfounderProfile(),
        ranAs: WakeRule.legacy,
      );
      expect(ran['rule'], 'legacy');
      expect((ran['effective'] as Map)['hrRiseBpm'], 4);
    });
  });

  group('planner (Sol code r1 #2, #4)', () {
    final wakeAt = DateTime.utc(2026, 10, 26, 7);
    NaturalDecision decide(WakeHarnessConfig h,
            {bool userActive = false,
            bool? legacyFire,
            NaturalObservation? obs}) =>
        NaturalWakePlanner.decide(NaturalDecisionInput(
          now: wakeAt.subtract(const Duration(minutes: 20)),
          wakeAt: wakeAt,
          windowMinutes: 60,
          observation: obs,
          connected: true,
          alreadyFired: false,
          acknowledged: false,
          lateness: Duration.zero,
          userActive: userActive,
          harness: h,
          legacyFire: legacyFire,
          evidence: const NaturalGateEvidence(
              baseline: 50, recentHr: 70, motion: 0.0, trending: false),
        ));
    const nrem = NaturalObservation(
      stage: 'nrem', confidence: 0.6, evidenceAgeMs: 30000,
      abstention: null, runSec: 600, epochStartMs: 1, note: null);
    const hybrid = WakeHarnessConfig(
        rule: WakeRule.hybrid, requireRemOrWake: true, hrRiseBpm: 15);

    test('user activity fires Natural (control) but never hybrid', () {
      expect(decide(WakeHarnessConfig.defaults, userActive: true).fire,
          isTrue);
      expect(
          decide(hybrid, userActive: true, legacyFire: false, obs: nrem).fire,
          isFalse);
      expect(decide(hybrid, userActive: true, legacyFire: true, obs: nrem).fire,
          isFalse, reason: 'the NREM veto still applies');
    });

    test("hybrid's boolean is the legacy evaluator's, not the gate evidence",
        () {
      const h = WakeHarnessConfig(rule: WakeRule.hybrid);
      expect(decide(h, legacyFire: false).reason, NaturalReason.legacyHold,
          reason: 'evidence alone (+20 bpm, still) would pass the gates');
      expect(decide(h, legacyFire: true).fire, isTrue);
      expect(decide(h).fire, isFalse, reason: 'unknown legacy answer holds');
      expect(decide(h, legacyFire: true, obs: nrem).fire, isFalse);
    });
  });

  test('the harness pref never travels in a backup', () {
    expect(kPrefsNotBackedUp.containsKey(kWakeHarnessPrefKey), isTrue);
    expect(kWakeHarnessPrefKey, 'dev.wake_harness.v1');
  });
}
