import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import 'fixtures.dart';

void main() {
  test('P2 tests run in UTC', () => expect(Platform.environment['TZ'], 'UTC'));

  test(
    'one epoch has every event in clock order, first Natural and Gradual only',
    () {
      final input = [...fullTrace().reversed, row('ack', 9, {}, epoch + 86400)];
      final night = WakeNightTimeline.forEpoch(
        wakeEpochSec: epoch,
        trace: input,
        bandAlarms: [WakeBandAlarm(wakeEpochSec: epoch, at: alarmAt)],
      );
      expect(night.events.map((e) => e.kind), eventKinds);
      expect(night.events.map((e) => e.at), eventMinutes.map(atMinute));
      expect(
        night.events
            .where((e) => e.kind == WakeNightEventKind.snooze)
            .map((e) => e.count),
        [1, 2],
      );
      expect(night.events[7].reason, 'im_up');
      expect(
        input.first.kind,
        'natural_repeat',
        reason: 'projection must not sort caller input',
      );
    },
  );

  test('time to wake is ack minus first fire, never the scheduled alarm', () {
    final n = WakeNightTimeline.forEpoch(
      wakeEpochSec: epoch,
      trace: fullTrace(),
    );
    expect(n.firstFireAt, atMinute(-20));
    expect(n.ackAt, atMinute(8));
    expect(n.timeToWake, const Duration(minutes: 28)); // 07:08 - 06:40
    expect(n.snoozeCount, 2);
  });

  test(
    'absent ack does not invent a duration or zero snoozes for a known snooze',
    () {
      final n = WakeNightTimeline.forEpoch(
        wakeEpochSec: epoch,
        trace: [
          row('natural', -20, {'reason': 'fire'}),
          row('snooze', 1, {'count': 1}),
        ],
      );
      expect(n.firstFireAt, atMinute(-20));
      expect(n.ackAt, isNull);
      expect(n.timeToWake, isNull);
      expect(n.snoozeCount, 1);
    },
  );

  test('ack without fire is visible with unknown time to wake', () {
    final n = WakeNightTimeline.forEpoch(
      wakeEpochSec: epoch,
      trace: [row('ack', 8)],
    );
    expect(n.ackAt, atMinute(8));
    expect(n.firstFireAt, isNull);
    expect(n.timeToWake, isNull);
  });

  test('clock-regressed ack is retained but duration is unknown', () {
    final n = WakeNightTimeline.forEpoch(
      wakeEpochSec: epoch,
      trace: [
        row('natural', 0, {'reason': 'fire'}),
        row('ack', -1),
      ],
    );
    expect(n.ackAt, atMinute(-1));
    expect(n.timeToWake, isNull);
  });

  test(
    'backup band code 57 alone establishes first fire; another epoch does not',
    () {
      final n = WakeNightTimeline.forEpoch(
        wakeEpochSec: epoch,
        trace: [row('ack', 8)],
        bandAlarms: [
          WakeBandAlarm(wakeEpochSec: epoch, at: alarmAt),
          WakeBandAlarm(wakeEpochSec: epoch + 86400, at: atMinute(-90)),
          WakeBandAlarm(wakeEpochSec: epoch, at: atMinute(-60), code: 58),
        ],
      );
      expect(n.events.map((e) => e.kind), [
        WakeNightEventKind.alarm,
        WakeNightEventKind.ack,
      ]);
      expect(n.firstFireAt, alarmAt);
      expect(n.timeToWake, const Duration(minutes: 8));
    },
  );

  test('Gradual-only first delivered step starts the wake interval', () {
    final n = WakeNightTimeline.forEpoch(
      wakeEpochSec: epoch,
      trace: [
        row('gradual', -20, {'index': 0, 'result': 'skippedLate'}),
        row('gradual', -15, {'index': 1, 'result': 'sent'}),
        row('ack', 8),
      ],
    );
    expect(n.firstFireAt, atMinute(-15));
    expect(n.timeToWake, const Duration(minutes: 23));
  });

  test(
    'status and failed deliveries never become wake events (positive control included)',
    () {
      final n = WakeNightTimeline.forEpoch(
        wakeEpochSec: epoch,
        trace: [
          row('fallback', -30, {'armed': true, 'confirmed': true}),
          row('natural', -25, {'reason': 'warmup'}),
          row('natural_repeat', -24, {'phase': 'start'}),
          row('natural_repeat', -23, {
            'phase': 'result',
            'result': 'notDelivered',
          }),
          row('gradual', -22, {'result': 'notDelivered'}),
          row('error', -21),
          row('natural', -20, {'reason': 'fire'}),
          row('ack', 8),
        ],
      );
      expect(n.events.map((e) => e.kind), [
        WakeNightEventKind.natural,
        WakeNightEventKind.ack,
      ]);
    },
  );

  test(
    'repeated ack keeps the first acknowledgement and duplicate alarm sources collapse',
    () {
      final n = WakeNightTimeline.forEpoch(
        wakeEpochSec: epoch,
        trace: [
          row('fallback', 0, {'fired': true}),
          row('ack', 8),
          row('ack', 12),
        ],
        bandAlarms: [WakeBandAlarm(wakeEpochSec: epoch, at: alarmAt)],
      );
      expect(n.events.map((e) => e.kind), [
        WakeNightEventKind.alarm,
        WakeNightEventKind.ack,
      ]);
      expect(n.timeToWake, const Duration(minutes: 8));
    },
  );

  test('dream answer belongs to the observed wake record', () {
    final n = WakeNightTimeline.forEpoch(
      wakeEpochSec: epoch,
      trace: fullTrace(),
      dream: WakeDreamResponse(
        answer: DreamAnswer.dream,
        path: WakePath.natural,
        at: atMinute(8),
      ),
    );
    expect(n.dream?.answer, DreamAnswer.dream);
    expect(n.dream?.path, WakePath.natural);
  });

  test('a completely missing night stays absent', () {
    final n = WakeNightTimeline.forEpoch(wakeEpochSec: epoch, trace: []);
    expect(n.events, isEmpty);
    expect(n.firstFireAt, isNull);
    expect(n.ackAt, isNull);
    expect(n.timeToWake, isNull);
  });
}
