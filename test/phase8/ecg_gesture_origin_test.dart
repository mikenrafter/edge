// 8N: raw ECG recorded for a tap gesture later arrives through ordinary
// history sync. It must be labelled (`ecg_raw_packet.origin = 'gesture'`) and
// never read as an ECG reading. Real LocalDb over sqflite_ffi.
//
// Covers: packets inside / at the edges of / outside a gesture interval,
// out-of-order arrival (packets before the interval is known get re-tagged),
// a real reading next to a gesture keeping its packets and reading_id, another
// device's packets at the same time, the user-facing count, the migration
// (idempotent, plus a same-version repair), and a restore that would otherwise
// REPLACE a tagged row with an untagged copy.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _tol = LocalDb.gestureTagToleranceSec;

EcgRawPacket _pkt(int sec, {String deviceId = '', String tag = ''}) =>
    EcgRawPacket(
      hex: '2f10${deviceId.isEmpty ? 'aa' : 'bb'}$sec$tag',
      deviceId: deviceId,
      sequence: sec,
      strapSeconds: sec,
      strapSubsec: 0,
      capturedAt: 1790000000000 + sec,
    );

Future<void> _commit(List<EcgRawPacket> pk) =>
    LocalDb.commitSyncBatch(const [], const <Sample?>[], ecgRawPackets: pk);

Future<Map<int, String?>> _origins({String deviceId = ''}) async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    'SELECT strap_seconds, origin FROM ecg_raw_packet WHERE device_id = ?',
    [deviceId],
  );
  return {
    for (final r in rows)
      (r['strap_seconds'] as num).toInt(): r['origin'] as String?,
  };
}

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Future<void> _fresh(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  await databaseFactory.deleteDatabase(await _path(name));
  LocalDb.dbName = name;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
  });

  group('tagging', () {
    setUp(() => _fresh('openstrap_ecg_gesture_origin_test.db'));

    test('inside, at the edges, and outside an interval', () async {
      await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 1000,
        strapEnd: 1010,
        finalCount: 3,
        createdAtMs: 1,
      );
      await _commit([
        _pkt(1000 - _tol - 1), // just outside the tolerance
        _pkt(1000 - _tol), // the tolerance edge: tagged
        _pkt(1000), // interval start
        _pkt(1005),
        _pkt(1010), // interval end
        _pkt(1010 + _tol), // the tolerance edge: tagged
        _pkt(1010 + _tol + 1), // just outside
      ]);
      final o = await _origins();
      expect(o[1000 - _tol - 1], isNull);
      expect(o[1000 - _tol], 'gesture');
      expect(o[1000], 'gesture');
      expect(o[1005], 'gesture');
      expect(o[1010], 'gesture');
      expect(o[1010 + _tol], 'gesture');
      expect(o[1010 + _tol + 1], isNull);
    });

    test('packets that arrive BEFORE the interval is known are re-tagged',
        () async {
      await _commit([_pkt(2000), _pkt(2004), _pkt(2100)]);
      expect((await _origins()).values.every((v) => v == null), isTrue);
      final n = await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 2000,
        strapEnd: 2005,
        finalCount: null,
        reason: 'link_lost',
        createdAtMs: 2,
      );
      expect(n, 2);
      final o = await _origins();
      expect(o[2000], 'gesture');
      expect(o[2004], 'gesture');
      expect(o[2100], isNull);
    });

    test('re-tagging is idempotent and re-delivery keeps the tag', () async {
      await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 3000,
        strapEnd: 3003,
        finalCount: 2,
        createdAtMs: 3,
      );
      await _commit([_pkt(3001)]);
      await _commit([_pkt(3001)]); // same bytes again
      expect((await _origins())[3001], 'gesture');
      final again = await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 3000,
        strapEnd: 3003,
        finalCount: 2,
        createdAtMs: 3, // the same session written twice
      );
      expect(again, 0, reason: 'already tagged: nothing left to change');
      expect(await LocalDb.ecgGestureSessions(), hasLength(1));
    });

    test('a real reading next to a gesture keeps its packets and reading_id',
        () async {
      // The reading's raw packets, linked to it, sit inside the gesture's
      // tolerance band numerically but are linked: never gesture contact.
      await _commit([_pkt(3999), _pkt(4020)]);
      final db = await LocalDb.instance;
      await db.update(
        'ecg_raw_packet',
        {'reading_id': 'reading-1'},
        where: 'strap_seconds IN (3999, 4020)',
      );
      await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 4000,
        strapEnd: 4010,
        finalCount: 2,
        createdAtMs: 4,
      );
      // A new packet inside the gesture, and one far from it.
      await _commit([_pkt(4005), _pkt(4100)]);
      final rows = await db.query('ecg_raw_packet', orderBy: 'strap_seconds');
      final by = {for (final r in rows) (r['strap_seconds'] as num).toInt(): r};
      expect(by[3999]!['reading_id'], 'reading-1');
      expect(by[3999]!['origin'], isNull,
          reason: 'a packet linked to a reading is never gesture contact');
      expect(by[4020]!['reading_id'], 'reading-1');
      expect(by[4020]!['origin'], isNull);
      expect(by[4005]!['origin'], 'gesture');
      expect(by[4005]!['reading_id'], isNull,
          reason: 'gesture packets are never linked to a reading');
      expect(by[4100]!['origin'], isNull);
    });

    test("another device's packets at the same time are not tagged", () async {
      await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 5000,
        strapEnd: 5010,
        finalCount: 2,
        createdAtMs: 5,
      );
      await _commit([_pkt(5005), _pkt(5005, deviceId: 'dev-2')]);
      expect((await _origins())[5005], 'gesture');
      expect((await _origins(deviceId: 'dev-2'))[5005], isNull);
      // And the other direction: a session on dev-2 does not tag the primary.
      await _commit([_pkt(6005)]);
      await LocalDb.recordEcgGestureSession(
        deviceId: 'dev-2',
        strapStart: 6000,
        strapEnd: 6010,
        finalCount: 2,
        createdAtMs: 6,
      );
      expect((await _origins())[6005], isNull);
    });

    test('a session with no known strap bounds is stored but tags nothing',
        () async {
      await _commit([_pkt(7000)]);
      final n = await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: null,
        strapEnd: null,
        finalCount: null,
        reason: 'start_failed',
        createdAtMs: 7,
      );
      expect(n, 0);
      final s = (await LocalDb.ecgGestureSessions()).single;
      expect(s['strap_start'], isNull);
      expect(s['outcome'], 'abandoned');
      expect(s['reason'], 'start_failed');
      expect((await _origins())[7000], isNull);
    });

    test('the session row is the interval and the outcome, nothing else',
        () async {
      await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 100,
        strapEnd: 130,
        finalCount: 4,
        createdAtMs: 8,
      );
      final db = await LocalDb.instance;
      final cols = (await db.rawQuery('PRAGMA table_info(ecg_gesture_session)'))
          .map((c) => c['name'])
          .toSet();
      expect(cols, {
        'device_id', 'strap_start', 'strap_end', 'final_count', 'outcome',
        'reason', 'created_at',
      }, reason: 'no samples column (invariant 14)');
      final s = (await LocalDb.ecgGestureSessions()).single;
      expect(s['outcome'], 'counted');
      expect(s['final_count'], 4);
    });

    test('the count shown to the user leaves gesture packets out', () async {
      await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 9000,
        strapEnd: 9010,
        finalCount: 2,
        createdAtMs: 9,
      );
      await _commit([_pkt(9005), _pkt(9006), _pkt(9500)]);
      expect(await LocalDb.ecgRawPacketCount(), 1);
    });
  });

  group('migration', () {
    const oldDdl = '''
      CREATE TABLE ecg_raw_packet (
        hex           TEXT PRIMARY KEY,
        device_id     TEXT NOT NULL,
        sequence      INTEGER,
        strap_seconds INTEGER,
        strap_subsec  INTEGER,
        captured_at   INTEGER NOT NULL,
        reading_id    TEXT
      )
    ''';

    Future<void> seedOld(String name, int version) async {
      final path = await _path(name);
      await databaseFactory.deleteDatabase(path);
      final db = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: version,
          onCreate: (db, _) async {
            await db.execute(oldDdl);
            await db.insert('ecg_raw_packet', {
              'hex': 'aa',
              'device_id': '',
              'strap_seconds': 10,
              'captured_at': 1,
              'reading_id': 'r1',
            });
          },
        ),
      );
      await db.close();
    }

    Future<Set<String>> cols(String t) async {
      final db = await LocalDb.instance;
      return {
        for (final c in await db.rawQuery('PRAGMA table_info($t)'))
          c['name'] as String
      };
    }

    test('schemaVersion is 57', () => expect(LocalDb.schemaVersion, 57));

    test('v56 -> v57 adds origin and the session table, keeping rows',
        () async {
      const name = 'openstrap_ecg_gesture_mig_test.db';
      await LocalDb.close();
      LocalDb.lastRebuild = null;
      await seedOld(name, 56);
      LocalDb.dbName = name;
      final db = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull,
          reason: '${LocalDb.lastRebuild?.cause}');
      expect((await db.rawQuery('PRAGMA user_version')).first.values.first, 57);
      expect(await cols('ecg_raw_packet'), contains('origin'));
      expect(await cols('ecg_gesture_session'), contains('strap_start'));
      final row = (await db.query('ecg_raw_packet')).single;
      expect(row['reading_id'], 'r1');
      expect(row['origin'], isNull);
    });

    test('re-opening (the creators running again) is a no-op', () async {
      await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 1,
        strapEnd: 2,
        finalCount: 2,
        createdAtMs: 1,
      );
      await LocalDb.close();
      final again = await LocalDb.instance; // onOpen repair runs again
      expect(await cols('ecg_raw_packet'),
          containsAll(['hex', 'origin', 'reading_id']));
      expect(await LocalDb.ecgGestureSessions(), hasLength(1));
      final origin = (await again.rawQuery('PRAGMA table_info(ecg_raw_packet)'))
          .where((c) => c['name'] == 'origin');
      expect(origin, hasLength(1));
    });

    test('a same-version (57) build with the old shape self-heals on open',
        () async {
      const name = 'openstrap_ecg_gesture_repair_test.db';
      await LocalDb.close();
      LocalDb.lastRebuild = null;
      await seedOld(name, 57); // already at the target version: no rung runs
      LocalDb.dbName = name;
      await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull);
      expect(await cols('ecg_raw_packet'), contains('origin'));
      expect(await cols('ecg_gesture_session'), isNotEmpty);
    });
  });

  group('restore', () {
    test('a restore cannot demote a tagged packet to an untagged copy',
        () async {
      await _fresh('openstrap_ecg_gesture_restore_dst.db');
      await LocalDb.recordEcgGestureSession(
        deviceId: '',
        strapStart: 50,
        strapEnd: 60,
        finalCount: 2,
        createdAtMs: 1,
      );
      await _commit([_pkt(55)]);
      expect((await _origins())[55], 'gesture');

      // An export from an older build: same packet bytes, no origin column.
      final srcPath = await _path('openstrap_ecg_gesture_restore_src.db');
      await databaseFactory.deleteDatabase(srcPath);
      final src = await databaseFactory.openDatabase(
        srcPath,
        options: OpenDatabaseOptions(version: 1),
      );
      await src.execute('''
        CREATE TABLE ecg_raw_packet (
          hex TEXT PRIMARY KEY, device_id TEXT NOT NULL, sequence INTEGER,
          strap_seconds INTEGER, strap_subsec INTEGER,
          captured_at INTEGER NOT NULL, reading_id TEXT)''');
      await src.insert('ecg_raw_packet', {
        'hex': _pkt(55).hex,
        'device_id': '',
        'strap_seconds': 55,
        'captured_at': 1,
      });
      await src.close();

      await LocalDb.importFromDbFile(srcPath);
      expect((await _origins())[55], 'gesture');
    });
  });
}
