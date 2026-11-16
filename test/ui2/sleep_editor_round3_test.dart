// WHY: owner-approved v3 layout and reversible actions.
// CLAIM(sleep-editor-v3): displayed changes remain entry-scoped and undoable.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import 'package:openstrap_edge/ui2/theme.dart';
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
    final ghost=find.byKey(const ValueKey('sleep-editor-ghost:main:start'));
    expect(ghost,findsOneWidget);
    await t.tap(ghost);
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
}
