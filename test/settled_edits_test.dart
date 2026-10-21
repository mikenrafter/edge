// A day with a sleep edit must be able to settle. The settled record keeps the
// day's edit revision (design 06 1c: sleep_override and sleep_nap are
// day-scoped catalogued inputs), so only a CHANGED edit reopens the day. An
// old nap used to keep a declined day pending for ever: the validity check
// rejected any day with an edit row, and run() forced every edited day into
// each pass.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

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
    LocalDb.dbName = 'openstrap_settled_edits_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  const slow = Timeout(Duration(minutes: 8));

  Future<List<String>> heavyHooked() async {
    final e = DerivationEngine();
    final hooked = <String>[];
    e.debugDayHook = (d) async => hooked.add(d);
    await e.run(_profile, heavy: true);
    return hooked;
  }

  test('a day with a pre-existing nap settles, and the next pass leaves it',
      () async {
    await _clear();
    await (await LocalDb.instance).delete('sleep_nap');
    await _insertDay(_day);
    await _oldRow(_day);
    await LocalDb.putNapEdit(
      dayId: _day,
      startTs: _localSec(_day, 14),
      endTs: _localSec(_day, 15),
      source: 'manual',
    );
    expect(await heavyHooked(), contains(_day), reason: 'first pass declines');
    expect(await DerivationEngine().debugSettledDays(), contains(_day));
    expect(await heavyHooked(), isEmpty,
        reason: 'an unchanged old edit is not a reason to derive again');
  }, timeout: slow);

  test('editing the nap afterwards reopens the day', () async {
    expect(await DerivationEngine().debugSettledDays(), contains(_day),
        reason: 'precondition: settled by the previous test');
    await LocalDb.putNapEdit(
      dayId: _day,
      startTs: _localSec(_day, 16),
      endTs: _localSec(_day, 17),
      source: 'manual',
    );
    expect(await DerivationEngine().debugSettledDays(), isNot(contains(_day)));
    expect(await heavyHooked(), contains(_day));
  }, timeout: slow);
}
