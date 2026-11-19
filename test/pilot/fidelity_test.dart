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
import 'package:openstrap_edge/ui2/charts.dart' show SleepStage;
import 'package:openstrap_edge/pilot/timeline_policy.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_controller.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show BigButton;
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
    expect(find.text('~6 h 40 min'),findsOneWidget);expect(find.text('400 min'),findsNothing);
    expect(find.text('17:30–19:00'),findsOneWidget);expect(find.text('Zone 3+'),findsOneWidget);
    for(final chart in t.widgetList<PilotTimelineChart>(find.byType(PilotTimelineChart)))expect(chart.showHeartRate,false);
  });

  // catches: bare ListTile timing rows, Material SwitchListTiles, text-only Cancel/Save, or a heart-rate alarm chart.
  testWidgets('alarm editor uses the app rows, tabs and buttons',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',earlyMinutes:20,phoneSound:true),now:day,reference:(_)async=>sample(),onSave:(_)async{}));
    expect(find.byType(PilotSegmented),findsOneWidget);
    // Full-width two-column control, as wide as the chart (v22 .tabs).
    expect(t.getSize(find.byType(PilotSegmented)).width,t.getSize(find.byKey(const ValueKey('pilot-timeline-plot'))).width);
    // Snoozes are dashed lines only, never icons (v22 marks()).
    expect(find.descendant(of:find.byType(PilotTimelineChart),matching:find.byTooltip('Snooze')),findsNothing);
    expect(find.descendant(of:find.byKey(const ValueKey('pilot-time:early')),matching:find.byType(SetRow)),findsOneWidget);
    // v22 .item .t small: the subtitle sits under the time, right-aligned.
    final early=find.byKey(const ValueKey('pilot-time:early'));
    final time=t.getRect(find.descendant(of:early,matching:find.text('06:40'))),sub=t.getRect(find.descendant(of:early,matching:find.text('up to 20 min earlier')));
    expect(sub.top,greaterThanOrEqualTo(time.bottom-1));expect((sub.right-time.right).abs(),lessThan(1));
    final title=t.getRect(find.descendant(of:early,matching:find.text('Early wake')));expect(title.height,lessThan(time.height*1.6));
    expect(find.widgetWithText(BigButton,'Save'),findsOneWidget);expect(find.widgetWithText(BigButton,'Cancel'),findsOneWidget);
    final chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));expect(chart.showHeartRate,false);expect(chart.showHeader,false);
    await t.tap(find.text('Waking'));await t.pumpAndSettle();
    expect(find.byType(SwitchListTile),findsNothing);
    final band=find.widgetWithText(SetRow,'Band buzz');expect(band,findsOneWidget);
    expect(find.descendant(of:band,matching:find.byType(Switch)),findsOneWidget);
    await t.scrollUntilVisible(find.text('Phone sound'),200,scrollable:find.byType(Scrollable).last);
    expect(find.descendant(of:find.widgetWithText(SetRow,'Phone sound'),matching:find.textContaining('min after · set on Times')),findsOneWidget);
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
    expect(find.textContaining('Actual',findRichText:true),findsWidgets);
    await t.scrollUntilVisible(find.text('Remove this block'),200,scrollable:find.byType(Scrollable).last);
    expect(find.widgetWithText(BigButton,'Calculate stages for this block'),findsOneWidget);
    expect(find.widgetWithText(BigButton,'Remove this block'),findsOneWidget);
  });

  // m241. catches: a tap doing nothing on the day timeline, a pan that scrubs,
  // a tap near an item moving the cursor, or temporary-scrub charts gaining tap-to-scrub.
  group('day timeline tap places the scrub cursor',(){
    late TimelineController c;late TimelineInteraction i;String? focused;
    Future<Rect> mount(WidgetTester t,PilotScrub retention)async{
      c=TimelineController(homeStartSec:base,homeEndSec:base+86400);i=TimelineInteraction(retention:retention);focused=null;
      addTearDown(c.dispose);addTearDown(i.dispose);
      await pump(t,Scaffold(body:Padding(padding:const EdgeInsets.all(16),child:PilotTimelineChart(controller:c,interaction:i,
        graph:DayGraph(dayStart:base,hr:List.filled(1440,62),movement:List.filled(1440,.1)),
        annotations:[ChartAnnotation(id:'meal',kind:AnnotationKind.moment,at:base+18*3600.0,label:'Meal')],onSelect:(id)=>focused=id))));
      return t.getRect(find.byKey(const ValueKey('pilot-timeline-plot')));
    }
    testWidgets('tap on empty graph moves the cursor there',(t)async{
      final r=await mount(t,PilotScrub.permanent);
      await t.tapAt(Offset(r.left+r.width*.25,r.center.dy));await t.pump();
      expect(c.scrub,base+6*3600.0);expect(focused,isNull);expect(i.cursor,base+6*3600.0);
    });
    testWidgets('a drag pans and never scrubs',(t)async{
      final r=await mount(t,PilotScrub.permanent);
      await t.dragFrom(Offset(r.left+r.width*.5,r.center.dy),const Offset(-80,0));await t.pump();
      expect(c.scrub,isNull);
    });
    testWidgets('tap near an annotation focuses it without moving the cursor',(t)async{
      final r=await mount(t,PilotScrub.permanent);
      await t.tapAt(Offset(r.left+r.width*.75,r.center.dy));await t.pump();
      expect(focused,'meal');expect(c.scrub,isNull);
    });
    testWidgets('temporary-scrub charts ignore a tap',(t)async{
      final r=await mount(t,PilotScrub.temporary);
      await t.tapAt(Offset(r.left+r.width*.25,r.center.dy));await t.pump();
      expect(c.scrub,isNull);
    });
  });

  // why: signed-off day timeline draws a half-opacity hypnogram inside sleep.
  // catches: the day chart dropping the recorded stages it was given.
  testWidgets('a day with a sleep block paints stage segments',(t)async{
    Future<RenderObject> paint(List<SleepStage?> stages)async{
      final c=TimelineController(homeStartSec:base,homeEndSec:base+86400);addTearDown(c.dispose);
      final i=TimelineInteraction();addTearDown(i.dispose);
      await pump(t,Scaffold(body:PilotTimelineChart(key:UniqueKey(),controller:c,interaction:i,stages:stages,
        graph:DayGraph(dayStart:base,hr:List.filled(1440,62),movement:List.filled(1440,.1),rest:const [(0,400,Colors.pink)]))));
      return t.renderObject(find.descendant(of:find.byKey(const ValueKey('pilot-timeline-plot')),matching:find.byType(CustomPaint)).first);
    }
    // 00:00-06:40 asleep: light, deep, rem runs in 5-min slots.
    final night=<SleepStage?>[for(var k=0;k<288;k++)k<80?[SleepStage.light,SleepStage.deep,SleepStage.rem][(k~/10)%3]:null];
    expect(await paint(night),paints..rrect()..rrect());
    expect(await paint(const []),isNot(paints..rrect()..rrect()));
  });
}
