import 'package:flutter/material.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/personal_day_inputs.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';

void main() {
  // WHY: events and graph samples on opposite calendar days must share one
  // axis without filling holes or taking untimed notes from both dates.
  // catches: returning the anchor calendar day's graph unchanged.
  test('timeline joins existing graphs then reuses the existing window', () {
    final a = DateTime(2026, 11, 2), b = DateTime(2026, 11, 3);
    final as = a.millisecondsSinceEpoch ~/ 1000;
    final bs = b.millisecondsSinceEpoch ~/ 1000;
    final day = PersonalDay(DateTime(2026, 11, 2, 8), DateTime(2026, 11, 3, 8),
        '2026-11-02', '2026-11-03');
    final first = List<double?>.filled(1440, null)..[9*60] = 60;
    final second = List<double?>.filled(1440, null)..[7*60] = 70;
    final data = personalTimelineOf(PersonalDayView(day, PersonalDayMode.wakeToWake, true, [day]), [
      TimelineData(day: '2026-11-02', graph: DayGraph(dayStart: as, hr: first),
        moments: [Moment(at: as+7*3600, title: 'Outside', icon: Icons.circle),
          Moment(at: as+9*3600, title: 'First', icon: Icons.circle)],
        notes: const [DayNote('Wrong date', '', Icons.circle)],
        discarded:[Moment(at:as+9*3600,title:'Discarded inside',icon:Icons.circle),
          Moment(at:as+7*3600,title:'Discarded outside',icon:Icons.circle)]),
      TimelineData(day: '2026-11-03', graph: DayGraph(dayStart: bs, hr: second),
        moments: [Moment(at: bs+7*3600, title: 'Second', icon: Icons.circle),
          Moment(at: bs+8*3600, title: 'Next day', icon: Icons.circle)],
        notes: const [DayNote('Score date', '', Icons.circle)]),
    ]);
    expect(data.graph.dayStart, as+8*3600);
    expect(data.graph.slots, 1440);
    expect(data.graph.hr[60], 60);
    expect(data.graph.hr[23*60], 70);
    expect(data.graph.hr[2*60], isNull);
    expect(data.moments.map((m) => m.title), ['First', 'Second']);
    expect(data.notes.map((n) => n.title), ['Score date']);
    expect(data.discarded.map((m)=>m.title),['Discarded inside']);
    expect(data.days, [day.id]);
  });
  // WHY: retaining a full-calendar axis mislabels a noon-to-noon timeline.
  testWidgets('personal graph axis shows its actual boundary clocks', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) =>
      dayGraphCard(c, DayGraph(dayStart: DateTime(2026,11,2,12).millisecondsSinceEpoch~/1000,
        hr: List<double?>.filled(1440, 60), clockAxis: true))!))));
    expect(find.text('Midnight'), findsNothing);
    // The landed chart paints clocks on canvas instead of Text widgets.
    // Pin its actual time domain; day_timeline_test checks painted axis labels.
    final painter=t.widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w)=>w.painter).whereType<TimelinePainter>().single;
    expect(painter.view.start,DateTime(2026,11,2,12).millisecondsSinceEpoch/1000);
    expect(painter.view.end,DateTime(2026,11,3,12).millisecondsSinceEpoch/1000);
  });

}
