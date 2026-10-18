// getToday's freshness refresh must not hold a screen's first paint.
//
// (a) SleepDetail paints its night while the refresh never completes.
// (b) Home over a stored `today` row for ANOTHER day shows an honest absent
//     state, never the old values as today's, then the refreshed values.
// (c) The refresh is single-flight, and a throwing run clears its latch.
//
// Fakes and a fixed-date database; no real clock decides a result.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' show CircularProgressIndicator;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import 'support/as_of_recalc_fakes.dart';
import 'support/shift_run.dart' show phoneSurface;

/// Stored-read repo: `getToday` and the refresh never answer.
class _HangingRefreshRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() => Completer<Map<String, dynamic>>().future;
  @override
  Future<Map<String, dynamic>> getTodayStored() async => {
        'status': {'today_day': '2026-08-05', 'refresh_pending': true},
      };
  @override
  Future<void> refreshTodayFreshness() => Completer<void>().future;
  @override
  Future<List<String>> availableDays() async => ['2026-08-05', '2026-08-04'];
  @override
  Future<SleepDetailBundle> getSleepDetailBundle(String day,
      {required List<String> chartKeys, required int windowDays}) async {
    return SleepDetailBundle(
      night: const {'duration_min': 443, 'in_bed_min': 486, 'efficiency': .91},
      timeline: const {},
      insights: const {},
      charts: {for (final k in chartKeys) k: {'points': const []}},
      windows: const [],
    );
  }
}

/// Home: stored read answers at once with today's figures absent; the refresh
/// is released by the test, after which the stored read has them.
class _TwoStageHome extends HomeRepo {
  _TwoStageHome() : super(const {});
  final release = Completer<void>();
  int refreshes = 0;
  bool refreshed = false;

  @override
  Future<Map<String, dynamic>> getToday() => Completer<Map<String, dynamic>>().future;
  @override
  Future<Map<String, dynamic>> getTodayStored() async => refreshed
      ? homeBundle(
          readiness: 71, overnightAt: todayAtMs(8, 42), activityAt: todayAtMs(8, 42))
      : {
          ...homeBundle(withDaily: false),
          'status': {
            'today_day': todayId,
            'activity_state': 'building',
            'overnight_state': 'building',
            'overnight_day': yesterdayId,
            'showing_prior_overnight': true,
            'refresh_pending': true,
          },
        };
  @override
  Future<void> refreshTodayFreshness() async {
    refreshes++;
    await release.future;
    refreshed = true;
  }
}

class _Throw implements FreshnessWriteProbe {
  _Throw(this.f);
  final Future<void>? Function() f;
  @override
  Future<void> beforeWrite() async => await f();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('(a) SleepDetail paints its night without the refresh', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _HangingRefreshRepo();
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const SleepDetail(day: '2026-08-05')));
    await t.pump(const Duration(seconds: 3));
    expect(find.textContaining('7h 23'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('(b) Home: absent while the refresh runs, then the new values',
      (t) async {
    phoneSurface(t);
    final repo = _TwoStageHome();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    await t.pump(const Duration(seconds: 1));
    expect(repo.refreshes, 1, reason: 'asked once, after the first paint');
    expect(find.text('71'), findsNothing);
    expect(find.text('70'), findsNothing);

    repo.release.complete();
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('71'), findsWidgets);
    expect(repo.refreshes, 1);
  });

  group('real database', () {
    final systemNowMs = LocalDb.nowMs;
    late LocalRepositoryImpl repo;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_today_first_paint_test.db';
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
      repo = LocalRepositoryImpl(getProfileMap: () => const {});
    });
    tearDownAll(() async {
      LocalDb.nowMs = systemNowMs;
      LocalDb.debugBeforeFreshnessWrite = null;
      await LocalDb.close();
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
    });

    test('a stored row for another day is never served as today', () async {
      final db = await LocalDb.instance;
      await db.delete('day_result');
      final y = dayLabelOf(DateTime.now().subtract(const Duration(days: 1)));
      await LocalDb.putDayResult(
        dayId: y,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({
          'date': y,
          'scalars': {'readiness': 80.0, 'rhr': 50.0, 'rmssd': 55.0},
        }),
        windowJson: '{}',
        series: const {},
      );
      await LocalDb.putComputeFreshness(
        'today',
        jsonEncode({
          'today_day': y,
          'overnight_state': 'ready',
          'overnight_day': y,
          'activity_state': 'ready',
          'activity_day': y,
          'activity_computed_at': 1,
        }),
      );
      final runs = LocalDb.debugFreshnessRuns;
      final r = await repo.getTodayStored();
      expect(LocalDb.debugFreshnessRuns, runs, reason: 'no refresh on the read');
      final s = r['status'] as Map;
      expect(s['refresh_pending'], true);
      expect(s['today_day'], todayLabel());
      expect(s['activity_state'], 'building');
      expect(s['activity_day'], isNull);
      expect(s['overnight_state'], 'building');
      expect(s['showing_prior_overnight'], true);
      expect(s['overnight_day'], y);
      for (final k in ['strain', 'steps']) {
        final m = (r['daily'] as Map)[k];
        expect(m is Map ? m['value'] : m, isNull, reason: k);
      }
    });

    test('two opens during one refresh run it once; a throw clears the latch',
        () async {
      final gate = Completer<void>();
      var calls = 0;
      LocalDb.debugBeforeFreshnessWrite = _Throw(() {
        calls++;
        return calls == 1 ? gate.future : (calls == 2 ? throw StateError('x') : null);
      });
      final before = LocalDb.debugFreshnessRuns;
      final a = repo.refreshTodayFreshness();
      final b = repo.refreshTodayFreshness();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      gate.complete();
      await Future.wait([a, b]);
      expect(LocalDb.debugFreshnessRuns - before, 1);

      await expectLater(repo.refreshTodayFreshness(), throwsStateError);
      // The latch is clear: the next open runs again.
      final runs = LocalDb.debugFreshnessRuns;
      await repo.refreshTodayFreshness();
      expect(LocalDb.debugFreshnessRuns - runs, 1);
    });
  });
}
