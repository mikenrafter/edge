// The six Tasker haptic slots (RED). `tasker.1` .. `tasker.6` are named system
// slots like the gesture and breathing cues: slot n's built-in default is n
// short pulses, each can be given a saved pattern, and they are listed on the
// Haptics screen under a "Tasker" section. Tasker plays them by number or by
// key (see tasker_incoming_play_test.dart for the delivery).
//
// "n short pulses" is read off the notes: n pulses, each as long as the
// pulse of the built-in "One pulse", one rest (as in the other pulse presets)
// between them. A 4.0 holds eight taps, so six fit whole.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;

import '../../support/haptics_screen_support.dart';

final _keys = [for (var n = 1; n <= 6; n++) 'tasker.$n'];

void main() {
  group('the keys', () {
    test('taskerSlotKey, isTaskerSlot and taskerSlotNumber agree on 1..6', () {
      for (var n = 1; n <= 6; n++) {
        expect(taskerSlotKey(n), 'tasker.$n');
        expect(isTaskerSlot('tasker.$n'), isTrue);
        expect(taskerSlotNumber('tasker.$n'), n);
      }
      for (final other in [
        'tasker.0',
        'tasker.7',
        'tasker',
        'alert.tasker',
        'gesture.start',
        'breath.done',
        '',
      ]) {
        expect(isTaskerSlot(other), isFalse, reason: other);
        expect(taskerSlotNumber(other), isNull, reason: other);
      }
      expect(() => taskerSlotKey(0), throwsArgumentError);
      expect(() => taskerSlotKey(7), throwsArgumentError);
    });
  });

  group('the built-in defaults: slot n is n short pulses', () {
    final one = presetByName('One pulse')!.sequence;
    final onePulse = pulseLengths(notesOf(one)).single;

    for (var n = 1; n <= 6; n++) {
      test('tasker.$n is $n short pulses', () {
        final spec = builtInDefault('tasker.$n');
        expect(spec, isNotNull, reason: 'a built-in default');
        expect(spec!.sequence.patternId, systemPatternId('tasker.$n'));
        expect(spec.sequence.notes, isNotNull,
            reason: 'written as notes (an MG pattern)');
        final es = notesOf(spec.sequence);
        expect(pulseLengths(es), List.filled(n, onePulse),
            reason: '$n pulses, each as long as "One pulse"');
        expect(restsBetween(es), hasLength(n - 1),
            reason: 'a rest between pulses, none around them');
        expect(restsBetween(es).toSet().length, lessThanOrEqualTo(1),
            reason: 'every rest the same');
        expect(spec.sequence.offsetsMs, hasLength(n),
            reason: 'the 4.0 taps rhythm has one tap per pulse');
        expect(spec.sequence.bakedSteps, isNotNull,
            reason: 'compiled for the MG');
      });
    }

    test('for 1..5 it is the same pattern as the preset of that count', () {
      const presets = [
        'One pulse',
        'Two pulses',
        'Three pulses',
        'Four pulses',
        'Five pulses',
      ];
      for (var n = 1; n <= 5; n++) {
        expect(builtInDefault('tasker.$n')!.sequence.notes,
            presetByName(presets[n - 1])!.sequence.notes,
            reason: 'slot $n');
      }
    });

    test('each has its own name, and the six are different from each other',
        () {
      final names = {for (final k in _keys) builtInDefault(k)!.name};
      expect(names, hasLength(6));
      for (final k in _keys) {
        expect(builtInDefault(k)!.name, startsWith('Tasker'), reason: k);
      }
      final notes = {for (final k in _keys) builtInDefault(k)!.sequence.notes};
      expect(notes, hasLength(6));
    });

    test('they are built-ins: listed, and seeded into a fresh store', () {
      final fresh = HapticPatternStore.decodeSeeded(null);
      for (final k in _keys) {
        expect(builtInKeys(), contains(k), reason: k);
        final p = fresh.bySystemKey(k);
        expect(p, isNotNull, reason: k);
        expect(p!.system, isTrue);
        expect(p.id, systemPatternId(k));
      }
    });

    test('an old store without them gains them and loses nothing', () {
      final fresh = HapticPatternStore.decodeSeeded(null);
      final all = jsonDecode(fresh.encode()) as List;
      final old = jsonEncode([
        for (final e in all)
          if (!'${(e as Map)['systemKey']}'.startsWith('tasker.')) e,
      ]);
      expect(HapticPatternStore.decode(old).bySystemKey('tasker.1'), isNull);
      final seeded = HapticPatternStore.decodeSeeded(old);
      for (final k in _keys) {
        expect(seeded.bySystemKey(k), isNotNull, reason: k);
      }
      expect(seeded.list.length, fresh.list.length);
    });

    test('a slot the wearer changed is put back to its n pulses', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final p = store.bySystemKey('tasker.3')!;
      store.replace(p.id, builtInDefault('tasker.1')!.sequence);
      expect(store.bySystemKey('tasker.3')!.sequence.notes,
          builtInDefault('tasker.1')!.sequence.notes);
      store.resetToDefault(p.id);
      expect(store.bySystemKey('tasker.3')!.sequence.notes,
          builtInDefault('tasker.3')!.sequence.notes);
    });
  });

  group('the section and reassignment (data)', () {
    test('a "Tasker" section holds the six, in order', () {
      final s = kHapticSlotSections.singleWhere((s) => s.id == 'tasker');
      expect(s.title, 'Tasker');
      expect([for (final x in s.slots) x.key], _keys);
      for (var n = 1; n <= 6; n++) {
        expect(s.slots[n - 1].label, startsWith('Tasker'));
        expect(s.slots[n - 1].label, contains('$n'));
      }
    });

    test('no slot key is listed twice, and the alert slot is still there', () {
      final all = [
        for (final s in kHapticSlotSections) for (final x in s.slots) x.key,
      ];
      expect(all.toSet().length, all.length);
      expect(all, contains('alert.tasker'),
          reason: 'the automation alert is a different slot');
    });

    test('they are cue slots: stored assignments and resolution accept them',
        () {
      for (final k in _keys) {
        expect(isCueSlot(k), isTrue, reason: k);
        expect(isGestureCueSlot(k), isFalse, reason: k);
        expect(isBreathCueSlot(k), isFalse, reason: k);
      }
      final raw = encodeCueAssignments({
        'tasker.2': 'a',
        'tasker.9': 'b',
        'alert.water': 'c',
      });
      expect(decodeCueAssignments(raw), {'tasker.2': 'a'});
    });

    test('resolveCuePatterns: the assigned pattern wins, else the slot\'s '
        'own built-in', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final mine = store.add('Mine', builtInDefault('preset.sos')!.sequence);
      final r = resolveCuePatterns(store, {'tasker.2': mine.id});
      expect(r['tasker.2'], same(mine.sequence));
      expect(r['tasker.5'], same(store.bySystemKey('tasker.5')!.sequence));
      for (final k in _keys) {
        expect(r.containsKey(k), isTrue, reason: k);
      }
    });

    test('an assignment naming a pattern that is gone falls back to the '
        'built-in', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final r = resolveCuePatterns(store, {'tasker.6': 'no-such'});
      expect(r['tasker.6'], same(store.bySystemKey('tasker.6')!.sequence));
    });

    test('slotPatternLabel names the default, or the assigned pattern', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final mine = store.add('Soft', builtInDefault('preset.sos')!.sequence);
      String label(String k, Map<String, String> assigned) => slotPatternLabel(
            k,
            patterns: store.list,
            alerts: const NotificationPrefs(),
            channels: const {},
            cueAssignments: assigned,
          );
      expect(label('tasker.1', const {}), builtInDefault('tasker.1')!.name);
      expect(label('tasker.4', const {}), builtInDefault('tasker.4')!.name);
      expect(label('tasker.2', {'tasker.2': mine.id}), 'Your: Soft');
    });
  });

  group('the Haptics screen', () {
    // The section may sit on any tab; it is found, not assumed.
    Future<String?> findTab(WidgetTester t) async {
      for (final id in ['alerts', 'cues', 'activity', 'patterns', 'band']) {
        await openHapticsTab(t, id);
        if (find
            .byWidgetPredicate(
                (w) => w is SettingsAccordion && w.title == 'Tasker')
            .evaluate()
            .isNotEmpty) {
          return id;
        }
      }
      return null;
    }

    testWidgets('lists a Tasker group with the six slots and the pattern each '
        'plays', (t) async {
      await pumpHub(t, HubCalls(), slotNames: {
        for (var n = 1; n <= 6; n++) 'tasker.$n': '$n pulses',
      });
      final tab = await findTab(t);
      expect(tab, isNotNull, reason: 'no tab has a "Tasker" section');
      final header = find.byWidgetPredicate(
          (w) => w is SettingsAccordion && w.title == 'Tasker');
      expect(header, findsOneWidget);
      for (var n = 1; n <= 6; n++) {
        final row = find.byKey(ValueKey('haptic-slot:tasker.$n'));
        expect(row, findsOneWidget, reason: 'tasker.$n');
        expect(find.descendant(of: row, matching: find.text('$n pulses')),
            findsOneWidget);
        expect(find.descendant(of: header, matching: row), findsOneWidget,
            reason: 'in its own group');
      }
    });

    testWidgets('tapping a Tasker slot opens the picker and choosing a pattern '
        'assigns it to that slot', (t) async {
      final c = HubCalls();
      final mine = userPattern('a', 'Morning nudge');
      await pumpHub(t, c, patterns: [mine]);
      await findTab(t);
      await t.tap(find.byKey(const ValueKey('haptic-slot:tasker.3')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pattern-picker')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pattern-picker-row:a')));
      await t.pumpAndSettle();
      expect(c.assigned, [('tasker.3', 'a')]);
    });

    testWidgets('"Use on a slot" lists the Tasker slots too', (t) async {
      await pumpHub(t, HubCalls(), patterns: [userPattern('a', 'Morning nudge')]);
      await openHapticsTab(t, 'patterns');
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
