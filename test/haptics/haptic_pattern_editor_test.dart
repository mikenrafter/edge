// 8AD, spec C: the advanced notes editor (HapticPatternEditorPage) and the
// extraction of the probe's notation widgets into pattern_notation.dart.
//
// Contracts these tests pin that the spec leaves open:
//  - HapticPatternEditorPage takes the spec's parameters plus
//    `existingNames` (Iterable<String>, default empty), the names already in
//    the store, so the name dialog can refuse a duplicate.
//  - the entry model reuses the probe page's keys: `pattern-wheel`,
//    `pattern-len-1|2|4|8`, `pattern-dot`, `pattern-dyn-ff|f|mf|mp|p|pp`,
//    `pattern-kind` (text Note / Rest), `pattern-delete`. The entries read
//    back as a code line, a Text keyed `pattern-editor-code` that shows
//    "N4mf R1 N4mf" and is absent while there are no entries.
//  - the feedback under the wheel is the 8AC wording, from compile(notes,
//    profile, extended, maxRuntimeMs: 10 s) with the DEFAULT dynamicWeight
//    (notes carry dynamics, unlike taps). With allowLong the cap is lifted.
//  - Play (`pattern-editor-play`) hands onPlay a BuzzSequence with the notes,
//    the profile id/version, the baked plan and the switch. Save
//    (`pattern-editor-save`) hands onSave the same plus offsets and durations
//    derived from the notes. Both are inert while there are no notes, or the
//    plan is over the cap and allowLong is off. The footer controls, Play and
//    Save stay on screen at 360x640.
//  - "Start from taps" (`pattern-editor-from-taps`): when notes exist an
//    AlertDialog asks first, with buttons Replace and Cancel. Then a pad
//    (`pattern-editor-tap-pad`, text "Tap your pattern"; press, hold,
//    release) takes the rhythm; two seconds after the last release the pad
//    closes and the notes become notesFromTaps(take). The pad has no
//    `buzz-extended` switch of its own (the page's is the only one).
//  - the name dialog is an AlertDialog with a TextField keyed
//    `pattern-name-field` and buttons Save and Cancel; an empty name says
//    "Give it a name." and a duplicate (case-insensitive) says "A pattern
//    with that name already exists."; the dialog stays open on either.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/haptic_pattern_editor.dart';
import 'package:openstrap_edge/ui2/profile/pattern_notation.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;
const _codeKey = ValueKey('pattern-editor-code');
const _extKey = ValueKey('buzz-extended');
const _playKey = ValueKey('pattern-editor-play');
const _saveKey = ValueKey('pattern-editor-save');
const _tapsKey = ValueKey('pattern-editor-from-taps');
const _padKey = ValueKey('pattern-editor-tap-pad');
const _nameKey = ValueKey('pattern-name-field');
const _dyns = ['ff', 'f', 'mf', 'mp', 'p', 'pp'];

void _view(WidgetTester t, Size size) {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> _show(
  WidgetTester t, {
  BuzzSequence? initial,
  String? name,
  Future<bool> Function(BuzzSequence)? onPlay,
  void Function(String, BuzzSequence)? onSave,
  bool allowLong = false,
  List<String> existingNames = const [],
  Size size = const Size(390, 844),
}) async {
  _view(t, size);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: HapticPatternEditorPage(
      initial: initial,
      name: name,
      profile: _mg,
      onPlay: onPlay ?? (_) async => true,
      onSave: onSave ?? (a, b) {},
      allowLong: allowLong,
      existingNames: existingNames,
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester t, Key k) async {
  await t.tap(find.byKey(k));
  await t.pumpAndSettle();
}

Future<void> _tap(WidgetTester t, String key) => _tapKey(t, ValueKey(key));

/// The notes the page shows, '' while there are none.
String _code(WidgetTester t) {
  final f = find.byKey(_codeKey);
  return f.evaluate().isEmpty ? '' : t.widget<Text>(f).data ?? '';
}

BuzzSequence _withNotes(String notes) =>
    BuzzSequence(const [0], durationsMs: const [500], notes: notes);

HapticPlan? _plan(String code, {bool extended = false, bool long = false}) =>
    compile(
      PatternTranscript.parseCode(code).entries,
      _mg,
      extended: extended,
      maxRuntimeMs: long ? null : kMaxHapticRuntime.inMilliseconds,
    );

List<BakedStep> _baked(HapticPlan plan) => [
      for (final s in plan.steps)
        BakedStep(
          effects: s.phrase.effects,
          loop: s.phrase.loop,
          delayMs: s.delayMs,
        ),
    ];

String _notExact(HapticPlan plan) {
  final lo = plan.feltMin.join(' ');
  final hi = plan.feltMax.join(' ');
  return 'May not play exactly as written. The band plays: '
      '${lo == hi ? lo : '$lo to $hi'}.';
}

/// Every feedback line the 8AC wording gives for [plan], present or absent.
void _expectFeedback(HapticPlan plan) {
  expect(find.textContaining(plan.summary), findsOneWidget);
  expect(find.text('Plays as written.'),
      plan.asWritten ? findsOneWidget : findsNothing);
  expect(find.text(_notExact(plan)),
      plan.asWritten ? findsNothing : findsOneWidget);
  expect(find.text('Extended haptics: timings may vary unexpectedly.'),
      plan.usesUnstable ? findsOneWidget : findsNothing);
  expect(find.text('Pauses between buzzes can vary a little.'),
      plan.steps.length > 1 ? findsOneWidget : findsNothing);
  expect(find.textContaining('Too long for the band'), findsNothing);
}

const _tooLong = 'Too long for the band: keep it under 10 seconds.';

/// Eleven half notes and rests: 88 sixteenths, 11 s at 125 ms, over the cap.
Future<void> _enterOverCap(WidgetTester t) async {
  for (var i = 0; i < 11; i++) {
    await _tap(t, 'pattern-len-8');
  }
}

/// Two half-second holds with a 125 ms gap: N4mf R1 N4mf.
Future<void> _takeHolds(WidgetTester t) async {
  final at = t.getCenter(find.byKey(_padKey));
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

Finder _inDialog(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

void main() {
  group('the page', () {
    testWidgets('has the entry controls, the switch and the three actions',
        (t) async {
      await _show(t);
      for (final k in [
        'pattern-wheel',
        'pattern-len-1',
        'pattern-len-2',
        'pattern-len-4',
        'pattern-len-8',
        'pattern-dot',
        for (final d in _dyns) 'pattern-dyn-$d',
        'pattern-kind',
        'pattern-delete',
        'buzz-extended',
        'pattern-editor-play',
        'pattern-editor-from-taps',
        'pattern-editor-save',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.text('Extended haptics opset'), findsOneWidget);
    });

    testWidgets('has none of the probe-only parts', (t) async {
      await _show(t);
      for (final k in [
        'pattern-play',
        'pattern-rendition-a',
        'pattern-rendition-b',
        'pattern-metronome',
        'pattern-dynamic-tempo',
        'pattern-limit',
        'pattern-prev',
        'pattern-next',
        'pattern-finish',
      ]) {
        expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
      }
    });

    testWidgets('the footer, Play and Save stay on screen at 360x640 with a '
        'full list', (t) async {
      final full = _withNotes(List.filled(16, 'N1mf R1').join(' '));
      await _show(t, initial: full, size: const Size(360, 640));
      expect(_code(t).split(' '), hasLength(32));
      final screen = Offset.zero & const Size(360, 640);
      for (final k in [
        'pattern-len-1',
        'pattern-len-2',
        'pattern-len-4',
        'pattern-len-8',
        'pattern-dot',
        for (final d in _dyns) 'pattern-dyn-$d',
        'pattern-kind',
        'pattern-delete',
        'pattern-editor-play',
        'pattern-editor-save',
      ]) {
        final f = find.byKey(ValueKey(k));
        expect(f.hitTestable(), findsOneWidget, reason: '$k can be tapped');
        final rect = t.getRect(f);
        expect(
          screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
          isTrue,
          reason: '$k is fully on screen: $rect',
        );
      }
    });
  });

  group('the entry model', () {
    testWidgets('starts empty without initial notes', (t) async {
      await _show(t);
      expect(_code(t), '');
      expect(find.byKey(_codeKey), findsNothing);
    });

    testWidgets('starts from initial.notes, and the next tap appends',
        (t) async {
      await _show(t, initial: _withNotes('N4mf R2 N4ff'));
      expect(_code(t), 'N4mf R2 N4ff');
      await _tap(t, 'pattern-len-1');
      // The toggle follows the last entry: a rest comes next.
      expect(_code(t), 'N4mf R2 N4ff R1');
    });

    testWidgets('an initial without notes starts empty', (t) async {
      await _show(t, initial: BuzzSequence.defaultFor(2));
      expect(_code(t), '');
    });

    testWidgets('the toggle alternates note and rest after every tap',
        (t) async {
      await _show(t);
      await _tap(t, 'pattern-len-2');
      await _tap(t, 'pattern-len-1');
      await _tap(t, 'pattern-len-4');
      expect(_code(t), 'N2mf R1 N4mf');
      expect(find.byKey(const ValueKey('pattern-kind')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('pattern-kind')),
          matching: find.text('Rest'),
        ),
        findsOneWidget,
        reason: 'after a note the toggle reads Rest',
      );
    });

    testWidgets('the toggle can be overridden: two notes in a row, a rest '
        'first', (t) async {
      await _show(t);
      await _tap(t, 'pattern-kind');
      await _tap(t, 'pattern-len-2');
      expect(_code(t), 'R2');
      await _tap(t, 'pattern-len-2');
      await _tap(t, 'pattern-kind');
      await _tap(t, 'pattern-len-2');
      expect(_code(t), 'R2 N2mf N2mf');
    });

    testWidgets('lengths 16th, eighth, quarter and half', (t) async {
      await _show(t);
      for (final n in [1, 2, 4, 8]) {
        await _tap(t, 'pattern-len-$n');
      }
      expect(_code(t), 'N1mf R2 N4mf R8');
    });

    testWidgets('Dot makes the next entry 3/2 as long, once; a 16th cannot '
        'be dotted', (t) async {
      await _show(t);
      await _tap(t, 'pattern-dot');
      await _tap(t, 'pattern-len-1');
      expect(_code(t), '', reason: 'the 16th does nothing while Dot is on');
      await _tap(t, 'pattern-len-4');
      expect(_code(t), 'N6mf');
      await _tap(t, 'pattern-len-4');
      expect(_code(t), 'N6mf R4', reason: 'the dot cleared');
      await _tap(t, 'pattern-dot');
      await _tap(t, 'pattern-len-2');
      await _tap(t, 'pattern-dot');
      await _tap(t, 'pattern-len-8');
      expect(_code(t), 'N6mf R4 N3mf R12');
    });

    testWidgets('six dynamics, sticky, notes only', (t) async {
      await _show(t);
      for (final d in _dyns) {
        await _tap(t, 'pattern-dyn-$d');
        await _tap(t, 'pattern-len-2');
        // Rest in between, so the next one is a note again.
        await _tap(t, 'pattern-len-1');
      }
      expect(
        _code(t),
        'N2ff R1 N2f R1 N2mf R1 N2mp R1 N2p R1 N2pp R1',
      );
      // Sticky: the next note keeps pp.
      await _tap(t, 'pattern-len-4');
      expect(_code(t).split(' ').last, 'N4pp');
    });

    testWidgets('Delete removes the last entry, then the next, to empty',
        (t) async {
      await _show(t);
      await _tap(t, 'pattern-len-2');
      await _tap(t, 'pattern-len-1');
      await _tap(t, 'pattern-len-4');
      await _tap(t, 'pattern-delete');
      expect(_code(t), 'N2mf R1');
      await _tap(t, 'pattern-delete');
      await _tap(t, 'pattern-delete');
      expect(_code(t), '');
      // Nothing to delete is not an error.
      await _tap(t, 'pattern-delete');
      expect(_code(t), '');
    });

    testWidgets('holds at most the transcript maximum (32 entries)',
        (t) async {
      await _show(t);
      for (var i = 0; i < 34; i++) {
        await _tap(t, 'pattern-len-1');
      }
      expect(_code(t).split(' '), hasLength(PatternTranscript.maxEntries));
    });
  });

  group('the feedback under the wheel', () {
    testWidgets('nothing before there are notes', (t) async {
      await _show(t);
      expect(find.textContaining(RegExp(r'\d+ commands?')), findsNothing);
      expect(find.text('Plays as written.'), findsNothing);
      expect(find.textContaining('May not play exactly'), findsNothing);
      expect(find.textContaining('Too long for the band'), findsNothing);
    });

    testWidgets('shows what the band plays, in the 8AC words', (t) async {
      await _show(t, initial: _withNotes('N4mf R1 N4mf'));
      final plan = _plan('N4mf R1 N4mf')!;
      _expectFeedback(plan);
    });

    testWidgets('is recomputed on every edit', (t) async {
      await _show(t, initial: _withNotes('N4mf R1 N4mf'));
      _expectFeedback(_plan('N4mf R1 N4mf')!);
      await _tap(t, 'pattern-len-8');
      await _tap(t, 'pattern-len-2');
      expect(_code(t), 'N4mf R1 N4mf R8 N2mf');
      _expectFeedback(_plan('N4mf R1 N4mf R8 N2mf')!);
      await _tap(t, 'pattern-delete');
      await _tap(t, 'pattern-delete');
      _expectFeedback(_plan('N4mf R1 N4mf')!);
    });

    testWidgets('a dynamic change is a new plan', (t) async {
      await _show(t);
      await _tap(t, 'pattern-dyn-ff');
      await _tap(t, 'pattern-len-4');
      await _tap(t, 'pattern-len-1');
      await _tap(t, 'pattern-dyn-pp');
      await _tap(t, 'pattern-len-4');
      expect(_code(t), 'N4ff R1 N4pp');
      _expectFeedback(_plan('N4ff R1 N4pp')!);
    });

    testWidgets('the opset switch recompiles without any edit', (t) async {
      await _show(t, initial: _withNotes('N4mf R1 N4mf'));
      expect(t.widget<Switch>(find.byKey(_extKey)).value, isFalse);
      await _tapKey(t, _extKey);
      expect(t.widget<Switch>(find.byKey(_extKey)).value, isTrue);
      _expectFeedback(_plan('N4mf R1 N4mf', extended: true)!);
      expect(_code(t), 'N4mf R1 N4mf');
      await _tapKey(t, _extKey);
      _expectFeedback(_plan('N4mf R1 N4mf')!);
    });

    testWidgets('the switch starts from initial.extended', (t) async {
      await _show(
        t,
        initial: BuzzSequence(
          const [0],
          durationsMs: const [500],
          notes: 'N4mf R1 N4mf',
          extended: true,
        ),
      );
      expect(t.widget<Switch>(find.byKey(_extKey)).value, isTrue);
      _expectFeedback(_plan('N4mf R1 N4mf', extended: true)!);
    });

    testWidgets('over the 10 second cap: the 8AC message and no plan lines',
        (t) async {
      await _show(t);
      await _enterOverCap(t);
      expect(_plan(_code(t)), isNull, reason: 'the entries really are over');
      expect(find.text(_tooLong), findsOneWidget);
      expect(find.text('Plays as written.'), findsNothing);
      expect(find.textContaining('May not play exactly'), findsNothing);
    });

    testWidgets('with allowLong the cap message is gone and the plan shows',
        (t) async {
      await _show(t, allowLong: true);
      await _enterOverCap(t);
      final plan = _plan(_code(t), long: true);
      expect(plan, isNotNull);
      expect(find.text(_tooLong), findsNothing);
      expect(find.textContaining(plan!.summary), findsOneWidget);
    });
  });

  group('Play plays what the user has', () {
    testWidgets('onPlay gets the notes and the baked plan', (t) async {
      final played = <BuzzSequence>[];
      await _show(
        t,
        initial: _withNotes('N4mf R1 N4mf'),
        onPlay: (s) async {
          played.add(s);
          return true;
        },
      );
      await _tapKey(t, _playKey);
      final plan = _plan('N4mf R1 N4mf')!;
      expect(played, hasLength(1));
      expect(played.single.notes, 'N4mf R1 N4mf');
      expect(played.single.bakedSteps, _baked(plan));
      expect(played.single.profileId, _mg.id);
      expect(played.single.profileVersion, _mg.version);
      expect(played.single.extended, isFalse);
    });

    testWidgets('plays what is on the page now, with the switch', (t) async {
      final played = <BuzzSequence>[];
      await _show(
        t,
        onPlay: (s) async {
          played.add(s);
          return true;
        },
      );
      await _tap(t, 'pattern-dyn-ff');
      await _tap(t, 'pattern-len-4');
      await _tap(t, 'pattern-len-1');
      await _tap(t, 'pattern-len-4');
      await _tapKey(t, _extKey);
      await _tapKey(t, _playKey);
      final plan = _plan('N4ff R1 N4ff', extended: true)!;
      expect(played.single.notes, 'N4ff R1 N4ff');
      expect(played.single.extended, isTrue);
      expect(played.single.bakedSteps, _baked(plan));
    });

    testWidgets('does nothing while there are no notes', (t) async {
      final played = <BuzzSequence>[];
      await _show(t, onPlay: (s) async {
        played.add(s);
        return true;
      });
      await _tapKey(t, _playKey);
      expect(played, isEmpty);
    });

    testWidgets('does nothing over the cap, and again once the list is '
        'short enough', (t) async {
      final played = <BuzzSequence>[];
      await _show(t, onPlay: (s) async {
        played.add(s);
        return true;
      });
      await _enterOverCap(t);
      await _tapKey(t, _playKey);
      expect(played, isEmpty);
      // Dropping the last note leaves 72 sixteenths, 9 s.
      await _tap(t, 'pattern-delete');
      expect(_plan(_code(t)), isNotNull);
      await _tapKey(t, _playKey);
      expect(played, hasLength(1));
    });

    testWidgets('over the cap with allowLong it plays, with a plan baked '
        'without the cap', (t) async {
      final played = <BuzzSequence>[];
      await _show(
        t,
        allowLong: true,
        onPlay: (s) async {
          played.add(s);
          return true;
        },
      );
      await _enterOverCap(t);
      await _tapKey(t, _playKey);
      final plan = _plan(_code(t), long: true)!;
      expect(played, hasLength(1));
      expect(played.single.bakedSteps, _baked(plan));
      expect(played.single.notes, _code(t));
    });
  });

  group('Start from taps', () {
    testWidgets('with no notes it opens the pad at once and fills the notes',
        (t) async {
      await _show(t);
      await _tapKey(t, _tapsKey);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(_padKey), findsOneWidget);
      expect(find.text('Tap your pattern'), findsOneWidget);
      expect(find.byKey(_extKey), findsOneWidget,
          reason: 'the pad has no switch of its own');
      await _takeHolds(t);
      expect(find.byKey(_padKey), findsNothing, reason: 'the pad closed');
      expect(_code(t), 'N4mf R1 N4mf');
      expect(
        PatternTranscript.parseCode(_code(t)).entries,
        notesFromTaps(
          BuzzSequence(const [0, 625], durationsMs: const [500, 500]),
          unitMs: _mg.unitMs,
        ),
      );
      _expectFeedback(_plan('N4mf R1 N4mf')!);
    });

    testWidgets('with notes it confirms first; Cancel keeps them and opens '
        'no pad', (t) async {
      await _show(t, initial: _withNotes('N2mf R2 N2mf'));
      await _tapKey(t, _tapsKey);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(_padKey), findsNothing);
      await t.tap(_inDialog('Cancel'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(_padKey), findsNothing);
      expect(_code(t), 'N2mf R2 N2mf');
    });

    testWidgets('with notes, Replace opens the pad and the take replaces '
        'them', (t) async {
      await _show(t, initial: _withNotes('N2mf R2 N2mf'));
      await _tapKey(t, _tapsKey);
      await t.tap(_inDialog('Replace'));
      await t.pumpAndSettle();
      expect(find.byKey(_padKey), findsOneWidget);
      expect(_code(t), 'N2mf R2 N2mf', reason: 'not replaced before a take');
      await _takeHolds(t);
      expect(_code(t), 'N4mf R1 N4mf');
    });
  });

  group('Save', () {
    testWidgets('does nothing while there are no notes', (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(t, onSave: (n, s) => saved.add((n, s)));
      await _tapKey(t, _saveKey);
      expect(find.byType(AlertDialog), findsNothing);
      expect(saved, isEmpty);
    });

    testWidgets('does nothing over the cap without allowLong', (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(t, name: 'Long', onSave: (n, s) => saved.add((n, s)));
      await _enterOverCap(t);
      await _tapKey(t, _saveKey);
      expect(find.byType(AlertDialog), findsNothing);
      expect(saved, isEmpty);
    });

    testWidgets('over the cap with allowLong it saves', (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(
        t,
        name: 'Long',
        allowLong: true,
        onSave: (n, s) => saved.add((n, s)),
      );
      await _enterOverCap(t);
      await _tapKey(t, _saveKey);
      expect(saved, hasLength(1));
      expect(saved.single.$2.bakedSteps, _baked(_plan(_code(t), long: true)!));
    });

    testWidgets('a new pattern asks for a name; the empty name is refused',
        (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(t,
          initial: _withNotes('N4mf R1 N4mf'),
          onSave: (n, s) => saved.add((n, s)));
      await _tapKey(t, _saveKey);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(_nameKey), findsOneWidget);
      await t.enterText(find.byKey(_nameKey), '   ');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(find.text('Give it a name.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(saved, isEmpty);
    });

    testWidgets('a duplicate name is refused, whatever its case', (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(
        t,
        initial: _withNotes('N4mf R1 N4mf'),
        existingNames: const ['Morning'],
        onSave: (n, s) => saved.add((n, s)),
      );
      await _tapKey(t, _saveKey);
      await t.enterText(find.byKey(_nameKey), 'mORNING');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(find.text('A pattern with that name already exists.'),
          findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(saved, isEmpty);
    });

    testWidgets('Cancel in the name dialog saves nothing', (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(t,
          initial: _withNotes('N4mf R1 N4mf'),
          onSave: (n, s) => saved.add((n, s)));
      await _tapKey(t, _saveKey);
      await t.tap(_inDialog('Cancel'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(saved, isEmpty);
    });

    testWidgets('a good name is trimmed and onSave gets the notes, the '
        'profile, the baked plan and the rhythm of the notes', (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(t,
          initial: _withNotes('N4mf R1 N4mf'),
          onSave: (n, s) => saved.add((n, s)));
      await _tapKey(t, _extKey);
      await _tapKey(t, _saveKey);
      await t.enterText(find.byKey(_nameKey), '  Evening  ');
      await t.tap(_inDialog('Save'));
      await t.pumpAndSettle();
      expect(saved, hasLength(1));
      final (name, s) = saved.single;
      expect(name, 'Evening');
      expect(s.notes, 'N4mf R1 N4mf');
      expect(s.profileId, _mg.id);
      expect(s.profileVersion, _mg.version);
      expect(s.extended, isTrue);
      expect(s.bakedSteps, _baked(_plan('N4mf R1 N4mf', extended: true)!));
      // A note is a press as long as its length (4 x 125 ms), a rest a gap.
      expect(s.offsetsMs, [0, 625]);
      expect(s.durationsMs, [500, 500]);
      expect(BuzzSequence.fromJson(s.toJson()), s);
    });

    testWidgets('an existing pattern (name given) saves without asking',
        (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(
        t,
        initial: _withNotes('N4mf R1 N4mf'),
        name: 'Morning',
        existingNames: const ['Morning'],
        onSave: (n, s) => saved.add((n, s)),
      );
      await _tap(t, 'pattern-len-2');
      await _tapKey(t, _saveKey);
      expect(find.byType(AlertDialog), findsNothing);
      expect(saved, hasLength(1));
      expect(saved.single.$1, 'Morning');
      expect(saved.single.$2.notes, 'N4mf R1 N4mf R2');
    });

    testWidgets('rests only inside, a hold per note: N2 R2 N8 R4 N1',
        (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(t,
          initial: _withNotes('N2mf R2 N8mf R4 N1mf'),
          name: 'x',
          onSave: (n, s) => saved.add((n, s)));
      await _tapKey(t, _saveKey);
      final s = saved.single.$2;
      expect(s.offsetsMs, [0, 500, 2000]);
      expect(s.durationsMs, [250, 1000, 125]);
    });

    testWidgets('notes beyond the 8-press limit keep a minimal [0] fallback '
        'and the full notes and plan', (t) async {
      final saved = <(String, BuzzSequence)>[];
      final nine = List.filled(9, 'N1mf').join(' R1 ');
      await _show(t,
          initial: _withNotes(nine),
          name: 'x',
          onSave: (n, s) => saved.add((n, s)));
      await _tapKey(t, _saveKey);
      final s = saved.single.$2;
      expect(s.offsetsMs, [0]);
      expect(s.notes, nine);
      expect(s.bakedSteps, _baked(_plan(nine)!));
    });

    testWidgets('a rest longer than the 2000 ms gap limit does the same',
        (t) async {
      final saved = <(String, BuzzSequence)>[];
      await _show(t, name: 'x', onSave: (n, s) => saved.add((n, s)));
      await _tap(t, 'pattern-len-1');
      await _tap(t, 'pattern-dot');
      await _tap(t, 'pattern-len-8'); // a dotted half rest, 12
      await _tap(t, 'pattern-kind'); // another rest, no note between
      await _tap(t, 'pattern-len-8');
      await _tap(t, 'pattern-len-1');
      expect(_code(t), 'N1mf R12 R8 N1mf');
      await _tapKey(t, _saveKey);
      // 20 sixteenths of silence is 2500 ms: not one BuzzSequence gap.
      expect(saved.single.$2.offsetsMs, [0]);
      expect(saved.single.$2.notes, 'N1mf R12 R8 N1mf');
    });
  });

  group('pattern_notation.dart (the extraction)', () {
    testWidgets('exports the widgets the probe page and the editor share',
        (t) async {
      expect(kPatternUnitColours, hasLength(4));
      _view(t, const Size(390, 844));
      var tapped = 0;
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Column(children: [
            const PatternNotation(length: 4, note: true),
            PatternEntryRow(
              index: 0,
              note: true,
              length: 4,
              dynamic: PatternDynamic.mf,
              selected: false,
              playing: false,
            ),
            PatternLengthButton(
              key: const ValueKey('len'),
              length: 2,
              note: true,
              onTap: () => tapped++,
            ),
            PatternDotButton(
              key: const ValueKey('dot'),
              selected: true,
              onTap: () => tapped++,
            ),
            PatternDynamicButton(
              key: const ValueKey('dyn'),
              dynamic: PatternDynamic.ff,
              selected: false,
              dim: false,
              onTap: () => tapped++,
            ),
          ]),
        ),
      ));
      await t.pumpAndSettle();
      // The same symbol and dashes the probe's tests read.
      expect(find.byKey(const ValueKey('pattern-symbol')), findsWidgets);
      expect(find.byKey(const ValueKey('dash-4')), findsWidgets);
      expect(find.text('8th'), findsOneWidget);
      expect(find.text('Dot'), findsOneWidget);
      expect(find.text('ff'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('len')));
      await t.tap(find.byKey(const ValueKey('dot')));
      await t.tap(find.byKey(const ValueKey('dyn')));
      expect(tapped, 3);
    });

    test('the probe page uses them instead of private copies', () {
      final src =
          File('lib/ui2/profile/pattern_probe_page.dart').readAsStringSync();
      expect(src, contains("import 'pattern_notation.dart'"));
      for (final gone in [
        'class _Notation',
        'class _SymbolPainter',
        'class _EntryRow',
        'class _LengthButton',
        'class _DotButton',
        'class _DynamicButton',
      ]) {
        expect(src, isNot(contains(gone)), reason: '$gone moved out');
      }
    });

    test('the editor uses them too, not a second copy', () {
      final src =
          File('lib/ui2/profile/haptic_pattern_editor.dart').readAsStringSync();
      expect(src, contains("import 'pattern_notation.dart'"));
      expect(src, isNot(contains('class _SymbolPainter')));
    });
  });
}
