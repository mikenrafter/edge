// P2.3 PublishGate (design 02 step 2, section 4.5).
//
// One serialised loop: (1) the freshness refresh (a durable write), (2) a
// best-effort warm, (3) the revision bump. `request()` increments a sequence;
// if it moved during (1)-(2) the loop compares the served revisions with what
// it warmed, warms the difference once, then bumps. A request that arrives
// during the bump gets a trailing run. A warm failure or a 2 s timeout never
// suppresses the bump.
//
// Part 1 drives the gate with fake steps under fakeAsync (no clock, no
// database). Part 2 runs the standard wiring over a real database and a
// recording decode lane.
//
// A request during refresh or warming causes one freshness refresh after the
// later commit, then revalidates and warms only changed sources before one bump.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/publish_gate.dart';

import 'support/p23_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  group('the loop (fake steps)', () {
    test('one request: refresh, then the served revisions, then a warm of '
        'them, then one bump', () {
      fakeAsync((async) {
        final r = P23Rig();
        r.gate.request();
        async.flushMicrotasks();

        expect(r.events, ['refresh', 'revs', 'warm:A,B', 'bump']);
        expect(r.gate.debugRuns, 1);
        r.gate.dispose();
      });
    });

    test('requests during the refresh are folded: one refresh in flight, one '
        'bump after a second freshness refresh', () {
      fakeAsync((async) {
        final r = P23Rig()..holdRefresh = Completer<void>();
        r.gate.request();
        async.flushMicrotasks();
        r.gate.request();
        r.gate.request();
        async.flushMicrotasks();
        expect(r.count('refresh'), 1, reason: 'no second refresh starts beside it');

        r.holdRefresh!.complete();
        async.flushMicrotasks();

        expect(r.count('refresh'), 2);
        expect(r.count('bump'), 1);
        expect(r.maxInFlight, 1);
        expect(r.events.indexOf('refresh', 1), lessThan(r.events.indexOf('bump')));
        r.gate.dispose();
      });
    });

    test('a commit during step (1) gets a second freshness refresh before the '
        'single bump', () {
      fakeAsync((async) {
        final r = P23Rig()..holdRefresh = Completer<void>();
        r.gate.request();
        async.flushMicrotasks();
        r.gate.request();
        async.flushMicrotasks();

        r.holdRefresh!.complete();
        async.flushMicrotasks();

        expect(r.events, ['refresh', 'refresh', 'revs', 'warm:A,B', 'bump']);
        expect(r.count('bump'), 1);
        expect(r.count('refresh'), 2);
        r.gate.dispose();
      });
    });

    test('the sequence moved during the warm: the served revisions are '
        'compared again and only the difference is warmed, once, then one '
        'bump', () {
      fakeAsync((async) {
        final r = P23Rig()
          ..holdWarm = Completer<void>()
          ..revs = [
            {'A': 1, 'B': 5},
            {'A': 2, 'B': 5, 'C': 1},
          ];
        r.gate.request();
        async.flushMicrotasks();
        expect(r.events, ['refresh', 'revs', 'warm:A,B']);

        r.gate.request(); // a new day landed while the warm ran
        r.holdWarm!.complete();
        async.flushMicrotasks();

        expect(r.events, [
          'refresh', 'revs', 'warm:A,B', 'refresh',
          'revs', 'warm:A,C', // A changed, C is new, B is untouched
          'bump',
        ]);
        r.gate.dispose();
      });
    });

    test('the sequence moved but nothing was replaced: nothing more is warmed, '
        'still one bump', () {
      fakeAsync((async) {
        final r = P23Rig()
          ..holdWarm = Completer<void>()
          ..revs = [
            {'A': 1},
          ];
        r.gate.request();
        async.flushMicrotasks();
        r.gate.request();
        r.holdWarm!.complete();
        async.flushMicrotasks();

        expect(r.count('warm'), 1);
        expect(r.count('revs'), 2);
        expect(r.events.last, 'bump');
        expect(r.count('bump'), 1);
        r.gate.dispose();
      });
    });

    test('an unmoved sequence does not look at the revisions a second time',
        () {
      fakeAsync((async) {
        final r = P23Rig();
        r.gate.request();
        async.flushMicrotasks();
        expect(r.count('revs'), 1);
        r.gate.dispose();
      });
    });

    test('a request that arrives during the bump gets a trailing run; older '
        'work never finishes after newer work', () {
      fakeAsync((async) {
        final r = P23Rig();
        var requested = false;
        r.onBump = () {
          if (!requested) {
            requested = true;
            r.gate.request();
          }
        };
        r.gate.request();
        async.flushMicrotasks();

        expect(r.events, [
          'refresh', 'revs', 'warm:A,B', 'bump',
          'refresh', 'revs', 'warm:A,B', 'bump',
        ]);
        expect(r.maxInFlight, 1);
        expect(r.gate.debugRuns, 2);
        r.gate.dispose();
      });
    });

    test('a request after the loop went idle starts a new run', () {
      fakeAsync((async) {
        final r = P23Rig();
        r.gate.request();
        async.flushMicrotasks();
        r.gate.request();
        async.flushMicrotasks();

        expect(r.count('bump'), 2);
        expect(r.gate.debugRuns, 2);
        r.gate.dispose();
      });
    });

    test('a warm that throws is logged and the bump still happens', () {
      fakeAsync((async) {
        final r = P23Rig()..warmThrows = StateError('warm down');
        r.gate.request();
        async.flushMicrotasks();

        expect(r.events.last, 'bump');
        expect(r.logs.join('\n'), contains('warm'));
        expect(r.logs.join('\n'), contains('warm down'));
        r.gate.dispose();
      });
    });

    test('a warm that never finishes is cut at 2 s and the bump happens',
        () {
      fakeAsync((async) {
        final r = P23Rig()..holdWarm = Completer<void>();
        r.gate.request();
        async.flushMicrotasks();

        async.elapse(const Duration(milliseconds: 1999));
        expect(r.count('bump'), 0, reason: 'the budget is 2 s');

        async.elapse(const Duration(milliseconds: 2));
        expect(r.count('bump'), 1);
        expect(r.logs.join('\n'), contains('warm'));

        r.holdWarm!.complete(); // the late warm changes nothing
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        expect(r.count('bump'), 1);
        expect(r.gate.debugRuns, 1);
        r.gate.dispose();
      });
    });

    test('the warm budget is a parameter', () {
      fakeAsync((async) {
        final r = P23Rig()..holdWarm = Completer<void>();
        final gate = PublishGate(
          steps: r,
          warmBudget: const Duration(milliseconds: 300),
        );
        gate.request();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 301));
        expect(r.count('bump'), 1);
        gate.dispose();
      });
    });

    test('a refresh that throws is logged and the loop carries on to the bump '
        '(as the coordinator does today)', () {
      fakeAsync((async) {
        final r = P23Rig()..refreshThrows = StateError('disk full');
        r.gate.request();
        async.flushMicrotasks();

        expect(r.logs.join('\n'), contains('freshness refresh failed'));
        expect(r.events.last, 'bump');
        r.gate.dispose();
      });
    });

    test('a failing revision query is logged and still bumps', () {
      fakeAsync((async) {
        final r = P23Rig()..revsThrow = StateError('meta down');
        r.gate.request();
        async.flushMicrotasks();

        expect(r.events.last, 'bump');
        expect(r.count('warm'), 0, reason: 'nothing known to warm');
        r.gate.dispose();
      });
    });

    test('a failed run does not stop the next request from running', () {
      fakeAsync((async) {
        final r = P23Rig()..refreshThrows = StateError('once');
        r.gate.request();
        async.flushMicrotasks();
        r.refreshThrows = null;
        r.gate.request();
        async.flushMicrotasks();

        expect(r.count('bump'), 2);
        r.gate.dispose();
      });
    });

    test('dispose during the warm: no bump, no further run', () {
      fakeAsync((async) {
        final r = P23Rig()..holdWarm = Completer<void>();
        r.gate.request();
        async.flushMicrotasks();

        r.gate.dispose();
        r.holdWarm!.complete();
        async.flushMicrotasks();
        r.gate.request();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));

        expect(r.count('bump'), 0);
        expect(r.count('refresh'), 1);
      });
    });

    test('idle completes after the bump, and at once when nothing is running',
        () {
      fakeAsync((async) {
        final r = P23Rig()..holdWarm = Completer<void>();
        var idleBeforeAnything = false;
        r.gate.idle.then((_) => idleBeforeAnything = true);
        async.flushMicrotasks();
        expect(idleBeforeAnything, isTrue);

        r.gate.request();
        async.flushMicrotasks();
        var idle = false;
        r.gate.idle.then((_) => idle = true);
        async.flushMicrotasks();
        expect(idle, isFalse, reason: 'the loop is still running');

        r.holdWarm!.complete();
        async.flushMicrotasks();
        expect(idle, isTrue);
        expect(r.events.last, 'bump');
        r.gate.dispose();
      });
    });
  });

  group('the standard wiring (real database, recording lane)', () {
    const name = 'p23_publish_gate.db';
    late Database db;
    late P22Lane lane;
    late BundleStore store;
    late List<String> logs;
    late List<Set<String>> cachedAtBump;
    late List<Map<String, String?>> freshnessAtBump;
    late PublishGate gate;

    /// today (no sleep), d1 (the night), older days, a crossday rollup, wake
    /// features for today.
    Future<void> seedHome() async {
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
      await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 70), computedAt: 4000, readinessColumn: 70);
      for (var i = 2; i <= 5; i++) {
        await p23Row(db, p23Day(i), p23Payload(sleep: true), computedAt: 4000 - i);
      }
      await p21RawBaseline(db, 'crossday', '{"built_for_day":"${p23Day(0)}"}');
      await p23Wake(db, p23Day(0), 777);
    }

    Set<String> cachedFull() => {
      for (final k in store.debugCachedKeys)
        if (k.projection == ProjectionId.full) '${k.kind}|${k.k1}',
    };

    setUp(() async {
      db = await p21Fresh(name);
      lane = P22Lane();
      store = p22Store(lane);
      p22UseStore(store);
      logs = [];
      cachedAtBump = [];
      freshnessAtBump = [];
      gate = PublishGate.standard(
        store: store,
        effects: P23Effects(
          onLog: logs.add,
          onBump: () {
          cachedAtBump.add(cachedFull());
          // The bump is synchronous; read the durable rows asynchronously and
          // let the test await them through `idle`.
          p23FreshnessRows(db).then(freshnessAtBump.add);
          },
        ),
      );
    });
    tearDown(() async {
      gate.dispose();
      await p21Drop(name);
    });

    Future<void> publish() async {
      gate.request();
      await gate.idle;
      await p22Flush(db);
    }

    group('the warm set is Home\'s real inputs', () {
      test('today, the night, the crossday rollup; the wake row; the window '
          'days of the last 14', () async {
        await seedHome();
        await LocalDb.refreshComputeFreshness();

        final set = await HomeWarmSet.resolve(today: p23Day(0));

        expect(
          [for (final s in set.bundles) '${s.kind}|${s.k1}'],
          ['day_result|${p23Day(0)}', 'day_result|${p23Day(1)}', 'baselines|crossday'],
        );
        expect(set.wakeDay, p23Day(0));
        expect(set.windowDays, [for (var i = 0; i <= 5; i++) p23Day(i)]);
      });

      test('the night is the freshness row\'s overnight day, and a night that '
          'is today is listed once', () async {
        await p23Row(db, p23Day(0), p23Payload(sleep: true, readiness: 70), computedAt: 5000);
        await LocalDb.refreshComputeFreshness();

        final set = await HomeWarmSet.resolve(today: p23Day(0));

        expect([for (final s in set.bundles) '${s.kind}|${s.k1}'],
            ['day_result|${p23Day(0)}']);
      });

      test('what is absent is absent: no rows, no baseline, no wake row',
          () async {
        await LocalDb.refreshComputeFreshness();

        final set = await HomeWarmSet.resolve(today: p23Day(0));

        expect(set.bundles, isEmpty);
        expect(set.wakeDay, isNull);
        expect(set.windowDays, isEmpty);
      });

      test('at most 14 window days, newest first', () async {
        for (var i = 0; i < 20; i++) {
          await p23Row(db, p23Day(i), p23Payload(sleep: true), computedAt: 100 - i);
        }
        await LocalDb.refreshComputeFreshness();

        final set = await HomeWarmSet.resolve(today: p23Day(0));

        expect(set.windowDays, [for (var i = 0; i < 14; i++) p23Day(i)]);
      });

      test('resolving reads no payload', () async {
        await seedHome();
        await LocalDb.refreshComputeFreshness();
        final reads = store.debugPayloadReads;
        final chunks = lane.chunks.length;

        await HomeWarmSet.resolve(today: p23Day(0));

        expect(store.debugPayloadReads, reads);
        expect(lane.chunks.length, chunks);
      });
    });

    group('a publish', () {
      test('writes the freshness, warms Home\'s bundles, THEN bumps: at the bump '
          'the durable rows exist and the warm set is cached', () async {
        await seedHome();

        await publish();

        expect(cachedAtBump, hasLength(1));
        expect(cachedAtBump.single, {
          'day_result|${p23Day(0)}',
          'day_result|${p23Day(1)}',
          'baselines|crossday',
        });
        expect(freshnessAtBump.single['today'], isNotNull);
        expect(jsonOf(freshnessAtBump.single['today'])['overnight_day'], p23Day(1));
      });

      test('Home\'s next read decodes no full bundle: getToday and getInsights '
          'are served from the warm', () async {
        await seedHome();
        await publish();
        final full = lane.chunks.expand((c) => c.projections).where((p) => p == 'full').length;
        final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);

        await repo.getToday();
        await repo.getInsights();

        expect(
          lane.chunks.expand((c) => c.projections).where((p) => p == 'full').length,
          full,
        );
      });

      test('it does not evict: a cached bundle outside the warm set is still '
          'cached afterwards (the revision key makes eviction unnecessary)',
          () async {
        await seedHome();
        await store.read(BundleSource.day(p23Day(4)));
        expect(cachedFull(), contains('day_result|${p23Day(4)}'));

        await publish();

        expect(cachedFull(), contains('day_result|${p23Day(4)}'));
      });

      test('a second publish with nothing changed decodes nothing and moves '
          'no payload', () async {
        await seedHome();
        await publish();
        final decoded = lane.payloads;
        final reads = store.debugPayloadReads;

        await publish();

        expect(lane.payloads, decoded);
        expect(store.debugPayloadReads, reads);
        expect(cachedAtBump, hasLength(2));
      });
    });

    group('stale and fencing', () {
      test('a row replaced while the warm decodes it: the bump comes once, and '
          'by then the cache holds the NEW revision, not the stale one',
          () async {
        await seedHome();
        var fired = false;
        lane.hook = (i, c) async {
          if (fired || !c.projections.contains('full')) return;
          fired = true;
          await p22Put(p23Day(0), 'override',
              payload: p23Payload(sleep: true, readiness: 99),
              reason: DayResultWrite.userOverride);
          gate.request(); // what the derive does after a commit
        };

        await publish();

        expect(fired, isTrue, reason: 'the warm decoded in the lane');
        expect(cachedAtBump, hasLength(1), reason: 'one run, one bump');
        final newRev = await p21DayRev(db, p23Day(0));
        final todayKeys = [
          for (final k in store.debugCachedKeys)
            if (k.projection == ProjectionId.full && k.k1 == p23Day(0)) k.rev,
        ];
        expect(todayKeys, [newRev], reason: 'only the current revision is cached');
        expect(cachedAtBump.single, contains('day_result|${p23Day(0)}'));
        final fulls = [
          for (final c in lane.chunks)
            for (var i = 0; i < c.payloadJson.length; i++)
              if (c.projections[i] == 'full') c.payloadJson[i],
        ];
        expect(fulls.where((t) => t.contains('"steps"') && !t.contains('"sleep"')),
            isNotEmpty, reason: 'the stale decode of the old today row happened');
        expect(fulls.where((t) => t.contains('"readiness":99')), isNotEmpty,
            reason: 'and the current row was decoded after it');
      });

      test('a warm that fails in the lane is logged; the freshness is written '
          'and the bump still happens', () async {
        await seedHome();
        lane.hook = (i, c) async {
          if (c.projections.contains('full')) throw StateError('lane down');
        };

        await publish();

        expect(cachedAtBump, hasLength(1));
        expect(freshnessAtBump.single['today'], isNotNull);
        expect(logs.join('\n'), contains('warm'));
        expect(store.debugFlightCount, 0);
        expect(store.debugReservedBytes, 0);
      });

      test('a row deleted between the freshness refresh and the warm is simply '
          'not warmed', () async {
        await seedHome();
        var fired = false;
        lane.hook = (i, c) async {
          if (fired || !c.projections.contains('full')) return;
          fired = true;
          await LocalDb.deleteDays({p23Day(1)});
          gate.request();
        };

        await publish();

        expect(cachedAtBump, hasLength(1));
        expect(cachedAtBump.single, isNot(contains('day_result|${p23Day(1)}')));
      });
    });
  });
}

Map<String, Object?> jsonOf(String? text) =>
    (jsonDecode(text!) as Map).cast<String, Object?>();
