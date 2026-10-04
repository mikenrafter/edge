// 8AI G4 (red): the Haptics screen layout, the slot rows and putting a saved
// pattern on a slot.
//
// Spec: three accordions in order, "Your patterns", "Presets", "Where patterns
// are used", then Safety / Test / Calibration unchanged. The last one lists the
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
//     "Presets" / `haptics_presets`, "Where patterns are used" /
//     `haptics_where_used`.
//   * Keys: a slot row `haptic-slot:<slotKey>`; a section header
//     `haptic-slot-section:<sectionId>`; there is NO
//     separator between two sections (`haptic-slot-sep:` is gone, Oct 4);
//     a section's link `haptic-slot-section-link:<sectionId>` calling
//     `onOpenSlotScreen(sectionId)`. Section ids include `alerts` and
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
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;

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

const _where = 'Where patterns are used';

Future<void> _tapKey(WidgetTester t, String key) async {
  expect(find.byKey(ValueKey(key)), findsOneWidget, reason: 'missing: $key');
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  group('three accordions, in order', () {
    testWidgets('Your patterns, Presets, Where patterns are used, then the '
        'unchanged Safety and Test', (t) async {
      await pumpHub(t, HubCalls(), patterns: [_mine, _presetOne]);
      expect(sectionTitles(t), [
        'Your patterns',
        'Presets',
        _where,
        'Safety',
        'Test',
      ]);
    });

    testWidgets('Calibration still comes last, in developer mode only', (t) async {
      await pumpHub(t, HubCalls(), devMode: true);
      expect(sectionTitles(t).first, 'Your patterns');
      expect(sectionTitles(t).last, 'Calibration');
      expect(sectionTitles(t).take(3).toList(),
          ['Your patterns', 'Presets', _where]);
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
      expect(ids[_where], 'haptics_where_used');
    });
  });

  group('Where patterns are used', () {
    final names = {
      'alert.water': 'Three pulses',
      'alert.health': 'Your: Morning nudge',
      'gesture.start': 'SOS',
    };

    testWidgets('a row for every alert that plays a pattern and for each '
        'gesture cue', (t) async {
      await pumpHub(t, HubCalls(), slotNames: names);
      for (final k in [...alertSlotKeys(), ...kGestureSlotKeys]) {
        expect(_in(_where, find.byKey(ValueKey('haptic-slot:$k'))),
            findsOneWidget,
            reason: 'slot $k');
      }
    });

    testWidgets('a row shows the pattern NAME, never "N buzzes"', (t) async {
      await pumpHub(t, HubCalls(), slotNames: names);
      for (final e in names.entries) {
        expect(
          find.descendant(
              of: find.byKey(ValueKey('haptic-slot:${e.key}')),
              matching: find.text(e.value)),
          findsOneWidget,
          reason: e.key,
        );
      }
      expect(_in(_where, find.textContaining(RegExp(r'\d+ buzz'))),
          findsNothing);
      expect(_in(_where, find.textContaining(RegExp(r'\bbuzzes\b'))),
          findsNothing);
    });

    testWidgets('grouped by section, with no separator of its own between '
        'sections', (t) async {
      await pumpHub(t, HubCalls());
      final headers = withKeyPrefix(t, 'haptic-slot-section:').toList();
      final seps = withKeyPrefix(t, 'haptic-slot-sep:').toList();
      expect(headers.length, greaterThanOrEqualTo(2),
          reason: 'at least Alerts and Gestures');
      expect(seps, isEmpty,
          reason: 'the accordion draws a hairline above every row; a hand-made '
              'divider next to it doubled the line');
      final drawn = _in(_where, find.byType(Divider)).evaluate().length;
      expect(drawn, t.widget<SettingsAccordion>(_accordion(_where)).children.length,
          reason: 'only the accordion\'s own one-per-row hairlines');
      expect(find.byKey(const ValueKey('haptic-slot-section:alerts')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('haptic-slot-section:gestures')),
          findsOneWidget);
      // Each row sits under its own section's header.
      final alertsY =
          t.getTopLeft(find.byKey(const ValueKey('haptic-slot-section:alerts'))).dy;
      final gesturesY = t
          .getTopLeft(find.byKey(const ValueKey('haptic-slot-section:gestures')))
          .dy;
      final waterY =
          t.getTopLeft(find.byKey(const ValueKey('haptic-slot:alert.water'))).dy;
      final startY = t
          .getTopLeft(find.byKey(const ValueKey('haptic-slot:gesture.start')))
          .dy;
      if (alertsY < gesturesY) {
        expect(waterY, inInclusiveRange(alertsY, gesturesY));
        expect(startY, greaterThan(gesturesY));
      } else {
        expect(startY, inInclusiveRange(gesturesY, alertsY));
        expect(waterY, greaterThan(alertsY));
      }
    });

    testWidgets('each section links to the screen where its slots are used',
        (t) async {
      final c = HubCalls();
      await pumpHub(t, c);
      await _tapKey(t, 'haptic-slot-section-link:gestures');
      await _tapKey(t, 'haptic-slot-section-link:alerts');
      expect(c.openedSections, ['gestures', 'alerts']);
    });

    testWidgets('tapping a slot opens the picker; choosing a saved pattern '
        'puts it on that slot and edits nothing', (t) async {
      final c = HubCalls();
      await pumpHub(t, c,
          patterns: [_mine, _mine2, _presetOne], profile: kMg);
      await _tapKey(t, 'haptic-slot:alert.water');
      expect(find.byKey(const ValueKey('pattern-picker')), findsOneWidget);
      await _tapKey(t, 'pattern-picker-row:b');
      expect(c.assigned, [('alert.water', 'b')]);
      expect(c.storeUntouched, isTrue);
    });

    testWidgets('the picker can also put a preset on a slot', (t) async {
      final c = HubCalls();
      await pumpHub(t, c, patterns: [_mine, _presetSos], profile: kMg);
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
