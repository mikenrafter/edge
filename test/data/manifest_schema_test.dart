// Design 06 phase 1e: `day_manifest`, schema 78 -> 79.
//
// Additive, idempotent, no backfill, healed by `_repairOpenSchema` on every
// open (AGENTS 3.11). Derive bookkeeping: not restored from a backup, wiped by
// "Delete everything", removed by `deleteDays` for the deleted days, and
// sliced (recent days) in an issue report like group_row.
//
// The two existing net guards (wake_ledger_tables_restore_test and
// issue_report_test 'every table in the schema is classified') fail as soon as
// the table exists without these entries; the tests here name them.
//
// Real sqflite_ffi, same idiom as group_row_schema_test.dart. Needs no new
// symbol beyond schemaVersion 79 and the table.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/data/restore_classification.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// A database as schema 78 left it: one unrelated row that must survive.
Future<void> _seedV78(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 78,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE last_result ('
                'key TEXT PRIMARY KEY, computed_at INTEGER NOT NULL, '
                'payload_json TEXT NOT NULL, input_sig TEXT)');
            await db.insert('last_result',
                {'key': 'k', 'computed_at': 7, 'payload_json': '{}'});
          }));
  await db.close();
}

Future<Database> _open(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  expect(LocalDb.lastRebuild, isNull,
      reason: 'the upgrade bricked and fell back to quarantine-and-rebuild: '
          '${LocalDb.lastRebuild?.cause}');
  return db;
}

Future<int> _userVersion(Database db) async =>
    ((await db.rawQuery('PRAGMA user_version')).first.values.first as num)
        .toInt();

Future<Map<String, Map<String, Object?>>> _cols(Database db) async => {
      for (final c in await db.rawQuery('PRAGMA table_info(day_manifest)'))
        c['name'] as String: c,
    };

void _expectShape(Map<String, Map<String, Object?>> cols) {
  expect(cols.keys.toSet(), {
    'day_id',
    'manifest_seq',
    'compat',
    'registry_version',
    'selected_json',
    'key_order_json',
    'bundle_sha',
    'series_sha',
    'freshness_json',
    'published_at',
  });
  expect(cols['day_id']!['pk'], 1);
  expect(cols['manifest_seq']!['pk'], 2);
  for (final k in ['manifest_seq', 'compat', 'registry_version', 'published_at']) {
    expect(cols[k]!['type'], 'INTEGER', reason: k);
  }
  for (final k in ['day_id', 'selected_json', 'key_order_json', 'bundle_sha',
      'series_sha', 'freshness_json']) {
    expect(cols[k]!['type'], 'TEXT', reason: k);
  }
}

Future<void> _insert(Database db, {String day = '2026-03-10', int seq = 1}) =>
    db.insert('day_manifest', {
      'day_id': day,
      'manifest_seq': seq,
      'compat': 1,
      'registry_version': 1,
      'selected_json': '{}',
      'key_order_json': '[]',
      'bundle_sha': 'x',
      'series_sha': 'y',
      'freshness_json': '{}',
      'published_at': 9,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _path(n));
    }
  });

  test('schemaVersion is 79', () => expect(LocalDb.schemaVersion, 79));

  test('upgrade from v78 creates the table, empty, and keeps other rows',
      () async {
    const name = 'openstrap_day_manifest_78.db';
    created.add(name);
    await _seedV78(name);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    expect(await db.query('day_manifest'), isEmpty,
        reason: 'no backfill: a day with no manifest is simply unpublished');
    expect((await db.query('last_result')).single['computed_at'], 7);
  });

  test('the rung is idempotent over an already-79 shape', () async {
    const name = 'openstrap_day_manifest_rerun.db';
    created.add(name);
    await _seedV78(name);
    var db = await _open(name);
    await _insert(db);
    await db.execute('PRAGMA user_version = 78');
    db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    expect(await db.query('day_manifest'), hasLength(1));
  });

  test('a v77 database climbs through both rungs', () async {
    const name = 'openstrap_day_manifest_from77.db';
    created.add(name);
    await _seedV78(name);
    final raw = await databaseFactory.openDatabase(await _path(name));
    await raw.execute('PRAGMA user_version = 77');
    await raw.close();
    final db = await _open(name);
    _expectShape(await _cols(db));
    expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name = 'group_row'"),
        isNotEmpty);
  });

  test('self-heal: a current-version database without the table gets it',
      () async {
    const name = 'openstrap_day_manifest_heal.db';
    created.add(name);
    await _seedV78(name);
    var db = await _open(name);
    await db.execute('DROP TABLE day_manifest');
    db = await _open(name);
    _expectShape(await _cols(db));
  });

  test('a fresh install has it too', () async {
    const name = 'openstrap_day_manifest_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    _expectShape(await _cols(db));
  });

  test('(day, seq) is the key: a later seq coexists, the same key is refused',
      () async {
    const name = 'openstrap_day_manifest_key.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    await _insert(db);
    await _insert(db, seq: 2);
    await _insert(db, day: '2026-03-11');
    expect(await db.query('day_manifest'), hasLength(3));
    await expectLater(_insert(db), throwsA(anything));
  });

  group('classification', () {
    test('day_manifest is not restored, with a reason: derive bookkeeping of '
        'this install', () {
      expect(kTablesNotRestored.keys, contains('day_manifest'));
      expect(kTablesNotRestored['day_manifest']!.trim(), isNotEmpty);
      expect(LocalDb.restoreTablesForTest, isNot(contains('day_manifest')));
    });

    test('day_manifest is in kSliceTables, recent days only', () {
      expect(kSliceTables.keys, contains('day_manifest'));
      final (keep, col, why) = kSliceTables['day_manifest']!;
      expect(keep, SliceKeep.recentDay);
      expect(col, 'day_id');
      expect(why.trim(), isNotEmpty);
    });
  });

  test('"Delete everything" empties day_manifest, keeps the schema', () async {
    const name = 'openstrap_day_manifest_wipe.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    await _insert(db);
    await LocalDb.wipeAll();
    expect(await db.query('day_manifest'), isEmpty);
    expect(await LocalDb.tableNames(), contains('day_manifest'));
  });

  test('deleteDays removes the deleted days\' manifests only', () async {
    const name = 'openstrap_day_manifest_delete.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    await _insert(db);
    await _insert(db, seq: 2);
    await _insert(db, day: '2026-03-11');
    await LocalDb.deleteDays({'2026-03-10'});
    final left = await db.query('day_manifest');
    expect(left, hasLength(1));
    expect(left.single['day_id'], '2026-03-11');
  });
}
