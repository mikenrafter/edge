// Oct 4: the breathing cues are haptic slots. `breath.inhale`, `breath.exhale`,
// `breath.hold` and `breath.done` are named system slots like the gesture cues:
// each has a built-in default drawn from the MG's measured vocabulary, can be
// assigned a saved pattern, and is listed on the Haptics screen under a
// "Breathing" section. This file pins the data side (defaults, store seeding,
// assignment, labels) and the screen; the delivery over the band is pinned in
// test/breath_cues_band_writes_test.dart.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;

import 'support/haptics_screen_support.dart';

const _keys = [
  kBreathInhaleKey,
  kBreathExhaleKey,
  kBreathHoldKey,
  kBreathDoneKey,
];

void main() {
  group('the four slots and their built-in defaults', () {
    test('the ids match the gesture cues\' style', () {
      expect(_keys,
          ['breath.inhale', 'breath.exhale', 'breath.hold', 'breath.done']);
    });

    test('each is a built-in with a name and the id every built-in has', () {
      for (final k in _keys) {
        expect(builtInKeys(), contains(k), reason: k);
        final spec = builtInDefault(k);
        expect(spec, isNotNull, reason: k);
        expect(spec!.sequence.patternId, systemPatternId(k));
        expect(spec.name, startsWith('Breathing '));
      }
    });

    test('the four defaults are different from each other', () {
      final feel = {
        for (final k in _keys)
          k: builtInDefault(k)!
              .sequence
              .bakedSteps!
              .map((s) => '${s.effects}x${s.loop}')
              .join('|'),
      };
      expect(feel.values.toSet(), hasLength(4), reason: '$feel');
      final names = {for (final k in _keys) builtInDefault(k)!.name};
      expect(names, hasLength(4));
    });

    test('each is ONE band command (the band allows 30 commands in two '
        'minutes, and box breathing cues four times every 16 s)', () {
      for (final k in _keys) {
        expect(builtInDefault(k)!.sequence.bakedSteps, hasLength(1), reason: k);
      }
    });

    test('they are phrases of the measured vocabulary, not invented', () {
      final mg = HapticDeviceProfile.whoopMg;
      for (final k in _keys) {
        final step = builtInDefault(k)!.sequence.bakedSteps!.single;
        expect(
          mg.phrases.any((p) =>
              p.stable &&
              p.loop == step.loop &&
              p.effects.join(',') == step.effects.join(',')),
          isTrue,
          reason: k,
        );
      }
    });

    test('a phase cue fits inside the shortest phase of every built-in '
        'pattern; only the session-complete cue may run longer', () {
      var shortest = double.infinity;
      for (final p in kBreathPatterns) {
        for (final ph in p.phases) {
          if (ph.seconds < shortest) shortest = ph.seconds;
        }
      }
      for (final k in [kBreathInhaleKey, kBreathExhaleKey, kBreathHoldKey]) {
        final ms = builtInDefault(k)!.sequence.bakedRuntimeMs!;
        expect(ms, lessThan(shortest * 1000 / 2),
            reason: '$k plays in the first half of the shortest phase');
      }
    });

    test('the inhale cue is the longest phase cue and the hold the lightest: '
        'long in, shorter out, a double tick for a hold', () {
      int ms(String k) => builtInDefault(k)!.sequence.bakedRuntimeMs!;
      expect(ms(kBreathInhaleKey), greaterThan(ms(kBreathExhaleKey)));
      expect(ms(kBreathExhaleKey), greaterThan(ms(kBreathHoldKey)));
    });

    test('a fresh store seeds them, and an old store without them gains them '
        'without losing what it had', () {
      final fresh = HapticPatternStore.decodeSeeded(null);
      for (final k in _keys) {
        expect(fresh.bySystemKey(k), isNotNull, reason: k);
      }
      // A store written before the breathing cues: no breath.* entry.
      final all = jsonDecode(fresh.encode()) as List;
      final old = jsonEncode([
        for (final e in all)
          if (!'${(e as Map)['systemKey']}'.startsWith('breath.')) e,
      ]);
      expect(HapticPatternStore.decode(old).bySystemKey(kBreathDoneKey), isNull);
      final seeded = HapticPatternStore.decodeSeeded(old);
      for (final k in _keys) {
        expect(seeded.bySystemKey(k), isNotNull, reason: k);
      }
      expect(seeded.list.length, fresh.list.length);
    });

    test('putting a built-in back resets it to its default', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final p = store.bySystemKey(kBreathExhaleKey)!;
      store.replace(p.id, builtInDefault(kBreathInhaleKey)!.sequence);
      store.resetToDefault(p.id);
      expect(store.bySystemKey(kBreathExhaleKey)!.sequence.bakedSteps!.single.effects,
          builtInDefault(kBreathExhaleKey)!.sequence.bakedSteps!.single.effects);
    });
  });

  group('the slots', () {
    test('a "Breathing" section holds the four, in play order', () {
      final s = kHapticSlotSections.singleWhere((s) => s.id == 'breathing');
      expect(s.title, 'Breathing');
      expect([for (final x in s.slots) x.key], _keys);
      expect([for (final x in s.slots) x.label],
          ['Inhale', 'Exhale', 'Hold', 'Session complete']);
    });

    test('the old "Breathing session cue" alert slot is gone: it played a '
        'fixed per-tap pattern and never read what was put on it', () {
      final all = [for (final s in kHapticSlotSections) ...s.slots];
      expect(all.where((s) => s.key == 'alert.breath'), isEmpty);
    });

    test('no slot key is listed twice', () {
      final all = [
        for (final s in kHapticSlotSections) for (final x in s.slots) x.key,
      ];
      expect(all.toSet().length, all.length);
    });

    test('they are cue slots: stored assignments and resolution accept them',
        () {
      for (final k in _keys) {
        expect(isBreathCueSlot(k), isTrue);
        expect(isGestureCueSlot(k), isFalse);
        expect(isCueSlot(k), isTrue);
      }
      expect(isCueSlot('alert.water'), isFalse);
      final raw = encodeCueAssignments({
        kBreathInhaleKey: 'a',
        kGestureStartKey: 'b',
        'alert.water': 'c',
      });
      expect(decodeCueAssignments(raw),
          {kBreathInhaleKey: 'a', kGestureStartKey: 'b'});
    });

    test('resolveCuePatterns: the assigned pattern wins, else the store\'s '
        'own built-in', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final mine = store.add('Mine', builtInDefault(kBreathDoneKey)!.sequence);
      final r = resolveCuePatterns(store, {kBreathExhaleKey: mine.id});
      expect(r[kBreathExhaleKey]!.patternId, mine.sequence.patternId);
      expect(r[kBreathExhaleKey], same(mine.sequence));
      expect(r[kBreathInhaleKey], same(store.bySystemKey(kBreathInhaleKey)!.sequence));
      for (final k in _keys) {
        expect(r.containsKey(k), isTrue, reason: k);
      }
    });

    test('an assignment naming a pattern that is gone falls back to the '
        'built-in', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final r = resolveCuePatterns(store, {kBreathHoldKey: 'no-such'});
      expect(r[kBreathHoldKey], same(store.bySystemKey(kBreathHoldKey)!.sequence));
    });

    test('slotPatternLabel names the default, or the assigned pattern', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final mine = store.add('Soft', builtInDefault(kBreathHoldKey)!.sequence);
      String label(String k, Map<String, String> assigned) => slotPatternLabel(
            k,
            patterns: store.list,
            alerts: const NotificationPrefs(),
            channels: const {},
            cueAssignments: assigned,
          );
      expect(label(kBreathInhaleKey, const {}), 'Breathing inhale');
      expect(label(kBreathDoneKey, const {}), 'Breathing done');
      expect(label(kBreathExhaleKey, {kBreathExhaleKey: mine.id}), 'Your: Soft');
    });
  });

  group('the Haptics screen', () {
    testWidgets('lists a Breathing group on the Cues tab with the four slots '
        'and the pattern each plays', (t) async {
      await pumpHub(t, HubCalls(), slotNames: {
        kBreathInhaleKey: 'Breathing inhale',
        kBreathExhaleKey: 'Breathing exhale',
        kBreathHoldKey: 'Your: Soft',
        kBreathDoneKey: 'Breathing done',
      });
      await openHapticsTab(t, 'cues');
      final header = find.byWidgetPredicate(
          (w) => w is SettingsAccordion && w.title == 'Breathing');
      expect(header, findsOneWidget);
      final labels = {
        kBreathInhaleKey: ('Inhale', 'Breathing inhale'),
        kBreathExhaleKey: ('Exhale', 'Breathing exhale'),
        kBreathHoldKey: ('Hold', 'Your: Soft'),
        kBreathDoneKey: ('Session complete', 'Breathing done'),
      };
      for (final e in labels.entries) {
        final row = find.byKey(ValueKey('haptic-slot:${e.key}'));
        expect(row, findsOneWidget, reason: e.key);
        expect(find.descendant(of: row, matching: find.text(e.value.$1)),
            findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(e.value.$2)),
            findsOneWidget);
        expect(find.descendant(of: header, matching: row), findsOneWidget,
            reason: 'in its own group');
      }
      expect(find.byKey(const ValueKey('haptic-slot:alert.breath')), findsNothing);
      // Not on the Alerts tab.
      await openHapticsTab(t, 'alerts');
      expect(find.byKey(const ValueKey('haptic-slot:breath.inhale')), findsNothing);
    });

    testWidgets('tapping a breathing slot opens the picker and choosing a '
        'pattern assigns it to that slot', (t) async {
      final c = HubCalls();
      final mine = userPattern('a', 'Morning nudge');
      await pumpHub(t, c, patterns: [mine]);
      await openHapticsTab(t, 'cues');
      await t.tap(find.byKey(const ValueKey('haptic-slot:breath.hold')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pattern-picker')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pattern-picker-row:a')));
      await t.pumpAndSettle();
      expect(c.assigned, [(kBreathHoldKey, 'a')]);
    });

    testWidgets('"Use on a slot" lists the breathing slots too', (t) async {
      await pumpHub(t, HubCalls(), patterns: [userPattern('a', 'Morning nudge')]);
      await t.tap(find.byKey(const ValueKey('haptic-pattern:a')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('haptic-action-assign')));
      await t.pumpAndSettle();
      for (final k in _keys) {
        expect(find.byKey(ValueKey('haptic-assign-slot:$k')), findsOneWidget,
            reason: k);
      }
    });
  });
}
