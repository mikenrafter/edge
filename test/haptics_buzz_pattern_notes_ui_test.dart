// The rule editor on a WHOOP MG band: after a take it shows the notes it
// heard and what the band will play (one calm line), and Save
// stores the notes, the profile and the baked plan. The
// full vocabulary is the only mode, so there is no switch. The
// no-profile text is in test/haptics_buzz_pattern_controls_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/buzz_pattern.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 15000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

Widget _sheet({
  Future<bool> Function(BuzzSequence)? onPlay,
  ValueChanged<BuzzSequence>? onSave,
}) =>
    Scaffold(
      body: BuzzPatternSheet(
        profile: _mg,
        bandConnected: true,
        onPlay: onPlay ?? (_) async => true,
        onSave: onSave,
      ),
    );

/// Two half-second holds with a 125 ms release gap: N4* R1 N4*.
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

/// Two half-second holds with a 750 ms release gap: N4* R6 N4*.
Future<void> _takeApart(WidgetTester t) async {
  final at = t.getCenter(find.text('Tap your pattern'));
  final a = await t.startGesture(at, pointer: 1);
  await t.pump(const Duration(milliseconds: 500));
  await a.up();
  await t.pump(const Duration(milliseconds: 750));
  final b = await t.startGesture(at, pointer: 2);
  await t.pump(const Duration(milliseconds: 500));
  await b.up();
  await t.pump(const Duration(milliseconds: 2100));
  await t.pumpAndSettle();
}

BuzzSequence _apart() => BuzzSequence(const [0, 1250],
    durationsMs: const [500, 500]);

/// One half-second hold: N4*.
Future<void> _takeSingle(WidgetTester t) async {
  final at = t.getCenter(find.text('Tap your pattern'));
  final a = await t.startGesture(at, pointer: 1);
  await t.pump(const Duration(milliseconds: 500));
  await a.up();
  await t.pump(const Duration(milliseconds: 2100));
  await t.pumpAndSettle();
}

/// Eight quick taps 1.9 s apart: about 14 s of rhythm.
Future<void> _takeLong(WidgetTester t) async {
  final at = t.getCenter(find.text('Tap your pattern'));
  for (var i = 0; i < 8; i++) {
    final g = await t.startGesture(at, pointer: i + 1);
    await t.pump(const Duration(milliseconds: 50));
    await g.up();
    if (i < 7) await t.pump(const Duration(milliseconds: 1900));
  }
  await t.pumpAndSettle();
}

BuzzSequence _single() =>
    BuzzSequence(const [0], durationsMs: const [500]);

/// The not-exact line for [plan]: "May not play exactly as written. The band
/// plays: (shortest)[ to (longest)]."
String _notExact(HapticPlan plan) {
  final lo = plan.feltMin.join(' ');
  final hi = plan.feltMax.join(' ');
  return 'May not play exactly as written. The band plays: '
      '${lo == hi ? lo : '$lo to $hi'}.';
}

BuzzSequence _holds() => BuzzSequence(
      const [0, 625],
      durationsMs: const [500, 500],
    );

void main() {
  testWidgets('before a take there are no notes and no plan', (t) async {
    await _pump(t, _sheet());
    expect(find.textContaining(RegExp(r'N\d+(ff|f|mf|mp|p|pp)\b')),
        findsNothing);
    expect(find.textContaining(RegExp(r'\d+ commands?')), findsNothing);
  });

  testWidgets('a take shows the notes it heard and the plan summary',
      (t) async {
    await _pump(t, _sheet());
    await _takeHolds(t);
    expect(find.textContaining('N4* R1 N4*'), findsOneWidget);
    final plan = planForTaps(_holds(), _mg)!;
    expect(find.textContaining(plan.summary), findsOneWidget);
  });

  testWidgets('an approximate plan says what the band plays, calmly',
      (t) async {
    await _pump(t, _sheet());
    await _takeHolds(t);
    // One unit of silence between commands is only measured on the unstable
    // 100 ms row, which is felt as a range: the plan is not "as written".
    final plan = planForTaps(_holds(), _mg)!;
    expect(plan.asWritten, isFalse);
    expect(find.textContaining('close, not exact'), findsNothing);
    expect(find.textContaining(_notExact(plan)), findsOneWidget);
    expect(find.text('Plays as written.'), findsNothing);
    expect(find.byIcon(LucideIcons.info), findsOneWidget);
  });

  testWidgets('an exact plan says Plays as written, with no info icon',
      (t) async {
    await _pump(t, _sheet());
    await _takeSingle(t);
    final plan = planForTaps(_single(), _mg)!;
    expect(plan.exact, isTrue);
    expect(find.text('Plays as written.'), findsOneWidget);
    expect(find.textContaining('May not play exactly'), findsNothing);
    expect(find.byIcon(LucideIcons.info), findsNothing);
    expect(find.textContaining('Pauses between buzzes'), findsNothing);
    expect(find.textContaining('Extended haptics:'), findsNothing);
  });

  testWidgets('"to" appears only when the shortest and longest felt differ',
      (t) async {
    await _pump(t, _sheet());
    await _takeHolds(t);
    final plan = planForTaps(_holds(), _mg)!;
    final differ = plan.feltMin.join(' ') != plan.feltMax.join(' ');
    final line = t
        .widget<Text>(find.textContaining('May not play exactly'))
        .data!;
    expect(line.contains(' to '), differ);
    expect(line, _notExact(plan));
  });

  testWidgets('a plan with several commands adds the pauses line', (t) async {
    await _pump(t, _sheet());
    await _takeApart(t);
    final plan = planForTaps(_apart(), _mg)!;
    expect(plan.steps.length, greaterThan(1));
    expect(plan.exact, isTrue);
    // The wait between the commands is a measured range, so the plan is not
    // "as written" even though it scores exact.
    expect(plan.asWritten, isFalse);
    expect(find.text('Plays as written.'), findsNothing);
    expect(find.textContaining(_notExact(plan)), findsOneWidget);
    expect(find.text('Pauses between buzzes can vary a little.'),
        findsOneWidget);
  });

  testWidgets('an unstable plan adds the timings-may-vary line', (t) async {
    await _pump(t, _sheet());
    await _takeHolds(t);
    final on = planForTaps(_holds(), _mg)!;
    expect(on.usesUnstable, isTrue);
    expect(find.textContaining('timings may vary unexpectedly'),
        findsOneWidget);
    expect(on.exact, isTrue);
    expect(on.asWritten, isFalse);
    expect(find.text('Plays as written.'), findsNothing);
    expect(find.textContaining(_notExact(on)), findsOneWidget);
  });

  testWidgets('no feedback text is drawn in an alarm colour', (t) async {
    await _pump(t, _sheet());
    await _takeHolds(t);
    final p = P.of(t.element(find.byType(BuzzPatternSheet)));
    for (final text in [
      'The band plays',
      'timings may vary',
      'Pauses between buzzes',
    ]) {
      final w = t.widget<Text>(find.textContaining(text));
      expect(w.style?.color, anyOf(p.ink2, p.ink3), reason: text);
    }
    final w = t.widget<Text>(find.textContaining('May not play exactly'));
    expect(w.style?.color, anyOf(p.ink2, p.ink3));
  });

  testWidgets('over the 10 second cap: a message and Save is disabled',
      (t) async {
    final saved = <BuzzSequence>[];
    await _pump(t, _sheet(onSave: saved.add));
    await _takeLong(t);
    expect(find.text('Too long for the band: keep it under 10 seconds.'),
        findsOneWidget);
    expect(find.text('Plays as written.'), findsNothing);
    expect(find.textContaining('May not play exactly'), findsNothing);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(saved, isEmpty);
    expect(find.text('Record again'), findsOneWidget);
  });

  testWidgets('a take under the cap saves', (t) async {
    final saved = <BuzzSequence>[];
    await _pump(t, _sheet(onSave: saved.add));
    await _takeHolds(t);
    expect(find.textContaining('Too long for the band'), findsNothing);
    await t.tap(find.text('Save'));
    expect(saved, hasLength(1));
  });

  testWidgets('on MG the stale "long press plays twice" line is gone',
      (t) async {
    await _pump(t, _sheet());
    expect(find.textContaining('long press plays the buzz twice'),
        findsNothing);
  });

  testWidgets('the saved sequence is the take', (t) async {
    final saved = <BuzzSequence>[];
    await _pump(t, _sheet(onSave: saved.add));
    await _takeHolds(t);
    await t.tap(find.text('Save'));
    expect(saved, hasLength(1));
    expect(saved.single.offsetsMs, [0, 625]);
    expect(saved.single.durationsMs, [500, 500]);
  });

  group('Save stores the notes, the profile and the baked plan', () {
    testWidgets('notes are the take as notes; profile id and version', (t) async {
      final saved = <BuzzSequence>[];
      await _pump(t, _sheet(onSave: saved.add));
      await _takeHolds(t);
      await t.tap(find.text('Save'));
      final s = saved.single;
      expect(s.notes, 'N4* R1 N4*');
      expect(s.profileId, _mg.id);
      expect(s.profileVersion, _mg.version);
    });

    testWidgets('the baked steps are the plan the sheet showed', (t) async {
      final saved = <BuzzSequence>[];
      await _pump(t, _sheet(onSave: saved.add));
      await _takeHolds(t);
      await t.tap(find.text('Save'));
      final plan = planForTaps(_holds(), _mg)!;
      final s = saved.single;
      expect(s.bakedSteps, isNotNull);
      expect([for (final b in s.bakedSteps!) b.effects],
          [for (final st in plan.steps) st.phrase.effects]);
      expect([for (final b in s.bakedSteps!) b.loop],
          [for (final st in plan.steps) st.phrase.loop]);
      expect([for (final b in s.bakedSteps!) b.delayMs],
          [for (final st in plan.steps) st.delayMs]);
    });

    testWidgets('the saved sequence survives a JSON round trip', (t) async {
      final saved = <BuzzSequence>[];
      await _pump(t, _sheet(onSave: saved.add));
      await _takeSingle(t);
      await t.tap(find.text('Save'));
      expect(BuzzSequence.fromJson(saved.single.toJson()), saved.single);
      expect(saved.single.notes, 'N4*');
    });

    testWidgets('the played preview is the take (the plan is made on delivery)',
        (t) async {
      final played = <BuzzSequence>[];
      await _pump(
          t,
          _sheet(onPlay: (s) async {
            played.add(s);
            return true;
          }));
      await _takeHolds(t);
      expect(played.single.offsetsMs, [0, 625]);
    });
  });
}
