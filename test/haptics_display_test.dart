// The Haptics screen's display overhaul (Settings > Band > Haptics):
//
//   1. A pattern row is the name and the staff, nothing else: no purple waves
//      box, no notes code, no "N commands . ~X s" line. The lock (built-ins)
//      and the chevron stay on the right and the padding is a little tighter.
//      The row's semantics still say the name, the length and the command
//      count (the text is gone from the screen, not from a screen reader).
//   2. The Presets are grouped in accordions by slot section, the order the
//      other tabs use: General (the ten presets), Alerts, Apps, Tasker,
//      Activity, Gestures, Breathing, Alarm, ECG. A group with nothing in it is
//      not shown. "Your patterns" stays first. A built-in's section is decided
//      by `builtInSectionId` (haptics/haptic_slots.dart) from its systemKey, the
//      one place that knows which slot section a key belongs to.
//   3. "New from taps" / "New from notes" are ONE row of two buttons pinned under
//      the nav bar and above the tabs, on every tab, not scrolling with the
//      page. "New from notes" is hidden without a profile (a 4.0).
//
// The buzz limit control is pinned in haptic_command_limit_ui_test.dart.
//
// New API pinned:
//   builtInSectionId(String systemKey) -> String          (haptic_slots.dart)
//   accordion ids of the Patterns tab: `haptics_presets_<sectionId>`
//     (`haptics_presets_general` for General); titles are the slot sections'
//     own ('Apps and automation', 'Alarm snooze'), 'General' for the ten.
//   `haptics-create-row`: the one row holding `haptics-new-taps` and
//     `haptics-new-notes`, a direct child of the screen's column, between the
//     NavBar and the SubTabs.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/buzz_pattern.dart';
import 'package:openstrap_edge/ui2/profile/haptic_pattern_editor.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/dart_source_lexical.dart';
import 'support/haptics_screen_support.dart';
import 'support/settings_sections.dart';

// A pattern of the wearer's: 'N4mf R4 N8mf' is 16 sixteenths, 2.0 s written,
// sent as two stored commands that play for [runtimeMs] (the plan's recorded
// length, which is what the row prints when it is known).
SavedHapticPattern _mine(String id, String name,
        {String notes = 'N4mf R4 N8mf', int runtimeMs = 2000}) =>
    SavedHapticPattern(
      id: id,
      name: name,
      sequence: BuzzSequence(
        const [0, 625],
        durationsMs: const [500, 500],
        notes: notes,
        profileId: kMg.id,
        profileVersion: kMg.version,
        bakedSteps: [
          BakedStep(effects: const [47], loop: 1, delayMs: 0),
          BakedStep(effects: const [14], loop: 1, delayMs: 300),
        ],
        bakedRuntimeMs: runtimeMs,
        patternId: id,
      ),
    );

// A built-in, as the store seeds it.
SavedHapticPattern _builtIn(String key) {
  final spec = builtInDefault(key)!;
  return SavedHapticPattern(
    id: systemPatternId(key),
    name: spec.name,
    sequence: spec.sequence,
    systemKey: key,
  );
}

Finder _row(String id) => find.byKey(ValueKey('haptic-pattern:$id'));

Finder _in(String accordion, Finder f) =>
    find.descendant(of: section(accordion), matching: f);

const _create = ValueKey('haptics-create-row');
const _taps = ValueKey('haptics-new-taps');
const _notes = ValueKey('haptics-new-notes');
const _tabs = ['patterns', 'alerts', 'activity', 'cues', 'band'];

// A pattern row has no text but: the name, the length, the dynamics.
Iterable<String> _texts(WidgetTester t, Finder row) => [
      for (final w in t.widgetList<Text>(
          find.descendant(of: row, matching: find.byType(Text))))
        w.data ?? '',
    ];

void main() {
  group('a pattern row is the name and the staff', () {
    final mine = _mine('a', 'Morning');
    final preset = _builtIn('preset.sos');

    testWidgets('its only texts are the name, the length and the dynamics',
        (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine], profile: kMg);
      expect(find.descendant(of: _row('a'), matching: find.text('Morning')),
          findsOneWidget);
      expect(_texts(t, _row('a')).toSet(), {'Morning', '~2.0s', 'mf'});
    });

    testWidgets('no notes code, no command count, no "Taps"', (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine], profile: kMg);
      final row = _row('a');
      expect(find.descendant(of: row, matching: find.textContaining('N4mf')),
          findsNothing);
      expect(find.descendant(of: row, matching: find.textContaining(RegExp(r'\bN\d'))),
          findsNothing);
      expect(find.descendant(of: row, matching: find.textContaining('command')),
          findsNothing);
      expect(find.descendant(of: row, matching: find.textContaining('·')),
          findsNothing);
      expect(find.descendant(of: row, matching: find.text('Taps')), findsNothing);
    });

    testWidgets('a tapped pattern (no notes) says neither "Taps" nor a count',
        (t) async {
      final taps = SavedHapticPattern(
        id: 'c',
        name: 'Taps only',
        sequence: BuzzSequence(const [0, 625], durationsMs: const [125, 125]),
      );
      await pumpHub(t, HubCalls(), patterns: [taps]);
      final shown = _texts(t, _row('c')).toSet();
      expect(shown, contains('Taps only'));
      expect(shown.where((x) => x == 'Taps' || x.contains('command')), isEmpty);
    });

    testWidgets('the length is the plan\'s recorded runtime when there is one, '
        'what compiling the notes plays when there is not', (t) async {
      final h = t.ensureSemantics();
      // 16 sixteenths written (2.0 s), but the plan plays for 2.5 s.
      final longer = _mine('l', 'Longer', runtimeMs: 2500);
      // No plan at all: the notes are compiled when sent, two 47s with a
      // 300 ms wait (up to 6 sixteenths) between: 4 + 6 + 4 = 1.75 s.
      final bare = SavedHapticPattern(
        id: 'b',
        name: 'Bare',
        sequence: BuzzSequence(const [0, 625],
            durationsMs: const [500, 500],
            notes: 'N4mf R4 N4mf',
            profileId: kMg.id,
            profileVersion: kMg.version),
      );
      await pumpHub(t, HubCalls(), patterns: [longer, bare], profile: kMg);
      expect(find.descendant(of: _row('l'), matching: find.text('~2.5s')),
          findsOneWidget);
      expect(find.descendant(of: _row('l'), matching: find.text('~2.0s')),
          findsNothing);
      expect(t.getSemantics(_row('l')).label, contains('2.5 seconds'));
      expect(find.descendant(of: _row('b'), matching: find.text('~1.8s')),
          findsOneWidget);
      expect(t.getSemantics(_row('b')).label, contains('1.75 seconds'));
      h.dispose();
    });

    testWidgets('on a 4.0 the same pattern is the length its taps play, not '
        'the MG plan\'s', (t) async {
      final h = t.ensureSemantics();
      // Taps hold 625 ms; the MG plan is stored as 1.0 s.
      final p = SavedHapticPattern(
        id: 'm',
        name: 'Made on an MG',
        sequence: BuzzSequence(const [0],
            durationsMs: const [625],
            notes: 'N8*',
            profileId: kMg.id,
            profileVersion: kMg.version,
            bakedSteps: [BakedStep(effects: const [47], loop: 3, delayMs: 0)],
            bakedRuntimeMs: 1000),
      );
      await pumpHub(t, HubCalls(), patterns: [p], profile: kMg);
      expect(find.descendant(of: _row('m'), matching: find.text('~1.0s')),
          findsOneWidget);
      expect(t.getSemantics(_row('m')).label, contains('1 second'));
      await pumpHub(t, HubCalls(), patterns: [p]);
      expect(find.descendant(of: _row('m'), matching: find.text('~0.6s')),
          findsOneWidget);
      expect(find.descendant(of: _row('m'), matching: find.text('~1.0s')),
          findsNothing);
      expect(t.getSemantics(_row('m')).label, contains('0.63 seconds'));
      expect(t.getSemantics(_row('m')).label, contains('1 command'));
      h.dispose();
    });

    testWidgets('a plan with no recorded runtime is sized from the profile, '
        'as the picker\'s detail line does', (t) async {
      // 47 (500 ms), 300 ms wait (up to 6 sixteenths), 14 (500 ms) = 1.75 s.
      final old = SavedHapticPattern(
        id: 'o',
        name: 'Old',
        sequence: BuzzSequence(const [0, 625],
            durationsMs: const [500, 500],
            notes: 'N4mf R4 N4mf',
            profileId: kMg.id,
            profileVersion: kMg.version,
            bakedSteps: [
              BakedStep(effects: const [47], loop: 1, delayMs: 0),
              BakedStep(effects: const [14], loop: 1, delayMs: 300),
            ]),
      );
      await pumpHub(t, HubCalls(), patterns: [old], profile: kMg);
      expect(find.descendant(of: _row('o'), matching: find.text('~1.8s')),
          findsOneWidget);
    });

    testWidgets('the purple waves box is gone', (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine, preset], profile: kMg);
      for (final id in ['a', preset.id]) {
        expect(find.descendant(of: _row(id), matching: find.byIcon(LucideIcons.waves)),
            findsNothing,
            reason: id);
        final p = P.of(t.element(_row(id)));
        expect(
            find.descendant(
                of: _row(id),
                matching: find.byWidgetPredicate((w) =>
                    w is Container &&
                    w.decoration is BoxDecoration &&
                    (w.decoration as BoxDecoration).color == p.wash(C.purple))),
            findsNothing,
            reason: id);
      }
    });

    testWidgets('the row shows the staff', (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine, preset], profile: kMg);
      for (final id in ['a', preset.id]) {
        expect(find.descendant(of: _row(id), matching: find.byType(HapticScore)),
            findsOneWidget);
      }
    });

    testWidgets('the staff is told the band so it can colour by command',
        (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine], profile: kMg);
      final score = t.widget<HapticScore>(
          find.descendant(of: _row('a'), matching: find.byType(HapticScore)));
      expect(score.profile, kMg);
    });

    testWidgets('a built-in keeps its lock, a pattern of yours has none, both '
        'keep the chevron', (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine, preset], profile: kMg);
      Finder icon(String id, IconData i) =>
          find.descendant(of: _row(id), matching: find.byIcon(i));
      expect(icon(preset.id, LucideIcons.lock), findsOneWidget);
      expect(icon('a', LucideIcons.lock), findsNothing);
      expect(icon(preset.id, LucideIcons.chevronRight), findsOneWidget);
      expect(icon('a', LucideIcons.chevronRight), findsOneWidget);
    });

    testWidgets('the lock and the chevron are at the right end of the row',
        (t) async {
      await pumpHub(t, HubCalls(), patterns: [preset], profile: kMg);
      final row = t.getRect(_row(preset.id));
      final lock = t.getRect(find.descendant(
          of: _row(preset.id), matching: find.byIcon(LucideIcons.lock)));
      final chevron = t.getRect(find.descendant(
          of: _row(preset.id), matching: find.byIcon(LucideIcons.chevronRight)));
      final staff = t.getRect(find.descendant(
          of: _row(preset.id), matching: find.byType(HapticScore)));
      expect(lock.left, lessThan(chevron.left));
      expect(chevron.right, closeTo(row.right, 1));
      expect(staff.right, lessThanOrEqualTo(lock.left + 0.5),
          reason: 'the staff does not run under the icons');
    });

    testWidgets('the vertical padding is tighter than the old 12', (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine], profile: kMg);
      final row = t.getRect(_row('a'));
      final name = t.getRect(
          find.descendant(of: _row('a'), matching: find.text('Morning')));
      expect(name.top - row.top, lessThanOrEqualTo(S.x2 + 0.5));
      final staff = t.getRect(
          find.descendant(of: _row('a'), matching: find.byType(HapticScore)));
      expect(row.bottom - staff.bottom, lessThanOrEqualTo(S.x2 + 0.5));
    });

    testWidgets('the row is still one tap target that opens the sheet',
        (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine], profile: kMg);
      await t.tap(_row('a'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('haptic-pattern-sheet')), findsOneWidget);
    });

    group('semantics', () {
      testWidgets('name, length and command count are spoken', (t) async {
        final h = t.ensureSemantics();
        await pumpHub(t, HubCalls(), patterns: [mine], profile: kMg);
        final label = t.getSemantics(_row('a')).label;
        expect(label, contains('Morning'));
        expect(label, matches(RegExp(r'\b2(\.0)? seconds\b')),
            reason: '16 sixteenths of 125 ms: $label');
        expect(label, contains('2 commands'));
        h.dispose();
      });

      testWidgets('the count is the one the budget counts', (t) async {
        final h = t.ensureSemantics();
        final sos = _builtIn('preset.sos');
        await pumpHub(t, HubCalls(), patterns: [sos], profile: kMg);
        final n = bandSequenceCommands(sos.sequence, kMg);
        expect(n, 5);
        expect(t.getSemantics(_row(sos.id)).label, contains('$n commands'));
        h.dispose();
      });

      testWidgets('a single command is "1 command"', (t) async {
        final h = t.ensureSemantics();
        final one = _builtIn('preset.one_pulse');
        await pumpHub(t, HubCalls(), patterns: [one], profile: kMg);
        final label = t.getSemantics(_row(one.id)).label;
        expect(label, contains('1 command'));
        expect(label, isNot(contains('1 commands')));
        h.dispose();
      });

      testWidgets('a 4.0 counts its taps as commands', (t) async {
        final h = t.ensureSemantics();
        final taps = SavedHapticPattern(
          id: 'c',
          name: 'Taps only',
          sequence: BuzzSequence(const [0, 625, 1250],
              durationsMs: const [125, 125, 125]),
        );
        await pumpHub(t, HubCalls(), patterns: [taps]);
        final label = t.getSemantics(_row('c')).label;
        expect(label, contains('Taps only'));
        expect(label, contains('3 commands'));
        expect(label, matches(RegExp(r'seconds?\b')));
        h.dispose();
      });
    });
  });

  group('builtInSectionId: the one place a key finds its section', () {
    test('the ten presets are General', () {
      for (final p in kPresets) {
        expect(builtInSectionId(p.$1), 'general', reason: p.$1);
      }
      expect(kGeneralSectionId, 'general');
    });

    test('every slot of every section maps to that section', () {
      for (final sec in kHapticSlotSections) {
        for (final slot in sec.slots) {
          expect(builtInSectionId(slot.key), sec.id, reason: slot.key);
        }
      }
    });

    test('the keys the screen names', () {
      const want = {
        'alert.health': 'alerts',
        'alert.relay': 'apps',
        'alert.tasker': 'apps',
        'alert.zone': 'activity',
        'alert.autoDetect': 'activity',
        'tasker.1': 'tasker',
        'tasker.6': 'tasker',
        'gesture.start': 'gestures',
        'gesture.failed': 'gestures',
        'breath.inhale': 'breathing',
        'breath.done': 'breathing',
        'alarm.snooze.confirm': 'alarm',
        'alarm.snooze.realarm': 'alarm',
        'ecg.started': 'ecg',
        'ecg.attention': 'ecg',
        'preset.sos': 'general',
      };
      want.forEach((k, v) => expect(builtInSectionId(k), v, reason: k));
    });

    test('every built-in key lands in General or in a section that exists',
        () {
      final ids = {for (final s in kHapticSlotSections) s.id, kGeneralSectionId};
      for (final k in [...builtInKeys(), ...alertSlotKeys()]) {
        expect(ids, contains(builtInSectionId(k)), reason: k);
      }
    });

    test('a key nobody knows is General, not lost', () {
      expect(builtInSectionId('nonsense.key'), 'general');
      expect(builtInSectionId(''), 'general');
    });

    test('the Patterns tab order is General, then the tabs\' own order', () {
      expect(kPresetSectionOrder, [
        'general',
        'alerts',
        'apps',
        'tasker',
        'activity',
        'gestures',
        'breathing',
        'alarm',
        'ecg',
      ]);
      expect({...kPresetSectionOrder},
          {kGeneralSectionId, for (final s in kHapticSlotSections) s.id});
    });
  });

  group('the Patterns tab: presets in accordions by section', () {
    // One of each section, plus a second gesture and the SOS preset, in an
    // order that is not the screen's.
    final all = [
      _builtIn('ecg.started'),
      _builtIn('alarm.snooze.confirm'),
      _builtIn('breath.inhale'),
      _builtIn('gesture.confirm'),
      _builtIn('gesture.start'),
      _builtIn('alert.zone'),
      _builtIn('tasker.2'),
      _builtIn('alert.relay'),
      _builtIn('alert.health'),
      _builtIn('preset.sos'),
      _builtIn('preset.one_pulse'),
      _mine('a', 'Morning'),
    ];
    const titles = [
      'Your patterns',
      'General',
      'Alerts',
      'Apps and automation',
      'Tasker',
      'Activity',
      'Gestures',
      'Breathing',
      'Alarm snooze',
      'ECG',
    ];

    testWidgets('Your patterns first, then General, then the sections in the '
        'order of the other tabs', (t) async {
      await pumpHub(t, HubCalls(), patterns: all, profile: kMg);
      expect(sectionTitles(t), titles);
    });

    testWidgets('there is no single "Presets" accordion any more', (t) async {
      await pumpHub(t, HubCalls(), patterns: all, profile: kMg);
      expect(section('Presets'), findsNothing);
    });

    testWidgets('each built-in sits in its own section and in no other',
        (t) async {
      await pumpHub(t, HubCalls(), patterns: all, profile: kMg);
      const home = {
        'sys.preset.sos': 'General',
        'sys.preset.one_pulse': 'General',
        'sys.alert.health': 'Alerts',
        'sys.alert.relay': 'Apps and automation',
        'sys.tasker.2': 'Tasker',
        'sys.alert.zone': 'Activity',
        'sys.gesture.start': 'Gestures',
        'sys.gesture.confirm': 'Gestures',
        'sys.breath.inhale': 'Breathing',
        'sys.alarm.snooze.confirm': 'Alarm snooze',
        'sys.ecg.started': 'ECG',
        'a': 'Your patterns',
      };
      for (final e in home.entries) {
        for (final title in titles) {
          expect(_in(title, _row(e.key)),
              title == e.value ? findsOneWidget : findsNothing,
              reason: '${e.key} in "$title"');
        }
      }
    });

    testWidgets('the accordions are remembered under stable ids', (t) async {
      await pumpHub(t, HubCalls(), patterns: all, profile: kMg);
      expect([for (final a in accordions(t)) a.id], [
        'haptics_your_patterns',
        'haptics_presets_general',
        'haptics_presets_alerts',
        'haptics_presets_apps',
        'haptics_presets_tasker',
        'haptics_presets_activity',
        'haptics_presets_gestures',
        'haptics_presets_breathing',
        'haptics_presets_alarm',
        'haptics_presets_ecg',
      ]);
    });

    testWidgets('a section with nothing in it is not shown', (t) async {
      await pumpHub(t, HubCalls(),
          patterns: [_builtIn('preset.one_pulse'), _builtIn('gesture.start'),
              _mine('a', 'Morning')],
          profile: kMg);
      expect(sectionTitles(t), ['Your patterns', 'General', 'Gestures']);
    });

    testWidgets('no built-ins: only Your patterns, nothing empty', (t) async {
      await pumpHub(t, HubCalls(), patterns: [_mine('a', 'Morning')],
          profile: kMg);
      expect(sectionTitles(t), ['Your patterns']);
      await pumpHub(t, HubCalls(), profile: kMg);
      expect(sectionTitles(t), ['Your patterns']);
      expect(find.textContaining('No saved patterns'), findsOneWidget);
    });

    testWidgets('Your patterns is shown with its empty state above the '
        'presets', (t) async {
      await pumpHub(t, HubCalls(),
          patterns: [_builtIn('preset.one_pulse')], profile: kMg);
      expect(sectionTitles(t), ['Your patterns', 'General']);
      expect(_in('Your patterns', find.textContaining('No saved patterns')),
          findsOneWidget);
    });

    testWidgets('General lists the ten in the presets\' own order, whatever '
        'order the store gives', (t) async {
      final presets = [for (final p in kPresets) _builtIn(p.$1)];
      await pumpHub(t, HubCalls(),
          patterns: presets.reversed.toList(), profile: kMg);
      expect(sectionTitles(t), ['Your patterns', 'General']);
      final ys = [
        for (final p in presets) t.getTopLeft(_row(p.id)).dy,
      ];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: presets[i].name);
      }
    });

    testWidgets('a section lists its slots in the order the other tabs do',
        (t) async {
      await pumpHub(t, HubCalls(),
          patterns: [_builtIn('gesture.failed'), _builtIn('gesture.confirm'),
              _builtIn('gesture.start'), _builtIn('gesture.followUp')],
          profile: kMg);
      final order = [
        for (final k in ['start', 'followUp', 'confirm', 'failed'])
          t.getTopLeft(_row('sys.gesture.$k')).dy,
      ];
      expect(order, [...order]..sort());
    });

    testWidgets('every real built-in has a home, none is lost', (t) async {
      final real = [for (final k in builtInKeys()) _builtIn(k)];
      await pumpHub(t, HubCalls(), patterns: real, profile: kMg);
      for (final p in real) {
        expect(_row(p.id), findsOneWidget, reason: p.systemKey);
        final home = kHapticSlotSections
            .where((s) => s.id == builtInSectionId(p.systemKey!))
            .map((s) => s.title)
            .followedBy(['General']).first;
        expect(_in(home, _row(p.id)), findsOneWidget, reason: p.systemKey);
      }
      expect(sectionTitles(t), [
        'Your patterns',
        'General',
        'Tasker',
        'Gestures',
        'Breathing',
        'Alarm snooze',
        'ECG',
      ]);
    });

    testWidgets('an unknown system key is listed under General', (t) async {
      await pumpHub(t, HubCalls(),
          patterns: [presetPattern('sys.x', 'Odd one', 'weird.key')],
          profile: kMg);
      expect(_in('General', _row('sys.x')), findsOneWidget);
    });

    testWidgets('the groups start open', (t) async {
      await pumpHub(t, HubCalls(), patterns: all, profile: kMg);
      await expectAllSectionsExpanded(t, 'Haptics > Patterns');
    });

    testWidgets('the other tabs are unchanged', (t) async {
      await pumpHub(t, HubCalls(), patterns: all, profile: kMg);
      await openHapticsTab(t, 'alerts');
      expect(sectionTitles(t), ['Alerts', 'Apps and automation', 'Tasker']);
      await openHapticsTab(t, 'cues');
      expect(sectionTitles(t), ['Gestures', 'Breathing', 'Alarm snooze', 'ECG']);
      await openHapticsTab(t, 'band');
      expect(sectionTitles(t), ['Safety', 'Test']);
    });
  });

  group('the create row: pinned under the nav bar, above the tabs', () {
    for (final tab in _tabs) {
      testWidgets('$tab tab: one row, two buttons, above the sub-tabs, below '
          'the nav bar', (t) async {
        await pumpHub(t, HubCalls(), patterns: [_mine('a', 'Morning')],
            profile: kMg);
        await openHapticsTab(t, tab);
        expect(find.byKey(_create), findsOneWidget);
        expect(find.byKey(_taps), findsOneWidget);
        expect(find.byKey(_notes), findsOneWidget);
        final row = t.getRect(find.byKey(_create));
        expect(t.getRect(find.byKey(_taps)).overlaps(row), isTrue);
        expect(row.contains(t.getRect(find.byKey(_taps)).center), isTrue);
        expect(row.contains(t.getRect(find.byKey(_notes)).center), isTrue);
        expect(row.bottom,
            lessThanOrEqualTo(t.getTopLeft(find.byType(SubTabs)).dy + 0.5),
            reason: 'above the tabs');
        expect(row.top,
            greaterThanOrEqualTo(t.getBottomLeft(find.byType(NavBar)).dy - 1),
            reason: 'under the nav bar');
      });
    }

    testWidgets('two buttons side by side in one row: same line, taps first',
        (t) async {
      await pumpHub(t, HubCalls(), profile: kMg);
      final a = t.getRect(find.byKey(_taps)), b = t.getRect(find.byKey(_notes));
      expect(a.center.dy, closeTo(b.center.dy, 1));
      expect(a.right, lessThanOrEqualTo(b.left + 0.5));
      expect(find.text('New from taps'), findsOneWidget);
      expect(find.text('New from notes'), findsOneWidget);
    });

    testWidgets('both are at least a tap target tall', (t) async {
      await pumpHub(t, HubCalls(), profile: kMg);
      expect(t.getSize(find.byKey(_taps)).height, greaterThanOrEqualTo(S.tap - 0.5));
      expect(t.getSize(find.byKey(_notes)).height, greaterThanOrEqualTo(S.tap - 0.5));
    });

    testWidgets('it is not part of the scrolling page', (t) async {
      await pumpHub(t, HubCalls(), profile: kMg);
      for (final tab in _tabs) {
        await openHapticsTab(t, tab);
        expect(find.byKey(_create), findsOneWidget, reason: tab);
        expect(
            find.descendant(
                of: find.byKey(ValueKey('haptics-tab-body:$tab')),
                matching: find.byKey(_create)),
            findsNothing,
            reason: tab);
      }
    });

    testWidgets('the old rows in Your patterns are gone', (t) async {
      await pumpHub(t, HubCalls(), profile: kMg);
      expect(_in('Your patterns', find.byKey(_taps)), findsNothing);
      expect(_in('Your patterns', find.byKey(_notes)), findsNothing);
      expect(find.text('Tap out a rhythm'), findsNothing);
      expect(find.text('Notes and rests, with dynamics'), findsNothing);
    });

    testWidgets('scrolling a long page leaves it where it is', (t) async {
      t.view.physicalSize = const Size(390 * 3, 520 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final many = [for (var i = 0; i < 14; i++) _mine('p$i', 'Pattern $i')];
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: hubView(HubCalls(), patterns: many, profile: kMg),
      ));
      await t.pumpAndSettle();
      final before = t.getTopLeft(find.byKey(_create));
      final listTop = t.getTopLeft(find.byKey(const ValueKey('haptics-tab-body:patterns')));
      await t.drag(find.byKey(const ValueKey('haptics-tab-body:patterns')),
          const Offset(0, -400));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('haptic-pattern:p0')).hitTestable(),
          findsNothing, reason: 'the page really scrolled');
      expect(t.getTopLeft(find.byKey(_create)), before);
      expect(t.getTopLeft(find.byKey(const ValueKey('haptics-tab-body:patterns'))),
          listTop);
    });

    testWidgets('without a profile (a 4.0) there is only "New from taps", on '
        'every tab', (t) async {
      await pumpHub(t, HubCalls());
      for (final tab in _tabs) {
        await openHapticsTab(t, tab);
        expect(find.byKey(_taps), findsOneWidget, reason: tab);
        expect(find.byKey(_notes), findsNothing, reason: tab);
        expect(find.text('New from notes'), findsNothing, reason: tab);
      }
    });

    testWidgets('the buttons work from any tab: taps opens the tap sheet, '
        'notes the editor', (t) async {
      await pumpHub(t, HubCalls(), profile: kMg);
      await openHapticsTab(t, 'band');
      await t.tap(find.byKey(_taps));
      await t.pumpAndSettle();
      expect(find.byType(BuzzPatternSheet), findsOneWidget);
      await t.tapAt(const Offset(5, 5)); // the barrier
      await t.pumpAndSettle();
      await openHapticsTab(t, 'cues');
      await t.tap(find.byKey(_notes));
      await t.pumpAndSettle();
      expect(find.byType(HapticPatternEditorPage), findsOneWidget);
    });

    testWidgets('narrow and large text: still one row, nothing overflows',
        (t) async {
      t.view.physicalSize = const Size(320 * 2, 900 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: hubView(HubCalls(),
            patterns: [_mine('a', 'Morning'), _builtIn('preset.sos')],
            profile: kMg),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final row = t.getRect(find.byKey(_create));
      for (final k in [_taps, _notes]) {
        final r = t.getRect(find.byKey(k));
        expect(r.left, greaterThanOrEqualTo(-0.5));
        expect(r.right, lessThanOrEqualTo(320.5));
        expect(row.contains(r.center), isTrue);
      }
      // The pattern rows too: nothing runs off the screen.
      for (final id in ['a', 'sys.preset.sos']) {
        final r = t.getRect(_row(id));
        expect(r.right, lessThanOrEqualTo(320.5), reason: id);
      }
    });
  });

  group('a dense pattern in a real row at 320 px', () {
    // Sixteen glyphs in a measure, eight of them writing a dynamic: more than
    // a phone row holds at the glyphs' own size.
    final dense = [
      ...List.filled(8, 'N1mf R1'),
      ...List.filled(8, 'N1f R1'),
    ].join(' ');
    SavedHapticPattern densePattern() {
      final e = PatternTranscript.parseCode(dense).entries;
      return SavedHapticPattern(
        id: 'd',
        name: 'Dense',
        sequence: tapsFromNotes(e).copyWith(
          notes: dense,
          profileId: kMg.id,
          profileVersion: kMg.version,
        ),
      );
    }

    for (final scale in const [1.0, 2.0]) {
      testWidgets('text x$scale: nothing overflows, clips or leaves the row',
          (t) async {
        t.view.physicalSize = const Size(320 * 2, 1400 * 2);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: hubView(HubCalls(), patterns: [densePattern()], profile: kMg),
        ));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        final row = t.getRect(_row('d'));
        expect(row.right, lessThanOrEqualTo(320.5));
        final score = find.descendant(of: _row('d'), matching: find.byType(HapticScore));
        final box = t.getRect(score);
        final staff = find.descendant(
            of: score, matching: find.byKey(const ValueKey('haptic-score-staff')));
        final paint = t.getRect(staff);
        final layout =
            (t.widget<CustomPaint>(staff).painter! as HapticScorePainter).layout;
        expect(layout.contentWidth, lessThanOrEqualTo(paint.width + 0.01));
        expect(layout.height, lessThanOrEqualTo(paint.height + 0.01));
        for (final g in layout.glyphs) {
          expect(g.x, greaterThanOrEqualTo(-0.01));
          expect(g.x + g.width, lessThanOrEqualTo(paint.width + 0.01));
        }
        for (final line in layout.lines) {
          expect(line.right, lessThanOrEqualTo(paint.width + 0.01));
        }
        for (final w in t.widgetList<Text>(
            find.descendant(of: score, matching: find.byType(Text)))) {
          final r = t.getRect(find.byWidget(w));
          expect(r.left, greaterThanOrEqualTo(box.left - 0.5), reason: w.data);
          expect(r.right, lessThanOrEqualTo(box.right + 0.5), reason: w.data);
          expect(r.top, greaterThanOrEqualTo(box.top - 0.5), reason: w.data);
          expect(r.bottom, lessThanOrEqualTo(box.bottom + 0.5), reason: w.data);
        }
        expect(paint.right, lessThanOrEqualTo(box.right + 0.5));
        // The glyphs really were too many for the row at their own size.
        expect((layout as dynamic).scale as double, lessThan(1.0));
      });
    }
  });

  group('source', () {
    test('the screen builds the create row between the nav bar and the tabs',
        () {
      final src = File('lib/ui2/profile/haptics_settings.dart').readAsStringSync();
      final raw =
          bodyOf(src, 'Widget build(BuildContext c) {\n    final p = P.of(c);');
      expect(raw, isNotEmpty);
      expect(raw.indexOf('_createRow('),
          inInclusiveRange(raw.indexOf('NavBar(') + 1, raw.indexOf('SubTabs(') - 1));
      expect(bodyOf(src, 'Widget _createRow(BuildContext c) {'),
          contains('haptics-create-row'));
    });
  });
}
