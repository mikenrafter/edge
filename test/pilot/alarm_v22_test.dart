// why: owner m217/m220 pins this pilot batch at the actual widget seams.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/pilot/pilot_theme.dart' show PilotSegmented;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/alarm_screen.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/pilot/sunrise_overlay.dart';
import 'package:openstrap_edge/pilot/wake_runtime.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/platform/device_actions.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'screens_test.dart' show pump;

void main(){
  final day=DateTime(2026,11,23),base=DateTime(2026,11,23).millisecondsSinceEpoch~/1000;
  setUp(()async{SharedPreferences.setMockInitialValues({});await Prefs.reload();await PilotFlags.set(PilotFlag.wakeMethods,true);ClockFormatController.seed(ClockFormat.h24);});
  tearDown(ClockFormatController.debugReset);
  PilotAlarmReference sample({int bed=-30,int wake=390,int sleep=420})=>PilotAlarmReference(graph:DayGraph(dayStart:base,hr:List.filled(1440,62),movement:List.filled(1440,.1)),bedMinute:bed,wakeMinute:wake,usualSleepMinutes:sleep);
  // catches: paging calendar days instead of this alarm's enabled nights, stale references, or changing repeats.
  testWidgets('night pager follows repeat days and loads that weekday without changing the alarm',(t)async{
    final dates=<DateTime>[];PilotAlarm? saved;
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',days:{1,3},earlyMinutes:60),now:day,
      reference:(d)async{dates.add(d);return sample(bed:d.weekday==1?-30:-20,wake:d.weekday==1?390:400);},onSave:(a)async{saved=a.copy();}));
    expect(dates,[DateTime(2026,11,23)]);expect(find.text('Tonight'),findsOneWidget);
    expect(t.widget<IconButton>(find.ancestor(of:find.byTooltip('Previous night'),matching:find.byType(IconButton))).onPressed,null);
    final chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));
    expect(chart.controller.view.start,base+340*60);expect(chart.controller.view.end,base+440*60);expect(chart.handles.single.id,'wake');
    await t.tap(find.byTooltip('Next night'));await t.pumpAndSettle();
    expect(dates,[DateTime(2026,11,23),DateTime(2026,11,25)]);expect(find.text('Wed, Nov 25'),findsOneWidget);
    expect(find.byKey(const ValueKey('pilot-time:bed')),findsOneWidget);
    await t.tap(find.text('Save'));await t.pump();expect(saved!.days,{1,3});expect(saved!.referenceWakeMinute,390);expect(t.takeException(),null);
  });
  // catches: allowing Once to page into nights that will never ring, or retaining the removed Tonight tab.
  testWidgets('Once has one preview night and only Times and Waking tabs',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',days:{}),now:day,onSave:(_)async{}));
    expect(t.widget<IconButton>(find.ancestor(of:find.byTooltip('Next night'),matching:find.byType(IconButton))).onPressed,null);
    Finder tab(String text)=>find.descendant(of:find.byType(PilotSegmented),matching:find.text(text));
    expect(tab('Tonight'),findsNothing);
    expect(tab('Times'),findsOneWidget);expect(tab('Waking'),findsOneWidget);
    expect(find.byKey(const ValueKey('pilot-time:bed')),findsNothing);
  });
  // catches: an icon hidden behind its thumb or a zoom that jumps instead of gliding.
  testWidgets('annotation selects its own timing and alarm zoom glides without a cursor',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',sunrise:true,sunriseMinutes:10),now:day,onSave:(_)async{}));
    final chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));
    await t.tap(find.byTooltip('Sunrise alarm'));await t.pumpAndSettle();
    expect(t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart)).handles.single.id,'sunrise');
    chart.controller.setScrub(base+410*60.0);await t.pump();
    await t.tap(find.text('Zoom out'));await t.pump();final before=chart.controller.view.span;
    expect(chart.controller.scrub,null);await t.pump(const Duration(milliseconds:225));expect(chart.controller.view.span,greaterThan(before));expect(chart.controller.view.span,lessThan(86400));
    await t.pump(const Duration(milliseconds:250));expect(chart.controller.view.span,86400);expect(t.takeException(),null);
  });
  // catches: inserting a different-height scrub panel or changing chart/row positions while the hand moves.
  testWidgets('alarm scrub changes its readout without shifting the chart tabs or Times list',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A'),now:day,reference:(_)async=>sample(),onSave:(_)async{}));
    final plot=find.byKey(const ValueKey('pilot-timeline-plot')),row=find.byKey(const ValueKey('pilot-time:bed')),detail=find.byKey(const ValueKey('pilot-alarm-readout'));
    final plotRect=t.getRect(plot),rowRect=t.getRect(row),detailSize=t.getSize(detail);
    final held=await t.startGesture(Offset(plotRect.left+plotRect.width*.22,plotRect.center.dy));await t.pump(const Duration(milliseconds:350));
    expect(t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart)).controller.scrub,isNotNull);
    expect(find.descendant(of:detail,matching:find.text('Stage')),findsOneWidget);expect(t.getSize(detail),detailSize);expect(t.getRect(row),rowRect);expect(t.getRect(plot),plotRect);
    await held.moveBy(const Offset(40,0));await t.pump();expect(t.getRect(row),rowRect);await held.up();await t.pump();expect(t.getSize(detail),detailSize);expect(t.takeException(),null);
  });
  // catches: silently persisting a what-if, adding another subtitle line, or forgetting Preview orange/Reset (m225).
  testWidgets('Fall asleep preview uses one unsaved subtitle and orange time then Reset restores recorded bedtime',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A'),now:day,reference:(_)async=>sample(),onSave:(_)async{}));
    final row=find.byKey(const ValueKey('pilot-time:bed'));final before=t.getSize(row).height;
    expect(find.descendant(of:row,matching:find.text('your usual')),findsOneWidget);
    await t.drag(row,const Offset(20,0));await t.pumpAndSettle();
    expect(find.descendant(of:row,matching:find.text('what-if · not saved')),findsOneWidget);expect(t.getSize(row).height,before);
    final time=t.widget<Text>(find.descendant(of:row,matching:find.text('23:40')));expect(time.style!.color,const Color(0xFFF5A36B));
    await t.tap(find.descendant(of:row,matching:find.text('Reset')));await t.pumpAndSettle();expect(find.descendant(of:row,matching:find.text('your usual')),findsOneWidget);expect(find.descendant(of:row,matching:find.text('23:30')),findsOneWidget);
  });
  // catches: showing only Wake in the overview, duplicating coincident time labels, or omitting the overnight cut.
  testWidgets('overview cuts the night and labels every time with coincident icons stacked vertically',(t)async{
    await pump(t,PilotAlarmScreen(alarms:[PilotAlarm(id:'a',label:'A',wakeMinute:390,phoneSound:true,soundDelayMinutes:0,phoneVibration:true,vibrationDelayMinutes:0)],now:day,reference:(_)async=>sample(),onSave:(_)async{}));
    final chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));expect(chart.overview,true);expect(chart.cut,isNotNull);expect(find.byKey(const ValueKey('pilot-overview-cut')),findsOneWidget);
    final time=find.byKey(ValueKey('pilot-overview-time:${base+390*60}'));expect(time,findsOneWidget);
    final group=find.ancestor(of:time,matching:find.byType(Row)).first;
    final icons=find.descendant(of:group,matching:find.byType(Icon));expect(icons,findsNWidgets(4));
    expect(t.getTopLeft(icons.at(1)).dy,greaterThan(t.getTopLeft(icons.first).dy));expect(t.getTopLeft(icons.at(1)).dx,t.getTopLeft(icons.first).dx);
    expect(find.text('Usual sleep'),findsOneWidget);expect(find.text('Sleep'),findsNothing);expect(t.takeException(),null);
  });
  // catches: hiding the recorded usual-sleep stat merely because expected wake is outside the window.
  testWidgets('overview hides Usual sleep only when the recorded bedtime is absent',(t)async{
    await pump(t,PilotAlarmScreen(alarms:[PilotAlarm(id:'a',label:'A')],now:day,reference:(_)async=>sample(wake:500,sleep:530),onSave:(_)async{}));
    expect(find.text('Usual sleep'),findsOneWidget);expect(find.text('~8 h 50 min'),findsOneWidget);
    await t.pumpWidget(const SizedBox());await pump(t,PilotAlarmScreen(alarms:[PilotAlarm(id:'a',label:'A')],now:day,onSave:(_)async{}));expect(find.text('Usual sleep'),findsNothing);
  });
  // catches: cancelling a flash-only backup before a foreground frame is shown.
  testWidgets('flash keeps backup until a foreground screen effect is rendered',(t)async{
    final fire=DateTime(2026,11,23,7),cancelled=<DateTime>[];
    final a=PilotAlarm(id:'a',label:'A',days:{1},band:false,phoneFlash:true,flashDelayMinutes:0);
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(_,_)async{},phone:(_,_)async=>false,fireApp:(_,_)async=>true,cancelBackup:(_,at)async{cancelled.add(at);},isEnabled:()=>true);
    await r.tick(now:fire,connected:true,alarms:[a]);expect(cancelled,isEmpty);
    await t.pumpWidget(MaterialApp(home:PilotWakeLight(runtime:r,torch:(_)async=>false,child:const SizedBox())));await t.pump();
    expect(find.byKey(const ValueKey('pilot-screen-flash')),findsOneWidget);
    await r.tick(now:fire.add(const Duration(seconds:30)),connected:true,alarms:[a]);expect(cancelled,[fire]);
    await t.pumpWidget(const SizedBox());await t.pump();r.dispose();
  });
  // catches: timing Flash from Latest/expected, or stopping screen flash when the torch cannot be opened.
  testWidgets('flash anchors to the early real fire and falls back to screen when torch is unavailable',(t)async{
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(_,_)async{},phone:(_,_)async=>true,isEnabled:()=>true);
    final a=PilotAlarm(id:'a',label:'A',phoneFlash:true,flashDelayMinutes:5,referenceWakeMinute:420);
    var now=DateTime(2026,11,23,6,45);final calls=<bool>[];
    r.noteFire(a,now);
    await pump(t,PilotWakeLight(runtime:r,torch:(on)async{calls.add(on);return false;},child:const Scaffold(body:Text('Alarm'))));
    now=DateTime(2026,11,23,6,49,59);await r.tick(now:now,connected:false,alarms:[a]);await t.pump();expect(find.byKey(const ValueKey('pilot-screen-flash')),findsNothing);expect(calls,[]);
    now=DateTime(2026,11,23,6,50);await r.tick(now:now,connected:false,alarms:[a]);await t.pump();expect(find.byKey(const ValueKey('pilot-screen-flash')),findsOneWidget);expect(calls,[true]);
    await t.pump(const Duration(milliseconds:700));expect(find.byKey(const ValueKey('pilot-screen-flash')),findsNothing);await t.pump(const Duration(milliseconds:700));expect(find.byKey(const ValueKey('pilot-screen-flash')),findsOneWidget);expect(calls,[true]);
    r.acknowledge();await t.pump();expect(find.byKey(const ValueKey('pilot-screen-flash')),findsNothing);await t.pumpWidget(const SizedBox());r.dispose();
  });
  // catches: using a toggle for cleanup, leaving a successful torch on during snooze, or leaking it on route teardown.
  testWidgets('flash sends explicit torch states and clears it for snooze and disposal',(t)async{
    const channel=MethodChannel('openstrap/device_actions');final states=<bool>[],methods=<String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{methods.add(call.method);states.add((call.arguments as Map)['enabled'] as bool);return true;});
    addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null));
    expect(await DeviceActions.setTorch(false),true);expect(states,[false]);states.clear();
    final now=DateTime(2026,11,23,7),a=PilotAlarm(id:'a',label:'A',phoneFlash:true,flashDelayMinutes:0);
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(_,_)async{},phone:(_,_)async=>true,isEnabled:()=>true);r.noteFire(a,now);
    await pump(t,PilotWakeLight(runtime:r,child:const Scaffold()));await r.tick(now:now,connected:true,alarms:[a]);await t.pump();await t.pump();expect(r.flash.value,true);expect(find.byKey(const ValueKey('pilot-screen-flash')),findsOneWidget);expect(states,[true]);
    await r.tick(now:now,connected:true,alarms:[a],snoozed:true);await t.pump();expect(states,[true,false]);
    await r.tick(now:now,connected:true,alarms:[a]);await t.pump();expect(states,[true,false,true]);await t.pumpWidget(const SizedBox());await t.pump();expect(states,[true,false,true,false]);expect(methods,everyElement('setTorch'));r.dispose();
  });
}
