// The Device lab's alarm-slot probe card: the button, the confirm sheet that
// says what the probe will do to the wearer's alarm, the running view (Stop,
// "felt A / felt B"), the result text, and that leaving the screen puts the
// real alarm back. Over the shared fake band, on fake time.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/alarm_slot_probe_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/alarm_slot_rig.dart';

Future<void> _pump(WidgetTester t, AlarmSlotRig rig) async {
  t.view.physicalSize = const Size(1200, 4000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: SingleChildScrollView(child: AlarmSlotProbeCard(runner: rig.runner)),
    ),
  ));
}

const _run = ValueKey('probe-alarm-slots');

Future<void> _startAndConfirm(WidgetTester t) async {
  await t.tap(find.byKey(_run));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const ValueKey('alarm-slot-confirm-run')));
  await t.pump();
}

void main() {
  testWidgets('the button is offered, with what it does spelled out',
      (t) async {
    await _pump(t, AlarmSlotRig());
    expect(find.text('Run alarm slot probe'), findsOneWidget);
    expect(find.textContaining('more than one alarm'), findsWidgets);
    expect(t.widget<BigButton>(find.byKey(_run)).onTap, isNotNull);
  });

  testWidgets('developer mode off: the card is not there', (t) async {
    await _pump(t, AlarmSlotRig()..dev = false);
    expect(find.byKey(_run), findsNothing);
    expect(find.text('Run alarm slot probe'), findsNothing);
  });

  testWidgets('an unknown band family disables it and says why', (t) async {
    await _pump(t, AlarmSlotRig(family: null));
    expect(t.widget<BigButton>(find.byKey(_run)).onTap, isNull);
    expect(find.textContaining('family'), findsWidgets);
  });

  testWidgets('a real alarm within 10 minutes disables it and says why',
      (t) async {
    await _pump(t, AlarmSlotRig(heldIn: const Duration(minutes: 6)));
    expect(t.widget<BigButton>(find.byKey(_run)).onTap, isNull);
    expect(find.textContaining('10 minutes'), findsWidgets);
  });

  testWidgets('the confirm sheet says the real alarm is replaced, then '
      'restored; Cancel writes nothing', (t) async {
    final rig = AlarmSlotRig();
    await _pump(t, rig);
    await t.tap(find.byKey(_run));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('alarm-slot-confirm')), findsOneWidget);
    expect(find.textContaining('replace your armed alarm'), findsOneWidget);
    expect(find.textContaining('restore'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('alarm-slot-confirm-cancel')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('alarm-slot-confirm')), findsNothing);
    expect(rig.calls, isEmpty);
    expect(rig.runner.running, isFalse);
  });

  testWidgets('a confirmed run shows Stop and the felt ticks, then the result '
      'and the evidence', (t) async {
    final rig = AlarmSlotRig();
    await _pump(t, rig);
    await _startAndConfirm(t);
    await t.pump(const Duration(seconds: 1));
    expect(rig.runner.running, isTrue);
    expect(find.byKey(const ValueKey('alarm-slot-cancel')), findsOneWidget);
    expect(find.byKey(const ValueKey('alarm-slot-felt-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('alarm-slot-felt-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('alarm-slot-result')), findsNothing);

    await t.tap(find.byKey(const ValueKey('alarm-slot-felt-a')));
    await t.pump();
    expect(rig.runner.evidence!.feltA, isTrue);

    await t.pump(const Duration(minutes: 6));
    expect(rig.runner.running, isFalse);
    expect(find.text('The band holds 2 alarms at once'), findsOneWidget);
    expect(find.byKey(const ValueKey('alarm-slot-result')), findsOneWidget);
    expect(find.textContaining('valid_input_pattern'), findsWidgets,
        reason: 'the raw status the band gave is on screen');
    expect(find.byKey(const ValueKey('alarm-slot-cancel')), findsNothing);
    expect(rig.stored, {0: rig.held!});
  });

  testWidgets('the result says when only one alarm is kept', (t) async {
    final rig = AlarmSlotRig(capacity: 1);
    await _pump(t, rig);
    await _startAndConfirm(t);
    await t.pump(const Duration(minutes: 6));
    expect(find.text('Only one alarm is kept (B replaced A)'), findsOneWidget);
  });

  testWidgets('the result says inconclusive when the evidence is thin',
      (t) async {
    final rig = AlarmSlotRig(family: 'gen4')..fires = false;
    await _pump(t, rig);
    await _startAndConfirm(t);
    await t.pump(const Duration(minutes: 6));
    expect(find.textContaining('nconclusive'), findsWidgets);
    // Felt ticks can still be added after the run, and move the verdict.
    await t.tap(find.byKey(const ValueKey('alarm-slot-felt-a')));
    await t.tap(find.byKey(const ValueKey('alarm-slot-felt-b')));
    await t.pump();
    expect(find.text('The band holds 2 alarms at once'), findsOneWidget);
  });

  testWidgets('Stop restores the real alarm at once', (t) async {
    final rig = AlarmSlotRig();
    await _pump(t, rig);
    await _startAndConfirm(t);
    await t.pump(const Duration(seconds: 30));
    expect(rig.stored.keys, containsAll([0, 1]));
    await t.tap(find.byKey(const ValueKey('alarm-slot-cancel')));
    await t.pump(const Duration(seconds: 5));
    expect(rig.runner.running, isFalse);
    expect(rig.calls, contains('restore:${rig.held}'));
    expect(rig.stored, {0: rig.held!});
  });

  testWidgets('leaving the screen mid-run restores the real alarm', (t) async {
    final rig = AlarmSlotRig();
    await _pump(t, rig);
    await _startAndConfirm(t);
    await t.pump(const Duration(seconds: 30));
    expect(rig.runner.running, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    expect(rig.runner.running, isFalse);
    expect(rig.calls, contains('clear1'));
    expect(rig.calls, contains('restore:${rig.held}'));
    expect(rig.stored, {0: rig.held!});
  });
}
