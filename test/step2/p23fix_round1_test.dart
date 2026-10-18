// P2.3 fix round 1 (Sol r1 = REVISE). Findings 1, 2, 4, 5, 6, 7; the imports
// (finding 3) are in p23fix_import_test.dart.
//
//   1  the gate acknowledges only the sequence it captured before each refresh;
//      a commit that arrives during refresh #2, during the warm or during the
//      revalidation warm gets a trailing run, so the last bump never carries
//      freshness older than the last commit.
//   2  freshness writes have ONE owner: concurrent `refreshComputeFreshness`
//      calls (a reader, the gate, startup) never overlap, and an older run can
//      not land after a newer one.
//   4  a cold repository with historical sleep, no freshness row and no input
//      for today still answers with the prior night.
//   5  the freshness scan pairs each projection with the metadata of the SAME
//      revision: a deleted row is not chosen through its old readiness column,
//      and a replaced row does not pair new sleep with an old computed_at.
//   6  the warm set resolves the freshness row's overnight day directly, even
//      when it is older than the 14 newest rows.
//   7  the startup warm has one deadline across resolution and warm.

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

const _name = 'p23fix_round1.db';

/// Runs [onRefresh] / [onWarm] after the real step with the 1-based call number,
/// so a test can commit a REAL row "during" a refresh or a warm and request the
/// gate, exactly as a derive does after a commit.
class _HookedSteps implements PublishGateSteps {
  _HookedSteps(this.inner, {this.onRefresh, this.onWarm});
  final PublishGateSteps inner;
  final Future<void> Function(int n)? onRefresh;
  final Future<void> Function(int n)? onWarm;
  int refreshes = 0;
  int warms = 0;

  @override
  Future<void> refreshFreshness() async {
    final n = ++refreshes;
    await inner.refreshFreshness();
    await onRefresh?.call(n);
  }

  @override
  Future<Map<String, int>> servedRevisions() => inner.servedRevisions();

  @override
  Future<void> warm(Set<String> sources) async {
    final n = ++warms;
    await inner.warm(sources);
    await onWarm?.call(n);
  }

  @override
  void bump() => inner.bump();

  @override
  void log(String line) => inner.log(line);
}

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

  group('1: the gate acknowledges only what it captured (fake steps)', () {
    test('a request during refresh #2 gets exactly one trailing run', () {
      fakeAsync((async) {
        final r = P23Rig()..holdRefresh = Completer<void>();
        r.gate.request();
        async.flushMicrotasks();
        r.gate.request(); // during refresh #1: folded, refresh #2 follows

        final first = r.holdRefresh!;
        r.holdRefresh = Completer<void>();
        first.complete();
        async.flushMicrotasks();
        expect(r.count('refresh'), 2, reason: 'refresh #2 is running');

        r.gate.request(); // during refresh #2: NOT covered by it
        final second = r.holdRefresh!;
        r.holdRefresh = null;
        second.complete();
        async.flushMicrotasks();

        expect(r.events, [
          'refresh', 'refresh', 'revs', 'warm:A,B', 'bump',
          'refresh', 'revs', 'warm:A,B', 'bump',
        ]);
        expect(r.gate.debugRuns, 2);
        r.gate.dispose();
      });
    });

    test('a request during the warm that follows a folded request still gets '
        'its own refresh before the bump', () {
      fakeAsync((async) {
        final r = P23Rig()
          ..holdRefresh = Completer<void>()
          ..holdWarm = Completer<void>()
          ..revs = [
            {'A': 1},
            {'A': 2},
          ];
        r.gate.request();
        async.flushMicrotasks();
        r.gate.request(); // during refresh #1
        final h = r.holdRefresh!;
        r.holdRefresh = null;
        h.complete();
        async.flushMicrotasks();
        expect(r.events, ['refresh', 'refresh', 'revs', 'warm:A']);

        r.gate.request(); // during the warm
        final w = r.holdWarm!;
        r.holdWarm = null;
        w.complete();
        async.flushMicrotasks();

        expect(r.count('refresh'), 3, reason: 'the old code skipped this one');
        expect(r.count('bump'), 1);
        expect(r.events.indexOf('bump'), r.events.lastIndexOf('refresh') + 3,
            reason: 'refresh, revs, warm of the difference, then the bump');
        r.gate.dispose();
      });
    });

    test('a request during the revalidation warm gets a trailing run', () {
      fakeAsync((async) {
        final r = P23Rig()
          ..holdWarm = Completer<void>()
          ..revs = [
            {'A': 1},
            {'A': 2},
            {'A': 3},
          ];
        r.gate.request();
        async.flushMicrotasks();
        r.gate.request(); // during the warm: refresh again, revalidate
        final w1 = r.holdWarm!;
        r.holdWarm = Completer<void>();
        w1.complete();
        async.flushMicrotasks();
        expect(r.events.last, 'warm:A', reason: 'the revalidation warm is running');

        r.gate.request(); // during the revalidation warm
        final w2 = r.holdWarm!;
        r.holdWarm = null;
        w2.complete();
        async.flushMicrotasks();

        expect(r.count('bump'), 2, reason: 'the swallowed request gets its run');
        expect(r.events.sublist(r.events.indexOf('bump') + 1).first, 'refresh');
        expect(r.events.last, 'bump');
        expect(r.gate.debugRuns, 2);
        r.gate.dispose();
      });
    });
  });

  group('1: the last bump carries freshness of the last commit (real rows)', () {
    late List<int?> computedAtAtBump;
    late List<Future<void>> reads;
    late PublishGate gate;
    late _HookedSteps steps;

    /// Replace today's row with [computedAt] (a real commit) and request.
    Future<void> commit(int computedAt) async {
      await p23Row(db, p23Day(0), p23Payload(sleep: true, readiness: 60), computedAt: computedAt);
      gate.request();
    }

    void build({
      Future<void> Function(int n)? onRefresh,
      Future<void> Function(int n)? onWarm,
    }) {
      computedAtAtBump = [];
      reads = [];
      final inner = LocalPublishGateSteps(
        store: store,
        effects: P23Effects(
          onLog: (_) {},
          onBump: () => reads.add(p23FreshnessRows(db).then((rows) {
            final today = jsonDecode(rows['today']!) as Map;
            computedAtAtBump.add((today['activity_computed_at'] as num?)?.toInt());
          })),
        ),
      );
      steps = _HookedSteps(inner, onRefresh: onRefresh, onWarm: onWarm);
      gate = PublishGate(steps: steps);
    }

    Future<void> run() async {
      gate.request();
      await gate.idle;
      await Future.wait(reads);
    }

    setUp(() async {
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 1000);
      await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 900);
    });
    tearDown(() => gate.dispose());

    test('a commit during refresh #2 is in the freshness of the NEXT bump',
        () async {
      build(onRefresh: (n) async {
        if (n == 1) await commit(2000);
        if (n == 2) await commit(3000);
      });

      await run();

      expect(computedAtAtBump, [2000, 3000]);
      expect(steps.refreshes, 3, reason: 'two for the first bump, one trailing');
      expect(gate.debugRuns, 2);
    });

    test('a commit during the warm, after a folded one, is in the single bump',
        () async {
      build(
        onRefresh: (n) async {
          if (n == 1) await commit(2000);
        },
        onWarm: (n) async {
          if (n == 1) await commit(3000);
        },
      );

      await run();

      expect(computedAtAtBump, [3000], reason: 'the freshness is not older than the last commit');
      expect(steps.refreshes, 3);
      expect(gate.debugRuns, 1);
    });

    test('a commit during the revalidation warm gets one trailing run and the '
        'final bump reflects it', () async {
      build(
        onRefresh: (n) async {
          if (n == 1) await commit(2000);
        },
        onWarm: (n) async {
          if (n == 1) await commit(3000);
          if (n == 2) await commit(4000);
        },
      );

      await run();

      expect(computedAtAtBump.last, 4000);
      expect(computedAtAtBump, [3000, 4000]);
      expect(gate.debugRuns, 2);
    });
  });

  group('2: one owner for freshness writes', () {
    test('an older refresh can not land after a newer one: raw data that '
        'arrives while the first is parked before its write is in the final '
        'state', () async {
      await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 900);
      final release = Completer<void>();
      var calls = 0;
      LocalDb.debugBeforeFreshnessWrite = _Park(() => calls++ == 0 ? release.future : null);
      addTearDown(() => LocalDb.debugBeforeFreshnessWrite = null);

      final older = LocalDb.refreshComputeFreshness(); // read: no raw for today
      await p22Until(() => calls == 1, 'the older run parks before its write');
      await p23Raw(db, p23Day(0)); // raw data reaches today
      final newer = LocalDb.refreshComputeFreshness();
      // Unserialised, the newer run reaches its write while the older one is
      // still parked; serialised it waits behind it and never gets here.
      for (var i = 0; i < 3000 && calls < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      release.complete();
      await Future.wait([older, newer]);

      final rows = await p23FreshnessRows(db);
      final today = jsonDecode(rows['today']!) as Map;
      expect(today['overnight_state'], 'building',
          reason: 'raw data reached today; the older run said "missing"');
      expect(today['activity_state'], 'building',
          reason: 'the older run must not overwrite the newer answer');
      expect((jsonDecode(rows['capture']!) as Map)['latest_raw_day'], p23Day(0));
    });

    test('calls that arrive during a run share ONE trailing run', () async {
      await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 900);
      lane.hold(0);
      LocalDb.debugFreshnessRuns = 0;

      final a = LocalDb.refreshComputeFreshness();
      await lane.arrived(1);
      final b = LocalDb.refreshComputeFreshness();
      final c = LocalDb.refreshComputeFreshness();
      await p22Flush(db);
      expect(LocalDb.debugFreshnessRuns, 1, reason: 'nothing runs beside the first');
      lane.release(0);
      await Future.wait([a, b, c]);

      expect(LocalDb.debugFreshnessRuns, 2);
    });

    test('a failed run fails its callers and does not wedge the owner',
        () async {
      await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 900);
      lane.hook = (i, c) async => throw StateError('lane down');
      await expectLater(LocalDb.refreshComputeFreshness(), throwsA(anything));

      lane.hook = null;
      await LocalDb.refreshComputeFreshness();

      final today = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(today['overnight_day'], p23Day(1));
    });
  });

  group('4: a cold repository with history only', () {
    test('no freshness row, no input for today: Home still gets the prior '
        'night, not an empty answer', () async {
      await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 70),
          computedAt: 4000, readinessColumn: 70);
      final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);

      final out = await repo.getToday();

      expect((out['sleep'] as Map), isNotEmpty);
      final today = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(today['showing_prior_overnight'], true);
      expect(today['overnight_day'], p23Day(1));
    });
  });

  group('5: metadata of the same revision as the projection', () {
    test('a row deleted while it is decoded is not chosen as the recovery day '
        'through its old readiness column', () async {
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
      await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 4000, readinessColumn: 70);
      await p23Row(db, p23Day(2), p23Payload(sleep: true), computedAt: 3000);
      var fired = false;
      lane.hook = (i, c) async {
        if (fired) return;
        fired = true;
        await LocalDb.deleteDays({p23Day(1)});
      };

      await LocalDb.refreshComputeFreshness();

      expect(fired, isTrue);
      final today = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(today['recovery_day'], isNull, reason: 'the only readiness was on the deleted row');
      expect(today['recovery_computed_at'], isNull);
      expect(today['overnight_day'], p23Day(2));
    });

    test('a replaced row does not pair its new content with the old '
        'computed_at', () async {
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
      await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 4000);
      var fired = false;
      lane.hook = (i, c) async {
        if (fired) return;
        fired = true;
        await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 80),
            computedAt: 9000, readinessColumn: 80);
      };

      await LocalDb.refreshComputeFreshness();

      expect(fired, isTrue);
      final today = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(today['overnight_day'], p23Day(1));
      expect(today['overnight_computed_at'], 9000);
      expect(today['recovery_day'], p23Day(1));
      expect(today['recovery_computed_at'], 9000);
    });

    test('an existing row whose payload is undecodable still counts through '
        'its readiness column (the golden fallback)', () async {
      await p23Row(db, p23Day(1), '{not json', computedAt: 4000, readinessColumn: 70);

      await LocalDb.refreshComputeFreshness();

      final today = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(today['recovery_day'], p23Day(1));
      expect(today['recovery_computed_at'], 4000);
    });
  });

  group('6: the warm set resolves the selected overnight row directly', () {
    test('an overnight day older than the 14 newest rows is in the set',
        () async {
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
      for (var i = 1; i <= 19; i++) {
        await p23Row(db, p23Day(i), p23Payload(sleep: i == 20 - 0 ? true : false), computedAt: 4000 - i);
      }
      await p23Row(db, p23Day(20), p23Payload(sleep: true), computedAt: 3000);
      await LocalDb.refreshComputeFreshness();
      final fresh = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(fresh['overnight_day'], p23Day(20), reason: 'guard: freshness scans 30 rows');

      final set = await HomeWarmSet.resolve(today: p23Day(0));

      expect([for (final s in set.bundles) '${s.kind}|${s.k1}'],
          contains('day_result|${p23Day(20)}'));
    });
  });

  group('7: the startup warm has one deadline', () {
    test('a slow resolution followed by a slow warm is cut at 3 s in total',
        () {
      fakeAsync((async) {
        final steps = _SlowSteps(
          resolveAfter: const Duration(milliseconds: 2000),
          warmAfter: const Duration(milliseconds: 2000),
        );
        var done = false;
        WarmResult? out = const WarmDone(-1);
        StartupWarm(headless: false, steps: steps).run().then((r) {
          out = r;
          done = true;
        });

        async.elapse(const Duration(milliseconds: 2999));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 2));
        expect(done, isTrue, reason: 'resolution and warm share the 3 s');
        expect(out, isNull);
      });
    });

    test('stages that together fit the deadline still complete', () {
      fakeAsync((async) {
        final steps = _SlowSteps(
          resolveAfter: const Duration(milliseconds: 1000),
          warmAfter: const Duration(milliseconds: 1500),
        );
        WarmResult? out;
        StartupWarm(headless: false, steps: steps).run().then((r) => out = r);

        async.elapse(const Duration(milliseconds: 2600));

        expect(out, isA<WarmDone>());
      });
    });
  });
}

class _Park implements FreshnessWriteProbe {
  _Park(this.onWrite);
  final Future<void>? Function() onWrite;
  @override
  Future<void> beforeWrite() async => await onWrite();
}

class _SlowSteps implements StartupWarmSteps {
  _SlowSteps({required this.resolveAfter, required this.warmAfter});
  final Duration resolveAfter;
  final Duration warmAfter;

  @override
  Future<HomeWarmSet> resolve() => Future.delayed(
    resolveAfter,
    () => HomeWarmSet(
      bundles: [BundleSource.day(p23Day(0))],
      wakeDay: null,
      windowDays: const [],
    ),
  );

  @override
  Future<WarmResult> warm(List<BundleSource> sources, int maxSourceBytes) =>
      Future.delayed(warmAfter, () => WarmDone(sources.length));
}
