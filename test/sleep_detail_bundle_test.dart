// Sleep detail reads everything in ONE repository call.
//
// Measured on a real export: SleepData.load awaited ~14 repository calls in a
// row and every getChart re-read worn_min and the whole version table, ~50-60
// serialized round-trips behind any writer. The combined read must (a) return
// exactly what the per-key getChart path returned, (b) read worn_min and the
// version table once per load, and (c) be the only repository call the screen
// makes for the night.
//
// Part 1 runs through the production repository over a real (FFI) database with
// fixed dates and a fixed LocalDb clock. Part 2 uses fakes that throw on any
// per-piece read, so a screen that still sequences them fails.
import 'dart:convert';

import 'package:flutter/material.dart' show CircularProgressIndicator;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import 'support/as_of_recalc_fakes.dart' show perfApp;
import 'support/shift_run.dart' show phoneSurface;

const _keys = [
  'sleep',
  'deep',
  'efficiency',
  'unobserved_min',
  'awakenings',
  'longest_sleep_min',
  'sol_min',
];

Future<void> _put(String day, int at, Map<String, double?> series) async {
  LocalDb.nowMs = () => at;
  await LocalDb.putDayResult(
    dayId: day,
    algoVersion: kAlgoVersion,
    payloadJson: jsonEncode({'date': day, 'scalars': {'rmssd': 55.0}}),
    windowJson: '{}',
    series: series,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('real database', () {
    late LocalRepositoryImpl repo;
    final systemNowMs = LocalDb.nowMs;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_sleep_bundle_test.db';
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
      repo = LocalRepositoryImpl(getProfileMap: () => const {});
    });

    tearDownAll(() async {
      LocalDb.nowMs = systemNowMs;
      await LocalDb.close();
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final db = await LocalDb.instance;
      await db.delete('day_result');
      await db.delete('metric_series');
      await db.delete('metric_series_version');
      var at = DateTime.utc(2026, 9, 1, 8).millisecondsSinceEpoch;
      // Day 03 has no deep row and an explicit null efficiency; sol_min and
      // awakenings exist for the last night only. worn_min is on every day but 04.
      for (var d = 1; d <= 5; d++) {
        final day = '2026-08-0$d';
        await _put(day, at += 1000, {
          'tst_min': 400.0 + d,
          if (d != 3) 'deep_min': 80.0 + d,
          'efficiency': d == 3 ? null : 90.0 + d,
          'unobserved_min': 5.0 * d,
          if (d == 5) 'awakenings': 2.0,
          if (d == 5) 'sol_min': 12.0,
          'longest_sleep_min': 120.0 + d,
          if (d != 4) 'worn_min': 1200.0 + d,
        });
      }
    });

    test('bundle charts equal what getChart returns, key for key', () async {
      final expected = {for (final k in _keys) k: await repo.getChart(k)};
      final b = await repo.getSleepDetailBundle('2026-08-05',
          chartKeys: _keys, windowDays: 29);
      expect(jsonEncode(b.charts), jsonEncode(expected));
      // The absent cases survive: no deep on day 3, no sol_min before day 5.
      expect(b.charts['deep']!['points'], hasLength(4));
      expect(b.charts['sol_min']!['points'], hasLength(1));
    });

    test('bundle night, timeline, insights and windows equal their readers',
        () async {
      final b = await repo.getSleepDetailBundle('2026-08-05',
          chartKeys: _keys, windowDays: 29);
      expect(jsonEncode(b.night), jsonEncode(await repo.getDaySleepV2('2026-08-05')));
      expect(jsonEncode(b.timeline),
          jsonEncode(await repo.getDayTimeline('2026-08-05')));
      expect(jsonEncode(b.insights), jsonEncode(await repo.getInsights()));
      expect(jsonEncode(b.windows), jsonEncode(await repo.sleepWindows(days: 29)));
    });

    test('worn_min and the version table are read once per load', () async {
      // Re-open the same file through a logging factory, so every statement
      // the load sends to the handle is seen (a batch counts as its operations).
      final sql = <String>[];
      await LocalDb.close();
      // ignore: experimental_member_use
      databaseFactory = SqfliteDatabaseFactoryLogger(
        databaseFactoryFfi,
        options: SqfliteLoggerOptions(
          type: SqfliteDatabaseFactoryLoggerType.all,
          log: (e) {
            if (e is SqfliteLoggerSqlEvent || e is SqfliteLoggerBatchEvent) {
              sql.add(e.toString());
            }
          },
        ),
      );
      addTearDown(() async {
        await LocalDb.close();
        databaseFactory = databaseFactoryFfi;
      });
      await LocalDb.instance; // open (and its own statements) before the load
      sql.clear();
      await SleepData.load(repo, want: '2026-08-05');
      int count(bool Function(String) f) => sql.where(f).length;
      if (sql.isEmpty) fail("no statements were logged");
      expect(count((l) => l.contains('metric_series_version')), 1,
          reason: 'versions are one statement, not one per chart');
      expect(
          count((l) => l.contains('metric_series') &&
              !l.contains('metric_series_version') &&
              l.contains('worn_min')),
          1,
          reason: 'worn_min rides in the one metric_series read');
      expect(
          count((l) => l.contains('FROM metric_series') &&
              !l.contains('metric_series_version')),
          1,
          reason: 'every chart key comes from ONE metric_series statement');
    });
  });

  group('fakes', () {
    test('SleepData.load makes exactly one repository call for the night',
        () async {
      final repo = _BundleOnlyRepo();
      final d = await SleepData.load(repo, want: '2026-08-05');
      expect(repo.bundleCalls, 1);
      expect(repo.windowCalls, 1);
      expect(d.day, '2026-08-05');
      expect(d.night['duration_min'], 443);
      expect(d.tstHistory, [401.0, 402.0]);
      expect(d.deepHistory, <double>[]); // absent chart stays empty, not zeros
      expect(d.solMin, 12.0);
      expect(d.awakenings, isNull);
    });

    testWidgets('the screen shows its content after the one bundle call',
        (t) async {
      phoneSurface(t);
      final repo = _BundleOnlyRepo();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await t.pumpWidget(perfApp(app, const SleepDetail(day: '2026-08-05')));
      await t.pump(const Duration(seconds: 3));
      expect(repo.bundleCalls, 1);
      expect(find.textContaining('7h 23'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}

/// getToday / availableDays, the bundle and the windows before the night only;
/// every per-piece read throws.
class _BundleOnlyRepo extends LocalRepository {
  int bundleCalls = 0;

  @override
  Future<Map<String, dynamic>> getToday() async =>
      {'status': {'today_day': '2026-08-05'}};
  @override
  Future<List<String>> availableDays() async => ['2026-08-05', '2026-08-04'];

  // The windows BEFORE the night ride beside the bundle in the same `.wait`
  // (the bundle's own windows are the newest nights overall). One read, in
  // parallel, not a per-piece sequence.
  int windowCalls = 0;
  @override
  Future<List<Map<String, dynamic>>> sleepWindows(
      {int days = 60, String? before}) async {
    windowCalls++;
    return const [];
  }

  @override
  Future<SleepDetailBundle> getSleepDetailBundle(String day,
      {required List<String> chartKeys, required int windowDays}) async {
    bundleCalls++;
    int noon(int d) =>
        DateTime(2026, 8, d, 12).millisecondsSinceEpoch ~/ 1000;
    Map<String, dynamic> pts(List<(int, double)> l) => {
          'points': [for (final (d, v) in l) {'t': noon(d), 'v': v}],
        };
    return SleepDetailBundle(
      night: const {'duration_min': 443, 'in_bed_min': 486, 'efficiency': .91},
      timeline: const {},
      insights: const {},
      charts: {
        for (final k in chartKeys) k: pts(const []),
        'sleep': pts([(3, 401.0), (4, 402.0), (5, 403.0)]),
        'sol_min': pts([(5, 12.0)]),
      },
      windows: const [],
    );
  }
}
