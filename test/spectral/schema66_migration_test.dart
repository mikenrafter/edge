// Schema 65 -> 66: `spectral_archive` (RED).
//
// ASSUMED (lib/data/db.dart):
//   * `LocalDb.schemaVersion == 66` (was 65 when this was written).
//   * spectral_archive(day_id TEXT NOT NULL, signal TEXT NOT NULL,
//       codec_version INTEGER NOT NULL, blob BLOB NOT NULL,
//       n_valid INTEGER NOT NULL, rms_err REAL NOT NULL, max_err REAL NOT NULL,
//       created_at INTEGER NOT NULL,
//       PRIMARY KEY (day_id, signal, codec_version))
//   * Created from the `if (oldV < 66)` rung AND `_repairOpenSchema`
//     (invariant 11: additive, idempotent, NO backfill, cheap under the iOS
//     watchdog). No kAlgoVersion bump: nothing derived reads it.
//
// Real sqflite_ffi, same idiom as gestures/moments/schema65_migration_test.
// NOTE for the green phase: gestures/moments/schema65_migration_test.dart pins
// `schemaVersion == 65` exactly and must become `>= 65`.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Future<void> _seedV65(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 65,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE journal ('
                'date TEXT PRIMARY KEY, tags_json TEXT NOT NULL DEFAULT \'[]\', '
                'note TEXT NOT NULL DEFAULT \'\', updated_at INTEGER NOT NULL)');
            await db.insert('journal', {
              'date': '2026-10-06',
              'tags_json': '[]',
              'note': 'kept',
              'updated_at': 1,
            });
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

Future<void> _expectShape(Database db) async {
  final cols = {
    for (final c in await db.rawQuery('PRAGMA table_info(spectral_archive)'))
      c['name'] as String: c,
  };
  expect(cols.keys.toSet(), {
    'day_id', 'signal', 'codec_version', 'blob', 'n_valid', 'rms_err',
    'max_err', 'created_at',
  });
  expect(cols['day_id']!['type'], 'TEXT');
  expect(cols['day_id']!['pk'], 1);
  expect(cols['signal']!['pk'], 2);
  expect(cols['codec_version']!['type'], 'INTEGER');
  expect(cols['codec_version']!['pk'], 3);
  expect(cols['blob']!['type'], 'BLOB');
  expect(cols['n_valid']!['type'], 'INTEGER');
  expect(cols['rms_err']!['type'], 'REAL');
  expect(cols['max_err']!['type'], 'REAL');
  for (final k in cols.keys) {
    expect(cols[k]!['notnull'], 1, reason: k);
  }
}

Map<String, Object?> _row({String day = '2026-10-06', int v = 1}) => {
      'day_id': day,
      'signal': 'hr',
      'codec_version': v,
      'blob': Uint8List.fromList([1, 2, 3]),
      'n_valid': 3,
      'rms_err': 0.1,
      'max_err': 0.2,
      'created_at': 1790000000,
    };

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

  test('schemaVersion is 66', () {
    expect(LocalDb.schemaVersion, 66);
  });

  test('upgrade from v65 reaches 66, adds the table EMPTY (no backfill), '
      'keeps existing rows', () async {
    const name = 'openstrap_schema66_up.db';
    created.add(name);
    await _seedV65(name);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    await _expectShape(db);
    expect(await db.query('spectral_archive'), isEmpty);
    expect((await db.query('journal')).single['note'], 'kept');
  });

  test('the rung is idempotent: re-running it over an existing table loses '
      'nothing', () async {
    const name = 'openstrap_schema66_rerun.db';
    created.add(name);
    await _seedV65(name);
    var db = await _open(name);
    await db.insert('spectral_archive', _row());
    await db.execute('PRAGMA user_version = 65');
    db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    await _expectShape(db);
    expect((await db.query('spectral_archive')).single['n_valid'], 3);
  });

  test('self-heal: a v66 database that lost the table gets it back on open',
      () async {
    const name = 'openstrap_schema66_heal.db';
    created.add(name);
    await _seedV65(name);
    var db = await _open(name);
    await db.execute('DROP TABLE spectral_archive');
    db = await _open(name);
    await _expectShape(db);
  });

  test('a fresh install has the table (onCreate path)', () async {
    const name = 'openstrap_schema66_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    await _expectShape(db);
  });

  test('one row per (day, signal, codec_version): a duplicate key is refused '
      'by the table, a new codec version is a sibling row', () async {
    const name = 'openstrap_schema66_pk.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    await db.insert('spectral_archive', _row());
    await expectLater(db.insert('spectral_archive', _row()), throwsA(anything));
    await db.insert('spectral_archive', _row(v: 2));
    expect(await db.query('spectral_archive'), hasLength(2));
  });
}
