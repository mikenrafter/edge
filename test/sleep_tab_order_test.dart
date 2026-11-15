// CLAIM sleep-tab-order: the uncarded timeline and four owner-approved cards
// keep every existing function and one need reading. Late reads retain
// the normal loading geometry budget; no spinner is allowed at sampled frames.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show DayNav;
import 'package:openstrap_edge/ui2/why_row.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show InsideCard, Surface;
import 'support/as_of_recalc_fakes.dart';
import 'support/skeleton_fixture.dart';
import 'support/shift_run.dart';
import 'support/pilot_shots.dart';

class OrderedSleepRepo extends SleepRepo {
  Completer<void>? held;
  @override
  Future<List<Map<String,Object?>>> getDeviceNights(String day) async => [
    {'device_id':'paired','label':'Paired watch',...await getDaySleepV2(day)}];
  @override
  Future<SleepDetailBundle> getSleepDetailBundle(String day, {required List<String> chartKeys, required int windowDays, String? before}) async {
    await held?.future;
    return SleepDetailBundle(night:await getDaySleepV2(day), timeline:const{},
      insights:const {'sleep_coach':{'need':{'value':{'need_sec':28800},'confidence':1.0},
        'bedtime':{'value':{'bedtime_min_of_day':1320},'confidence':1.0},
        'wake':{'value':{'wake_min_of_day':420}}},'sleep_debt':{'value':{'debt_hours':1.0},'confidence':1.0}},
      charts:{'irregular_rhythm_flag':{'points':[{'t':DateTime.parse(day).add(const Duration(hours:12)).millisecondsSinceEpoch~/1000,'v':1.0}]}},windows:const[]);
  }
}
const cards=['timeline','stood-out','usual','signals','plan'];
Finder card(String id)=>find.byKey(ValueKey('sleep-tab:$id'));
Finder within(String id,Finder child)=>find.descendant(of:card(id),matching:child);
void main(){
  setUpAll(skLoadAppFonts);
  testWidgets('uncarded timeline keeps its contents above the four cards', (t) async {
    skTallView(t,w:390,h:10000);final repo=OrderedSleepRepo();final app=AppState.forTesting()..repo=repo;addTearDown(app.dispose);
    final data=await SleepData.load(repo);
    await t.pumpWidget(perfApp(app,SleepDetail(embedded:true,data:data)));
    for(final id in cards) { expect(card(id),findsOneWidget); }
    final tops=[for(final id in cards)t.getTopLeft(card(id)).dy];expect(tops,orderedEquals([...tops]..sort()));
    expect(t.widget(card('timeline')), isNot(isA<Surface>()));
    expect(find.text('Sleep timeline'), findsNothing);
    for (final element in within('timeline', find.byType(Surface)).evaluate()) {
      expect(InsideCard.of(element), isTrue,
        reason: 'timeline contents stay flat when the outer card is removed');
    }
    expect(within('timeline',find.byType(SettingsAccordion)),findsNothing);
    expect(find.byType(SettingsAccordion),findsNWidgets(4));
    expect(within('timeline',find.byType(DayNav)),findsOneWidget);
    expect(within('timeline',find.byKey(const ValueKey('card:answer'))),findsOneWidget);
    expect(within('timeline',find.byKey(const ValueKey('card:window'))),findsOneWidget);
    expect(within('timeline',find.text('Naps')),findsOneWidget);
    expect(within('stood-out',find.text('What charged and drained you')),findsOneWidget);
    expect(within('stood-out',find.byType(WhyRow)),findsOneWidget);
    expect(within('signals',find.byKey(const ValueKey('sleep-stage-rows'))),findsOneWidget);
    expect(within('signals',find.byType(DeviceFilter)),findsOneWidget);
    expect(within('plan',find.text("Tonight's need")),findsOneWidget);
    expect(find.text("Tonight's need"),findsOneWidget);
    expect(within('plan',find.text('Body clock')),findsOneWidget);
    expect(within('plan',find.text('Alarm')),findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  // CLAIM sleep-pending-actions: cold loading cannot assert a different action
  // from the scored-night action that replaces it.
  testWidgets('cold night uses the loaded edit label from its first frame', (t) async {
    skTallView(t);
    final repo = OrderedSleepRepo()..held = Completer<void>();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    try {
      await t.pumpWidget(perfApp(app, const SleepTab()));
      await t.pump();
      expect(find.text('Set the times myself'), findsOneWidget);
      expect(find.text('I was asleep'), findsNothing);
      repo.held!.complete();
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Set the times myself'), findsOneWidget);
      expect(find.text('I was asleep'), findsNothing);
    } finally {
      if (!repo.held!.isCompleted) repo.held!.complete();
      await t.pumpWidget(const SizedBox());
    }
  });
  testWidgets('late cards keep the visible loading layout within the normal budget', (t) async {
    phoneSurface(t);final repo=OrderedSleepRepo()..held=Completer<void>();final app=AppState.forTesting()..repo=repo;addTearDown(app.dispose);
    final run=ShiftRun(t);await t.pumpWidget(perfApp(app,const SleepTab()));await t.pump();
    expect(card('timeline'),findsOneWidget);run.opened();await run.frames([0,200,500,2500]);
    repo.held!.complete();await run.frames([0,16,100,300,600]);
    final score=run.score(ShiftPolicy.standard.copyWith(loadWeight:0,colorWeight:0));
    debugPrint(formatShiftReport('sleep-tab-order',score,run.probe.frames.length));
    expect(score.total,lessThan(.016));for(final f in score.findings.where((f)=>f.rule=='shift')) { expect(f.score,lessThan(.002)); }
    await t.pumpWidget(const SizedBox());
  });
  // Reviewed render artifacts for the five approved cards, using the existing
  // shot helper; assertions above own behavior and geometry.
  testWidgets('five Sleep cards dark review renders', (t) async {
    phoneSurface(t); final repo=OrderedSleepRepo();
    final app=AppState.forTesting()..repo=repo; addTearDown(app.dispose);
    final data=await SleepData.load(repo);
    await t.pumpWidget(pilotShot(perfApp(app,SleepDetail(embedded:true,data:data),brightness:Brightness.dark)));
    await t.pump(); await t.pump(const Duration(milliseconds:600));
    for(final id in cards) {
      await t.scrollUntilVisible(card(id),300,scrollable:find.byType(Scrollable).first);
      await Scrollable.ensureVisible(t.element(card(id)),alignment:0);
      await t.pump();
      await takePilotShot(t,'sleep-$id');
      expect(t.takeException(),isNull);
    }
    await t.pumpWidget(const SizedBox());
  });

}
