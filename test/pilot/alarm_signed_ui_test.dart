// why: the signed alarm UI keeps the same three readout cells during scrubbing
// and directs enabled timing changes to Times. Supplemental pilot scope only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
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
      final tile=find.widgetWithText(SetRow,pair.$1);expect(tile,findsOneWidget);
      expect(find.descendant(of:tile,matching:find.textContaining(pair.$2)),findsOneWidget);
    }
    expect(find.textContaining('If the torch is unavailable'),findsOneWidget);
  });
  // catches: Band off leaving every phone method off or omitting the Times cue.
  testWidgets('Band off enables immediate Phone sound and flashes Times',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A'),now:day,onSave:(_)async{}));
    await t.tap(find.text('Waking'));await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Band buzz'),160,scrollable:find.byType(Scrollable).last);
    await t.tap(find.text('Band buzz'));await t.pump();await t.pump(const Duration(milliseconds:100));
    final flash=find.byKey(const ValueKey('pilot-times-flash'));expect(flash,findsOneWidget);
    expect(((t.widget<DecoratedBox>(flash).decoration as BoxDecoration).color?.a??0),greaterThan(0));
    await t.scrollUntilVisible(find.text('Phone sound'),160,scrollable:find.byType(Scrollable).last);
    final sound=find.widgetWithText(SetRow,'Phone sound');expect(t.widget<Switch>(find.descendant(of:sound,matching:find.byType(Switch))).value,true);
    expect(find.descendant(of:sound,matching:find.text('0 min after · set on Times')),findsOneWidget);
    await t.tap(find.text('Times'));await t.pumpAndSettle();t.state<ScrollableState>(find.byType(Scrollable).last).position.jumpTo(0);await t.pump();await t.scrollUntilVisible(find.byKey(const ValueKey('pilot-time:sound')),160,scrollable:find.byType(Scrollable).last);expect(find.byKey(const ValueKey('pilot-time:sound')),findsOneWidget);
  });
  // catches: idle two-cell stats becoming Stage/HR/movement, losing title/controls,
  // or using a text Happening value with no accessible icon description.
  testWidgets('alarm readout swaps at-rest stats for scrub values in one fixed layout',(t)async{
    final graph=DayGraph(dayStart:base-3600,hr:List.filled(600,62),movement:List.filled(600,.1));
    final stages=List<SleepStage?>.filled(120,SleepStage.light);
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'Work',sunrise:true,sunriseMinutes:20,phoneSound:true,soundDelayMinutes:0),now:day,
      reference:(_)async=>PilotAlarmReference(graph:graph,stages:stages,bedMinute:360,wakeMinute:420,usualSleepMinutes:60),onSave:(_)async{}));
    final detail=find.byKey(const ValueKey('pilot-alarm-readout')),plot=find.byKey(const ValueKey('pilot-timeline-plot'));
    final before=t.getSize(detail),zoom=t.getRect(find.text('Zoom in')),title=t.getRect(find.descendant(of:detail,matching:find.text('Work')));
    // At rest (mock-up v22 statsOf): Wake / Expected / Usual sleep.
    void rest(){for(final label in ['Wake','Expected','Usual sleep']){expect(find.descendant(of:detail,matching:find.text(label)),findsOneWidget);}expect(find.descendant(of:detail,matching:find.text('Stage')),findsNothing);}
    rest();
    final cells=t.getRect(find.descendant(of:detail,matching:find.text('Wake'))),bigTime=find.descendant(of:detail,matching:find.byKey(const ValueKey('pilot-readout-time'))),big=t.getRect(bigTime);
    final rect=t.getRect(plot),g=await t.startGesture(Offset(rect.left+rect.width*.25,rect.center.dy));await t.pump(const Duration(milliseconds:350));
    // 06:50 is a quarter through 06:40…07:20; the small move stays at 06:50 after 5-min snapping.
    await g.moveBy(Offset(rect.width*.05,0));await t.pump();
    expect(t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart)).controller.scrub,isNotNull);
    expect(find.descendant(of:detail,matching:find.byWidgetPredicate((w)=>w is Semantics&&w.properties.label=='Sunrise alarm')),findsOneWidget,reason:'cursor ${t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart)).controller.scrub}');
    expect(find.descendant(of:detail,matching:find.text('Light')),findsOneWidget);
    // The forecast readout estimates 50 min since this night’s 06:00 bedtime.
    expect(find.descendant(of:detail,matching:find.text('~50 min')),findsOneWidget);
    for(final label in ['Stage','Asleep for','Happening']){expect(find.descendant(of:detail,matching:find.text(label)),findsOneWidget);}
    expect(find.descendant(of:detail,matching:find.text('Wake')),findsNothing);
    // m214: title row, big time and control row stay put; only the values change.
    expect(t.getSize(detail),before);expect(t.getRect(find.text('Zoom in')),zoom);expect(t.getRect(find.descendant(of:detail,matching:find.text('Work'))),title);
    expect(t.getRect(find.descendant(of:detail,matching:find.text('Stage'))).topLeft,cells.topLeft);
    expect(t.widget<Text>(bigTime).data,'06:50');expect(t.getRect(bigTime).right,big.right);
    await g.up();await t.pump();expect(t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart)).controller.scrub,null);
    rest();expect(t.getSize(detail),before);
    expect(t.takeException(),null);
  });
  // catches: dropping the forecast tilde, displaying negative elapsed time,
  // or showing raw minutes instead of the signed preview's hours/minutes format.
  testWidgets('forecast estimate formats hours and stays absent before bedtime',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'Work'),now:day,
      reference:(_)async=>PilotAlarmReference(graph:DayGraph(dayStart:base),bedMinute:0,wakeMinute:420),onSave:(_)async{}));
    final detail=find.byKey(const ValueKey('pilot-alarm-readout')),chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));
    expect(find.descendant(of:detail,matching:find.text('~7 h')),findsOneWidget);
    chart.controller.setScrub(base+370*60.0);await t.pump();expect(find.descendant(of:detail,matching:find.text('~6 h 10 min')),findsOneWidget);
    chart.controller.setScrub(base-60.0);await t.pump();
    final label=find.descendant(of:detail,matching:find.text('Asleep for'));expect(label,findsOneWidget);
    final cell=find.ancestor(of:label,matching:find.byType(Column)).first;expect(find.descendant(of:cell,matching:find.text('—')),findsOneWidget);
  });
  // catches: inventing a bedtime when this weekday has no usual-sleep reference.
  testWidgets('forecast Asleep for stays absent without a usual bedtime',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'Work'),now:day,
      reference:(_)async=>PilotAlarmReference(graph:DayGraph(dayStart:base),wakeMinute:420),onSave:(_)async{}));
    final detail=find.byKey(const ValueKey('pilot-alarm-readout'));
    // Asleep for is a scrub value; at rest Usual sleep stays absent too.
    t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart)).controller.setScrub(base+400*60.0);await t.pump();
    final label=find.descendant(of:detail,matching:find.text('Asleep for'));expect(label,findsOneWidget);
    final cell=find.ancestor(of:label,matching:find.byType(Column)).first;
    expect(find.descendant(of:cell,matching:find.text('—')),findsOneWidget);
  });
}
