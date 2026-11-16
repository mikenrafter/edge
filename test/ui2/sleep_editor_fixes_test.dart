// WHY: owner feedback 1–6, CLAIM(sleep-editor-night-region),
// CLAIM(sleep-editor-stable-text), CLAIM(sleep-editor-entry-write).
// Exercise the editor the wearer uses, including its acknowledgement boundary.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import '../support/day_timeline_fixtures.dart';

class _Saver implements SleepEditSaver {
  final plans = <SleepEditPlan>[];
  final written = Completer<void>();
  final done = Completer<SleepOperationResult>();
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan plan) {
    plans.add(plan);
    return (written: written.future, done: done.future);
  }
}

class _Repo extends LocalRepository {
  _Repo(this.naps);
  final List<Map<String, dynamic>> naps;
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => {};
  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async => {'naps': naps};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {'sleep_source': 'manual'};
}

Future<SleepTimelineEditorState> _open(WidgetTester t, _Saver saver,
    {SleepEditorData? data}) async {
  t.view.physicalSize = const Size(412, 1500);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark),
    home: Builder(builder: (c) => Scaffold(body: TextButton(
      child: const Text('Sleep tab · 2026-11-14'),
      onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) =>
        SleepTimelineEditor(data: data ?? dtNight(), save: saver))),
    )))));
  await t.tap(find.text('Sleep tab · 2026-11-14'));
  await t.pumpAndSettle();
  return t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
}

void main() {
  // Round 2 replaces editor step buttons with the day view's selection control.
  testWidgets('full night includes the afternoon nap; shared selection and reset preserve it exactly', (t) async {
    final s = await _open(t, _Saver());
    final home = TimelineView(dtAt(160).toDouble(), dtAt(1090).toDouble());
    expect(s.controller.view, home);
    final zoom = find.byKey(const ValueKey('sleep-editor-zoom'));
    expect(t.getSize(zoom).height, greaterThanOrEqualTo(48));
    expect(find.byKey(const ValueKey('sleep-editor-zoom-in')), findsNothing);
    expect(find.byKey(const ValueKey('sleep-editor-zoom-out')), findsNothing);
    await t.tap(zoom);
    await t.pumpAndSettle();
    expect(s.controller.zoomSelection, isNotNull);
    await t.tap(zoom);
    await t.pumpAndSettle();
    expect(s.controller.view.span, lessThan(home.span));
    final reset = find.byKey(SleepTimelineEditor.resetKey);
    expect(t.getSize(reset).height, greaterThanOrEqualTo(48));
    await t.tap(reset);
    await t.pumpAndSettle();
    expect(s.controller.view, home);
  });

  testWidgets('a short recorded night keeps its exact bounds on open and reset', (t) async {
    final base = dtNight(withNap: false);
    final d = SleepEditorData(day: base.day, domainStart: base.domainStart, hr: base.hr,
      movement: base.movement,
      main: SleepBlock('main', BlockKind.main, dtAt(160), dtAt(180)));
    final state = await _open(t, _Saver(), data: d);
    final home = TimelineView(dtAt(160).toDouble(), dtAt(180).toDouble());
    expect(state.controller.view, home);
    state.controller.glideTo(TimelineView(dtAt(150).toDouble(), dtAt(210).toDouble()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(SleepTimelineEditor.resetKey));
    await t.pumpAndSettle();
    expect(state.controller.view, home);
    // The full-region invariant also applies after dragging a window shorter.
    state.blocksChanged([d.main.copyWith(end: dtAt(170))]);
    state.controller.reset();
    await t.pumpAndSettle();
    expect(state.controller.view, TimelineView(dtAt(160).toDouble(), dtAt(170).toDouble()));
  });

  testWidgets('zoom frames preserve readout Text widgets and list position', (t) async {
    final s = await _open(t, _Saver());
    final readout = find.descendant(of: find.byKey(SleepTimelineEditor.readoutKey), matching: find.byType(Text));
    final before = t.widgetList<Text>(readout).toList();
    final list = t.state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)));
    final offset = list.position.pixels;
    s.controller.zoomAt(s.controller.view.center);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final during = t.widgetList<Text>(readout).toList();
    expect(during.length, before.length);
    for (var i = 0; i < before.length; i++) {
      expect(identical(before[i], during[i]), isTrue, reason: 'Static readout text $i rebuilt during zoom');
    }
    expect(list.position.pixels, offset);
    await t.pumpAndSettle();
  });

  test('load retains overlapping stored naps and respects a calendar day across DST', () async {
    // Under America/Denver this evening-to-evening domain is 25 hours. Under
    // UTC it is 24. The expected end is a calendar boundary in either zone.
    final a = DateTime(2026, 11, 1, 1).millisecondsSinceEpoch ~/ 1000;
    final b = a + 1800;
    final d = await SleepEditorData.load(_Repo([{'start': a, 'end': b, 'source': 'manual'}]),
      '2026-11-01', window: (a - 3600, b + 3600));
    expect(d.naps.map((n) => (n.start, n.end)).toList(), [(a, b), (a, b)],
      reason: 'Display retains each returned entry, including overlaps');
    final expectedEnd = DateTime(2026, 11, 1, 20).millisecondsSinceEpoch ~/ 1000;
    expect(d.domainEnd, expectedEnd);
  });

  testWidgets('entry controls are exclusive and target the selected manual nap through Save', (t) async {
    final base = dtNight();
    final nap = base.naps.single;
    final d = SleepEditorData(day: base.day, domainStart: base.domainStart, hr: base.hr,
      movement: base.movement, main: base.main, naps: base.naps, napSources: {nap.id: 'manual'});
    final saver = _Saver();
    final s = await _open(t, saver, data: d);
    expect(find.text('Recalculate time in bed'), findsOneWidget);
    expect(find.text('Back to automatic'), findsNothing);
    s.blockSelected(nap.id, zoom: false);
    await t.pumpAndSettle();
    expect(find.byIcon(LucideIcons.bedDouble), findsWidgets);
    expect(find.text('Recalculate time in bed'), findsNothing);
    final automatic = find.text('Back to automatic');
    expect(automatic, findsOneWidget);
    await t.ensureVisible(automatic);
    await t.tap(automatic);
    await t.pumpAndSettle();
    // Choosing the action only stages it. Cancel/back can still leave safely.
    expect(saver.plans, isEmpty);
    await t.ensureVisible(find.byKey(SleepTimelineEditor.saveKey));
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));
    await t.pump();
    final entry = saver.plans.single.entry!;
    expect((entry.start, entry.end, entry.main, entry.source, entry.action.name),
      (nap.start, nap.end, false, 'manual', 'automatic'));
    expect(saver.plans.single.naps, isEmpty, reason: 'Unrelated naps are untouched');
    expect(find.byType(SleepTimelineEditor), findsOneWidget);
    saver.written.complete();
    await t.pumpAndSettle();
    expect(find.text('Sleep tab · 2026-11-14'), findsOneWidget);
    expect(saver.done.isCompleted, isFalse);
  });

  testWidgets('Not sleep is entry scoped and write failure keeps the editor open', (t) async {
    final saver = _Saver();
    final s = await _open(t, saver);
    final notSleep = find.text('Not sleep');
    await t.ensureVisible(notSleep);
    await t.tap(notSleep);
    await t.pumpAndSettle();
    expect(saver.plans, isEmpty);
    await t.ensureVisible(find.byKey(SleepTimelineEditor.saveKey));
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));
    await t.pump();
    final entry = saver.plans.single.entry!;
    expect((entry.start, entry.end, entry.main, entry.action.name),
      (s.blocks.first.start, s.blocks.first.end, true, 'notSleep'));
    saver.written.completeError(const SleepEditInvalid('Entry changed'));
    saver.done.complete(const SleepOperationResult(success: false));
    await t.pumpAndSettle();
    expect(find.byType(SleepTimelineEditor), findsOneWidget);
    expect(find.textContaining('Entry changed'), findsOneWidget);
  });

  // WHY: retaining separately stored overlapping entries is display-only.
  // Opening and immediately saving must never hand a merge to the writer.
  testWidgets('unchanged Save with an overlapping stored nap writes nothing', (t) async {
    final base = dtNight();
    final saver = _Saver();
    final nap = SleepBlock('overlap', BlockKind.nap, base.main.start + 600, base.main.start + 2400);
    final d = SleepEditorData(day: base.day, domainStart: base.domainStart, hr: base.hr,
      movement: base.movement, main: base.main, naps: [nap, ...base.naps],
      napSources: {nap.id: 'manual'});
    final s = await _open(t, saver, data: d);
    expect(s.blocks, [base.main, nap, ...base.naps]);
    await t.ensureVisible(find.byKey(SleepTimelineEditor.saveKey));
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));
    await t.pumpAndSettle();
    expect(saver.plans, isEmpty);
    expect(find.text('Sleep tab · 2026-11-14'), findsOneWidget);
  });

  testWidgets('manual main window exposes only automatic; detected main recalculation is durable', (t) async {
    final base = dtNight();
    final mine = SleepEditorData(day: base.day, domainStart: base.domainStart, hr: base.hr,
      movement: base.movement, main: base.main, naps: base.naps, mainSource: 'manual');
    final first = _Saver();
    await _open(t, first, data: mine);
    expect(find.text('Back to automatic'), findsOneWidget);
    expect(find.text('Recalculate time in bed'), findsNothing);
    await t.tap(find.byIcon(LucideIcons.chevronLeft));
    await t.pumpAndSettle();
    final saver = _Saver();
    await _open(t, saver);
    await t.ensureVisible(find.text('Recalculate time in bed'));
    await t.tap(find.text('Recalculate time in bed'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(SleepTimelineEditor.saveKey));
    await t.tap(find.byKey(SleepTimelineEditor.saveKey));
    await t.pump();
    final entry = saver.plans.single.entry!;
    expect((entry.main, entry.start, entry.end, entry.action),
      (true, base.main.start, base.main.end, SleepEntryAction.recalculate));
    expect(saver.plans.single.naps, isEmpty);
    expect(saver.plans.single.window, isNull);
    saver.written.complete();
    await t.pumpAndSettle();
    expect(find.text('Sleep tab · 2026-11-14'), findsOneWidget);
  });

  // WHY: navigation must use the selected SleepDetail night, not today.
  // Exercise the production openTimeline method and the real navigation stack.
  testWidgets('Sleep tab opens its selected historical night and back preserves the tab state', (t) async {
    final app = AppState.forTesting()..repo = _Repo([]);
    addTearDown(app.dispose);
    final base = dtNight(withNap: false);
    t.view.physicalSize = const Size(412, 1300);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(value: app,
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: SleepDetail(
        day: base.day, data: SleepData(day: base.day, night: {
          'onset_ts': base.main.start, 'wake_ts': base.main.end,
          'sleep_source': 'manual', 'duration_min': 480, 'in_bed_min': 530,
        }),
      ))));
    await t.pumpAndSettle();
    final tab = t.state(find.byType(SleepDetail));
    unawaited((tab as dynamic).openTimeline() as Future<void>);
    await t.pumpAndSettle();
    final editor = t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
    expect(editor.widget.data.day, '2026-11-14');
    expect((editor.widget.data.main.start, editor.widget.data.main.end),
      (base.main.start, base.main.end));
    await t.tap(find.byIcon(LucideIcons.chevronLeft));
    await t.pumpAndSettle();
    expect(identical(t.state(find.byType(SleepDetail)), tab), isTrue);
    expect(t.widget<SleepDetail>(find.byType(SleepDetail)).day, '2026-11-14');
  });

  testWidgets('back returns to the same Sleep tab night without writing', (t) async {
    final saver = _Saver();
    await _open(t, saver);
    expect(find.text('Edit sleep'), findsOneWidget);
    expect(find.textContaining('14'), findsWidgets);
    await t.tap(find.byIcon(LucideIcons.chevronLeft));
    await t.pumpAndSettle();
    expect(find.text('Sleep tab · 2026-11-14'), findsOneWidget);
    expect(saver.plans, isEmpty);
  });
}
