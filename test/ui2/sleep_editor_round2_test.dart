// WHY: phone round 2. CLAIM(sleep-editor-shared-zoom): identical gestures
// must use the day view's controller and targets, even over a sleep block.
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/day_timeline/activities_timeline.dart';
import 'package:openstrap_edge/ui2/day_timeline/pilot_flags.dart';
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
  var graph = Completer<Map<String, dynamic>>();
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
    final data = SleepEditorData(day: base.day, domainStart: DateTime(2026,11,14).millisecondsSinceEpoch~/1000,
      hr: base.hr, movement: base.movement,
      main: SleepBlock('main', BlockKind.main, DateTime(2026,11,14).millisecondsSinceEpoch~/1000,DateTime(2026,11,15).millisecondsSinceEpoch~/1000));
    final traces = <List<TimelineView>>[];
    for (final sleep in [false, true]) {
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: sleep
        ? SleepTimelineEditor(data: data, save: _Saver())
        : Scaffold(body: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
          child: ActivitiesTimeline(data: TimelineData(day: data.day,
            graph: DayGraph(dayStart: data.domainStart, hr: data.hr, movement: data.movement)),
            rows: const [], review: null, editor: _Editor())))));
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
      await t.tap(zoom); // The single control resets a zoomed view first.
      await t.pumpAndSettle();
      trace.add(controller.view);
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
      await t.tap(zoom);
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
    DayTimelinePilot.debugOverride[DayTimelinePilot.sleep] = true;
    addTearDown(DayTimelinePilot.debugOverride.clear);
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
    final entry = find.widgetWithText(TextButton, 'Edit sleep');
    await t.ensureVisible(entry);
    await t.pumpAndSettle();
    // Deliver a burst through the actual entry control's callback. Capturing
    // it also covers queued taps after the incoming route blocks hit testing.
    final tap = t.widget<TextButton>(entry).onPressed!;
    for (var i = 0; i < 3; i++) { tap(); }
    await t.pump(); // Starts the route transition at opacity zero.
    await t.pump(const Duration(milliseconds: 16)); // First drawn editor frame; read still blocked.
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
    await t.pump(const Duration(milliseconds: 16));
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

  // CLAIM(sleep-editor-immediate-route): a failed read stays inside the single
  // editor route and can retry without losing the selected Sleep tab night.
  testWidgets('load failure retries inside the same editor route', (t) async {
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
    await t.pumpAndSettle();
    repo.graph.completeError(StateError('read failed'));
    await t.pumpAndSettle();
    expect(find.text('Could not load this night.'), findsOneWidget);
    unawaited((tab as dynamic).openTimeline() as Future<void>);
    await t.pump();
    expect(routes.pushed, hasLength(2));
    repo.graph = Completer<Map<String, dynamic>>();
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sleep-editor-loading')), findsOneWidget);
    repo.graph.complete({});
    await t.pumpAndSettle();
    expect(find.byType(SleepTimelineEditor), findsOneWidget);
    expect(routes.pushed, hasLength(2));
  });

  // WHY: replacing icon controls must preserve accessible 48 dp actions in
  // every shipped locale, including larger text. CLAIM(sleep-editor-shared-zoom).
  testWidgets('shared zoom controls expose selected state and 48 dp targets in every locale', (t) async {
    for (final language in ['en', 'de', 'es', 'fr', 'hi', 'ru', 'zh']) {
      final l = lookupAppLocalizations(Locale(language));
      final c = TimelineController(domainStart: 0, domainEnd: 86400,
        home: const TimelineView(0, 86400));
      addTearDown(c.dispose);
      c.zoomAt(43200);
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark),
        home: Scaffold(body: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SizedBox(width: 260, child: TimelineZoomControls(controller: c,
            zoomLabel: l.sleepEditorZoom, resetLabel: l.sleepEditorResetZoom,
            zoomKey: const ValueKey('zoom'), resetKey: const ValueKey('reset')))))));
      await t.pumpAndSettle();
      for (final key in ['zoom', 'reset']) {
        final size = t.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(48), reason: language);
        expect(size.height, greaterThanOrEqualTo(48), reason: language);
      }
      await t.tap(find.byKey(const ValueKey('zoom')));
      await t.pumpAndSettle();
      expect(t.getSemantics(find.byKey(const ValueKey('zoom'))).flagsCollection.isSelected,
        Tristate.isTrue, reason: language);
      await t.tap(find.byKey(const ValueKey('reset')));
      await t.pumpAndSettle();
      expect(c.view, const TimelineView(0, 86400));
      expect(c.zoomSelection, isNull);
      expect(t.takeException(), isNull, reason: language);
    }
  });

}
