// The owner's database, as our fork built it, opened by the integrated build.
//
// The fork shipped schemaVersion 71 and kAlgoVersion 104 (merge log D13, D16).
// The integrated build runs upstream's four rungs as 72-75 and derives at our
// single bump atop upstream 113, i.e. 114 (D27 revised). Opening the fork's
// database must need no manual step:
//   * the ladder runs 71 -> current without error;
//   * a backfill derive pass writes (day, 114) rows for every day with raw data;
//   * a day with no raw left keeps serving its (day, 104) row, frozen, never
//     deleted (invariant 4: an old version's row is only superseded by a new
//     sibling row);
//   * the raw prune never drops a day not yet derived at the current version
//     (invariant 9).
//
// test/fixtures/fork_v71_schema.json is the fork's own DDL: every table,
// index, view and trigger `sqlite_master` held after the fork's `LocalDb`
// (integrate/agg-cls @ 2b8c957b, the fork side of the merge) opened a fresh
// database at v71. The rows below are inserted into that schema directly, the
// way a fork build's writes left them.
//
// RED until the 114 bump: "a derive pass writes (day, 114) rows". The other
// tests guard behaviour that already holds.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _dbName = 'fork_db_upgrade_test.db';

int _sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

/// Days with a stored fork result and NO raw left (pruned under the fork).
const String _noRawFinal = '2025-08-20';
const String _noRawProv = '2025-08-21';

/// Days whose nights are still in `decoded_onehz`.
const String _rawFinal = '2025-09-04';
const String _rawProv = '2025-09-05';

final int _firstRawSec = _sec(2025, 9, 3, 22, 0);

String _forkPayload(String day, double tst) => jsonEncode({
      'date': day,
      'scalars': {'tst_min': tst, 'rhr': 55.0, 'rmssd': 42.0},
      'sleep': <String, dynamic>{},
    });

Future<void> _buildForkDb(String path) async {
  final fixture = jsonDecode(
          File('test/fixtures/fork_v71_schema.json').readAsStringSync())
      as Map<String, dynamic>;
  expect(fixture['user_version'], 71, reason: 'fixture is the fork at v71');
  final db = await databaseFactory.openDatabase(path);
  for (final o in (fixture['objects'] as List).cast<Map<String, dynamic>>()) {
    await db.execute(o['sql'] as String);
  }

  final now = DateTime(2025, 9, 5, 9).millisecondsSinceEpoch;
  Future<void> dayRow(String day, {required bool finalized, double tst = 420}) =>
      db.insert('day_result', {
        'day_id': day,
        'algo_version': 104,
        'payload_json': _forkPayload(day, tst),
        'window_json': '{}',
        'computed_at': now,
        'finalized': finalized ? 1 : 0,
        'rhr': 55.0,
        'rmssd': 42.0,
        'readiness': 70.0,
      });
  await dayRow(_noRawFinal, finalized: true, tst: 431);
  await dayRow(_noRawProv, finalized: false, tst: 377);
  await dayRow(_rawFinal, finalized: true);
  await dayRow(_rawProv, finalized: false);

  // Two still nights at a sleeping heart rate, 1 Hz, as a WHOOP drain left
  // them under the fork (device_id '' is the legacy primary band).
  final b = db.batch();
  var c = 0;
  void run(int from, int to) {
    for (var ts = from; ts < to; ts++) {
      b.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': c++,
        'hr': 52 + (ts % 7),
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      });
    }
  }

  run(_firstRawSec, _sec(2025, 9, 4, 8, 0));
  run(_sec(2025, 9, 4, 22, 0), _sec(2025, 9, 5, 8, 0));
  await b.commit(noResult: true);
  await db.setVersion(71);
  await db.close();
}

Future<List<int>> _versions(Database db, String day) async => [
      for (final r in await db.query('day_result',
          columns: ['algo_version'],
          where: 'day_id = ?',
          whereArgs: [day],
          orderBy: 'algo_version'))
        r['algo_version'] as int,
    ];

Future<int> _count(Database db, String table) async =>
    (await db.rawQuery('SELECT COUNT(*) AS n FROM $table')).first['n'] as int;

void main() {
  late Database db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = _dbName;
    final path = p.join(await databaseFactory.getDatabasesPath(), _dbName);
    await databaseFactory.deleteDatabase(path);
    await _buildForkDb(path);
    db = await LocalDb.instance;
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), _dbName));
  });

  test('the ladder takes the fork database from 71 to the current version',
      () async {
    final v = (await db.rawQuery('PRAGMA user_version')).first.values.first;
    expect(v, LocalDb.schemaVersion);
    // Upstream's rungs (D13) ran: 73 device.wearing_set_ts, 75 the band's
    // own hypnogram table.
    final cols = [
      for (final r in await db.rawQuery('PRAGMA table_info(device)'))
        r['name'] as String
    ];
    expect(cols, contains('wearing_set_ts'));
    final t = await db.query('sqlite_master',
        where: "type = 'table' AND name = 'vendor_sleep_epoch'");
    expect(t, hasLength(1));
    // Nothing the fork stored was dropped on the way.
    expect(
        await _count(db, 'day_result'),
        4);
    expect(
        await _count(db, 'decoded_onehz'),
        greaterThan(0));
  });

  test('before any derive, the prune holds every raw day (invariant 9)',
      () async {
    // No raw day is derived at the current version yet; their fork rows (one
    // finalized, one provisional) are at 104 and do not count.
    final finalized = (await LocalDb.finalizedDayIds(kAlgoVersion))
        .difference(await LocalDb.partialDayIds(kAlgoVersion));
    expect(finalized.intersection({_rawFinal, _rawProv}), isEmpty);
    // A data edge far enough on that the retention window alone would cut
    // through both nights.
    final cutoff = DerivationEngine.rawPruneCutoffSec(
      dataNowSec: _sec(2025, 9, 12, 12, 0),
      rawDayIds: const ['2025-09-03', _rawFinal, _rawProv],
      finalizedDayIds: finalized,
    );
    expect(cutoff == null || cutoff <= _firstRawSec, isTrue,
        reason: 'cutoff $cutoff would drop raw from $_firstRawSec on');
  });

  test('a backfill derive pass writes (day, kAlgoVersion) for each day with raw, '
      'and every fork row stays', () async {
    final rawBefore = await _count(db, 'decoded_onehz');
    // The backfill pass (heavy): every pending day in one pass. A light pass
    // takes one pending day at a time, newest first, by design.
    await DerivationEngine().run(const Profile(), heavy: true);

    for (final day in [_rawFinal, _rawProv]) {
      final vs = await _versions(db, day);
      expect(vs, contains(104), reason: '$day: the fork row is a sibling, kept');
      expect(vs, contains(kAlgoVersion),
          reason: '$day: derived at the current version, got $vs');
      expect(vs, contains(kAlgoVersion), reason: '$day: derived at our bump, got $vs');
      expect((await LocalDb.dayResult(day))!['algo_version'], kAlgoVersion,
          reason: '$day serves the current version');
    }

    // Raw days were derived before anything could be pruned: the nights are
    // all still there (the data edge is within retention of them).
    expect(
        await _count(db, 'decoded_onehz'),
        rawBefore);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a day with no raw keeps serving its fork row, frozen', () async {
    for (final (day, finalized, tst) in [
      (_noRawFinal, 1, 431.0),
      (_noRawProv, 0, 377.0),
    ]) {
      expect(await _versions(db, day), [104], reason: '$day: not deleted');
      final row = (await LocalDb.dayResult(day))!;
      expect(row['algo_version'], 104);
      expect(row['finalized'], finalized);
      final payload = jsonDecode(row['payload_json'] as String) as Map;
      expect((payload['scalars'] as Map)['tst_min'], tst,
          reason: '$day: payload untouched');
    }
  });
}
