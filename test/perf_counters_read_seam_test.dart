// P2.0a, desktop part: perf counters at the read seam (design 02 step 2 scope,
// sections 2 B1/B3/B7 and 5 P2.0a). RED: nothing is counted yet, so every test
// that expects a counter fails on the missing key.
//
// The counters go to `ReadPerf.sink` (a `DerivePerf`; null = disabled). Names:
//
//   Per repository reader (the public `LocalRepositoryImpl` method a screen
//   calls; every payload decoded on its behalf is booked to it, a memo hit
//   included, because a hit still reads the full row through sqflite and
//   deep-copies the graph):
//     payload_reads_<reader>   payloads handed out (a day bundle, the crossday
//                              artifact, a freshness or wake row ...)
//     payload_bytes_<reader>   stored payload_json length (ASCII in these tests,
//                              so characters = bytes)
//     payload_nodes_<reader>   payloadNodeCount of the decoded graph returned
//
//   The cross-day artifact on its own (B3: decoded on every call, not memoised):
//     crossday_payload_bytes / crossday_payload_nodes
//
//   LastResultCache, by artifact kind = the key up to the first '|'
//   (`beats|<day>` -> `beats`; B7 and the `beats|day` size in section 2):
//     last_result_puts_<kind>, last_result_put_bytes_<kind>   (jsonEncode result)
//     last_result_reads_<kind>, last_result_read_bytes_<kind>,
//     last_result_read_nodes_<kind>   (table reads only; a memory hit adds none)
//
// Values are seeded and fixed; no real clock is read (the sink's clock is
// injected and nothing here depends on elapsed time).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/compute/derive_perf.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import 'support/last_result_db.dart';

const _db = 'perf_counters_read_seam_test.db';
const _day = '2025-09-02';

/// 10 nodes: root, skipped, scalars (1 + 2 leaves), sleep, stages (1 + 3).
final _dayJson = jsonEncode({
  'skipped': false,
  'scalars': {'steps': 1234, 'strain': 9.5},
  'sleep': {
    'stages': [1, 2, 3],
  },
});

/// 3 nodes: root, load, acwr.
final _crossJson = jsonEncode({
  'load': {'acwr': 1.1},
});

DerivePerf _sink() => DerivePerf(nowMs: () => 0)..startPass();

Map<String, int> _counts(DerivePerf p) =>
    ((p.summary()['counts'] as Map).cast<String, int>());

Future<void> _seedDay() async {
  final db = await LocalDb.instance;
  await db.insert(
      'day_result',
      {
        'day_id': _day,
        'algo_version': kAlgoVersion,
        'payload_json': _dayJson,
        'window_json': '{}',
        'computed_at': 1000,
        'finalized': 0,
        'skipped': 0,
        'partial': 0,
        'rmssd': 55.0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalRepositoryImpl repo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await g1FreshDb(_db);
    await LocalDb.instance;
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
    BundleStore.shared.invalidateAll();
    BundleStore.debugResetDecodeDispatches();
    ReadPerf.sink = null;
  });
  tearDown(() => ReadPerf.sink = null);
  tearDownAll(() => g1DropDb(_db));

  group('repository readers', () {
    test('a cold reader dispatches one worker decode', () async {
      await _seedDay();
      await repo.getDayHrv(_day);
      expect(BundleStore.debugDecodeDispatches, 1);
      expect(BundleStore.shared.debugCachedKeys, hasLength(1));
    });

    test('a cache hit does not dispatch another decode', () async {
      await _seedDay();
      await repo.getDayHrv(_day);
      await repo.getDayHrv(_day);
      expect(BundleStore.debugDecodeDispatches, 1);
    });

    test('two readers share one cached row', () async {
      await _seedDay();
      await repo.getDayHrv(_day);
      await repo.getDayStrain(_day);
      expect(BundleStore.debugDecodeDispatches, 1);
    });

    test('day and crossday payloads each use the worker', () async {
      await _seedDay();
      await LocalDb.putBaseline('crossday', _crossJson);
      await repo.getDayStrain(_day);
      expect(BundleStore.debugDecodeDispatches, 2);
    });

    test('an absent row dispatches no decode', () async {
      await repo.getDayHrv('2025-01-01');
      expect(BundleStore.debugDecodeDispatches, 0);
    });

    test('disabled: a null sink or a disabled DerivePerf records nothing and the '
        'reader returns the same answer', () async {
      await _seedDay();
      final want = await repo.getDayHrv(_day);
      expect(BundleStore.debugDecodeDispatches, 1);

      BundleStore.shared.invalidateAll();
      BundleStore.debugResetDecodeDispatches();
      ReadPerf.sink = null;
      expect(await repo.getDayHrv(_day), want);
      expect(BundleStore.debugDecodeDispatches, 1);

      final off = ReadPerf.sink = DerivePerf(nowMs: () => 0, enabled: false);
      BundleStore.shared.invalidateAll();
      BundleStore.debugResetDecodeDispatches();
      expect(await repo.getDayHrv(_day), want);
      expect(off.summary()['counts'], isEmpty);
    });
  });

  group('LastResultCache', () {
    // 6 nodes: root, rr list (1 + 3), n.
    final beats = <String, Object?>{
      'rr': [800, 810, 790],
      'n': 3,
    };
    final beatsJson = jsonEncode(beats);
    const key = 'beats|$_day';

    test('a put books the encoded size under its artifact kind', () async {
      final sink = ReadPerf.sink = _sink();
      final cache = LastResultCache(now: () => DateTime.utc(2025, 9, 2, 12));

      cache.put(key, beats);
      cache.put('workout|7', <String, Object?>{'id': 7});
      await cache.flush();

      final c = _counts(sink);
      expect(c['last_result_puts_beats'], 1);
      expect(c['last_result_put_bytes_beats'], beatsJson.length);
      expect(c['last_result_puts_workout'], 1);
      expect(c['last_result_put_bytes_workout'], '{"id":7}'.length);
    });

    test('a table read books bytes and nodes; a memory hit books nothing',
        () async {
      final writer = LastResultCache(now: () => DateTime.utc(2025, 9, 2, 12));
      writer.put(key, beats);
      await writer.flush();

      final sink = ReadPerf.sink = _sink();
      final cold = LastResultCache(); // empty memory: the read goes to the table
      final got = await cold.read<Map>(key);
      expect(got, isNotNull, reason: 'guard: the artifact is stored');

      var c = _counts(sink);
      expect(c['last_result_reads_beats'], 1);
      expect(c['last_result_read_bytes_beats'], beatsJson.length);
      expect(c['last_result_read_nodes_beats'], 6);

      await cold.read<Map>(key); // promoted into memory by the first read
      c = _counts(sink);
      expect(c['last_result_reads_beats'], 1);
      expect(c['last_result_read_bytes_beats'], beatsJson.length);
    });

    test('a missing artifact books no read', () async {
      final sink = ReadPerf.sink = _sink();
      expect(await LastResultCache().read<Map>('beats|2000-01-01'), isNull);
      expect(_counts(sink).keys.where((k) => k.startsWith('last_result_')),
          isEmpty);
    });

    test('disabled: put and read still work and book nothing', () async {
      final off = ReadPerf.sink = DerivePerf(nowMs: () => 0, enabled: false);
      final cache = LastResultCache(now: () => DateTime.utc(2025, 9, 2, 12));
      cache.put(key, beats);
      await cache.flush();
      expect((await LastResultCache().read<Map>(key))?.value, beats);
      expect(off.summary()['counts'], isEmpty);
    });
  });
}
