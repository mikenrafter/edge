// 8AD, spec D: the Haptics hub (Settings > Band > Haptics) and the pattern
// pickers that Notifications and Band notifications open before the tap sheet.
// Pumped headless as the pure views, like the other settings tests.
//
// Contracts these tests pin that the spec leaves open:
//  - MoreSettingsView gets `VoidCallback? onHaptics`; its row is keyed
//    `settings-haptics`, titled "Haptics", sub "Your buzz patterns and band
//    safety", and sits after Gestures.
//  - HapticsSettingsView({patterns, usageOf, profile, allowLong, devMode,
//    commandsLeft, queued, bandConnected, onPlay, onBuzz, onAllowLong, onAdd,
//    onReplace, onRename, onDelete, onDeviceLab}); every callback is a plain
//    `void Function` (or Future<bool> for onPlay) so a test closure fits.
//    `usageOf(id)` is how many alerts and channels hold the pattern (A).
//  - SettingsAccordion titles: Patterns, Safety, Test, and Calibration only
//    when devMode.
//  - a pattern row is keyed `haptic-pattern:<id>`, shows the name, the notes
//    code and "N commands . ~X s" (middle dot), or "Taps" without notes. Its
//    sheet (`haptic-pattern-sheet`) has `haptic-action-preview|edit|rerecord|
//    rename|delete`; edit is absent without a profile. Delete asks in an
//    AlertDialog (Delete / Cancel) and names the usage as "Used by N alerts"
//    ("Used by 1 alert"; nothing for 0).
//  - rows `haptics-new-taps`, `haptics-new-notes` (absent without a profile),
//    `haptics-buzz`, `haptics-device-lab`; empty state text starts "No saved
//    patterns". The Safety checkbox is `haptics-allow-long`; the read-out is
//    "N of 30 band commands left in the last 2 minutes" and "Queue: N
//    waiting" / "Queue: empty".
//  - the name dialog is the editor's (see haptic_pattern_editor_test.dart).
//  - the picker is showPatternPicker(...) opening a sheet keyed
//    `pattern-picker`, rows `pattern-picker-default`, `pattern-picker-row:<id>`
//    (with a `pattern-picker-selected` check inside the current one),
//    `pattern-picker-record`, `pattern-picker-notes` (absent without a
//    profile). The tap sheet it opens offers `buzz-save-to-patterns` (a switch,
//    off) and then a `pattern-name-field`; that switch exists ONLY there.
//    The picker takes `onSaveNew`, which makes the stored pattern and returns
//    it, so the choice can carry its id.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/buzz_pattern.dart';
import 'package:openstrap_edge/ui2/profile/haptic_pattern_editor.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/pattern_picker.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../phase8/support/dart_source.dart';
import '../phase8/support/sections.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;
const _nameKey = ValueKey('pattern-name-field');
const _dup = 'A pattern with that name already exists.';
const _risk = 'May cause harm to your device. Use at your own risk.';

BuzzSequence _seq(String id, {String? notes = 'N4mf R1 N4mf'}) => BuzzSequence(
      const [0, 625],
      durationsMs: const [500, 500],
      notes: notes,
      profileId: notes == null ? null : _mg.id,
      profileVersion: notes == null ? null : _mg.version,
      bakedSteps: notes == null
          ? null
          : [
              BakedStep(effects: const [47], loop: 1, delayMs: 0),
              BakedStep(effects: const [14], loop: 1, delayMs: 300),
            ],
      patternId: id,
    );

SavedHapticPattern _pat(String id, String name, {String? notes}) =>
    SavedHapticPattern(
      id: id,
      name: name,
      sequence: _seq(id, notes: notes ?? 'N4mf R1 N4mf'),
    );

final _morning = _pat('a', 'Morning');
final _evening = _pat('b', 'Evening', notes: 'N2mf R2 N2mf');
final _tapsOnly = SavedHapticPattern(
  id: 'c',
  name: 'Taps only',
  sequence: _seq('c', notes: null),
);

Finder _inDialog(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

bool _checked(WidgetTester t, Key k) {
  final w = t.widget(find.byKey(k));
  if (w is CheckboxListTile) return w.value ?? false;
  if (w is Checkbox) return w.value ?? false;
  final inner = find.descendant(of: find.byKey(k), matching: find.byType(Checkbox));
  return t.widget<Checkbox>(inner.first).value ?? false;
}

Future<void> _takeHolds(WidgetTester t) async {
  final at = t.getCenter(find.text('Tap your pattern'));
  final a = await t.startGesture(at, pointer: 1);
  await t.pump(const Duration(milliseconds: 500));
  await a.up();
  await t.pump(const Duration(milliseconds: 125));
  final b = await t.startGesture(at, pointer: 2);
  await t.pump(const Duration(milliseconds: 500));
  await b.up();
  await t.pump(const Duration(milliseconds: 2100));
  await t.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

Future<void> _tapText(WidgetTester t, String text) async {
  await t.tap(find.text(text));
  await t.pumpAndSettle();
}

class _Calls {
  final added = <(String, BuzzSequence)>[];
  final replaced = <(String, BuzzSequence)>[];
  final renamed = <(String, String)>[];
  final deleted = <String>[];
  final played = <BuzzSequence>[];
  final allow = <bool>[];
  int buzzed = 0, lab = 0;
}

Widget _hub(
  _Calls c, {
  List<SavedHapticPattern> patterns = const [],
  HapticDeviceProfile? profile,
  bool allowLong = false,
  bool devMode = false,
  int commandsLeft = 30,
  int queued = 0,
  int Function(String id)? usageOf,
}) =>
    HapticsSettingsView(
      patterns: patterns,
      usageOf: usageOf ?? (_) => 0,
      profile: profile,
      allowLong: allowLong,
      devMode: devMode,
      commandsLeft: commandsLeft,
      queued: queued,
      bandConnected: true,
      onPlay: (s) async {
        c.played.add(s);
        return true;
      },
      onBuzz: () => c.buzzed++,
      onAllowLong: c.allow.add,
      onAdd: (n, s) => c.added.add((n, s)),
      onReplace: (id, s) => c.replaced.add((id, s)),
      onRename: (id, n) => c.renamed.add((id, n)),
      onDelete: c.deleted.add,
      onDeviceLab: () => c.lab++,
    );

void main() {
  group('Settings > Band > Haptics', () {
    testWidgets('the row sits after Gestures and opens the hub', (t) async {
      var opened = 0;
      await pumpTall(
        t,
        MoreSettingsView(
          onGestures: () {},
          onHaptics: () => opened++,
        ),
      );
      final row = find.byKey(const ValueKey('settings-haptics'));
      expect(row, findsOneWidget);
      expect(find.text('Haptics'), findsOneWidget);
      expect(
          find.descendant(of: section('Band'), matching: find.text('Haptics')),
          findsOneWidget);
      expect(find.text('Your buzz patterns and band safety'), findsOneWidget);
      final gestures = t.getTopLeft(find.text('Gestures')).dy;
      final haptics = t.getTopLeft(find.text('Haptics')).dy;
      final zone = t.getTopLeft(find.text('HR zone alert')).dy;
      expect(haptics, greaterThan(gestures));
      expect(haptics, lessThan(zone));
      await t.tap(row);
      expect(opened, 1);
    });

    test('the stateful Settings wires the row to the real hub', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      final state = codeOnly(bodyOf(src, 'class _MoreSettingsState'));
      expect(state, contains('onHaptics:'));
      expect(state, contains('HapticsSettings()'));
    });
  });

  group('the hub: groups', () {
    testWidgets('Patterns, Safety and Test; Calibration only in dev mode',
        (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, profile: _mg));
      expect(sectionTitles(t), ['Patterns', 'Safety', 'Test']);
      expect(find.byKey(const ValueKey('haptics-device-lab')), findsNothing);
      await pumpTall(t, _hub(c, profile: _mg, devMode: true));
      expect(sectionTitles(t), ['Patterns', 'Safety', 'Test', 'Calibration']);
      await expectAllSectionsExpanded(t, 'Haptics');
    });

    testWidgets('Test: "Buzz the band" is the device page\'s action',
        (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, profile: _mg));
      expect(find.text('Buzz the band'), findsOneWidget);
      await _tapKey(t, 'haptics-buzz');
      expect(c.buzzed, 1);
    });

    testWidgets('Calibration: Device lab opens the lab', (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, profile: _mg, devMode: true));
      expect(find.text('Device lab'), findsOneWidget);
      await _tapKey(t, 'haptics-device-lab');
      expect(c.lab, 1);
    });
  });

  group('the hub: Patterns', () {
    testWidgets('empty store: an empty-state text and the two new rows',
        (t) async {
      await pumpTall(t, _hub(_Calls(), profile: _mg));
      expect(find.textContaining('No saved patterns'), findsOneWidget);
      expect(find.byKey(const ValueKey('haptics-new-taps')), findsOneWidget);
      expect(find.byKey(const ValueKey('haptics-new-notes')), findsOneWidget);
      expect(find.text('New from taps'), findsOneWidget);
      expect(find.text('New from notes'), findsOneWidget);
    });

    testWidgets('rows show name, notes code and the command count and time',
        (t) async {
      await pumpTall(
          t, _hub(_Calls(), patterns: [_evening, _morning], profile: _mg));
      expect(find.textContaining('No saved patterns'), findsNothing);
      final row = find.byKey(const ValueKey('haptic-pattern:a'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Morning')),
          findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.textContaining('N4mf R1 N4mf')),
        findsOneWidget,
      );
      final line = t
          .widget<Text>(find.descendant(
              of: row, matching: find.textContaining('2 commands')))
          .data!;
      expect(line, matches(RegExp(r'2 commands · ~\d+(\.\d+)? s')));
      // The list keeps the order it is given.
      expect(t.getTopLeft(find.text('Evening')).dy,
          lessThan(t.getTopLeft(find.text('Morning')).dy));
    });

    testWidgets('a pattern with no notes says Taps', (t) async {
      await pumpTall(t, _hub(_Calls(), patterns: [_tapsOnly], profile: _mg));
      final row = find.byKey(const ValueKey('haptic-pattern:c'));
      // Exact: the name "Taps only" also contains the word.
      expect(find.descendant(of: row, matching: find.text('Taps')),
          findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('commands')),
          findsNothing);
    });

    testWidgets('tapping a row opens its sheet with the five actions',
        (t) async {
      await pumpTall(t, _hub(_Calls(), patterns: [_morning], profile: _mg));
      expect(find.byKey(const ValueKey('haptic-pattern-sheet')), findsNothing);
      await _tapKey(t, 'haptic-pattern:a');
      expect(find.byKey(const ValueKey('haptic-pattern-sheet')), findsOneWidget);
      for (final k in ['preview', 'edit', 'rerecord', 'rename', 'delete']) {
        expect(find.byKey(ValueKey('haptic-action-$k')), findsOneWidget,
            reason: k);
      }
      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Edit notes'), findsOneWidget);
      expect(find.text('Re-record'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('Preview plays the stored sequence', (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, patterns: [_morning], profile: _mg));
      await _tapKey(t, 'haptic-pattern:a');
      await _tapKey(t, 'haptic-action-preview');
      expect(c.played, [_morning.sequence]);
    });

    testWidgets('Rename: prefilled, saves the new name', (t) async {
      final c = _Calls();
      await pumpTall(
          t, _hub(c, patterns: [_morning, _evening], profile: _mg));
      await _tapKey(t, 'haptic-pattern:a');
      await _tapKey(t, 'haptic-action-rename');
      expect(t.widget<TextField>(find.byKey(_nameKey)).controller?.text,
          'Morning');
      await t.enterText(find.byKey(_nameKey), '  Dawn ');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(c.renamed, [('a', 'Dawn')]);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('Rename: another pattern\'s name is refused, case aside; '
        'its own case may change', (t) async {
      final c = _Calls();
      await pumpTall(
          t, _hub(c, patterns: [_morning, _evening], profile: _mg));
      await _tapKey(t, 'haptic-pattern:a');
      await _tapKey(t, 'haptic-action-rename');
      await t.enterText(find.byKey(_nameKey), 'EVENING');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(find.text(_dup), findsOneWidget);
      expect(c.renamed, isEmpty);
      await t.enterText(find.byKey(_nameKey), '');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(find.text('Give it a name.'), findsOneWidget);
      await t.enterText(find.byKey(_nameKey), 'morning');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(c.renamed, [('a', 'morning')]);
    });

    testWidgets('Delete: asks, names the usage, then deletes', (t) async {
      final c = _Calls();
      await pumpTall(
        t,
        _hub(c,
            patterns: [_morning],
            profile: _mg,
            usageOf: (id) => id == 'a' ? 3 : 0),
      );
      await _tapKey(t, 'haptic-pattern:a');
      await _tapKey(t, 'haptic-action-delete');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Used by 3 alerts'), findsWidgets);
      expect(c.deleted, isEmpty, reason: 'not before the confirm');
      await t.tap(_inDialog('Cancel'));
      await t.pumpAndSettle();
      expect(c.deleted, isEmpty);
      await _tapKey(t, 'haptic-pattern:a');
      await _tapKey(t, 'haptic-action-delete');
      await t.tap(_inDialog('Delete'));
      await t.pumpAndSettle();
      expect(c.deleted, ['a']);
    });

    testWidgets('Delete: one alert is singular', (t) async {
      await pumpTall(
          t,
          _hub(_Calls(),
              patterns: [_morning], profile: _mg, usageOf: (_) => 1));
      await _tapKey(t, 'haptic-pattern:a');
      await _tapKey(t, 'haptic-action-delete');
      expect(find.textContaining('Used by 1 alert'), findsWidgets);
      expect(find.textContaining('1 alerts'), findsNothing);
    });

    testWidgets('Delete: a pattern nobody uses says nothing about usage',
        (t) async {
      await pumpTall(t, _hub(_Calls(), patterns: [_morning], profile: _mg));
      await _tapKey(t, 'haptic-pattern:a');
      await _tapKey(t, 'haptic-action-delete');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Used by'), findsNothing);
    });

    testWidgets('Edit notes: the advanced editor starts from the notes and '
        'Save replaces the pattern', (t) async {
      final c = _Calls();
      await pumpTall(
          t, _hub(c, patterns: [_morning, _evening], profile: _mg));
      await _tapKey(t, 'haptic-pattern:a');
      await _tapKey(t, 'haptic-action-edit');
      expect(find.byType(HapticPatternEditorPage), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('pattern-editor-code'))).data,
          'N4mf R1 N4mf');
      // The key is the length in 16ths (len-4 is N4), so a 16th rest is len-1.
      await _tapKey(t, 'pattern-len-1');
      await _tapKey(t, 'pattern-editor-save');
      // An existing pattern has its name: no dialog.
      expect(find.byType(AlertDialog), findsNothing);
      expect(c.replaced, hasLength(1));
      expect(c.replaced.single.$1, 'a');
      expect(c.replaced.single.$2.notes, 'N4mf R1 N4mf R1');
      expect(c.added, isEmpty);
    });

    testWidgets('Re-record: the tap sheet; Save replaces the pattern',
        (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, patterns: [_morning], profile: _mg));
      await _tapKey(t, 'haptic-pattern:a');
      await _tapKey(t, 'haptic-action-rerecord');
      expect(find.byType(BuzzPatternSheet), findsOneWidget);
      await _takeHolds(t);
      await _tapText(t, 'Save');
      expect(c.replaced, hasLength(1));
      expect(c.replaced.single.$1, 'a');
      expect(c.replaced.single.$2.notes, 'N4mf R1 N4mf');
      expect(c.added, isEmpty);
    });

    testWidgets('New from taps: tap sheet, then a name', (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, patterns: [_morning], profile: _mg));
      await _tapKey(t, 'haptics-new-taps');
      expect(find.byType(BuzzPatternSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('buzz-save-to-patterns')), findsNothing,
          reason: 'only the picker offers that');
      await _takeHolds(t);
      await _tapText(t, 'Save');
      expect(find.byType(AlertDialog), findsOneWidget);
      await t.enterText(find.byKey(_nameKey), 'morning');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(find.text(_dup), findsOneWidget);
      expect(c.added, isEmpty);
      await t.enterText(find.byKey(_nameKey), 'Noon');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(c.added, hasLength(1));
      expect(c.added.single.$1, 'Noon');
      expect(c.added.single.$2.offsetsMs, [0, 625]);
      expect(c.added.single.$2.notes, 'N4mf R1 N4mf');
    });

    testWidgets('New from notes: the editor, empty; Save asks the name',
        (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, patterns: [_morning], profile: _mg));
      await _tapKey(t, 'haptics-new-notes');
      expect(find.byType(HapticPatternEditorPage), findsOneWidget);
      expect(find.byKey(const ValueKey('pattern-editor-code')), findsNothing);
      await _tapKey(t, 'pattern-len-4');
      await _tapKey(t, 'pattern-editor-save');
      await t.enterText(find.byKey(_nameKey), 'Short');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(c.added, hasLength(1));
      expect(c.added.single.$1, 'Short');
      expect(c.added.single.$2.notes, 'N4mf');
      expect(c.replaced, isEmpty);
    });

    testWidgets('a duplicate name in the editor is refused using the store\'s '
        'names', (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, patterns: [_morning], profile: _mg));
      await _tapKey(t, 'haptics-new-notes');
      await _tapKey(t, 'pattern-len-4');
      await _tapKey(t, 'pattern-editor-save');
      await t.enterText(find.byKey(_nameKey), 'MORNING');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(find.text(_dup), findsOneWidget);
      expect(c.added, isEmpty);
    });
  });

  group('the hub: on a 4.0 band (no profile)', () {
    testWidgets('no notes features; tap patterns still work', (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, patterns: [_tapsOnly]));
      expect(find.byKey(const ValueKey('haptics-new-notes')), findsNothing);
      expect(find.text('New from notes'), findsNothing);
      expect(find.byKey(const ValueKey('haptics-new-taps')), findsOneWidget);
      await _tapKey(t, 'haptic-pattern:c');
      expect(find.byKey(const ValueKey('haptic-action-edit')), findsNothing);
      expect(find.byKey(const ValueKey('haptic-action-preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('haptic-action-rerecord')), findsOneWidget);
      await _tapKey(t, 'haptic-action-rerecord');
      expect(find.byType(BuzzPatternSheet), findsOneWidget);
      await _takeHolds(t);
      await _tapText(t, 'Save');
      expect(c.replaced.single.$1, 'c');
      expect(c.replaced.single.$2.offsetsMs, [0, 625]);
    });
  });

  group('the hub: Safety', () {
    testWidgets('Allow long sequences is a checkbox with the risk caption',
        (t) async {
      await pumpTall(t, _hub(_Calls(), profile: _mg));
      expect(find.text('Allow long sequences'), findsOneWidget);
      expect(_checked(t, const ValueKey('haptics-allow-long')), isFalse);
      final caption = find.textContaining(_risk);
      expect(caption, findsOneWidget);
      // The limits that stay on are said in the same caption.
      expect(t.widget<Text>(caption).data, contains('still apply'));
      await pumpTall(t, _hub(_Calls(), profile: _mg, allowLong: true));
      expect(_checked(t, const ValueKey('haptics-allow-long')), isTrue);
    });

    testWidgets('turning it on asks first; Cancel changes nothing, Allow '
        'turns it on', (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, profile: _mg));
      await _tapKey(t, 'haptics-allow-long');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.textContaining(_risk)),
        findsOneWidget,
      );
      expect(c.allow, isEmpty);
      await t.tap(_inDialog('Cancel'));
      await t.pumpAndSettle();
      expect(c.allow, isEmpty);
      await _tapKey(t, 'haptics-allow-long');
      await t.tap(_inDialog('Allow'));
      await t.pumpAndSettle();
      expect(c.allow, [true]);
    });

    testWidgets('turning it off needs no confirmation', (t) async {
      final c = _Calls();
      await pumpTall(t, _hub(c, profile: _mg, allowLong: true));
      await _tapKey(t, 'haptics-allow-long');
      expect(find.byType(AlertDialog), findsNothing);
      expect(c.allow, [false]);
    });

    testWidgets('the ledger and the queue are read out', (t) async {
      await pumpTall(
          t, _hub(_Calls(), profile: _mg, commandsLeft: 22, queued: 3));
      expect(find.text('22 of 30 band commands left in the last 2 minutes'),
          findsOneWidget);
      expect(find.text('Queue: 3 waiting'), findsOneWidget);
      await pumpTall(t, _hub(_Calls(), profile: _mg));
      expect(find.text('30 of 30 band commands left in the last 2 minutes'),
          findsOneWidget);
      expect(find.text('Queue: empty'), findsOneWidget);
    });
  });

  group('the pattern picker', () {
    late List<BuzzSequence> chosen;
    late int defaults;
    late List<(String, BuzzSequence)> saved;

    Future<void> open(
      WidgetTester t, {
      List<SavedHapticPattern> patterns = const [],
      BuzzSequence? current,
      HapticDeviceProfile? profile,
    }) async {
      chosen = [];
      defaults = 0;
      saved = [];
      t.view.physicalSize = const Size(1170, 3000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showPatternPicker(
                  c,
                  patterns: patterns,
                  current: current,
                  profile: profile,
                  bandConnected: true,
                  onPlay: (_) async => true,
                  onDefault: () => defaults++,
                  onChoose: chosen.add,
                  onSaveNew: (name, s) async {
                    saved.add((name, s));
                    return SavedHapticPattern(
                      id: 'n1',
                      name: name,
                      sequence: s.copyWith(patternId: 'n1'),
                    );
                  },
                ),
                child: const Text('open picker'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open picker'));
      await t.pumpAndSettle();
    }

    testWidgets('lists Default, the stored patterns, Record new and Write '
        'notes, in that order', (t) async {
      await open(t, patterns: [_evening, _morning], profile: _mg);
      expect(find.byKey(const ValueKey('pattern-picker')), findsOneWidget);
      double y(String key) => t.getTopLeft(find.byKey(ValueKey(key))).dy;
      final order = [
        y('pattern-picker-default'),
        y('pattern-picker-row:b'),
        y('pattern-picker-row:a'),
        y('pattern-picker-record'),
        y('pattern-picker-notes'),
      ];
      expect(order, [...order]..sort());
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Record new…'), findsOneWidget);
      expect(find.text('Write notes…'), findsOneWidget);
      expect(find.text('Morning'), findsOneWidget);
    });

    testWidgets('the current stored pattern is the selected one', (t) async {
      await open(t,
          patterns: [_evening, _morning],
          current: _morning.sequence,
          profile: _mg);
      Finder mark(String id) => find.descendant(
            of: find.byKey(ValueKey('pattern-picker-row:$id')),
            matching: find.byKey(const ValueKey('pattern-picker-selected')),
          );
      expect(mark('a'), findsOneWidget);
      expect(mark('b'), findsNothing);
    });

    testWidgets('Write notes is for the MG only', (t) async {
      await open(t, patterns: [_tapsOnly]);
      expect(find.byKey(const ValueKey('pattern-picker-notes')), findsNothing);
      expect(find.text('Write notes…'), findsNothing);
      expect(find.byKey(const ValueKey('pattern-picker-record')), findsOneWidget);
    });

    testWidgets('Default clears to the registry default', (t) async {
      await open(t, patterns: [_morning], profile: _mg);
      await _tapKey(t, 'pattern-picker-default');
      expect(defaults, 1);
      expect(chosen, isEmpty);
      expect(find.byKey(const ValueKey('pattern-picker')), findsNothing);
    });

    testWidgets('choosing a stored pattern gives its snapshot with the id',
        (t) async {
      await open(t, patterns: [_evening, _morning], profile: _mg);
      await _tapKey(t, 'pattern-picker-row:b');
      expect(chosen, hasLength(1));
      final s = chosen.single;
      expect(s.patternId, 'b');
      expect(s.notes, 'N2mf R2 N2mf');
      expect(s.bakedSteps, _evening.sequence.bakedSteps);
      expect(s.offsetsMs, _evening.sequence.offsetsMs);
      expect(BuzzSequence.fromJson(s.toJson()).patternId, 'b');
      expect(defaults, 0);
      expect(find.byKey(const ValueKey('pattern-picker')), findsNothing);
    });

    testWidgets('Record new: the tap sheet; Save keeps the take as it is by '
        'default', (t) async {
      await open(t, patterns: [_morning], profile: _mg);
      await _tapKey(t, 'pattern-picker-record');
      expect(find.byType(BuzzPatternSheet), findsOneWidget);
      await _takeHolds(t);
      expect(find.text('Save to my patterns'), findsOneWidget);
      expect(t.widget<Switch>(find.byKey(const ValueKey('buzz-save-to-patterns'))).value,
          isFalse);
      expect(find.byKey(_nameKey), findsNothing);
      await _tapText(t, 'Save');
      expect(chosen, hasLength(1));
      expect(chosen.single.patternId, isNull);
      expect(chosen.single.notes, 'N4mf R1 N4mf');
      expect(saved, isEmpty);
    });

    testWidgets('Record new + Save to my patterns: a name, then the stored '
        'pattern is chosen with its id', (t) async {
      await open(t, patterns: [_morning], profile: _mg);
      await _tapKey(t, 'pattern-picker-record');
      await _takeHolds(t);
      await _tapKey(t, 'buzz-save-to-patterns');
      expect(find.byKey(_nameKey), findsOneWidget);
      // Empty, then a duplicate: refused, nothing stored or chosen.
      await _tapText(t, 'Save');
      expect(find.text('Give it a name.'), findsOneWidget);
      await t.enterText(find.byKey(_nameKey), 'morning');
      await _tapText(t, 'Save');
      expect(find.text(_dup), findsOneWidget);
      expect(saved, isEmpty);
      expect(chosen, isEmpty);
      await t.enterText(find.byKey(_nameKey), ' Fresh ');
      await _tapText(t, 'Save');
      expect(saved, hasLength(1));
      expect(saved.single.$1, 'Fresh');
      expect(saved.single.$2.notes, 'N4mf R1 N4mf');
      expect(chosen, hasLength(1));
      expect(chosen.single.patternId, 'n1');
      expect(chosen.single.notes, 'N4mf R1 N4mf');
    });

    testWidgets('Record new works on a 4.0 band too', (t) async {
      await open(t);
      await _tapKey(t, 'pattern-picker-record');
      await _takeHolds(t);
      await _tapText(t, 'Save');
      expect(chosen.single.offsetsMs, [0, 625]);
      expect(chosen.single.patternId, isNull);
    });

    testWidgets('Write notes: the editor; Save stores it under a name and '
        'chooses it', (t) async {
      await open(t, patterns: [_morning], profile: _mg);
      await _tapKey(t, 'pattern-picker-notes');
      expect(find.byType(HapticPatternEditorPage), findsOneWidget);
      await _tapKey(t, 'pattern-len-4');
      await _tapKey(t, 'pattern-editor-save');
      await t.enterText(find.byKey(_nameKey), 'Morning');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(find.text(_dup), findsOneWidget);
      expect(saved, isEmpty);
      await t.enterText(find.byKey(_nameKey), 'Written');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved.single.$1, 'Written');
      expect(saved.single.$2.notes, 'N4mf');
      expect(chosen, hasLength(1));
      expect(chosen.single.patternId, 'n1');
    });
  });

  group('the two screens open the picker, not the bare tap sheet', () {
    test('Notifications: _pickPattern', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      final body = codeOnly(bodyOf(src, 'void _pickPattern('));
      expect(body, contains('showPatternPicker('));
      expect(body, isNot(contains('showBuzzPatternSheet(')));
      expect(body, contains('onDefault:'));
      expect(body, contains('onChoose:'));
    });

    test('Band notifications: _pick (channel and per-app)', () {
      final src =
          File('lib/ui2/profile/band_notifications.dart').readAsStringSync();
      final body = codeOnly(bodyOf(src, 'void _pick('));
      expect(body, contains('showPatternPicker('));
      expect(body, isNot(contains('showBuzzPatternSheet(')));
      expect(body, contains('onDefault:'));
      expect(body, contains('onChoose:'));
    });

    test('the hub reads and writes the one store', () {
      final src =
          File('lib/ui2/profile/haptics_settings.dart').readAsStringSync();
      expect(codeOnly(src), contains('HapticPatternStore'));
    });
  });
}
