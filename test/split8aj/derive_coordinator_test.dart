// 8AJ seam 1: DeriveCoordinator in isolation, with fake collaborators. The
// same behaviours are pinned through AppState in the characterization tests;
// these prove the coordinator stands on its own and never reaches for AppState.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/compute/periodic_calculation_policy.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';
import 'package:openstrap_edge/state/recalc_state.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart' show WakeSamples;

import '../perf/support/p3_warmer_support.dart';
import 'support/derive_harness.dart';

const _db = 'openstrap_split8aj_derive_coordinator.db';

/// A host for the coordinator: every collaborator is a recorder.
class FakeHost {
  final logs = <String>[];
  int notifies = 0;
  bool disposed = false;
  bool warmHeld = false;
  bool healthSync = false;
  bool telemetry = false;
  bool healthShare = false;
  int steps = 0;
  int recovery = 0;
  int exports = 0;
  int reclaims = 0;
  Object? exportThrows;

  late final DeriveCoordinator coordinator = DeriveCoordinator(
    engine: () => engine ??= DerivationEngine(log: logs.add),
    profile: () => Profile.fromMap(const <String, dynamic>{}),
    log: logs.add,
    notify: () => notifies++,
    isDisposed: () => disposed,
    repo: () => null,
    warmHeld: () => warmHeld,
    refreshPhoneStepsToday: () async => steps++,
    maybeNotifyRecoveryReady: () async => recovery++,
    runHealthExport: () async {
      exports++;
      if (exportThrows != null) throw exportThrows!;
      return 2;
    },
    healthSyncEnabled: () => healthSync,
    telemetryConsent: () => telemetry,
    healthShareConsent: () => healthShare,
    maybeReclaimDiskSpace: () async => reclaims++,
    calculationPolicy: policy,
  );

  DerivationEngine? engine;
  PeriodicCalculationPolicy? policy;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late FakeHost host;
  DeriveCoordinator make() {
    final c = host.coordinator;
    addTearDown(c.dispose);
    c.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    return c;
  }

  setUp(() => host = FakeHost());

  group('construction', () {
    test('touches no collaborator until a pass runs (the engine in particular '
        'is resolved lazily)', () {
      final c = make();
      expect(host.engine, isNull);
      expect(host.notifies, 0);
      expect(host.logs, isEmpty);
      expect(c.recalc.value, RecalcState.idle);
      expect(c.insightsRevision.value, 0);
      expect(c.lastHomeRenderMs, isNull);
    });

    test('the notifiers are single objects', () {
      final c = make();
      expect(identical(c.insightsRevision, c.insightsRevision), isTrue);
      expect(identical(c.recalc, c.recalc), isTrue);
      expect(identical(c.scheduler, c.scheduler), isTrue);
    });
  });

  group('a pass', () {
    test('forwards its flags and maps the outcome', () async {
      final c = make();
      final calls = <HookCall>[];
      c.debugDeriveRun = deriveHook(days: ['d2', 'd1'], calls: calls);
      final o = await c.debugRunScheduled(kind: DeriveJobKind.light);
      expect(calls.single.heavy, isFalse);
      expect(calls.single.changedOnly, isTrue);
      expect(o.complete, isTrue);
      expect(o.computed, 2);

      await c.debugRunScheduled(kind: DeriveJobKind.heavy);
      expect(calls.last.heavy, isTrue);
      expect(calls.last.changedOnly, isFalse);
    });

    test('a throw is a failed outcome carrying the error', () async {
      final c = make();
      c.debugDeriveRun = deriveHook(throws: StateError('nope'));
      final o = await c.afterDrain();
      expect(o.failed, isTrue);
      expect(o.error, contains('nope'));
      expect(host.notifies, 0);
    });

    test('notify counts per pass (day 1, every 3rd, last, plus the publish)',
        () async {
      final c = make();
      c.debugDeriveRun = deriveHook(days: ['d4', 'd3', 'd2', 'd1']);
      await c.afterDrain();
      expect(host.notifies, 4);
    });

    test('the phone-step refresh runs once per full pass; recovery-ready and '
        'disk reclaim only after a heavy one', () async {
      final c = make();
      c.debugDeriveRun = deriveHook(days: ['d1']);
      await c.afterDrain();
      await settleMs();
      expect((host.steps, host.recovery, host.reclaims), (1, 0, 0));
      await c.afterDrain(heavy: true);
      await settleMs();
      expect((host.steps, host.recovery, host.reclaims), (2, 1, 1));
    });

    test('the nothing-changed early return skips the post-derive callbacks '
        'unless it is an automatic pass (which only refreshes steps)',
        () async {
      final c = make();
      c.debugDeriveRun = deriveHook(scope: 0);
      await c.afterDrain(changedOnly: true);
      await settleMs();
      expect((host.steps, host.notifies), (0, 0));
      await c.debugRunScheduled(kind: DeriveJobKind.light);
      await settleMs();
      expect(host.steps, 1);
      expect(host.recovery, 0);
    });

    test('the health export runs only when sync is on, and a failure is '
        'logged, never thrown', () async {
      final c = make();
      c.debugDeriveRun = deriveHook(days: ['d1']);
      await c.afterDrain();
      await settleMs();
      expect(host.exports, 0);

      host.healthSync = true;
      await c.afterDrain();
      await settleMs();
      expect(host.exports, 1);
      expect(host.logs, contains('[health] exported 2 day(s)'));

      host.exportThrows = StateError('no health');
      final o = await c.afterDrain();
      await settleMs();
      expect(host.exports, 2);
      expect(o.failed, isFalse);
      expect(host.logs.any((l) => l.startsWith('[health] export failed')),
          isTrue);
    });

    test('a pass that finishes after the host is disposed sets no recalc and '
        'bumps nothing from the clear path', () async {
      final c = make();
      host.disposed = true;
      c.debugDeriveRun = deriveHook(days: ['d2', 'd1']);
      var recalcTicks = 0;
      c.recalc.addListener(() => recalcTicks++);
      await c.afterDrain();
      await settleMs();
      expect(recalcTicks, 0);
      expect(c.recalc.value, RecalcState.idle);
    });
  });

  group('recalc and revision', () {
    test('bumpInsights moves only the revision', () {
      final c = make();
      var recalcTicks = 0;
      c.recalc.addListener(() => recalcTicks++);
      c.bumpInsights();
      expect(c.insightsRevision.value, 1);
      expect((host.notifies, recalcTicks), (0, 0));
    });

    test('the owner that set the days is the only one that clears them',
        () async {
      final c = make();
      final gate = Completer<void>();
      c.debugDeriveRun =
          deriveHook(days: ['d2', 'd1'], gate: gate, holdAfter: 0);
      final running = c.afterDrain();
      await until(() => c.recalc.value.days.length == 2);
      c.debugDeriveRun = deriveHook(reportScope: false, returns: 0);
      await c.afterDrain();
      expect(c.recalc.value.days, {'d2', 'd1'});
      gate.complete();
      await running;
      expect(c.recalc.value, RecalcState.idle);
    });

    test('debugSetRecalc writes the notifier', () {
      final c = make();
      final s = RecalcState(days: {'x'}, passStartedAt: DateTime(2026));
      c.debugSetRecalc(s);
      expect(c.recalc.value, s);
    });

    test('recordHomeRender stores and logs', () {
      final c = make();
      c.recordHomeRender(33);
      expect(c.lastHomeRenderMs, 33);
      expect(host.logs, contains('[perf] home render 33 ms'));
    });

    test('lastPassPerf reads the engine\'s snapshot, null before a pass',
        () {
      final c = make();
      expect(c.lastPassPerf, isNull);
      expect(host.engine, isNotNull);
    });
  });

  group('warmer', () {
    test('warms the days a productive pass reported', () async {
      final src = FakeArtifactSource();
      final c = make()..debugArtifactSource = src;
      c.debugDeriveRun = deriveHook(days: ['d2', 'd1']);
      await c.afterDrain();
      await until(() => src.candidateCalls.isNotEmpty);
      expect(src.candidateCalls, [
        ['d2', 'd1']
      ]);
    });

    test('the host hold keeps it from warming', () async {
      final src = FakeArtifactSource();
      final c = make()..debugArtifactSource = src;
      host.warmHeld = true;
      c.debugDeriveRun = deriveHook(days: ['d1']);
      await c.afterDrain();
      await settleMs();
      expect(src.candidateCalls, isEmpty);
    });

    test('an active offload on the scheduler holds it too', () async {
      final src = FakeArtifactSource();
      final c = make()..debugArtifactSource = src;
      c.scheduler.setOffloadActive(true);
      c.debugDeriveRun = deriveHook(days: ['d1']);
      await c.afterDrain();
      await settleMs();
      expect(src.candidateCalls, isEmpty);
      c.scheduler.setOffloadActive(false);
      await c.afterDrain();
      await until(() => src.candidateCalls.isNotEmpty);
      expect(src.candidateCalls.length, 1);
    });

    test('nothing to warm without a source and without a repository',
        () async {
      final c = make();
      c.debugDeriveRun = deriveHook(days: ['d1']);
      final o = await c.afterDrain();
      expect(o.complete, isTrue);
    });
  });

  group('calculation policy', () {
    test('a real light pass asks the injected policy once; heavy never does',
        () async {
      var charging = 0;
      host.policy = PeriodicCalculationPolicy(
        phoneCharging: () async {
          charging++;
          return true;
        },
        loadSamples: (from, to) async =>
            throw StateError('not asked while charging'),
      );
      final c = make();
      await c.debugRunScheduled(kind: DeriveJobKind.light);
      expect(charging, 1);
      await c.debugRunScheduled(kind: DeriveJobKind.heavy);
      expect(charging, 1);
    });

    test('the debug hook bypasses the policy', () async {
      var charging = 0;
      host.policy = PeriodicCalculationPolicy(
        phoneCharging: () async {
          charging++;
          return null;
        },
        loadSamples: (from, to) async => const WakeSamples.empty(),
      );
      final c = make();
      c.debugDeriveRun = deriveHook(days: ['d1']);
      await c.debugRunScheduled(kind: DeriveJobKind.light);
      expect(charging, 0);
    });
  });

  group('lifecycle', () {
    test('dispose disposes both notifiers and is safe twice', () {
      final c = host.coordinator;
      c.dispose();
      c.dispose();
      expect(() => c.insightsRevision.addListener(() {}), throwsFlutterError);
      expect(() => c.recalc.addListener(() {}), throwsFlutterError);
    });

    test('dispose with a trailing publish pending leaves no live timer',
        () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final c = host.coordinator
          ..debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
        c.debugDeriveRun = deriveHook(days: ['d1']);
        await c.afterDrain();
        await c.afterDrain();
        await settleMs();
        expect(spy.live, isNotEmpty);
        c.dispose();
        await settleMs();
        expect(spy.live, isEmpty);
      });
    });

    test('dispose cancels the workout hold cap armed on the scheduler',
        () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final c = host.coordinator;
        c.scheduler.setWorkoutActive(true);
        expect(spy.live, isNotEmpty);
        c.dispose();
        expect(spy.live, isEmpty);
      });
    });

    test('a pass in flight at dispose completes without throwing', () async {
      final c = host.coordinator
        ..debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      final gate = Completer<void>();
      c.debugDeriveRun =
          deriveHook(days: ['d2', 'd1'], gate: gate, holdAfter: 1);
      final pass = c.afterDrain();
      await until(() => c.recalc.value.days.length < 2);
      c.dispose();
      gate.complete();
      await expectLater(pass, completes);
    });

    test('flags and owners reset in finally: a throwing pass leaves the '
        'coordinator ready for the next', () async {
      final c = make();
      c.debugDeriveRun = ({
        required heavy,
        required changedOnly,
        onScope,
        onScopeDays,
        onDayDone,
        onCrossDay,
      }) async {
        onScopeDays?.call(['d1']);
        onCrossDay?.call(true);
        throw StateError('x');
      };
      await c.afterDrain();
      expect(c.recalc.value, RecalcState.idle);
      c.debugDeriveRun = deriveHook(days: ['d1']);
      final o = await c.afterDrain();
      expect(o.complete, isTrue);
    });
  });

  test('the coordinator imports nothing from AppState', () {
    // Source guard: a controller must not grow a back-reference.
    final src = File('lib/state/derive_coordinator.dart').readAsStringSync();
    expect(src, isNot(contains('app_state.dart')));
  });
}
