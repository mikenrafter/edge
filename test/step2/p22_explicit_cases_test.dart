// P2.2 "Explicit cases (each is a P2.2 test)", design 02 step 2, section 4.2.
// One group per row of that table, in table order.
//
// ASSUMED: see p22_bundle_store_read_test.dart. `store.read` is meta-first, so
// every row below is decided by what the database says about (kind, k1, k2,
// rev) and the generation at the moment of the read, never by a callback.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';

import '../support/dart_source.dart';
import 'support/p22_support.dart';

const _name = 'p22_explicit.db';
const _other = 'p22_explicit_other.db';
const _foreign = 'p22_explicit_foreign.db';
const _day = '2026-03-10';
const _y = '2026-03-11';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  late P22Lane lane;
  late BundleStore store;
  setUp(() async {
    db = await p21Fresh(_name);
    lane = P22Lane();
    store = p22Store(lane);
  });
  tearDown(() async {
    await p21Drop(_name);
    await databaseFactory.deleteDatabase(await p21Path(_other));
    await databaseFactory.deleteDatabase(await p21Path(_foreign));
  });

  Future<BundleOk> read(String day) async =>
      await store.read(BundleSource.day(day)) as BundleOk;

  group('accepted override or import replacement', () {
    test('a user override of a finalized row at an EQUAL timestamp is a miss',
        () async {
      LocalDb.nowMs = P21Clock(7777).call;
      await p22Put(_day, 'derived', finalized: true);
      final a = await read(_day);

      final ok = await p22Put(_day, 'override',
          finalized: true, reason: DayResultWrite.userOverride);
      expect(ok, isTrue);
      final b = await read(_day);

      expect(a.asOfMs, 7777);
      expect(b.asOfMs, 7777, reason: 'same millisecond: computed_at cannot tell');
      expect(b.key.rev, greaterThan(a.key.rev));
      expect(b.view.owned('tag'), 'override');
      expect(lane.sizes, [1, 1]);
    });

    test('an import over a non-measured row at an equal timestamp is a miss',
        () async {
      LocalDb.nowMs = P21Clock(7777).call;
      await LocalDb.putDayResult(
        dayId: _day,
        algoVersion: p21Version,
        payloadJson: p22Tiny('skip'),
        windowJson: '{}',
        finalized: true,
        skipped: true,
      );
      final a = await read(_day);

      final accepted = await LocalDb.putDayResult(
        dayId: _day,
        algoVersion: p21Version,
        payloadJson: p21ImportPayload('import'),
        windowJson: '{}',
        finalized: true,
      );
      expect(accepted, isTrue);
      final b = await read(_day);

      expect(b.key.rev, greaterThan(a.key.rev));
      expect(b.view.owned('tag'), 'import');
      expect(lane.sizes, [1, 1]);
    });
  });

  group('value-identical re-encode', () {
    test('keeps the revision: the retained decode stays valid and still reads '
        'the same curve', () async {
      await p21RawDay(
        db,
        _day,
        version: 47,
        finalized: true,
        payload: jsonEncode(p21LegacyBundle(1783572180)),
      );
      final a = await read(_day);
      final curveBefore = a.view.curve('series.hr_curve');
      expect(curveBefore, isA<List>());

      expect(await LocalDb.reencodeLegacyDayResults(), 1);
      final b = await read(_day);

      expect(b.key, a.key, reason: 'same row, same revision');
      expect(lane.sizes, [1], reason: 'a hit: nothing was decoded again');
      expect(b.view.curve('series.hr_curve'), curveBefore);
    });
  });

  group('algo bump and rollback', () {
    test('the key carries the served row\'s algo_version; a row above the '
        'ceiling is never served; an older row still is', () async {
      Future<void> row(int version, String tag) =>
          p21RawDay(db, _day, version: version, payload: p22Tiny(tag, day: _day));

      await row(p21Version - 1, 'old');
      final old = await read(_day);
      expect(old.key.k2, p21Version - 1);
      expect(old.view.owned('tag'), 'old');

      await row(p21Version, 'current'); // the bump: a new sibling row
      final cur = await read(_day);
      expect(cur.key.k2, p21Version);
      expect(cur.view.owned('tag'), 'current');
      expect(lane.sizes, [1, 1]);

      await row(p21Version + 1, 'future'); // a newer build's row: not served
      final still = await read(_day);
      expect(still.key, cur.key);
      expect(still.view.owned('tag'), 'current');
      expect(lane.sizes, [1, 1], reason: 'a hit; the future row changed nothing');

      // rollback: the current row goes away, the older sibling is served again
      await db.delete('day_result',
          where: 'day_id = ? AND algo_version = ?', whereArgs: [_day, p21Version]);
      final back = await read(_day);
      expect(back.key.k2, p21Version - 1);
      expect(back.view.owned('tag'), 'old');
    });
  });

  group('deleteDays (direct call, no generation bump)', () {
    test('the meta read finds no row: Absent, and the generation never moved',
        () async {
      await p22Put(_day, 'a');
      await read(_day);
      final gen = LocalDb.storeGeneration;

      await LocalDb.deleteDays({_day});

      expect(LocalDb.storeGeneration, gen, reason: 'deleteDays does not bump');
      expect(await store.read(const BundleSource.day(_day)), isA<BundleAbsent>());
    });

    test('a flight started earlier answers nobody with the deleted data: its '
        'starter and a joiner get Stale, the cache stays empty, a later reader '
        'is Absent', () async {
      await p22Put(_day, 'a');
      lane.holdAll = true;

      final starter = store.readOnce(const BundleSource.day(_day));
      await lane.arrived(1);
      final joiner = store.readOnce(const BundleSource.day(_day));
      await p22Flush(db);
      expect(store.debugFlightCount, 1, reason: 'the joiner joined');

      await LocalDb.deleteDays({_day});
      lane.releaseAll();

      expect(await starter, isA<BundleStale>());
      expect(await joiner, isA<BundleStale>());
      expect(store.debugCachedKeys, isEmpty);
      expect(await store.read(const BundleSource.day(_day)), isA<BundleAbsent>());
      expect(lane.sizes, [1], reason: 'one decode served the whole story');
    });
  });

  group('raw prune', () {
    test('day bundles stay cached: their durable source survives', () async {
      await p22Put(_day, 'a');
      final a = await read(_day);
      final gen = LocalDb.storeGeneration;

      await LocalDb.pruneDecodedBeforeRecTs(4102444800); // year 2100: everything

      expect(LocalDb.storeGeneration, gen);
      final b = await read(_day);
      expect(b.key, a.key);
      expect(lane.sizes, [1], reason: 'still a hit');
    });
  });

  group('device selection', () {
    test('no device in the key or the source: bundles are canonical merged '
        'results', () async {
      await p22Put(_day, 'a');
      final key = (await read(_day)).key;
      expect(key.toString().toLowerCase(), isNot(contains('device')));

      final code = stripCommentsAndStrings(
        File('lib/data/bundle_store.dart').readAsStringSync(),
      );
      expect(RegExp('device', caseSensitive: false).hasMatch(code), isFalse,
          reason: 'any per-device cache must carry the device id elsewhere; '
              'none is added in step 2');
    });
  });

  group('wipe, reopen, rebuild', () {
    test('wipeAll then the identical content again: a new generation, a new '
        'revision, a miss', () async {
      await p22Put(_day, 'a');
      final a = await read(_day);

      await LocalDb.wipeAll();
      await p22Put(_day, 'a');
      final b = await read(_day);

      expect(b.key.generation, isNot(a.key.generation));
      expect(b.key.rev, greaterThan(a.key.rev), reason: 'revisions are not reused');
      expect(b.key, isNot(a.key));
      expect(lane.sizes, [1, 1]);
    });

    test('a plain reopen keeps the row and the revision but changes the '
        'generation: the old entry does not answer', () async {
      await p22Put(_day, 'a');
      final a = await read(_day);

      await p21Reopen();
      final b = await read(_day);

      expect(b.key.rev, a.key.rev);
      expect(b.key.generation, isNot(a.key.generation));
      expect(lane.sizes, [1, 1]);
    });

    test('a different database file with the SAME (day, version, rev): only '
        'the generation tells them apart', () async {
      await p22Put(_day, 'file-a');
      final a = await read(_day);

      await p21Fresh(_other);
      final dbB = await LocalDb.instance;
      await p22Put(_day, 'file-b');
      final b = await read(_day);

      expect(await p21DayRev(dbB, _day), a.key.rev,
          reason: 'precondition: a fresh sequence reuses the number');
      expect(b.view.owned('tag'), 'file-b', reason: 'not the other file\'s decode');
      expect(b.key.generation, isNot(a.key.generation));
      expect(lane.sizes, [1, 1]);
    });
  });

  group('restore and merge', () {
    test('every replaced row presents a new revision; a locally finalized row '
        'the merge skips keeps its own', () async {
      await p22Put(_day, 'local-x');
      await p22Put(_y, 'local-y', finalized: true);
      final x0 = await read(_day);
      final y0 = await read(_y);
      final src = await p21MakeForeignExport(
        _foreign,
        days: [
          (day: _day, version: p21Version, tag: 'foreign-x', finalized: false),
          (day: _y, version: p21Version, tag: 'foreign-y', finalized: false),
        ],
      );

      await LocalDb.importFromDbFile(src);
      final x1 = await read(_day);
      final y1 = await read(_y);

      expect(x1.view.owned('tag'), 'foreign-x');
      expect(x1.key.rev, greaterThan(x0.key.rev));
      expect(x1.key.rev, lessThan(p21ForeignRevBase), reason: 'a local number');
      expect(y1.view.owned('tag'), 'local-y', reason: 'finalized: skipped');
      expect(y1.key.rev, y0.key.rev, reason: 'the skipped row keeps its revision');
      expect(y1.key.generation, isNot(y0.key.generation),
          reason: 'but the merge crossed a generation, so it is decoded again');
      expect(lane.sizes, [1, 1, 1, 1]);
    });
  });
}
