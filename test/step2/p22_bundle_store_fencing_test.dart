// P2.2 flights, post-worker fence, wipe ordering (design 02 step 2, 4.2).
//
// ASSUMED (lib/data/bundle_store.dart):
//   * A flight is registered before its decode starts, is identified by the
//     full key INCLUDING the generation, and is removed on completion only if
//     `identical(_flights[key], thisFlight)`.
//   * After the worker returns and BEFORE the result is cached or returned, the
//     store re-reads (kind, k1, k2, rev) from `row_rev` and the current
//     `storeGeneration`; any difference makes the completion BundleStale: it
//     neither fills the cache nor answers the starter or any joiner.
//   * `readOnce` surfaces that Stale. `read` re-reads the meta once; a second
//     Stale throws BundleRetryable. A row that is gone by then is an honest
//     Absent, never a retryable error and never a made-up empty bundle.
//   * `invalidateDays` / `invalidateAll` only evict and detach flights nobody
//     may join any more; correctness never depends on them being called.
//
// Interleavings are placed with P22Lane: the lane records a chunk, runs the
// test's hook (a DB commit) and only then returns the decode, so the commit
// lands "between dispatch and completion" with no timing involved.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/p22_support.dart';

const _name = 'p22_fencing.db';
const _day = '2026-03-10';
const _src = BundleSource.day(_day);

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
  tearDown(() => p21Drop(_name));

  group('flights', () {
    test('concurrent reads of one key share one decode and one view', () async {
      await p22Put(_day, 'a');
      lane.holdAll = true;

      final a = store.read(_src);
      await lane.arrived(1);
      final b = store.read(_src);
      await p22Flush(db);
      expect(store.debugFlightCount, 1, reason: 'the second joined the first');
      lane.releaseAll();

      final ra = await a as BundleOk;
      final rb = await b as BundleOk;
      expect(lane.sizes, [1]);
      expect(identical(ra.view.debugFrozenRoot, rb.view.debugFrozenRoot), isTrue);
    });

    test('a finished flight is removed', () async {
      await p22Put(_day, 'a');
      await store.read(_src);
      expect(store.debugFlightCount, 0);
    });

    test('a flight is removed on failure too (a lane that throws)', () async {
      await p22Put(_day, 'a');
      lane.hook = (_, _) async => throw StateError('boom');
      await expectLater(store.read(_src), throwsA(isA<StateError>()));
      expect(store.debugFlightCount, 0);
      expect(store.debugCachedKeys, isEmpty);

      lane.hook = null;
      expect(p22TagOf(await store.read(_src)), 'a', reason: 'the key is usable again');
    });

    test('removal is conditional: a detached flight finishing must not remove '
        'the flight that replaced it', () async {
      await p22Put(_day, 'a');
      lane.holdAll = true;

      final first = store.readOnce(_src); // flight A
      await lane.arrived(1);
      store.invalidateAll(); // A is detached: no future read may join it
      final before = store.debugFlightCount;
      final second = store.readOnce(_src); // flight B, same key
      await p22Until(() => store.debugFlightCount > before, 'flight B registered');

      lane.release(0); // A finishes first (one lane: B has not even started)
      expect(await first, isA<BundleStale>(), reason: 'A was detached');
      await lane.arrived(2); // B reaches the lane only after A is done
      await Future<void>.delayed(Duration.zero);
      expect(store.debugFlightCount, 1, reason: 'B is still registered');

      final third = store.readOnce(_src); // must join B, not start a third decode
      await p22Flush(db);
      lane.releaseAll();
      expect(await second, isA<BundleOk>());
      expect(await third, isA<BundleOk>());
      expect(lane.sizes, [1, 1], reason: 'two decodes in total, no third flight');
    });

    test('a read after invalidateDays does not join the detached flight',
        () async {
      await p22Put(_day, 'a');
      lane.holdAll = true;
      final first = store.readOnce(_src);
      await lane.arrived(1);

      store.invalidateDays([_day]);
      final second = store.readOnce(_src);
      await p22Flush(db);
      lane.releaseAll();

      expect(await first, isA<BundleStale>());
      expect(await second, isA<BundleOk>());
      expect(lane.sizes, [1, 1]);
    });

    test('invalidateDays and invalidateAll only evict: the next read decodes '
        'again and gets the same answer', () async {
      await p22Put(_day, 'a');
      await p22Put('2026-03-11', 'b');
      await store.read(_src);
      await store.read(const BundleSource.day('2026-03-11'));
      expect(store.debugCachedKeys, hasLength(2));

      store.invalidateDays([_day]);
      expect(store.debugCachedKeys.map((k) => k.k1), ['2026-03-11']);
      expect(p22TagOf(await store.read(_src)), 'a');
      expect(lane.sizes, [1, 1, 1]);

      store.invalidateAll();
      expect(store.debugCachedKeys, isEmpty);
      expect(store.debugCacheBytes, 0);
    });

    test('missing an invalidation costs memory, never a stale answer', () async {
      await p22Put(_day, 'a');
      await store.read(_src);
      await p22Put(_day, 'b'); // nobody told the store
      expect(p22TagOf(await store.read(_src)), 'b');
    });
  });

  group('post-worker fence', () {
    Future<void> replaceNow(int i, DecodeChunkInput c) async {
      await p22Put(_day, 'replaced', reason: DayResultWrite.userOverride);
    }

    test('a replace between dispatch and completion: Stale, not cached', () async {
      await p22Put(_day, 'a');
      lane.hook = replaceNow;

      final r = await store.readOnce(_src);

      expect(r, isA<BundleStale>());
      expect(store.debugCachedKeys, isEmpty, reason: 'the stale decode is not kept');
      expect(store.debugFlightCount, 0);
      lane.hook = null;
      expect(p22TagOf(await store.read(_src)), 'replaced');
    });

    test('a replace AND a delete between dispatch and completion: Stale', () async {
      await p22Put(_day, 'a');
      lane.hook = (i, c) async {
        await p22Put(_day, 'replaced', reason: DayResultWrite.userOverride);
        await LocalDb.deleteDays({_day});
      };

      expect(await store.readOnce(_src), isA<BundleStale>());
      expect(store.debugCachedKeys, isEmpty);
      lane.hook = null;
      expect(await store.read(_src), isA<BundleAbsent>());
    });

    test('the stale completion answers neither the starter nor any joiner',
        () async {
      await p22Put(_day, 'a');
      lane.holdAll = true;
      final starter = store.readOnce(_src);
      await lane.arrived(1);
      final joiner = store.readOnce(_src);
      await p22Flush(db);

      await p22Put(_day, 'replaced', reason: DayResultWrite.userOverride);
      lane.releaseAll();

      expect(await starter, isA<BundleStale>());
      expect(await joiner, isA<BundleStale>());
      expect(store.debugCachedKeys, isEmpty);
    });

    test('read re-reads the meta once after a Stale and answers the new row',
        () async {
      await p22Put(_day, 'a');
      lane.hook = (i, c) async {
        if (i == 0) await p22Put(_day, 'replaced', reason: DayResultWrite.userOverride);
      };

      final r = await store.read(_src);

      expect(p22TagOf(r), 'replaced');
      expect(lane.sizes, [1, 1], reason: 'one stale decode, one good one');
      expect(store.debugCachedKeys.single.rev, (r as BundleOk).key.rev);
    });

    test('a second Stale in a row is a retryable error, never an empty state',
        () async {
      await p22Put(_day, 'a');
      var n = 0;
      lane.hook = (i, c) async {
        await p22Put(_day, 'again${n++}', reason: DayResultWrite.userOverride);
      };

      await expectLater(store.read(_src), throwsA(isA<BundleRetryable>()));
      expect(lane.sizes, [1, 1], reason: 'exactly one retry');
      expect(store.debugCachedKeys, isEmpty);
      expect(store.debugFlightCount, 0);
    });

    test('a row deleted during the decode reads as honest absence on the retry',
        () async {
      await p22Put(_day, 'a');
      lane.hook = (i, c) async => LocalDb.deleteDays({_day});

      final r = await store.read(_src);

      expect(r, isA<BundleAbsent>());
      expect((r as BundleAbsent).undecodable, isFalse);
    });

    test('readAll: one source going stale does not poison the others', () async {
      await p22Put(_day, 'a');
      await p22Put('2026-03-11', 'b');
      lane.hook = (i, c) async {
        if (i == 0) await p22Put(_day, 'replaced', reason: DayResultWrite.userOverride);
      };

      final out = await store.readAll([_src, const BundleSource.day('2026-03-11')]);

      expect(out.map(p22TagOf).toList(), ['replaced', 'b']);
    });
  });

  group('generation: wipe, reopen', () {
    test('a read that captured the old generation before a wipe commits is '
        'rejected; the retry sees an empty store', () async {
      await p22Put(_day, 'a');
      lane.hook = (i, c) async {
        await LocalDb.wipeAll();
      };

      final once = await store.readOnce(_src);
      expect(once, isA<BundleStale>());
      expect(store.debugCachedKeys, isEmpty);

      lane.hook = null;
      expect(await store.read(_src), isA<BundleAbsent>(),
          reason: 'the wipe emptied the store: honest absence, not an error');
    });

    test('a wipe followed by the identical row again: the old flight cannot '
        'return the deleted data', () async {
      await p22Put(_day, 'a');
      lane.hook = (i, c) async {
        if (i != 0) return;
        await LocalDb.wipeAll();
        await p22Put(_day, 'a'); // identical text, same (day, version)
      };

      final r = await store.read(_src);

      expect(lane.sizes, [1, 1], reason: 'the first decode was thrown away');
      final ok = r as BundleOk;
      expect(ok.key.generation, LocalDb.storeGeneration);
      expect(ok.key.rev, await p21DayRev(db, _day));
    });

    test('a reopen between dispatch and completion: Stale', () async {
      await p22Put(_day, 'a');
      lane.hook = (i, c) async {
        if (i == 0) await p21Reopen();
      };

      expect(await store.readOnce(_src), isA<BundleStale>());
      expect(store.debugCachedKeys, isEmpty);
      lane.hook = null;
      final r = await store.read(_src) as BundleOk;
      expect(r.key.generation, LocalDb.storeGeneration);
    });

    test('a flight of the old generation is never joined by a read of the new '
        'one: the generation is part of the flight identity', () async {
      await p22Put(_day, 'a');
      lane.holdAll = true;
      final old = store.readOnce(_src);
      await lane.arrived(1);

      await p21Reopen();
      final fresh = store.readOnce(_src);
      await p22Flush(await LocalDb.instance);
      lane.releaseAll();

      expect(await old, isA<BundleStale>());
      final ok = await fresh as BundleOk;
      expect(ok.key.generation, LocalDb.storeGeneration);
      expect(lane.sizes, [1, 1], reason: 'two flights, not one shared');
    });

    test('a generation change clears the cache: nothing from before answers',
        () async {
      await p22Put(_day, 'a');
      await store.read(_src);
      expect(store.debugCachedKeys, hasLength(1));

      await p21Reopen();
      await store.read(_src);

      expect(store.debugCachedKeys.map((k) => k.generation).toSet(),
          {LocalDb.storeGeneration},
          reason: 'only the current generation is cached');
    });
  });
}
