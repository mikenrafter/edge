// P2.1 meta-first reads, design 02 step 2, section 4.1.
//
// ASSUMED (lib/data/db.dart, lib/data/day_payload_read.dart):
//
//   * `LocalDb.dayResultMeta(day)` returns the served row for [day] (highest
//     `algo_version` at or below `_servedAlgoCeiling`, the same pick as
//     `LocalDb.dayResult`) WITHOUT `payload_json`, with every other column and
//     `rev` = `COALESCE(row_rev.rev, 0)`. A `date` alias like the other
//     `day_result` readers is allowed. Null when no served row exists.
//   * `LocalDb.dayPayload(day, version, expectedRev: r)` reads exactly that
//     (day, version) and answers with the sealed `DayPayloadRead`:
//       `DayPayloadOk(payloadJson, rev)` when the row's revision equals r,
//       `DayPayloadStale(currentRev)` when the row exists at another revision,
//       `DayPayloadAbsent` when there is no such row.
//     `payloadJson` is the stored text, byte for byte.
//   * "As of" fields (`computed_at`) come fresh from the meta on every call.
//
// Rows are seeded through `putDayResult` or raw inserts; `LocalDb.nowMs` is
// frozen where the clock matters.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_payload_read.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/p21_support.dart';

const _name = 'p21_meta_payload_reads.db';
const _day = '2026-03-10';

Future<bool> _put(
  String day,
  String tag, {
  int version = p21Version,
  bool finalized = false,
  DayResultWrite reason = DayResultWrite.derive,
}) => LocalDb.putDayResult(
  dayId: day,
  algoVersion: version,
  payloadJson: p21Payload(tag, day: day),
  windowJson: '{"w":"$tag"}',
  finalized: finalized,
  partial: true,
  rhr: 51.5,
  rmssd: 42.5,
  readiness: 73.5,
  reason: reason,
);

Future<String> _storedPayload(Database db, String day, int version) async =>
    (await db.query(
      'day_result',
      columns: ['payload_json'],
      where: 'day_id = ? AND algo_version = ?',
      whereArgs: [day, version],
    )).single['payload_json'] as String;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async => db = await p21Fresh(_name));
  tearDown(() => p21Drop(_name));

  group('dayResultMeta', () {
    test('null for a day with no row', () async {
      expect(await LocalDb.dayResultMeta(_day), isNull);
    });

    test('every column except payload_json, plus rev', () async {
      LocalDb.nowMs = P21Clock(4242).call;
      await _put(_day, 'a', finalized: true);

      final meta = await LocalDb.dayResultMeta(_day);

      expect(meta, isNotNull);
      expect(meta!.containsKey('payload_json'), isFalse,
          reason: 'the meta read must not move the payload');
      expect(meta['day_id'], _day);
      expect(meta['algo_version'], p21Version);
      expect(meta['computed_at'], 4242);
      expect(meta['finalized'], 1);
      expect(meta['skipped'], 0);
      expect(meta['partial'], 1);
      expect(meta['rhr'], 51.5);
      expect(meta['rmssd'], 42.5);
      expect(meta['readiness'], 73.5);
      expect(meta['window_json'], '{"w":"a"}');
      expect(meta['rev'], await p21DayRev(db, _day));
      expect(meta['rev'], greaterThan(0));
    });

    test('computed_at is read fresh: it follows the latest write', () async {
      final clock = P21Clock(1000);
      LocalDb.nowMs = clock.call;
      await _put(_day, 'a');
      expect((await LocalDb.dayResultMeta(_day))!['computed_at'], 1000);
      clock.ms = 2000;
      await _put(_day, 'b');
      final meta = (await LocalDb.dayResultMeta(_day))!;
      expect(meta['computed_at'], 2000);
      expect(meta['window_json'], '{"w":"b"}');
    });

    test('rev changes with every accepted write, also inside one millisecond',
        () async {
      LocalDb.nowMs = P21Clock(1000).call;
      await _put(_day, 'a');
      final r1 = (await LocalDb.dayResultMeta(_day))!['rev'];
      await _put(_day, 'b');
      final r2 = (await LocalDb.dayResultMeta(_day))!['rev'];
      expect(r2, isNot(r1));
      expect(r2 as int, greaterThan(r1 as int));
    });

    test('serves the highest version at or below the ceiling, with that '
        "row's own revision", () async {
      await p21RawDay(db, _day, version: p21Version - 5);
      await p21RawDay(db, _day, version: p21Version - 2);
      await p21RawDay(db, _day, version: p21Version + 1);

      final meta = (await LocalDb.dayResultMeta(_day))!;

      expect(meta['algo_version'], p21Version - 2);
      expect(meta['rev'], await p21DayRev(db, _day, p21Version - 2));
      expect(meta['rev'], isNot(await p21DayRev(db, _day, p21Version - 5)));
      expect(meta['rev'], isNot(await p21DayRev(db, _day, p21Version + 1)));
    });

    test('a row above the ceiling is never served, even alone', () async {
      await p21RawDay(db, _day, version: p21Version + 1);
      expect(await LocalDb.dayResultMeta(_day), isNull);
      expect(await LocalDb.dayResult(_day), isNull,
          reason: 'same pick as the existing full-row reader');
    });

    test('an older version is still served when it is the only one', () async {
      await p21RawDay(db, _day, version: p21Version - 7);
      expect((await LocalDb.dayResultMeta(_day))!['algo_version'], p21Version - 7);
    });

    test('a row written before schema 71 (no row_rev row) reads revision 0',
        () async {
      await p21RawDay(db, _day);
      await p21ExpectRevTables(db);
      await db.delete('row_rev');
      expect((await LocalDb.dayResultMeta(_day))!['rev'], 0);
      await _put(_day, 'after');
      expect((await LocalDb.dayResultMeta(_day))!['rev'], greaterThan(0));
    });

    test('the same pick as dayResult for the same day', () async {
      await p21RawDay(db, _day, version: p21Version - 3, finalized: true);
      await p21RawDay(db, _day, version: p21Version - 1);
      final full = (await LocalDb.dayResult(_day))!;
      final meta = (await LocalDb.dayResultMeta(_day))!;
      for (final k in const [
        'day_id',
        'algo_version',
        'computed_at',
        'finalized',
        'skipped',
        'partial',
        'rhr',
        'rmssd',
        'readiness',
        'window_json',
      ]) {
        expect(meta[k], full[k], reason: k);
      }
    });
  });

  group('dayPayload', () {
    test('Ok: the stored text, byte for byte, at the expected revision',
        () async {
      await _put(_day, 'a');
      final meta = (await LocalDb.dayResultMeta(_day))!;

      final read = await LocalDb.dayPayload(
        _day,
        meta['algo_version'] as int,
        expectedRev: meta['rev'] as int,
      );

      expect(read, isA<DayPayloadOk>());
      final ok = read as DayPayloadOk;
      expect(ok.payloadJson, await _storedPayload(db, _day, p21Version));
      expect(ok.rev, meta['rev']);
    });

    test('Stale: a replace landed after the meta read; the answer names the '
        'new revision and a restart from the meta then succeeds', () async {
      LocalDb.nowMs = P21Clock(1000).call;
      await _put(_day, 'first');
      final first = (await LocalDb.dayResultMeta(_day))!;
      await _put(_day, 'second'); // same millisecond, new revision

      final read = await LocalDb.dayPayload(
        _day,
        p21Version,
        expectedRev: first['rev'] as int,
      );

      expect(read, isA<DayPayloadStale>());
      final fresh = (await LocalDb.dayResultMeta(_day))!;
      expect((read as DayPayloadStale).currentRev, fresh['rev']);
      expect(read.currentRev, isNot(first['rev']));

      final again = await LocalDb.dayPayload(
        _day,
        p21Version,
        expectedRev: fresh['rev'] as int,
      );
      expect(again, isA<DayPayloadOk>());
      expect((again as DayPayloadOk).payloadJson,
          await _storedPayload(db, _day, p21Version));
    });

    test('Absent: the row was deleted after the meta read', () async {
      await _put(_day, 'a');
      final meta = (await LocalDb.dayResultMeta(_day))!;
      await LocalDb.deleteDays({_day});
      final read = await LocalDb.dayPayload(
        _day,
        p21Version,
        expectedRev: meta['rev'] as int,
      );
      expect(read, isA<DayPayloadAbsent>());
    });

    test('Absent: no such row ever', () async {
      expect(
        await LocalDb.dayPayload('1999-01-01', p21Version, expectedRev: 0),
        isA<DayPayloadAbsent>(),
      );
    });

    test('Absent after a wipe, and a reinsert is Stale against the old '
        'revision, never Ok', () async {
      await _put(_day, 'a');
      final old = (await LocalDb.dayResultMeta(_day))!['rev'] as int;
      await LocalDb.wipeAll();
      expect(
        await LocalDb.dayPayload(_day, p21Version, expectedRev: old),
        isA<DayPayloadAbsent>(),
      );
      await _put(_day, 'reinserted');
      expect(
        await LocalDb.dayPayload(_day, p21Version, expectedRev: old),
        isA<DayPayloadStale>(),
        reason: 'a revision is never reused, so the old one cannot match',
      );
    });

    test('reads exactly the (day, version) asked for, not the served one',
        () async {
      await _put(_day, 'old', version: p21Version - 4);
      await _put(_day, 'new');
      final rev = await p21DayRev(db, _day, p21Version - 4);
      final read = await LocalDb.dayPayload(
        _day,
        p21Version - 4,
        expectedRev: rev,
      );
      expect(read, isA<DayPayloadOk>());
      expect((read as DayPayloadOk).payloadJson,
          await _storedPayload(db, _day, p21Version - 4));
    });

    test('a revision-0 row (written before schema 71) is Ok at expectedRev 0',
        () async {
      await p21RawDay(db, _day);
      await p21ExpectRevTables(db);
      await db.delete('row_rev');
      final read = await LocalDb.dayPayload(_day, p21Version, expectedRev: 0);
      expect(read, isA<DayPayloadOk>());
      expect((read as DayPayloadOk).rev, 0);
    });
  });
}
