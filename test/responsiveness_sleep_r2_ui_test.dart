// WHY: an ongoing durable write cannot disable sleep controls or swallow a
// newer action. The write is gated to exercise actual widget callbacks.
import 'dart:async';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/ui2/sleep_operation_errors.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/data/local_repository.dart';

class _App extends AppState {
  _App() : super.forTesting();
  final receipt = Completer<SleepOperationResult>();
  int rejected = 0, recalculated = 0, cleared = 0;
  Completer<SleepOperationResult>? slowReject;
  @override
  Future<SleepOperationResult> clearSleepOverride(String day) async {
    cleared++;
    return const SleepOperationResult(success: true, recalculating: true);
  }

  @override
  Future<SleepOperationResult> recalculateSleep(String day) {
    recalculated++;
    return sleepOperations.mutate(day, () async {
      final result = await receipt.future;
      if (!result.success) throw StateError(result.error ?? 'write failed');
    });
  }

  @override
  Future<SleepOperationResult> rejectSleep(String day) async {
    rejected++;
    if (slowReject != null) return slowReject!.future;
    return const SleepOperationResult(success: true, recalculating: true);
  }
}

class _ChartRepo extends LocalRepository {
  _ChartRepo(this.phase);
  final String phase;
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async => {
    'points': [
      {'t': 1794571200, 'v': 55.0},
    ],
    'sleep_edit': SleepEditView(dependsOn: '2026-11-10', dependsPhase: phase),
  };
  @override
  Future<List<String>> availableDays() async => [
    for (var d = 9; d <= 15; d++) '2026-11-${d.toString().padLeft(2, '0')}',
  ];
  @override
  Future<Map<String, dynamic>> getInsights() async => {};
  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async => {};
}

void _test(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(
      name,
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 11, 15, 12)),
        () => body(tester),
      ),
    );

void main() {
  const saved = {
    'has_sleep': false,
    'sleep_source': 'manual',
    'onset_ts': 1000,
    'wake_ts': 4600,
  };
  // WHY: failed writes must reach the current screen after navigation.
  // CLAIM(sleep-edit-r2-receipt); catches: route-owned failures and mounted gating.
  // Reviewer probe PASSES when a failed receipt after leaving Sleep is lost.
  _test('R2-5 failed persistence survives route disposal and reopening', (
    t,
  ) async {
    t.view.physicalSize = const Size(1200, 14000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = _App();
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          builder: (c, child) => SleepOperationErrors(child: child!),
          navigatorKey: nav,
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: const Text('Home')),
        ),
      ),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const SleepDetail(
          data: SleepData(day: '2026-11-13', night: saved),
        ),
      ),
    );
    await t.pumpAndSettle();
    final recalculate = find.widgetWithText(
      TextButton,
      'Recalculate this night',
    );
    await t.ensureVisible(recalculate);
    await t.tap(recalculate);
    await t.pump();
    expect(app.recalculated, 1);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    app.receipt.complete(
      const SleepOperationResult(success: false, error: 'disk is full'),
    );
    await t.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.textContaining('disk is full'), findsWidgets);
    expect(find.byType(SnackBar), findsNothing);
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const SleepDetail(
          data: SleepData(day: '2026-11-13', night: saved),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.textContaining('disk is full'),
      findsWidgets,
      reason: 'failure belongs to the operation owner, not the departed route',
    );
    await t.tap(find.widgetWithText(TextButton, 'Dismiss'));
    await t.pumpAndSettle();
    expect(app.sleepOperations.failures, isEmpty);
    expect(find.textContaining('disk is full'), findsNothing);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });
  // WHY: chart values keep their edit warning through backoff with no live pass.
  // CLAIM(sleep-edit-r2-status); catches: discarding durable status in MetricData.
  for (final phase in ['queued', 'failed']) {
    _test('R2-4 chart renders $phase edit status while the runner is idle', (
      t,
    ) async {
      t.view.physicalSize = const Size(1200, 14000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final app = _App();
      final data = await MetricData.load(
        _ChartRepo(phase),
        'hrv',
        journal: false,
      );
      expect(data.sleepEdit?.dependsOn, '2026-11-10');
      expect(data.series.map((p) => p.v), [55.0]);
      await t.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: MetricDetail('hrv', data: data, initialRange: 7),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('sleep-edit-status')), findsOneWidget);
      expect(
        find.textContaining(phase == 'failed' ? 'failed' : 'pending'),
        findsWidgets,
      );
      expect(
        find.textContaining('55'),
        findsWidgets,
        reason: 'the measured value stays visible',
      );
      await t.pumpWidget(const SizedBox());
      app.dispose();
    });
  }

  // WHY: after own-night publication only the later work is pending.
  // CLAIM(sleep-edit-r2-status); catches: hiding applied values under a pulse.
  _test('R2-3 applied own-night values stay readable during dependent work', (
    t,
  ) async {
    t.view.physicalSize = const Size(1200, 14000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = _App();
    await t.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const SleepDetail(
            data: SleepData(
              day: '2026-11-13',
              night: {
                'has_sleep': true,
                'duration_min': 420,
                'sleep_source': 'manual',
                'onset_ts': 1000,
                'wake_ts': 26200,
                'recalculating': true,
                'sleep_edit': SleepEditView(ownPhase: 'dependents'),
              },
            ),
          ),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Updating later days'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is PendingContent && w.pending),
      findsNothing,
    );
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  _test('R2-4 Home keeps queued edit status while no calculation runs', (
    t,
  ) async {
    t.view.physicalSize = const Size(1200, 14000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = _App();
    await t.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const HomeScreen(
            data: HomeData(
              sleepEdit: SleepEditView(
                dependsOn: '2026-11-10',
                dependsPhase: 'queued',
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('sleep-edit-status')), findsOneWidget);
    expect(find.textContaining('pending'), findsWidgets);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  // WHY: the receipt timeout also belongs to the operation, after navigation.
  // CLAIM(sleep-edit-r2-receipt); catches: publishing only widget-caught failures.
  _test('R2-5 receipt timeout is reported after the Sleep route closes', (
    t,
  ) async {
    t.view.physicalSize = const Size(1200, 14000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = _App(), nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          builder: (c, child) => SleepOperationErrors(child: child!),
          navigatorKey: nav,
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const SleepDetail(
          data: SleepData(day: '2026-11-13', night: saved),
        ),
      ),
    );
    await t.pumpAndSettle();
    final button = find.widgetWithText(TextButton, 'Recalculate this night');
    await t.ensureVisible(button);
    await t.tap(button);
    await t.pump();
    nav.currentState!.pop();
    await t.pumpAndSettle();
    await t.pump(const Duration(minutes: 16));
    expect(find.textContaining('Saving timed out'), findsWidgets);
    expect(app.sleepOperations.failures.single.day, '2026-11-13');
    app.receipt.complete(
      const SleepOperationResult(success: false, error: 'late write failure'),
    );
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });
}
