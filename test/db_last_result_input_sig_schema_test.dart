// `last_result.input_sig`, schema 59 -> 60.
//
// ASSUMED (lib/data/db.dart):
//
//   * `LocalDb.schemaVersion == 60`.
//   * `last_result` gains ONE column, `input_sig TEXT` (nullable, no default):
//     the signature of the inputs the stored result was computed from. Rows
//     written before the column existed read NULL, and a NULL signature is
//     never "fresh" (see calc_artifact_cache_test.dart).
//   * Added through the one sanctioned helper (`_addColumnIfMissing`) from
//     BOTH the new `if (oldV < 60)` rung AND `_repairOpenSchema` (invariant
//     11: additive, idempotent, cheap, same-version merged builds self-heal).
//     `_createLastResult` itself is modernised in place, so a fresh install gets
//     the column from `CREATE TABLE`.
//   * Nothing else changes: the existing columns, their order and constraints,
//     and every existing row survive.
//
// Real sqflite_ffi, same idiom as test/db_last_result_schema_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// A database exactly as schema 59 left it: `last_result` WITHOUT `input_sig`,
/// holding one row.
Future<void> _seedV59(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 59,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE last_result ('
                'key TEXT PRIMARY KEY, computed_at INTEGER NOT NULL, '
                'payload_json TEXT NOT NULL)');
            await db.insert('last_result', {
              'key': 'beats|2026-10-01',
              'computed_at': 1234,
              'payload_json': '{"nn":[]}',
            });
          }));
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

Future<Map<String, Map<String, Object?>>> _cols(Database db) async => {
      for (final c in await db.rawQuery('PRAGMA table_info(last_result)'))
        c['name'] as String: c,
    };

void _expectCurrentShape(Map<String, Map<String, Object?>> cols) {
  expect(cols.keys.toSet(), {'key', 'computed_at', 'payload_json', 'input_sig'});
  expect(cols['input_sig']!['type'], 'TEXT');
  expect(cols['input_sig']!['notnull'], 0, reason: 'nullable: old rows have none');
  expect(cols['input_sig']!['dflt_value'], isNull, reason: 'no default');
  // The existing columns are untouched.
  expect(cols['key']!['pk'], 1);
  expect(cols['computed_at']!['notnull'], 1);
  expect(cols['payload_json']!['notnull'], 1);
}

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

  test('upgrade from v59 reaches 60, adds input_sig, keeps the old row with a '
      'NULL signature', () async {
    const name = 'openstrap_input_sig_schema_59.db';
    created.add(name);
    await _seedV59(name);
    final db = await _openThroughLocalDb(name);
    expect(await _userVersion(db), 60);
    _expectCurrentShape(await _cols(db));

    final rows = await db.query('last_result');
    expect(rows, hasLength(1));
    expect(rows.single['key'], 'beats|2026-10-01');
    expect(rows.single['computed_at'], 1234);
    expect(rows.single['payload_json'], '{"nn":[]}');
    expect(rows.single['input_sig'], isNull);
  });

  test('the rung is idempotent: running 59 -> 60 a second time over an '
      'already-60 shape neither throws nor loses the column or the rows',
      () async {
    const name = 'openstrap_input_sig_schema_rerun.db';
    created.add(name);
    await _seedV59(name);
    var db = await _openThroughLocalDb(name);
    await db.update('last_result', {'input_sig': '100|a'},
        where: 'key = ?', whereArgs: ['beats|2026-10-01']);

    // Stamp it back to 59 WITHOUT undoing anything: the rung runs again over a
    // table that already has the column ("duplicate column name" would roll the
    // whole ladder back and quarantine the database).
    await db.execute('PRAGMA user_version = 59');
    db = await _openThroughLocalDb(name);
    expect(await _userVersion(db), 60);
    _expectCurrentShape(await _cols(db));
    final rows = await db.query('last_result');
    expect(rows.single['input_sig'], '100|a', reason: 'data survived the rerun');
  });

  test('self-heal: a v60 database whose last_result lost the column gets it '
      'back on open', () async {
    const name = 'openstrap_input_sig_schema_heal.db';
    created.add(name);
    await _seedV59(name);
    var db = await _openThroughLocalDb(name);
    await db.execute('DROP TABLE last_result');
    await db.execute('CREATE TABLE last_result ('
        'key TEXT PRIMARY KEY, computed_at INTEGER NOT NULL, '
        'payload_json TEXT NOT NULL)');
    await db.insert('last_result',
        {'key': 'k', 'computed_at': 1, 'payload_json': '{}'});

    db = await _openThroughLocalDb(name); // same version: onOpen repair only
    expect(await _userVersion(db), 60);
    _expectCurrentShape(await _cols(db));
    expect((await db.query('last_result')).single['key'], 'k');
  });

  test('a fresh install has the column too (onCreate path)', () async {
    const name = 'openstrap_input_sig_schema_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _openThroughLocalDb(name);
    expect(await _userVersion(db), 60);
    _expectCurrentShape(await _cols(db));
    expect(await db.query('last_result'), isEmpty);
  });

  test('regression guard: an insert that omits input_sig is '
      'still legal (old writers)', () async {
    const name = 'openstrap_input_sig_schema_legacy_write.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _openThroughLocalDb(name);
    await db.insert('last_result',
        {'key': 'k', 'computed_at': 1, 'payload_json': '{}'});
    expect((await db.query('last_result')).single['input_sig'], isNull);
  });
}
