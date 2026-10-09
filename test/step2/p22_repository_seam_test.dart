// P2.2 repository seam: B1-B4 of the design 02 step 2 inventory.
//
//   B1  _bundle / _decodeDay / _decodeDayShared / _decode: every getDay* and
//       getToday reads its bundle through BundleStore.shared.
//   B2  _latestBundleAt: the 14-row walk decodes in chunks of 3.
//   B3  _crossDay / _crossDayArtifactAt (getInsights): keyed by the baselines
//       revision, ('baselines', 'crossday', 0, rev).
//   B4  getCycle: a projection of three scalars per day, never a full decode.
//
// The repository is handed a store over a recording lane (P22Lane) through
// `BundleStore.debugUseShared`. Day payloads carry a `p22_marker`, so a test
// can tell the payloads it asked about from any other small payload that the
// same call decodes (freshness rows and the like travel in the same lane).
//
// Several tests here also pass on the pre-P2.2 code (they say so): they pin
// behaviour that must not change while the decode moves.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

import '../support/dart_source.dart';
import 'support/p22_support.dart';

const _name = 'p22_repo_seam.db';

String _d(int i) => DateTime.utc(2025, 1, 1 + i).toIso8601String().substring(0, 10);

/// Per chunk, how many payloads carry [marker].
List<int> _marked(P22Lane lane, String marker) => [
  for (final c in lane.chunks)
    c.payloadJson.where((p) => p.contains('"p22_marker":"$marker"')).length,
].where((n) => n > 0).toList();

int _count(P22Lane lane, String needle) => lane.chunks.fold(
  0,
  (a, c) => a + c.payloadJson.where((p) => p.contains(needle)).length,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  late P22Lane lane;
  late BundleStore store;
  late LocalRepositoryImpl repo;
  final profile = <String, dynamic>{...p22Profile};

  setUp(() async {
    db = await p21Fresh(_name);
    LocalDb.nowMs = P21Clock(1700000000000).call;
    lane = P22Lane();
    store = p22Store(lane);
    p22UseStore(store);
    repo = LocalRepositoryImpl(getProfileMap: () => profile);
  });
  tearDown(() => p21Drop(_name));

  group('B1: bundle readers go through the store', () {
    test('a day reader decodes its row in the lane; a second reader of the '
        'same row is a hit', () async {
      await p22Seed(db, p22D1, p22DayBundle(p22D1, i: 1, marker: 'b1'));

      await repo.getDayHrv(p22D1);
      expect(_count(lane, '"p22_marker":"b1"'), 1);
      expect(store.debugCachedKeys.map((k) => k.k1), [p22D1]);

      await repo.getDayStrain(p22D1);
      await repo.getDayTimeline(p22D1);
      expect(_count(lane, '"p22_marker":"b1"'), 1, reason: 'decoded once');
    });

    test('all twelve day readers together decode one row once', () async {
      await p22Seed(db, p22D1, p22DayBundle(p22D1, i: 1, marker: 'b1'));
      for (final e in p22DayReaders.entries) {
        await e.value(repo, p22D1);
      }
      expect(lane.payloads, 1);
    });

    test('a re-derive is seen by the next read with no invalidation call',
        () async {
      await p22Put(p22D1, 'a',
          payload: jsonEncode({'scalars': {'rmssd': 55.0}}));
      expect((await repo.getDayHrv(p22D1))['rmssd'], 55.0);

      await p22Put(p22D1, 'b', payload: jsonEncode({'scalars': {'rmssd': 71.0}}));

      expect((await repo.getDayHrv(p22D1))['rmssd'], 71.0);
    });

    test('a day with no row, and a day with an undecodable payload, read as the '
        'honest empty shape (passes before P2.2)', () async {
      await db.insert('day_result', {
        'day_id': p22D4,
        'algo_version': p21Version,
        'payload_json': '{not json',
        'window_json': '{}',
        'computed_at': 1,
        'finalized': 0,
        'skipped': 0,
        'partial': 0,
      });
      expect(await repo.getDayHrv(p22D4), isEmpty);
      expect(await repo.getDayHrv(p22D9), isEmpty);
      expect(await repo.getDayStrain(p22D4), isEmpty);
    });

    test('the repository decodes no payload itself: no _decode, no memo, no '
        'SeriesCodec decode in local_repository_impl.dart', () {
      final code = stripCommentsAndStrings(
        File('lib/data/local_repository_impl.dart').readAsStringSync(),
      );
      for (final gone in [
        'decodePayloadJson',
        '_decodeDayShared',
        '_decodeDay(',
        '_bundleMemo',
        'static Map<String, dynamic>? _decode(',
      ]) {
        expect(code.contains(gone), isFalse, reason: '`$gone` should be gone');
      }
    });
  });

  group('B2: the latest-bundle walk', () {
    Future<void> seedWalk({int? sleepAtNewestIndex}) async {
      // _d(13) is the newest; none can be today.
      for (var i = 0; i < 14; i++) {
        final rank = 13 - i; // 0 = newest
        await p22Seed(
          db,
          _d(i),
          p22DayBundle(
            _d(i),
            i: i,
            sleep: rank == sleepAtNewestIndex,
            points: 12,
            marker: 'walk',
          ),
          computedAt: 100 + i,
        );
      }
    }

    test('14 rows with no sleep anywhere decode in chunks of 3', () async {
      await seedWalk();

      await repo.getToday();

      expect(_marked(lane, 'walk'), [3, 3, 3, 3, 2]);
    });

    test('the walk stops after the chunk that holds the newest day with sleep',
        () async {
      await seedWalk(sleepAtNewestIndex: 4); // the fifth newest

      await repo.getToday();

      final chunks = _marked(lane, 'walk');
      expect(chunks, everyElement(lessThanOrEqualTo(3)));
      expect(chunks.fold(0, (a, b) => a + b), inInclusiveRange(5, 6),
          reason: 'two chunks of 3, not all 14');
    });

    test('a second walk decodes nothing; a newer row costs one decode',
        () async {
      await seedWalk();
      await repo.getToday();
      final first = _marked(lane, 'walk').fold(0, (a, b) => a + b);
      expect(first, 14);

      await repo.getToday();
      expect(_marked(lane, 'walk').fold(0, (a, b) => a + b), 14);

      await p22Seed(db, _d(14), p22DayBundle(_d(14), i: 14, sleep: false, points: 12, marker: 'walk'));
      await repo.getToday();
      expect(_marked(lane, 'walk').fold(0, (a, b) => a + b), 15);
    });
  });

  group('B3: the cross-day rollup is keyed by the baselines revision', () {
    String rollup(String tag, {String? builtFor}) => jsonEncode({
      'algo_version': p21Version,
      'built_for_day': builtFor ?? p22Today(),
      'p22_crossday': tag,
      'load': {'acwr': 1.1},
    });

    test('five readers share one decode keyed (baselines, crossday, 0, rev)',
        () async {
      await p22Seed(db, p22D1, p22DayBundle(p22D1, i: 1));
      await LocalDb.putBaseline('crossday', rollup('v1'));
      final rev = await p21BaseRev(db, 'crossday');

      await repo.getDayStrain(p22D1);
      await repo.getDayStress(p22D1);
      await repo.getDayHeart(p22D1);
      await repo.getDaySleepV2(p22D1);
      await repo.getInsights();

      expect(_count(lane, '"p22_crossday"'), 1);
      final key = store.debugCachedKeys.singleWhere((k) => k.kind == 'baselines');
      expect((key.k1, key.k2, key.rev), ('crossday', 0, rev));
      expect(key.projection, ProjectionId.full);
    });

    test('a new rollup is a new revision and a miss; a touch is neither, and '
        'computed_at comes fresh from the meta', () async {
      final clock = P21Clock(1000);
      LocalDb.nowMs = clock.call;
      await LocalDb.putBaseline('crossday', rollup('v1'));
      final a = await repo.getInsights();
      expect(a['p22_crossday'], 'v1');
      expect(a['computed_at'], 1000);

      clock.ms = 2000;
      await LocalDb.touchBaseline('crossday');
      final b = await repo.getInsights();
      expect(b['computed_at'], 2000);
      expect(_count(lane, '"p22_crossday"'), 1, reason: 'same revision: a hit');

      clock.ms = 3000;
      await LocalDb.putBaseline('crossday', rollup('v2'));
      final c = await repo.getInsights();
      expect(c['p22_crossday'], 'v2');
      expect(c['computed_at'], 3000);
      expect(_count(lane, '"p22_crossday"'), 2);
    });

    test('a stale rollup is still withheld with its reason, and no rollup is '
        'still an empty answer (passes before P2.2)', () async {
      expect(await repo.getInsights(), isEmpty);

      await LocalDb.putBaseline('crossday', rollup('old', builtFor: '2000-01-01'));
      final out = await repo.getInsights();
      expect(out.keys, ['stale']);
      expect((out['stale'] as Map)['kind'], 'stale');
      expect((out['stale'] as Map)['built_for_day'], '2000-01-01');
    });
  });

  group('B4: getCycle reads three scalars, never a full bundle', () {
    Future<void> seedCycle() async {
      for (var i = 0; i < 30; i++) {
        final day = _d(i);
        await p22Seed(
          db,
          day,
          p22DayBundle(day, i: i, points: 12, marker: 'cyc'),
        );
      }
      for (final d in [_d(0), _d(10), _d(20)]) {
        await LocalDb.putCycleLog(d, 'start');
      }
    }

    test('every payload goes through the lane as a cycleScalars projection',
        () async {
      await seedCycle();

      await repo.getCycle();

      expect(_count(lane, '"p22_marker":"cyc"'), 30);
      expect(
        lane.chunks.expand((c) => c.projections).toSet(),
        {'cycleScalars'},
        reason: 'no full decode of any day',
      );
      expect(lane.chunks.map((c) => c.payloadJson.length),
          everyElement(lessThanOrEqualTo(BundleStore.maxChunkRows)));
      expect(store.debugCachedKeys.map((k) => k.projection).toSet(),
          {ProjectionId.cycleScalars});
    });

    test('a second getCycle is served from the projection cache', () async {
      await seedCycle();
      await repo.getCycle();
      final first = lane.payloads;
      expect(first, 30);

      await repo.getCycle();
      expect(lane.payloads, first);
    });

    test('the overlay carries the stored scalars; an absent scalar stays null '
        '(passes before P2.2)', () async {
      await seedCycle();

      final out = await repo.getCycle();

      final overlay = (out['overlay'] as List).cast<Map>();
      expect(overlay, hasLength(30));
      final byDate = {for (final o in overlay) o['date'] as String: o};
      for (var i = 0; i < 30; i++) {
        final o = byDate[_d(i)]!;
        expect(o['resting_hr'], 55.0 + i, reason: 'day $i');
        expect(o['hrv_rmssd'], 40.0 + i, reason: 'day $i');
        expect(o['skin_temp_idx'], i.isOdd ? -0.5 + i * 0.1 : isNull,
            reason: 'day $i: even days have no skin_temp_z and must read null');
      }
    });

    test('cycle tracking off decodes nothing (passes before P2.2)', () async {
      await seedCycle();
      profile['track_cycle'] = false;
      addTearDown(() => profile['track_cycle'] = true);

      final out = await repo.getCycle();

      expect(out['enabled'], false);
      expect(lane.chunks, isEmpty);
    });
  });
}
