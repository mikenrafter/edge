// Design 06 phase 1d: `group_row`, schema 77 -> 78.
//
// Additive, idempotent, no backfill (an empty table means "no group rows yet":
// nothing reads it in 1d), healed by `_repairOpenSchema` on every open
// (AGENTS 3.11). It is a derive cache: not restored from a backup, wiped by
// "Delete everything", and sliced like `day_checkpoint` in an issue report.
//
// The classification tests here fail on the maps today; the two existing
// guards (test/backup/wake_ledger_tables_restore_test.dart and
// test/issue_report_test.dart 'every table in the schema is classified') fail
// as soon as the table exists without those entries, which is the point: they
// are the net, and these tests name the expected entries.
//
// Real sqflite_ffi, same idiom as test/db_day_checkpoint_schema_test.dart.
// This file needs no new symbol.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/data/restore_classification.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// A database as schema 77 left it: one unrelated row that must survive.
Future<void> _seedV77(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 77,
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
      for (final c in await db.rawQuery('PRAGMA table_info(group_row)'))
        c['name'] as String: c,
    };

void _expectShape(Map<String, Map<String, Object?>> cols) {
  expect(cols.keys.toSet(), {
    'day_id',
    'group_id',
    'revision',
    'counter',
    'ancestors_json',
    'input_stamp_json',
    'payload',
    'computed_at',
    'finalized',
    'partial',
    'published',
  });
  expect(cols['day_id']!['pk'], 1);
  expect(cols['group_id']!['pk'], 2);
  expect(cols['revision']!['pk'], 3);
  expect(cols['payload']!['type'], 'BLOB');
  for (final k in ['revision', 'counter', 'computed_at', 'finalized',
      'partial', 'published']) {
    expect(cols[k]!['type'], 'INTEGER', reason: k);
  }
  expect(cols['published']!['dflt_value'], '0');
}

Future<void> _insert(Database db, {int revision = 1}) => db.insert('group_row', {
      'day_id': '2026-03-10',
      'group_id': 'sleep.stage',
      'revision': revision,
      'counter': 1,
      'ancestors_json': '{}',
      'input_stamp_json': '{}',
      'payload': Uint8List.fromList([1, 2, 3]),
      'computed_at': 9,
      'finalized': 1,
      'partial': 0,
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

  test('schemaVersion is 78 (77 is taken by input_revision)', () {
    expect(LocalDb.schemaVersion, 78);
  });

  test('upgrade from v77 creates the table, empty, and keeps other rows',
      () async {
    const name = 'openstrap_group_row_77.db';
    created.add(name);
    await _seedV77(name);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    expect(await db.query('group_row'), isEmpty,
        reason: 'no backfill: nothing to compute under the iOS watchdog');
    expect((await db.query('last_result')).single['computed_at'], 7);
  });

  test('the rung is idempotent over an already-78 shape', () async {
    const name = 'openstrap_group_row_rerun.db';
    created.add(name);
    await _seedV77(name);
    var db = await _open(name);
    await _insert(db);
    await db.execute('PRAGMA user_version = 77');
    db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    expect(await db.query('group_row'), hasLength(1),
        reason: 'the rerun neither threw nor emptied the table');
  });

  test('self-heal: a current-version database without the table gets it',
      () async {
    const name = 'openstrap_group_row_heal.db';
    created.add(name);
    await _seedV77(name);
    var db = await _open(name);
    await db.execute('DROP TABLE group_row');
    db = await _open(name);
    _expectShape(await _cols(db));
  });

  test('a fresh install has it too', () async {
    const name = 'openstrap_group_row_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    _expectShape(await _cols(db));
  });

  test('(day, group, revision) is the key: a sibling revision coexists, '
      'the same key is refused', () async {
    const name = 'openstrap_group_row_key.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    await _insert(db);
    await _insert(db, revision: 2);
    expect(await db.query('group_row'), hasLength(2));
    await expectLater(_insert(db), throwsA(anything));
  });

  group('classification', () {
    test('group_row is not restored, with a reason: a derive cache keyed to '
        "this install's counters", () {
      expect(kTablesNotRestored.keys, contains('group_row'));
      expect(kTablesNotRestored['group_row']!.trim(), isNotEmpty);
      expect(LocalDb.restoreTablesForTest, isNot(contains('group_row')));
    });

    test('group_row is in kSliceTables, recent days only (payload blobs)',
        () {
      expect(kSliceTables.keys, contains('group_row'));
      final (keep, col, why) = kSliceTables['group_row']!;
      expect(keep, SliceKeep.recentDay);
      expect(col, 'day_id');
      expect(why.trim(), isNotEmpty);
    });
  });

  test('"Delete everything" empties group_row', () async {
    const name = 'openstrap_group_row_wipe.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    await _insert(db);
    expect(await db.query('group_row'), hasLength(1));
    await LocalDb.wipeAll();
    expect(await db.query('group_row'), isEmpty);
    expect(await LocalDb.tableNames(), contains('group_row'),
        reason: 'the schema stays, only rows go');
  });
}
