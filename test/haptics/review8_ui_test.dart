// External review 8, findings 7, 8 and 9 (the screen half).
//
// 7: "Plays as written." only when the plan's whole felt range is the
//    requested timing; otherwise the range line, even at cost 0.
// 8: the pattern name dialog enforces the store's 40-character limit, and the
//    editor / take stays open until persistence succeeds, with the error shown.
// 9: the hub row's duration is the baked plan's, not the fallback taps'.
//
// Only API that exists today is used, so each test fails on behaviour first.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/buzz_pattern.dart';
import 'package:openstrap_edge/ui2/profile/haptic_pattern_editor.dart';
import 'package:openstrap_edge/ui2/profile/haptic_plan_text.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/pattern_picker.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../phase8/support/sections.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;
const _nameKey = ValueKey('pattern-name-field');
const _tooLongName = 'Keep it under 40 characters.';
const _saveFailed = 'Could not save that pattern. Try again.';

HapticPlan _plan(String code) => compile(
  PatternTranscript.parseCode(code).entries,
  _mg,
  maxRuntimeMs: kMaxHapticRuntime.inMilliseconds,
)!;

Future<void> _pumpLines(WidgetTester t, HapticPlan plan) async {
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (c) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: hapticPlanLines(P.of(c), plan, tooLong: false),
        ),
      ),
    ),
  ));
}

Finder _inDialog(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

Future<void> _tapKey(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

Future<void> _editorSave(WidgetTester t) async {
  await _tapKey(t, 'pattern-len-4');
  await _tapKey(t, 'pattern-editor-save');
}

Future<void> _enterName(WidgetTester t, String name) async {
  await t.enterText(find.byKey(_nameKey), name);
  await t.tap(_inDialog('Save'));
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

void _view(WidgetTester t) {
  t.view.physicalSize = const Size(1170, 2800);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Widget _editor({
  required FutureOr<void> Function(String, BuzzSequence) onSave,
  List<String> names = const [],
}) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: HapticPatternEditorPage(
    profile: _mg,
    onPlay: (_) async => true,
    onSave: onSave,
    existingNames: names,
  ),
);

Widget _hub({
  List<SavedHapticPattern> patterns = const [],
  void Function(String, BuzzSequence)? onAdd,
}) => HapticsSettingsView(
  patterns: patterns,
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
  onAdd: onAdd ?? (n, s) {},
  onReplace: (id, s) {},
  onRename: (id, n) {},
  onDelete: (_) {},
  onDeviceLab: () {},
);

/// A stored pattern as the editor wrote it for [code]: the taps are the
/// compatibility fallback, the plan is what plays.
SavedHapticPattern _stored(String code, {int? runtimeMs}) {
  final plan = _plan(code);
  final taps = tapsFromNotes(
    PatternTranscript.parseCode(code).entries,
    unitMs: _mg.unitMs,
  );
  final seq = BuzzSequence.fromJson(jsonDecode(jsonEncode({
    'offsetsMs': taps.offsetsMs,
    'durationsMs': taps.durationsMs,
    'notes': code,
    'profileId': _mg.id,
    'profileVersion': _mg.version,
    'plan': [
      for (final s in plan.steps)
        {
          'effects': s.phrase.effects,
          'loop': s.phrase.loop,
          'delayMs': s.delayMs,
        },
    ],
    'patternId': 'g',
    'bakedRuntimeMs': ?runtimeMs,
  })));
  return SavedHapticPattern(id: 'g', name: 'Gappy', sequence: seq);
}

void main() {
  group('finding 7: "Plays as written." means the whole range', () {
    testWidgets('N3f on effect 14 is felt N3f to N4f: range line, no claim',
        (t) async {
      final plan = _plan('N3f');
      expect(plan.cost, 0);
      expect(plan.feltMin.join(' '), 'N3f');
      expect(plan.feltMax.join(' '), 'N4f');
      await _pumpLines(t, plan);
      expect(find.text('Plays as written.'), findsNothing);
      expect(find.textContaining('The band plays: N3f to N4f'), findsOneWidget);
    });

    testWidgets('a variable gap shows the range, not the claim', (t) async {
      final plan = _plan('N4ff R6 N4ff');
      expect(plan.exact, isTrue);
      await _pumpLines(t, plan);
      expect(find.text('Plays as written.'), findsNothing);
      expect(
        find.textContaining(
          'The band plays: N4ff R6 N4ff to N4ff R8 N4ff',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a plan felt exactly as asked still says so', (t) async {
      final plan = _plan('N4ff R12 R12 N4ff');
      expect(plan.feltMin.join(' '), plan.feltMax.join(' '));
      await _pumpLines(t, plan);
      expect(find.text('Plays as written.'), findsOneWidget);
      expect(find.textContaining('The band plays'), findsNothing);
    });
  });

  group('finding 8: the name limit and a save that fails', () {
    testWidgets('41 characters: a message, the dialog and editor stay',
        (t) async {
      _view(t);
      final saved = <(String, BuzzSequence)>[];
      await t.pumpWidget(_editor(onSave: (n, s) => saved.add((n, s))));
      await _editorSave(t);
      await _enterName(t, 'a' * 41);
      expect(find.text(_tooLongName), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(HapticPatternEditorPage), findsOneWidget);
      expect(saved, isEmpty);
    });

    testWidgets('40 characters is accepted', (t) async {
      _view(t);
      final saved = <(String, BuzzSequence)>[];
      await t.pumpWidget(_editor(onSave: (n, s) => saved.add((n, s))));
      await _editorSave(t);
      await _enterName(t, 'a' * 40);
      expect(find.text(_tooLongName), findsNothing);
      expect(saved.single.$1, 'a' * 40);
    });

    testWidgets('a throwing save keeps the editor open and says so; a retry '
        'works', (t) async {
      _view(t);
      var fail = true;
      final saved = <(String, BuzzSequence)>[];
      await t.pumpWidget(_editor(onSave: (n, s) {
        if (fail) throw StateError('disk full');
        saved.add((n, s));
      }));
      await _editorSave(t);
      await _enterName(t, 'Short');
      expect(find.byType(HapticPatternEditorPage), findsOneWidget);
      expect(find.text(_saveFailed), findsOneWidget);
      expect(find.text('Saved.'), findsNothing);
      expect(saved, isEmpty);

      fail = false;
      await _tapKey(t, 'pattern-editor-save');
      // The name is asked again, with what was typed.
      expect(
        t.widget<TextField>(find.byKey(_nameKey)).controller!.text,
        'Short',
      );
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(saved.single.$1, 'Short');
      expect(find.text(_saveFailed), findsNothing);
      expect(find.text('Saved.'), findsOneWidget);
    });

    testWidgets('an async rejection is handled the same way', (t) async {
      _view(t);
      await t.pumpWidget(_editor(onSave: (n, s) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw StateError('disk full');
      }));
      await _editorSave(t);
      await _enterName(t, 'Short');
      expect(find.byType(HapticPatternEditorPage), findsOneWidget);
      expect(find.text(_saveFailed), findsOneWidget);
    });

    testWidgets('hub, new from notes: a throwing add keeps the editor',
        (t) async {
      await pumpTall(t, _hub(onAdd: (n, s) => throw StateError('disk full')));
      await _tapKey(t, 'haptics-new-notes');
      await _editorSave(t);
      await _enterName(t, 'Short');
      expect(find.byType(HapticPatternEditorPage), findsOneWidget);
      expect(find.text(_saveFailed), findsOneWidget);
    });

    testWidgets('hub, new from taps: a throwing add asks the name again with '
        'the take kept', (t) async {
      var fail = true;
      final added = <(String, BuzzSequence)>[];
      await pumpTall(t, _hub(onAdd: (n, s) {
        if (fail) throw StateError('disk full');
        added.add((n, s));
      }));
      await _tapKey(t, 'haptics-new-taps');
      await _takeHolds(t);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      await _enterName(t, 'Noon');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(_saveFailed), findsOneWidget);
      expect(
        t.widget<TextField>(find.byKey(_nameKey)).controller!.text,
        'Noon',
      );
      fail = false;
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(added.single.$1, 'Noon');
      expect(added.single.$2.offsetsMs, [0, 625]);
    });

    group('the pattern picker', () {
      late List<BuzzSequence> chosen;

      Future<void> open(
        WidgetTester t, {
        required Future<SavedHapticPattern> Function(String, BuzzSequence)
        onSaveNew,
      }) async {
        _view(t);
        chosen = [];
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () => showPatternPicker(
                  c,
                  patterns: const [],
                  profile: _mg,
                  bandConnected: true,
                  onPlay: (_) async => true,
                  onDefault: () {},
                  onChoose: chosen.add,
                  onSaveNew: onSaveNew,
                ),
                child: const Text('open picker'),
              ),
            ),
          ),
        ));
        await t.tap(find.text('open picker'));
        await t.pumpAndSettle();
      }

      testWidgets('Write notes: a failing store keeps the editor open',
          (t) async {
        var fail = true;
        await open(t, onSaveNew: (n, s) async {
          if (fail) throw ArgumentError('taken');
          return SavedHapticPattern(
            id: 'n1',
            name: n,
            sequence: s.copyWith(patternId: 'n1'),
          );
        });
        await _tapKey(t, 'pattern-picker-notes');
        await _editorSave(t);
        await _enterName(t, 'Short');
        expect(find.byType(HapticPatternEditorPage), findsOneWidget);
        expect(find.text(_saveFailed), findsOneWidget);
        expect(chosen, isEmpty);

        fail = false;
        await _tapKey(t, 'pattern-editor-save');
        await t.tap(_inDialog('Save'));
        await t.pumpAndSettle();
        expect(find.byType(HapticPatternEditorPage), findsNothing);
        expect(chosen.single.patternId, 'n1');
      });

      testWidgets('Record new: a failing store keeps the take open',
          (t) async {
        var fail = true;
        await open(t, onSaveNew: (n, s) async {
          if (fail) throw ArgumentError('taken');
          return SavedHapticPattern(
            id: 'n1',
            name: n,
            sequence: s.copyWith(patternId: 'n1'),
          );
        });
        await _tapKey(t, 'pattern-picker-record');
        await _takeHolds(t);
        await _tapKey(t, 'buzz-save-to-patterns');
        await t.enterText(find.byKey(_nameKey), 'Short');
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(find.byType(BuzzPatternSheet), findsOneWidget);
        expect(find.text(_saveFailed), findsOneWidget);
        expect(chosen, isEmpty);

        fail = false;
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(find.byType(BuzzPatternSheet), findsNothing);
        expect(chosen.single.patternId, 'n1');
      });
    });
  });

  group('finding 9: the hub row says how long the baked plan plays', () {
    testWidgets('N4ff R12 R12 N4ff: 4 s, not the 0.5 s fallback taps',
        (t) async {
      final p = _stored('N4ff R12 R12 N4ff', runtimeMs: 4000);
      expect(p.sequence.playTime, const Duration(milliseconds: 500));
      await pumpTall(t, _hub(patterns: [p]));
      final row = find.byKey(const ValueKey('haptic-pattern:g'));
      expect(
        find.descendant(of: row, matching: find.text('2 commands · ~4.0 s')),
        findsOneWidget,
      );
    });

    testWidgets('an older save without the runtime is sized from the profile',
        (t) async {
      final p = _stored('N4ff R12 R12 N4ff');
      await pumpTall(t, _hub(patterns: [p]));
      final row = find.byKey(const ValueKey('haptic-pattern:g'));
      final line = t
          .widget<Text>(find.descendant(
              of: row, matching: find.textContaining('2 commands')))
          .data!;
      final secs = double.parse(RegExp(r'~(\d+\.\d)').firstMatch(line)!.group(1)!);
      expect(secs, greaterThanOrEqualTo(3.0), reason: line);
    });
  });
}
