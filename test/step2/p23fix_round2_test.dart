// P2.3 fix round 2 (Sol r2 + the full-suite regression).
//
//   A  the freshness owner (`LocalDb.refreshComputeFreshness`) is process-wide
//      state: a run begun by a caller whose zone later stops scheduling (a
//      fakeAsync body that returned) must not strand the owner and with it
//      every later caller (found as calc_power_wiring_test timing out).
//   B  a refresh that FAILED is not acknowledged: the bump still happens, the
//      sequence stays pending and is retried once, boundedly.
//   C  the startup warm never starts after its deadline.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/publish_gate.dart';

import 'support/p23_support.dart';

const _name = 'p23fix_round2.db';

class _FailOnce implements FreshnessWriteProbe {
  int calls = 0;
  @override
  Future<void> beforeWrite() async {
    if (calls++ == 0) throw StateError('transient projection failure');
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
    lane = P22Lane();
    store = p22Store(lane);
    p22UseStore(store);
  });
  tearDown(() async {
    LocalDb.debugBeforeFreshnessWrite = null;
    await p21Drop(_name);
  });

  group('A: the freshness owner outlives the zone of the caller that started a '
      'run', () {
    test('a run started inside a fakeAsync body that then returns does not '
        'strand later callers', () async {
      await p23Row(db, p23Day(1), p23Payload(sleep: true), computedAt: 900);

      fakeAsync((async) {
        unawaited(LocalDb.refreshComputeFreshness());
        async.flushMicrotasks();
      }); // the zone is gone; the run it started has not resumed there

      await LocalDb.refreshComputeFreshness().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the owner is wedged by a stopped zone'),
      );
      final today = jsonDecode((await p23FreshnessRows(db))['today']!) as Map;
      expect(today['overnight_day'], p23Day(1));
    });
  });

  group('B: a failed refresh is not acknowledged (fake steps)', () {
    test('the bump is not suppressed; one retry after the delay; then it '
        'gives up and stops', () {
      fakeAsync((async) {
        final r = P23Rig()..refreshThrows = StateError('disk full');
        final gate = PublishGate(
          steps: r,
          retryDelay: const Duration(milliseconds: 500),
        );
        gate.request();
        async.flushMicrotasks();

        expect(r.count('bump'), 1, reason: 'a refresh failure never suppresses the bump');
        expect(r.count('refresh'), 1);
        async.elapse(const Duration(milliseconds: 499));
        expect(r.count('refresh'), 1, reason: 'not before the delay');
        async.elapse(const Duration(milliseconds: 1));
        expect(r.count('refresh'), 2, reason: 'one retry');
        expect(r.count('bump'), 2);

        async.elapse(const Duration(hours: 1));
        expect(r.count('refresh'), 2, reason: 'bounded: no third attempt');
        expect(async.pendingTimers, isEmpty);
        gate.dispose();
      });
    });

    test('a retry that succeeds acknowledges: nothing runs again', () {
      fakeAsync((async) {
        final r = P23Rig()..refreshThrows = StateError('once');
        final gate = PublishGate(
          steps: r,
          retryDelay: const Duration(milliseconds: 500),
        );
        gate.request();
        async.flushMicrotasks();
        r.refreshThrows = null;
        async.elapse(const Duration(milliseconds: 500));
        expect(r.count('refresh'), 2);
        expect(r.count('bump'), 2);

        async.elapse(const Duration(hours: 1));
        expect(r.count('refresh'), 2);
        expect(r.count('bump'), 2);
        gate.dispose();
      });
    });

    test('dispose during the retry wait: no retry, no timer left', () {
      fakeAsync((async) {
        final r = P23Rig()..refreshThrows = StateError('down');
        final gate = PublishGate(
          steps: r,
          retryDelay: const Duration(milliseconds: 500),
        );
        gate.request();
        async.flushMicrotasks();
        gate.dispose();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(seconds: 5));
        expect(r.count('refresh'), 1);
        expect(r.count('bump'), 1);
      });
    });
  });

  group('B: a failed refresh after an import (real rows)', () {
    test('the refresh fails once: the bump still happens, and the FINAL bump '
        'sees the imported night', () async {
      // Home's freshness row is stamped before the import: nothing yet.
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 1000);
      await LocalDb.refreshComputeFreshness();
      expect(jsonDecode((await p23FreshnessRows(db))['today']!)['recovery_day'], isNull);
      // The import commits yesterday's scored night.
      await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 70),
          computedAt: 4000, readinessColumn: 70);
      final probe = _FailOnce();
      LocalDb.debugBeforeFreshnessWrite = probe;

      final seen = <Future<Object?>>[];
      final gate = PublishGate(
        steps: LocalPublishGateSteps(
          store: store,
          effects: P23Effects(
            onLog: (_) {},
            onBump: () => seen.add(p23FreshnessRows(db).then(
              (rows) => (jsonDecode(rows['today']!) as Map)['recovery_day'],
            )),
          ),
        ),
        retryDelay: Duration.zero,
      );
      addTearDown(gate.dispose);

      await gate.publishAndWait();
      final atBump = await Future.wait(seen);

      expect(atBump, hasLength(2), reason: 'the failed pass still bumped');
      expect(atBump.first, isNull, reason: 'that bump saw the stale row');
      expect(atBump.last, p23Day(1), reason: 'the final bump sees the import');
      expect(probe.calls, 2);
    });
  });

  group('C: the startup warm does not start after its deadline', () {
    test('a resolution that completes after the deadline: zero warm calls', () {
      fakeAsync((async) {
        final steps = _LateSteps(resolveAfter: const Duration(seconds: 4));
        var done = false;
        WarmResult? out = const WarmDone(-1);
        StartupWarm(headless: false, steps: steps).run().then((r) {
          out = r;
          done = true;
        });

        async.elapse(const Duration(milliseconds: 3001));
        expect(done, isTrue);
        expect(out, isNull);
        async.elapse(const Duration(seconds: 2)); // resolution lands at 4 s
        async.flushMicrotasks();

        expect(steps.resolved, 1);
        expect(steps.warmCalls, 0, reason: 'the deadline expired first');
      });
    });

    test('a resolution inside the deadline still warms', () {
      fakeAsync((async) {
        final steps = _LateSteps(resolveAfter: const Duration(seconds: 1));
        WarmResult? out;
        StartupWarm(headless: false, steps: steps).run().then((r) => out = r);

        async.elapse(const Duration(seconds: 2));

        expect(steps.warmCalls, 1);
        expect(out, isA<WarmDone>());
      });
    });
  });
}

class _LateSteps implements StartupWarmSteps {
  _LateSteps({required this.resolveAfter});
  final Duration resolveAfter;
  int resolved = 0;
  int warmCalls = 0;

  @override
  Future<HomeWarmSet> resolve() => Future.delayed(resolveAfter, () {
    resolved++;
    return HomeWarmSet(
      bundles: [BundleSource.day(p23Day(0))],
      wakeDay: null,
      windowDays: const [],
    );
  });

  @override
  Future<WarmResult> warm(List<BundleSource> sources, int maxSourceBytes) async {
    warmCalls++;
    return WarmDone(sources.length);
  }
}
