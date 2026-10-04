// 8AI G4 (red): the notes editor's two modes, "Follow rhythm" (the default) and
// "Allow dynamics".
//
// Spec: in Follow rhythm the dynamics bar is hidden and every entered note is a
// `*` note (rhythm only); in Allow dynamics the bar shows. Switching modes
// never rewrites dynamics the user already set; it only governs new entry and
// visibility. The mode is persisted.
//
// ASSUMED API (lib/ui2/profile/haptic_pattern_editor.dart,
// HapticPatternEditorPage; no constructor change):
//   * A two-option control under the wheel in a row keyed
//     `pattern-editor-mode`: `pattern-editor-mode-follow` ("Follow rhythm")
//     and `pattern-editor-mode-dynamics` ("Allow dynamics"), the chosen one
//     marked with Semantics(selected: true) like the priority options.
//   * The dynamics bar is the seven `pattern-dyn-ff|f|mf|mp|p|pp|any` buttons
//     that exist today. In Follow rhythm none of them is in the tree.
//   * The mode is stored in the app prefs (lib/state/prefs.dart `Prefs`) under
//     the string key `haptics_editor_mode`, with the values `follow_rhythm`
//     (default when nothing is stored) and `allow_dynamics`. The page reads it
//     in initState and writes it on every switch, so a new page opens in the
//     last chosen mode.
//   * Follow rhythm: a note tapped in is written as `*` whatever sticky
//     dynamic was chosen earlier. Allow dynamics: it is written at the sticky
//     dynamic (mf until changed), as today.
//   * Switching does not rewrite any existing entry: the code line
//     (`pattern-editor-code`) is the same before and after.
//
// The first test must stay first: Prefs caches its SharedPreferences instance.
//
// Failure mode today: there is no mode control, the dynamics bar is always
// shown and a new note is written at mf.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/haptic_pattern_editor.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/g45_support.dart';

const _modeKey = 'haptics_editor_mode';
const _follow = 'follow_rhythm';
const _allow = 'allow_dynamics';
const _codeKey = ValueKey('pattern-editor-code');
const _bar = ['ff', 'f', 'mf', 'mp', 'p', 'pp', 'any'];

Future<void> _show(WidgetTester t, {BuzzSequence? initial}) async {
  t.view.physicalSize = const Size(390, 844) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: HapticPatternEditorPage(
      initial: initial,
      profile: kMg,
      onPlay: (_) async => true,
      onSave: (a, b) {},
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

String _code(WidgetTester t) {
  final f = find.byKey(_codeKey);
  return f.evaluate().isEmpty ? '' : t.widget<Text>(f).data ?? '';
}

BuzzSequence _withNotes(String notes) =>
    BuzzSequence(const [0], durationsMs: const [500], notes: notes);

bool _barShown() =>
    _bar.every((d) => find.byKey(ValueKey('pattern-dyn-$d')).evaluate().isNotEmpty);

bool _barHidden() =>
    _bar.every((d) => find.byKey(ValueKey('pattern-dyn-$d')).evaluate().isEmpty);

bool _selected(WidgetTester t, String key) {
  final f = find.byKey(ValueKey(key));
  if (f.evaluate().isEmpty) return false;
  return t.getSemantics(f).flagsCollection.isSelected.toBoolOrNull() ?? false;
}

/// Pick the mode through the control, as the wearer does.
Future<void> _choose(WidgetTester t, String mode) async {
  final key = mode == _follow
      ? 'pattern-editor-mode-follow'
      : 'pattern-editor-mode-dynamics';
  expect(find.byKey(ValueKey(key)), findsOneWidget,
      reason: 'the mode control is missing');
  await _tap(t, key);
}

void main() {
  // First on purpose: nothing stored yet, so this sees the default.
  group('the default', () {
    testWidgets('with nothing stored the editor opens in Follow rhythm: the '
        'dynamics bar is hidden and Follow rhythm is the chosen option',
        (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      await _show(t);
      expect(find.byKey(const ValueKey('pattern-editor-mode')), findsOneWidget);
      expect(find.text('Follow rhythm'), findsOneWidget);
      expect(find.text('Allow dynamics'), findsOneWidget);
      expect(_barHidden(), isTrue, reason: 'no dynamics button in Follow rhythm');
      expect(_selected(t, 'pattern-editor-mode-follow'), isTrue);
      expect(_selected(t, 'pattern-editor-mode-dynamics'), isFalse);
    });
  });

  group('Follow rhythm', () {
    setUp(() async {
      await Prefs.ensureLoaded();
      Prefs.setString(_modeKey, _follow);
    });

    testWidgets('every note entered is a `*` note', (t) async {
      await _show(t);
      await _tap(t, 'pattern-len-4'); // note
      await _tap(t, 'pattern-len-2'); // rest
      await _tap(t, 'pattern-len-4'); // note
      await _tap(t, 'pattern-len-1'); // rest
      await _tap(t, 'pattern-len-8'); // note
      expect(_code(t), 'N4* R2 N4* R1 N8*');
    });

    testWidgets('a dynamic chosen in an earlier session does not leak into '
        'new notes', (t) async {
      await _show(t);
      await _choose(t, _allow);
      await _tap(t, 'pattern-dyn-pp');
      await _choose(t, _follow);
      await _tap(t, 'pattern-len-2');
      expect(_code(t), 'N2*');
    });

    testWidgets('the dynamics bar is hidden and the rest of the footer stays',
        (t) async {
      await _show(t);
      expect(_barHidden(), isTrue);
      for (final k in [
        'pattern-len-1',
        'pattern-len-8',
        'pattern-dot',
        'pattern-kind',
        'pattern-delete',
        'pattern-editor-play',
        'pattern-editor-priority',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
    });

    testWidgets('opening a pattern that has dynamics keeps every one of them',
        (t) async {
      await _show(t, initial: _withNotes('N4ff R2 N2pp R1 N2mf'));
      expect(_code(t), 'N4ff R2 N2pp R1 N2mf');
    });
  });

  group('Allow dynamics', () {
    setUp(() async {
      await Prefs.ensureLoaded();
      Prefs.setString(_modeKey, _allow);
    });

    testWidgets('the dynamics bar shows, all seven buttons', (t) async {
      await _show(t);
      expect(_barShown(), isTrue);
      expect(_selected(t, 'pattern-editor-mode-dynamics'), isTrue);
    });

    testWidgets('a note is written at the chosen dynamic', (t) async {
      await _show(t);
      await _tap(t, 'pattern-len-4');
      await _tap(t, 'pattern-len-2');
      await _tap(t, 'pattern-dyn-ff');
      await _tap(t, 'pattern-len-4');
      expect(_code(t), 'N4mf R2 N4ff');
    });
  });

  group('switching modes', () {
    setUp(() async {
      await Prefs.ensureLoaded();
      Prefs.setString(_modeKey, _allow);
    });

    testWidgets('never rewrites the dynamics already set: to Follow rhythm and '
        'back, the code is the same', (t) async {
      await _show(t, initial: _withNotes('N4ff R2 N2pp R1 N2mf'));
      expect(_barShown(), isTrue);
      await _choose(t, _follow);
      expect(_code(t), 'N4ff R2 N2pp R1 N2mf');
      expect(_barHidden(), isTrue);
      await _choose(t, _allow);
      expect(_code(t), 'N4ff R2 N2pp R1 N2mf');
      expect(_barShown(), isTrue);
    });

    testWidgets('it only governs new entry: after switching to Follow rhythm '
        'the old dynamics stay and the new note is `*`', (t) async {
      await _show(t, initial: _withNotes('N4ff R2 N2pp'));
      await _choose(t, _follow);
      await _tap(t, 'pattern-len-1'); // a rest
      await _tap(t, 'pattern-len-2'); // a note
      expect(_code(t), 'N4ff R2 N2pp R1 N2*');
    });

    testWidgets('and after switching to Allow dynamics the new note takes the '
        'sticky dynamic while `*` notes already there stay `*`', (t) async {
      Prefs.setString(_modeKey, _follow);
      await _show(t, initial: _withNotes('N4* R2 N2*'));
      await _choose(t, _allow);
      expect(_code(t), 'N4* R2 N2*');
      await _tap(t, 'pattern-len-1');
      await _tap(t, 'pattern-len-2');
      expect(_code(t), 'N4* R2 N2* R1 N2mf');
    });

    testWidgets('a dynamic set on the cursor note in Allow dynamics survives a '
        'round trip through Follow rhythm', (t) async {
      await _show(t);
      await _tap(t, 'pattern-len-4');
      await _tap(t, 'pattern-dyn-ff'); // the cursor is past the note: sticky
      await _choose(t, _follow);
      await _choose(t, _allow);
      expect(_code(t), 'N4mf');
    });
  });

  group('the mode is persisted', () {
    setUp(() async {
      await Prefs.ensureLoaded();
      Prefs.setString(_modeKey, _follow);
    });

    testWidgets('choosing a mode writes it; a new editor opens in it',
        (t) async {
      await _show(t);
      await _choose(t, _allow);
      expect(Prefs.getString(_modeKey, ''), _allow);
      await _show(t); // a fresh page
      expect(_barShown(), isTrue, reason: 'it opens in Allow dynamics');
      expect(_selected(t, 'pattern-editor-mode-dynamics'), isTrue);
      await _choose(t, _follow);
      expect(Prefs.getString(_modeKey, ''), _follow);
      await _show(t);
      expect(_barHidden(), isTrue);
    });

    testWidgets('it is stored as a string under haptics_editor_mode',
        (t) async {
      await _show(t);
      await _choose(t, _allow);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(_modeKey), _allow);
    });
  });
}
