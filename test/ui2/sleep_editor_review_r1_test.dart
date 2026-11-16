// WHY: editor review r1. CLAIM(sleep-editor-overlap-choice) and
// CLAIM(sleep-editor-visible-action). Drive actual chart gestures and native
// dialog buttons; calling blockSelected would bypass the bug being pinned.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import '../support/day_timeline_fixtures.dart';
import '../support/pin_tz.dart';

class _Saver implements SleepEditSaver {
  final plans = <SleepEditPlan>[];
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan plan) {
    plans.add(plan);
    return (written: Future.value(), done: Future.value(const SleepOperationResult(success: true)));
  }
}

class _HeldSaver implements SleepEditSaver {
  final written = Completer<void>();
  SleepEditPlan? plan;
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan value) {
    plan = value;
    return (written: written.future, done: Future.value(const SleepOperationResult(success: true)));
  }
}

Future<SleepTimelineEditorState> openEditor(WidgetTester t, SleepEditSaver saver, SleepEditorData data) async {
  t.view.physicalSize = const Size(412, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark),
    home: Builder(builder: (c) => Scaffold(body: TextButton(child: const Text('open'),
      onPressed: () => Navigator.of(c).push(MaterialPageRoute<SleepEditorResult>(builder: (_) =>
        SleepTimelineEditor(data: data, save: saver))),
    )))));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
}

SleepEditorData dataWith(List<SleepBlock> naps, {Map<String, String> sources = const {}}) {
  final d = dtNight(withNap: false);
  return SleepEditorData(day: d.day, domainStart: d.domainStart, hr: d.hr,
    movement: d.movement, main: d.main, naps: naps, napSources: sources);
}

Offset at(WidgetTester t, SleepTimelineEditorState state, int epoch) {
  final box = t.getRect(find.byKey(DayTimelineChart.chartKey));
  return Offset(box.left + 44 + state.controller.view.fraction(epoch.toDouble()) * (box.width - 52),
    box.top + 120);
}

Future<void> tapTime(WidgetTester t, SleepTimelineEditorState state, int epoch) async {
  await Scrollable.ensureVisible(t.element(find.byKey(DayTimelineChart.chartKey)), alignment: .5);
  await t.pumpAndSettle();
  await t.tapAt(at(t, state, epoch));
  await t.pump(const Duration(milliseconds: 350)); // Resolve the chart double-tap timer.
  await t.pumpAndSettle();
}

Future<void> stage(WidgetTester t, String label) async {
  await t.ensureVisible(find.text(label).last);
  await t.pumpAndSettle();
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

void main() {
  pinProcessTimeZone("${Platform.environment['TZDIR'] ?? '/usr/share/zoneinfo'}/America/Denver");
  final main = dtNight(withNap: false).main;
  final cases = [
    ('contained nap', [SleepBlock('inside', BlockKind.nap, dtAt(300), dtAt(330))],
      {'inside': 'legacy'}, dtAt(315)),
    ('identical main and nap', [SleepBlock('same', BlockKind.nap, main.start, main.end)],
      {'same': 'manual'}, dtAt(315)),
    ('overlapping naps', [SleepBlock('first', BlockKind.nap, dtAt(900), dtAt(960)),
      SleepBlock('second', BlockKind.nap, dtAt(930), dtAt(990))],
      {'first': 'manual', 'second': 'legacy'}, dtAt(945)),
    ('identical nap bounds', [SleepBlock('same-a', BlockKind.nap, dtAt(900), dtAt(930)),
      SleepBlock('same-b', BlockKind.nap, dtAt(900), dtAt(930))],
      {'same-a': 'manual', 'same-b': 'legacy'}, dtAt(915)),
  ];

  for (final (name, naps, sources, time) in cases) {
    testWidgets('$name: real chart tap chooses the exact entry before Save', (t) async {
      final saver = _Saver();
      final state = await openEditor(t, saver, dataWith(naps, sources: sources));
      await tapTime(t, state, time);
      expect(find.byKey(const ValueKey('sleep-editor-entry-chooser')), findsOneWidget);
      final target = naps.last;
      final row = find.byKey(ValueKey('sleep-editor-entry:${target.id}'));
      expect(row, findsOneWidget);
      expect(t.getSize(row).height, greaterThanOrEqualTo(48));
      final label = t.getSemantics(row).label;
      expect(label, contains('Nap'));
      expect(label, contains(sources[target.id] == 'legacy' ? 'Retained history' : 'User-set'));
      expect(label, contains('2026-11-14'));
      expect(label, contains(':00'));
      await t.tap(row);
      await t.pumpAndSettle();
      expect(state.active, target.id);
      await stage(t, 'Remove selected sleep block');
      await t.tap(find.byKey(SleepTimelineEditor.saveKey));
      await t.pumpAndSettle();
      final entry = saver.plans.single.entry!;
      expect((entry.main, entry.start, entry.end, entry.source, entry.action),
        (false, target.start, target.end, sources[target.id], SleepEntryAction.remove));
      expect(saver.plans.single.window, isNull);
      expect(saver.plans.single.naps, isEmpty);
    });
  }

  testWidgets('choosing the same overlapping entry or dismissing its chooser preserves the staged action', (t) async {
    final saver = _Saver();
    final nap = SleepBlock('inside', BlockKind.nap, dtAt(300), dtAt(330));
    final state = await openEditor(t, saver, dataWith([nap]));
    await stage(t, 'Remove selected sleep block');
    await tapTime(t, state, dtAt(315));
    expect(find.byKey(const ValueKey('sleep-editor-entry-chooser')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sleep-editor-entry:main')));
    await t.pumpAndSettle();
    expect(state.active, 'main');
    expect(find.byKey(const ValueKey('sleep-editor-pending-action')), findsOneWidget);
    expect(find.byKey(const ValueKey('sleep-editor-action-cancelled')), findsNothing);
    await tapTime(t, state, dtAt(315));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sleep-editor-entry-chooser')), findsNothing);
    expect(find.byKey(const ValueKey('sleep-editor-pending-action')), findsOneWidget);
    expect(find.byKey(const ValueKey('sleep-editor-action-cancelled')), findsNothing);
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));
    await t.pumpAndSettle();
    final entry = saver.plans.single.entry!;
    expect((entry.main, entry.start, entry.end, entry.action),
      (true, main.start, main.end, SleepEntryAction.remove));
  });

  testWidgets('chooser distinguishes repeated wall times by exact UTC offsets on a DST night', (t) async {
    int epoch(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;
    final early = SleepBlock('early', BlockKind.nap, epoch(DateTime.utc(2026, 11, 1, 7, 10)),
      epoch(DateTime.utc(2026, 11, 1, 8, 50)));
    final late = SleepBlock('late', BlockKind.nap, epoch(DateTime.utc(2026, 11, 1, 8, 10)),
      epoch(DateTime.utc(2026, 11, 1, 8, 40)));
    final data = SleepEditorData(day: '2026-11-01',
      domainStart: epoch(DateTime(2026, 10, 31, 20)), hr: List.filled(1500, null),
      movement: List.filled(1500, null),
      main: SleepBlock('main', BlockKind.main, epoch(DateTime.utc(2026, 11, 1, 5)),
        epoch(DateTime.utc(2026, 11, 1, 15))), naps: [early, late]);
    final state=await openEditor(t, _Saver(), data);
    await tapTime(t,state,epoch(DateTime.utc(2026,11,1,8,20)));
    expect(t.getSemantics(find.byKey(const ValueKey('sleep-editor-entry:early'))).label,
      contains('2026-11-01 01:10:00 UTC-06:00'));
    expect(t.getSemantics(find.byKey(const ValueKey('sleep-editor-entry:late'))).label,
      contains('2026-11-01 01:10:00 UTC-07:00'));
  });

  testWidgets('double tapping overlapping entries also chooses before zooming and saving main sleep', (t) async {
    final saver = _Saver();
    final nap = SleepBlock('inside', BlockKind.nap, dtAt(300), dtAt(330));
    final state = await openEditor(t, saver, dataWith([nap]));
    final point = at(t, state, dtAt(315));
    await t.tapAt(point);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(point);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sleep-editor-entry-chooser')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sleep-editor-entry:main')));
    await t.pumpAndSettle();
    expect(state.active, 'main');
    await stage(t, 'Remove selected sleep block');
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));
    await t.pumpAndSettle();
    final entry = saver.plans.single.entry!;
    expect((entry.main, entry.start, entry.end, entry.action),
      (true, main.start, main.end, SleepEntryAction.remove));
  });

  testWidgets('an action being durably written stays visible when another entry is tapped', (t) async {
    final saver = _HeldSaver();
    final base = dtNight();
    final state = await openEditor(t, saver, base);
    await stage(t, 'Remove selected sleep block');
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));
    await t.pump();
    await tapTime(t, state, base.naps.single.start + 600);
    expect(state.active, 'main');
    expect(find.byKey(const ValueKey('sleep-editor-pending-action')), findsOneWidget);
    expect(find.byKey(const ValueKey('sleep-editor-action-cancelled')), findsNothing);
    expect(saver.plan!.entry!.main, isTrue);
    saver.written.complete();
    await t.pumpAndSettle();
    expect(find.byType(SleepTimelineEditor), findsNothing);
  });

  testWidgets('identical entries have distinct accessible labels and keyboard selection', (t) async {
    final naps = [SleepBlock('a', BlockKind.nap, dtAt(300), dtAt(330)),
      SleepBlock('b', BlockKind.nap, dtAt(300), dtAt(330))];
    final state = await openEditor(t, _Saver(), dataWith(naps, sources: {'a': 'legacy', 'b': 'legacy'}));
    await tapTime(t,state,dtAt(315));
    final a = find.byKey(const ValueKey('sleep-editor-entry:a'));
    final b = find.byKey(const ValueKey('sleep-editor-entry:b'));
    expect(t.getSemantics(a).label, isNot(t.getSemantics(b).label));
    expect(t.getSemantics(b).getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    // Main sleep starts focused; Tab visits the first nap, then the second.
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(state.active, 'b');
  });

  for (final action in ['Remove selected sleep block', 'Calculate selected sleep block stages', 'Reset to detected']) {
    testWidgets('$action is cancelled and announced only when selection actually changes', (t) async {
      final initial = dtNight();
      final base = SleepEditorData(day:initial.day,domainStart:initial.domainStart,hr:initial.hr,movement:initial.movement,
        main:initial.main,naps:[initial.naps.single.copyWith(start:dtAt(800),end:dtAt(840))]);
      final data = SleepEditorData(day: base.day, domainStart: base.domainStart, hr: base.hr,
        movement: base.movement, main: base.main, naps: base.naps,
        mainSource: action == 'Reset to detected' ? 'manual' : null,
        detected:action=='Reset to detected'?{'main':base.main.copyWith(start:base.main.start-600)}:const{});
      final saver = _Saver();
      final state = await openEditor(t, saver, data);
      await stage(t, action);
      // Sticky controls keep the staged target/action and its Save/Cancel visible.
      final pending = find.byKey(const ValueKey('sleep-editor-pending-action'));
      expect(pending, findsOneWidget);
      expect(find.descendant(of: pending, matching: find.textContaining(action)), findsWidgets);
      expect(find.byKey(SleepTimelineEditor.saveKey).hitTestable(), findsOneWidget);
      expect(find.byKey(SleepTimelineEditor.cancelKey).hitTestable(), findsOneWidget);
      await tapTime(t, state, dtAt(400)); // Same main entry: just scrub.
      expect(find.byKey(const ValueKey('sleep-editor-action-cancelled')), findsNothing);
      await t.ensureVisible(find.byKey(const ValueKey('sleep-editor-zoom')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sleep-editor-zoom')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sleep-editor-zoom')));
      await t.pumpAndSettle();
      expect(pending, findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('sleep-editor-zoom')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sleep-editor-zoom')));
      await t.pumpAndSettle();
      await tapTime(t, state, base.naps.single.start + 600);
      expect(state.active, base.naps.single.id);
      expect(pending, findsNothing);
      final notice = find.byKey(const ValueKey('sleep-editor-action-cancelled'));
      expect(notice, findsOneWidget);
      expect(t.getSemantics(notice).flagsCollection.isLiveRegion, isTrue);
      expect(find.text('Unsaved action cancelled.'), findsOneWidget);
      await t.scrollUntilVisible(find.byKey(SleepTimelineEditor.saveKey), 180);
      await t.pumpAndSettle();
      await t.tap(find.byKey(SleepTimelineEditor.saveKey));
      await t.pumpAndSettle();
      expect(saver.plans, isEmpty, reason: 'Save cannot submit the cancelled, hidden action');
    });
  }

  testWidgets('pending action pauses handle and suggestion edits, while keeping the exact action visible', (t) async {
    final saver = _Saver();
    final state = await openEditor(t, saver, dtNight(withNap: false));
    final original = state.blocks.first;
    await stage(t, 'Remove selected sleep block');
    expect(find.text('Save or cancel this action before changing times.'), findsOneWidget);
    expect(t.getSemantics(find.byKey(const ValueKey('sleep-editor-pending-action'))).flagsCollection.isLiveRegion, isTrue);
    await Scrollable.ensureVisible(t.element(find.byKey(DayTimelineChart.chartKey)), alignment: .5);
    await t.pumpAndSettle();
    final gesture = await t.startGesture(at(t, state, original.end));
    await gesture.moveBy(const Offset(-35, 0));
    await t.pump();
    expect(find.byKey(DayTimelineChart.magnifierKey), findsNothing);
    await gesture.up();
    await t.pumpAndSettle();
    expect(state.blocks.first, original);
    expect(t.widget<DayTimelineChart>(find.byType(DayTimelineChart)).annotations.where((a)=>a.id.startsWith('suggestion:')),isEmpty);
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));
    await t.pumpAndSettle();
    final entry = saver.plans.single.entry!;
    expect((entry.start, entry.end, entry.action),
      (original.start, original.end, SleepEntryAction.remove));
    expect(saver.plans.single.window, isNull);
  });
}
