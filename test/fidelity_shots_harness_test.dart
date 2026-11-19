// Disposable artifact harness. All readings are deterministic fictional fixtures.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/alarm_screen.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/sleep_editor.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'support/apk2_review_harness.dart';
import 'support/pilot_shots.dart';
import 'support/bundled_fonts.dart';

void main(){
  setUpAll(loadFonts);
  testWidgets('capture alarm and canonical sleep editor pilot',(t)async{
    final rig=await Apk2Rig.create(t);
    await PilotFlags.set(PilotFlag.alarmScreen,true);await PilotFlags.set(PilotFlag.wakeMethods,true);await PilotFlags.set(PilotFlag.timelines,true);
    t.view.physicalSize=const Size(390,844);t.view.devicePixelRatio=1;
    final start=DateTime(2026,11,22,12).millisecondsSinceEpoch~/1000;
    final graph=DayGraph(dayStart:start,hr:[for(var i=0;i<2880;i++)i%177<9?null:i<1150?54+(i%20)/3:68+(i%32)/3],movement:[for(var i=0;i<2880;i++)i < 1150 ? .04 : (i%17)/30],rest:[(690,1140,C.pink)]);
    final stages=<SleepStage?>[for(var i=0;i<576;i++)i<138||i>228?null:[SleepStage.light,SleepStage.deep,SleepStage.rem,SleepStage.awake][(i~/10)%4]];
    final alarms=[PilotAlarm(id:'work',label:'Work',wakeMinute:390,earlyMinutes:20,gradual:true,phoneSound:true,phoneVibration:true,sunrise:true,phoneFlash:true,primary:true,days:{1,2,3,5}),PilotAlarm(id:'run',label:'Run',type:PilotAlarmType.workout,wakeMinute:1140,days:{1,3}),PilotAlarm(id:'weekend',label:'Weekend',wakeMinute:600,enabled:false,days:{6,7})];
    Future<void> mount(Widget w)async{await t.pumpWidget(pilotShot(MaterialApp(key:UniqueKey(),debugShowCheckedModeBanner:false,theme:buildTheme(Brightness.dark),localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,home:w)));await t.pumpAndSettle();}
    await mount(PilotAlarmScreen(alarms:alarms,now:DateTime(2026,11,23,5),graph:graph,stages:stages,reference:(_)async=>PilotAlarmReference(graph:graph,stages:stages,bedMinute:-30,wakeMinute:390,usualSleepMinutes:400),onSave:(_)async{}));await takePilotShot(t,'alarm-list');
    await mount(PilotAlarmEditor(alarm:alarms.first,now:DateTime(2026,11,23),graph:graph,stages:stages,reference:(_)async=>PilotAlarmReference(graph:graph,stages:stages,bedMinute:-30,wakeMinute:390,usualSleepMinutes:400),onSave:(_)async{}));await takePilotShot(t,'alarm-times');
    final plot=find.byKey(const ValueKey('pilot-timeline-plot'));final scrub=await t.startGesture(t.getCenter(plot)+const Offset(-50,0));await t.pump(const Duration(milliseconds:350));await takePilotShot(t,'alarm-scrub');await scrub.up();await t.pumpAndSettle();
    final bed=find.byKey(const ValueKey('pilot-time:bed'));await t.drag(bed,const Offset(20,0));await t.pumpAndSettle();await takePilotShot(t,'alarm-bed-preview');
    await t.drag(find.byType(ListView),const Offset(0,-280));await t.pumpAndSettle();await takePilotShot(t,'alarm-times-escalation');
    await t.tap(find.text('Waking'));await t.pumpAndSettle();await takePilotShot(t,'alarm-waking');
    await t.drag(find.byType(ListView),const Offset(0,-500));await t.pumpAndSettle();await takePilotShot(t,'alarm-waking-methods');
    await t.tap(find.byTooltip('Next night'));await t.pumpAndSettle();await takePilotShot(t,'alarm-next-night');
    await mount(PilotAlarmEditor(alarm:alarms.first.copy()..band=false,now:DateTime(2026,11,23),graph:graph,stages:stages,onSave:(_)async{}));await t.drag(find.byType(ListView),const Offset(0,-350));await t.pumpAndSettle();await takePilotShot(t,'alarm-band-off-backup');
    await mount(PilotAlarmEditor(alarm:alarms[1],now:DateTime(2026,11,23),graph:graph,onSave:(_)async{}));await takePilotShot(t,'workout-window');
    final onset=DateTime(2026,11,22,23,30).millisecondsSinceEpoch~/1000,wake=DateTime(2026,11,23,7).millisecondsSinceEpoch~/1000;
    final read=SleepEditorRead(dayId:'2026-11-23',revision:null,draftGeneration:0,entries:[SleepEditorEntry(ref:DetectedMainRef('2026-11-23',onset,wake),kind:SleepBlockKind.main,day:'2026-11-23',startTs:onset,endTs:wake,provenance:SleepEntryProvenance.automatic,history:DetectedKnown(startTs:onset,endTs:wake,sourceDay:'2026-11-23',measures:{'asleep_min':400}),removed:false),SleepEditorEntry(ref:DetectedNapRef('2026-11-23',start+93600,start+96000),kind:SleepBlockKind.nap,day:'2026-11-23',startTs:start+93600,endTs:start+96000,provenance:SleepEntryProvenance.automatic,history:const DetectedAbsent(),removed:false)]);
    await mount(PilotSleepEditor(day:'2026-11-23',read:read,graph:graph,stages:stages,onSave:(_)async=>const SleepNoChange()));await takePilotShot(t,'sleep-editor');
    await t.pumpWidget(const SizedBox());
    await rig.mount(t,size:const Size(390,844),screen:pilotShot(MaterialApp(key:UniqueKey(),debugShowCheckedModeBanner:false,theme:buildTheme(Brightness.dark),localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,home:const DayTimelineScreen(day:apk2Day))));
    await t.pumpAndSettle();await takePilotShot(t,'day-pending');
    await t.tap(find.byKey(const ValueKey('pilot-tab:saved')));await t.pumpAndSettle();await takePilotShot(t,'day-saved');
    expect(t.takeException(),null);
  });
}
