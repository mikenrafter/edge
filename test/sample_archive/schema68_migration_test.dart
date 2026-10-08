// Schema 67 -> 68 (RED): spectral_archive gains origin_sec, n_slots, slot_sec.
//
// A part's slots are positional; the origin is the absolute epoch second of
// slot 0, so coverage reconciles across time zones. Legacy parts (written
// before 68) get origin = the start of their day id in the zone the migration
// runs in (ASSUMPTION: the device has not changed zone since archiving; a part
// archived abroad would be misplaced), n_slots from the blob header (the day
// length if the blob is unreadable), slot_sec 1. Additive, idempotent, no
// kAlgoVersion bump.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sample_codec.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Uint8List _good() => SampleCodec.encode(
        'hr', <double?>[70.0, 71.0, 72.0, ...List<double?>.filled(1000, null)]).blob;

Future<void> _seedV67(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 67,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE spectral_archive ('
                "day_id TEXT NOT NULL, device_id TEXT NOT NULL DEFAULT '', "
                'signal TEXT NOT NULL, codec_version INTEGER NOT NULL, '
                'part INTEGER NOT NULL DEFAULT 0, blob BLOB NOT NULL, '
                'n_valid INTEGER NOT NULL, rms_err REAL NOT NULL, '
                'max_err REAL NOT NULL, created_at INTEGER NOT NULL, '
                'PRIMARY KEY (day_id, device_id, signal, codec_version, part))');
            Future<void> ins(String day, int part, Uint8List blob) =>
                db.insert('spectral_archive', {
                  'day_id': day, 'device_id': '', 'signal': 'hr',
                  'codec_version': 1, 'part': part, 'blob': blob,
                  'n_valid': 3, 'rms_err': 0.1, 'max_err': 0.2,
                  'created_at': 9,
                });
            await ins('2026-10-03', 0, _good());
            await ins('2026-10-04', 0, Uint8List.fromList([1, 2, 3])); // junk
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

  test('schemaVersion is 68', () => expect(LocalDb.schemaVersion, 68));

  test('v67 -> 68 adds the columns and derives legacy origins', () async {
    const name = 'openstrap_schema68_up.db';
    created.add(name);
    await _seedV67(name);
    final db = await _open(name);
    final cols = {
      for (final c in await db.rawQuery('PRAGMA table_info(spectral_archive)'))
        c['name'] as String: c
    };
    expect(cols.keys, containsAll(['origin_sec', 'n_slots', 'slot_sec']));
    expect(cols['slot_sec']!['dflt_value'], '1');
    final rows = await db.query('spectral_archive', orderBy: 'day_id');
    expect(rows[0]['origin_sec'], localDayStartSec('2026-10-03'));
    expect(rows[0]['n_slots'], 1003, reason: 'from the blob header');
    expect(rows[0]['slot_sec'], 1);
    expect(rows[1]['origin_sec'], localDayStartSec('2026-10-04'));
    expect(rows[1]['n_slots'], localDayLengthSec('2026-10-04'),
        reason: 'unreadable blob: the day length');
    expect(rows[0]['blob'], _good());
  });

  test('idempotent: re-running keeps origins already set', () async {
    const name = 'openstrap_schema68_rerun.db';
    created.add(name);
    await _seedV67(name);
    var db = await _open(name);
    await db.update('spectral_archive', {'origin_sec': 12345},
        where: "day_id = '2026-10-03'");
    await db.execute('PRAGMA user_version = 67');
    db = await _open(name);
    expect((await db.query('spectral_archive', where: "day_id = '2026-10-03'"))
        .single['origin_sec'], 12345);
  });

  test('fresh install and self-heal have the columns', () async {
    const name = 'openstrap_schema68_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    final c = [
      for (final r in await db.rawQuery('PRAGMA table_info(spectral_archive)'))
        r['name']
    ];
    expect(c, containsAll(['origin_sec', 'n_slots', 'slot_sec']));
  });
}
