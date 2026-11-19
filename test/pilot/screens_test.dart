// why: these are the pilot's actual widget entry points, not painter snapshots.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/alarm_screen.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/pilot/timeline_policy.dart';
import 'package:openstrap_edge/pilot/day_layout.dart';
import 'package:openstrap_edge/pilot/pilot_readout.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_controller.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/state/prefs.dart';

Future<void> pump(WidgetTester t,Widget child)async{
  t.view.physicalSize=const Size(390,844);t.view.devicePixelRatio=1;addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme:buildTheme(Brightness.dark),localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,home:child));
  await t.pumpAndSettle();
}
void main(){
  setUp(()async{SharedPreferences.setMockInitialValues({});await Prefs.reload();});
  // catches: dimming disabled alarms by removing the timeline/readout's height.
  testWidgets('disabled alarm retains its row and list pins the next own entry',(t)async{
    await pump(t,PilotAlarmScreen(now:DateTime(2026,11,23,5),alarms:[PilotAlarm(id:'late',label:'Late',wakeMinute:600,enabled:false),PilotAlarm(id:'next',label:'Work',wakeMinute:390)],onSave:(_)async{}));
    final next=find.byKey(const ValueKey('pilot-alarm:next')),late=find.byKey(const ValueKey('pilot-alarm:late'));
    expect(t.getSize(next).height,t.getSize(late).height);
    expect(t.getTopLeft(next).dy,lessThan(t.getTopLeft(late).dy));
    expect(find.text('next'),findsOneWidget);expect(t.takeException(),null);
  });
  // catches: edits escaping the detached draft before Save.
  testWidgets('primary draft and repeat edits cancel without writing',(t)async{
    var writes=0;final a=PilotAlarm(id:'a',label:'Work');
    await pump(t,Scaffold(body:Builder(builder:(c)=>TextButton(onPressed:()=>Navigator.of(c).push(MaterialPageRoute(builder:(_)=>PilotAlarmEditor(alarm:a,now:DateTime(2026,11,23),onSave:(_)async{writes++;}))),child:const Text('Open')))));
    await t.tap(find.text('Open'));await t.pumpAndSettle();
    await t.drag(find.byType(ListView),const Offset(0,-350));await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pilot-primary')));await t.pumpAndSettle();
    expect(a.primary,false);expect(writes,0);
    await t.tap(find.text('Cancel').first);await t.pumpAndSettle();expect(writes,0);expect(find.text('Open'),findsOneWidget);expect(t.takeException(),null);
  });
  // catches: treating every drag as a scrub or keeping the temporary cursor.
  testWidgets('immediate move pans and hold scrubs without scroll feedback',(t)async{
    final c=TimelineController(homeStartSec:0,homeEndSec:86400)..selectRange(20000,50000);
    final s=TimelineInteraction(retention:PilotScrub.temporary);
    await pump(t,Scaffold(body:PilotTimelineChart(controller:c,graph:const DayGraph(),interaction:s)));
    final plot=find.byKey(const ValueKey('pilot-timeline-plot'));
    final gesture=await t.startGesture(t.getCenter(plot));await gesture.moveBy(const Offset(50,0));await t.pump();await gesture.up();
    expect(c.view.start,lessThan(20000));expect(c.scrub,null);
    final held=await t.startGesture(t.getCenter(plot));await t.pump(const Duration(milliseconds:350));
    expect(s.handScrubbing,true);final cursor=c.scrub,view=c.view;
    s.scroll();s.focus(100);await t.pump();expect(c.scrub,cursor);expect(c.view,view);
    await held.up();await t.pump();expect(c.scrub,null);
    await t.pumpWidget(const SizedBox());c.dispose();s.dispose();
  });
  // catches: keeping the duplicate for a manual pin or collapsing its original slot on auto-pin.
  testWidgets('manual pin moves original and automatic pin preserves its slot',(t)async{
    final c=TimelineController(homeStartSec:0,homeEndSec:86400),s=TimelineInteraction(),list=ScrollController();
    await pump(t,PilotDayLayout(title:'Day',dayRow:const SizedBox(height:48),graph:const DayGraph(),controller:c,interaction:s,tab:PilotTimelineTab.saved,onTab:(_){},listController:list,rows:const [SizedBox(height:1200)],annotations:const []));
    expect(s.pinned,false);
    s.startScrub(300);await t.pump();await t.pump(const Duration(milliseconds:800));
    expect(find.byType(PilotReadout,skipOffstage:false),findsNWidgets(2));
    s.lift();s.scroll();await t.pump();await t.pump(const Duration(milliseconds:800));
    expect(t.getSize(find.byType(AutomaticReadout)).height,0);
    s.togglePin();await t.pumpAndSettle();expect(find.byType(PilotReadout),findsOneWidget);
    expect(t.takeException(),null);
    await t.pumpWidget(const SizedBox());c.dispose();s.dispose();list.dispose();
  });
  // why: each enabled timing is an independently draggable Times item and graph handle.
  // catches: hiding a timing in a Waking dropdown, coupling all phone delays, or keeping absolute times when Wake moves.
  for(final step in ['sound','vibration','sunrise','flash'])testWidgets('$step timing drags in list and graph and follows Wake',(t)async{
    await PilotFlags.set(PilotFlag.wakeMethods,true);
    PilotAlarm? saved;
    final a=PilotAlarm(id:'a',label:'A',phoneSound:step=='sound',phoneVibration:step=='vibration',sunrise:step=='sunrise',phoneFlash:step=='flash',flashDelayMinutes:1);
    await pump(t,PilotAlarmEditor(alarm:a,now:DateTime(2026,11,23),onSave:(a)async{saved=a.copy();}));
    final row=find.byKey(ValueKey('pilot-time:$step'));expect(row,findsOneWidget);
    await t.ensureVisible(row);await t.pumpAndSettle();await t.drag(row,const Offset(20,0));await t.pumpAndSettle();
    await t.tap(row);await t.pumpAndSettle();
    var chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));
    final base=DateTime(2026,11,23).millisecondsSinceEpoch~/1000;
    // The list drag moves 10 min later: +1 becomes +11; Sunrise -30 becomes -20.
    expect(chart.handles.single.at,base+(step=='sunrise'?400:431)*60);
    chart.controller.selectRange(base+390*60,base+450*60);await t.pumpAndSettle();
    final plot=find.byKey(const ValueKey('pilot-timeline-plot')),rect=t.getRect(plot);
    final handle=chart.handles.single.at;
    final gesture=await t.startGesture(Offset(rect.left+(handle-(base+390*60))/3600*rect.width,rect.center.dy));
    await gesture.moveBy(Offset(rect.width/6,0));await gesture.up();await t.pumpAndSettle();
    chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));expect(chart.handles.single.at,base+(step=='sunrise'?410:440)*60);
    await t.ensureVisible(find.byKey(const ValueKey('pilot-time:wake')));await t.pumpAndSettle();await t.tap(find.byKey(const ValueKey('pilot-time:wake')));await t.pumpAndSettle();
    chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));
    final wakeGesture=await t.startGesture(Offset(rect.left+rect.width/2,rect.center.dy));await wakeGesture.moveBy(Offset(rect.width/6,0));await wakeGesture.up();await t.pumpAndSettle();
    await t.tap(find.text('Save').first);await t.pump();
    expect(saved!.wakeMinute,430);
    expect(switch(step){'sound'=>saved!.soundDelayMinutes,'vibration'=>saved!.vibrationDelayMinutes,'flash'=>saved!.flashDelayMinutes,_=>saved!.sunriseMinutes},step=='sunrise'?10:20);
    expect(t.takeException(),null);
  });
  // why: v16 bounds Sunrise to 5–60 min and phone escalation to 0–30 min.
  // catches: persisting arbitrarily large phone delays or a zero-duration Sunrise.
  testWidgets('timing rows clamp to v16 ranges and hidden methods have no row',(t)async{
    await PilotFlags.set(PilotFlag.wakeMethods,true);PilotAlarm? saved;
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',sunrise:true,phoneSound:true),now:DateTime(2026,11,23),onSave:(a)async{saved=a.copy();}));
    expect(find.byKey(const ValueKey('pilot-time:vibration')),findsNothing);
    for(final id in ['sunrise','sound']){final row=find.byKey(ValueKey('pilot-time:$id'));await t.ensureVisible(row);await t.pumpAndSettle();await t.drag(row,const Offset(200,0));await t.pumpAndSettle();}
    await t.tap(find.text('Save').first);await t.pump();expect(saved!.sunriseMinutes,5);expect(saved!.soundDelayMinutes,30);
  });
  // why: v16 points to the new timing without navigating away from Waking.
  // catches: one continuous flash or glowing the row on every return to Times.
  testWidgets('new Sunrise flashes Times twice then glows only on first view',(t)async{
    await PilotFlags.set(PilotFlag.wakeMethods,true);
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A'),now:DateTime(2026,11,23),onSave:(_)async{}));
    await t.tap(find.text('Waking'));await t.pumpAndSettle();await t.scrollUntilVisible(find.text('Sunrise alarm'),200,scrollable:find.byType(Scrollable).last);await t.tap(find.text('Sunrise alarm'));await t.pump();
    Color? tabColor(){final f=find.byKey(const ValueKey('pilot-times-flash'));return f.evaluate().isEmpty?null:(t.widget<DecoratedBox>(f).decoration as BoxDecoration).color;}
    await t.pump(const Duration(milliseconds:250));final first=tabColor();await t.pump(const Duration(milliseconds:250));expect(tabColor(),isNot(first));
    await t.pump(const Duration(milliseconds:250));expect(tabColor(),first);await t.pump(const Duration(milliseconds:250));
    await t.scrollUntilVisible(find.text('Phone sound'),200,scrollable:find.byType(Scrollable).last);await t.tap(find.text('Phone sound'));await t.pumpAndSettle();
    await t.tap(find.text('Times'));await t.pump();await t.pump(const Duration(milliseconds:450));
    final row=find.byKey(const ValueKey('pilot-time:sunrise'));
    Color? glow(Finder r)=>(t.widget<Container>(find.descendant(of:r,matching:find.byType(Container)).first).decoration as BoxDecoration).color;
    expect(glow(row)!.a,greaterThan(0));
    final sound=find.byKey(const ValueKey('pilot-time:sound'));expect(glow(sound)!.a,greaterThan(0));await t.pumpAndSettle();expect(glow(row),isNull);
    await t.tap(find.text('Waking'));await t.pumpAndSettle();await t.tap(find.text('Times'));await t.pump(const Duration(milliseconds:450));expect(glow(row),isNull);
  });
}
