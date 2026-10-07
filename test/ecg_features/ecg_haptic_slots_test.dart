// ECG features, phase 1 (RED): the six ECG haptic slots.
//
// `ecg.started`, `ecg.complete`, `ecg.inconclusive`, `ecg.inconclusiveRetry`,
// `ecg.failed` and `ecg.attention` are named system slots like the gesture and
// breathing cues: each has its own built-in default, can be assigned a saved
// pattern, is seeded into the pattern store, is listed on the Haptics screen
// (Cues tab) under an "ECG" section, and sits in ONE confusable set so the
// "Feels like ..." warning applies. `ecg.attention` defaults to the SOS rhythm
// and is the only one that does: it is for a band that may still be recording,
// never for what a reading found (the mapping is pinned in
// ecg_cue_mapping_test.dart).
//
// Assumed (lib/): the six consts and kEcgCueKeys in haptics/builtin_patterns.dart
// (they exist); isEcgCueSlot in haptic_slots.dart; builtInKeys()/builtInDefault
// know the six; kHapticSlotSections has an 'ecg' section titled "ECG";
// decodeCueAssignments / resolveCuePatterns / slotPatternLabel treat them as cue
// slots; kConfusableSets has one set holding all six.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/pattern_similarity.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;

import '../support/haptics_screen_support.dart';

const _keys = [
  'ecg.started',
  'ecg.complete',
  'ecg.inconclusive',
  'ecg.inconclusiveRetry',
  'ecg.failed',
  'ecg.attention',
];

BuiltInSpec _spec(String k) {
  final s = builtInDefault(k);
  expect(s, isNotNull, reason: 'no built-in default for $k');
  return s!;
}

String _plan(String k) => _spec(k)
    .sequence
    .bakedSteps!
    .map((s) => '${s.effects}x${s.loop}@${s.delayMs}')
    .join('|');

void main() {
  group('the keys', () {
    test('are the owner-specified names, in listing order', () {
      expect(kEcgCueKeys, _keys);
      expect(kEcgStartedKey, 'ecg.started');
      expect(kEcgCompleteKey, 'ecg.complete');
      expect(kEcgInconclusiveKey, 'ecg.inconclusive');
      expect(kEcgInconclusiveRetryKey, 'ecg.inconclusiveRetry');
      expect(kEcgFailedKey, 'ecg.failed');
      expect(kEcgAttentionKey, 'ecg.attention');
    });
  });

  group('each has its own built-in default', () {
    test('every key is a built-in with a name and the id every built-in has',
        () {
      for (final k in _keys) {
        expect(builtInKeys(), contains(k), reason: k);
        final spec = builtInDefault(k);
        expect(spec, isNotNull, reason: k);
        expect(spec!.key, k);
        expect(spec.sequence.patternId, systemPatternId(k));
        expect(spec.name, startsWith('ECG '), reason: k);
      }
    });

    test('the six defaults are mutually distinct: names, notes and band plans',
        () {
      final names = {for (final k in _keys) _spec(k).name};
      expect(names, hasLength(6));
      final notes = {for (final k in _keys) _spec(k).sequence.notes};
      expect(notes, hasLength(6), reason: 'six different rhythms');
      expect(notes, isNot(contains(null)));
      final plans = {for (final k in _keys) _plan(k)};
      expect(plans, hasLength(6), reason: 'six different plans on the band');
    });

    test('ecg.attention is the S.O.S. rhythm (three short, three long, three '
        'short) and nothing else defaults to it', () {
      final sos = _spec('preset.sos').sequence;
      expect(_spec(kEcgAttentionKey).sequence.notes, sos.notes);
      for (final k in _keys.where((k) => k != kEcgAttentionKey)) {
        expect(_spec(k).sequence.notes, isNot(sos.notes), reason: k);
      }
    });

    test('no ECG default is the rhythm of a gesture or breathing cue: a '
        'double tap starts an ECG, so gesture.start is heard right before '
        'ecg.started', () {
      final others = {
        for (final k in builtInKeys())
          if (k.startsWith('gesture.') || k.startsWith('breath.'))
            _spec(k).sequence.notes,
      };
      for (final k in _keys) {
        expect(others, isNot(contains(_spec(k).sequence.notes)),
            reason: '$k would be mistaken for a gesture or breathing cue');
        expect(_plan(k), isNot(anyOf([
          for (final o in builtInKeys())
            if (o.startsWith('gesture.') || o.startsWith('breath.')) _plan(o),
        ])), reason: '$k plays the same band plan as a gesture/breathing cue');
      }
    });
  });

  group('the ECG confusable set', () {
    test('one set holds all six ECG slots', () {
      final set = kConfusableSets.where((s) => s.contains('ecg.started'));
      expect(set, hasLength(1));
      expect(set.single.toSet(), _keys.toSet());
    });

    test('the defaults raise no "Feels like" warning against each other: '
        'different beat counts AND more than 0.5 s apart in length', () {
      final seqs = {for (final k in _keys) k: _spec(k).sequence};
      expect(similarityWarnings(seqs), isEmpty,
          reason: '${[for (final w in similarityWarnings(seqs)) '${w.slotA}~${w.slotB}'.toString()]}');
      final beats = {for (final s in seqs.values) patternBeats(s)};
      expect(beats, hasLength(6));
    });

    test('two ECG slots given the same rhythm ARE flagged (the set is live)',
        () {
      final a = _spec(kEcgCompleteKey).sequence;
      final w = similarityWarnings({kEcgCompleteKey: a, kEcgFailedKey: a});
      expect(w, hasLength(1));
      expect(w.single.reason, SimilarityReason.sameBeats);
    });
  });

  group('the slots', () {
    test('an "ECG" section holds the six, in order, each with its own label',
        () {
      final s = kHapticSlotSections.singleWhere((s) => s.id == 'ecg');
      expect(s.title, 'ECG');
      expect([for (final x in s.slots) x.key], _keys);
      final labels = [for (final x in s.slots) x.label];
      expect(labels.toSet(), hasLength(6));
      expect(labels.every((l) => l.trim().isNotEmpty), isTrue);
    });

    test('no slot key is listed twice across the sections', () {
      final all = [
        for (final s in kHapticSlotSections) for (final x in s.slots) x.key,
      ];
      expect(all.toSet().length, all.length);
    });

    test('they are cue slots: known, ECG, not gesture or breathing', () {
      for (final k in _keys) {
        expect(isEcgCueSlot(k), isTrue, reason: k);
        expect(isGestureCueSlot(k), isFalse);
        expect(isBreathCueSlot(k), isFalse);
        expect(isCueSlot(k), isTrue, reason: k);
        expect(isKnownSlot(k), isTrue, reason: k);
      }
      expect(isEcgCueSlot('gesture.start'), isFalse);
      expect(isEcgCueSlot('alert.health'), isFalse);
      expect(isEcgCueSlot('ecg.nonsense'), isFalse);
    });

    test('stored assignments accept them', () {
      final raw = encodeCueAssignments({
        kEcgFailedKey: 'a',
        kGestureStartKey: 'b',
        'alert.water': 'c',
        'ecg.nonsense': 'd',
      });
      expect(decodeCueAssignments(raw),
          {kEcgFailedKey: 'a', kGestureStartKey: 'b'});
    });

    test('resolveCuePatterns: the assigned pattern wins, else the store\'s '
        'own built-in', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final mine = store.add('Mine', _spec(kEcgStartedKey).sequence);
      final r = resolveCuePatterns(store, {kEcgCompleteKey: mine.id});
      expect(r[kEcgCompleteKey], same(mine.sequence));
      expect(r[kEcgFailedKey], same(store.bySystemKey(kEcgFailedKey)!.sequence));
      for (final k in _keys) {
        expect(r.containsKey(k), isTrue, reason: k);
      }
    });

    test('slotPatternLabel names the default, or the assigned pattern', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final mine = store.add('Soft', _spec(kEcgStartedKey).sequence);
      String label(String k, Map<String, String> assigned) => slotPatternLabel(
            k,
            patterns: store.list,
            alerts: const NotificationPrefs(),
            channels: const {},
            cueAssignments: assigned,
          );
      for (final k in _keys) {
        expect(label(k, const {}), _spec(k).name, reason: k);
      }
      expect(label(kEcgFailedKey, {kEcgFailedKey: mine.id}), 'Your: Soft');
    });
  });

  group('the pattern store', () {
    test('a fresh store seeds them, and an old store without them gains them '
        'without losing what it had', () {
      final fresh = HapticPatternStore.decodeSeeded(null);
      for (final k in _keys) {
        expect(fresh.bySystemKey(k), isNotNull, reason: k);
      }
      final all = jsonDecode(fresh.encode()) as List;
      final old = jsonEncode([
        for (final e in all)
          if (!'${(e as Map)['systemKey']}'.startsWith('ecg.')) e,
      ]);
      expect(HapticPatternStore.decode(old).bySystemKey(kEcgStartedKey), isNull);
      final seeded = HapticPatternStore.decodeSeeded(old);
      for (final k in _keys) {
        expect(seeded.bySystemKey(k), isNotNull, reason: k);
      }
      expect(seeded.list.length, fresh.list.length);
    });

    test('putting a built-in back resets it to its default', () {
      final store = HapticPatternStore.decodeSeeded(null);
      final p = store.bySystemKey(kEcgFailedKey)!;
      store.replace(p.id, _spec(kEcgStartedKey).sequence);
      store.resetToDefault(p.id);
      expect(store.bySystemKey(kEcgFailedKey)!.sequence.notes,
          _spec(kEcgFailedKey).sequence.notes);
    });
  });

  group('the Haptics screen', () {
    testWidgets('lists an ECG group on the Cues tab with the six slots and '
        'the pattern each plays', (t) async {
      await pumpHub(t, HubCalls(), slotNames: {
        for (final k in _keys) k: builtInDefault(k)?.name ?? '?',
      });
      await openHapticsTab(t, 'cues');
      final header = find.byWidgetPredicate(
          (w) => w is SettingsAccordion && w.title == 'ECG');
      expect(header, findsOneWidget);
      for (final k in _keys) {
        final row = find.byKey(ValueKey('haptic-slot:$k'));
        expect(row, findsOneWidget, reason: k);
        expect(find.descendant(of: header, matching: row), findsOneWidget,
            reason: '$k in its own group');
      }
      await openHapticsTab(t, 'alerts');
      expect(find.byKey(const ValueKey('haptic-slot:ecg.started')), findsNothing);
    });

    testWidgets('tapping an ECG slot opens the picker and choosing a pattern '
        'assigns it to that slot', (t) async {
      final c = HubCalls();
      await pumpHub(t, c, patterns: [userPattern('a', 'Morning nudge')]);
      await openHapticsTab(t, 'cues');
      await t.tap(find.byKey(const ValueKey('haptic-slot:ecg.complete')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pattern-picker')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pattern-picker-row:a')));
      await t.pumpAndSettle();
      expect(c.assigned, [(kEcgCompleteKey, 'a')]);
    });

    testWidgets('"Use on a slot" lists the ECG slots too', (t) async {
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
