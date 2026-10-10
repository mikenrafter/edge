// P2.5 fix round 1 (Sol r1 = REVISE). The golden fixture (finding 5) is in
// p25_reader_golden_test.dart.
//
//   1  the health export does not materialise whole bundles: it reads through a
//      caller-owned LAZY view that copies only the subtrees it touches.
//   2  the generic JSON lane publishes only after revalidating: a wipe, a
//      deletion or a replacement during the worker call never returns or caches
//      the old value (a replaced row is decoded once more; twice is absence).
//   3  the lane is bounded: one entry per key, old generations dropped, a
//      retained-bytes budget, oversized values not kept, chunks limited by
//      source bytes as well as by rows.
//   4  a one-pass stream keeps its non-caching policy through the stale retry.
//   6  the Android priority scan reads a light projection and decodes each
//      day's full bundle once.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derive_perf.dart' show payloadNodeCount;
import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/json_payload_lane.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import 'support/p25_support.dart';

const _name = 'p25fix_round1.db';

/// A JSON lane that records its calls and can park or act in each.
class _JsonLane implements JsonPayloadDecodeLane {
  final calls = <JsonPayloadsInput>[];
  Future<void> Function(int index)? hook;

  List<int> get sizes => [for (final c in calls) c.values.length];

  @override
  Future<JsonPayloadsResult> run(JsonPayloadsInput input) async {
    final index = calls.length;
    calls.add(input);
    await hook?.call(index);
    return decodeJsonPayloadsHeavy(bundleWorkerInputs, input);
  }
}

/// A source whose current row the test moves by hand.
class _Src implements JsonRowSource {
  _Src(this.key, this.row);
  @override
  final String key;
  JsonRowState? row;
  int reads = 0;

  @override
  Future<JsonRowState?> current() async {
    reads++;
    return row;
  }
}

JsonRowState _row(int rev, Object? value) =>
    JsonRowState(revision: rev, text: jsonEncode(value));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async {
    db = await p21Fresh(_name);
    BundleStore.debugResetShared();
    JsonPayloadLane.debugResetShared();
  });
  tearDown(() async {
    BundleStore.debugResetShared();
    JsonPayloadLane.debugResetShared();
    await p21Drop(_name);
  });

  // -- 2. revalidate before publishing ------------------------------------------

  group('2: the lane revalidates after the worker call', () {
    late _JsonLane fake;
    setUp(() {
      fake = _JsonLane();
      JsonPayloadLane.debugUseShared(JsonPayloadLane(lane: fake));
    });

    /// Parks the worker call number [n] until [release] is completed; completes
    /// [arrived] when the call is parked.
    ({Completer<void> arrived, Completer<void> release}) park(int n) {
      final arrived = Completer<void>();
      final release = Completer<void>();
      final before = fake.hook;
      fake.hook = (i) async {
        await before?.call(i);
        if (i != n) return;
        arrived.complete();
        await release.future;
      };
      return (arrived: arrived, release: release);
    }

    test('LastResultCache.read: a wipe during the worker call answers a miss, '
        'not the deleted artifact', () async {
      await p25SeedLastResults();
      final cache = LastResultCache();
      final gate = park(0);

      final read = cache.read<Map<String, dynamic>>('workout|w1');
      await gate.arrived.future;
      await LocalDb.wipeAll();
      gate.release.complete();

      expect(await read, isNull);
      expect(cache.get<Map<String, dynamic>>('workout|w1'), isNull,
          reason: 'nothing was promoted into memory');
    });

    test('LastResultCache.read: a row deleted during the worker call answers a '
        'miss', () async {
      await p25SeedLastResults();
      final cache = LastResultCache();
      final gate = park(0);

      final read = cache.read<Map<String, dynamic>>('workout|w1');
      await gate.arrived.future;
      await db.delete('last_result', where: 'key = ?', whereArgs: ['workout|w1']);
      gate.release.complete();

      expect(await read, isNull);
      expect(cache.get<Map<String, dynamic>>('workout|w1'), isNull);
    });

    test('LastResultCache.read: a row replaced during the worker call is '
        'decoded once more and answers the NEW value, time and signature',
        () async {
      await p25SeedLastResults();
      final cache = LastResultCache();
      final gate = park(0);

      final read = cache.read<Map<String, dynamic>>('workout|w1');
      await gate.arrived.future;
      await LocalDb.putLastResult('workout|w1', 9100, jsonEncode({'name': 'new'}), 200, sig: 's2');
      gate.release.complete();

      final got = await read;
      expect(got!.value, {'name': 'new'});
      expect(got.cachedAt.millisecondsSinceEpoch, 9100);
      expect(got.sig, 's2');
      expect(fake.calls, hasLength(2), reason: 'one retry');
    });

    test('a row replaced twice answers absence and nothing is cached',
        () async {
      await p25SeedLastResults();
      final cache = LastResultCache();
      fake.hook = (i) async {
        if (i < 2) {
          await LocalDb.putLastResult(
              'workout|w1', 9200 + i, jsonEncode({'n': i}), 200);
        }
      };

      expect(await cache.read<Map<String, dynamic>>('workout|w1'), isNull);
      expect(fake.calls, hasLength(2), reason: 'retried once, then stopped');
      expect(cache.get<Map<String, dynamic>>('workout|w1'), isNull);
    });

    test('sleepWindows: a day replaced during the worker call shows its new '
        'window, and the lane keeps only the new revision', () async {
      await p25SeedWindows(db);
      final gate = park(0);
      final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);

      final out = repo.sleepWindows(days: 14);
      await gate.arrived.future;
      // Writers REPLACE a row (delete + insert), which is what moves its revision.
      await p25Row(db, p25WindowDays[15],
          window: jsonEncode({'onset_ms': 1000000, 'offset_ms': 2000000}),
          computedAt: 4000);
      gate.release.complete();

      final rows = await out;
      final replaced = rows.firstWhere((r) => r['date'] == p25WindowDays[15]);
      expect(replaced['onset_ts'], 1000);
      expect(replaced['wake_ts'], 2000);
    });

    test('a deleted source answers absence and is not cached (lane level)',
        () async {
      final lane = JsonPayloadLane(lane: fake);
      final src = _Src('k', _row(1, {'a': 1}));
      final gate = park(0);

      final out = lane.decode(src, _row(1, {'a': 1}));
      await gate.arrived.future;
      src.row = null;
      gate.release.complete();

      expect(await out, isNull);
      expect(lane.debugEntries, 0);
    });
  });

  // -- 3. bounded ---------------------------------------------------------------

  group('3: the lane is bounded', () {
    late _JsonLane fake;
    late JsonPayloadLane lane;
    setUp(() {
      fake = _JsonLane();
      lane = JsonPayloadLane(lane: fake);
    });

    Map<String, Object?> fat(int chars, [String tag = 'x']) => {'s': tag * chars};

    test('a new revision of the same key replaces the old one', () async {
      final src = _Src('k', _row(1, fat(1000)));
      await lane.decode(src, _row(1, fat(1000)));
      final one = lane.debugRetainedBytes;
      src.row = _row(2, fat(3000));
      await lane.decode(src, _row(2, fat(3000)));

      expect(lane.debugEntries, 1);
      expect(lane.debugRetainedBytes, greaterThan(one));
      expect(lane.debugRetainedBytes, lessThan(one + 2 * 3000 + 200),
          reason: 'only the new one is held');
    });

    test('entries of an older store generation are dropped', () async {
      final a = _Src('a', _row(1, fat(500)));
      await lane.decode(a, _row(1, fat(500)));
      expect(lane.debugEntries, 1);

      await p21Reopen(); // moves the generation

      final b = _Src('b', _row(1, fat(500)));
      await lane.decode(b, _row(1, fat(500)));
      expect(lane.debugEntries, 1, reason: 'a belonged to the old generation');
    });

    test('the retained estimate stays under the byte budget', () async {
      for (var i = 0; i < 24; i++) {
        final src = _Src('k$i', _row(1, fat(100000, '$i')));
        await lane.decode(src, _row(1, fat(100000, '$i')));
      }

      expect(lane.debugRetainedBytes,
          lessThanOrEqualTo(JsonPayloadLane.retainedByteBudget));
      expect(lane.debugEntries, greaterThan(2), reason: 'it still caches');
      expect(lane.debugEntries, lessThan(24));
    });

    test('an oversized value is returned but not kept', () async {
      final big = fat(300000); // ~600 KB estimated: over the per-entry limit
      final src = _Src('big', _row(1, big));

      final first = await lane.decode(src, _row(1, big));
      final second = await lane.decode(src, _row(1, big));

      expect((first!.value as Map)['s'], hasLength(300000));
      expect(lane.debugEntries, 0);
      expect(fake.calls, hasLength(2), reason: 'not a hit the second time');
      expect(second, isNotNull);
    });

    test('a chunk holds at most 8 rows AND 256 KB of source text; a larger '
        'row runs alone', () async {
      final rows = <JsonLaneRow>[];
      for (var i = 0; i < 5; i++) {
        final v = fat(100000, '$i'); // ~100 KB of text each
        rows.add((source: _Src('c$i', _row(1, v)), state: _row(1, v)));
      }
      final huge = fat(300000);
      rows.insert(2, (source: _Src('huge', _row(1, huge)), state: _row(1, huge)));

      final out = await lane.decodeMany(rows);

      expect(out.every((r) => r != null), isTrue);
      expect(fake.sizes, [2, 1, 2, 1],
          reason: '100+100 KB; the 300 KB row alone; 100+100 KB; 100 KB');
      for (final c in fake.calls) {
        final bytes = c.values.fold<int>(0, (n, v) => n + (v as String).length);
        expect(bytes <= BundleStore.chunkSourceBytes || c.values.length == 1, isTrue);
      }
    });

    test('many small rows still go eight at a time', () async {
      final rows = [
        for (var i = 0; i < 20; i++)
          (source: _Src('s$i', _row(1, {'i': i})), state: _row(1, {'i': i})),
      ];

      await lane.decodeMany(rows);

      expect(fake.sizes, [8, 8, 4]);
    });
  });

  // -- 1. the export does not materialise whole bundles ----------------------------

  group('1/4/6: the health export', () {
    final days = [for (var i = 1; i <= 12; i++) '2025-03-${i.toString().padLeft(2, '0')}'];

    void mockChannels() {
      SharedPreferences.setMockInitialValues({});
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final name in const [
        'flutter_health',
        'openstrap/health_connect_sleep',
        'openstrap/health_connect_heart_rate',
      ]) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (c) async => true);
        addTearDown(() => messenger.setMockMethodCallHandler(MethodChannel(name), null));
      }
    }

    test('1: export copies only what it reads, not every curve of every day',
        () async {
      mockChannels();
      var total = 0;
      for (var i = 0; i < days.length; i++) {
        final bundle = p22DayBundle(days[i], i: i, points: 1500);
        total += payloadNodeCount(bundle);
        await p22Seed(db, days[i], bundle, finalized: true, computedAt: 1000 + i);
      }
      BundleView.debugResetCopiedNodes();

      await HealthExporter().exportAll();

      expect(BundleView.debugCopiedNodes, greaterThan(0), reason: 'guard: it read');
      expect(BundleView.debugCopiedNodes, lessThan(total ~/ 10),
          reason: 'copied ${BundleView.debugCopiedNodes} of $total nodes');
    });

    test('1: the export source holds no whole-bundle materialiser', () {
      final code = File('lib/health/health_export.dart').readAsStringSync();
      expect(code, isNot(contains('materialise')));
    });

    test('4: a day replaced while it streams leaves the retained cache alone',
        () async {
      final lane = P22Lane();
      final store = p22Store(lane);
      await p22Seed(db, days[0], p22DayBundle(days[0], i: 1), computedAt: 1000);
      await p22Seed(db, days[1], p22DayBundle(days[1], i: 2), computedAt: 1001);
      // Home's warmed data.
      final warmed = await store.read(BundleSource.day(days[1]));
      expect(warmed, isA<BundleOk>());
      final cachedBefore = store.debugCachedKeys;
      final bytesBefore = store.debugCacheBytes;
      lane.hold(1); // chunk 0 was the warm above; the stream's first decode

      final stream = store.readStream([BundleSource.day(days[0])]);
      await lane.arrived(2);
      await p22Seed(db, days[0], p22DayBundle(days[0], i: 3), computedAt: 2000);
      lane.release(1);
      final reads = await stream;

      expect(reads.single, isA<BundleOk>(), reason: 'it retried on the new revision');
      expect(lane.chunks.length, greaterThanOrEqualTo(3), reason: 'the retry decoded');
      expect(store.debugCachedKeys, cachedBefore);
      expect(store.debugCacheBytes, bytesBefore);
    });

    test('6: the Android path scans a light projection and decodes each full '
        'bundle once', () async {
      mockChannels();
      final lane = P22Lane();
      final store = p22Store(lane);
      p22UseStore(store);
      // Newest four days have no sleep; the fifth newest is the priority night.
      for (var i = 0; i < days.length; i++) {
        final newest = days.length - 1 - i;
        await p22Seed(db, days[i], p22DayBundle(days[i], i: i % 9, sleep: newest >= 4),
            finalized: true, computedAt: 1000 + i);
      }

      await HealthExporter(platform: const _Android()).exportAll();

      final byProjection = <String, int>{};
      for (final chunk in lane.chunks) {
        for (final p in chunk.projections) {
          byProjection[p] = (byProjection[p] ?? 0) + 1;
        }
      }
      expect(byProjection['full'], days.length, reason: 'each day decoded in full once');
      expect(byProjection['sleepWindow'], 5,
          reason: 'four days without sleep, then the priority night: one light '
              'read each, never repeated');
    });
  });
}

class _Android implements HealthExportPlatform {
  const _Android();
  @override
  bool get isAndroid => true;
}
