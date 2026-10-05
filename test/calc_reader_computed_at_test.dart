// 8AG-perf P1b: the reader shapes carry the computed time of the row they
// actually read (epoch ms), so "As of" never names a time that was not read.
//
// Through the production repository over a real database, the way the other
// repository tests do: getDaySleepV2 / getDayHrv / getDayStress read it off the
// day_result row, getChart off the day_result rows of the days it draws. A day
// with no row has no `computed_at` (never "now"), and a past day never borrows
// another day's.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

import 'support/as_of_recalc_fakes.dart' show yesterdayId;

Future<int> _put(String day, {Map<String, double?> series = const {}}) async {
  await LocalDb.putDayResult(
    dayId: day,
    algoVersion: kAlgoVersion,
    payloadJson: jsonEncode({
      'date': day,
      'scalars': {'rmssd': 55.0},
      'sleep': {
        'accounting': {
          'value': {'tst_sec': 25200, 'waso_sec': 600, 'efficiency_pct': 91.0}
        },
      },
      'stress': {'score': 34, 'level': 'low'},
    }),
    windowJson: '{}',
    series: series,
  );
  return (await LocalDb.dayResult(day))!['computed_at'] as int;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalRepositoryImpl repo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_reader_computed_at_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
  });

  tearDownAll(() async {
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
  });

  test('day readers return the computed_at of the row they read', () async {
    final at = await _put(todayLabel());
    expect((await repo.getDaySleepV2(todayLabel()))['computed_at'], at);
    expect((await repo.getDayHrv(todayLabel()))['computed_at'], at);
    expect((await repo.getDayStress(todayLabel()))['computed_at'], at);
  });

  test('a past day with no row has none, and does not borrow today\'s',
      () async {
    await _put(todayLabel());
    expect((await repo.getDaySleepV2(yesterdayId))['computed_at'], isNull);
    expect((await repo.getDayHrv(yesterdayId)).containsKey('computed_at'),
        isFalse,
        reason: 'an empty day is the empty shape');
    expect((await repo.getDayStress(yesterdayId)).containsKey('computed_at'),
        isFalse);
  });

  test('today with no row of its own reports the row it fell back to',
      () async {
    final at = await _put(yesterdayId);
    final hrv = await repo.getDayHrv(todayLabel());
    expect(hrv['computed_at'], at,
        reason: 'the latest complete day is what was read, so its own time');
  });

  test('getChart: the newest computed time of the days it draws', () async {
    final a = await _put(yesterdayId, series: {'rmssd': 50.0});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final b = await _put(todayLabel(), series: {'rmssd': 55.0});
    expect(b, greaterThan(a));
    expect((await repo.getChart('hrv'))['computed_at'], b);
  });

  test('getChart: no series rows, no computed_at', () async {
    await _put(todayLabel());
    expect((await repo.getChart('hrv'))['computed_at'], isNull);
  });
}
