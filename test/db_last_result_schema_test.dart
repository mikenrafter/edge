// 8AI G1 (red first): the `last_result` table, schema 58 -> 59.
//
// ASSUMED (lib/data/db.dart):
//   LocalDb.schemaVersion == 59
//   CREATE TABLE IF NOT EXISTS last_result(
//     key          TEXT PRIMARY KEY,
//     computed_at  INTEGER NOT NULL,     -- epoch ms: when the stored result
//                                        -- was COMPUTED, never the write time
//     payload_json TEXT NOT NULL)        -- the repository-level JSON map
//   * created by the `if (oldV < 59)` rung AND by `_repairOpenSchema`
//     (invariant 11: additive, idempotent, cheap; a same-version merged build
//     self-heals);
//   * no existing table is touched.
//
// 8AG-perf P3 moves this to schema 60: `last_result` gains the nullable
// `input_sig` column (see test/db_last_result_input_sig_schema_test.dart); the other columns and
// the ladder below are unchanged, so this file now expects 60 and the extra
// column.
//
// Real sqflite_ffi, same idiom as test/db_alarm_schedule_migration_test.dart.
// Failure mode today: schemaVersion is 58 and `last_result` does not exist
// ("no such table" / a column list that is empty).

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Future<void> _seedEmptyV58(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(version: 58, onCreate: (db, _) async {}));
  await db.close();
}

Future<Database> _openThroughLocalDb(String name) async {
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

  test('schemaVersion is 60', () {
    expect(LocalDb.schemaVersion, 60);
  });

  test('upgrade from v58 reaches 60 and creates last_result with the agreed '
      'columns', () async {
    const name = 'openstrap_fix8ai_g1_schema_58.db';
    created.add(name);
    await _seedEmptyV58(name);
    final db = await _openThroughLocalDb(name);
    expect(await _userVersion(db), 60);

    final cols = {
      for (final c in await db.rawQuery('PRAGMA table_info(last_result)'))
        c['name'] as String: c,
    };
    expect(cols.keys.toSet(),
        {'key', 'computed_at', 'payload_json', 'input_sig'});
    expect(cols['key']!['type'], 'TEXT');
    expect(cols['key']!['pk'], 1, reason: 'key is the primary key');
    expect(cols['computed_at']!['type'], 'INTEGER');
    expect(cols['computed_at']!['notnull'], 1);
    expect(cols['payload_json']!['type'], 'TEXT');
    expect(cols['payload_json']!['notnull'], 1);
  });

  test('a row survives a reopen (the rung and onOpen are idempotent)',
      () async {
    const name = 'openstrap_fix8ai_g1_schema_reopen.db';
    created.add(name);
    await _seedEmptyV58(name);
    var db = await _openThroughLocalDb(name);
    await db.insert('last_result',
        {'key': 'beats|2026-10-01', 'computed_at': 1000, 'payload_json': '{}'});
    db = await _openThroughLocalDb(name); // closes and opens again
    final rows = await db.query('last_result');
    expect(rows, hasLength(1));
    expect(rows.single['key'], 'beats|2026-10-01');
    expect(rows.single['computed_at'], 1000);
  });

  test('self-heal: a current-version database missing the table gets it back on open',
      () async {
    const name = 'openstrap_fix8ai_g1_schema_heal.db';
    created.add(name);
    await _seedEmptyV58(name);
    var db = await _openThroughLocalDb(name);
    await db.execute('DROP TABLE last_result');
    db = await _openThroughLocalDb(name);
    expect(await _userVersion(db), 60);
    expect(await db.query('last_result'), isEmpty,
        reason: '_repairOpenSchema re-runs the creator on every open');
  });

  test('a fresh install has the table too (onCreate path)', () async {
    const name = 'openstrap_fix8ai_g1_schema_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _openThroughLocalDb(name);
    expect(await _userVersion(db), 60);
    expect(await db.query('last_result'), isEmpty);
  });
}
