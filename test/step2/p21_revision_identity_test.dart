// P2.1 revision identity, design 02 step 2, section 4.1.
//
// ASSUMED (lib/data/db.dart, schema 71):
//
//   * `store_rev (id INTEGER PRIMARY KEY AUTOINCREMENT)` is the sequence and
//     `row_rev (kind, k1, k2, rev, PRIMARY KEY (kind, k1, k2)) WITHOUT ROWID` is
//     the current revision per source row: `('day_result', day_id,
//     algo_version)` and `('baselines', key, 0)`. No column is added to
//     `day_result` or `baselines`, so nothing large is rewritten.
//   * Five triggers: `day_result` AFTER INSERT and AFTER DELETE; `baselines`
//     AFTER INSERT, AFTER UPDATE OF payload_json and AFTER DELETE. None on
//     UPDATE of `day_result`: the value-identical re-encode and
//     `touchBaseline` keep their revision.
//   * Revisions come from the AUTOINCREMENT sequence, so they are unique,
//     increase in write order across both tables, and are never reused after a
//     delete or `wipeAll` (`sqlite_sequence` survives both).
//   * A row with no `row_rev` row (written before schema 71) reads revision 0.
//   * `LocalDb.purgeDemoRows()` is the demo delete, moved out of
//     `DemoDataGenerator.purge`.
//
// `LocalDb.nowMs` is frozen wherever two writes must land in one millisecond.
// Nothing here sleeps.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_payload_read.dart';
import 'package:openstrap_edge/data/series_codec.dart';

import 'support/p21_support.dart';

const _name = 'p21_revision_identity.db';
const _d1 = '2026-03-10';
const _d2 = '2026-03-11';
const _d3 = '2026-03-12';

Future<bool> _put(
  String day,
  String tag, {
  int version = p21Version,
  bool finalized = false,
  bool skipped = false,
  String? payload,
  DayResultWrite reason = DayResultWrite.derive,
}) => LocalDb.putDayResult(
  dayId: day,
  algoVersion: version,
  payloadJson: payload ?? p21Payload(tag, day: day),
  windowJson: '{}',
  finalized: finalized,
  skipped: skipped,
  reason: reason,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async => db = await p21Fresh(_name));
  tearDown(() => p21Drop(_name));

  group('schema objects', () {
    test('store_rev is the AUTOINCREMENT sequence', () async {
      await p21ExpectRevTables(db);
      final sql = (await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE name = 'store_rev'",
      )).single['sql'] as String;
      expect(sql.toLowerCase(), contains('autoincrement'));
    });

    test('row_rev is WITHOUT ROWID with PRIMARY KEY (kind, k1, k2)', () async {
      await p21ExpectRevTables(db);
      final sql = ((await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE name = 'row_rev'",
      )).single['sql'] as String).toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      expect(sql, contains('without rowid'));
      expect(sql, contains('primary key (kind, k1, k2)'));
      final cols = {
        for (final c in await db.rawQuery('PRAGMA table_info(row_rev)'))
          c['name'] as String: c,
      };
      expect(cols.keys.toSet(), {'kind', 'k1', 'k2', 'rev'});
      expect(cols['kind']!['type'], 'TEXT');
      expect(cols['k1']!['type'], 'TEXT');
      expect(cols['k2']!['type'], 'INTEGER');
      expect(cols['k2']!['dflt_value'], '0');
      expect(cols['rev']!['type'], 'INTEGER');
      for (final c in cols.values) {
        expect(c['notnull'], 1, reason: '${c['name']} is NOT NULL');
      }
    });

    test('day_result and baselines gain no column (nothing large is rewritten)',
        () async {
      final dr = {
        for (final c in await db.rawQuery('PRAGMA table_info(day_result)'))
          c['name'],
      };
      expect(dr, {
        'day_id',
        'algo_version',
        'payload_json',
        'window_json',
        'computed_at',
        'finalized',
        'rhr',
        'rmssd',
        'readiness',
        'skipped',
        'partial',
      });
      final bl = {
        for (final c in await db.rawQuery('PRAGMA table_info(baselines)'))
          c['name'],
      };
      expect(bl, {'key', 'payload_json', 'updated_at'});
      await p21ExpectRevTables(db);
    });

    test('five triggers: two on day_result, three on baselines', () async {
      await p21ExpectRevTables(db);
      final t = await p21Triggers(db);
      final dr = [for (final e in t.entries) if (e.key.startsWith('day_result:')) e.value];
      final bl = [for (final e in t.entries) if (e.key.startsWith('baselines:')) e.value];
      expect(dr, hasLength(2), reason: '$t');
      expect(bl, hasLength(3), reason: '$t');
      bool has(List<String> sqls, String after) =>
          sqls.any((s) => s.contains(after));
      expect(has(dr, 'after insert on day_result'), isTrue);
      expect(has(dr, 'after delete on day_result'), isTrue);
      expect(has(bl, 'after insert on baselines'), isTrue);
      expect(has(bl, 'after update of payload_json on baselines'), isTrue);
      expect(has(bl, 'after delete on baselines'), isTrue);
    });

    test('no trigger fires on a plain UPDATE of day_result', () async {
      await p21ExpectRevTables(db);
      final t = await p21Triggers(db);
      expect(
        t.entries.where(
          (e) => e.key.startsWith('day_result:') && e.value.contains('update'),
        ),
        isEmpty,
      );
    });

    test('no trigger body uses INSERT ... DEFAULT VALUES (illegal in a trigger)',
        () async {
      await p21ExpectRevTables(db);
      final t = await p21Triggers(db);
      expect(t, isNotEmpty);
      for (final e in t.entries) {
        expect(e.value, isNot(contains('default values')), reason: e.key);
      }
    });
  });

  group('revisions follow accepted writes', () {
    test('an insert gets a revision, row_rev mirrors the source tables', () async {
      await _put(_d1, 'a');
      await LocalDb.putBaseline('k', '{"v":1}');
      expect(await p21DayRev(db, _d1), greaterThan(0));
      expect(await p21BaseRev(db, 'k'), greaterThan(0));
      await p21ExpectRevsConsistent(db);
    });

    test('revisions are unique and increase in write order across both tables',
        () async {
      final seen = <int>[];
      await _put(_d1, 'a');
      seen.add(await p21DayRev(db, _d1));
      await LocalDb.putBaseline('k', '{"v":1}');
      seen.add(await p21BaseRev(db, 'k'));
      await _put(_d2, 'b');
      seen.add(await p21DayRev(db, _d2));
      await LocalDb.putBaseline('k2', '{"v":2}');
      seen.add(await p21BaseRev(db, 'k2'));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]), reason: '$seen');
      }
    });

    test('a write to one row leaves every other row revision alone', () async {
      await _put(_d1, 'a');
      await _put(_d2, 'b');
      await LocalDb.putBaseline('k', '{"v":1}');
      final before = await p21AllRevs(db);
      await _put(_d1, 'a2');
      final after = await p21AllRevs(db);
      expect(after['day_result|$_d2|$p21Version'], before['day_result|$_d2|$p21Version']);
      expect(after['baselines|k|0'], before['baselines|k|0']);
      expect(after['day_result|$_d1|$p21Version'], greaterThan(before['day_result|$_d1|$p21Version']!));
    });

    test('INSERT OR REPLACE bumps and leaves exactly one row_rev row per key',
        () async {
      await _put(_d1, 'a');
      final r1 = await p21DayRev(db, _d1);
      await _put(_d1, 'b');
      final r2 = await p21DayRev(db, _d1);
      expect(r2, greaterThan(r1));
      await p21ExpectRevsConsistent(db);
      // A raw REPLACE (the merge paths use batch.insert the same way).
      await p21RawDay(db, _d1, conflict: ConflictAlgorithm.replace);
      expect(await p21DayRev(db, _d1), greaterThan(r2));
      await p21ExpectRevsConsistent(db);
    });

    test('a replace under recursive_triggers=ON ends with one, newer revision',
        () async {
      await db.execute('PRAGMA recursive_triggers = ON');
      try {
        await _put(_d1, 'a');
        final r1 = await p21DayRev(db, _d1);
        await _put(_d1, 'b');
        expect(await p21DayRev(db, _d1), greaterThan(r1));
        await p21ExpectRevsConsistent(db);
      } finally {
        await db.execute('PRAGMA recursive_triggers = OFF');
      }
    });

    test('a value-identical re-encode keeps the revision', () async {
      final t0 = 1783572180;
      await p21RawDay(
        db,
        _d1,
        version: 47,
        finalized: true,
        payload: jsonEncode(p21LegacyBundle(t0)),
      );
      final before = await p21DayRev(db, _d1, 47);
      expect(before, greaterThan(0));
      final old = (await db.query('day_result', columns: ['payload_json']))
          .single['payload_json'] as String;

      expect(await LocalDb.reencodeLegacyDayResults(), 1);

      final now = (await db.query('day_result', columns: ['payload_json']))
          .single['payload_json'] as String;
      expect(now, isNot(old), reason: 'the payload really was rewritten');
      expect(await p21DayRev(db, _d1, 47), before);
    });

    test('a plain UPDATE of day_result.payload_json does not bump', () async {
      await _put(_d1, 'a');
      final before = await p21DayRev(db, _d1);
      await db.update(
        'day_result',
        {'payload_json': p21Payload('same-values-new-spelling', day: _d1)},
        where: 'day_id = ?',
        whereArgs: [_d1],
      );
      expect(await p21DayRev(db, _d1), before);
    });

    test('touchBaseline keeps the revision, putBaseline and updateBaseline bump',
        () async {
      final clock = P21Clock(1000);
      LocalDb.nowMs = clock.call;
      await LocalDb.putBaseline('k', '{"v":1}');
      final r1 = await p21BaseRev(db, 'k');

      clock.ms = 2000;
      await LocalDb.touchBaseline('k');
      expect((await LocalDb.baseline('k'))!['updated_at'], 2000);
      expect(await p21BaseRev(db, 'k'), r1, reason: 'updated_at only');

      await LocalDb.putBaseline('k', '{"v":1}');
      final r2 = await p21BaseRev(db, 'k');
      expect(r2, greaterThan(r1), reason: 'a replace is a write, even identical');

      await LocalDb.updateBaseline('k', (cur) => '{"v":3}');
      final r3 = await p21BaseRev(db, 'k');
      expect(r3, greaterThan(r2));

      await LocalDb.updateBaseline('k', (cur) => null);
      expect(await p21BaseRev(db, 'k'), r3, reason: 'null leaves the row alone');
    });

    test('a baselines UPDATE that sets payload_json bumps, one that sets '
        'updated_at only does not', () async {
      await LocalDb.putBaseline('k', '{"v":1}');
      final r1 = await p21BaseRev(db, 'k');
      await db.update('baselines', {'updated_at': 5},
          where: 'key = ?', whereArgs: ['k']);
      expect(await p21BaseRev(db, 'k'), r1);
      await db.update('baselines', {'payload_json': '{"v":2}'},
          where: 'key = ?', whereArgs: ['k']);
      expect(await p21BaseRev(db, 'k'), greaterThan(r1));
    });

    test('store_rev is left empty: the sequence lives in sqlite_sequence',
        () async {
      await _put(_d1, 'a');
      await LocalDb.putBaseline('k', '{}');
      await p21ExpectRevTables(db);
      expect(await db.query('store_rev'), isEmpty);
      final seq = await db.rawQuery(
        "SELECT seq FROM sqlite_sequence WHERE name = 'store_rev'",
      );
      expect(seq.single['seq'], greaterThanOrEqualTo(2));
    });
  });

  group('deletes and wipes never reuse a revision', () {
    test('a delete removes the row_rev row; a reinsert is larger than every '
        'revision seen before', () async {
      final ever = <int>[];
      await _put(_d1, 'a');
      await _put(_d2, 'b');
      await LocalDb.putBaseline('k', '{}');
      ever
        ..add(await p21DayRev(db, _d1))
        ..add(await p21DayRev(db, _d2))
        ..add(await p21BaseRev(db, 'k'));

      expect(await LocalDb.deleteDays({_d2}), greaterThan(0));
      final after = await p21AllRevs(db);
      expect(after.containsKey('day_result|$_d2|$p21Version'), isFalse);
      expect(after.containsKey('day_result|$_d1|$p21Version'), isTrue);
      await p21ExpectRevsConsistent(db);

      await _put(_d2, 'b-again');
      final r = await p21DayRev(db, _d2);
      expect(r, greaterThan(ever.reduce((a, b) => a > b ? a : b)));
    });

    test('a baselines delete removes its row_rev row', () async {
      await LocalDb.putBaseline('k', '{}');
      expect(await p21BaseRev(db, 'k'), greaterThan(0));
      await db.delete('baselines', where: 'key = ?', whereArgs: ['k']);
      expect(await p21BaseRev(db, 'k'), 0);
      await p21ExpectRevsConsistent(db);
    });

    test('wipeAll empties row_rev; a reinsert is larger than every earlier '
        'revision', () async {
      await _put(_d1, 'a');
      await _put(_d2, 'b');
      await LocalDb.putBaseline('k', '{}');
      final highest = (await p21AllRevs(db)).values.reduce((a, b) => a > b ? a : b);

      await LocalDb.wipeAll();

      expect(await p21AllRevs(db), isEmpty);
      await _put(_d1, 'after-wipe');
      expect(await p21DayRev(db, _d1), greaterThan(highest));
    });
  });

  group('two accepted writes in one millisecond', () {
    test('derive then userOverride: different revisions, the second payload '
        'is what a read returns', () async {
      LocalDb.nowMs = P21Clock(7777).call;
      await _put(_d1, 'derived', finalized: true);
      final r1 = await p21DayRev(db, _d1);
      final c1 = (await db.query('day_result')).single['computed_at'];

      await _put(_d1, 'override',
          finalized: true, reason: DayResultWrite.userOverride);
      final r2 = await p21DayRev(db, _d1);
      final c2 = (await db.query('day_result')).single['computed_at'];

      expect(c2, c1, reason: 'the clock is frozen: same computed_at');
      expect(r2, isNot(r1));
      expect(r2, greaterThan(r1));
      final read = await LocalDb.dayPayload(_d1, p21Version, expectedRev: r2);
      expect(read, isA<DayPayloadOk>());
      expect(
        SeriesCodec.decodePayloadJson((read as DayPayloadOk).payloadJson)!['tag'],
        'override',
      );
    });

    test('an import over a non-measured row: different revisions, the import '
        'payload is read back', () async {
      LocalDb.nowMs = P21Clock(7777).call;
      await _put(_d1, 'skip', finalized: true, skipped: true);
      final r1 = await p21DayRev(db, _d1);

      final accepted = await _put(
        _d1,
        'import',
        finalized: true,
        payload: p21ImportPayload('import'),
      );
      expect(accepted, isTrue, reason: 'imports replace non-measured rows');
      final r2 = await p21DayRev(db, _d1);

      expect(r2, greaterThan(r1));
      final read = await LocalDb.dayPayload(_d1, p21Version, expectedRev: r2);
      expect(read, isA<DayPayloadOk>());
      expect(
        SeriesCodec.decodePayloadJson((read as DayPayloadOk).payloadJson)!['tag'],
        'import',
      );
    });

    test('two putBaseline calls: different revisions, the second payload wins',
        () async {
      LocalDb.nowMs = P21Clock(7777).call;
      await LocalDb.putBaseline('k', '{"v":1}');
      final r1 = await p21BaseRev(db, 'k');
      await LocalDb.putBaseline('k', '{"v":2}');
      final r2 = await p21BaseRev(db, 'k');
      expect(r2, greaterThan(r1));
      expect((await LocalDb.baseline('k'))!['payload_json'], '{"v":2}');
    });

    test('updateBaseline right after putBaseline: different revisions, the '
        'transformed payload is read back', () async {
      LocalDb.nowMs = P21Clock(7777).call;
      await LocalDb.putBaseline('k', '{"v":1}');
      final r1 = await p21BaseRev(db, 'k');
      await LocalDb.updateBaseline('k', (cur) => '{"v":9}');
      final r2 = await p21BaseRev(db, 'k');
      expect(r2, greaterThan(r1));
      expect((await LocalDb.baseline('k'))!['payload_json'], '{"v":9}');
      expect((await LocalDb.baseline('k'))!['updated_at'], 7777);
    });
  });

  group('sqflite insert() still returns the source row id', () {
    test('day_result: the trigger does not leak its own last_insert_rowid',
        () async {
      // Push the sequence well past any rowid the tables hold.
      for (var i = 0; i < 4; i++) {
        await LocalDb.putBaseline('pad$i', '{}');
      }
      final id = await p21RawDay(db, _d1);
      final rowid = (await db.rawQuery(
        'SELECT rowid AS r FROM day_result WHERE day_id = ?',
        [_d1],
      )).single['r'];
      expect(id, rowid);
      expect(await p21DayRev(db, _d1), greaterThan(4),
          reason: 'the trigger really ran, with a sequence number above the rowid');
    });

    test('day_result replace: returns the new rowid, not the sequence number',
        () async {
      await p21RawDay(db, _d1);
      for (var i = 0; i < 4; i++) {
        await LocalDb.putBaseline('pad$i', '{}');
      }
      final id = await p21RawDay(db, _d1, conflict: ConflictAlgorithm.replace);
      final rowid = (await db.rawQuery(
        'SELECT rowid AS r FROM day_result WHERE day_id = ?',
        [_d1],
      )).single['r'];
      expect(id, rowid);
      expect(await p21DayRev(db, _d1), greaterThan(5));
    });

    test('baselines: same', () async {
      for (var i = 0; i < 3; i++) {
        await p21RawDay(db, '2026-04-0${i + 1}');
      }
      final id = await db.insert('baselines', {
        'key': 'k',
        'payload_json': '{}',
        'updated_at': 1,
      });
      final rowid = (await db.rawQuery(
        "SELECT rowid AS r FROM baselines WHERE key = 'k'",
      )).single['r'];
      expect(id, rowid);
      expect(await p21BaseRev(db, 'k'), greaterThan(3));
    });
  });

  group('rows from before schema 71 have no revision', () {
    test('a row with no row_rev row reads 0 and a write moves it above 0',
        () async {
      await _put(_d1, 'old');
      await p21ExpectRevTables(db);
      await db.delete('row_rev'); // what a migrated v70 row looks like
      expect(await p21DayRev(db, _d1), 0);

      await _put(_d1, 'new');
      expect(await p21DayRev(db, _d1), greaterThan(0));
    });

    test('same for a baseline', () async {
      await LocalDb.putBaseline('k', '{}');
      await p21ExpectRevTables(db);
      await db.delete('row_rev');
      expect(await p21BaseRev(db, 'k'), 0);
      await LocalDb.updateBaseline('k', (cur) => '{"v":2}');
      expect(await p21BaseRev(db, 'k'), greaterThan(0));
    });
  });

  group('(c) each public writer moves the revision of exactly the rows whose '
      'payload it changed', () {
    test('walk through every writer on a seeded database', () async {
      final clock = P21Clock(1000);
      LocalDb.nowMs = clock.call;
      await _put(_d1, 'a');
      await _put(_d2, 'frozen', finalized: true);
      await _put(_d3, 'c');
      await LocalDb.putBaseline('b1', '{"v":1}');
      await LocalDb.putBaseline('b2', '{"v":1}');

      Future<Set<String>> changedBy(Future<void> Function() act) async {
        final before = await p21AllRevs(db);
        await act();
        final after = await p21AllRevs(db);
        return {
          for (final k in {...before.keys, ...after.keys})
            if (before[k] != after[k]) k,
        };
      }

      String d(String day) => 'day_result|$day|$p21Version';

      expect(await changedBy(() => _put(_d1, 'a2')), {d(_d1)},
          reason: 'putDayResult replaces a provisional row');

      expect(await changedBy(() => _put(_d2, 'refused')), isEmpty,
          reason: 'a derive over a frozen row is refused and writes nothing');
      expect(
        SeriesCodec.decodePayloadJson(
            (await db.query('day_result', where: 'day_id = ?', whereArgs: [_d2]))
                .single['payload_json'] as String)!['tag'],
        'frozen',
      );

      expect(
        await changedBy(
          () => _put(_d2, 'forced',
              finalized: true, reason: DayResultWrite.userOverride),
        ),
        {d(_d2)},
      );

      expect(await changedBy(() => LocalDb.putBaseline('b1', '{"v":2}')),
          {'baselines|b1|0'});
      expect(await changedBy(() => LocalDb.touchBaseline('b2')), isEmpty);
      expect(await changedBy(() => LocalDb.updateBaseline('b2', (c) => null)),
          isEmpty);
      expect(
          await changedBy(() => LocalDb.updateBaseline('b2', (c) => '{"v":5}')),
          {'baselines|b2|0'});

      expect(await changedBy(() => LocalDb.deleteDays({_d3})), {d(_d3)},
          reason: 'the deleted row loses its revision row');

      await p21ExpectRevsConsistent(db);
    });
  });

  group('demo delete lives in LocalDb', () {
    test('purgeDemoRows removes the demo versions only, with their revisions',
        () async {
      // Two versions of one day: the older real, the newer demo. The demo
      // provenance stamp names one immutable version, never the whole date.
      await LocalDb.putDayResult(
        dayId: _d1,
        algoVersion: p21Version - 1,
        payloadJson: p21Payload('real', day: _d1),
        windowJson: '{}',
        finalized: true,
        series: {'readiness': 61.0},
        source: 'band',
      );
      await LocalDb.putDayResult(
        dayId: _d2,
        algoVersion: p21Version,
        payloadJson: p21Payload('demo', day: _d2),
        windowJson: '{}',
        finalized: true,
        series: {'readiness': 99.0},
        source: 'demo',
      );
      final realRev = await p21DayRev(db, _d1, p21Version - 1);
      expect(await p21DayRev(db, _d2), greaterThan(0));
      await LocalDb.putSession({
        'id': 'demo-s1',
        'start_ts': 1000,
        'end_ts': 1200,
        'type': 'running',
        'status': 'done',
        'source': 'demo',
        'created_at': 1000000,
      });

      await LocalDb.purgeDemoRows();

      expect(await db.query('day_result', where: 'day_id = ?', whereArgs: [_d2]),
          isEmpty);
      expect(await p21AllRevs(db), {'day_result|$_d1|${p21Version - 1}': realRev},
          reason: 'the demo row lost its revision, the real row kept its own');
      expect(await db.query('metric_series', where: 'date = ?', whereArgs: [_d2]),
          isEmpty);
      expect(
          await db.query('metric_series_version',
              where: 'date = ?', whereArgs: [_d2]),
          isEmpty);
      expect(await db.query('sessions', where: 'id = ?', whereArgs: ['demo-s1']),
          isEmpty);
      expect(await db.query('day_result', where: 'day_id = ?', whereArgs: [_d1]),
          hasLength(1));
    });
  });
}
