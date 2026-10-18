// P2.2 fix round 1 (Sol r1 = REVISE): queue and race behaviour of the
// BundleStore read path, and the ownership of what a reader returns.
//
//   1  invalidateAll / invalidateDays answer queued flights (Stale), so a reader
//      waiting on one retries instead of waiting forever.
//   2  a revision that moves between the meta read and the payload read is
//      Stale (read retries), never a false absence.
//   3  readAll captures every member's flight before awaiting any of them.
//   4  readAll fetches payload text one chunk at a time, through admission.
//   5  a repository reader's output behaves like a normal mutable map: a nested
//      mutation is still there on the next access (the returned objects are
//      memoised), and the next repository read is unaffected.
//   6  two cold reads started together decode once.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

import 'support/p22_support.dart';

const _name = 'p22_fix_round1.db';

String _d(int i) => DateTime.utc(2025, 1, 1 + i).toIso8601String().substring(0, 10);

/// Runs [action] once, between the meta read and the payload read.
final class _OnceAfterMeta implements BundleReadProbe {
  Future<void> Function()? action;
  @override
  Future<void> afterMeta(BundleSource source) async {
    final a = action;
    action = null;
    if (a != null) await a();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  late P22Lane lane;
  late BundleStore store;
  setUp(() async {
    db = await p21Fresh(_name);
    LocalDb.nowMs = P21Clock(1700000000000).call;
    lane = P22Lane();
    store = p22Store(lane);
  });
  tearDown(() => p21Drop(_name));

  group('1: invalidation answers queued flights', () {
    final variants = <String, void Function(BundleStore s, List<String> days)>{
      'invalidateAll': (s, days) => s.invalidateAll(),
      'invalidateDays': (s, days) => s.invalidateDays(days),
    };
    for (final v in variants.entries) {
      test('${v.key}: a running and a queued reader both complete, and the '
          'retry serves the new revision', () async {
        await p22Put(_d(0), 'a1');
        await p22Put(_d(1), 'b1');
        lane.holdAll = true;
        final done = <String, BundleRead>{};
        final failed = <Object>[];
        final ra = store.read(BundleSource.day(_d(0))).then((r) => done['a'] = r, onError: failed.add);
        await lane.arrived(1); // A is running in the lane
        final rb = store.read(BundleSource.day(_d(1))).then((r) => done['b'] = r, onError: failed.add);
        await p22Until(() => store.debugFlightCount == 2, 'B queued behind A');

        await p22Put(_d(0), 'a2', reason: DayResultWrite.userOverride);
        await p22Put(_d(1), 'b2', reason: DayResultWrite.userOverride);
        v.value(store, [_d(0), _d(1)]);
        lane.releaseAll();

        await p22Until(() => done.length + failed.length == 2,
            'both readers complete (the queued one must not wait forever)');
        await Future.wait([ra, rb]);
        expect(failed, isEmpty);
        expect(p22TagOf(done['a']!), 'a2');
        expect(p22TagOf(done['b']!), 'b2');
        expect(store.debugFlightCount, 0);
      });
    }

    test('an invalidation of other days leaves a queued flight alone', () async {
      await p22Put(_d(0), 'a1');
      await p22Put(_d(1), 'b1');
      lane.holdAll = true;
      final ra = store.read(BundleSource.day(_d(0)));
      await lane.arrived(1);
      final rb = store.read(BundleSource.day(_d(1)));
      await p22Until(() => store.debugFlightCount == 2, 'B queued');

      store.invalidateDays([_d(5)]);
      lane.releaseAll();

      expect(p22TagOf(await ra), 'a1');
      expect(p22TagOf(await rb), 'b1');
      expect(lane.sizes.length, lessThanOrEqualTo(2));
    });
  });

  group('2: a revision that moves between meta and payload', () {
    late _OnceAfterMeta probe;
    setUp(() {
      probe = _OnceAfterMeta();
      store.debugProbe = probe;
    });

    test('readOnce answers Stale, not Absent', () async {
      await p22Put(_d(0), 'a');
      probe.action = () => p22Put(_d(0), 'b', reason: DayResultWrite.userOverride);

      expect(await store.readOnce(BundleSource.day(_d(0))), isA<BundleStale>());
    });

    test('read retries from the meta and serves the new revision', () async {
      await p22Put(_d(0), 'a');
      probe.action = () => p22Put(_d(0), 'b', reason: DayResultWrite.userOverride);

      final r = await store.read(BundleSource.day(_d(0)));

      expect(p22TagOf(r), 'b');
      expect(lane.sizes, [1], reason: 'the stale attempt never reached the lane');
    });

    test('a row deleted in that window is an honest absence after the retry',
        () async {
      await p22Put(_d(0), 'a');
      probe.action = () => LocalDb.deleteDays({_d(0)});

      expect(await store.read(BundleSource.day(_d(0))), isA<BundleAbsent>());
    });

    test('a baseline that moves in that window is Stale too', () async {
      await LocalDb.putBaseline('crossday', jsonEncode({'tag': 'a'}));
      probe.action = () => LocalDb.putBaseline('crossday', jsonEncode({'tag': 'b'}));

      expect(await store.readOnce(const BundleSource.baseline('crossday')),
          isA<BundleStale>());
      probe.action = null;
      expect(p22TagOf(await store.read(const BundleSource.baseline('crossday'))), 'b');
    });

    test('readAll: the moved member is retried, the others are untouched',
        () async {
      await p22Put(_d(0), 'a');
      await p22Put(_d(1), 'b');
      probe.action = () => p22Put(_d(0), 'a2', reason: DayResultWrite.userOverride);

      final out = await store.readAll([BundleSource.day(_d(0)), BundleSource.day(_d(1))]);

      expect(out.map(p22TagOf).toList(), ['a2', 'b']);
    });
  });

  group('3: readAll holds every member flight before awaiting any', () {
    test('a publish that clears the flights mid-batch retries each member',
        () async {
      for (var i = 0; i < 3; i++) {
        await p22Put(_d(i), 'old$i');
      }
      lane.holdAll = true;
      final all = store.readAll([for (var i = 0; i < 3; i++) BundleSource.day(_d(i))]);
      await lane.arrived(1);
      expect(lane.sizes, [3], reason: 'three decodes in flight in one chunk');

      for (var i = 0; i < 3; i++) {
        await p22Put(_d(i), 'new$i', reason: DayResultWrite.userOverride);
      }
      store.invalidateAll(); // what the derive publisher does
      lane.releaseAll();

      final out = await all;
      expect(out.map(p22TagOf).toList(), ['new0', 'new1', 'new2'],
          reason: 'never Absent: each stale member is read again');
    });

    test('joining a flight another reader started does not serialise the batch',
        () async {
      for (var i = 0; i < 3; i++) {
        await p22Put(_d(i), 't$i');
      }
      lane.holdAll = true;
      final first = store.read(BundleSource.day(_d(0)));
      await lane.arrived(1);

      final all = store.readAll([for (var i = 0; i < 3; i++) BundleSource.day(_d(i))]);
      await p22Until(() => store.debugFlightCount == 3, 'members 1 and 2 queued');
      lane.releaseAll();

      expect((await all).map(p22TagOf).toList(), ['t0', 't1', 't2']);
      expect(p22TagOf(await first), 't0');
      expect(lane.sizes, [1, 2], reason: 'member 0 joined, 1 and 2 share a chunk');
    });
  });

  group('4: readAll fetches payload text a chunk at a time', () {
    test('at most one chunk of payload text is held undecoded', () async {
      const n = 120;
      for (var i = 0; i < n; i++) {
        await p22Put(_d(i), 't$i');
      }
      var held = 0;
      lane.hook = (i, chunk) async {
        final undecoded = store.debugPayloadReads - lane.payloads;
        if (undecoded > held) held = undecoded;
      };

      final out = await store.readAll(
        [for (var i = 0; i < n; i++) BundleSource.day(_d(i))],
        projection: ProjectionId.cycleScalars,
        chunkRows: 3,
      );

      expect(out.whereType<BundleOk>(), hasLength(n));
      expect(lane.sizes, everyElement(lessThanOrEqualTo(3)));
      expect(held, lessThanOrEqualTo(3),
          reason: 'payloads read from the database but not yet decoded');
      expect(store.debugPayloadReads, n);
    });

    test('a payload carried over to the next chunk is read once', () async {
      for (var i = 0; i < 4; i++) {
        await p21RawDay(db, _d(i), version: p21Version, payload: jsonEncode({'tag': 'p$i', 'pad': 'x' * 100 * 1024}));
      }

      await store.readAll([for (var i = 0; i < 4; i++) BundleSource.day(_d(i))]);

      expect(lane.sizes, [2, 2]);
      expect(store.debugPayloadReads, 4);
    });

    test('readAll goes through the same admission as read: over the byte '
        'limit it fails as retryable instead of queueing past the bound',
        () async {
      for (var i = 0; i < 3; i++) {
        await p21RawDay(db, _d(i), version: p21Version, payload: jsonEncode({'tag': 'big$i', 'pad': 'x' * 1400 * 1024}));
      }
      store = p22Store(lane, queueWait: Duration.zero);
      lane.holdAll = true;
      final r0 = store.read(BundleSource.day(_d(0)));
      await lane.arrived(1);
      final r1 = store.read(BundleSource.day(_d(1)));
      await p22Until(() => store.debugFlightCount == 2, 'two big reads admitted');

      await expectLater(
        store.readAll([BundleSource.day(_d(2))]),
        throwsA(isA<BundleRetryable>()),
      );
      expect(store.debugFlightCount, 2, reason: 'the refused read left no flight');

      lane.releaseAll();
      expect(p22TagOf(await r0), 'big0');
      expect(p22TagOf(await r1), 'big1');
    });

    test('getCycle reads its days three at a time', () async {
      const n = 40;
      for (var i = 0; i < n; i++) {
        await p22Put(_d(i), 't$i');
      }
      for (final d in [_d(0), _d(10), _d(20)]) {
        await LocalDb.putCycleLog(d, 'start');
      }
      p22UseStore(store);
      var held = 0;
      lane.hook = (i, chunk) async {
        final undecoded = store.debugPayloadReads - lane.payloads;
        if (undecoded > held) held = undecoded;
      };
      final repo = LocalRepositoryImpl(getProfileMap: () => {...p22Profile});

      final out = await repo.getCycle();

      expect((out['overlay'] as List), hasLength(n));
      expect(lane.sizes, everyElement(lessThanOrEqualTo(3)));
      expect(held, lessThanOrEqualTo(3));
    });
  });

  group('5: a returned bundle map is a normal mutable map', () {
    final payload = jsonEncode({
      'scalars': {'rmssd': 50.0},
      'clinical': {
        'hrv_time': {
          'value': {
            'rmssd': 50.0,
            'inner': {'k': 1},
            'xs': [1, 2, 3],
          },
        },
      },
    });

    test('nested map and list mutations survive the next access', () async {
      await p22Put(_d(0), 'a', payload: payload);
      p22UseStore(store);
      final repo = LocalRepositoryImpl(getProfileMap: () => {...p22Profile});

      final out = await repo.getDayHrv(_d(0));

      final hrv = out['hrv_time'] as Map;
      (hrv['value'] as Map)['rmssd'] = 99.0;
      ((hrv['value'] as Map)['inner'] as Map)['k'] = 2;
      ((hrv['value'] as Map)['inner'] as Map)['added'] = true;
      ((hrv['value'] as Map)['xs'] as List).add(4);
      expect(((out['hrv_time'] as Map)['value'] as Map)['rmssd'], 99.0);
      expect((((out['hrv_time'] as Map)['value'] as Map)['inner'] as Map)['k'], 2);
      expect((((out['hrv_time'] as Map)['value'] as Map)['inner'] as Map)['added'], true);
      expect((((out['hrv_time'] as Map)['value'] as Map)['xs'] as List), [1, 2, 3, 4]);
    });

    test('a later repository read does not see the mutation', () async {
      await p22Put(_d(0), 'a', payload: payload);
      p22UseStore(store);
      final repo = LocalRepositoryImpl(getProfileMap: () => {...p22Profile});

      final out = await repo.getDayHrv(_d(0));
      final value = (out['hrv_time'] as Map)['value'] as Map;
      value['rmssd'] = 99.0;
      (value['inner'] as Map)['k'] = 2;
      (value['xs'] as List).clear();

      final again = await repo.getDayHrv(_d(0));
      final v2 = (again['hrv_time'] as Map)['value'] as Map;
      expect(v2['rmssd'], 50.0);
      expect((v2['inner'] as Map)['k'], 1);
      expect(v2['xs'], [1, 2, 3]);
      expect(lane.sizes, [1], reason: 'the second read was a hit');
    });
  });

  group('6: two cold reads started together', () {
    test('decode once and both get Ok', () async {
      await p22Put(_d(0), 'a');

      final a = store.read(BundleSource.day(_d(0)));
      final b = store.read(BundleSource.day(_d(0)));
      final ra = await a;
      final rb = await b;

      expect(ra, isA<BundleOk>());
      expect(rb, isA<BundleOk>());
      expect(lane.sizes, [1]);
      expect(store.debugFlightCount, 0);
    });

    test('a reader and a readAll member for one key decode once', () async {
      await p22Put(_d(0), 'a');
      await p22Put(_d(1), 'b');

      final a = store.read(BundleSource.day(_d(0)));
      final all = store.readAll([BundleSource.day(_d(0)), BundleSource.day(_d(1))]);

      expect(p22TagOf(await a), 'a');
      expect((await all).map(p22TagOf).toList(), ['a', 'b']);
      expect(lane.payloads, 2);
    });
  });
}
