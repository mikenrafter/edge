// WHY: slow pilot reads must reserve the screen before their first result.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/pilot/alarm_screen.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/pilot/pilot_readout.dart';
import 'package:openstrap_edge/pilot/day_layout.dart';
import 'package:openstrap_edge/pilot/timeline_policy.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_controller.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_summary.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Surface, SubTabs;
import '../support/skeleton_fixture.dart';
import '../support/pilot_shots.dart';
import '../support/as_of_recalc_fakes.dart' show SleepRepo;
import '../support/live_guide_harness.dart' show GuideFakeRepo;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/sleep_editor.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget host(Widget child)=>pilotShot(skHost(Scaffold(body:child),brightness:Brightness.dark));
class SlowSleepRepo extends SleepRepo {
  final days=Completer<List<String>>();
  final editor=Completer<SleepEditorRead>();
  @override Future<Map<String,dynamic>> getDaySleepV2(String day)async{
    final night=await super.getDaySleepV2(day);
    final start=DateTime(2026,11,19).millisecondsSinceEpoch~/1000;
    return {...night,'onset_ts':start,'wake_ts':start+486*60,'hypnogram':const []};
  }
  @override Future<List<String>> availableDays()=>days.future;
  @override Future<SleepEditorRead> readSleepEditor(String day)=>editor.future;
}
class SlowHomeRepo extends GuideFakeRepo {
  final gate=Completer<void>();
  SlowHomeRepo():super(withPending:false);
  @override Future<Map<String,dynamic>> getTodayStored()async{await gate.future;return getToday();}
}


void main() {
  setUpAll(skLoadAppFonts);
  setUp(()async{SharedPreferences.setMockInitialValues({});await Prefs.reload();});
  // catches: replacing the list with a centered progress indicator.
  testWidgets('alarm read reserves the first card and keeps its chart position', (t) async {
    skTallView(t, w:390, h:844);
    final read=Completer<List<PilotAlarm>>();
    await t.pumpWidget(host(PilotAlarmScreen(loadAlarms:()=>read.future,onSave:(_)async{})));
    await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(find.byType(CircularProgressIndicator),findsNothing);
    expect(find.byType(LinearProgressIndicator),findsNothing);
    expect(find.byType(PendingContent),findsWidgets);
    await takePilotShot(t,'alarms-loading');
    final before=t.getRect(find.byType(PilotTimelineChart).first);
    read.complete([PilotAlarm(id:'one',label:'Morning'),PilotAlarm(id:'two',label:'Evening',wakeMinute:1140)]);
    await t.pump();await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(t.getRect(find.byType(PilotTimelineChart).first),before);
    expect(t.takeException(),isNull);
    await takePilotShot(t,'alarms-loaded');
    await t.pumpWidget(const SizedBox());
  });
  // catches: painting the empty reference as a settled chart during a slow read.
  testWidgets('alarm editor reserves reference chart and night pager', (t) async {
    skTallView(t, w:390, h:844);
    final read=Completer<PilotAlarmReference?>(),next=Completer<PilotAlarmReference?>();var reads=0;
    await t.pumpWidget(host(PilotAlarmEditor(alarm:PilotAlarm(id:'one',label:'Morning'),onSave:(_)async{},reference:(_)=>reads++==0?read.future:next.future)));
    await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(find.byType(CircularProgressIndicator),findsNothing);
    expect(find.byType(LinearProgressIndicator),findsNothing);
    expect(t.widgetList<PendingContent>(find.byType(PendingContent)).any((w)=>w.pending),isTrue);
    await takePilotShot(t,'alarm-editor-loading');
    final chart=t.getRect(find.byType(PilotTimelineChart).first);
    final pager=t.getRect(find.byKey(const ValueKey('pilot-night-pager')));
    read.complete(PilotAlarmReference(graph:DayGraph(dayStart:DateTime.now().millisecondsSinceEpoch~/1000,hr:List.filled(1440,62)),bedMinute:-60,wakeMinute:420,usualSleepMinutes:480));await t.pump();await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(t.getRect(find.byType(PilotTimelineChart).first),chart);
    expect(t.getRect(find.byKey(const ValueKey('pilot-night-pager'))),pager);
    await takePilotShot(t,'alarm-editor-loaded');
    await t.tap(find.byKey(const ValueKey('pilot-night-next')));await t.pump();
    expect(reads,2);
    expect(t.widgetList<PendingContent>(find.byType(PendingContent)).any((w)=>w.pending),isTrue);
    expect(t.getRect(find.byType(PilotTimelineChart).first),chart);
    next.complete(null);await t.pump();await t.pump(const Duration(milliseconds:700));
    expect(t.getRect(find.byKey(const ValueKey('pilot-night-pager'))),pager);
    await t.pumpWidget(const SizedBox());
  });
  // catches: a loading caption inserted above the weekly chart then removed.
  testWidgets('observations slow retry reserves chart position', (t) async {
    skTallView(t,w:390,h:844);
    final read=Completer<List<PulseEpisodeSummary>>();
    await t.pumpWidget(host(SimplifiedFindingsLog(const [],loadEpisodes:()=>read.future,today:'2026-11-19')));
    await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(t.widgetList<PendingContent>(find.byType(PendingContent)).any((w)=>w.pending),isTrue);
    await takePilotShot(t,'observations-loading');
    final first=t.getTopLeft(find.byType(Surface).first);
    read.complete([]);await t.pump();await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(t.getTopLeft(find.byType(Surface).first),first);
    await takePilotShot(t,'observations-loaded');
    await t.pumpWidget(const SizedBox());
  });
  // catches: returning the centered spinner instead of the editable layout.
  testWidgets('sleep editor slow read reserves day bar and chart',(t)async{
    skTallView(t,w:390,h:844);
    final repo=SlowSleepRepo(),app=AppState.forTesting();app.repo=repo;
    await t.pumpWidget(host(ChangeNotifierProvider<AppState>.value(value:app,child:const PilotSleepEditor(day:'2026-11-19'))));
    await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(find.byType(CircularProgressIndicator),findsNothing);
    expect(find.byType(LinearProgressIndicator),findsNothing);
    expect(find.byType(PilotTimelineChart),findsOneWidget);
    final rect=t.getRect(find.byType(PilotTimelineChart));
    expect(t.widget<SubTabs>(find.byType(SubTabs)).items,['Sleep']);
    final readout=t.getRect(find.byType(PilotReadout));
    await takePilotShot(t,'sleep-editor-loading');
    final start=DateTime(2026,11,19,1).millisecondsSinceEpoch~/1000,end=DateTime(2026,11,19,8).millisecondsSinceEpoch~/1000;
    repo.editor.complete(SleepEditorRead(dayId:'2026-11-19',entries:[SleepEditorEntry(ref:DetectedNapRef('2026-11-19',start,end),kind:SleepBlockKind.nap,day:'2026-11-19',startTs:start,endTs:end,provenance:SleepEntryProvenance.automatic,history:const DetectedAbsent(),removed:false)],revision:null,draftGeneration:0));
    await t.pump();await t.pump(const Duration(milliseconds:700));
    expect(t.getRect(find.byType(PilotTimelineChart)),rect);
    expect(t.getTopLeft(find.byType(PilotReadout)),readout.topLeft);
    await takePilotShot(t,'sleep-editor-loaded');
    await t.pumpWidget(const SizedBox());app.dispose();
  });
  // catches: loading the landed timeline before switching to the pilot's chart.
  for(final personal in [false,true])testWidgets('pilot timeline reserves chart personal=$personal',(t)async{
    skTallView(t,w:390,h:844);await PilotFlags.set(PilotFlag.timelines,true);
    if(personal)await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    await t.pumpWidget(host(const DayTimelineScreen(resolving:true,day:'2026-11-19')));
    await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(find.byType(PilotTimelineChart),findsOneWidget);
    expect(find.byType(CircularProgressIndicator),findsNothing);
    expect(find.byType(LinearProgressIndicator),findsNothing);
    final rect=t.getRect(find.byType(PilotTimelineChart));
    expect(t.widget<SubTabs>(find.byType(SubTabs)).badges.values.every((w)=>w is PendingContent&&w.pending),isTrue);
    await takePilotShot(t,'timeline-${personal?'personal':'calendar'}-loading');
    await t.pumpWidget(host(const DayTimelineScreen(key:ValueKey('loaded'),data:TimelineData(day:'2026-11-19'),day:'2026-11-19')));
    await t.pump(const Duration(milliseconds:700));
    expect(t.getRect(find.byType(PilotTimelineChart)),rect);
    await takePilotShot(t,'timeline-${personal?'personal':'calendar'}-loaded');
    await t.pumpWidget(const SizedBox());
  });
  // catches: replacing the pilot summary's geometry while the primary read waits.
  testWidgets('sleep summary slow read keeps its first section position',(t)async{
    skTallView(t,w:390,h:844);await PilotFlags.set(PilotFlag.sleepSummary,true);
    final repo=SlowSleepRepo(),app=AppState.forTesting();app.repo=repo;
    await t.pumpWidget(host(ChangeNotifierProvider<AppState>.value(value:app,child:const SleepDetail(day:'2026-11-19'))));
    await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(find.byType(CircularProgressIndicator),findsNothing);
    expect(find.byType(LinearProgressIndicator),findsNothing);
    expect(t.widgetList<PendingContent>(find.byType(PendingContent)).any((w)=>w.pending),isTrue);
    final summary=t.getTopLeft(find.byKey(const ValueKey('sleep-summary')));
    final nextSection=t.getTopLeft(find.byKey(const ValueKey('section:night')));
    await takePilotShot(t,'sleep-summary-loading');
    repo.days.complete(['2026-11-19']);await t.pump();await t.pump(const Duration(milliseconds:700));
    expect(t.getTopLeft(find.byKey(const ValueKey('sleep-summary'))),summary);
    expect(t.getTopLeft(find.byKey(const ValueKey('section:night'))),nextSection);
    await takePilotShot(t,'sleep-summary-loaded');
    expect(t.takeException(),isNull);
    await t.pumpWidget(const SizedBox());app.dispose();
  });
  // catches: inserting the personal-day caption above the rings on settlement.
  for(final personal in [false,true])testWidgets('Home reserves rings personal=$personal',(t)async{
    skTallView(t,w:390,h:844);
    if(personal)await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    final repo=SlowHomeRepo(),app=AppState.forTesting();app.repo=repo;
    await t.pumpWidget(host(ChangeNotifierProvider<AppState>.value(value:app,child:const HomeScreen())));
    await t.pump(const Duration(milliseconds:500));await t.pump(const Duration(milliseconds:300));
    expect(find.byType(CircularProgressIndicator),findsNothing);
    expect(find.byType(LinearProgressIndicator),findsNothing);
    final rect=t.getRect(find.byType(RingTrio));
    await takePilotShot(t,'home-${personal?'personal':'calendar'}-loading');
    repo.gate.complete();await t.pump();await t.pump(const Duration(milliseconds:700));
    expect(t.getTopLeft(find.byType(RingTrio)),rect.topLeft);
    await takePilotShot(t,'home-${personal?'personal':'calendar'}-loaded');
    expect(t.takeException(),isNull);
    await t.pumpWidget(const SizedBox());app.dispose();
  });

  // catches: removing the pending row owner and instantly moving its next link.
  testWidgets('empty pilot row area settles without a first-frame jump',(t)async{
    skTallView(t,w:390,h:844);
    final controller=TimelineController(homeStartSec:0,homeEndSec:86400),interaction=TimelineInteraction(retention:PilotScrub.temporary),scroll=ScrollController();
    var pending=true;late StateSetter change;
    await t.pumpWidget(host(StatefulBuilder(builder:(context,set){change=set;return PilotDayLayout(title:'Day',dayRow:const SizedBox(height:44),graph:const DayGraph(),controller:controller,interaction:interaction,tab:PilotTimelineTab.pending,onTab:(_){},listController:scroll,rows:const [],annotations:const [],pending:pending,after:const [Text('Following',key:ValueKey('following'))]);})));
    await t.pump(const Duration(milliseconds:800));
    final before=t.getTopLeft(find.byKey(const ValueKey('following')));
    change(()=>pending=false);await t.pump();
    expect(t.getTopLeft(find.byKey(const ValueKey('following'))),before);
    await t.pump(const Duration(milliseconds:700));
    expect(t.getTopLeft(find.byKey(const ValueKey('following'))).dy,lessThan(before.dy));
    await t.pumpWidget(const SizedBox());controller.dispose();interaction.dispose();scroll.dispose();
  });

}
