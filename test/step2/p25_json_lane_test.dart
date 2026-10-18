// P2.5 worker lane (design 02 step 2, sections 2 (B6, B7, B9, B12, and the
// batching paragraph under the table), 4.4 and 4.5; P2.3 carry-over (a), (b)).
//
// What the red run pins, from the outside (the lane's own signature is green's
// to choose; these tests only watch which worker entry reported, from which
// isolate, how many dispatches a call cost, and what a warm leaves behind):
//
//   1. THE DECODE LEAVES THE UI ISOLATE. `LocalDb.recentDayDiagnostics`,
//      `sleepWindows` (14 inline `jsonDecode`s today), `getDayCalorieCurve`
//      and `LastResultCache.read` / `put` each report at least one worker
//      entry and none from this isolate. The small keyed payloads (windows,
//      wake row, last_result rows, kcal) use the GENERIC lane,
//      `decodeJsonPayloadsHeavy`, registered like `decodeDayPayloadsHeavy`.
//   2. BATCHED. Fourteen window rows cost one request (at most two chunks of
//      eight), never one per row.
//   3. CACHED, AND A WARM CAN FILL IT. A second read of unchanged rows costs
//      no dispatch; a rewritten row is decoded again and shows its NEW value;
//      after the publish gate's warm, `sleepWindows(14)` and Home's wake
//      estimate cost no dispatch.
//   4. THE HEALTH EXPORT STREAMS. Each day's bundle is decoded exactly once, in
//      chunks of at most eight, the undecoded source text held at any moment is
//      at most one chunk, and nothing is cached afterwards.
//
// Open (not pinned, see the report): whether `getToday`'s freshness row is
// cached (P2.3 carry-over (c)); the design batches it with the bundles of the
// same request (section 2, Q1) but never says it is cached.


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/state/publish_gate.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import 'support/p25_support.dart';

const _name = 'p25_lane.db';
const _jsonLane = 'decodeJsonPayloadsHeavy';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  late P25Audit audit;
  setUp(() async {
    db = await p21Fresh(_name);
    BundleStore.debugResetShared();
    audit = P25Audit()..attach();
    addTearDown(audit.detach);
  });
  tearDown(() async {
    BundleStore.debugResetShared();
    await p21Drop(_name);
  });

  LocalRepositoryImpl repo() => LocalRepositoryImpl(getProfileMap: () => p22Profile);

  String why() => 'dispatches: ${audit.dispatches.map((d) => d.label).toList()}';

  // -- 1. the decode leaves the UI isolate ---------------------------------------

  group('1. decoded in a worker', () {
    test('recentDayDiagnostics (B6)', () async {
      await p25SeedDiagnostics(db);

      final rows = await LocalDb.recentDayDiagnostics(10);
      await audit.settle();

      expect(rows, hasLength(5));
      p25ExpectDecodedInWorker(audit, 'recentDayDiagnostics');
      expect(audit.dispatches.length, lessThanOrEqualTo(1),
          reason: 'five payloads are one chunk of at most eight; ${why()}');
    });

    test('sleepWindows(14) (carry-over a): the generic JSON lane', () async {
      await p25SeedWindows(db);

      final rows = await repo().sleepWindows(days: 14);
      await audit.settle();

      expect(rows, hasLength(14));
      p25ExpectDecodedInWorker(audit, 'sleepWindows');
      expect(audit.names, contains(_jsonLane));
    });

    test('sleepWindows: fourteen rows are one batch, never one request per row',
        () async {
      await p25SeedWindows(db);

      await repo().sleepWindows(days: 14);

      expect(audit.dispatches.length, inInclusiveRange(1, 2),
          reason: 'at most 8 rows per chunk (4.4), so 14 rows are 2 chunks at '
              'most; ${why()}');
    });

    test('getDayCalorieCurve (B9): the 1,440-minute record is not parsed here',
        () async {
      await p25SeedKcal();

      final out = await repo().getDayCalorieCurve(p25KcalFull);
      await audit.settle();

      expect((out!['minutes'] as List), hasLength(1440));
      p25ExpectDecodedInWorker(audit, 'getDayCalorieCurve');
      expect(audit.names, {_jsonLane});
    });

    test('LastResultCache.read (B7): a table hit decodes in a worker, the '
        'second read is a memory hit', () async {
      await p25SeedLastResults();
      final cache = LastResultCache();

      final first = await cache.read<Map<String, dynamic>>('beats|2025-06-01');
      await audit.settle();
      final dispatched = audit.dispatches.length;
      final second = await cache.read<Map<String, dynamic>>('beats|2025-06-01');

      expect((first!.value['nn'] as List), hasLength(6000));
      p25ExpectDecodedInWorker(audit, 'LastResultCache.read');
      expect(audit.names, {_jsonLane});
      expect(second!.value, same(first.value),
          reason: 'memory hit: the promoted value, not a second decode');
      expect(audit.dispatches.length, dispatched);
    });

    test('LastResultCache.read: a miss, a corrupt row and a wrong type are '
        'still nulls', () async {
      await p25SeedLastResults();
      final cache = LastResultCache();

      expect(await cache.read<Map<String, dynamic>>('absent'), isNull);
      expect(await cache.read<Map<String, dynamic>>('corrupt'), isNull);
      expect(await cache.read<Map<String, dynamic>>('circadian'), isNull);
      expect(await cache.read<List<dynamic>>('beats|2025-06-01'), isNull);
    });

    test('LastResultCache.put (B7): the encode runs in a worker; put itself '
        'returns at once and memory has the value before the table does',
        () async {
      final cache = LastResultCache(now: () => DateTime.fromMillisecondsSinceEpoch(9100));
      final value = p25BigArtifact();

      cache.put<Map<String, dynamic>>('put|big', value, sig: 's1');
      final instantly = cache.get<Map<String, dynamic>>('put|big');
      await cache.flush();
      await audit.settle();

      expect(instantly, isNotNull, reason: 'memory first, before any worker');
      expect(instantly!.value, same(value));
      p25ExpectDecodedInWorker(audit, 'LastResultCache.put');
      final row = await LocalDb.lastResult('put|big');
      expect(row, isNotNull);
      expect(row!.payload.length, greaterThan(50000));
      expect(row.sig, 's1');
    });
  });

  // -- 3. cached, and a warm fills it --------------------------------------------

  group('3. cached, invalidated by a rewrite, filled by a warm', () {
    test('a second sleepWindows over unchanged rows costs no dispatch',
        () async {
      await p25SeedWindows(db);
      final r = repo();
      final first = await r.sleepWindows(days: 14);
      await audit.settle();
      final dispatched = audit.dispatches.length;

      final second = await r.sleepWindows(days: 14);

      expect(dispatched, greaterThanOrEqualTo(1), reason: 'guard: the first read decoded');
      expect(audit.dispatches.length, dispatched, reason: why());
      expect(p25Text(second), p25Text(first));
    });

    test('a rewritten window row is decoded again and shows its new value, '
        'even when only the window text changed (same computed_at)', () async {
      await p25Row(db, p25WindowDays[0],
          window: '{"onset_ms":1746000000000,"offset_ms":1746028800000}', computedAt: 3000);
      final r = repo();
      final before = await r.sleepWindows(days: 14);
      await audit.settle();
      final dispatched = audit.dispatches.length;

      await p25Row(db, p25WindowDays[0],
          window: '{"onset_ms":1746010000000,"offset_ms":1746040000000}', computedAt: 3000);
      final after = await r.sleepWindows(days: 14);

      expect(before.single['onset_ts'], 1746000000);
      expect(after.single['onset_ts'], 1746010000, reason: 'never the cached value');
      expect(after.single['wake_ts'], 1746040000);
      expect(audit.dispatches.length, greaterThan(dispatched),
          reason: 'the changed row was decoded again');
    });

    test('a store that was wiped and reopened serves no old window', () async {
      await p25Row(db, p25WindowDays[0],
          window: '{"onset_ms":1746000000000,"offset_ms":1746028800000}', computedAt: 3000);
      final r = repo();
      await r.sleepWindows(days: 14);

      await db.delete('day_result');
      final fresh = await p21Reopen();
      await p25Row(fresh, p25WindowDays[0],
          window: '{"onset_ms":1747700000000,"offset_ms":1747729000000}', computedAt: 3000);
      final rows = await r.sleepWindows(days: 14);

      expect(rows.single['date'], p25WindowDays[0]);
      expect(rows.single['onset_ts'], 1747700000);
    });

    test('after the publish gate\'s warm, sleepWindows(14) costs no decode',
        () async {
      await p25SeedWindows(db);
      final store = BundleStore();
      p22UseStore(store);
      final gate = PublishGate.standard(store: store, effects: P25Effects());
      addTearDown(gate.dispose);

      await gate.publishAndWait();
      await audit.settle();
      expect(audit.names, contains(_jsonLane),
          reason: 'the warm itself decoded the window rows, in a worker '
              '(without this the zero below is true today for the wrong reason: '
              'the rows are decoded inline and nothing is dispatched)');
      audit.dispatches.clear();
      final windows = await repo().sleepWindows(days: 14);
      await audit.settle();

      expect(windows, hasLength(14));
      expect(audit.dispatches, isEmpty,
          reason: 'the warm decoded the window rows (4.5: the warm set is '
              'Home\'s real inputs, "the window_json rows behind '
              'sleepWindows(days: 14)"); ${why()}');
    });

    test('after the publish gate\'s warm, Home\'s wake estimate costs no decode '
        '(one history night, the crossday baseline, a wake row for today)',
        () async {
      // One history day only: the latest-night walk reads three payloads at a
      // time, so a second old day would be read ahead and say nothing about
      // the wake row. Past P2.2's chunks, this fixture isolates the wake row.
      final today = p23Day(0);
      await p22Seed(db, p23Day(1), p22DayBundle(p23Day(1), i: 2), computedAt: 1002);
      await p25Wake(db, today, {
        'steps': 5123.4,
        'calories': 480.4,
        'absent_notes': {'spo2': 'no_input'},
      });
      await LocalDb.putBaseline(
        'crossday',
        '{"algo_version":$p21Version,"built_for_day":"$today",'
            '"sleep_coach":{"need":{"value":{"need_sec":28800}}},"load":{"acwr":1.1}}',
      );
      final store = BundleStore();
      p22UseStore(store);
      final gate = PublishGate.standard(store: store, effects: P25Effects());
      addTearDown(gate.dispose);

      await gate.publishAndWait();
      await audit.settle();
      audit.dispatches.clear();
      final strain = await repo().getDayStrain(today);
      await audit.settle();

      expect(strain['steps'], 5123, reason: 'the wake estimate answered the steps');
      expect(audit.dispatches, isEmpty,
          reason: 'the warm decoded the wake row; ${why()}');
    });

    test('before any warm the same reads do decode (guard for the test above)',
        () async {
      await p25SeedWindows(db);
      final today = p23Day(0);
      await p22Seed(db, p23Day(1), p22DayBundle(p23Day(1), i: 2), computedAt: 1002);
      await p25Wake(db, today, {'steps': 5123.4});
      final r = repo();

      await r.sleepWindows(days: 14);
      await r.getDayStrain(today);
      await audit.settle();

      expect(audit.names, contains(_jsonLane),
          reason: 'cold: the wake row and the windows use the generic lane');
    });
  });

  // -- 4. the health export streams ---------------------------------------------

  group('4. HealthExporter streams (B12)', () {
    final days = [for (var i = 1; i <= 20; i++) '2025-03-${i.toString().padLeft(2, '0')}'];

    Future<void> seed() async {
      for (var i = 0; i < days.length; i++) {
        await p22Seed(db, days[i], p22DayBundle(days[i], i: i % 9), finalized: true, computedAt: 1000 + i);
      }
    }

    Future<void> export() async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_health'), (c) async => true);
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_health'), null));
      await HealthExporter().exportAll();
    }

    test('every exported day is decoded exactly once, through the store\'s '
        'lane, in chunks of at most eight', () async {
      final lane = P22Lane();
      p22UseStore(p22Store(lane));
      await seed();

      await export();

      expect(lane.payloads, days.length, reason: 'one decode per day');
      expect(lane.sizes, everyElement(lessThanOrEqualTo(BundleStore.maxChunkRows)),
          reason: 'sizes: ${lane.sizes}');
    });

    test('the source text held undecoded never exceeds one chunk, however '
        'many days are pending', () async {
      final lane = P22Lane();
      final store = p22Store(lane);
      p22UseStore(store);
      await seed();
      var worst = 0;
      lane.hook = (index, chunk) async {
        // payloads read out of the database minus payloads that reached the
        // lane (this chunk included): text read ahead of the decode.
        final heldAhead = store.debugPayloadReads - lane.payloads;
        if (heldAhead > worst) worst = heldAhead;
      };

      await export();

      expect(lane.payloads, days.length, reason: 'guard: the export decoded');
      expect(worst, lessThanOrEqualTo(BundleStore.maxChunkRows));
    });

    test('nothing is cached: the first and the last exported day are not hits '
        'afterwards', () async {
      final lane = P22Lane();
      final store = p22Store(lane);
      p22UseStore(store);
      await seed();
      await export();
      final decoded = lane.payloads;

      final first = await store.read(BundleSource.day(days.first));
      final last = await store.read(BundleSource.day(days.last));

      expect(decoded, days.length, reason: 'guard: the export decoded');
      expect(first, isA<BundleOk>());
      expect((first as BundleOk).fromCache, isFalse);
      expect((last as BundleOk).fromCache, isFalse,
          reason: 'a one-shot export must not fill the 12 MB cache or evict '
              'what the screens need');
    });

    test('the export reads through the store, not around it', () async {
      final lane = P22Lane();
      final store = p22Store(lane);
      p22UseStore(store);
      await seed();

      await export();

      expect(store.debugPayloadReads, greaterThanOrEqualTo(days.length),
          reason: 'the payload texts came out of the database via the store');
    });
  });
}
