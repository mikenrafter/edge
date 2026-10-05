// 8AI G4 (red): the built-in presets and where the slot defaults point.
//
// Spec: new built-in presets One pulse, Two pulses, Three pulses, Four pulses,
// Five pulses, One long pulse, Two long pulses, Three long pulses, SOS
// (··· ——— ···) and "Hip hip hooray ×2" (default for the step-goal alert).
// Slot DEFAULTS are redistributed more evenly across the presets so different
// alerts feel different; a user's own choice is never overwritten.
//
// ASSUMED API: none new. The tests go through the existing seams in
// lib/haptics/builtin_patterns.dart and lib/haptics/pattern_store.dart:
//   * `builtInKeys()` lists every built-in key; `builtInDefault(key)` returns
//     its BuiltInSpec (name + BuzzSequence). A PRESET is any built-in whose
//     spec name is one of the ten names above (so no preset key is assumed).
//   * `builtInDefault('alert.<ruleId>')` / `builtInDefault('gesture.start')`
//     keep meaning "the default pattern of that slot" (the slot key scheme
//     8AF.6 already uses). For an alert slot the default is now a PRESET: its
//     spec name is one of the ten names (today it is a per-rule name such as
//     "Health alert"). The three gesture cues keep their own built-ins (the
//     start pair, the follow-up single, the confirm), not presets.
//   * `HapticPatternStore.decodeSeeded(raw)` seeds every preset as a system
//     pattern (`SavedHapticPattern.system`), idempotently, without touching a
//     stored pattern.
//
// Encoded interpretations (documented because the spec leaves them open):
//   * N pulses = N separate pulses (a rest between each), every pulse as long
//     as the pulse of "One pulse"; N long pulses = every pulse strictly longer
//     than that.
//   * SOS = nine pulses: three short, three long, three short.
//   * "Hip hip hooray ×2" = two identical rounds of (short, short, longer):
//     six pulses.
//   * The slot spread: with 16 alert slots and ten presets, no preset is the
//     default of more than TWO alert slots (today the nine `defaultFor`
//     rhythms are shared by up to THREE: 0, 9 and 18 mod 9), and at least
//     EIGHT of the ten are used. The step-goal slot is Hip hip hooray ×2.
//
// Failure mode today: the ten names are not built in, every alert default has
// a per-rule name, three slots share a rhythm.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import 'support/haptics_screen_support.dart';

/// The slot-spread bound documented above.
const int kMaxSlotsPerPreset = 2;
const int kMinDistinctPresetsUsed = 8;

List<int> _pulses(String name) {
  final spec = presetByName(name);
  expect(spec, isNotNull, reason: 'preset "$name" is not built in');
  expect(spec!.sequence.notes, isNotNull,
      reason: '"$name" is written as notes (an MG pattern)');
  return pulseLengths(notesOf(spec.sequence));
}

void main() {
  group('the ten presets exist', () {
    test('every spec name is a built-in', () {
      final names = {
        for (final k in builtInKeys())
          if (builtInDefault(k) != null) builtInDefault(k)!.name,
      };
      for (final n in kPresetNames) {
        expect(names, contains(n), reason: 'missing preset "$n"');
      }
    });

    test('a fresh store seeds each as a system pattern, once', () {
      final store = HapticPatternStore.decodeSeeded(null);
      for (final n in kPresetNames) {
        final hits = store.list.where((p) => p.name == n).toList();
        expect(hits, hasLength(1), reason: '"$n" seeded exactly once');
        if (hits.length == 1) {
          expect(hits.single.system, isTrue, reason: '"$n" is read-only');
          expect(hits.single.sequence.patternId, hits.single.id);
        }
      }
      // Seeding again from what was written changes nothing.
      final again = HapticPatternStore.decodeSeeded(store.encode());
      expect(again.list.length, store.list.length);
      expect(again.encode(), store.encode());
    });

    test('a stored built-in the wearer customised, and a pattern of their '
        'own, are not overwritten by seeding', () {
      final custom = seqOf('sys.alert.water', notes: 'N8mf');
      final raw = jsonEncode([
        {
          'id': 'sys.alert.water',
          'name': 'Water alert',
          'sequence': custom.toJson(),
          'systemKey': 'alert.water',
        },
        {
          'id': 'u1',
          'name': 'Morning nudge',
          'sequence': seqOf('u1').toJson(),
        },
      ]);
      final store = HapticPatternStore.decodeSeeded(raw);
      expect(store.byId('sys.alert.water')!.sequence.notes, 'N8mf');
      expect(store.byId('u1')!.name, 'Morning nudge');
      expect(store.byId('u1')!.system, isFalse);
    });
  });

  group('what each preset is', () {
    test('One pulse: one pulse; the others are that pulse repeated, with a '
        'rest between every two', () {
      final one = _pulses('One pulse');
      expect(one, hasLength(1));
      for (final (name, n) in [
        ('Two pulses', 2),
        ('Three pulses', 3),
        ('Four pulses', 4),
        ('Five pulses', 5),
      ]) {
        final p = _pulses(name);
        expect(p, hasLength(n), reason: name);
        expect(p.toSet(), {one.single}, reason: '$name: same pulse each time');
        final rests =
            restsBetween(notesOf(presetByName(name)!.sequence));
        expect(rests, hasLength(n - 1), reason: '$name: a rest between pulses');
        expect(rests.every((r) => r >= 1), isTrue);
      }
    });

    test('long pulses: one, two or three, each strictly longer than the '
        'plain pulse', () {
      final plain = _pulses('One pulse').single;
      for (final (name, n) in [
        ('One long pulse', 1),
        ('Two long pulses', 2),
        ('Three long pulses', 3),
      ]) {
        final p = _pulses(name);
        expect(p, hasLength(n), reason: name);
        for (final len in p) {
          expect(len, greaterThan(plain), reason: '$name: a long pulse');
        }
      }
    });

    test('SOS is three short, three long, three short', () {
      final p = _pulses('SOS');
      expect(p, hasLength(9));
      if (p.length != 9) return;
      final short = p[0];
      final long = p[3];
      expect(long, greaterThan(short));
      expect([p[1], p[2], p[6], p[7], p[8]], everyElement(short));
      expect([p[4], p[5]], everyElement(long));
    });

    test('Hip hip hooray ×2 is two identical rounds of short, short, longer',
        () {
      final p = _pulses('Hip hip hooray ×2');
      expect(p, hasLength(6));
      if (p.length != 6) return;
      expect(p.sublist(0, 3), p.sublist(3, 6), reason: 'two identical rounds');
      expect(p[0], p[1], reason: 'hip, hip');
      expect(p[2], greaterThan(p[1]), reason: 'hooray is the longest');
    });

    test('every preset can be played on the MG inside the default 10 s cap, '
        'in at most 8 band commands, and carries its stored plan', () {
      for (final n in kPresetNames) {
        final spec = presetByName(n);
        expect(spec, isNotNull, reason: n);
        if (spec == null || spec.sequence.notes == null) continue;
        final plan = compile(
          notesOf(spec.sequence),
          kMg,
          dynamicWeight: 0,
          maxRuntimeMs: kMaxHapticRuntime.inMilliseconds,
        );
        expect(plan, isNotNull, reason: '$n compiles under the cap');
        expect(plan!.steps.length, lessThanOrEqualTo(BuzzSequence.maxBakedSteps),
            reason: n);
        final baked = spec.sequence.bakedSteps;
        expect(baked, isNotNull, reason: '$n is delivered from a stored plan');
        expect(baked, isNotEmpty);
      }
    });
  });

  group('slot defaults are spread across the presets', () {
    final alerts = alertSlotKeys();

    test('every alert slot has a default, and it is a preset', () {
      expect(alerts, isNotEmpty);
      for (final k in alerts) {
        final spec = slotDefault(k);
        expect(spec, isNotNull, reason: '$k has no default pattern');
        expect(kPresetNames, contains(spec?.name),
            reason: '$k defaults to "${spec?.name}", which is not a preset');
      }
    });

    test('no preset is the default of more than $kMaxSlotsPerPreset alert '
        'slots, and at least $kMinDistinctPresetsUsed are used', () {
      final byName = <String, List<String>>{};
      for (final k in alerts) {
        final name = slotDefault(k)?.name;
        if (name != null) (byName[name] ??= []).add(k);
      }
      for (final e in byName.entries) {
        expect(e.value.length, lessThanOrEqualTo(kMaxSlotsPerPreset),
            reason: '"${e.key}" is the default of ${e.value}');
      }
      expect(byName.keys.where(kPresetNames.contains).length,
          greaterThanOrEqualTo(kMinDistinctPresetsUsed));
    });

    test('and by rhythm too: no two slots beyond the bound play the same '
        'notes', () {
      final byNotes = <String, List<String>>{};
      for (final k in alerts) {
        final s = slotDefault(k)?.sequence;
        if (s == null) continue;
        final code = s.notes ?? 'taps:${s.offsetsMs}:${s.durationsMs}';
        (byNotes[code] ??= []).add(k);
      }
      for (final e in byNotes.entries) {
        expect(e.value.length, lessThanOrEqualTo(kMaxSlotsPerPreset),
            reason: 'rhythm ${e.key} is shared by ${e.value}');
      }
    });

    test('the step-goal alert defaults to Hip hip hooray ×2', () {
      expect(slotDefault('alert.stepGoal')?.name, 'Hip hip hooray ×2');
    });

    test('the gesture cues keep their own built-ins, not presets', () {
      for (final k in kGestureSlotKeys) {
        final spec = slotDefault(k);
        expect(spec, isNotNull, reason: k);
        expect(kPresetNames, isNot(contains(spec?.name)), reason: k);
      }
    });
  });
}
