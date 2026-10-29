// Wake dev harness config: parse-on-read, bounds, composition with the journal
// policy, developer-mode gate (S3, S4) and backup exclusion.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';
import 'package:openstrap_edge/wake/wake_harness.dart';

void main() {
  WakeHarnessConfig parse(Map<String, Object?> j, [List<String>? errors]) =>
      WakeHarnessConfig.parse(jsonEncode(j), onError: errors?.add);

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
        final c = WakeHarnessConfig.parse(raw, onError: errors.add);
        expect(c.isDefault, isTrue, reason: '$raw');
        if (raw != null && raw.isNotEmpty) {
          expect(errors, hasLength(1), reason: '$raw');
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
      expect(hi.motionCeilingG, 0.02);
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
      final p = c.compose(const ConfounderProfile());
      final rec = c.provenance(learnedOffsetSec: -15, composed: p);
      expect(rec['version'], 1);
      expect(rec['rule'], 'hybrid');
      final eff = rec['effective'] as Map;
      expect(eff['triggerRunSec'], 105);
      expect(eff['hrRiseBpm'], 9);
      expect(eff['motionCeilingG'], 0.08);
      expect(eff['vetoMinConfidence'], 0.5);
      expect(rec['digest'], isA<String>());
      expect(c.provenance(learnedOffsetSec: -15, composed: p)['digest'],
          rec['digest']);
      expect(c.provenance(learnedOffsetSec: 0, composed: p)['digest'],
          isNot(rec['digest']));
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

  test('the harness pref never travels in a backup', () {
    expect(kPrefsNotBackedUp.containsKey(kWakeHarnessPrefKey), isTrue);
    expect(kWakeHarnessPrefKey, 'dev.wake_harness.v1');
  });
}
