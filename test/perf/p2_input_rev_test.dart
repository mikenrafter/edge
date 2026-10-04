// 8AG-perf P2-A: trustworthy input revisions.
//
// The bug: `LocalDb.decodedDayFingerprints` was `MAX(rec_ts):COUNT(*)` over a
// day's decoded 1 Hz rows. It cannot see (1) a row REPLACED in place (same
// rec_ts, same count, different hr) or (2) any change to `decoded_rr`, so
// `run(changedOnly:)` would call a day "unchanged" after the very data it
// reads changed.
//
// ASSUMED API (lib/data/db.dart):
//
//   * `LocalDb.schemaVersion == 58`.
//   * New table `input_rev(bucket INTEGER PRIMARY KEY, rev INTEGER NOT NULL)`;
//     bucket = rec_ts ~/ 900 (absolute 15-minute buckets).
//   * SQLite triggers on BOTH `decoded_onehz` and `decoded_rr`, AFTER INSERT,
//     AFTER UPDATE and AFTER DELETE, each bumping the row's bucket by 1
//     (creating it at 1). Rows with rec_ts NULL or <= 0 are ignored. No
//     trigger names are assumed: the tests read them out of `sqlite_master`.
//     (INSERT OR REPLACE fires the AFTER INSERT trigger; the delete trigger
//     is not involved, recursive_triggers being off.)
//   * The creator runs from the `oldV < 58` rung AND from `_repairOpenSchema`
//     (onOpen), idempotently (`CREATE ... IF NOT EXISTS`). Existing days are
//     NOT backfilled (a missing bucket reads as rev 0).
//   * `decodedDayFingerprints(days)` -> `{day: "MAX(rec_ts):COUNT(*):REVSUM"}`
//     with REVSUM = COALESCE(SUM(rev), 0) over buckets
//     [lo ~/ 900, (hi - 1) ~/ 900], lo/hi = localDayStartSec / localDayEndSec.
//
// The day boundary is exercised at lo / hi-1 / hi rather than at a +05:45
// offset: the test process cannot change its timezone, and local midnight is a
// multiple of 900 s in every real zone, so "the last second of D is in D's
// bucket range and the first second of D+1 is not" is the same property.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _counter = 1000;

Future<void> _record(int ts, {int hr = 62}) async {
  final c = _counter++;
  await LocalDb.insertRecord(
    RawRecord(
      counter: c,
      packetType: 47,
      hex: 'p2rev$c',
      capturedAt: ts * 1000,
      recTs: ts,
    ),
    Sample(
      tsEpoch: ts,
      counter: c,
      hr: hr,
      rrIntervalsMs: const [],
      ax: 0,
      ay: 0,
      az: 1,
      spo2RedRaw: 1,
      spo2IrRaw: 1,
      skinTempRaw: 3000,
    ),
  );
}

Future<void> _rr(int ts, {int beat = 0, int ms = 900}) async {
  final db = await LocalDb.instance;
  await db.execute(
    'INSERT OR REPLACE INTO decoded_rr '
    '(device_id, ts_ms, rec_ts, beat_index, rr_ts_ms, rr_ms) '
    "VALUES ('', ?, ?, ?, ?, ?)",
    [ts * 1000, ts, beat, ts * 1000, ms],
  );
}

String _dayLabel(int daysAgo) {
  final n = DateTime.now();
  return dayLabelOf(DateTime(n.year, n.month, n.day - daysAgo));
}

Future<String?> _fp(String day) async =>
    (await LocalDb.decodedDayFingerprints([day]))[day];

Future<int> _rev(int ts) async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    'SELECT rev FROM input_rev WHERE bucket = ?',
    [ts ~/ 900],
  );
  return rows.isEmpty ? 0 : (rows.first['rev'] as num).toInt();
}

Future<List<Map<String, Object?>>> _triggers() async {
  final db = await LocalDb.instance;
  return db.rawQuery(
    "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'trigger' "
    "AND sql LIKE '%input_rev%'",
  );
}

Future<bool> _hasInputRevTable() async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'input_rev'",
  );
  return rows.isNotEmpty;
}

Future<void> _reopen() async {
  await LocalDb.close();
  await LocalDb.instance;
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_p2_input_rev_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('schema ladder is at 58', () {
    expect(LocalDb.schemaVersion, 58);
  });

  group('the day fingerprint sees what MAX:COUNT cannot', () {
    test('format is MAX(rec_ts):COUNT(*):REVSUM', () async {
      final lo = localDayStartSec(_dayLabel(3))!;
      final t = lo + 3600;
      await _record(t);
      await _record(t + 1);
      final fp = await _fp(_dayLabel(3));
      expect(fp, matches(RegExp(r'^\d+:\d+:\d+$')));
      final parts = fp!.split(':');
      expect(parts[0], '${t + 1}');
      expect(parts[1], '2');
      expect(int.parse(parts[2]), greaterThan(0),
          reason: 'two inserts happened, so the buckets carry revisions');
    });

    test('REPLACE of a row (same rec_ts, same count, different hr) changes it',
        () async {
      final lo = localDayStartSec(_dayLabel(4))!;
      final t = lo + 7200;
      await _record(t, hr: 60);
      await _record(t + 1, hr: 61);
      final before = await _fp(_dayLabel(4));

      await _record(t + 1, hr: 99); // same second, new contents
      final after = await _fp(_dayLabel(4));

      expect(after, isNot(before),
          reason: 'a derive would now read a different heart rate; the old '
              'MAX:COUNT cannot tell');
      expect(after!.split(':').take(2), before!.split(':').take(2),
          reason: 'MAX and COUNT really are unchanged: only the revision '
              'part tells the two states apart');
    });

    test('an RR-only insert (decoded_rr, no 1 Hz change) changes it', () async {
      final lo = localDayStartSec(_dayLabel(5))!;
      final t = lo + 7200;
      await _record(t);
      final before = await _fp(_dayLabel(5));

      await _rr(t, beat: 3, ms: 812);
      final after = await _fp(_dayLabel(5));

      expect(after, isNot(before));
    });

    test('an RR-only delete changes it', () async {
      final lo = localDayStartSec(_dayLabel(6))!;
      final t = lo + 7200;
      await _record(t);
      await _rr(t, beat: 0);
      await _rr(t, beat: 1);
      final before = await _fp(_dayLabel(6));

      final db = await LocalDb.instance;
      await db.delete('decoded_rr',
          where: 'rec_ts = ? AND beat_index = 1', whereArgs: [t]);
      final after = await _fp(_dayLabel(6));

      expect(after, isNot(before));
    });

    test('a 1 Hz delete bumps the row\'s bucket', () async {
      final lo = localDayStartSec(_dayLabel(7))!;
      final t = lo + 7200;
      await _record(t);
      await _record(t + 1);
      final before = await _rev(t);

      final db = await LocalDb.instance;
      await db.delete('decoded_onehz', where: 'rec_ts = ?', whereArgs: [t + 1]);

      expect(await _rev(t), before + 1);
    });

    test('an UPDATE in place bumps the bucket', () async {
      final lo = localDayStartSec(_dayLabel(8))!;
      final t = lo + 7200;
      await _record(t, hr: 60);
      final before = await _rev(t);

      final db = await LocalDb.instance;
      await db.update('decoded_onehz', {'hr': 77},
          where: 'rec_ts = ?', whereArgs: [t]);

      expect(await _rev(t), before + 1);
    });

    test('an UPDATE that moves rec_ts bumps both the old and the new bucket',
        () async {
      final lo = localDayStartSec(_dayLabel(9))!;
      final t = lo + 7200;
      final moved = t + 3 * 900; // three buckets later
      await _record(t);
      final oldBefore = await _rev(t);
      final newBefore = await _rev(moved);

      final db = await LocalDb.instance;
      await db.update('decoded_onehz', {'rec_ts': moved, 'ts_ms': moved * 1000},
          where: 'rec_ts = ?', whereArgs: [t]);

      expect(await _rev(t), oldBefore + 1);
      expect(await _rev(moved), newBefore + 1);
    });

    test('rows with rec_ts <= 0 are ignored by the triggers', () async {
      final db = await LocalDb.instance;
      final before = (await db.rawQuery('SELECT COUNT(*) AS n FROM input_rev'))
          .first['n'];
      await db.execute(
        'INSERT OR REPLACE INTO decoded_rr '
        '(device_id, ts_ms, rec_ts, beat_index, rr_ts_ms, rr_ms) '
        "VALUES ('', 0, 0, 0, 0, 800)",
      );
      final after = (await db.rawQuery('SELECT COUNT(*) AS n FROM input_rev'))
          .first['n'];
      expect(after, before, reason: 'bucket 0 must not be created');
      await db.delete('decoded_rr', where: 'rec_ts = 0');
    });
  });

  group('a day only sees its own buckets', () {
    test('a write on day D does not change day D+1 (or D-1)', () async {
      final d = _dayLabel(11);
      final next = _dayLabel(10);
      final prev = _dayLabel(12);
      final lo = localDayStartSec(d)!;
      await _record(lo + 7200, hr: 60);
      await _record(localDayStartSec(next)! + 7200, hr: 60);
      await _record(localDayStartSec(prev)! + 7200, hr: 60);
      final nextBefore = await _fp(next);
      final prevBefore = await _fp(prev);
      final dBefore = await _fp(d);

      await _record(lo + 7200, hr: 88); // replace on D only
      await _rr(lo + 7200, beat: 2); // and RR on D only

      expect(await _fp(d), isNot(dBefore));
      expect(await _fp(next), nextBefore);
      expect(await _fp(prev), prevBefore);
    });

    test('the last second of D belongs to D, the first second of D+1 does not',
        () async {
      final d = _dayLabel(14);
      final next = _dayLabel(13);
      final hi = localDayEndSec(d)!;
      expect(hi, localDayStartSec(next));
      await _record(hi - 1, hr: 60);
      await _record(hi, hr: 60);
      final dBefore = await _fp(d);
      final nextBefore = await _fp(next);

      await _record(hi - 1, hr: 90); // replace D's last second
      expect(await _fp(d), isNot(dBefore));
      expect(await _fp(next), nextBefore,
          reason: 'hi-1 is in the last bucket of D, not in D+1');

      final dMid = await _fp(d);
      await _record(hi, hr: 91); // replace D+1's first second
      expect(await _fp(next), isNot(nextBefore));
      expect(await _fp(d), dMid, reason: 'hi is D+1\'s first bucket');
    });

    test('a day with no rows has no fingerprint', () async {
      expect(await _fp(_dayLabel(40)), isNull);
    });
  });

  group('triggers are present, self-heal and migrate', () {
    test('both tables carry insert, update and delete triggers', () async {
      expect(await _hasInputRevTable(), isTrue);
      final ts = await _triggers();
      for (final table in const ['decoded_onehz', 'decoded_rr']) {
        final mine = ts.where((t) => t['tbl_name'] == table).toList();
        for (final event in const ['INSERT', 'UPDATE', 'DELETE']) {
          expect(
            mine.any((t) => (t['sql'] as String).toUpperCase().contains('AFTER $event')),
            isTrue,
            reason: '$table needs an AFTER $event trigger',
          );
        }
      }
    });

    test('they survive a close and reopen', () async {
      final before = (await _triggers()).length;
      await _reopen();
      expect((await _triggers()).length, before);
      final lo = localDayStartSec(_dayLabel(20))!;
      await _record(lo + 100);
      final rev = await _rev(lo + 100);
      await _record(lo + 100, hr: 70);
      expect(await _rev(lo + 100), rev + 1);
    });

    test('dropped triggers are re-created on open (onOpen repair)', () async {
      var db = await LocalDb.instance;
      for (final t in await _triggers()) {
        await db.execute('DROP TRIGGER IF EXISTS "${t['name']}"');
      }
      expect(await _triggers(), isEmpty);

      await _reopen();

      expect((await _triggers()).length, greaterThanOrEqualTo(6),
          reason: 'same-version merged builds must self-heal');
      db = await LocalDb.instance;
      final lo = localDayStartSec(_dayLabel(21))!;
      await _record(lo + 100);
      final rev = await _rev(lo + 100);
      await _record(lo + 100, hr: 71);
      expect(await _rev(lo + 100), rev + 1);
    });

    test('a database stamped version 57 upgrades: table and triggers appear, '
        'twice over without error', () async {
      Future<void> downgradeTo57() async {
        final db = await LocalDb.instance;
        for (final t in await _triggers()) {
          await db.execute('DROP TRIGGER IF EXISTS "${t['name']}"');
        }
        await db.execute('DROP TABLE IF EXISTS input_rev');
        await db.execute('PRAGMA user_version = 57');
      }

      await downgradeTo57();
      await _reopen();
      expect(await _hasInputRevTable(), isTrue);
      final first = (await _triggers()).length;
      expect(first, greaterThanOrEqualTo(6));
      final db = await LocalDb.instance;
      final v = await db.rawQuery('PRAGMA user_version');
      expect(v.first.values.first, 58);

      // Idempotent: stamp it back to 57 WITHOUT removing anything, run the
      // rung again.
      await db.execute('PRAGMA user_version = 57');
      await _reopen();
      expect((await _triggers()).length, first,
          reason: 're-running the rung must not duplicate triggers');
      expect(await _hasInputRevTable(), isTrue);
    });
  });
}
