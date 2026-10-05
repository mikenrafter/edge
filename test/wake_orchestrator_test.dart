// The Natural/Gradual orchestrator against fakes: four configurations,
// abstentions, restart/reboot, the native fallback at T, and the trace.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

import 'support/wake_fakes.dart';

final _t = DateTime(2026, 10, 5, 7, 0);
int get _tSec => _t.millisecondsSinceEpoch ~/ 1000;

class Rig {
  Rig({DateTime? at, MemoryWakeStateStore? state, MemoryWakeTraceStore? trace})
      : clock = TestClock(at ?? _t.subtract(const Duration(minutes: 30))),
        state = state ?? MemoryWakeStateStore(),
        trace = trace ?? MemoryWakeTraceStore() {
    env = FakeWakeEnv()..armedEpochSec = _tSec;
    observer = ScriptedObserver();
    orchestrator = _build();
  }

  final TestClock clock;
  final MemoryWakeStateStore state;
  final MemoryWakeTraceStore trace;
  late final FakeWakeEnv env;
  late final ScriptedObserver observer;
  late WakeOrchestrator orchestrator;

  WakeOrchestrator _build() => WakeOrchestrator(
        env: env,
        observer: observer,
        stateStore: state,
        traceStore: trace,
        now: clock.call,
      );

  /// A fresh orchestrator over the same stores: what an app restart is.
  void restart() => orchestrator = _build();

  Future<WakeTickOutcome> tick(WakePlanInput plan, {DateTime? scheduledFor}) =>
      orchestrator.tick(plan, scheduledFor: scheduledFor);

  Future<List<WakeTraceEntry>> entries([String? kind]) async {
    final all = await trace.forWake(_tSec);
    return kind == null ? all : all.where((e) => e.kind == kind).toList();
  }
}

void main() {
  setUp(HeadlessSyncGate.resetForTest);

  group('four configurations', () {
    test('neither: no samples fetched, no haptic, fallback still verified',
        () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 5)));
      await r.tick(planFor(_t));
      expect(r.env.haptics, isEmpty);
      expect(r.observer.requests, isEmpty);
      expect(r.env.sampleRanges, isEmpty);
      expect((await r.entries('plan')).single.data['configuration'], 'neither');
      expect((await r.entries('fallback')), isNotEmpty);
    });

    test('Natural only: fires one early haptic inside [T-N, T) and no Gradual '
        'step', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      final plan = planFor(_t, natural: 60);
      final out = await r.tick(plan);
      expect(out.naturalFired, isTrue);
      expect(r.env.haptics, hasLength(1));
      expect(r.env.haptics.single.kind, WakeHapticKind.natural);
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.env.haptics, hasLength(1), reason: 'once only');
    });

    test('Gradual only: steps begin at T-G and never consult the stager',
        () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 30)));
      final plan = planFor(_t, gradual: 15, cadenceSec: 180);
      await r.tick(plan);
      expect(r.env.haptics, isEmpty, reason: 'T-30 is before T-15');
      r.clock.advance(const Duration(minutes: 15));
      final out = await r.tick(plan);
      expect(out.gradualStepFired, 0);
      expect(r.env.haptics.single.kind, WakeHapticKind.gradual);
      expect(r.observer.requests, isEmpty);
    });

    test('both: Natural fires early and Gradual still begins at T-G', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      final plan = planFor(_t, natural: 60, gradual: 15, cadenceSec: 180);
      await r.tick(plan);
      expect(r.env.haptics.map((h) => h.kind), [WakeHapticKind.natural]);
      r.clock.at(_t.subtract(const Duration(minutes: 15)));
      await r.tick(plan);
      expect(r.env.haptics.map((h) => h.kind),
          [WakeHapticKind.natural, WakeHapticKind.gradual]);
    });

    test('the native alarm at T is armed in every configuration', () async {
      for (final (n, g) in [(0, 0), (60, 0), (0, 15), (60, 15)]) {
        final r = Rig(at: _t.subtract(const Duration(minutes: 5)));
        r.env.armedEpochSec = null; // nothing armed yet
        await r.tick(planFor(_t, natural: n, gradual: g));
        expect(r.env.armCalls, [_tSec], reason: 'config natural=$n gradual=$g');
        expect(r.env.armedEpochSec, _tSec);
        expect(r.env.cancelCalls, isEmpty);
      }
    });
  });

  group('Natural abstentions are recorded, never silent', () {
    Future<(Rig, String?)> run(
        void Function(Rig r) setup, {WakePlanInput? plan, DateTime? at}) async {
      final r = Rig(at: at ?? _t.subtract(const Duration(minutes: 40)));
      setup(r);
      await r.tick(plan ?? planFor(_t, natural: 60));
      final n = await r.entries('natural');
      return (r, n.isEmpty ? null : n.last.data['reason'] as String?);
    }

    test('no REM candidate', () async {
      final (r, reason) = await run((r) => r.observer.next = stageObs('nrem'));
      expect(r.env.haptics, isEmpty);
      expect(reason, 'noRemCandidate');
    });

    test('low confidence', () async {
      final (r, reason) =
          await run((r) => r.observer.next = remObs(confidence: 0.1));
      expect(r.env.haptics, isEmpty);
      expect(reason, 'lowConfidence');
    });

    test('missing HR, missing accel, off-wrist, stale', () async {
      for (final raw in ['missingHr', 'missingAccel', 'offWrist', 'staleEvidence']) {
        final (r, reason) =
            await run((r) => r.observer.next = absentObs(raw));
        expect(r.env.haptics, isEmpty, reason: raw);
        expect(reason, isNotNull, reason: raw);
        expect(reason, isNot('fire'));
      }
    });

    test('disconnect: no haptic, reason recorded', () async {
      final (r, reason) = await run((r) => r.env.connected = false);
      expect(r.env.haptics, isEmpty);
      expect(reason, 'disconnected');
    });

    test('late background execution', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      await r.tick(planFor(_t, natural: 60),
          scheduledFor: r.clock.now.subtract(const Duration(minutes: 10)));
      expect(r.env.haptics, isEmpty);
      expect((await r.entries('natural')).last.data['reason'], 'lateExecution');
    });

    test('the observer throwing abstains and leaves the stager state alone',
        () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      r.observer.failWith = StateError('isolate died');
      final out = await r.tick(planFor(_t, natural: 60));
      expect(out.naturalFired, isFalse);
      expect((await r.entries('natural')).last.data['reason'], 'observerFailed');
      expect(r.state.value?['stager'], isNull);
      r.observer.failWith = null;
      r.clock.advance(const Duration(seconds: 30));
      expect((await r.tick(planFor(_t, natural: 60))).naturalFired, isTrue,
          reason: 'a later healthy tick recovers');
    });

    test('main sleep only: a nap alarm never reaches the stager', () async {
      final r = Rig(at: DateTime(2026, 10, 5, 14, 20));
      final nap = DateTime(2026, 10, 5, 15, 0);
      await r.orchestrator.tick(planFor(nap, natural: 60));
      expect(r.observer.requests, isEmpty);
      expect(r.env.haptics, isEmpty);
      final n = await r.trace.forWake(nap.millisecondsSinceEpoch ~/ 1000);
      expect(n.where((e) => e.kind == 'natural').last.data['reason'],
          'ineligibleNap');
    });

    test('an unresolved upgrade explanation keeps Natural inactive', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      await r.tick(planFor(_t, natural: 60, upgradePending: true));
      expect(r.env.haptics, isEmpty);
      expect(r.observer.requests, isEmpty);
      expect((await r.entries('natural')).last.data['reason'], 'upgradePending');
    });

    test('warm-up before T-N feeds the stager but cannot fire', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 70)));
      await r.tick(planFor(_t, natural: 60));
      expect(r.observer.requests, hasLength(1));
      expect(r.env.haptics, isEmpty);
    });

    test('before the collection lead nothing runs', () async {
      final r = Rig(at: _t.subtract(naturalCollectionLead(60) + const Duration(minutes: 1)));
      await r.tick(planFor(_t, natural: 60));
      expect(r.observer.requests, isEmpty);
    });

    test('sample feeding is incremental from the newest sample received',
        () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 70)));
      final plan = planFor(_t, natural: 60);
      final base = r.clock.now.millisecondsSinceEpoch.toDouble();
      for (var s = 40; s > 0; s--) {
        r.env.store(base - s * 1000);
      }
      final newest = base - 1000;
      await r.tick(plan);
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.env.sampleRanges.last.$1.millisecondsSinceEpoch, newest.round());
      expect(r.observer.requests.last.priorState, {'v': 1, 'calls': 1});
    });
  });

  group('the early haptic and the native fallback', () {
    test('an early haptic never disarms T', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      await r.tick(planFor(_t, natural: 60, gradual: 30));
      expect(r.env.haptics, isNotEmpty);
      expect(r.env.cancelCalls, isEmpty);
      expect(r.env.armedEpochSec, _tSec);
      // Even many ticks later, through every Gradual step.
      for (var i = 0; i < 40; i++) {
        r.clock.advance(const Duration(seconds: 30));
        await r.tick(planFor(_t, natural: 60, gradual: 30));
      }
      expect(r.env.cancelCalls, isEmpty);
      expect(r.env.armedEpochSec, _tSec);
    });

    test('a failing haptic does not touch the fallback either', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      r.env.hapticThrows = StateError('write refused');
      final out = await r.tick(planFor(_t, natural: 60));
      expect(out.naturalFired, isTrue, reason: 'it was attempted');
      expect(r.env.armedEpochSec, _tSec);
      expect(r.env.cancelCalls, isEmpty);
      final res = (await r.entries('natural_haptic')).last;
      expect(res.data['phase'], 'result');
      expect(res.data['error'], isNotNull);
    });

    test('only an explicit acknowledgement stops the remaining steps, and '
        'it does not cancel the native alarm unless asked', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 20)));
      final plan = planFor(_t, natural: 60, gradual: 30, cadenceSec: 60);
      await r.tick(plan);
      final before = r.env.haptics.length;
      final out = await r.orchestrator.acknowledge(plan);
      expect(out.nativeCancelRequested, isFalse);
      expect(r.env.cancelCalls, isEmpty);
      expect(r.env.armedEpochSec, _tSec);
      r.clock.advance(const Duration(minutes: 5));
      await r.tick(plan);
      expect(r.env.haptics.length, before, reason: 'acknowledged: no more steps');
      expect((await r.entries('ack')).single.data['cancelNative'], false);
    });

    test('an acknowledgement may request the native cancel, and it succeeds',
        () async {
      final r = Rig();
      final out =
          await r.orchestrator.acknowledge(planFor(_t, natural: 60), cancelNative: true);
      expect(out.nativeCancelRequested, isTrue);
      expect(out.nativeCancelled, isTrue);
      expect(r.env.cancelCalls, [_tSec]);
      expect(out.fallbackArmed, isFalse);
    });

    test('a failed cancellation leaves the fallback armed', () async {
      final r = Rig();
      r.env.cancelResult = false;
      final out =
          await r.orchestrator.acknowledge(planFor(_t, natural: 60), cancelNative: true);
      expect(out.nativeCancelled, isFalse);
      expect(out.fallbackArmed, isTrue);
      expect(r.env.armedEpochSec, _tSec);
      expect((await r.entries('ack')).last.data['fallbackArmed'], true);
    });

    test('a throwing cancellation also leaves it armed, re-arming if the '
        'state is unknown', () async {
      final r = Rig();
      r.env.cancelThrows = true;
      r.env.armedEpochSec = null; // the cancel half-landed
      final out =
          await r.orchestrator.acknowledge(planFor(_t, natural: 60), cancelNative: true);
      expect(out.nativeCancelled, isFalse);
      expect(out.fallbackArmed, isTrue);
      expect(r.env.armCalls, [_tSec]);
    });

    test('a hung cancellation gives up rather than wedging', () async {
      final r = Rig();
      final c = Completer<void>();
      final env = _HangingCancelEnv(c.future)..armedEpochSec = _tSec;
      final orch = WakeOrchestrator(
        env: env,
        observer: r.observer,
        stateStore: r.state,
        traceStore: r.trace,
        now: r.clock.call,
        opTimeout: const Duration(milliseconds: 50),
      );
      final out = await orch.acknowledge(planFor(_t, natural: 60), cancelNative: true);
      expect(out.nativeCancelled, isFalse);
      expect(out.fallbackArmed, isTrue);
    });
  });

  group('app death, restart and reboot', () {
    test('a restarted orchestrator reloads the stager state and does not '
        're-fire', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 50)));
      final plan = planFor(_t, natural: 60, gradual: 30, cadenceSec: 180);
      r.observer.next = stageObs('nrem');
      await r.tick(plan);
      r.clock.advance(const Duration(minutes: 21)); // T-29: Gradual step 0 is due
      r.observer.next = remObs();
      await r.tick(plan);
      expect(r.env.haptics.where((h) => h.kind == WakeHapticKind.natural), hasLength(1));
      final gradualBefore =
          r.env.haptics.where((h) => h.kind == WakeHapticKind.gradual).length;
      expect(gradualBefore, 1);

      r.restart();
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.env.haptics.where((h) => h.kind == WakeHapticKind.natural), hasLength(1),
          reason: 'the fired flag survived the restart');
      expect(r.env.haptics.where((h) => h.kind == WakeHapticKind.gradual).length,
          gradualBefore,
          reason: 'a step already sent is not replayed');
    });

    test('a restart carries the prior stager state forward', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 70)));
      final plan = planFor(_t, natural: 60);
      await r.tick(plan);
      r.restart();
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.observer.requests.last.priorState, {'v': 1, 'calls': 1});
    });

    test('unreadable persisted state starts fresh instead of crashing',
        () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      await r.state.save({'wakeEpoch': _tSec, 'stager': 'garbage', 'gradualNext': 'x'});
      r.restart();
      final out = await r.tick(planFor(_t, natural: 60));
      expect(out.naturalFired, isTrue);
    });

    test('phone reboot: the fallback is re-armed when the phone lost it',
        () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 90)));
      final plan = planFor(_t, natural: 60);
      await r.tick(plan);
      expect(r.env.armCalls, isEmpty, reason: 'armed and confirmed: left alone');
      r.restart();
      r.env.armedEpochSec = null; // the phone-side arm record is gone
      r.env.confirmed = false;
      r.clock.advance(const Duration(minutes: 5));
      await r.tick(plan);
      expect(r.env.armCalls, [_tSec]);
      final fb = await r.entries('fallback');
      expect(fb.last.data['armed'], isTrue);
    });

    test('a new wake epoch discards the previous night', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      await r.tick(planFor(_t, natural: 60));
      expect(r.env.haptics, hasLength(1));
      final tomorrow = _t.add(const Duration(days: 1));
      r.clock.at(tomorrow.subtract(const Duration(minutes: 40)));
      r.env.armedEpochSec = tomorrow.millisecondsSinceEpoch ~/ 1000;
      await r.tick(planFor(tomorrow, natural: 60));
      expect(r.env.haptics, hasLength(2));
    });
  });

  group('latches and give-up states', () {
    test('a second concurrent tick is coalesced, and the latch clears after '
        'an error', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      final gate = Completer<void>();
      final env = _SlowSamplesEnv(gate.future)..armedEpochSec = _tSec;
      final orch = WakeOrchestrator(
        env: env,
        observer: r.observer,
        stateStore: r.state,
        traceStore: r.trace,
        now: r.clock.call,
      );
      final plan = planFor(_t, natural: 60);
      final first = orch.tick(plan);
      final second = await orch.tick(plan);
      expect(second.coalesced, isTrue);
      gate.complete();
      await first;
      // An exception inside a tick must not leave it wedged.
      env.hapticThrows = StateError('boom');
      r.clock.advance(const Duration(minutes: 1));
      final third = await orch.tick(plan);
      expect(third.coalesced, isFalse);
    });

    test('a hung sample read times out instead of wedging the tick', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      final env = _SlowSamplesEnv(Completer<void>().future)..armedEpochSec = _tSec;
      final orch = WakeOrchestrator(
        env: env,
        observer: r.observer,
        stateStore: r.state,
        traceStore: r.trace,
        now: r.clock.call,
        opTimeout: const Duration(milliseconds: 50),
      );
      final out = await orch.tick(planFor(_t, natural: 60, gradual: 0));
      expect(out.naturalFired, isFalse);
      expect((await r.entries('natural')).last.data['reason'], isNotNull);
    });
  });

  group('Gradual', () {
    test('runs on its own schedule even when Natural never finds REM',
        () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 10)));
      r.observer.next = stageObs('nrem');
      final plan = planFor(_t, natural: 60, gradual: 10, cadenceSec: 60);
      var n = 0;
      while (r.clock.now.isBefore(_t.subtract(const Duration(seconds: 30)))) {
        await r.tick(plan);
        r.clock.advance(const Duration(seconds: 30));
        n++;
      }
      expect(n, greaterThan(10));
      final gradual = r.env.haptics.where((h) => h.kind == WakeHapticKind.gradual);
      expect(gradual.length, 10);
      expect(gradual.map((h) => h.stepIndex), [for (var i = 0; i < 10; i++) i]);
      expect(r.env.haptics.where((h) => h.kind == WakeHapticKind.natural), isEmpty);
    });

    test('a step the OS ran late is skipped and recorded, not replayed',
        () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 10)));
      final plan = planFor(_t, gradual: 10, cadenceSec: 60);
      await r.tick(plan); // step 0
      r.clock.advance(const Duration(minutes: 4)); // steps 1..3 missed
      await r.tick(plan);
      final steps = await r.entries('gradual');
      expect(steps.where((e) => e.data['result'] == 'skippedLate'), isNotEmpty);
      expect(r.env.haptics.length, lessThanOrEqualTo(2));
    });

    test('outside the active span a tick does nothing and touches no store',
        () async {
      final r = Rig(at: _t.subtract(const Duration(hours: 5)));
      await r.tick(planFor(_t, natural: 60, gradual: 30));
      expect(r.trace.all, isEmpty);
      expect(r.state.value, isNull);
      expect(r.env.armCalls, isEmpty);
    });

    test('nothing fires at or after T: the native alarm owns T', () async {
      final r = Rig(at: _t);
      final out = await r.tick(planFor(_t, natural: 60, gradual: 30));
      expect(r.env.haptics, isEmpty);
      expect(out.closed, isTrue);
    });
  });

  group('the decision trace', () {
    test('records samples state, stage, confidence, suppression, haptic '
        'request and result, and fallback confirmation', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      r.env.hapticResult =
          const WakeHapticResult(delivered: ['band'], suppressionReason: null);
      r.observer.next = stageObs('nrem');
      final plan = planFor(_t, natural: 60);
      await r.tick(plan);
      r.clock.advance(const Duration(minutes: 1));
      r.observer.next = remObs(runSec: 180, confidence: 0.55);
      await r.tick(plan);

      final natural = await r.entries('natural');
      final first = natural.first.data;
      expect(first['stage'], 'nrem');
      expect(first['reason'], 'noRemCandidate');
      expect(first['samples'], 'current');
      final fire = natural.last.data;
      expect(fire['reason'], 'fire');
      expect(fire['stage'], 'rem');
      expect(fire['confidence'], 0.55);
      expect(fire['runSec'], 180);

      final haptic = await r.entries('natural_haptic');
      expect(haptic.map((e) => e.data['phase']), ['request', 'result']);
      expect(haptic.last.data['delivered'], ['band']);

      final fb = await r.entries('fallback');
      expect(fb.first.data['armed'], isTrue);
      expect(fb.first.data['confirmed'], isTrue);

      final plans = await r.entries('plan');
      expect(plans.single.data['naturalMinutes'], 60);
      expect(plans.single.data['configuration'], 'naturalOnly');
    });

    test('stale samples are marked stale', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      r.observer.next = remObs(evidenceAgeMs: 400000);
      await r.tick(planFor(_t, natural: 60));
      expect((await r.entries('natural')).last.data['samples'], 'stale');
    });

    test('an unchanged abstention is not re-logged every tick', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      r.observer.next = stageObs('nrem');
      for (var i = 0; i < 6; i++) {
        await r.tick(planFor(_t, natural: 60));
        r.clock.advance(const Duration(seconds: 30));
      }
      expect(await r.entries('natural'), hasLength(1));
    });

    test('closing at T leaves one summary row', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      await r.tick(planFor(_t, natural: 60));
      r.clock.at(_t.add(const Duration(seconds: 5)));
      await r.tick(planFor(_t, natural: 60));
      await r.tick(planFor(_t, natural: 60));
      final closed = await r.entries('closed');
      expect(closed, hasLength(1));
      expect(closed.single.data['naturalFired'], true);
    });
  });

  group('headless and background entry', () {
    test('runs through HeadlessSyncGate.tryRun', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      final out = await r.orchestrator
          .tickThroughGate(planFor(_t, natural: 60), owner: 'test_wake');
      expect(out, isNotNull);
      expect(r.env.haptics, hasLength(1));
      expect(HeadlessSyncGate.busy, isFalse);
    });

    test('skips (never queues) when another headless run holds the gate, and '
        'records the skip', () async {
      final r = Rig(at: _t.subtract(const Duration(minutes: 40)));
      final hold = Completer<void>();
      final holder =
          HeadlessSyncGate.tryRun<void>('sync', () => hold.future);
      final out = await r.orchestrator
          .tickThroughGate(planFor(_t, natural: 60), owner: 'test_wake');
      expect(out, isNull);
      expect(r.env.haptics, isEmpty);
      expect((await r.entries('skip')).single.data['reason'], 'headlessGateBusy');
      hold.complete();
      await holder;
      // Not queued: nothing runs after the holder finishes.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(r.env.haptics, isEmpty);
    });
  });
}

class _SlowSamplesEnv extends FakeWakeEnv {
  _SlowSamplesEnv(this.gate);
  final Future<void> gate;
  @override
  Future<WakeSamples> samples(DateTime from, DateTime to) async {
    await gate;
    return super.samples(from, to);
  }
}

class _HangingCancelEnv extends FakeWakeEnv {
  _HangingCancelEnv(this.hang);
  final Future<void> hang;
  @override
  Future<bool> cancelNativeAlarm(DateTime wakeAt) async {
    await hang;
    return true;
  }
}
