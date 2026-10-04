// 8AI G4 (red): the Haptics screen layout, the slot rows and putting a saved
// pattern on a slot.
//
// Spec (laid out as sub-tabs since Oct 4, see test/haptics/haptics_tabs_test.dart;
// the groups below are the same, each on its tab): "Your patterns" and "Presets"
// (Patterns tab), then Safety / Test / Calibration unchanged (Band tab). The
// "Where patterns are used" slots, now on the Alerts, Activity and Cues tabs, list the
// haptic SLOTS grouped by section (Alerts, Gestures, Wake/Alarm, Workout, ...)
// under a header row each, no separator between sections (the accordion already
// draws a hairline above every row; a second one doubled it, Oct 4), and a link
// that opens the screen where the slot is used. A slot row shows the NAME of the pattern it plays ("Three
// pulses", "Your: Morning nudge"), never "N buzzes". A saved pattern, and a
// slot's own picker, can put a saved pattern on any slot; presets stay
// read-only.
//
// ASSUMED API (lib/ui2/profile/haptics_settings.dart; every new name is passed
// through Function.apply with a plain-view fallback, so a missing name fails
// the test that needs it):
//   HapticsSettingsView({... existing ...,
//     String Function(String slotKey) slotPatternName,
//     void Function(String sectionId) onOpenSlotScreen,
//     FutureOr<void> Function(String slotKey, SavedHapticPattern pattern)
//         onAssignToSlot})
//   * Slot keys are the systemKey scheme 8AF.6 uses: `alert.<ruleId>` for the
//     alert rules that play a pattern, `gesture.start|followUp|confirm`.
//     `slotPatternName(key)` is what the row says; the stateful HapticsSettings
//     builds it (preset name, or "Your: <name>" for a stored pattern of the
//     wearer's), so the view stays a pure function.
//   * Accordion titles and ids: "Your patterns" / `haptics_your_patterns`,
//     "Presets" / `haptics_presets`; each slot section a group of its own,
//     `haptics_slots_<sectionId>` ("Where patterns are used" is gone).
//   * Keys: a slot row `haptic-slot:<slotKey>`; a section header
//     NO in-list header or separator between two sections any more
//     (`haptic-slot-sep:` is gone, Oct 4; `haptic-slot-section:` went with the
//     sub-tabs); a section's link `haptic-slot-section-link:<sectionId>`, at the
//     bottom of its tab, calling `onOpenSlotScreen(sectionId)`. Section ids include `alerts` and
//     `gestures`; the Alerts section holds the alert rules, the Gestures
//     section the three gesture cues. Other sections (wake, workout) are free.
//   * A saved (or preset) pattern's sheet gets `haptic-action-assign` ("Use on
//     a slot"), which opens `haptic-assign-sheet` with one
//     `haptic-assign-slot:<slotKey>` row per slot; tapping one calls
//     `onAssignToSlot(slotKey, pattern)` and closes the sheet. Assigning never
//     calls onAdd/onReplace/onRename/onDelete (the store is not edited).
//   * Tapping a slot row opens the existing pattern picker (`pattern-picker`);
//     choosing `pattern-picker-row:<id>` calls `onAssignToSlot(slotKey,
//     thatPattern)`.
//
// Failure mode today: the screen has accordions Patterns / Safety / Test, no
// slot rows, no assign action.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../phase8/support/dart_source.dart';
import '../phase8/support/sections.dart';
import 'support/g45_support.dart';

final _mine = userPattern('a', 'Morning nudge');
final _mine2 = userPattern('b', 'Evening');
final _presetOne = presetPattern('sys.p1', 'One pulse', 'preset.one_pulse');
final _presetSos = presetPattern('sys.p2', 'SOS', 'preset.sos');

Finder _accordion(String title) => section(title);

Finder _in(String accordion, Finder f) =>
    find.descendant(of: _accordion(accordion), matching: f);

/// The tab each slot section is listed on.
const _tabOfSection = {
  'alerts': 'alerts',
  'apps': 'alerts',
  'activity': 'activity',
  'gestures': 'cues',
  'breathing': 'cues',
};

Future<void> _tapKey(WidgetTester t, String key) async {
  expect(find.byKey(ValueKey(key)), findsOneWidget, reason: 'missing: $key');
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  group('sub-tabs and their accordions', () {
    testWidgets('Your patterns and Presets on the Patterns tab, the unchanged '
        'Safety and Test on the Band tab', (t) async {
      await pumpHub(t, HubCalls(), patterns: [_mine, _presetOne]);
      expect(sectionTitles(t), ['Your patterns', 'Presets']);
      await openHapticsTab(t, 'band');
      expect(sectionTitles(t), ['Safety', 'Test']);
    });

    testWidgets('Calibration still comes last, in developer mode only', (t) async {
      await pumpHub(t, HubCalls(), devMode: true);
      expect(sectionTitles(t), ['Your patterns', 'Presets']);
      await openHapticsTab(t, 'band');
      expect(sectionTitles(t).first, 'Safety');
      expect(sectionTitles(t).last, 'Calibration');
    });

    testWidgets('the saved patterns are under Your patterns and the presets '
        'under Presets, not the other way round', (t) async {
      await pumpHub(t, HubCalls(),
          patterns: [_mine, _mine2, _presetOne, _presetSos]);
      for (final id in ['a', 'b']) {
        expect(_in('Your patterns', find.byKey(ValueKey('haptic-pattern:$id'))),
            findsOneWidget);
        expect(_in('Presets', find.byKey(ValueKey('haptic-pattern:$id'))),
            findsNothing);
      }
      for (final id in ['sys.p1', 'sys.p2']) {
        expect(_in('Presets', find.byKey(ValueKey('haptic-pattern:$id'))),
            findsOneWidget);
        expect(_in('Your patterns', find.byKey(ValueKey('haptic-pattern:$id'))),
            findsNothing);
      }
    });

    testWidgets('Your patterns keeps its empty state and the two ways to make '
        'one', (t) async {
      await pumpHub(t, HubCalls(), profile: kMg);
      expect(_in('Your patterns', find.textContaining('No saved patterns')),
          findsOneWidget);
      expect(_in('Your patterns', find.byKey(const ValueKey('haptics-new-taps'))),
          findsOneWidget);
      expect(_in('Your patterns', find.byKey(const ValueKey('haptics-new-notes'))),
          findsOneWidget);
    });

    testWidgets('Safety and Test content is unchanged, Safety before Test',
        (t) async {
      await pumpHub(t, HubCalls());
      await openHapticsTab(t, 'band');
      expect(_in('Safety', find.byKey(const ValueKey('haptics-allow-long'))),
          findsOneWidget);
      expect(_in('Safety', find.textContaining('band commands left')),
          findsOneWidget);
      expect(_in('Test', find.byKey(const ValueKey('haptics-buzz'))),
          findsOneWidget);
      expect(t.getTopLeft(_accordion('Test')).dy,
          greaterThan(t.getTopLeft(_accordion('Safety')).dy));
    });

    testWidgets('the accordions are remembered under stable ids', (t) async {
      await pumpHub(t, HubCalls());
      final ids = {for (final a in accordions(t)) a.title: a.id};
      expect(ids['Your patterns'], 'haptics_your_patterns');
      expect(ids['Presets'], 'haptics_presets');
      await openHapticsTab(t, 'band');
      expect([for (final a in accordions(t)) a.id],
          ['haptics_safety', 'haptics_test']);
    });
  });

  group('Where patterns are used (the slot tabs)', () {
    final names = {
      'alert.water': 'Three pulses',
      'alert.health': 'Your: Morning nudge',
      'gesture.start': 'SOS',
    };

    // Opens every slot tab in turn and calls [look] on each, with its id.
    Future<void> eachSlotTab(
        WidgetTester t, Future<void> Function(String tab) look) async {
      for (final tab in ['alerts', 'activity', 'cues']) {
        await openHapticsTab(t, tab);
        await look(tab);
      }
    }

    testWidgets('a row for every alert that plays a pattern and for each '
        'gesture cue', (t) async {
      await pumpHub(t, HubCalls(), slotNames: names);
      final found = <String>{};
      await eachSlotTab(t, (_) async {
        for (final k in [...alertSlotKeys(), ...kGestureSlotKeys]) {
          if (find.byKey(ValueKey('haptic-slot:$k')).evaluate().isNotEmpty) {
            found.add(k);
          }
        }
      });
      expect(found, {...alertSlotKeys(), ...kGestureSlotKeys});
    });

    testWidgets('a row shows the pattern NAME, never "N buzzes"', (t) async {
      await pumpHub(t, HubCalls(), slotNames: names);
      var checked = 0;
      await eachSlotTab(t, (_) async {
        for (final e in names.entries) {
          final row = find.byKey(ValueKey('haptic-slot:${e.key}'));
          if (row.evaluate().isEmpty) continue;
          checked++;
          expect(find.descendant(of: row, matching: find.text(e.value)),
              findsOneWidget,
              reason: e.key);
        }
        expect(find.textContaining(RegExp(r'\d+ buzz')), findsNothing);
        expect(find.textContaining(RegExp(r'\bbuzzes\b')), findsNothing);
      });
      expect(checked, names.length);
    });

    testWidgets('grouped by section, with no separator of its own between '
        'sections', (t) async {
      await pumpHub(t, HubCalls());
      await eachSlotTab(t, (_) async {
        expect(withKeyPrefix(t, 'haptic-slot-sep:'), isEmpty,
            reason: 'the accordion draws a hairline above every row; a '
                'hand-made divider next to it doubled the line');
        expect(withKeyPrefix(t, 'haptic-slot-section:'), isEmpty);
        for (final a in accordions(t)) {
          final drawn = _in(a.title, find.byType(Divider)).evaluate().length;
          expect(drawn, a.children.length,
              reason: '${a.title}: only the accordion\'s own one-per-row '
                  'hairlines');
        }
      });
      // Each row sits in its own section's group.
      await openHapticsTab(t, 'alerts');
      expect(_in('Alerts', find.byKey(const ValueKey('haptic-slot:alert.water'))),
          findsOneWidget);
      expect(
          _in('Apps and automation',
              find.byKey(const ValueKey('haptic-slot:alert.relay'))),
          findsOneWidget);
      expect(
          _in('Alerts', find.byKey(const ValueKey('haptic-slot:alert.relay'))),
          findsNothing);
      await openHapticsTab(t, 'cues');
      expect(
          _in('Gestures', find.byKey(const ValueKey('haptic-slot:gesture.start'))),
          findsOneWidget);
      expect(
          _in('Breathing', find.byKey(const ValueKey('haptic-slot:breath.inhale'))),
          findsOneWidget);
    });

    testWidgets('each section links to the screen where its slots are used, '
        'at the bottom of its tab', (t) async {
      final c = HubCalls();
      await pumpHub(t, c);
      await openHapticsTab(t, 'cues');
      await _tapKey(t, 'haptic-slot-section-link:gestures');
      await openHapticsTab(t, 'alerts');
      await _tapKey(t, 'haptic-slot-section-link:alerts');
      expect(c.openedSections, ['gestures', 'alerts']);
      for (final e in _tabOfSection.entries) {
        await openHapticsTab(t, e.value);
        final link = find.byKey(ValueKey('haptic-slot-section-link:${e.key}'));
        expect(link, findsOneWidget, reason: e.key);
        for (final k in alertSlotKeys()) {
          final row = find.byKey(ValueKey('haptic-slot:$k'));
          if (row.evaluate().isNotEmpty) {
            expect(t.getTopLeft(link).dy, greaterThan(t.getBottomLeft(row).dy),
                reason: '${e.key} link below $k');
          }
        }
      }
    });

    testWidgets('tapping a slot opens the picker; choosing a saved pattern '
        'puts it on that slot and edits nothing', (t) async {
      final c = HubCalls();
      await pumpHub(t, c,
          patterns: [_mine, _mine2, _presetOne], profile: kMg);
      await openHapticsTab(t, 'alerts');
      await _tapKey(t, 'haptic-slot:alert.water');
      expect(find.byKey(const ValueKey('pattern-picker')), findsOneWidget);
      await _tapKey(t, 'pattern-picker-row:b');
      expect(c.assigned, [('alert.water', 'b')]);
      expect(c.storeUntouched, isTrue);
    });

    testWidgets('the picker can also put a preset on a slot', (t) async {
      final c = HubCalls();
      await pumpHub(t, c, patterns: [_mine, _presetSos], profile: kMg);
      await openHapticsTab(t, 'cues');
      await _tapKey(t, 'haptic-slot:gesture.confirm');
      await _tapKey(t, 'pattern-picker-row:sys.p2');
      expect(c.assigned, [('gesture.confirm', 'sys.p2')]);
      expect(c.storeUntouched, isTrue);
    });
  });

  group('copy a saved pattern onto a slot', () {
    testWidgets('its sheet offers "Use on a slot"; the slot list takes the '
        'pattern and the store is not touched', (t) async {
      final c = HubCalls();
      await pumpHub(t, c, patterns: [_mine, _presetOne], profile: kMg);
      await _tapKey(t, 'haptic-pattern:a');
      expect(find.byKey(const ValueKey('haptic-action-assign')), findsOneWidget);
      await _tapKey(t, 'haptic-action-assign');
      expect(find.byKey(const ValueKey('haptic-assign-sheet')), findsOneWidget);
      // Every slot is offered, not just the alerts.
      for (final k in [...alertSlotKeys(), ...kGestureSlotKeys]) {
        expect(find.byKey(ValueKey('haptic-assign-slot:$k')), findsOneWidget,
            reason: k);
      }
      await _tapKey(t, 'haptic-assign-slot:gesture.start');
      expect(c.assigned, [('gesture.start', 'a')]);
      expect(c.storeUntouched, isTrue,
          reason: 'copying onto a slot does not rewrite the saved pattern');
      expect(find.byKey(const ValueKey('haptic-assign-sheet')), findsNothing,
          reason: 'the sheet closes once the pattern is assigned');
    });

    testWidgets('a preset can be put on a slot too, but stays read-only: '
        'no rename, no delete', (t) async {
      final c = HubCalls();
      await pumpHub(t, c, patterns: [_presetOne], profile: kMg);
      await _tapKey(t, 'haptic-pattern:sys.p1');
      expect(find.byKey(const ValueKey('haptic-action-assign')), findsOneWidget);
      expect(find.byKey(const ValueKey('haptic-action-rename')), findsNothing);
      expect(find.byKey(const ValueKey('haptic-action-delete')), findsNothing);
      await _tapKey(t, 'haptic-action-assign');
      await _tapKey(t, 'haptic-assign-slot:alert.water');
      expect(c.assigned, [('alert.water', 'sys.p1')]);
      expect(c.storeUntouched, isTrue);
    });
  });

  group('the stateful screen builds the slot rows from names, not counts', () {
    test('HapticsSettings passes slotPatternName, onOpenSlotScreen and '
        'onAssignToSlot, and never summarises a slot as "N buzzes"', () {
      final src = File('lib/ui2/profile/haptics_settings.dart')
          .readAsStringSync();
      final state = codeOnly(bodyOf(src, 'class _HapticsSettingsState'));
      expect(state, contains('slotPatternName:'));
      expect(state, contains('onOpenSlotScreen:'));
      expect(state, contains('onAssignToSlot:'));
      expect(codeOnly(src), isNot(contains('buzzSummary(')),
          reason: 'buzzSummary is the "N buzzes" text');
    });
  });
}
