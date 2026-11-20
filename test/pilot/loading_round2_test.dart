// WHY: locally known alarm state and screen chrome must paint before slow reads.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/alarm_screen.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/pilot/timeline_policy.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion, accordionPrefKey;
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/skeleton_fixture.dart';
import '../support/pilot_shots.dart';
import 'loading_placeholders_test.dart' show SlowSleepRepo;

Widget host(Widget child)=>pilotShot(skHost(Scaffold(body:child),brightness:Brightness.dark));
void main(){
  setUpAll(skLoadAppFonts);
  setUp(()async{SharedPreferences.setMockInitialValues({});await Prefs.reload();});
  // catches: a synthetic enabled card, or pending paint around the real header.
  testWidgets('prefs alarm cards expose real count states and times before forecasts',(t)async{
    skTallView(t,w:390,h:1100);
    final semantics=t.ensureSemantics();try{
    final alarms=[PilotAlarm(id:'off',label:'Weekend rest',enabled:false,wakeMinute:510,days:{6,7}),PilotAlarm(id:'on',label:'Morning',wakeMinute:390,days:{1,2,3,4,5})];
    SharedPreferences.setMockInitialValues({PilotAlarmStore.key:jsonEncode([for(final a in alarms)a.toJson()])});await Prefs.reload();
    final reference=Completer<PilotAlarmReference?>();
    await t.pumpWidget(host(PilotAlarmScreen(now:DateTime(2026,11,19),onSave:(_)async{},reference:(_)=>reference.future)));
    // The cached local store is available on the very first frame.
    for(final alarm in alarms){
      final card=find.byKey(ValueKey('pilot-alarm:${alarm.id}'));
      expect(card,findsOneWidget);
      expect(t.widget<Switch>(find.descendant(of:card,matching:find.byType(Switch))).value,alarm.enabled);
      expect(find.text(alarm.label),findsOneWidget);
    }
    expect(find.byType(Switch),findsNWidgets(2));
    await t.pump(const Duration(milliseconds:250));await t.pump(const Duration(milliseconds:300));
    expect(find.bySemanticsLabel(RegExp('Morning')),findsWidgets);
    expect(find.text('Weekdays'),findsOneWidget);expect(find.text('Weekends'),findsOneWidget);
    expect(find.text('6:30 AM'),findsWidgets);expect(find.text('8:30 AM'),findsWidgets);
    await takePilotShot(t,'r2-alarms-loading');
    reference.complete(PilotAlarmReference(graph:DayGraph(dayStart:DateTime(2026,11,19).millisecondsSinceEpoch~/1000,hr:List.filled(1440,62),movement:List.filled(1440,.1)),bedMinute:-30,wakeMinute:390,usualSleepMinutes:420));await t.pump();await t.pump(const Duration(milliseconds:700));
    await takePilotShot(t,'r2-alarms-loaded');expect(t.takeException(),isNull);
    await t.pumpWidget(const SizedBox());
    }finally{semantics.dispose();}
  });
  // catches: treating malformed saved metadata as an empty, successful read.
  testWidgets('malformed alarm prefs show the read error without fabricated cards',(t)async{
    SharedPreferences.setMockInitialValues({PilotAlarmStore.key:''});await Prefs.reload();
    await expectLater(PilotAlarmStore.load(),throwsFormatException);
    await t.pumpWidget(host(PilotAlarmScreen(onSave:(_)async{})));
    expect(find.byType(Switch),findsNothing);
    expect(find.textContaining('FormatException'),findsOneWidget);
    expect(find.text('No alarms'),findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  // catches: the whole accordion being treated as pending, hiding its header.
  for(final embedded in [false,true])testWidgets('sleep remembered headers are live before data embedded=$embedded',(t)async{
    skTallView(t,w:390,h:1800);
    final semantics=t.ensureSemantics();try{
    SharedPreferences.setMockInitialValues({PilotFlag.sleepSummary.key:true,
      for(final id in ['night','unusual','versus','context','plan','stages','tonight'])accordionPrefKey('sleep_$id'):false,
      accordionPrefKey('sleep_overnight'):true});await Prefs.reload();
    final repo=SlowSleepRepo(),app=AppState.forTesting();app.repo=repo;
    await t.pumpWidget(host(ChangeNotifierProvider<AppState>.value(value:app,child:SleepDetail(day:'2026-11-19',embedded:embedded))));
    await t.pump(const Duration(milliseconds:250));await t.pump(const Duration(milliseconds:300));
    final accordions=t.widgetList<SettingsAccordion>(find.byType(SettingsAccordion)).toList();
    expect(accordions,isNotEmpty);
    for(final accordion in accordions){
      expect(find.bySemanticsLabel(RegExp(RegExp.escape('${accordion.title}, ${accordion.id=='sleep_overnight'?'expanded':'collapsed'}'))),findsOneWidget);
      final scope=find.ancestor(of:find.byWidget(accordion),matching:find.byType(PendingContent));
      expect(t.widgetList<PendingContent>(scope).any((w)=>w.pending),isFalse);
      expect(find.descendant(of:find.byWidget(accordion),matching:find.byIcon(accordion.id=='sleep_overnight'?LucideIcons.chevronUp:LucideIcons.chevronDown)),findsWidgets);
      if(accordion.id=='sleep_overnight')expect(t.widgetList<PendingContent>(find.descendant(of:find.byWidget(accordion),matching:find.byType(PendingContent))).any((w)=>w.pending),isTrue);
    }
    expect(find.byIcon(LucideIcons.chevronDown),findsWidgets);
    expect(find.byKey(const ValueKey('pilot-sleep-signal-axis')),findsOneWidget);
    expect(find.byKey(const ValueKey('pilot-sleep-day-axis')),embedded?findsOneWidget:findsNothing);
    await takePilotShot(t,'r2-sleep-${embedded?'tab':'detail'}-loading');
    repo.days.complete(['2026-11-19']);await t.pump();await t.pump(const Duration(milliseconds:700));
    await takePilotShot(t,'r2-sleep-${embedded?'tab':'detail'}-loaded');
    for(final accordion in accordions)expect(find.bySemanticsLabel(RegExp(RegExp.escape('${accordion.title}, ${accordion.id=='sleep_overnight'?'expanded':'collapsed'}'))),findsOneWidget);
    expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox());app.dispose();
    }finally{semantics.dispose();}
  });
  // catches: expanding Usual into a one-row no-history verdict while reading.
  testWidgets('expanded usual section reserves its comparison rows',(t)async{
    skTallView(t,w:390,h:1800);
    SharedPreferences.setMockInitialValues({PilotFlag.sleepSummary.key:true,
      for(final id in ['night','unusual','overnight','plan','stages','tonight'])accordionPrefKey('sleep_$id'):false,
      accordionPrefKey('sleep_versus'):true});await Prefs.reload();
    final repo=SlowSleepRepo(),app=AppState.forTesting();app.repo=repo;
    await t.pumpWidget(host(ChangeNotifierProvider<AppState>.value(value:app,child:const SleepDetail(day:'2026-11-19',embedded:true))));
    await t.pump(const Duration(milliseconds:500));
    final rows=find.byKey(const ValueKey('sleep-versus-pending'));expect(rows,findsOneWidget);
    expect(t.getSize(rows).height,320);
    expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox());app.dispose();
  });
  // catches: axis labels living inside the substituted data painter.
  testWidgets('pending pilot chart paints its known time bounds and axis',(t)async{
    skTallView(t,w:390,h:400);
    final start=DateTime(2026,11,19).millisecondsSinceEpoch~/1000;
    final controller=TimelineController(homeStartSec:start,homeEndSec:start+7200),interaction=TimelineInteraction(retention:PilotScrub.temporary);
    await t.pumpWidget(host(PendingContent(pending:true,child:PilotTimelineChart(controller:controller,graph:const DayGraph(),interaction:interaction))));
    await t.pump(const Duration(milliseconds:250));await t.pump(const Duration(milliseconds:300));
    for(var i=0;i<=4;i++){
      final label=find.text(pilotClock(start+i*1800.0));
      expect(label,findsOneWidget);
      expect(find.ancestor(of:label,matching:find.byType(PendingStatic)),findsOneWidget);
    }
    expect(find.byKey(const ValueKey('pilot-chart-frame')),findsOneWidget);
    expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox());controller.dispose();interaction.dispose();
  });
  // catches: compressed-night tick labels painting over each other or losing bounds.
  testWidgets('compressed pilot time axis keeps both bounds without overlap',(t)async{
    skTallView(t,w:390,h:400);
    final start=DateTime(2026,11,19).millisecondsSinceEpoch~/1000;
    final controller=TimelineController(homeStartSec:start,homeEndSec:start+9*3600),interaction=TimelineInteraction(retention:PilotScrub.temporary);
    await t.pumpWidget(host(PendingContent(pending:true,child:PilotTimelineChart(controller:controller,graph:const DayGraph(),interaction:interaction,cut:PilotTimelineCut(leftEnd:start+80*60,rightStart:start+8*3600)))));
    await t.pump(const Duration(milliseconds:500));
    expect(find.text(pilotClock(start.toDouble())),findsOneWidget);
    expect(find.text(pilotClock(start+9*3600.0)),findsOneWidget);
    final labels=find.byWidgetPredicate((w)=>w is Text&&w.key is ValueKey<String>&&(w.key as ValueKey<String>).value.startsWith('pilot-axis:'));
    final rects=[for(final element in labels.evaluate())t.getRect(find.byWidget(element.widget))]..sort((a,b)=>a.left.compareTo(b.left));
    expect(rects.length,greaterThanOrEqualTo(2));
    for(var i=1;i<rects.length;i++)expect(rects[i-1].right,lessThanOrEqualTo(rects[i].left));
    expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox());controller.dispose();interaction.dispose();
  });

}
