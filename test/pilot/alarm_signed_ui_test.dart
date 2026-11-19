// why: the signed alarm UI keeps the same three readout cells during scrubbing
// and directs enabled timing changes to Times. Supplemental pilot scope only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/alarm_screen.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'screens_test.dart' show pump;

void main(){
  final day=DateTime(2026,11,23),base=DateTime(2026,11,23).millisecondsSinceEpoch~/1000;
  setUp(()async{SharedPreferences.setMockInitialValues({});await Prefs.reload();await PilotFlags.set(PilotFlag.wakeMethods,true);ClockFormatController.seed(ClockFormat.h24);});
  tearDown(ClockFormatController.debugReset);
  // catches: generic phone limitations replacing the enabled timing / Times subtitle.
  testWidgets('enabled Waking steps show before or after and set on Times',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',sunrise:true,sunriseMinutes:20,gradual:true,gradualMinutes:15,phoneSound:true,soundDelayMinutes:3,phoneVibration:true,vibrationDelayMinutes:5,phoneFlash:true,flashDelayMinutes:8),now:day,onSave:(_)async{}));
    await t.tap(find.text('Waking'));await t.pumpAndSettle();
    for(final pair in [('Sunrise alarm','20 min before · set on Times'),('Gradual wake','15 min before · set on Times'),('Phone vibration','5 min after · set on Times'),('Phone sound','3 min after · set on Times'),('Phone flash','8 min after · set on Times')]){
      await t.scrollUntilVisible(find.text(pair.$1),200,scrollable:find.byType(Scrollable).last);
      final tile=find.widgetWithText(SwitchListTile,pair.$1);expect(tile,findsOneWidget);
      expect(find.descendant(of:tile,matching:find.textContaining(pair.$2)),findsOneWidget);
    }
    expect(find.textContaining('If the torch is unavailable'),findsOneWidget);
  });
  // catches: idle two-cell stats becoming Stage/HR/movement, losing title/controls,
  // or using a text Happening value with no accessible icon description.
  testWidgets('alarm readout retains three fixed cells and accessible Happening icons during scrub',(t)async{
    final graph=DayGraph(dayStart:base-3600,hr:List.filled(600,62),movement:List.filled(600,.1));
    final stages=List<SleepStage?>.filled(120,SleepStage.light);
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'Work',sunrise:true,sunriseMinutes:20,phoneSound:true,soundDelayMinutes:0),now:day,
      reference:(_)async=>PilotAlarmReference(graph:graph,stages:stages,bedMinute:360,wakeMinute:420,usualSleepMinutes:60),onSave:(_)async{}));
    final detail=find.byKey(const ValueKey('pilot-alarm-readout')),plot=find.byKey(const ValueKey('pilot-timeline-plot'));
    final before=t.getSize(detail),zoom=t.getRect(find.text('Zoom in')),title=t.getRect(find.descendant(of:detail,matching:find.text('Work')));
    for(final label in ['Stage','Asleep for','Happening']){expect(find.descendant(of:detail,matching:find.text(label)),findsOneWidget);}
    final rect=t.getRect(plot),g=await t.startGesture(Offset(rect.left+rect.width*.25,rect.center.dy));await t.pump(const Duration(milliseconds:350));
    // 06:50 is a quarter through 06:40…07:20; the small move stays at 06:50 after 5-min snapping.
    await g.moveBy(Offset(rect.width*.05,0));await t.pump();
    expect(t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart)).controller.scrub,isNotNull);
    expect(find.descendant(of:detail,matching:find.bySemanticsLabel('Sunrise alarm')),findsOneWidget);
    expect(find.descendant(of:detail,matching:find.text('Light')),findsOneWidget);
    // The forecast readout estimates 50 min since this night’s 06:00 bedtime.
    expect(find.descendant(of:detail,matching:find.text('~50 min')),findsOneWidget);
    expect(t.getSize(detail),before);expect(t.getRect(find.text('Zoom in')),zoom);expect(t.getRect(find.descendant(of:detail,matching:find.text('Work'))),title);
    await g.up();await t.pump();expect(t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart)).controller.scrub,null);
    for(final label in ['Stage','Asleep for','Happening']){expect(find.descendant(of:detail,matching:find.text(label)),findsOneWidget);}
    expect(t.takeException(),null);
  });
  // catches: inventing a bedtime when this weekday has no usual-sleep reference.
  testWidgets('forecast Asleep for stays absent without a usual bedtime',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'Work'),now:day,
      reference:(_)async=>PilotAlarmReference(graph:DayGraph(dayStart:base),wakeMinute:420),onSave:(_)async{}));
    final detail=find.byKey(const ValueKey('pilot-alarm-readout'));
    final label=find.descendant(of:detail,matching:find.text('Asleep for'));expect(label,findsOneWidget);
    final cell=find.ancestor(of:label,matching:find.byType(Column)).first;
    expect(find.descendant(of:cell,matching:find.text('—')),findsOneWidget);
  });
}
