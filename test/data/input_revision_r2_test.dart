// Design 06 phase 1c, Sol r2 findings 1-4 (+ generator hardening).
//
//  1. A Colmi temperature reply is dated by its session anchor (rec_ts) but
//     carries slots up to kColmiHistoryDays earlier: those days' stamps move.
//  2. A bulk restore of wrist/charging transitions must not do per-row span
//     invalidation (quadratic in transitions x derived days).
//  3. The zone key distinguishes zones whose CURRENT offset is equal but whose
//     historical offsets differ (Denver vs Phoenix in winter).
//  4. The zone cursor and its bump commit together or not at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/colmi.dart' show kColmiHistoryDays;
import 'package:openstrap_edge/compute/groups/input_catalogue.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/input_revision_store.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart'
    show colmiBigDataRequest, colmiTemperatures, kColmiBigTemperature;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Future<int> _rev(String source, String scope,
    {String from = '2024-01-01', String to = '2027-12-31'}) async {
  final snap = await inputRevSnapshot([source], fromDay: from, toDay: to);
  return snap[source]?[scope] ?? 0;
}

int _noon(DateTime d) =>
    DateTime(d.year, d.month, d.day, 12).millisecondsSinceEpoch ~/ 1000;

String _label(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  const name = 'input_revision_r2_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _path(name));
    LocalDb.dbName = name;
    await LocalDb.instance;
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _path(name));
  });

  group('finding 1: Colmi history window', () {
    test('the window matches the decoder history', () {
      final t = kInputCatalogue
          .firstWhere((s) => s.id == 'wearable_records')
          .tables
          .single;
      expect(t.lookbackDays, kColmiHistoryDays);
      expect(t.lookbackWhen, contains(
          '0x${kColmiBigTemperature.toRadixString(16)}'));
    });

    for (final ago in [0, 3, kColmiHistoryDays - 1]) {
      test('a frame banked on the sync day carrying slots $ago days ago moves '
          "that day's stamp, as the decoder dates it", () async {
        final db = await LocalDb.instance;
        final sync = DateTime(2026, 3, 20 + ago);
        final reply = colmiBigDataRequest(
            kColmiBigTemperature, [ago, 60, for (var k = 0; k < 24; k++) 150]);
        final hex = [for (final b in reply) b.toRadixString(16).padLeft(2, '0')]
            .join();
        // The day the decoder puts the slots on.
        final slot = colmiTemperatures(reply).first;
        final day = _label(DateTime(sync.year, sync.month, sync.day - slot.daysAgo));
        expect(slot.daysAgo, ago);
        final before = await _rev('wearable_records', day);
        await db.insert('raw_archive', {
          'device_id': 'fx$ago', 'hex': hex, 'packet_type': reply[0],
          'rec_ts': _noon(sync), 'captured_at': _noon(sync) * 1000,
          'reason': 'colmi_big_0x25',
        });
        expect(await _rev('wearable_records', day), greaterThan(before));
      });
    }

    test('a non-temperature Colmi frame and an Ultrahuman record bump only '
        'their own day', () async {
      final db = await LocalDb.instance;
      final sync = DateTime(2026, 5, 20);
      final earlier = _label(DateTime(2026, 5, 18));
      final before = await _rev('wearable_records', earlier);
      for (final reason in ['colmi_big_0x27', 'ultrahuman_record']) {
        await db.insert('raw_archive', {
          'device_id': 'fxo', 'hex': 'h-$reason', 'packet_type': 1,
          'rec_ts': _noon(sync), 'captured_at': 1, 'reason': reason,
        });
      }
      expect(await _rev('wearable_records', earlier), before);
      expect(await _rev('wearable_records', _label(sync)), greaterThan(0));
    });
  });

  group('finding 2: bulk restore of transitions', () {
    const days = 400;
    const transitions = 2000;
    final base = DateTime(2025, 1, 1);

    Future<String> source() async {
      final f = p.join(Directory.systemTemp.path, 'ir_r2_src.db');
      await databaseFactoryFfi.deleteDatabase(f);
      final src = await databaseFactoryFfi.openDatabase(f);
      await src.execute('''CREATE TABLE events (device_id TEXT, hex TEXT,
        event_id INTEGER, ts INTEGER, captured_at INTEGER)''');
      await src.execute('''CREATE TABLE band_events (device_id TEXT, hex TEXT,
        event_id INTEGER, name TEXT, ts INTEGER, payload_json TEXT,
        captured_at INTEGER)''');
      final t0 = base.millisecondsSinceEpoch ~/ 1000;
      final step = days * 86400 ~/ transitions;
      await src.transaction((txn) async {
        for (var i = 0; i < transitions; i++) {
          final id = i.isEven ? proto.EventId.wristOff : proto.EventId.wristOn;
          await txn.insert('events', {
            'device_id': '', 'hex': 'ev$i', 'event_id': id,
            'ts': t0 + i * step, 'captured_at': 1,
          });
          await txn.insert('band_events', {
            'device_id': '', 'hex': 'be$i', 'event_id': id, 'name': 'x',
            'ts': t0 + i * step, 'payload_json': '{}', 'captured_at': 1,
          });
        }
      });
      await src.close();
      return f;
    }

    test('restoring $transitions transitions over $days derived days stays '
        'linear, and still invalidates the days they reach', () async {
      final db = await LocalDb.instance;
      for (var i = 0; i < days; i++) {
        await db.insert('day_result', {
          'day_id': _label(DateTime(base.year, base.month, base.day + i)),
          'algo_version': 1, 'payload_json': '{}', 'computed_at': 1,
        });
      }
      await db.execute('CREATE TABLE IF NOT EXISTS _upd(n INTEGER)');
      await db.execute('DELETE FROM _upd');
      await db.execute('CREATE TRIGGER IF NOT EXISTS _count_upd AFTER UPDATE '
          'ON input_revision BEGIN INSERT INTO _upd VALUES (1); END');
      final first = _label(DateTime(base.year, base.month, base.day + 10));
      final last = _label(DateTime(base.year, base.month, base.day + days - 1));
      final f10 = await _rev('events', first);
      final fl = await _rev('events', last);
      final src = await source();
      final sw = Stopwatch()..start();
      await LocalDb.importFromDbFile(src);
      sw.stop();
      final updates = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM _upd'))!;
      // ignore: avoid_print
      print('bulk restore: $updates revision updates, ${sw.elapsedMilliseconds} ms');
      // Per-row span bumps would be ~ transitions * days / 2 * 2 tables.
      expect(updates, lessThan(20 * days + 4 * transitions));
      expect(await _rev('events', first), greaterThan(f10));
      expect(await _rev('events', last), greaterThan(fl));
      await db.execute('DROP TRIGGER _count_upd');
      await File(src).delete();
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a normal single-row transition write still bumps the days it holds '
        'over', () async {
      final db = await LocalDb.instance;
      final d = DateTime(2025, 1, 1);
      final target = _label(DateTime(d.year, d.month, d.day + 200));
      final before = await _rev('events', target);
      await db.insert('band_events', {
        'hex': 'single-1', 'event_id': proto.EventId.chargingOn, 'name': 'x',
        'ts': _noon(DateTime(d.year, d.month, d.day + 100)),
        'captured_at': 1,
      });
      expect(await _rev('events', target), greaterThan(before));
    });
  });

  group('finding 3: zone identity', () {
    // Offsets (minutes) now, then 15 Jan / 15 Jul of last year and this.
    final denver = inputZoneKeyOf('MST', -420, [-420, -360, -420, -360]);
    final phoenix = inputZoneKeyOf('MST', -420, [-420, -420, -420, -420]);

    test('equal winter offset, different summer offset: different keys', () {
      expect(denver, isNot(phoenix));
    });

    test('the key is read off the process zone, deterministically', () {
      final now = DateTime.utc(2026, 1, 15);
      expect(inputZoneKey('X', now: now), inputZoneKey('X', now: now));
      expect(inputZoneKey('X', now: now), startsWith('X|'));
    });

    test('travel Denver to Phoenix in winter bumps the zone input', () async {
      await observeInputZone(zoneKey: denver);
      final before = await _rev('zone', '');
      expect(await observeInputZone(zoneKey: phoenix), isTrue);
      expect(await _rev('zone', ''), before + 1);
    });
  });

  group('finding 4: the cursor and the bump commit together', () {
    test('a failure between the cursor write and the bump rolls both back, '
        'and the next observation retries', () async {
      final db = await LocalDb.instance;
      await observeInputZone(zoneKey: 'A|0');
      final revBefore = await _rev('zone', '');
      Future<String?> cursor() async => (await db.query('sync_cursor',
              columns: ['value'],
              where: 'name = ?',
              whereArgs: [kObservedZoneCursor]))
          .single['value'] as String?;
      // The bump is the statement after the cursor write: make it fail.
      await db.execute('CREATE TRIGGER _fail_bump BEFORE UPDATE ON '
          "input_revision WHEN NEW.source = 'zone' "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END");
      await expectLater(
          observeInputZone(zoneKey: 'B|60'), throwsA(isA<DatabaseException>()));
      await db.execute('DROP TRIGGER _fail_bump');
      expect(await cursor(), 'A|0');
      expect(await _rev('zone', ''), revBefore);
      expect(await observeInputZone(zoneKey: 'B|60'), isTrue);
      expect(await _rev('zone', ''), revBefore + 1);
      expect(await cursor(), 'B|60');
    });
  });

  group('generator hardening', () {
    test('displaced-row scopes are DISTINCT', () async {
      final db = await LocalDb.instance;
      final sql = (await db.rawQuery("SELECT sql FROM sqlite_master WHERE "
              "type = 'trigger' AND name = 'ir_sessions_sessions_bi'"))
          .single['sql'] as String;
      expect(sql, contains('SELECT DISTINCT'));
    });

    test('a catalogued table with an expression index is refused', () async {
      final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await raw.execute('CREATE TABLE xx (a TEXT, b TEXT)');
      await raw.execute('CREATE UNIQUE INDEX xx_e ON xx(lower(a))');
      await expectLater(
          inputRevisionKeys(raw, ['xx']), throwsA(isA<AssertionError>()));
      await raw.execute('CREATE TABLE yy (a TEXT PRIMARY KEY, b TEXT)');
      expect((await inputRevisionKeys(raw, ['yy']))['yy'], [
        ['a']
      ]);
      await raw.close();
    });
  });
}
