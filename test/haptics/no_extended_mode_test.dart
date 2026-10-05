// 8AF.6 addendum F.2 (red first): there is no "extended" mode any more. The
// full vocabulary, unstable phrases and gaps included, is the only mode, and
// stable parts stay preferred through a small cost per unstable one.
//
// This file avoids calling compile() without its `extended:` argument (the
// compile-level tests are in no_extended_compile_test.dart, which cannot build
// until the argument is gone). Everything here goes through planForTaps, the
// widgets and JSON, so each test fails on its own assertion.
//
// Contracts these tests pin that the spec leaves open:
//  - the tap sheet and the advanced editor show no switch, with or without a
//    haptic profile.
//  - planForTaps(s, profile) always considers unstable parts: two half-second
//    taps with a 125 ms gap (N4 R1 N4) play as two commands with the unstable
//    100 ms gap row, whatever BuzzSequence.fromJson was given.
//  - old JSON with 'extended': true parses and the flag is ignored: the
//    sequence equals the one without it, plans the same, and writes no
//    'extended' key. Old JSON without it stays byte-identical.
//  - the "timings may vary" line stays under a plan that uses an unstable
//    part, without the old "Extended haptics:" prefix.
//
// Existing tests that will need conscious updates are listed in the report
// that came with this file (every `extended:` argument and the buzz-extended
// switch tests).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/buzz_pattern.dart';
import 'package:openstrap_edge/ui2/profile/haptic_pattern_editor.dart';
import 'package:openstrap_edge/ui2/profile/haptic_plan_text.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

/// Two half-second taps, a 125 ms release gap: N4 R1 N4.
Map<String, Object?> _holdsJson({bool extended = false}) => {
      'offsetsMs': [0, 625],
      'durationsMs': [500, 500],
      if (extended) 'extended': true,
    };

BuzzSequence _holds({bool extended = false}) =>
    BuzzSequence.fromJson(_holdsJson(extended: extended));

List<String> _ids(HapticPlan p) => [for (final s in p.steps) s.phrase.id];

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 15000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

void main() {
  group('no switch in the tap sheet or the editor', () {
    testWidgets('the tap sheet on an MG', (t) async {
      await _pump(
        t,
        Scaffold(
          body: BuzzPatternSheet(
            profile: _mg,
            bandConnected: true,
            onPlay: (_) async => true,
            onSave: (_) {},
          ),
        ),
      );
      expect(find.byKey(const ValueKey('buzz-extended')), findsNothing);
      expect(find.text('Extended haptics opset'), findsNothing);
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('the tap sheet on a 4.0 (no profile)', (t) async {
      await _pump(
        t,
        Scaffold(
          body: BuzzPatternSheet(
            bandConnected: true,
            onPlay: (_) async => true,
            onSave: (_) {},
          ),
        ),
      );
      expect(find.byKey(const ValueKey('buzz-extended')), findsNothing);
      expect(find.text('Extended haptics opset'), findsNothing);
    });

    testWidgets('the advanced editor', (t) async {
      await _pump(
        t,
        HapticPatternEditorPage(
          profile: _mg,
          onPlay: (_) async => true,
          onSave: (a, b) {},
        ),
      );
      expect(find.byKey(const ValueKey('buzz-extended')), findsNothing);
      expect(find.text('Extended haptics opset'), findsNothing);
    });

    testWidgets('the advanced editor with a saved pattern that had the flag',
        (t) async {
      await _pump(
        t,
        HapticPatternEditorPage(
          initial: BuzzSequence.fromJson({
            ..._holdsJson(extended: true),
            'notes': 'N4mf R1 N4mf',
          }),
          name: 'Old',
          profile: _mg,
          onPlay: (_) async => true,
          onSave: (a, b) {},
        ),
      );
      expect(find.byKey(const ValueKey('buzz-extended')), findsNothing);
    });
  });

  group('the full vocabulary is always considered', () {
    test('N4 R1 N4 taps use the unstable 100 ms gap row, with no flag', () {
      final plan = planForTaps(_holds(), _mg)!;
      expect(plan.steps, hasLength(2));
      expect(plan.steps[1].delayMs, 100);
      expect(plan.steps[1].gapStable, isFalse);
      expect(plan.usesUnstable, isTrue);
    });

    test('the old flag changes nothing: the same plan with and without it',
        () {
      final off = planForTaps(_holds(), _mg)!;
      final on = planForTaps(_holds(extended: true), _mg)!;
      expect(_ids(on), _ids(off));
      expect([for (final s in on.steps) s.delayMs],
          [for (final s in off.steps) s.delayMs]);
      expect(on.cost, off.cost);
      expect(on.usesUnstable, off.usesUnstable);
    });

    test('a rhythm the stable vocabulary fits stays on stable parts', () {
      // One half-second tap: N4. buzz14 fits it exactly.
      final plan = planForTaps(
          BuzzSequence(const [0], durationsMs: const [500]), _mg)!;
      expect(plan.usesUnstable, isFalse);
      expect(plan.steps.single.phrase.stable, isTrue);
      // Two taps 750 ms apart (R6): the 300 ms row covers it.
      final apart = planForTaps(
          BuzzSequence(const [0, 1250], durationsMs: const [500, 500]), _mg)!;
      expect(apart.usesUnstable, isFalse);
      for (final s in apart.steps) {
        expect(s.phrase.stable, isTrue);
        expect(s.gapStable, isTrue);
      }
    });
  });

  group('JSON: old files parse, new ones never write the flag', () {
    test('old JSON with extended: true still parses', () {
      expect(() => _holds(extended: true), returnsNormally);
    });

    test('and is equal to the same rhythm without it', () {
      expect(_holds(extended: true), _holds());
      expect(_holds(extended: true).hashCode, _holds().hashCode);
    });

    test('toJson never writes extended, even for a rule that had it', () {
      final j = _holds(extended: true).toJson();
      // Held presses make the old map form (a plain list is for taps with no
      // hold); the flag is not in it.
      expect((j as Map).keys.toSet(), {'offsetsMs', 'durationsMs'});
      expect(jsonEncode(j), jsonEncode(_holds().toJson()));
    });

    test('with notes: the old flag is dropped, the rest is kept', () {
      final s = BuzzSequence.fromJson({
        ..._holdsJson(extended: true),
        'notes': 'N4mf R1 N4mf',
        'profileId': 'whoop-5.0-mg',
        'profileVersion': 1,
        'priority': 'dynamics',
      });
      final j = s.toJson() as Map;
      expect(j.containsKey('extended'), isFalse);
      expect(j['notes'], 'N4mf R1 N4mf');
      expect(j['profileId'], 'whoop-5.0-mg');
      expect(j['priority'], 'dynamics');
    });

    test('old JSON without the flag stays byte-identical', () {
      for (final raw in [
        '[0,500]',
        '{"offsetsMs":[0,500],"durationsMs":[100,100]}',
        '{"offsetsMs":[0,500],"durationsMs":[100,100],"notes":"N1mf R4 N1mf"}',
      ]) {
        expect(jsonEncode(BuzzSequence.fromJson(jsonDecode(raw)).toJson()), raw);
      }
    });

    test('a stored pattern and an alert rule that carry the flag read, and '
        'write it no more', () {
      final p = SavedHapticPattern.fromJson({
        'id': 'a',
        'name': 'A',
        'sequence': _holdsJson(extended: true),
      });
      expect(jsonEncode(p.toJson()), isNot(contains('extended')));
      final r = AlertRule.fromJson({
        'id': 'water',
        'destinations': 2,
        'buzzSequence': _holdsJson(extended: true),
      });
      expect(jsonEncode(r.toJson()), isNot(contains('extended')));
    });
  });

  group('feedback: timings may vary stays', () {
    Future<void> showLines(WidgetTester t, HapticPlan plan) => _pump(
          t,
          Scaffold(
            body: Builder(
              builder: (c) => Column(
                children: hapticPlanLines(P.of(c), plan, tooLong: false),
              ),
            ),
          ),
        );

    testWidgets('a plan with an unstable part says so, without the old '
        '"Extended haptics" prefix', (t) async {
      final plan = planForTaps(_holds(), _mg)!;
      expect(plan.usesUnstable, isTrue);
      await showLines(t, plan);
      expect(find.textContaining('timings may vary'), findsOneWidget);
      expect(find.textContaining('Extended haptics'), findsNothing);
    });

    testWidgets('a plan on stable parts does not', (t) async {
      final plan = planForTaps(
          BuzzSequence(const [0], durationsMs: const [500]), _mg)!;
      expect(plan.usesUnstable, isFalse);
      await showLines(t, plan);
      expect(find.textContaining('timings may vary'), findsNothing);
    });
  });
}
