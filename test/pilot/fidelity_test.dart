// why: owner m233 fidelity fixes against the signed-off mock-ups (alarms v22,
// day timeline v16, sleep editor v11). Behaviour checks, not pixel goldens.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/alarm_screen.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/pilot_readout.dart';
import 'package:openstrap_edge/pilot/pilot_theme.dart';
import 'package:openstrap_edge/pilot/sleep_editor.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_controller.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show SubTabs, BigButton;
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'screens_test.dart' show pump;

void main(){
  final day=DateTime(2026,11,23),base=day.millisecondsSinceEpoch~/1000;
  setUp(()async{SharedPreferences.setMockInitialValues({});await Prefs.reload();await PilotFlags.set(PilotFlag.wakeMethods,true);ClockFormatController.seed(ClockFormat.h24);});
  tearDown(ClockFormatController.debugReset);
  PilotAlarmReference sample()=>PilotAlarmReference(graph:DayGraph(dayStart:base,hr:List.filled(1440,62),movement:List.filled(1440,.1)),bedMinute:-30,wakeMinute:390,usualSleepMinutes:400);

  // catches: PilotTheme recolouring every Switch (blue track, dark thumb) unlike the rest of the app.
  testWidgets('pilot theme keeps the app colour scheme for switches',(t)async{
    ColorScheme? outer,inner;
    await pump(t,Builder(builder:(c){outer=Theme.of(c).colorScheme;return PilotTheme(child:Builder(builder:(c){inner=Theme.of(c).colorScheme;return const SizedBox();}));}));
    expect(inner!.primary,outer!.primary);
  });

  // catches: "FriNext" (next glued to the days), the end time labelled Window, or minutes-only durations.
  testWidgets('alarm list card follows v22 head and stats',(t)async{
    await pump(t,PilotAlarmScreen(alarms:[PilotAlarm(id:'w',label:'Work',wakeMinute:390,earlyMinutes:20,days:{1,2,3,5}),PilotAlarm(id:'r',label:'Run',type:PilotAlarmType.workout,wakeMinute:1140,days:{1,3})],now:DateTime(2026,11,23,5),reference:(_)async=>sample(),onSave:(_)async{}));
    expect(find.text('next'),findsOneWidget);
    expect(find.text('06:10–06:30'),findsOneWidget);
    expect(find.text('~6h 40m'),findsOneWidget);expect(find.text('400 min'),findsNothing);
    expect(find.text('17:30–19:00'),findsOneWidget);expect(find.text('Zone 3+'),findsOneWidget);
    for(final chart in t.widgetList<PilotTimelineChart>(find.byType(PilotTimelineChart)))expect(chart.showHeartRate,false);
  });

  // catches: bare ListTile timing rows, Material SwitchListTiles, text-only Cancel/Save, or a heart-rate alarm chart.
  testWidgets('alarm editor uses the app rows, tabs and buttons',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',earlyMinutes:20,phoneSound:true),now:day,reference:(_)async=>sample(),onSave:(_)async{}));
    expect(find.byType(SubTabs),findsOneWidget);
    expect(find.descendant(of:find.byKey(const ValueKey('pilot-time:early')),matching:find.byType(SetRow)),findsOneWidget);
    expect(find.widgetWithText(BigButton,'Save'),findsOneWidget);expect(find.widgetWithText(BigButton,'Cancel'),findsOneWidget);
    final chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));expect(chart.showHeartRate,false);expect(chart.showHeader,false);
    await t.tap(find.text('Waking'));await t.pumpAndSettle();
    expect(find.byType(SwitchListTile),findsNothing);
    final band=find.widgetWithText(SetRow,'Band buzz');expect(band,findsOneWidget);
    expect(find.descendant(of:band,matching:find.byType(Switch)),findsOneWidget);
    expect(find.text('3 min after · set on Times'),findsOneWidget);
  });

  // catches: the day readout repeating the screen title, or zoom/pin outside the readout card.
  testWidgets('compact readout shows a caption, two cells and its controls inside',(t)async{
    final c=TimelineController(homeStartSec:base,homeEndSec:base+86400);addTearDown(c.dispose);
    await pump(t,Scaffold(body:PilotReadout(controller:c,graph:DayGraph(dayStart:base,hr:List.filled(1440,62),movement:List.filled(1440,.1)),compact:true,controls:const Text('controls'))));
    expect(find.text('TAP THE GRAPH OR A ROW'),findsOneWidget);
    expect(find.text('Stage'),findsNothing);expect(find.text('Heart rate'),findsOneWidget);
    expect(find.descendant(of:find.byType(PilotReadout),matching:find.text('controls')),findsOneWidget);
    c.setScrub(base+600.0);await t.pump();
    expect(find.textContaining('SELECTED · '),findsOneWidget);expect(find.text('62 bpm'),findsOneWidget);
  });

  // catches: Start/End rows, an ISO date in the day row, a "—" in place of the handle time, or text-only Calculate/Remove.
  testWidgets('sleep editor follows v11 rows, key and buttons',(t)async{
    final onset=DateTime(2026,11,22,23,30).millisecondsSinceEpoch~/1000,wake=DateTime(2026,11,23,7).millisecondsSinceEpoch~/1000;
    final read=SleepEditorRead(dayId:'2026-11-23',revision:null,draftGeneration:0,entries:[SleepEditorEntry(ref:DetectedMainRef('2026-11-23',onset,wake),kind:SleepBlockKind.main,day:'2026-11-23',startTs:onset,endTs:wake,provenance:SleepEntryProvenance.automatic,history:DetectedKnown(startTs:onset,endTs:wake,sourceDay:'2026-11-23',measures:{'asleep_min':400}),removed:false)]);
    await pump(t,PilotSleepEditor(day:'2026-11-23',read:read,graph:DayGraph(dayStart:onset-7200,hr:List.filled(720,60),movement:List.filled(720,.1)),onSave:(_)async=>const SleepNoChange()));
    expect(find.text('2026-11-23'),findsNothing);
    expect(find.text('Fell asleep'),findsOneWidget);expect(find.text('Woke up'),findsOneWidget);
    expect(find.text('Main sleep'),findsWidgets);
    expect(find.text('6h 40m'),findsOneWidget);expect(find.text('7h 30m'),findsOneWidget);
    expect(find.text('Actual'),findsOneWidget);
    await t.scrollUntilVisible(find.text('Remove this block'),200,scrollable:find.byType(Scrollable).last);
    expect(find.widgetWithText(BigButton,'Calculate stages for this block'),findsOneWidget);
    expect(find.widgetWithText(BigButton,'Remove this block'),findsOneWidget);
  });
}
