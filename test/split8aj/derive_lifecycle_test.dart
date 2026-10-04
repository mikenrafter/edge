// 8AJ seam 1 characterization: what AppState.dispose leaves behind from the
// derive machinery (timers, listeners, in-flight passes). Must pass before and
// after the DeriveCoordinator move.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/app_state.dart';

import '../perf/support/p3_warmer_support.dart';
import 'support/derive_harness.dart';

const _db = 'openstrap_split8aj_derive_lifecycle.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('timers', () {
    test('dispose cancels a pending trailing day publish (no live timer is '
        'left)', () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final app = AppState.forTesting();
        app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
        app.debugDeriveRun = deriveHook(days: ['d2', 'd1']);
        await app.debugAfterDrain();
        await app.debugAfterDrain(); // inside the 1.5 s gap: arms the trailing
        await settleMs();
        expect(spy.live, isNotEmpty,
            reason: 'precondition: the trailing publish timer is pending');
        app.dispose();
        await settleMs();
        expect(spy.live, isEmpty,
            reason: 'live: ${spy.live.length} of ${spy.created} created');
      });
    });

    test('dispose cancels the live-workout hold cap armed on the scheduler',
        () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final app = AppState.forTesting();
        app.startWorkout();
        expect(spy.live, isNotEmpty, reason: 'the 6 h hold cap is armed');
        app.dispose();
        await settleMs();
        expect(spy.live, isEmpty,
            reason: 'live: ${spy.live.length} of ${spy.created} created');
      });
    });

    test('a pass that finished before dispose leaves no timers behind',
        () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final app = AppState.forTesting();
        app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
        app.debugDeriveRun = deriveHook(days: ['d1']);
        await app.debugAfterDrain(heavy: true);
        await settleMs(250);
        app.dispose();
        await settleMs();
        expect(spy.live, isEmpty);
      });
    });
  });

  group('listeners', () {
    test('AppState adds no listener of its own to the derive notifiers, '
        'before, during or after passes', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      // ignore: invalid_use_of_protected_member
      expect(app.insightsRevision.hasListeners, isFalse);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      await settleMs();
      // ignore: invalid_use_of_protected_member
      expect(app.insightsRevision.hasListeners, isFalse);
    });

    test('a screen\'s add / remove on the derive notifiers balances, also '
        'across a pass and a dispose', () async {
      final app = AppState.forTesting();
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      void noop() {}
      app.insightsRevision.addListener(noop);
      app.recalc.addListener(noop);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      app.insightsRevision.removeListener(noop);
      app.recalc.removeListener(noop);
      // ignore: invalid_use_of_protected_member
      expect(app.insightsRevision.hasListeners, isFalse);
      app.dispose();
    });

    test('a screen that removes its listener AFTER dispose does not throw',
        () {
      final app = AppState.forTesting();
      void noop() {}
      app.insightsRevision.addListener(noop);
      app.recalc.addListener(noop);
      app.dispose();
      expect(() {
        app.insightsRevision.removeListener(noop);
        app.recalc.removeListener(noop);
      }, returnsNormally);
    });

    test('removing a listener from AppState itself restores the listener '
        'count (no derive path adds one)', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      final ticks = TickCounter(app);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      ticks.stop();
      final before = ticks.ticks;
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      expect(ticks.ticks, before, reason: 'the stopped counter hears nothing');
    });
  });

  group('scheduler wiring', () {
    test('a fresh app reports no derive running or pending', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(app.deriving, isFalse);
      expect(app.derivePending, isFalse);
    });

    test('a hooked pass does not go through the scheduler: it never shows as '
        'running or pending', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      final gate = Completer<void>();
      app.debugDeriveRun =
          deriveHook(days: ['d1'], gate: gate, holdAfter: 0);
      final pass = app.debugAfterDrain();
      await settleMs();
      expect(app.deriving, isFalse);
      expect(app.derivePending, isFalse);
      gate.complete();
      await pass;
    });
  });

  group('disposal while work is in flight', () {
    test('a pass still running when AppState is disposed finishes without '
        'throwing and without ticking a disposed notifier', () async {
      final app = AppState.forTesting();
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      final gate = Completer<void>();
      app.debugDeriveRun =
          deriveHook(days: ['d2', 'd1'], gate: gate, holdAfter: 1);
      final pass = app.debugAfterDrain();
      await until(() => app.recalc.value.days.length == 2 ||
          app.recalc.value.days.length == 1);
      app.dispose();
      gate.complete();
      await expectLater(pass, completes);
    });

    test('a warm in flight at dispose is cancelled and never completes a '
        'store', () async {
      final src = FakeArtifactSource()
        ..keys = ['k']
        ..sigs['k'] = 's'
        ..gates['k'] = Completer<void>();
      final app = AppState.forTesting();
      app.debugArtifactSource = src;
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      await until(() => src.computeStarted.isNotEmpty);
      app.dispose();
      src.gates['k']!.complete();
      await settleMs(200);
      expect(src.computeStarted, ['k']);
    });

    test('the engine hook and the debug seams are restorable: clearing the '
        'hook is allowed', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      app.debugDeriveRun = null;
      app.debugRescanRecent = null;
      expect(app.debugDeriveRun, isNull);
      expect(app.debugRescanRecent, isNull);
    });
  });
}
