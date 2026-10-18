// P2.3 freshness reads (design 02 step 2, B5 and section 5 P2.3).
//
// `LocalDb.refreshComputeFreshness` reads payload-free meta rows plus the
// `freshness` projection ({skipped, scalars.readiness,
// sleep.accounting.value.tst_sec, flags}) through the BundleStore; it never
// decodes a full bundle and never touches `SeriesCodec` itself. Output parity
// with the pre-P2.3 code is pinned separately (p23_freshness_golden_test).
//
// The store under test is installed as `BundleStore.shared` over a recording
// lane (P22Lane), so every payload the refresh decodes shows up as a chunk.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';

import '../support/dart_source.dart';
import 'support/p23_support.dart';

const _name = 'p23_freshness_reads.db';

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
    p22UseStore(store);
  });
  tearDown(() => p21Drop(_name));

  Future<void> seed(String scenario) async => p23Scenarios()[scenario]!(db);

  group('the freshness projection (worker entry)', () {
    Set<String> leafPaths(BundleView v) {
      final out = <String>{};
      p22Walk(v.materialiseLegacy(), (node, path) {
        if (node is! Map && node is! List) out.add(path.replaceAll(RegExp(r'\[\d+\]'), '[]'));
      });
      return out;
    }

    test('keeps exactly skipped, scalars.readiness, sleep.accounting.value.tst_sec '
        'and flags', () {
      final payload = p23Payload(
        sleep: true,
        readiness: 80,
        flags: ['NO_SLEEP_DETECTED', 'X'],
        skipped: false,
        extra: {'series': {'hr_curve': p22Curve(1700000000, 50)}, 'big': List.filled(200, 1)},
      );

      final view = p22View(payload, projection: ProjectionId.freshness);

      expect(view.materialiseLegacy(), equals({
        'skipped': false,
        'scalars': {'readiness': 80},
        'sleep': {
          'accounting': {
            'value': {'tst_sec': 25000},
          },
        },
        'flags': ['NO_SLEEP_DETECTED', 'X'],
      }));
      expect(view.nodes, lessThan(20), reason: 'a projection, not the bundle');
      expect(view.estimatedBytes, lessThan(2048));
    });

    test('a key absent from the payload stays absent: nothing is invented', () {
      final view = p22View(jsonEncode({'date': 'x', 'scalars': {'steps': 3}}),
          projection: ProjectionId.freshness);

      final g = view.materialiseLegacy();
      expect(g.containsKey('skipped'), isFalse);
      expect(g.containsKey('flags'), isFalse);
      expect(g.containsKey('sleep'), isFalse);
      expect((g['scalars'] as Map?)?.containsKey('readiness') ?? false, isFalse);
      expect(leafPaths(view), isEmpty);
    });

    test('nothing outside the four keys survives, whatever the bundle holds',
        () {
      final view = p22View(p22Stored(p22DayBundle('2025-03-01', i: 2)),
          projection: ProjectionId.freshness);

      expect(
        leafPaths(view),
        everyElement(isIn(const {
          'skipped',
          'scalars.readiness',
          'sleep.accounting.value.tst_sec',
          'flags[]',
          'flags',
        })),
      );
    });

    test('a sleep block without tst_sec, a non-list flags and a non-numeric '
        'readiness keep their stored shape (the reader decides)', () {
      final view = p22View(
        p23Payload(sleep: true, tst: null, flags: 'NO_SLEEP_DETECTED', readiness: '77'),
        projection: ProjectionId.freshness,
      );

      final g = view.materialiseLegacy();
      expect((g['scalars'] as Map)['readiness'], '77');
      expect(g['flags'], 'NO_SLEEP_DETECTED');
      final value = (((g['sleep'] as Map)['accounting'] as Map)['value'] as Map?);
      expect(value?['tst_sec'], isNull);
    });

    test('an undecodable payload is an undecodable read, as for every projection',
        () async {
      await p23Row(db, p23Day(1), '{not json', computedAt: 1);
      final r = await store.read(BundleSource.day(p23Day(1)), projection: ProjectionId.freshness);
      expect(r, isA<BundleAbsent>());
      expect((r as BundleAbsent).undecodable, isTrue);
    });
  });

  group('the refresh decodes the projection only', () {
    test('every payload goes through the lane as a freshness projection, never '
        'a full or legacy decode', () async {
      await seed('prior_overnight');

      await LocalDb.refreshComputeFreshness();

      expect(lane.chunks, isNotEmpty, reason: 'the refresh decodes in the worker lane');
      expect(lane.chunks.expand((c) => c.projections).toSet(), {'freshness'});
      expect(store.debugCachedKeys.map((k) => k.projection).toSet(),
          {ProjectionId.freshness});
    });

    test('a refresh with nothing changed decodes nothing and moves no payload '
        '(meta rows and the projection cache answer)', () async {
      await seed('prior_overnight');
      await LocalDb.refreshComputeFreshness();
      final decoded = lane.payloads;
      final reads = store.debugPayloadReads;
      expect(decoded, greaterThan(0));

      await LocalDb.refreshComputeFreshness();

      expect(lane.payloads, decoded);
      expect(store.debugPayloadReads, reads);
    });

    test('one replaced row costs one payload, and its new content is what the '
        'refresh reports', () async {
      await seed('prior_overnight'); // today: no sleep; d1: sleep + readiness col
      await LocalDb.refreshComputeFreshness();
      final decoded = lane.payloads;

      await p22Put(p23Day(0), 'override',
          payload: p23Payload(sleep: true, readiness: 99),
          reason: DayResultWrite.userOverride);
      await LocalDb.refreshComputeFreshness();

      expect(lane.payloads, decoded + 1);
      final today = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(today['overnight_day'], p23Day(0));
      expect(today['overnight_state'], 'ready');
      expect(today['showing_prior_overnight'], false);
    });

    test('the early break survives: a day that already settles overnight, '
        'recovery and today leaves the other 29 payloads alone', () async {
      await seed('thirty_complete_days_early_break');

      await LocalDb.refreshComputeFreshness();

      expect(lane.payloads, greaterThan(0), reason: 'decoded in the worker lane');
      expect(lane.payloads, lessThanOrEqualTo(BundleStore.maxChunkRows),
          reason: 'at most one chunk of look-ahead past the first row');
      expect(store.debugPayloadReads, lessThanOrEqualTo(BundleStore.maxChunkRows));
    });

    test('the 30-day window survives: rows older than the 30 newest are never '
        'read', () async {
      await seed('overnight_beyond_the_30_day_window');

      await LocalDb.refreshComputeFreshness();

      expect(lane.payloads, greaterThan(0), reason: 'decoded in the worker lane');
      expect(store.debugPayloadReads, lessThanOrEqualTo(30));
      expect(lane.payloads, lessThanOrEqualTo(30));
    });

    test('a decode failure fails the refresh and leaves the stored freshness '
        'as it was: no half-written state', () async {
      await seed('prior_overnight');
      await LocalDb.refreshComputeFreshness();
      final before = await p23FreshnessRows(db);
      expect(before['today'], isNotNull);

      await p23Row(db, p23Day(0), p23Payload(sleep: true, readiness: 70), computedAt: 6000);
      lane.hook = (i, c) async => throw StateError('lane down');

      await expectLater(LocalDb.refreshComputeFreshness(), throwsA(anything));

      expect(await p23FreshnessRows(db), before);
    });
  });

  group('fenced like every other read', () {
    test('a row replaced while its projection is being decoded is not reported '
        'from the stale decode', () async {
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
      await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 4000);
      var fired = false;
      lane.hook = (i, c) async {
        if (fired) return;
        fired = true;
        await p22Put(p23Day(0), 'override',
            payload: p23Payload(sleep: true, readiness: 99),
            reason: DayResultWrite.userOverride);
      };

      await LocalDb.refreshComputeFreshness();

      expect(fired, isTrue, reason: 'the decode ran in the lane');
      final today = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(today['overnight_day'], p23Day(0),
          reason: 'the replaced row, not the one the stale decode saw');
      expect(today['recovery_day'], p23Day(0));
    });

    test('a row deleted while its projection is being decoded drops out of the '
        'answer', () async {
      await p23Row(db, p23Day(0), p23Payload(sleep: true), computedAt: 5000);
      await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 4000);
      var fired = false;
      lane.hook = (i, c) async {
        if (fired) return;
        fired = true;
        await LocalDb.deleteDays({p23Day(0)});
      };

      await LocalDb.refreshComputeFreshness();

      expect(fired, isTrue);
      final today = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(today['overnight_day'], p23Day(1));
      expect(today['activity_state'], 'missing');
    });
  });

  group('the decode left LocalDb.refreshComputeFreshness', () {
    test('its body no longer calls SeriesCodec or reads payload rows', () {
      final body = p23RefreshBody(
        stripCommentsAndStrings(File('lib/data/db.dart').readAsStringSync()),
      );

      expect(body, isNot(contains('SeriesCodec')));
      expect(body, isNot(contains('decodePayloadJson')));
      expect(body, isNot(contains('recentDayResults(')),
          reason: 'recentDayResults selects payload_json; use the meta rows');
      expect(body, contains('recentDayResultMetas('));
    });

    test('the heavy-calc baseline no longer lists LocalDb.refreshComputeFreshness '
        '(the firm -1 of P2.3)', () {
      final base = jsonDecode(
        File('test/guards/heavy_calc_baseline.json').readAsStringSync(),
      ) as Map;
      final hits = [
        for (final o in (base['occurrences'] as List).cast<Map>())
          if (o['symbol'] == 'LocalDb.refreshComputeFreshness')
            '${o['rule']} ${o['element']}',
      ];
      expect(hits, isEmpty,
          reason: 'move the code: a baseline key is removed, not suppressed');
    });
  });
}
