// Shared fixtures for the design 02 step 2 / P2.1 tests (revision identity and
// the write seam). Real LocalDb over sqflite_ffi, one private file per test
// file, and no wall clock anywhere: tests that care about time freeze
// `LocalDb.nowMs` through [P21Clock].
//
// This file names only symbols that exist before the P2.1 green commit, apart
// from the stubs `dayResultMeta`, `dayPayload`, `storeGeneration` and
// `purgeDemoRows`. The schema it inspects (`store_rev`, `row_rev`, the
// triggers) is read through `sqlite_master`, so a missing object is an
// assertion failure, not a compile error.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';

/// The version every helper writes unless told otherwise.
const int p21Version = kAlgoVersion;

/// A `LocalDb.nowMs` that tests move by hand.
class P21Clock {
  P21Clock(this.ms);
  int ms;
  int call() => ms;
}

/// Restore the real `LocalDb.nowMs` after every test of the calling file.
void p21RestoreClockAfterEach() {
  final real = LocalDb.nowMs;
  tearDown(() => LocalDb.nowMs = real);
}

/// Point sqflite at the FFI factory. Idempotent.
void p21InitFfi() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

Future<String> p21Path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// An empty LocalDb at the current schema under [name].
Future<Database> p21Fresh(String name) async {
  p21InitFfi();
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(await p21Path(name));
  return LocalDb.instance;
}

/// Close LocalDb and reopen it on the same file.
Future<Database> p21Reopen() async {
  await LocalDb.close();
  return LocalDb.instance;
}

Future<void> p21Drop(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  await databaseFactory.deleteDatabase(await p21Path(name));
}

Future<int> p21UserVersion(Database db) async =>
    ((await db.rawQuery('PRAGMA user_version')).first.values.first as num)
        .toInt();

/// A payload whose [tag] says which write produced it.
String p21Payload(String tag, {String day = '2026-03-10'}) => jsonEncode({
  'date': day,
  'tag': tag,
  'scalars': {'rhr': 50.0, 'rmssd': 60.0, 'readiness': 70.0},
});

/// An import snapshot payload: `LocalDb` treats `imported: true` as one.
String p21ImportPayload(String tag) =>
    jsonEncode({'imported': true, 'tag': tag});

/// Insert a `day_result` row directly, bypassing `putDayResult`, so the seed
/// does not depend on the writer under test. Returns sqflite's insert result.
Future<int> p21RawDay(
  Database db,
  String day, {
  int version = p21Version,
  bool finalized = false,
  bool skipped = false,
  bool partial = false,
  String? payload,
  String window = '{}',
  int computedAt = 1000,
  double? rhr = 50.0,
  ConflictAlgorithm? conflict,
}) => db.insert(
  'day_result',
  {
    'day_id': day,
    'algo_version': version,
    'payload_json': payload ?? p21Payload('raw', day: day),
    'window_json': window,
    'computed_at': computedAt,
    'finalized': finalized ? 1 : 0,
    'skipped': skipped ? 1 : 0,
    'partial': partial ? 1 : 0,
    'rhr': rhr,
    'rmssd': 41.0,
    'readiness': 71.0,
  },
  conflictAlgorithm: conflict,
);

Future<void> p21RawBaseline(
  Database db,
  String key,
  String payload, {
  int updatedAt = 1000,
}) => db.insert('baselines', {
  'key': key,
  'payload_json': payload,
  'updated_at': updatedAt,
});

Future<bool> p21TableExists(Database db, String name) async =>
    (await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [name],
    )).isNotEmpty;

/// Fails (an assertion, not an exception) when the revision tables are absent.
Future<void> p21ExpectRevTables(Database db) async {
  expect(
    await p21TableExists(db, 'row_rev'),
    isTrue,
    reason: 'schema 71 adds the side table row_rev',
  );
  expect(
    await p21TableExists(db, 'store_rev'),
    isTrue,
    reason: 'schema 71 adds the sequence table store_rev',
  );
}

/// The revision of one source row; 0 when it has no `row_rev` row.
Future<int> p21Rev(
  Database db,
  String kind,
  String k1, [
  int k2 = 0,
]) async {
  await p21ExpectRevTables(db);
  final rows = await db.rawQuery(
    'SELECT COALESCE((SELECT rev FROM row_rev '
    'WHERE kind = ? AND k1 = ? AND k2 = ?), 0) AS r',
    [kind, k1, k2],
  );
  return (rows.first['r'] as num).toInt();
}

Future<int> p21DayRev(Database db, String day, [int version = p21Version]) =>
    p21Rev(db, 'day_result', day, version);

Future<int> p21BaseRev(Database db, String key) =>
    p21Rev(db, 'baselines', key);

/// Every `row_rev` row as `kind|k1|k2 -> rev`.
Future<Map<String, int>> p21AllRevs(Database db) async {
  await p21ExpectRevTables(db);
  return {
    for (final r in await db.rawQuery('SELECT kind, k1, k2, rev FROM row_rev'))
      '${r['kind']}|${r['k1']}|${r['k2']}': (r['rev'] as num).toInt(),
  };
}

/// `kind|k1|k2` for every row of `day_result` and `baselines`.
Future<Set<String>> p21SourceKeys(Database db) async => {
  for (final r in await db.query(
    'day_result',
    columns: ['day_id', 'algo_version'],
  ))
    'day_result|${r['day_id']}|${r['algo_version']}',
  for (final r in await db.query('baselines', columns: ['key']))
    'baselines|${r['key']}|0',
};

/// Every source row has exactly one revision row and every revision row has a
/// source row. For databases where every row was written after schema 71.
Future<void> p21ExpectRevsConsistent(Database db, {String? reason}) async {
  final revs = await p21AllRevs(db);
  expect(
    revs.keys.toSet(),
    await p21SourceKeys(db),
    reason: reason ?? 'row_rev must mirror day_result + baselines exactly',
  );
}

/// The triggers on `day_result` and `baselines`, as lowercase one-line SQL.
Future<Map<String, String>> p21Triggers(Database db) async => {
  for (final r in await db.rawQuery(
    "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'trigger' "
    "AND tbl_name IN ('day_result', 'baselines') ORDER BY name",
  ))
    '${r['tbl_name']}:${r['name']}': (r['sql'] as String)
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' '),
};

/// Every `sqlite_master` row for the revision objects, for before/after
/// comparison across reopens.
Future<List<String>> p21RevObjectSql(Database db) async => [
  for (final r in await db.rawQuery(
    'SELECT type, name, tbl_name, sql FROM sqlite_master '
    "WHERE name IN ('store_rev', 'row_rev') "
    "OR (type = 'trigger' AND tbl_name IN ('day_result', 'baselines')) "
    'ORDER BY type, name',
  ))
    '${r['type']}|${r['name']}|${r['tbl_name']}|${r['sql']}',
];

/// Drop every trigger on `day_result` and `baselines`.
Future<void> p21DropRevTriggers(Database db) async {
  for (final r in await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'trigger' "
    "AND tbl_name IN ('day_result', 'baselines')",
  )) {
    await db.execute('DROP TRIGGER IF EXISTS "${r['name']}"');
  }
}

/// Turn a current-schema database into exactly what schema 70 left behind: no
/// `store_rev`, no `row_rev`, no revision triggers, `user_version` 70. Holds
/// whatever rows the caller seeded first.
Future<void> p21DowngradeToV70(Database db) async {
  await p21DropRevTriggers(db);
  await db.execute('DROP TABLE IF EXISTS row_rev');
  await db.execute('DROP TABLE IF EXISTS store_rev');
  if (await p21TableExists(db, 'sqlite_sequence')) {
    await db.execute("DELETE FROM sqlite_sequence WHERE name = 'store_rev'");
  }
  await db.execute('PRAGMA user_version = 70');
}

/// A bundle old enough to be re-encoded by `reencodeLegacyDayResults`.
Map<String, dynamic> p21LegacyBundle(int t0, {int n = 30}) => {
  'scalars': {'rhr': 55.0, 'readiness': 71.0},
  'series': {
    'hr_curve': [
      for (var i = 0; i < n; i++) {'t': t0 + i * 60, 'v': 60 + (i % 17)},
    ],
    'hrv_day': [
      for (var i = 0; i < n; i++) {'t': t0 + i * 61 + (i % 5), 'v': 30.0 + i},
    ],
  },
};

/// A foreign export file standing in for another device's backup: the two
/// tables the revision work cares about, plus a `row_rev` full of revisions
/// that mean nothing on this device (all at or above [foreignRevBase]).
const int p21ForeignRevBase = 9000;

Future<String> p21MakeForeignExport(
  String name, {
  required List<({String day, int version, String tag, bool finalized})> days,
  List<({String key, String payload})> baselines = const [],
  bool withRowRev = true,
}) async {
  final path = await p21Path(name);
  await databaseFactory.deleteDatabase(path);
  final src = await databaseFactory.openDatabase(path);
  await src.execute('''
    CREATE TABLE day_result (
      day_id TEXT NOT NULL, algo_version INTEGER NOT NULL,
      payload_json TEXT NOT NULL, window_json TEXT NOT NULL DEFAULT '{}',
      computed_at INTEGER NOT NULL, finalized INTEGER NOT NULL DEFAULT 0,
      rhr REAL, rmssd REAL, readiness REAL,
      skipped INTEGER NOT NULL DEFAULT 0, partial INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (day_id, algo_version))
  ''');
  await src.execute('''
    CREATE TABLE baselines (
      key TEXT PRIMARY KEY, payload_json TEXT NOT NULL,
      updated_at INTEGER NOT NULL)
  ''');
  if (withRowRev) {
    await src.execute('''
      CREATE TABLE store_rev (id INTEGER PRIMARY KEY AUTOINCREMENT)
    ''');
    await src.execute('''
      CREATE TABLE row_rev (
        kind TEXT NOT NULL, k1 TEXT NOT NULL, k2 INTEGER NOT NULL DEFAULT 0,
        rev INTEGER NOT NULL, PRIMARY KEY (kind, k1, k2)) WITHOUT ROWID
    ''');
  }
  var rev = p21ForeignRevBase;
  for (final d in days) {
    await src.insert('day_result', {
      'day_id': d.day,
      'algo_version': d.version,
      'payload_json': p21Payload(d.tag, day: d.day),
      'window_json': '{}',
      'computed_at': 5000,
      'finalized': d.finalized ? 1 : 0,
    });
    if (withRowRev) {
      await src.insert('row_rev', {
        'kind': 'day_result',
        'k1': d.day,
        'k2': d.version,
        'rev': ++rev,
      });
    }
  }
  for (final b in baselines) {
    await src.insert('baselines', {
      'key': b.key,
      'payload_json': b.payload,
      'updated_at': 5000,
    });
    if (withRowRev) {
      await src.insert('row_rev', {
        'kind': 'baselines',
        'k1': b.key,
        'k2': 0,
        'rev': ++rev,
      });
    }
  }
  if (withRowRev) {
    // A revision row whose source row is not in the export at all.
    await src.insert('row_rev', {
      'kind': 'day_result',
      'k1': '2001-01-01',
      'k2': p21Version,
      'rev': ++rev,
    });
  }
  await src.close();
  return path;
}
