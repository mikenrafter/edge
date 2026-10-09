// P2.2 BundleStore read path (design 02 step 2, sections 4.1, 4.2, 4.4).
//
// ASSUMED (lib/data/bundle_store.dart; see test/step2/support/p22_support.dart
// for the full list):
//   * `store.read(source)` = `readOnce` plus one retry on Stale; it answers
//     BundleOk(view, key, asOfMs) | BundleAbsent, or throws BundleRetryable.
//   * A read starts with the payload-free meta (`LocalDb.dayResultMeta`, or the
//     baseline's row_rev + updated_at). Only a miss moves a payload, and the
//     decode runs in the lane (one chunk at a time).
//   * BundleKey = (generation, kind, k1, k2, rev, projection); k2 is the served
//     algo_version for a day, 0 for a baseline.
//   * Bounds: 12 MB LRU of estimated bytes, entries over 1 MB are not cached,
//     chunks of at most 256 KB of source / 8 rows (a larger payload runs alone),
//     at most 16 queued requests and 4 MB of source in flight plus queued; a
//     foreground read over the limit waits `queueWait` (5 s) then throws
//     BundleRetryable; a warm over the limit is refused (WarmRefusedBusy).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/p22_support.dart';

const _name = 'p22_store_read.db';
const _day = '2026-03-10';

String _d(int i) => DateTime.utc(2026, 1, 1 + i).toIso8601String().substring(0, 10);

/// A day payload of about [bytes] source characters (one long string, so the
/// decode is cheap and the estimate small).
String _padded(String tag, int bytes) =>
    jsonEncode({'tag': tag, 'pad': 'x' * bytes});

/// A payload whose estimate is about `24 x numbers` bytes.
String _numbers(String tag, int numbers) =>
    jsonEncode({'tag': tag, 'xs': List<int>.generate(numbers, (i) => i % 10)});

Future<void> _raw(Database db, String day, String payload, {int version = p21Version}) =>
    p21RawDay(db, day, version: version, payload: payload);

String _kind(BundleRead r) => switch (r) {
  BundleOk() => 'ok',
  BundleAbsent() => 'absent',
  BundleStale() => 'stale',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  late P22Lane lane;
  late BundleStore store;
  setUp(() async {
    db = await p21Fresh(_name);
    LocalDb.nowMs = P21Clock(4242).call;
    lane = P22Lane();
    store = p22Store(lane);
  });
  tearDown(() => p21Drop(_name));

  group('meta first', () {
    test('a miss decodes once and answers Ok with its key, revision and as-of',
        () async {
      await p22Put(_day, 'a');
      final rev = await p21DayRev(db, _day);

      final r = await store.read(const BundleSource.day(_day));

      expect(r, isA<BundleOk>());
      final ok = r as BundleOk;
      expect(
        ok.key,
        BundleKey(
          generation: LocalDb.storeGeneration,
          kind: 'day_result',
          k1: _day,
          k2: p21Version,
          rev: rev,
          projection: ProjectionId.full,
        ),
      );
      expect(ok.asOfMs, 4242, reason: 'computed_at of the row');
      expect(ok.view.owned('tag'), 'a');
      expect(lane.sizes, [1]);
      expect(lane.chunks.single.projections, ['full']);
      expect(_kind(r), 'ok');
    });

    test('a hit decodes nothing and shares the cached graph', () async {
      await p22Put(_day, 'a');
      final a = await store.read(const BundleSource.day(_day)) as BundleOk;
      final b = await store.read(const BundleSource.day(_day)) as BundleOk;

      expect(lane.sizes, [1]);
      expect(identical(a.view.debugFrozenRoot, b.view.debugFrozenRoot), isTrue);
      expect(b.key, a.key);
    });

    test('a hit reads no payload: the text changes behind the store\'s back '
        'without a new revision and the cached answer stands', () async {
      await p22Put(_day, 'a');
      await store.read(const BundleSource.day(_day));
      await db.rawUpdate(
        "UPDATE day_result SET payload_json = '{\"tag\":\"sneaky\"}' "
        'WHERE day_id = ?',
        [_day],
      );

      final r = await store.read(const BundleSource.day(_day));

      expect(p22TagOf(r), 'a',
          reason: 'a plain UPDATE keeps the revision, so the entry is valid');
      expect(lane.sizes, [1]);
    });

    test('a replaced row presents another revision: a miss with the new payload',
        () async {
      await p22Put(_day, 'a');
      final first = await store.read(const BundleSource.day(_day)) as BundleOk;
      await p22Put(_day, 'b');

      final second = await store.read(const BundleSource.day(_day)) as BundleOk;

      expect(second.key.rev, greaterThan(first.key.rev));
      expect(second.view.owned('tag'), 'b');
      expect(lane.sizes, [1, 1]);
    });

    test('a deleted row is Absent and the lane is not asked', () async {
      await p22Put(_day, 'a');
      await store.read(const BundleSource.day(_day));
      await LocalDb.deleteDays({_day});

      final r = await store.read(const BundleSource.day(_day));

      expect(r, isA<BundleAbsent>());
      expect((r as BundleAbsent).undecodable, isFalse);
      expect(lane.sizes, [1]);
    });

    test('a day with no row is Absent and nothing is decoded', () async {
      expect(await store.read(const BundleSource.day(_day)), isA<BundleAbsent>());
      expect(lane.chunks, isEmpty);
      expect(store.debugCachedKeys, isEmpty);
    });

    test('an undecodable payload is Absent(undecodable), never an empty bundle, '
        'and a later good write is seen', () async {
      await _raw(db, _day, '{oops');
      final bad = await store.read(const BundleSource.day(_day));
      expect(bad, isA<BundleAbsent>());
      expect((bad as BundleAbsent).undecodable, isTrue);

      await p22Put(_day, 'fixed');
      expect(p22TagOf(await store.read(const BundleSource.day(_day))), 'fixed');
    });

    test('the sealed result is exhaustive over Ok, Absent and Stale', () async {
      await p22Put(_day, 'a');
      final kinds = [
        _kind(await store.read(const BundleSource.day(_day))),
        _kind(await store.read(const BundleSource.day('2000-01-01'))),
      ];
      expect(kinds, ['ok', 'absent']);
    });
  });

  group('baselines', () {
    test('key is (baselines, key, 0, rev); a day and a baseline never share one',
        () async {
      await LocalDb.putBaseline('crossday', '{"tag":"c1"}');
      await p22Put('crossday', 'day-with-the-same-name');
      final rev = await p21BaseRev(db, 'crossday');

      final base = await store.read(const BundleSource.baseline('crossday')) as BundleOk;
      final day = await store.read(const BundleSource.day('crossday')) as BundleOk;

      expect(base.key.kind, 'baselines');
      expect(base.key.k1, 'crossday');
      expect(base.key.k2, 0);
      expect(base.key.rev, rev);
      expect(base.view.owned('tag'), 'c1');
      expect(day.key.kind, 'day_result');
      expect(day.view.owned('tag'), 'day-with-the-same-name');
      expect(store.debugCachedKeys.toSet(), hasLength(2));
      expect(lane.sizes, [1, 1]);
    });

    test('a rewrite is a new revision and a miss; touchBaseline keeps the '
        'entry and the as-of comes fresh from the meta', () async {
      final clock = P21Clock(100);
      LocalDb.nowMs = clock.call;
      await LocalDb.putBaseline('crossday', '{"tag":"c1"}');
      final a = await store.read(const BundleSource.baseline('crossday')) as BundleOk;
      expect(a.asOfMs, 100);

      clock.ms = 200;
      await LocalDb.touchBaseline('crossday');
      final b = await store.read(const BundleSource.baseline('crossday')) as BundleOk;
      expect(b.key, a.key, reason: 'updated_at only: same revision');
      expect(b.asOfMs, 200, reason: 'as-of is never cached with the bundle');
      expect(lane.sizes, [1]);

      clock.ms = 300;
      await LocalDb.putBaseline('crossday', '{"tag":"c2"}');
      final c = await store.read(const BundleSource.baseline('crossday')) as BundleOk;
      expect(c.key.rev, greaterThan(a.key.rev));
      expect(c.view.owned('tag'), 'c2');
      expect(lane.sizes, [1, 1]);
    });

    test('an absent baseline is Absent', () async {
      expect(await store.read(const BundleSource.baseline('crossday')),
          isA<BundleAbsent>());
      expect(lane.chunks, isEmpty);
    });
  });

  group('projections', () {
    test('a projection is its own cache entry with only the three scalars',
        () async {
      await p22Put(_day, 'a');
      await store.read(const BundleSource.day(_day));

      final p = await store.project(
        const BundleSource.day(_day),
        ProjectionId.cycleScalars,
      ) as BundleOk;

      expect(p.key.projection, ProjectionId.cycleScalars);
      expect(p.view.owned('scalars'), {'rhr': 50.0, 'rmssd': 60.0, 'skin_temp_z': -0.25});
      expect(p.view.owned('series'), isNull);
      expect(p.view.owned('tag'), isNull);
      expect(lane.sizes, [1, 1], reason: 'the full entry does not answer it');
      expect(lane.chunks.last.projections, ['cycleScalars']);
      expect(
        store.debugCachedKeys.map((k) => k.projection).toSet(),
        {ProjectionId.full, ProjectionId.cycleScalars},
      );
      // and the other way round: a cached projection never answers a full read.
      final again = await store.read(const BundleSource.day(_day)) as BundleOk;
      expect(again.view.owned('tag'), 'a');
      expect(lane.sizes, [1, 1], reason: 'the full entry is still cached');
    });

    test('a projection flight never answers a full read', () async {
      await p22Put(_day, 'a');
      lane.holdAll = true;

      final p = store.project(
        const BundleSource.day(_day),
        ProjectionId.cycleScalars,
      );
      await lane.arrived(1);
      final f = store.read(const BundleSource.day(_day));
      await p22Until(() => store.debugFlightCount == 2,
          'the full read registers its own flight');
      lane.releaseAll();

      final pr = await p as BundleOk;
      final fr = await f as BundleOk;
      expect(pr.view.owned('tag'), isNull);
      expect(fr.view.owned('tag'), 'a', reason: 'the whole bundle, not scalars');
      expect(lane.chunks.map((c) => c.projections.single).toList(),
          ['cycleScalars', 'full']);
    });

    test('a projection keeps a present zero and leaves an absent scalar absent',
        () async {
      await _raw(db, _day,
          jsonEncode({'scalars': {'rhr': 0.0, 'rmssd': -3}, 'sleep': {'x': 1}}));
      final p = await store.project(
        const BundleSource.day(_day),
        ProjectionId.cycleScalars,
      ) as BundleOk;
      final sc = (p.view.owned('scalars') as Map);
      expect(sc['rhr'], 0.0);
      expect(sc['rmssd'], -3);
      expect(sc.containsKey('skin_temp_z'), isFalse, reason: 'never a default');
    });
  });

  group('readAll and chunking', () {
    test('results keep request order; absent sources are Absent and not sent',
        () async {
      for (var i = 0; i < 5; i++) {
        await p22Put(_d(i), 't$i', payload: p22Tiny('t$i', day: _d(i)));
      }
      final out = await store.readAll([
        BundleSource.day(_d(0)),
        BundleSource.day('2000-01-01'),
        BundleSource.day(_d(1)),
        BundleSource.day(_d(2)),
        BundleSource.day('2000-01-02'),
        BundleSource.day(_d(3)),
        BundleSource.day(_d(4)),
      ], chunkRows: 3);

      expect(out.map(_kind).toList(),
          ['ok', 'absent', 'ok', 'ok', 'absent', 'ok', 'ok']);
      expect([for (final r in out) if (r is BundleOk) r.view.owned('tag')],
          ['t0', 't1', 't2', 't3', 't4']);
      expect(lane.sizes, [3, 2], reason: 'five present payloads, at most 3 per call');
    });

    test('a cached source is not sent again', () async {
      for (var i = 0; i < 3; i++) {
        await p22Put(_d(i), 't$i');
      }
      await store.read(BundleSource.day(_d(0)));
      await store.readAll([for (var i = 0; i < 3; i++) BundleSource.day(_d(i))]);
      expect(lane.payloads, 3, reason: 'one earlier + the two that were missing');
    });

    test('by default a chunk holds at most 8 payloads', () async {
      for (var i = 0; i < 10; i++) {
        await p22Put(_d(i), 't$i');
      }
      await store.readAll([for (var i = 0; i < 10; i++) BundleSource.day(_d(i))]);
      expect(lane.sizes, [8, 2]);
    });

    test('a chunk is cut at 256 KB of source text', () async {
      for (var i = 0; i < 4; i++) {
        await _raw(db, _d(i), _padded('p$i', 100 * 1024));
      }
      await store.readAll([for (var i = 0; i < 4; i++) BundleSource.day(_d(i))]);
      expect(lane.sizes, [2, 2], reason: '2 x 100 KB fits, a third would not');
    });

    test('a payload bigger than the budget runs alone, and is not refused',
        () async {
      for (var i = 0; i < 3; i++) {
        await _raw(db, _d(i), _padded('p$i', 300 * 1024));
      }
      final out = await store.readAll([for (var i = 0; i < 3; i++) BundleSource.day(_d(i))]);
      expect(lane.sizes, [1, 1, 1]);
      expect(out.map(_kind), everyElement('ok'));
    });
  });

  group('warm', () {
    test('warm fills the cache; the later read decodes nothing', () async {
      for (var i = 0; i < 3; i++) {
        await p22Put(_d(i), 't$i');
      }
      final w = await store.warm([for (var i = 0; i < 3; i++) BundleSource.day(_d(i))]);
      expect(w, isA<WarmDone>());
      expect((w as WarmDone).decoded, 3);
      final before = lane.payloads;

      expect(p22TagOf(await store.read(BundleSource.day(_d(1)))), 't1');
      expect(lane.payloads, before);
    });

    test('warming an absent day is a no-op, not a failure', () async {
      final w = await store.warm(const [BundleSource.day('2000-01-01')]);
      expect(w, isA<WarmDone>());
      expect((w as WarmDone).decoded, 0);
      expect(lane.chunks, isEmpty);
    });
  });

  group('byte bounds', () {
    test('the cache stays under its byte budget and drops the least recently '
        'used entry first', () async {
      const n = 40;
      for (var i = 0; i < n; i++) {
        await _raw(db, _d(i), _numbers('n$i', 15000));
      }
      await store.readAll([for (var i = 0; i < n; i++) BundleSource.day(_d(i))]);

      expect(store.debugCacheBytes, lessThanOrEqualTo(BundleStore.cacheByteBudget));
      expect(store.debugCacheBytes, greaterThan(BundleStore.cacheByteBudget ~/ 2),
          reason: 'it should actually be using the budget');
      final cached = store.debugCachedKeys.map((k) => k.k1).toSet();
      expect(cached, contains(_d(n - 1)));
      expect(cached, isNot(contains(_d(0))));
      final before = lane.payloads;
      await store.read(BundleSource.day(_d(0)));
      expect(lane.payloads, before + 1, reason: 'the evicted day is decoded again');
    });

    test('an entry estimated over 1 MB is returned once and never cached',
        () async {
      await _raw(db, _day, _numbers('huge', 60000));

      final a = await store.read(const BundleSource.day(_day));
      expect(p22TagOf(a), 'huge');
      expect(store.debugCachedKeys, isEmpty);
      expect(store.debugCacheBytes, 0);
      expect((a as BundleOk).view.estimatedBytes,
          greaterThan(BundleStore.oversizeBytes));

      await store.read(const BundleSource.day(_day));
      expect(lane.sizes, [1, 1]);
    });

    test('a foreground read waits 5 seconds by default', () {
      expect(BundleStore(lane: lane).queueWait, const Duration(seconds: 5));
    });

    test('more than 16 queued requests: the extra foreground reads fail as '
        'retryable, they are never answered Absent', () async {
      const n = 40;
      for (var i = 0; i < n; i++) {
        await p22Put(_d(i), 't$i');
      }
      store = p22Store(lane, queueWait: Duration.zero);
      lane.holdAll = true;

      final failed = <Object>[];
      final done = <BundleRead>[];
      final all = [
        for (var i = 0; i < n; i++)
          store.read(BundleSource.day(_d(i))).then<void>(done.add, onError: failed.add),
      ];
      await lane.arrived(1);
      await p22Until(() => failed.length >= n - (BundleStore.maxQueuedRequests + 1),
          'the over-limit reads give up');
      expect(failed, everyElement(isA<BundleRetryable>()));
      expect(failed.length, lessThanOrEqualTo(n - BundleStore.maxQueuedRequests));

      // a warm never waits: over the limits it is refused outright.
      final w = await store.warm([BundleSource.day(_d(n - 1))]);
      expect(w, isA<WarmRefusedBusy>());

      lane.releaseAll();
      await Future.wait(all);
      expect(done.map(_kind), everyElement('ok'));
      expect(done.length + failed.length, n);
      expect(done.length, inInclusiveRange(BundleStore.maxQueuedRequests, BundleStore.maxQueuedRequests + 1));
    });

    test('a foreground read is decoded before a warm that queued earlier',
        () async {
      for (var i = 0; i < 3; i++) {
        await p22Put(_d(i), 't$i');
      }
      lane.holdAll = true;
      final running = store.read(BundleSource.day(_d(0)));
      await lane.arrived(1);
      final warm = store.warm([BundleSource.day(_d(1))]);
      await p22Flush(db);
      final foreground = store.read(BundleSource.day(_d(2)));
      await p22Flush(db);
      lane.releaseAll();
      await Future.wait([running, warm, foreground]);

      expect(lane.sizes, [1, 1, 1]);
      expect(lane.chunks[1].payloadJson.single, contains('"tag":"t2"'),
          reason: 'the foreground read goes second');
      expect(lane.chunks[2].payloadJson.single, contains('"tag":"t1"'),
          reason: 'the warm goes last');
    });

    test('more than 4 MB of source in flight plus queued: the reads over it '
        'fail as retryable', () async {
      for (var i = 0; i < 4; i++) {
        await _raw(db, _d(i), _padded('big$i', 1400 * 1024));
      }
      store = p22Store(lane, queueWait: Duration.zero);
      lane.holdAll = true;

      final failed = <Object>[];
      final done = <BundleRead>[];
      final all = [
        for (var i = 0; i < 4; i++)
          store.read(BundleSource.day(_d(i))).then<void>(done.add, onError: failed.add),
      ];
      await lane.arrived(1);
      await p22Until(() => failed.length >= 2, 'the third and fourth give up');
      expect(failed, everyElement(isA<BundleRetryable>()));

      lane.releaseAll();
      await Future.wait(all);
      expect(failed, hasLength(2), reason: '2 x 1.4 MB fit in 4 MB, a third does not');
      expect(done, hasLength(2));
    });
  });
}
