// WHY: owner-approved v3 layout and reversible actions.
// CLAIM(sleep-editor-v3): displayed changes remain entry-scoped and undoable.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import '../support/day_timeline_fixtures.dart';
import 'sleep_editor_review_r1_test.dart' as rig;

class _Saver implements SleepEditSaver {
  final plans = <SleepEditPlan>[];
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan plan) {
    plans.add(plan);
    return (written: Future.value(), done: Future.value(const SleepOperationResult(success: true)));
  }
}

void main() {
  test('full day keeps noon when possible, uses midnight when it fits, and otherwise extends only to wake',(){
    int sec(DateTime t)=>t.millisecondsSinceEpoch~/1000;
    expect(sleepEditorDay(sec(DateTime(2026,11,13,23)),sec(DateTime(2026,11,14,7))),
      TimelineView(sec(DateTime(2026,11,13,12)).toDouble(),sec(DateTime(2026,11,14,12)).toDouble()));
    expect(sleepEditorDay(sec(DateTime(2026,11,14,6,39)),sec(DateTime(2026,11,14,16,15))),
      TimelineView(sec(DateTime(2026,11,14)).toDouble(),sec(DateTime(2026,11,15)).toDouble()));
    expect(sleepEditorDay(sec(DateTime(2026,11,13,22)),sec(DateTime(2026,11,14,16))),
      TimelineView(sec(DateTime(2026,11,13,12)).toDouble(),sec(DateTime(2026,11,14,16)).toDouble()));
  });

  testWidgets('two cards fit on 412 by 850 and full day resets exactly', (t) async {
    final saver = _Saver();
    final s = await rig.openEditor(t, saver, dtNight());
    t.view.physicalSize = const Size(412, 850);
    await t.pumpAndSettle();
    final start = DateTime(2026,11,13,12).millisecondsSinceEpoch / 1000;
    final end = DateTime(2026,11,14,12).millisecondsSinceEpoch / 1000;
    expect(s.controller.home, TimelineView(start,end));
    expect(s.controller.view, TimelineView(start,end));
    expect(find.byKey(const ValueKey('sleep-editor-suggestions')), findsNothing);
    expect(find.byKey(const ValueKey('sleep-editor-choose-entry')), findsNothing);
    expect(find.text('Calculate selected sleep block stages'), findsOneWidget);
    expect(find.text('Reset to detected'), findsOneWidget);
    expect(find.text('Remove selected sleep block'), findsOneWidget);
    expect(find.byKey(SleepTimelineEditor.saveKey).hitTestable(), findsOneWidget);
    expect(find.byKey(SleepTimelineEditor.cancelKey).hitTestable(), findsOneWidget);
    final detail = find.byKey(SleepTimelineEditor.readoutKey);
    expect(find.descendant(of: detail, matching: find.byKey(SleepTimelineEditor.addKey)), findsOneWidget);
    final zoom = find.byKey(const ValueKey('sleep-editor-zoom'));
    expect(find.descendant(of: detail, matching: zoom), findsOneWidget);
    expect(find.text('Zoom in'), findsOneWidget);
    await t.tap(zoom);
    await t.pumpAndSettle();
    // Day selection handles are reused, not a second zoom formula.
    expect(s.controller.zoomSelection, isNotNull);
    await t.tap(zoom);
    await t.pumpAndSettle();
    expect(find.text('Reset zoom'), findsOneWidget);
    await t.tap(zoom);
    await t.pumpAndSettle();
    expect(s.controller.view, TimelineView(start,end));
    expect(saver.plans, isEmpty);
    final scroll=t.state<ScrollableState>(find.descendant(of:find.byKey(const ValueKey('sleep-editor-scroll')),matching:find.byType(Scrollable)).first);
    expect(scroll.position.maxScrollExtent,0);
    expect(t.takeException(), isNull);
  });

  testWidgets('noon crossing sleep uses a containing midnight day instead of 48 hours', (t) async {
    final d = dtNight(withNap:false);
    final s = await rig.openEditor(t, _Saver(), SleepEditorData(day:d.day,domainStart:d.domainStart,
      hr:d.hr,movement:d.movement,main:SleepBlock('main',BlockKind.main,
      DateTime(2026,11,14,6,39).millisecondsSinceEpoch~/1000,
      DateTime(2026,11,14,16,15).millisecondsSinceEpoch~/1000)));
    expect(s.controller.home, TimelineView(DateTime(2026,11,14).millisecondsSinceEpoch/1000,
      DateTime(2026,11,15).millisecondsSinceEpoch/1000));
  });

  testWidgets('add starts with highlighted gaps, then zooms to the chosen half, Cancel writes nothing', (t) async {
    final saver = _Saver();
    final s = await rig.openEditor(t, saver, dtNight(withNap:false));
    await t.tap(find.byKey(SleepTimelineEditor.addKey));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sleep-editor-add-start')), findsOneWidget);
    expect(s.blocks, hasLength(1));
    await rig.tapTime(t,s,dtAt(800));
    expect(find.byKey(const ValueKey('sleep-editor-add-end')), findsOneWidget);
    expect(find.byKey(ChartAnnotationLane.labelKey),findsNothing,reason:'Instructions belong only in the scrub card');
    expect(s.controller.view.start, s.blocks.first.end);
    expect(s.controller.view.end, s.controller.home.end);
    expect(s.blocks, hasLength(1));
    await t.tap(find.byKey(const ValueKey('sleep-editor-add-cancel')));
    await t.pumpAndSettle();
    expect(s.blocks, hasLength(1));
    expect(saver.plans, isEmpty);
    expect(s.controller.view, s.controller.home);
  });

  testWidgets('Remove nap leaves a selectable outline, Undo and later restore preserve exact bounds', (t) async {
    final saver = _Saver();
    final s = await rig.openEditor(t,saver,dtNight());
    final nap=s.blocks.last;
    s.blockSelected(nap.id,zoom:false);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sleep-editor-remove')));
    await t.pumpAndSettle();
    expect(find.text('Reset to detected (restore nap)'), findsOneWidget);
    expect(find.byType(SnackBarAction), findsOneWidget);
    expect(saver.plans,isEmpty);
    await t.tap(find.byType(SnackBarAction));
    await t.pumpAndSettle();
    expect(s.blocks.last,nap);
    expect(find.text('Reset to detected (restore nap)'),findsNothing);
    await t.tap(find.byKey(const ValueKey('sleep-editor-remove')));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds:6));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sleep-editor-detected')));
    await t.pumpAndSettle();
    expect(s.blocks.last,nap);
    expect(saver.plans,isEmpty);
  });

  testWidgets('a detected ghost confirms before resetting only its own boundary and supports Undo', (t) async {
    final saver=_Saver();
    final s=await rig.openEditor(t,saver,dtNight(withNap:false));
    final original=s.blocks.first;
    s.blocksChanged([original.copyWith(start:original.start+1800,end:original.end+900)]);
    await t.pumpAndSettle();
    final ghost=find.byKey(ChartAnnotationLane.iconKey('ghost:main:start'));
    expect(ghost,findsOneWidget);
    final target=find.ancestor(of:ghost,matching:find.byType(Pressable)).first;
    expect(t.getSize(target).width,greaterThanOrEqualTo(48));
    expect(t.getSize(target).height,greaterThanOrEqualTo(48));
    expect(find.byWidgetPredicate((w)=>w is Semantics&&
      (w.properties.customSemanticsActions?.keys.any((a)=>a.label?.contains('Reset fell asleep to detected?')==true)??false)),findsOneWidget);
    await t.tap(ghost);
    await t.pump(const Duration(milliseconds:350));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog),findsOneWidget);
    expect(s.blocks.first.start,original.start+1800);
    await t.tap(find.byKey(const ValueKey('sleep-editor-ghost-confirm')));
    await t.pumpAndSettle();
    expect(s.blocks.first.start,original.start);
    expect(s.blocks.first.end,original.end+900);
    await t.tap(find.byType(SnackBarAction));
    await t.pumpAndSettle();
    expect(s.blocks.first.start,original.start+1800);
    expect(s.blocks.first.end,original.end+900);
    expect(saver.plans,isEmpty);
  });
  testWidgets('all shipped locales label the chart, individual blocks and real 48 dp actions',(t)async{
    t.view.physicalSize=const Size(412,1000);t.view.devicePixelRatio=1;addTearDown(t.view.reset);
    final semantics=t.ensureSemantics();
    try {
    for(final language in ['en','de','es','fr','hi','ru','zh']){
      final l=lookupAppLocalizations(Locale(language));
      await t.pumpWidget(MaterialApp(locale:Locale(language),
        localizationsDelegates:AppLocalizations.localizationsDelegates,
        supportedLocales:AppLocalizations.supportedLocales,theme:buildTheme(Brightness.dark),
        home:SleepTimelineEditor(key:ValueKey(language),data:dtNight(),save:_Saver())));
      await t.pumpAndSettle();
      final state=t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
      final chart=t.widget<DayTimelineChart>(find.byType(DayTimelineChart));
      final localized=find.byWidgetPredicate((w)=>w is Semantics&&w.properties.label==
        l.timelineSemanticsRange(chart.clock.of(state.controller.view.start.round()),chart.clock.of(state.controller.view.end.round())));
      expect(localized,findsOneWidget,reason:language);
      final widget=t.widget<Semantics>(localized);
      final labels=widget.properties.customSemanticsActions!.keys.map((a)=>a.label).toList();
      expect(labels,hasLength(2));
      expect(labels.first,contains(l.sleepEditorMainEntry));
      expect(labels.last,contains(l.sleepEditorNapEntry));
      for(final id in ['calculate','detected','remove']){
        final f=find.byKey(ValueKey('sleep-editor-$id'));
        expect(t.getSize(f).height,greaterThanOrEqualTo(48),reason:language);
        expect(t.getSemantics(f).getSemanticsData().label,isNotEmpty);
      }
      // The native control is keyboard operable, with the full localized label.
      expect(find.text(l.sleepEditorCalculate),findsOneWidget);
      expect(find.text(l.sleepEditorResetDetected),findsOneWidget);
      expect(find.text(l.sleepEditorRemove),findsOneWidget);
      widget.properties.customSemanticsActions!.values.last();await t.pumpAndSettle();
      expect(state.active,state.blocks.last.id);
      expect(t.takeException(),isNull,reason:language);
    }
    } finally {semantics.dispose();}
  });

  testWidgets('add highlights only free gaps and advances both instructions to the end step',(t)async{
    final base=dtNight(withNap:false);
    final data=SleepEditorData(day:base.day,domainStart:base.domainStart,hr:base.hr,movement:base.movement,
      main:base.main,naps:[SleepBlock('existing',BlockKind.nap,dtAt(800),dtAt(840))]);
    final state=await rig.openEditor(t,_Saver(),data);
    await t.tap(find.byKey(SleepTimelineEditor.addKey));await t.pumpAndSettle();
    final gaps=t.widget<DayTimelineChart>(find.byType(DayTimelineChart)).annotations;
    expect(gaps.every((g)=>g.until==null||g.until!<=dtAt(800)||g.at>=dtAt(840)),true,
      reason:'An existing nap is not an available place for another block');
    await rig.tapTime(t,state,dtAt(810));
    expect(find.byKey(const ValueKey('sleep-editor-add-start')),findsOneWidget);
    await rig.tapTime(t,state,dtAt(850));
    expect(find.byKey(const ValueKey('sleep-editor-add-end')),findsOneWidget);
    final endGaps=t.widget<DayTimelineChart>(find.byType(DayTimelineChart)).annotations;
    expect(endGaps.every((g)=>g.label.contains('Now tap where it ends.')),true);
    expect(endGaps.every((g)=>g.at>=dtAt(855)),true);
  });
  testWidgets('removing a new draft leaves Undo but no false pending-time warning or write',(t)async{
    final saver=_Saver();final state=await rig.openEditor(t,saver,dtNight(withNap:false));
    await t.tap(find.byKey(SleepTimelineEditor.addKey));await t.pumpAndSettle();
    await rig.tapTime(t,state,dtAt(800));await rig.tapTime(t,state,dtAt(840));
    await t.tap(find.byKey(const ValueKey('sleep-editor-remove')));await t.pumpAndSettle();
    expect(find.text('Save or cancel your time changes first.'),findsNothing);
    expect(find.byType(SnackBarAction),findsOneWidget);
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));await t.pumpAndSettle();
    expect(saver.plans,isEmpty);
    expect(find.byType(SleepTimelineEditor),findsNothing);
  });

  testWidgets('a removed manual nap with no detected history offers an honest snapshot restore',(t)async{
    final base=dtNight();final nap=base.naps.single;
    final data=SleepEditorData(day:base.day,domainStart:base.domainStart,hr:base.hr,movement:base.movement,
      main:base.main,naps:[nap],napSources:{nap.id:'manual'});
    final saver=_Saver();final state=await rig.openEditor(t,saver,data);
    state.blockSelected(nap.id,zoom:false);await t.pumpAndSettle();
    expect(t.widget<TextButton>(find.byKey(const ValueKey('sleep-editor-detected'))).onPressed,isNull);
    await t.tap(find.byKey(const ValueKey('sleep-editor-remove')));await t.pumpAndSettle();
    expect(find.text('Restore sleep block'),findsOneWidget);
    expect(find.text('Reset to detected (restore nap)'),findsNothing);
    await t.tap(find.byKey(const ValueKey('sleep-editor-detected')));await t.pumpAndSettle();
    expect(state.blocks.last,nap);
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));await t.pumpAndSettle();
    expect(saver.plans,isEmpty);
  });

}
