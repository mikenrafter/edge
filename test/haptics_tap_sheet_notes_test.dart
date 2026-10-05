// 8AF.6 F.3 and F.4: tap recording -> edit as notes, from the same bottom sheet,
// and taps carry no pressure so they are length-priority only.
//
//  F.3  After a take on an MG the tap sheet shows "Edit as notes" (key
//       `buzz-edit-notes`). It opens the advanced editor seeded with the
//       take's notes; saving there returns to the same flow the sheet was
//       opened from (the picker or the hub) as a notes pattern. Without a
//       profile (a 4.0) there are no notes, so no such row.
//  F.4  Tap-derived notes use the "any loudness" dynamic (code "*"), not mf;
//       the tap sheet has no priority toggle; when the take is opened in the
//       editor it starts as "*" notes on "Prioritize rhythm" (the wearer may
//       then change notes, dynamics and priority there).
//
// Drives the real widgets (BuzzPatternSheet, the picker, the hub view, the
// editor page) headless, like buzz_pattern_notes_ui_test.dart.

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_priority.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/buzz_pattern.dart';
import 'package:openstrap_edge/ui2/profile/haptic_pattern_editor.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/pattern_picker.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/settings_sections.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

const _editKey = ValueKey('buzz-edit-notes');
const _codeKey = ValueKey('pattern-editor-code');
const _nameKey = ValueKey('pattern-name-field');
const _rhythmKey = ValueKey('pattern-editor-priority-rhythm');
const _dynamicsKey = ValueKey('pattern-editor-priority-dynamics');

/// What a take of two half-second holds 125 ms apart is heard as.
const _heard = 'N4* R1 N4*';

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 15000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
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

Future<void> _tapKey(WidgetTester t, Key k) async {
  await t.tap(find.byKey(k));
  await t.pumpAndSettle();
}

Finder _inDialog(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

/// The editor's Save, the name, and the dialog's Save.
Future<void> _saveFromEditor(WidgetTester t, String name) async {
  await _tapKey(t, const ValueKey('pattern-editor-save'));
  await t.enterText(find.byKey(_nameKey), name);
  await t.tap(_inDialog('Save'));
  await t.pumpAndSettle();
}

bool _selected(WidgetTester t, Key k) =>
    t.getSemantics(find.byKey(k)).flagsCollection.isSelected == Tristate.isTrue;

String _code(WidgetTester t) {
  final f = find.byKey(_codeKey);
  return f.evaluate().isEmpty ? '' : t.widget<Text>(f).data ?? '';
}

Widget _sheet({
  bool mg = true,
  ValueChanged<BuzzSequence>? onSave,
  Future<void> Function(String, BuzzSequence)? onSaveNamed,
}) =>
    Scaffold(
      body: BuzzPatternSheet(
        profile: mg ? _mg : null,
        bandConnected: true,
        onPlay: (_) async => true,
        onSave: onSave,
        patternNames: onSaveNamed == null ? null : const <String>[],
        onSaveNamed: onSaveNamed,
      ),
    );

void main() {
  group('F.4: tap-derived notes are any-loudness, length priority only', () {
    test('notesFromTaps writes every note as "*", never mf', () {
      final s = BuzzSequence(const [0, 625], durationsMs: const [500, 500]);
      final notes = notesFromTaps(s, unitMs: _mg.unitMs);
      expect(notes.join(' '), _heard);
      for (final e in notes.where((e) => e.note)) {
        expect(e.dynamic, PatternDynamic.any, reason: '$e');
      }
    });

    test('a quick tap and a long hold are "*" too', () {
      expect(notesFromTaps(BuzzSequence(const [0])).join(' '), 'N1*');
      expect(
        notesFromTaps(BuzzSequence(const [0], durationsMs: const [1500]))
            .join(' '),
        'N12*',
      );
    });

    testWidgets('a take is shown as "*" notes, and there is no priority '
        'toggle in the tap sheet', (t) async {
      await _pump(t, _sheet());
      await _takeHolds(t);
      expect(find.textContaining(_heard), findsOneWidget);
      expect(find.textContaining('N4mf'), findsNothing);
      expect(find.byKey(const ValueKey('pattern-editor-priority')),
          findsNothing);
      expect(find.text('Prioritize rhythm'), findsNothing);
      expect(find.text('Prioritize dynamics'), findsNothing);
    });

    testWidgets('Save stores "*" notes with the default (rhythm) priority',
        (t) async {
      final saved = <BuzzSequence>[];
      await _pump(t, _sheet(onSave: saved.add));
      await _takeHolds(t);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(saved.single.notes, _heard);
      expect(saved.single.priority, HapticPriority.rhythm);
      expect((saved.single.toJson() as Map).containsKey('priority'), isFalse,
          reason: 'rhythm is the default and is not written');
      expect(saved.single.bakedSteps, isNotEmpty);
    });
  });

  group('F.3: Edit as notes, from the tap sheet', () {
    testWidgets('no "Edit as notes" before a take', (t) async {
      await _pump(t, _sheet());
      expect(find.byKey(_editKey), findsNothing);
    });

    testWidgets('after a take on an MG there is one, labelled "Edit as '
        'notes"', (t) async {
      await _pump(t, _sheet());
      await _takeHolds(t);
      expect(find.byKey(_editKey), findsOneWidget);
      expect(find.text('Edit as notes'), findsOneWidget);
    });

    testWidgets('a band with no profile has no notes to edit', (t) async {
      await _pump(t, _sheet(mg: false));
      await _takeHolds(t);
      expect(find.byKey(_editKey), findsNothing);
      expect(find.text('Edit as notes'), findsNothing);
    });

    testWidgets('it opens the editor seeded with the take\'s notes, as "*" '
        'notes on Prioritize rhythm', (t) async {
      final h = t.ensureSemantics();
      await _pump(t, _sheet());
      await _takeHolds(t);
      await _tapKey(t, _editKey);
      expect(find.byType(HapticPatternEditorPage), findsOneWidget);
      final page =
          t.widget<HapticPatternEditorPage>(find.byType(HapticPatternEditorPage));
      expect(page.initial?.notes, _heard);
      expect(page.initial?.priority, HapticPriority.rhythm);
      expect(_code(t), _heard);
      expect(find.byKey(const ValueKey('pattern-editor-priority')),
          findsOneWidget);
      expect(_selected(t, _rhythmKey), isTrue);
      expect(_selected(t, _dynamicsKey), isFalse);
      h.dispose();
    });

    testWidgets('the editor is for editing: the notes can then be changed '
        'and the priority too', (t) async {
      final h = t.ensureSemantics();
      await _pump(t, _sheet());
      await _takeHolds(t);
      await _tapKey(t, _editKey);
      await _tapKey(t, _dynamicsKey);
      expect(_selected(t, _dynamicsKey), isTrue);
      expect(_code(t), _heard, reason: 'the notes are not touched');
      h.dispose();
    });

    testWidgets('saving in the editor hands the notes pattern to the same '
        'flow (onSaveNamed) and closes the editor', (t) async {
      final named = <(String, BuzzSequence)>[];
      await _pump(t, _sheet(onSaveNamed: (n, s) async => named.add((n, s))));
      await _takeHolds(t);
      await _tapKey(t, _editKey);
      await _saveFromEditor(t, 'From taps');
      expect(named, hasLength(1));
      expect(named.single.$1, 'From taps');
      expect(named.single.$2.notes, _heard);
      expect(named.single.$2.profileId, _mg.id);
      expect(named.single.$2.bakedSteps, isNotEmpty);
      expect(find.byType(HapticPatternEditorPage), findsNothing);
    });
  });

  group('F.3 through the real flows', () {
    testWidgets('picker > Record new > take > Edit as notes > Save: the '
        'pattern is stored as notes and chosen', (t) async {
      final stored = <(String, BuzzSequence)>[];
      final chosen = <BuzzSequence>[];
      await _pump(
        t,
        Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showPatternPicker(
                  c,
                  patterns: const [],
                  profile: _mg,
                  bandConnected: true,
                  onPlay: (_) async => true,
                  onDefault: () {},
                  onChoose: chosen.add,
                  onSaveNew: (name, s) async {
                    stored.add((name, s));
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
      );
      await t.tap(find.text('open picker'));
      await t.pumpAndSettle();
      await _tapKey(t, const ValueKey('pattern-picker-record'));
      await _takeHolds(t);
      await _tapKey(t, _editKey);
      expect(_code(t), _heard);
      await _saveFromEditor(t, 'Wrist tap');
      expect(stored.single.$1, 'Wrist tap');
      expect(stored.single.$2.notes, _heard);
      expect(chosen.single.patternId, 'n1');
      expect(chosen.single.notes, _heard);
      expect(find.byType(HapticPatternEditorPage), findsNothing);
    });

    testWidgets('hub > New from taps > take > Edit as notes > Save: added as '
        'a notes pattern', (t) async {
      final added = <(String, BuzzSequence)>[];
      await pumpTall(
        t,
        HapticsSettingsView(
          patterns: const [],
          usageOf: (_) => 0,
          profile: _mg,
          allowLong: false,
          devMode: false,
          commandsLeft: 30,
          queued: 0,
          bandConnected: true,
          onPlay: (_) async => true,
          onBuzz: () {},
          onAllowLong: (_) {},
          onAdd: (n, s) => added.add((n, s)),
          onReplace: (id, s) {},
          onRename: (id, n) {},
          onDelete: (_) {},
          onDeviceLab: () {},
        ),
      );
      await _tapKey(t, const ValueKey('haptics-new-taps'));
      await _takeHolds(t);
      await _tapKey(t, _editKey);
      expect(_code(t), _heard);
      await _saveFromEditor(t, 'Hub take');
      expect(added.single.$1, 'Hub take');
      expect(added.single.$2.notes, _heard);
      expect(find.byType(HapticPatternEditorPage), findsNothing);
    });
  });
}
