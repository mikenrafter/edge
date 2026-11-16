// WHY: phone round 2. CLAIM(sleep-editor-shared-zoom): identical gestures
// must use the day view's controller and targets, even over a sleep block.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/day_timeline/activities_timeline.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import '../support/day_timeline_fixtures.dart';

class _Editor implements DayRowEditListener {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class _Saver implements SleepEditSaver {
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan plan) =>
      throw StateError('Gestures must never write');
}
class _LoadingRepo extends LocalRepository {
  final graph = Completer<Map<String, dynamic>>();
  int reads = 0;
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) {
    reads++;
    return graph.future;
  }
  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async => {};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {};
}
class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushed.add(route);
}

void main() {
  testWidgets('day and sleep share double tap, selection handles, scrub and reset transitions', (t) async {
    t.view.physicalSize = const Size(412, 1500);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final base = dtNight(withNap: false);
    // Equal inputs isolate behavior from the intentionally different home ranges.
    final data = SleepEditorData(day: base.day, domainStart: base.domainStart,
      hr: base.hr, movement: base.movement,
      main: SleepBlock('main', BlockKind.main, base.domainStart, base.domainEnd));
    final traces = <List<TimelineView>>[];
    for (final sleep in [false, true]) {
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: sleep
        ? SleepTimelineEditor(data: data, save: _Saver())
        : Scaffold(body: ActivitiesTimeline(data: TimelineData(day: data.day,
            graph: DayGraph(dayStart: data.domainStart, hr: data.hr, movement: data.movement)),
            rows: const [], review: null, editor: _Editor()))));
      await t.pumpAndSettle();
      final controller = sleep
        ? t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor)).controller
        : t.state<ActivitiesTimelineState>(find.byType(ActivitiesTimeline)).controller;
      final trace = <TimelineView>[controller.view];
      Offset point(double f) {
        final box = t.getRect(find.byKey(DayTimelineChart.chartKey));
        return Offset(box.left + DayTimelineChart.gutter +
            f * (box.width - DayTimelineChart.gutter - DayTimelineChart.rightPad), box.center.dy);
      }
      for (final f in [.45, .7]) {
        await t.tapAt(point(f));
        await t.pump(const Duration(milliseconds: 60));
        await t.tapAt(point(f));
        await t.pump();
        trace.add(controller.target!);
        await t.pumpAndSettle();
        trace.add(controller.view);
      }
      // Independent scale oracle: two 30% zooms from 1440 minutes.
      expect(controller.view.span, closeTo(705.6 * 60, .001));
      final zoom = find.byKey(ValueKey(sleep ? 'sleep-editor-zoom' : 'activities-zoom'));
      expect(zoom, findsOneWidget);
      await t.tap(zoom);
      await t.pumpAndSettle();
      expect(controller.zoomSelection, isNotNull);
      final z = controller.zoomSelection!;
      final from = point(controller.view.fraction(z.a));
      await t.dragFrom(from, const Offset(25, 0));
      await t.pumpAndSettle();
      await t.tap(zoom);
      await t.pump();
      trace.add(controller.target!);
      await t.pumpAndSettle();
      trace.add(controller.view);
      await t.dragFrom(point(.3), const Offset(20, 0));
      await t.pumpAndSettle();
      expect(controller.scrub, isNotNull);
      trace.add(controller.view); // Scrub changes no zoom range.
      await t.tap(find.byKey(ValueKey(sleep ? 'sleep-editor-reset' : 'activities-reset')));
      await t.pump();
      trace.add(controller.target!);
      await t.pumpAndSettle();
      trace.add(controller.view);
      expect(controller.view, TimelineView(data.domainStart.toDouble(), data.domainEnd.toDouble()));
      traces.add(trace);
    }
    expect(traces[1], traces[0]);
  });

  // CLAIM(sleep-editor-immediate-route): disk latency cannot delay navigation
  // or allow three in-flight loads to push three routes.
  testWidgets('three Edit sleep taps push one route before data loads and back once returns', (t) async {
    final repo = _LoadingRepo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    final routes = _Routes();
    final d = dtNight(withNap: false);
    t.view.physicalSize = const Size(412, 1300);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(value: app,
      child: MaterialApp(theme: buildTheme(Brightness.dark), navigatorObservers: [routes],
        home: SleepDetail(day: d.day, data: SleepData(day: d.day, night: {
          'onset_ts': d.main.start, 'wake_ts': d.main.end, 'sleep_source': 'manual',
          'duration_min': 480, 'in_bed_min': 530,
        })))));
    await t.pumpAndSettle();
    final tab = t.state(find.byType(SleepDetail));
    for (var i = 0; i < 3; i++) {
      unawaited((tab as dynamic).openTimeline() as Future<void>);
    }
    await t.pump(); // First frame, repository graph still blocked.
    expect(repo.graph.isCompleted, isFalse);
    expect(routes.pushed, hasLength(2)); // Sleep tab + exactly one editor.
    expect(find.text('Edit sleep'), findsOneWidget);
    expect(find.byKey(const ValueKey('sleep-editor-loading')), findsOneWidget);
    await t.pump(const Duration(milliseconds: 400));
    repo.graph.complete({});
    await t.pumpAndSettle();
    expect(find.byType(SleepTimelineEditor), findsOneWidget);
    expect(routes.pushed, hasLength(2));
    final editor = t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
    expect(editor.widget.data.day, d.day);
    Navigator.of(t.element(find.byType(SleepTimelineEditor))).pop();
    await t.pumpAndSettle();
    expect(identical(t.state(find.byType(SleepDetail)), tab), isTrue);
    expect(find.byType(SleepTimelineEditor), findsNothing);
    // A fresh tap after returning must work; the route latch must release.
    unawaited((tab as dynamic).openTimeline() as Future<void>);
    await t.pumpAndSettle();
    expect(routes.pushed, hasLength(3));
    expect(find.byType(SleepTimelineEditor), findsOneWidget);
  });
  // WHY: back during a read must neither reopen the route nor poison later taps.
  // CLAIM(sleep-editor-immediate-route).
  testWidgets('back during load is immediate and a late result cannot reopen editor', (t) async {
    final repo = _LoadingRepo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    final routes = _Routes();
    final d = dtNight(withNap: false);
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(value: app,
      child: MaterialApp(theme: buildTheme(Brightness.dark), navigatorObservers: [routes],
        home: SleepDetail(day: d.day, data: SleepData(day: d.day, night: {
          'onset_ts': d.main.start, 'wake_ts': d.main.end, 'duration_min': 480,
        })))));
    await t.pumpAndSettle();
    final tab = t.state(find.byType(SleepDetail));
    unawaited((tab as dynamic).openTimeline() as Future<void>);
    await t.pump();
    expect(routes.pushed, hasLength(2));
    Navigator.of(t.element(find.byKey(const ValueKey('sleep-editor-loading')))).pop();
    await t.pumpAndSettle();
    expect(identical(t.state(find.byType(SleepDetail)), tab), isTrue);
    repo.graph.complete({});
    await t.pumpAndSettle();
    expect(find.byType(SleepTimelineEditor), findsNothing);
    expect(routes.pushed, hasLength(2));
    unawaited((tab as dynamic).openTimeline() as Future<void>);
    await t.pumpAndSettle();
    expect(find.byType(SleepTimelineEditor), findsOneWidget);
    expect(routes.pushed, hasLength(3));
  });

}
