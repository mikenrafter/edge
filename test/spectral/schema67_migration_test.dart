// Schema 66 -> 67 (RED): spectral_archive gains device_id and part in its key,
// and spectral_archive_status is added.
//
// 66 was an experiment-branch rung whose table merged devices and could not
// hold more than one blob per signal-day. The rung rebuilds it additively and
// idempotently: existing rows keep their bytes, land on the primary device
// ('') as part 0. No backfill, no kAlgoVersion bump (nothing derived reads it).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Future<void> _seedV66(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 66,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE spectral_archive ('
                'day_id TEXT NOT NULL, signal TEXT NOT NULL, '
                'codec_version INTEGER NOT NULL, blob BLOB NOT NULL, '
                'n_valid INTEGER NOT NULL, rms_err REAL NOT NULL, '
                'max_err REAL NOT NULL, created_at INTEGER NOT NULL, '
                'PRIMARY KEY (day_id, signal, codec_version))');
            await db.insert('spectral_archive', {
              'day_id': '2026-10-03',
              'signal': 'hr',
              'codec_version': 1,
              'blob': Uint8List.fromList([4, 5, 6]),
              'n_valid': 3,
              'rms_err': 0.5,
              'max_err': 1.5,
              'created_at': 77,
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
      reason: 'the upgrade bricked: ${LocalDb.lastRebuild?.cause}');
  return db;
}

Future<void> _expectShape(Database db) async {
  final cols = {
    for (final c in await db.rawQuery('PRAGMA table_info(spectral_archive)'))
      c['name'] as String: c,
  };
  expect(cols.keys.toSet(), containsAll({
    'day_id', 'device_id', 'signal', 'codec_version', 'part', 'blob',
    'n_valid', 'rms_err', 'max_err', 'created_at',
  }));
  expect(cols['day_id']!['pk'], 1);
  expect(cols['device_id']!['pk'], 2);
  expect(cols['signal']!['pk'], 3);
  expect(cols['codec_version']!['pk'], 4);
  expect(cols['part']!['pk'], 5);
  expect(cols['device_id']!['dflt_value'], "''");
  expect(cols['part']!['dflt_value'], '0');
  final st = {
    for (final c
        in await db.rawQuery('PRAGMA table_info(spectral_archive_status)'))
      c['name'] as String: c,
  };
  expect(st.keys.toSet(),
      {'day_id', 'device_id', 'outcome', 'reason', 'updated_at'});
  expect(st['day_id']!['pk'], 1);
  expect(st['device_id']!['pk'], 2);
  expect(st['outcome']!['notnull'], 1);
  expect(st['reason']!['notnull'], 0);
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

  test('schemaVersion is at least 67',
      () => expect(LocalDb.schemaVersion, greaterThanOrEqualTo(67)));

  test('v66 -> 67 rebuilds the table: rows keep their bytes on the primary '
      'device as part 0', () async {
    const name = 'openstrap_schema67_up.db';
    created.add(name);
    await _seedV66(name);
    final db = await _open(name);
    await _expectShape(db);
    final r = (await db.query('spectral_archive')).single;
    expect(r['device_id'], '');
    expect(r['part'], 0);
    expect(r['blob'], Uint8List.fromList([4, 5, 6]));
    expect(r['created_at'], 77);
    expect(await db.query('spectral_archive_status'), isEmpty);
  });

  test('idempotent: re-running over the new shape loses nothing', () async {
    const name = 'openstrap_schema67_rerun.db';
    created.add(name);
    await _seedV66(name);
    var db = await _open(name);
    await db.execute('PRAGMA user_version = 66');
    db = await _open(name);
    await _expectShape(db);
    expect(await db.query('spectral_archive'), hasLength(1));
  });

  test('self-heal and fresh install both have the new shape', () async {
    const name = 'openstrap_schema67_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    var db = await _open(name);
    await _expectShape(db);
    await db.execute('DROP TABLE spectral_archive_status');
    db = await _open(name);
    await _expectShape(db);
  });
}
