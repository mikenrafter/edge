// P: the Status section's wake decision trace follows the trace. A tick adds
// rows for the SAME armed occurrence, so reloading only when the epoch changes
// left the section stale until you left and came back.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';

import '../wake/support/wake_fakes.dart';
import 'support/fake_alarm_engine.dart';

final _wakeAt = DateTime(2026, 10, 5, 7, 0);
int get _epoch => _wakeAt.millisecondsSinceEpoch ~/ 1000;

Future<void> _append(String kind, Map<String, Object?> data, int atMs) =>
    LocalDb.appendWakeTrace(
      wakeEpochSec: _epoch,
      atMs: atMs,
      kind: kind,
      dataJson: jsonEncode(data),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_alarm_trace_refresh_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> pumpScreen(WidgetTester t) async {
    final app = AppState.forTesting(engine: FakeAlarmEngine());
    addTearDown(app.dispose);
    app.device.alarmEpoch = _epoch;
    t.view.physicalSize = const Size(1170, 24000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const AlarmScreen(),
        ),
      ),
    );
    return app;
  }

  /// Let the real (sqflite) future finish, then show its result.
  Future<void> settle(WidgetTester t) async {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await t.pump();
  }

  testWidgets('a tick that appends to the same wake updates the Status trace',
      (t) async {
    await t.runAsync(() async {
      await _append('fallback', {
        'armed': true,
        'confirmed': true,
        'rearmed': false,
      }, 1);
    });
    final app = await pumpScreen(t);
    await settle(t);
    expect(find.textContaining('armed and confirmed'), findsOneWidget);
    expect(find.textContaining('Natural Wake:'), findsNothing);

    // A tick records a Natural decision for the same armed occurrence.
    await t.runAsync(() async {
      await _append('natural', {'reason': 'warmup'}, 2);
      app.wake.noteTraceChanged(); // what the orchestrator does after a tick
    });
    await t.pump();
    await settle(t);
    expect(
      find.textContaining('Natural Wake: it was still gathering'),
      findsOneWidget,
      reason: 'the trace must follow the tick, not wait for a re-entry',
    );
    expect(find.textContaining('armed and confirmed'), findsOneWidget);
  });

  testWidgets('a reload that finishes after the screen is gone is harmless',
      (t) async {
    await t.runAsync(() => _append('fallback', {'armed': true}, 3));
    final app = await pumpScreen(t);
    await settle(t);
    await t.runAsync(() async {
      app.wake.noteTraceChanged();
    });
    await t.pump(); // the reload starts
    await t.pumpWidget(const SizedBox()); // the screen goes before it ends
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await t.pump();
    expect(t.takeException(), isNull);
  });

  test('the orchestrator signals once per tick that wrote rows, not per row',
      () async {
    var signals = 0;
    final state = MemoryWakeStateStore();
    final trace = MemoryWakeTraceStore();
    final now = _wakeAt.subtract(const Duration(minutes: 5));
    final o = WakeOrchestrator(
      env: FakeWakeEnv()..armedEpochSec = _epoch,
      stateStore: state,
      traceStore: trace,
      now: () => now,
      onTraceChanged: () => signals++,
    );
    final plan = planFor(_wakeAt);
    await o.tick(plan);
    expect((await trace.forWake(_epoch)).length, greaterThan(1),
        reason: 'plan + fallback rows');
    expect(signals, 1);
    await o.tick(plan); // nothing new is logged
    expect(signals, 1, reason: 'an unchanged tick adds no rows and no signal');
  });

  test('the trace read is bounded to the newest rows, oldest first', () async {
    const wake = 1790000000;
    for (var i = 0; i < kWakeTraceReadLimit + 25; i++) {
      await LocalDb.appendWakeTrace(
        wakeEpochSec: wake,
        atMs: i,
        kind: 'gap',
        dataJson: jsonEncode({'i': i}),
      );
    }
    final rows = await const DbWakeTraceStore().forWake(wake);
    expect(rows, hasLength(kWakeTraceReadLimit));
    expect(rows.first.data['i'], 25, reason: 'the oldest 25 are dropped');
    expect(rows.last.data['i'], kWakeTraceReadLimit + 24);
  });
}
