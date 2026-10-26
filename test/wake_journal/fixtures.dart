// Fixed instants. Run all P2 suites with TZ=UTC.
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart' show WakeTraceEntry;
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';

final alarmAt = DateTime.utc(2026, 10, 26, 7);
final epoch = alarmAt.millisecondsSinceEpoch ~/ 1000;
DateTime atMinute(int minute) => alarmAt.add(Duration(minutes: minute));

WakeTraceEntry row(
  String kind,
  int minute, [
  Map<String, Object?> data = const {},
  int? forEpoch,
]) => WakeTraceEntry(
  wakeEpochSec: forEpoch ?? epoch,
  atMs: atMinute(minute).millisecondsSinceEpoch,
  kind: kind,
  data: data,
);

// Match the existing orchestrator wire shapes, including non-events.
List<WakeTraceEntry> fullTrace() => [
  row('plan', -35),
  row('natural', -32, {'reason': 'remNotStable'}),
  row('fallback', -31, {'armed': true, 'confirmed': true}), // not a fire
  row('natural', -20, {'reason': 'fire'}),
  row('natural_haptic', -20, {'phase': 'request'}),
  row('natural_haptic', -20, {'phase': 'result', 'result': 'sent'}),
  row('natural_repeat', -20, {'phase': 'start'}),
  row('natural_repeat', -19, {'phase': 'result', 'index': 1, 'result': 'sent'}),
  row('natural_repeat', -18, {'phase': 'result', 'index': 2, 'result': 'sent'}),
  row('gradual', -15, {'index': 0, 'result': 'sent'}),
  row('gradual', -12, {'index': 1, 'result': 'sent'}),
  row('fallback', 0, {'fired': true}), // explicit fired, unlike armed status
  row('snooze', 1, {'count': 1}),
  row('snooze', 6, {'count': 2}),
  row('snooze_stop', 8, {'reason': 'im_up'}),
  row('ack', 8),
  row('natural_repeat', 8, {'phase': 'stop', 'reason': 'acknowledged'}),
];

const eventKinds = [
  WakeNightEventKind.natural,
  WakeNightEventKind.repeat,
  WakeNightEventKind.repeat,
  WakeNightEventKind.gradual,
  WakeNightEventKind.alarm,
  WakeNightEventKind.snooze,
  WakeNightEventKind.snooze,
  WakeNightEventKind.snoozeStop,
  WakeNightEventKind.ack,
];
const eventMinutes = [-20, -19, -18, -15, 0, 1, 6, 8, 8];

// A data fixture, independent of the RED projector, for screen tests.
WakeNightTimeline renderedNight() => WakeNightTimeline(
  events: [
    for (var i = 0; i < eventKinds.length; i++)
      WakeNightEvent(
        kind: eventKinds[i],
        at: atMinute(eventMinutes[i]),
        count: i == 5
            ? 1
            : i == 6
            ? 2
            : null,
        reason: i == 7 ? 'im_up' : null,
      ),
  ],
  firstFireAt: atMinute(-20),
  ackAt: atMinute(8),
  timeToWake: const Duration(minutes: 28),
  snoozeCount: 2,
);

WakeNightOutcome outcome(
  int day, {
  int wakeOffsetSec = 0,
  WakePath path = WakePath.natural,
  DreamAnswer? answer = DreamAnswer.dream,
  int? minutes = 1,
  int? snoozes = 0,
  double? recovery = 80,
  int? tstMinutes = 480,
  WakeSubstance? substance,
}) => WakeNightOutcome(
  dayId: dayLabelOf(alarmAt.add(Duration(days: day))),
  wakeEpochSec: epoch + day * 86400 + wakeOffsetSec,
  timeToWake: minutes == null ? null : Duration(minutes: minutes),
  snoozeCount: snoozes,
  dream: answer == null
      ? null
      : WakeDreamResponse(
          answer: answer,
          path: path,
          at: atMinute(8).add(Duration(days: day, seconds: wakeOffsetSec)),
        ),
  recovery: recovery,
  mainSleepTst: tstMinutes == null ? null : Duration(minutes: tstMinutes),
  substance: substance,
);
