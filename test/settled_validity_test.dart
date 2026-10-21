// What keeps a settled day settled (engine/settled.dart).
//
//  F. A re-pass that DECLINES a day settles it on the raw fingerprint taken
//     BEFORE the day was prepared. Raw that arrives between preparation and
//     settling must leave the day reopened, not settled on the new rows
//     (which it never read; the prune would then drop recoverable raw).
//  G. Any committed write for a day clears its settled marker (a partial or
//     unfinalized row must not stay excluded from later passes), and a user
//     sleep window or nap edit invalidates it: those are inputs of the
//     decline that the raw fingerprint does not see.
//
// Assumed API: DerivationEngine.debugQuietLevelRepass(profile, dataNowSec) and
// DerivationEngine.debugSettledDays(), both @visibleForTesting.

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
    LocalDb.dbName = 'openstrap_settled_validity_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  const slow = Timeout(Duration(minutes: 8));

  test('F: raw that lands before a declined re-pass settles does not get the '
      'day settled on rows it never read', () async {
    await _clear();
    await _insertDay(_day);
    await _oldRow(_day);
    // Three earlier quiet levels, so the day is owed a re-score that can run.
    for (var d = 20; d <= 22; d++) {
      await LocalDb.putMetricSeriesValue('2026-06-$d', 'quiet_hrr', 0.20);
    }
    await LocalDb.putComputeFreshness(
        '${DerivationEngine.kQuietRepassKeyPrefix}$_day', '{}');
    DerivationEngine.debugQuietRepassHook = (day) async {
      if (day == _day) await _insertDay(_day, wakeMin: 30, hour: 20);
    };
    addTearDown(() => DerivationEngine.debugQuietRepassHook = null);

    final e = DerivationEngine();
    await e.debugQuietLevelRepass(_profile, _localSec(_day, 23));

    expect(
        (await LocalDb.settledFingerprints(kAlgoVersion)).containsKey(_day),
        isTrue,
        reason: 'precondition: the repass declined and settled the day');
    expect(await e.debugSettledDays(), isNot(contains(_day)),
        reason: 'the evening rows arrived after the fingerprint was taken');
  }, timeout: slow);

  test('G: a committed write clears the settled marker', () async {
    await _clear();
    await LocalDb.putSettledDay(_day, kAlgoVersion, own: 'a', prev: null);
    expect((await LocalDb.settledFingerprints(kAlgoVersion)).keys, [_day]);

    await LocalDb.putDayResult(
      dayId: _day,
      algoVersion: kAlgoVersion,
      payloadJson: '{}',
      windowJson: '{}',
      finalized: false,
      partial: true,
    );
    expect(await LocalDb.settledFingerprints(kAlgoVersion), isEmpty,
        reason: 'a partial, unfinalized row must not stay excluded');
  });

  test('G: a sleep override on a settled day reopens it', () async {
    await _clear();
    await _insertDay(_day);
    await _oldRow(_day);
    final e = DerivationEngine();
    await e.run(_profile, heavy: true);
    expect(await e.debugSettledDays(), contains(_day),
        reason: 'precondition: declined and settled');

    await LocalDb.putSleepOverride(
      dayId: _day,
      onsetTs: _localSec(_day, 1),
      offsetTs: _localSec(_day, 7),
      source: 'manual',
    );
    expect(await e.debugSettledDays(), isNot(contains(_day)),
        reason: 'the user window is an input the raw fingerprint cannot see');
  }, timeout: slow);
}
