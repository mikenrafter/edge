import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/natural_wake_card.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'fixtures.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/wake/wake_controller.dart';
import 'package:openstrap_edge/wake/wake_journal.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

const ackResult = WakeAckOutcome(
  nativeCancelRequested: false,
  nativeCancelled: false,
  fallbackArmed: true,
);

class RecordingJournal extends DbWakeJournal {
  final answers = <(int, DreamAnswer?, DateTime)>[];
  @override
  Future<void> answerDream({required int wakeEpochSec, required DateTime at,
      required DreamAnswer? answer}) async {
    answers.add((wakeEpochSec, answer, at));
  }
}

WakeController controller(Future<WakeAckOutcome> Function(bool) ack,
    {DbWakeJournal journal = const DbWakeJournal()}) => WakeController(
  schedule: () => [], saveEntry: (_) async {},
  loadUpgradeState: () async => WakeUpgradeState.none,
  saveUpgradeState: (_) async {}, acknowledgeWake: ack,
  traceFor: (_) async => [], journal: journal,
  journalNow: () => DateTime.utc(2026, 10, 26, 7, 9),
);

void main() {
  test('an old acknowledgement preserves a newer wake', () async {
    final gate = Completer<WakeAckOutcome>();
    final w = controller((_) => gate.future);
    addTearDown(w.dispose);
    w.noteWakeAwaitingAck(100, WakePath.gradual);
    final acknowledging = w.acknowledgeWake();
    w.noteWakeAwaitingAck(200, WakePath.alarm);
    gate.complete(ackResult);
    await acknowledging;
    expect(w.awaitingWakeEpoch, 200);
    expect(w.awaitingWakePath, WakePath.alarm);
  });

  test('path priority and replay cannot reopen an acknowledged occurrence', () async {
    final w = controller((_) async => ackResult);
    addTearDown(w.dispose);
    w.noteWakeAwaitingAck(100, WakePath.gradual);
    w.noteWakeAwaitingAck(100, WakePath.natural);
    w.noteWakeAwaitingAck(100, WakePath.alarm);
    expect(w.awaitingWakePath, WakePath.natural);
    await w.acknowledgeWake();
    w.noteWakeAwaitingAck(100, WakePath.alarm);
    expect(w.awaitingWakeEpoch, isNull);
    w.noteWakeAwaitingAck(200, WakePath.alarm);
    expect(w.awaitingWakeEpoch, 200);
  });

  testWidgets('sleep marks include post-sleep snoozes without extending stages', (t) async {
    t.view.physicalSize = const Size(1170, 15600);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final night = <String, dynamic>{
      'duration_min': 480,
      'onset_ts': atMinute(-480).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': epoch,
      'hypnogram': [
        {'t': atMinute(-480).millisecondsSinceEpoch ~/ 1000, 'stage': 'light'},
        {'t': epoch, 'stage': 'awake'},
      ],
    };
    final original = SleepData.stagesOf(night);
    final extended = SleepData.stagesOf(night, domainEnd: epoch + 8 * 60);
    expect(original.last, SleepStage.light);
    expect(extended.last, isNull);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
      home: SleepDetail(data: SleepData(night: night, wakeTimeline: renderedNight()))));
    await t.pumpAndSettle();
    final lane = t.widget<ChartAnnotationLane>(find.byType(ChartAnnotationLane));
    expect(lane.set.domainEnd, (epoch + 8 * 60).toDouble());
    expect(lane.set.items.where((e) => e.label == 'Snooze'), hasLength(2));
    expect(night['wake_ts'], epoch);
    expect(find.text('Time to wake: 28 min'), findsOneWidget);
  });

  testWidgets('question opens during ack; an answer waits and retains its epoch', (t) async {
    final gate = Completer<WakeAckOutcome>();
    final journal = RecordingJournal();
    var started = false;
    final w = controller((_) { started = true; return gate.future; }, journal: journal);
    addTearDown(w.dispose);
    w.noteWakeAwaitingAck(100, WakePath.alarm);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
      home: Scaffold(body: NaturalWakeBuzzingCard(wake: w))));
    await t.tap(find.byKey(const ValueKey('natural-wake-im-up')));
    await t.pumpAndSettle();
    expect(started, isTrue);
    expect(find.text('How did you wake up?'), findsOneWidget);
    await t.tap(find.text('Normally'));
    await t.pumpAndSettle();
    expect(journal.answers, isEmpty);
    w.noteWakeAwaitingAck(200, WakePath.natural);
    gate.complete(ackResult);
    await t.pumpAndSettle();
    expect(journal.answers, [(100, DreamAnswer.normal, DateTime.utc(2026, 10, 26, 7, 9))]);
    expect(w.awaitingWakeEpoch, 200);
  });
}
