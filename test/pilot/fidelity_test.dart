// why: owner m233 fidelity fixes against the signed-off mock-ups (alarms v22,
// day timeline v16, sleep editor v11). Behaviour checks, not pixel goldens.
import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/alarm_screen.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/pilot_readout.dart';
import 'package:openstrap_edge/pilot/pilot_theme.dart';
import 'package:openstrap_edge/ui2/theme.dart' show P,C;
import 'package:openstrap_edge/pilot/sleep_editor.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/ui2/charts.dart' show SleepStage;
import 'package:openstrap_edge/pilot/timeline_policy.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_controller.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show BigButton,SubTabs;
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
    // m261: the repeat days and the switch sit right on every card, whatever the name's length.
    for(final id in ['w','r']){final card=t.getRect(find.byKey(ValueKey('pilot-alarm:$id')));final toggle=t.getRect(find.descendant(of:find.byKey(ValueKey('pilot-alarm:$id')),matching:find.byType(Switch)));
      expect(card.right-toggle.right,lessThan(20));}
    // m244.3: the sleep alarm's chart draws no heart rate; the workout alarm's keeps it.
    expect([for(final chart in t.widgetList<PilotTimelineChart>(find.byType(PilotTimelineChart)))chart.showHeartRate],unorderedEquals([false,true]));
  });

  // why: m255.2 — Early wake's row button reads Disable and turns the window off.
  // catches: the early row keeping "Reset", or Disable not clearing the window.
  testWidgets('early wake row offers Disable',(t)async{
    final alarm=PilotAlarm(id:'a',label:'A',earlyMinutes:20);
    await pump(t,PilotAlarmEditor(alarm:alarm,now:day,reference:(_)async=>sample(),onSave:(_)async{}));
    final row=find.byKey(const ValueKey('pilot-time:early'));
    expect(find.descendant(of:row,matching:find.text('Reset')),findsNothing);
    await t.tap(find.descendant(of:row,matching:find.text('Disable')));await t.pumpAndSettle();
    expect(find.descendant(of:row,matching:find.text('Disable')),findsNothing);
    expect(find.descendant(of:row,matching:find.text('—')),findsOneWidget);
  });

  // why: m254 — Primary is v22's #primRow: the whole row is a switch with a bare star.
  // catches: a Material Switch on a tiled SetRow, or copy that doesn't follow the state.
  testWidgets('primary row is the signed star switch',(t)async{
    final handle=t.ensureSemantics();
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',primary:false),now:day,reference:(_)async=>sample(),onSave:(_)async{}));
    final row=find.byKey(const ValueKey('pilot-primary'));
    await t.ensureVisible(row);await t.pumpAndSettle();
    expect(find.descendant(of:row,matching:find.byType(Switch)),findsNothing);
    expect(find.text('Not the primary alarm'),findsOneWidget);
    // m261: the subtitle says what a tap does.
    expect(find.textContaining('Tap to make this the primary alarm.'),findsOneWidget);
    expect(t.getSemantics(row).flagsCollection.isToggled,Tristate.isFalse);
    await t.tap(row);await t.pumpAndSettle();
    expect(find.text('Primary alarm for these days'),findsOneWidget);
    expect(find.textContaining('Tap to stop this being the primary alarm.'),findsOneWidget);
    expect(t.getSemantics(row).flagsCollection.isToggled,Tristate.isTrue);
    handle.dispose();
  });

  // why: m268/m269 — on the list card graph a same-minute column holds its first icon and a "…"
  // standing for the rest; icons pushed down by a nearby different minute stay as they are.
  // catches: a same-minute column of three icons, a "…" without the hidden items' times, or
  // nearby different-minute icons being dropped.
  testWidgets('overview caps a same-minute column at an icon and an ellipsis',(t)async{
    final handle=t.ensureSemantics();
    final c=TimelineController(homeStartSec:base,homeEndSec:base+86400);final i=TimelineInteraction(retention:PilotScrub.temporary);
    addTearDown(c.dispose);addTearDown(i.dispose);c.selectRange(base+5*3600,base+8*3600);
    ChartAnnotation a(String id,int minute)=>ChartAnnotation(id:id,kind:AnnotationKind.wake,at:base+minute*60.0,label:id);
    await pump(t,Scaffold(body:Padding(padding:const EdgeInsets.all(16),child:PilotTimelineChart(controller:c,interaction:i,overview:true,height:72,showHeartRate:false,
      graph:DayGraph(dayStart:base,hr:List.filled(1440,62),movement:List.filled(1440,.1)),
      annotations:[a('Sound',390),a('Vibration',390),a('Flash',390),a('Sunrise',420),a('Gradual',422)]))));
    expect(find.byTooltip('Sound'),findsOneWidget);
    expect(find.byTooltip('Vibration'),findsNothing);expect(find.byTooltip('Flash'),findsNothing);
    expect(find.byKey(const ValueKey('pilot-overview-more')),findsOneWidget);
    expect(find.byWidgetPredicate((w)=>w is Semantics&&w.properties.label=='Vibration 06:30, Flash 06:30'),findsOneWidget);
    // Nearby different minutes: both drawn, as before.
    expect(find.byTooltip('Sunrise'),findsOneWidget);expect(find.byTooltip('Gradual'),findsOneWidget);
    handle.dispose();
  });

  // why: m279 — an icon over another item's thumb is half opacity and takes no touches, so a
  // press there grabs the thumb rather than selecting the icon.
  // catches: a full-strength icon over a thumb, a press there selecting that icon, or the thumb's
  // own icon or an icon away from every thumb being dimmed.
  testWidgets('icons over another thumb are dimmed and ignore touches',(t)async{
    final c=TimelineController(homeStartSec:base,homeEndSec:base+86400);final i=TimelineInteraction(retention:PilotScrub.temporary);
    addTearDown(c.dispose);addTearDown(i.dispose);c.selectRange(base+5*3600,base+8*3600);
    ChartAnnotation a(String id,int minute)=>ChartAnnotation(id:id,kind:AnnotationKind.wake,at:base+minute*60.0,label:id);
    final selected=<String>[];
    await pump(t,Scaffold(body:Padding(padding:const EdgeInsets.all(16),child:PilotTimelineChart(controller:c,interaction:i,showHeartRate:false,
      graph:DayGraph(dayStart:base,hr:List.filled(1440,62),movement:List.filled(1440,.1)),selectedAnnotationId:'Latest',onSelect:selected.add,
      handles:[PilotHandle('Latest',base+420*60.0,Colors.white)],
      annotations:[a('Latest',420),a('Flash',420),a('Sunrise',360)]))));
    final over=find.byKey(const ValueKey('pilot-icon-over-thumb:Flash'));
    expect(over,findsOneWidget);
    expect(t.widget<Opacity>(find.descendant(of:over,matching:find.byType(Opacity))).opacity,.5);
    expect(find.byKey(const ValueKey('pilot-icon-over-thumb:Latest')),findsNothing);
    expect(find.byKey(const ValueKey('pilot-icon-over-thumb:Sunrise')),findsNothing);
    await t.tapAt(t.getCenter(over));await t.pumpAndSettle();
    expect(selected,isNot(contains('Flash')));
    await t.tapAt(t.getCenter(find.byTooltip('Sunrise')));await t.pumpAndSettle();
    expect(selected.last,'Sunrise');
  });

  // why: m273 + v22 open(nw) — the + sheet's palette, a new alarm's title, the workout caption.
  // catches: an unstyled type picker, a new alarm titled Edit "…", or TIMES on a workout editor.
  testWidgets('+ opens the v22 sheet and the new alarm is titled as new',(t)async{
    await pump(t,PilotAlarmScreen(alarms:[PilotAlarm(id:'w',label:'Work',days:{1})],now:DateTime(2026,11,23,5),reference:(_)async=>sample(),onSave:(_)async{}));
    await t.tap(find.byTooltip('Add alarm'));await t.pumpAndSettle();
    // m273: the Material sheet, in the mock-up palette.
    expect(find.byType(ListTile),findsNWidgets(2));
    expect(t.widget<Icon>(find.descendant(of:find.byKey(const ValueKey('pilot-add:sleep')),matching:find.byType(Icon))).color,P.of(t.element(find.byType(ListTile).first)).on(C.indigo));
    expect(t.getSize(find.byKey(const ValueKey('pilot-add:sleep'))).height,greaterThanOrEqualTo(56));
    await t.tap(find.byKey(const ValueKey('pilot-add:sleep')));await t.pumpAndSettle();
    expect(find.text('New sleep alarm'),findsOneWidget);expect(find.textContaining('Edit'),findsNothing);
    expect(find.text('TIMES · TAP ONE, THEN DRAG IT ON THE GRAPH'),findsOneWidget);
    await t.tap(find.text('Cancel').first);await t.pumpAndSettle();
    await t.tap(find.byTooltip('Add alarm'));await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pilot-add:workout')));await t.pumpAndSettle();
    expect(find.text('New workout alarm'),findsOneWidget);
    expect(find.text('WINDOW · TAP ONE, THEN DRAG IT ON THE GRAPH'),findsOneWidget);
    await t.tap(find.text('Cancel').first);await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pilot-alarm:w')));await t.pumpAndSettle();
    expect(find.text('Edit "Work"'),findsOneWidget);
    expect(t.takeException(),null);
  });

  // catches: bare ListTile timing rows, Material SwitchListTiles, text-only Cancel/Save, or a heart-rate alarm chart.
  testWidgets('alarm editor uses the app rows, tabs and buttons',(t)async{
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',earlyMinutes:20,phoneSound:true),now:day,reference:(_)async=>sample(),onSave:(_)async{}));
    expect(find.byType(SubTabs),findsOneWidget);
    // The shared SubTabs in its segmented look: one full-width track, no scrolling row, as wide as the chart (v22 .tabs).
    expect(find.descendant(of:find.byType(SubTabs),matching:find.byType(SingleChildScrollView)),findsNothing);
    expect(t.getSize(find.byType(SubTabs)).width,t.getSize(find.byKey(const ValueKey('pilot-timeline-plot'))).width);
    // Snoozes are dashed lines only, never icons (v22 marks()).
    expect(find.descendant(of:find.byType(PilotTimelineChart),matching:find.byTooltip('Snooze')),findsNothing);
    expect(find.descendant(of:find.byKey(const ValueKey('pilot-time:early')),matching:find.byType(PilotItemRow)),findsOneWidget);
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
      // m254: the tap counts as scrubbing, so the readout auto-pins.
      expect(i.autoPinned,true);expect(i.handScrubbing,false);
    });
    testWidgets('a drag pans and never scrubs',(t)async{
      final r=await mount(t,PilotScrub.permanent);
      await t.dragFrom(Offset(r.left+r.width*.5,r.center.dy),const Offset(-80,0));await t.pump();
      expect(c.scrub,isNull);
    });
    testWidgets('tap near an annotation focuses it without moving the cursor',(t)async{
      final r=await mount(t,PilotScrub.permanent);
      await t.tapAt(Offset(r.left+r.width*.75,r.center.dy));await t.pump();
      expect(focused,'meal');expect(c.scrub,isNull);expect(i.autoPinned,false);
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
