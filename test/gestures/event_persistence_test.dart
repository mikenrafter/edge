// Event persistence keeps the strap's FULL timestamp (Phase 5A, step 2).
//
// Today `events` stores whole seconds only (`ts`) plus `captured_at`, the phone's
// receipt time. The strap's sub-second field is thrown away, so two taps in one
// second are indistinguishable and a replayed tap cannot be placed exactly.
// Schema 55 adds `ts_subsec INTEGER NOT NULL DEFAULT 0` (additive, idempotent,
// self-healing through `_repairOpenSchema`) and `insertEvent` writes it.
//
// Runs the REAL LocalDb over sqflite_ffi, like test/local_persistence_test.dart
// and test/db_migration_ladder_test.dart.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final DateTime _strapAt = DateTime.utc(2026, 3, 14, 12, 0, 0);
final int _ts = _strapAt.millisecondsSinceEpoch ~/ 1000;

String _eventHex(int id, int ts, int subsec) {
  final b = Uint8List(12);
  final v = ByteData.sublistView(b);
  b[0] = 0x30;
  b[1] = 0x07;
  v.setUint16(2, id, Endian.little);
  v.setUint32(4, ts, Endian.little);
  v.setUint16(8, subsec, Endian.little);
  v.setUint16(10, 0, Endian.little);
  return [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
}

StrapEvent _tap({
  required String device,
  required int subsec,
  int? ts,
  DateTime? receivedAt,
  int id = 14,
}) {
  final t = ts ?? _ts;
  return StrapEvent(
    eventId: id,
    tsEpoch: t,
    tsSubsec: subsec,
    receivedAt: receivedAt ?? _strapAt.add(const Duration(seconds: 1)),
    hex: _eventHex(id, t, subsec),
    deviceId: device,
  );
}

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// The events table as every install up to schema 54 has it.
const _legacyEventsDdl = '''
  CREATE TABLE events (
    device_id TEXT NOT NULL DEFAULT '',
    hex TEXT NOT NULL,
    event_id INTEGER,
    ts INTEGER,
    captured_at INTEGER NOT NULL,
    PRIMARY KEY (device_id, hex)
  )
''';

Future<void> _seedLegacy(String name, int version) async {
  final path = await _dbPath(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        await db.execute(_legacyEventsDdl);
        await db.insert('events', {
          'device_id': 'old-dev',
          'hex': _eventHex(14, 1786000000, 0),
          'event_id': 14,
          'ts': 1786000000,
          'captured_at': 1786000005000,
        });
      },
    ),
  );
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

Future<List<Map<String, Object?>>> _eventsCols(Database db) =>
    db.rawQuery('PRAGMA table_info(events)');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _dbPath(n));
    }
  });

  group('insertEvent keeps strap time and receipt time apart', () {
    late Database db;

    setUpAll(() async {
      const name = 'gestures_event_persistence_test.db';
      created.add(name);
      await databaseFactory.deleteDatabase(await _dbPath(name));
      db = await _openThroughLocalDb(name);
    });

    Future<List<Map<String, Object?>>> rows(String device) =>
        db.query('events', where: 'device_id = ?', whereArgs: [device]);

    test('the schema is 55', () {
      expect(LocalDb.schemaVersion, 55);
    });

    test('a fresh install has the ts_subsec column, NOT NULL DEFAULT 0',
        () async {
      final col =
          (await _eventsCols(db)).where((c) => c['name'] == 'ts_subsec');
      expect(col, hasLength(1));
      expect(col.single['notnull'], 1);
      expect('${col.single['dflt_value']}', '0');
    });

    test('ts_subsec is stored, ts stays whole seconds, captured_at is receipt',
        () async {
      final receipt = _strapAt.add(const Duration(days: 2, seconds: 3));
      await LocalDb.insertStrapEvent(
          _tap(device: 'p-1', subsec: 12345, receivedAt: receipt));

      final r = (await rows('p-1')).single;
      expect(r['ts_subsec'], 12345);
      expect(r['ts'], _ts);
      expect(r['event_id'], 14);
      expect(r['captured_at'], receipt.millisecondsSinceEpoch,
          reason: 'captured_at is the PHONE receipt time, never the strap time');
    });

    test('a delayed tap\'s receipt time is not substituted for its strap time',
        () async {
      final receipt = _strapAt.add(const Duration(hours: 7));
      await LocalDb.insertStrapEvent(
          _tap(device: 'p-2', subsec: 0, receivedAt: receipt));
      final r = (await rows('p-2')).single;
      expect(r['ts'], _ts);
      expect(r['captured_at'], isNot(_ts * 1000));
    });

    test('re-inserting the same event (same device + hex) adds no row and keeps '
        'the first receipt time', () async {
      final first = _tap(
          device: 'p-3',
          subsec: 777,
          receivedAt: _strapAt.add(const Duration(seconds: 1)));
      final resent = _tap(
          device: 'p-3',
          subsec: 777,
          receivedAt: _strapAt.add(const Duration(hours: 9)));
      await LocalDb.insertStrapEvent(first);
      await LocalDb.insertStrapEvent(resent);

      final r = await rows('p-3');
      expect(r, hasLength(1));
      expect(r.single['ts_subsec'], 777);
      expect(r.single['captured_at'], first.receivedAt.millisecondsSinceEpoch);
    });

    test('two taps in the same second with different subsec are two rows',
        () async {
      await LocalDb.insertStrapEvent(_tap(device: 'p-4', subsec: 100));
      await LocalDb.insertStrapEvent(_tap(device: 'p-4', subsec: 16384));
      final r = await rows('p-4');
      expect(r.map((x) => x['ts_subsec']).toSet(), {100, 16384});
    });

    test('the legacy positional insertEvent still works and reads subsec from '
        'the frame', () async {
      await LocalDb.insertEvent(14, _ts, _eventHex(14, _ts, 4321),
          deviceId: 'p-5');
      expect((await rows('p-5')).single['ts_subsec'], 4321);
    });

    test('insertEvent accepts an explicit tsSubsec and receivedAt', () async {
      final receipt = _strapAt.add(const Duration(minutes: 3));
      await LocalDb.insertEvent(14, _ts, 'aa01',
          deviceId: 'p-6', tsSubsec: 99, receivedAt: receipt);
      final r = (await rows('p-6')).single;
      expect(r['ts_subsec'], 99);
      expect(r['captured_at'], receipt.millisecondsSinceEpoch);
    });

    test('an unparseable frame with no explicit subsec stores 0, not garbage',
        () async {
      await LocalDb.insertEvent(33, _ts, 'aa02', deviceId: 'p-7');
      expect((await rows('p-7')).single['ts_subsec'], 0);
    });

    test('strapEvents returns strap time and receipt time separately, oldest '
        'first by (ts, subsec)', () async {
      final late = _strapAt.add(const Duration(days: 1));
      // Inserted newest-first on purpose.
      await LocalDb.insertStrapEvent(
          _tap(device: 'p-8', subsec: 16384, receivedAt: late));
      await LocalDb.insertStrapEvent(
          _tap(device: 'p-8', subsec: 0, receivedAt: late));
      await LocalDb.insertStrapEvent(
          _tap(device: 'p-8', subsec: 0, ts: _ts - 10, receivedAt: late));
      // A different device and a different event id must not leak in.
      await LocalDb.insertStrapEvent(
          _tap(device: 'p-8-other', subsec: 1, receivedAt: late));
      await LocalDb.insertStrapEvent(
          _tap(device: 'p-8', subsec: 5, id: 7, receivedAt: late));

      final got = await LocalDb.strapEvents(deviceId: 'p-8', eventId: 14);
      expect(got, hasLength(3));
      expect(got.map((e) => (e.tsEpoch, e.tsSubsec)).toList(),
          [(_ts - 10, 0), (_ts, 0), (_ts, 16384)]);
      expect(got.last.strapTime,
          DateTime.utc(2026, 3, 14, 12, 0, 0, 500));
      expect(got.last.receivedAt.toUtc(), late);
      expect(got.last.identity, 'p-8:14:$_ts:16384');
      expect(got.last.deviceId, 'p-8');
    });
  });

  group('schema 55 migration', () {
    test('54 -> 55 adds ts_subsec; existing rows survive with subsec 0',
        () async {
      const name = 'gestures_migrate_54_test.db';
      created.add(name);
      await _seedLegacy(name, 54);
      final db = await _openThroughLocalDb(name);

      final rows = await db.rawQuery('PRAGMA user_version');
      expect((rows.first.values.first as num).toInt(), LocalDb.schemaVersion);
      expect(LocalDb.schemaVersion, 55);

      final names = (await _eventsCols(db)).map((c) => c['name']).toSet();
      expect(names, contains('ts_subsec'));

      final old = (await db.query('events',
              where: 'device_id = ?', whereArgs: ['old-dev']))
          .single;
      expect(old['ts_subsec'], 0);
      expect(old['ts'], 1786000000);
      expect(old['captured_at'], 1786000005000, reason: 'receipt time untouched');
    });

    test('re-opening the migrated database is a no-op (idempotent)', () async {
      const name = 'gestures_migrate_54_idem_test.db';
      created.add(name);
      await _seedLegacy(name, 54);
      await _openThroughLocalDb(name);
      final db = await _openThroughLocalDb(name); // close + reopen
      final cols = (await _eventsCols(db))
          .where((c) => c['name'] == 'ts_subsec')
          .toList();
      expect(cols, hasLength(1));
      expect(await db.query('events', where: 'device_id = ?', whereArgs: ['old-dev']),
          hasLength(1));
    });

    test('a same-version build whose events table lacks the column self-heals '
        'on open (_repairOpenSchema)', () async {
      const name = 'gestures_selfheal_test.db';
      created.add(name);
      // Same user_version as the current schema: no onUpgrade runs, so only the
      // onOpen repair pass can add the column.
      await _seedLegacy(name, LocalDb.schemaVersion);
      final db = await _openThroughLocalDb(name);
      final names = (await _eventsCols(db)).map((c) => c['name']).toSet();
      expect(names, contains('ts_subsec'));
      // And the repaired table accepts the new insert path.
      await LocalDb.insertStrapEvent(_tap(device: 'healed', subsec: 42));
      expect(
          (await db.query('events',
                  where: 'device_id = ?', whereArgs: ['healed']))
              .single['ts_subsec'],
          42);
    });
  });
}
