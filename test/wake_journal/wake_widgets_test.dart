import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import 'fixtures.dart';

const markerLabels = [
  'Natural wake',
  'Gradual wake',
  'Alarm',
  'Snooze',
  'Snooze stopped',
  "I'm up",
];

Map<String, dynamic> chartDay() => {
  'day_start': DateTime.utc(2026, 10, 26).millisecondsSinceEpoch ~/ 1000,
  'hr': [
    for (var i = -40; i <= 10; i++)
      {'t': atMinute(i).millisecondsSinceEpoch ~/ 1000, 'v': 55.0},
  ],
};

SleepData sleepFixture({bool acknowledged = true}) => SleepData(
  day: '2026-10-26',
  night: {
    'duration_min': 480,
    'in_bed_min': 500,
    'onset_ts': atMinute(-480).millisecondsSinceEpoch ~/ 1000,
    'wake_ts': atMinute(8).millisecondsSinceEpoch ~/ 1000,
    'hypnogram': [
      {'t': atMinute(-480).millisecondsSinceEpoch ~/ 1000, 'stage': 'light'},
      {'t': atMinute(-20).millisecondsSinceEpoch ~/ 1000, 'stage': 'rem'},
      {'t': atMinute(8).millisecondsSinceEpoch ~/ 1000, 'stage': 'awake'},
    ],
  },
  wakeTimeline: acknowledged
      ? renderedNight()
      : WakeNightTimeline(
          events: renderedNight().events
              .where((e) => e.kind != WakeNightEventKind.ack)
              .toList(),
          firstFireAt: atMinute(-20),
          snoozeCount: 2,
        ),
);

Widget dayFixture() {
  final raw = chartDay();
  final data = TimelineData(
    day: '2026-10-26',
    graph: dayGraph(raw),
    moments: dayMoments(timeline: raw, wakeTimeline: renderedNight()),
  );
  return Builder(
    builder: (c) => Scaffold(
      body: ListView(children: timelineBody(c, data, fineDetail: false)),
    ),
  );
}

Future<void> pumpWakePage(WidgetTester t, Widget page) async {
  t.view.physicalSize = const Size(1170, 15600);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(theme: buildTheme(Brightness.light), home: page),
  );
  await t.pumpAndSettle();
}

void main() {
  test(
    'day annotation projection retains each wake point, including both snoozes and repeats',
    () {
      final moments = dayMoments(
        timeline: chartDay(),
        wakeTimeline: renderedNight(),
      );
      final marks = dayAnnotations(moments);
      expect(marks.map((m) => m.label), [
        'Natural wake',
        'Natural wake',
        'Natural wake',
        'Gradual wake',
        'Alarm',
        'Snooze',
        'Snooze',
        'Snooze stopped',
        "I'm up",
      ]);
      expect(
        marks.map((m) => m.at),
        eventMinutes.map((m) => atMinute(m).millisecondsSinceEpoch / 1000),
      );
      expect(
        marks.map((m) => m.kind.name).toSet(),
        {'wake'},
        reason: 'one wake marker group is sufficient',
      );
      expect(marks.map((m) => m.id).toSet(), hasLength(9));
    },
  );

  testWidgets('day timeline renders the six labelled wake marker types', (
    t,
  ) async {
    await pumpWakePage(t, dayFixture());
    for (final label in markerLabels) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    final lanes = t.widgetList<ChartAnnotationLane>(
      find.byType(ChartAnnotationLane),
    );
    expect(
      lanes.expand((l) => l.set.items).map((a) => a.label),
      containsAll(markerLabels),
    );
  });

  testWidgets(
    'sleep chart exposes the same six wake markers as the day timeline',
    (t) async {
      await pumpWakePage(t, SleepDetail(data: sleepFixture()));
      final marks = t
          .widgetList<ChartAnnotationLane>(find.byType(ChartAnnotationLane))
          .expand((l) => l.set.items)
          .toList();
      expect(marks.map((a) => a.label), containsAll(markerLabels));
      expect(marks.where((a) => a.label == 'Snooze'), hasLength(2));
    },
  );

  testWidgets(
    'sleep detail says Time to wake: 28 min for the recorded interval',
    (t) async {
      await pumpWakePage(t, SleepDetail(data: sleepFixture()));
      expect(find.text('Time to wake: 28 min'), findsOneWidget);
    },
  );

  testWidgets(
    'sleep detail renders unknown time to wake as a dash when ack is missing',
    (t) async {
      await pumpWakePage(
        t,
        SleepDetail(data: sleepFixture(acknowledged: false)),
      );
      expect(find.text('Time to wake: —'), findsOneWidget);
      expect(find.text('Time to wake: 0 min'), findsNothing);
    },
  );
}
