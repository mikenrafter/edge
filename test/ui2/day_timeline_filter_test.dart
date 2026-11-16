// WHY: activity visibility is an explicit, transient choice; the last kind
// cannot be unchecked. CLAIM(day-filter): the chart and list share that choice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/day_timeline/activities_timeline.dart';
import 'package:openstrap_edge/ui2/day_timeline/pilot_flags.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import '../support/apk2_review_harness.dart';
import '../support/as_of_recalc_fakes.dart' show settle;

class _Editor implements DayRowEditListener {
 @override
 dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
void main() {
  setUp(() {DayTimelinePilot.debugOverride[DayTimelinePilot.activities]=true;DayReviewController.debugClearDrafts();});
  tearDown(() {DayTimelinePilot.debugOverride.clear();DayReviewController.debugClearDrafts();});
  testWidgets('single zoom and numbered Filter share scrub detail; sheet keeps one kind and resets on next visit',(t) async {
    final rig=await Apk2Rig.create(t);
    await rig.mount(t,size:const Size(412,1000));
    final detail=find.byKey(const ValueKey('activities-scrub-detail'));
    final filter=find.byKey(const ValueKey('activities-filter'));
    expect(find.descendant(of:detail,matching:find.byKey(ActivitiesTimeline.zoomKey)),findsOneWidget);
    expect(find.descendant(of:filter,matching:find.byType(Icon)),findsNothing);
    expect(find.descendant(of:filter,matching:find.text('2')),findsOneWidget);
    expect(t.getSize(filter).height,greaterThanOrEqualTo(48));
    await t.tap(filter);await t.pumpAndSettle();
    expect(find.text('Show activities'),findsOneWidget);
    expect(find.text('Detected, waiting for your review'),findsOneWidget);
    expect(find.text('Kept as part of your day'),findsOneWidget);
    expect(find.text('Marked as not an activity'),findsOneWidget);
    final pending=find.byKey(const ValueKey('activity-kind:pending'));
    final saved=find.byKey(const ValueKey('activity-kind:saved'));
    final discarded=find.byKey(const ValueKey('activity-kind:discarded'));
    expect(t.widget<CheckboxListTile>(pending).value,true);
    expect(t.widget<CheckboxListTile>(saved).value,true);
    expect(t.widget<CheckboxListTile>(discarded).value,false);
    await t.tap(saved);await t.pumpAndSettle();
    expect(t.widget<CheckboxListTile>(pending).onChanged,isNull);
    expect(t.state<ActivitiesTimelineState>(find.byType(ActivitiesTimeline)).items.every((x)=>!x.discarded),true);
    await t.tap(discarded);await t.pumpAndSettle();
    await t.tap(pending);await t.pumpAndSettle();
    expect(t.widget<CheckboxListTile>(discarded).onChanged,isNull);
    expect(t.state<ActivitiesTimelineState>(find.byType(ActivitiesTimeline)).items.every((x)=>x.discarded),true);
    Navigator.of(t.element(discarded)).pop();await t.pumpAndSettle();
    expect(find.descendant(of:filter,matching:find.text('1')),findsOneWidget);
    await rig.navigator.currentState!.maybePop();await settle(t);
    await apk2Tap(t,find.text('Open breakdown'));await settle(t);
    expect(find.descendant(of:filter,matching:find.text('2')),findsOneWidget);
  });
  testWidgets('Filter, count semantics, sheet labels and descriptions are localized in all seven locales',(t)async{
    t.view.physicalSize=const Size(412,850);t.view.devicePixelRatio=1;addTearDown(t.view.reset);
    for(final language in ['en','de','es','fr','hi','ru','zh']){
      final l=lookupAppLocalizations(Locale(language));
      await t.pumpWidget(MaterialApp(key:ValueKey(language),locale:Locale(language),
        localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
        theme:buildTheme(Brightness.dark),home:Scaffold(body:ActivitiesTimeline(
          data:TimelineData(day:'2026-11-14',graph:DayGraph(dayStart:0,hr:List.filled(1440,null),movement:List.filled(1440,null))),
          rows:const[],review:null,editor:_Editor()))));
      await t.pumpAndSettle();
      final filter=find.byKey(ActivitiesTimeline.filterButtonKey);
      expect(find.text(l.dayActivitiesFilter),findsOneWidget);
      expect(t.getSize(filter).height,greaterThanOrEqualTo(48));
      expect(t.getSemantics(filter).label,contains(l.dayActivitiesFilterCount(2)));
      await t.tap(filter);await t.pumpAndSettle();
      for(final text in [l.dayActivitiesShow,l.dayActivitiesPending,l.dayActivitiesSaved,l.dayActivitiesDiscarded,
        l.dayActivitiesPendingDetail,l.dayActivitiesSavedDetail,l.dayActivitiesDiscardedDetail]){
        expect(find.text(text),findsOneWidget,reason:language);
      }
      expect(t.takeException(),isNull,reason:language);
      Navigator.of(t.element(find.text(l.dayActivitiesShow))).pop();await t.pumpAndSettle();
    }
  });

}
