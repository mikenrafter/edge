// Persisted "declined days": a day whose derive declined to overwrite an older
// stored result (edge#305) is listed with the reason, the older version that
// was kept and when the decision was made. A day that was only retired
// (truncation / quiet / profile repass) carries no reason and is not listed.
//
// Assumed API: LocalRepository.declinedDays(), LocalDb.declinedDays(version),
// and putSettledDay(..., reason:, decidedAtMs:).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

const _profile = Profile(
  ageYears: 35,
  sex: 'm',
  weightKg: 75,
  heightCm: 178,
  restingHrManual: 55,
);

const _cursor = 'decoded_pruned_before';
const _day = '2026-07-05';

int _localSec(String day, int hour) {
  final d = DateTime.parse(day);
  return DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch ~/ 1000;
}

Future<void> _insertDay(String day, {int wakeMin = 400, int hour = 9}) async {
  final db = await LocalDb.instance;
  final start = _localSec(day, hour);
  final batch = db.batch();
  for (var i = 0; i < wakeMin * 60; i++) {
    final ts = start + i;
    batch.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': i < 45 * 60 ? 130 : 62 + (i % 3) - 1,
      'ax': 0.05 * ((i % 60) / 60.0),
      'ay': 0.05 * ((i % 30) / 30.0),
      'az': 0.98,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

/// A finalized row from an EARLIER version that already has night scalars: a
/// day-time-only re-derive declines to replace it (edge#305).
Future<void> _oldRow(String day) => LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion - 1,
      payloadJson: jsonEncode({
        'scalars': {'rhr': 52.0, 'rmssd': 61.0, 'readiness': 74.0},
      }),
      windowJson: '{"onset_ms": 1, "offset_ms": 2}',
      finalized: true,
      rhr: 52,
      rmssd: 61,
      readiness: 74,
      series: {'rhr': 52.0, 'rmssd': 61.0, 'readiness': 74.0},
    );

Future<void> _clear() async {
  final db = await LocalDb.instance;
  for (final t in const [
    'decoded_onehz',
    'decoded_rr',
    'day_result',
    'metric_series',
    'metric_series_version',
    'compute_freshness',
    'sleep_override',
  ]) {
    await db.delete(t);
  }
  await db.delete('sync_cursor', where: 'name = ?', whereArgs: [_cursor]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_declined_days_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  const slow = Timeout(Duration(minutes: 8));
  final repo = LocalRepositoryImpl(getProfileMap: () => const {});

  test('a: a heavy run that declines a day lists it with reason, kept '
      'version and time', () async {
    await _clear();
    await _insertDay(_day);
    await _oldRow(_day);
    final before = DateTime.now().millisecondsSinceEpoch;
    await DerivationEngine().run(_profile, heavy: true);

    final declined = await repo.declinedDays();
    expect(declined.keys, [_day]);
    expect(declined[_day]!.reason, 'night_substrate_pruned');
    expect(declined[_day]!.keptAlgoVersion, kAlgoVersion - 1);
    expect(declined[_day]!.decidedAtMs, greaterThanOrEqualTo(before));
  }, timeout: slow);

  test('b: a reasoned settled day is listed until the day is written',
      () async {
    await _clear();
    await _oldRow(_day);
    await LocalDb.putSettledDay(_day, kAlgoVersion,
        own: 'a', prev: null, reason: 'raw_pruned', decidedAtMs: 5);
    final declined = await repo.declinedDays();
    expect(declined.keys, [_day]);
    expect(declined[_day]!.reason, 'raw_pruned');
    expect(declined[_day]!.keptAlgoVersion, kAlgoVersion - 1);
    expect(declined[_day]!.decidedAtMs, 5);

    await LocalDb.putDayResult(
      dayId: _day,
      algoVersion: kAlgoVersion,
      payloadJson: '{}',
      windowJson: '{}',
      finalized: true,
    );
    expect(await repo.declinedDays(), isEmpty,
        reason: 'writing the day clears the marker');
  });

  test('c: a retire without a reason, or a reason at another version, is '
      'not listed', () async {
    await _clear();
    await _oldRow(_day);
    await LocalDb.putSettledDay(_day, kAlgoVersion, own: 'a', prev: null);
    expect(await repo.declinedDays(), isEmpty,
        reason: 'a truncation retire is not a decline');

    await LocalDb.putSettledDay(_day, kAlgoVersion - 1,
        own: 'a', prev: null, reason: 'raw_pruned', decidedAtMs: 5);
    expect(await repo.declinedDays(), isEmpty,
        reason: 'a version bump reopens the day');
  });

  test('d: a reasoned settled day with no older row is not listed',
      () async {
    await _clear();
    await LocalDb.putSettledDay(_day, kAlgoVersion,
        own: 'a', prev: null, reason: 'raw_pruned', decidedAtMs: 5);
    expect(await repo.declinedDays(), isEmpty,
        reason: 'nothing older was kept');
  });

  test('e: the record survives closing and reopening the database',
      () async {
    await _clear();
    await _oldRow(_day);
    await LocalDb.putSettledDay(_day, kAlgoVersion,
        own: 'a', prev: null, reason: 'coverage_fell', decidedAtMs: 7);
    await LocalDb.close();

    final declined = await repo.declinedDays();
    expect(declined.keys, [_day]);
    expect(declined[_day]!.reason, 'coverage_fell');
    expect(declined[_day]!.decidedAtMs, 7);
  });
}
