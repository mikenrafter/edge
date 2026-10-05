// Failure injection — the wake orchestrator.
// BLE disconnect, a haptic that never answers, a duplicate tick, a skewed or
// jumping clock, a corrupt observation, a failing database, a process restart
// and a lost permission. The invariant throughout: the native alarm at T stays
// armed, and no early haptic is sent twice.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';

import 'support/wake_fakes.dart';

final _t = DateTime(2026, 10, 5, 7, 0);
int get _tSec => _t.millisecondsSinceEpoch ~/ 1000;

class _FlakyState implements WakeStateStore {
  final MemoryWakeStateStore inner = MemoryWakeStateStore();
  bool failSave = false, failLoad = false, hangSave = false;
  @override
  Future<Map<String, Object?>?> load() async {
    if (failLoad) throw StateError('database is locked');
    return inner.load();
  }

  @override
  Future<void> save(Map<String, Object?> state) {
    if (hangSave) return Completer<void>().future;
    if (failSave) throw StateError('database is locked');
    return inner.save(state);
  }
}

class _FlakyTrace implements WakeTraceStore {
  final MemoryWakeTraceStore inner = MemoryWakeTraceStore();
  bool fail = false;
  @override
  Future<void> append(WakeTraceEntry e) async {
    if (fail) throw StateError('database is locked');
    await inner.append(e);
  }

  @override
  Future<List<WakeTraceEntry>> forWake(int s) => inner.forWake(s);
}

class _Rig {
  _Rig({DateTime? at, _FlakyState? state, _FlakyTrace? trace})
      : clock = TestClock(at ?? _t.subtract(const Duration(minutes: 30))),
        state = state ?? _FlakyState(),
        trace = trace ?? _FlakyTrace() {
    env = FakeWakeEnv()..armedEpochSec = _tSec;
    observer = ScriptedObserver();
    orchestrator = build();
  }
  final TestClock clock;
  final _FlakyState state;
  final _FlakyTrace trace;
  late final FakeWakeEnv env;
  late final ScriptedObserver observer;
  late WakeOrchestrator orchestrator;

  WakeOrchestrator build() => WakeOrchestrator(
        env: env,
        observer: observer,
        stateStore: state,
        traceStore: trace,
        now: clock.call,
        opTimeout: const Duration(milliseconds: 60),
      );

  Future<WakeTickOutcome> tick(WakePlanInput p) => orchestrator.tick(p);
  int get naturalHaptics =>
      env.haptics.where((h) => h.kind == WakeHapticKind.natural).length;
}

void main() {
  setUp(HeadlessSyncGate.resetForTest);
  final plan = planFor(_t, natural: 60);

  group('DB failure', () {
    test('state that cannot be saved still never sends the early haptic twice',
        () async {
      final r = _Rig()..state.failSave = true;
      await r.tick(plan);
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.naturalHaptics, 1);
      expect(r.env.armedEpochSec, _tSec, reason: 'T stays armed');
    });

    test('state that cannot be LOADED after the haptic fired does not fire '
        'again either', () async {
      final r = _Rig();
      await r.tick(plan);
      expect(r.naturalHaptics, 1);
      r.state.failLoad = true;
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.naturalHaptics, 1);
    });

    test('state saves that hang are given up on, the tick still finishes',
        () async {
      final r = _Rig()..state.hangSave = true;
      final out = await r.tick(plan).timeout(const Duration(seconds: 5));
      expect(out.coalesced, isFalse);
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.naturalHaptics, 1);
    });

    test('a trace store that throws never breaks the wake', () async {
      final r = _Rig()..trace.fail = true;
      final out = await r.tick(plan);
      expect(out.naturalFired, isTrue);
      expect(r.env.armedEpochSec, _tSec);
    });

    test('a DB failure is not remembered across a restart as "fired": the '
        'durable dispatcher ledger is the second guard', () async {
      // A new orchestrator on a store that never saved starts fresh; the
      // request id is stable so the dispatcher's ledger refuses the repeat.
      final r = _Rig()..state.failSave = true;
      await r.tick(plan);
      final first = r.env.haptics.single.eventId;
      r.orchestrator = r.build();
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.env.haptics.map((h) => h.eventId).toSet(), {first},
          reason: 'any repeat carries the same event id');
    });
  });

  group('haptic failures', () {
    test('a haptic that never answers is given up on; no refire; T armed',
        () async {
      final r = _Rig();
      r.env.hapticThrows = null;
      final hang = _HangingHaptic(r.env);
      final orch = WakeOrchestrator(
        env: hang,
        observer: r.observer,
        stateStore: r.state,
        traceStore: r.trace,
        now: r.clock.call,
        opTimeout: const Duration(milliseconds: 60),
      );
      await orch.tick(plan).timeout(const Duration(seconds: 5));
      r.clock.advance(const Duration(seconds: 30));
      await orch.tick(plan);
      expect(hang.hapticCalls, 1);
      expect(r.env.armedEpochSec, _tSec);
      final results = (await r.trace.forWake(_tSec))
          .where((e) => e.kind == 'natural_haptic' && e.data['phase'] == 'result');
      expect(results.single.data['result'], 'notDelivered');
    });

    test('BLE disconnect between the decision and the write: recorded as not '
        'delivered, not retried, T still armed', () async {
      final r = _Rig();
      r.env.hapticResult = const WakeHapticResult(
          delivered: [], suppressionReason: 'bandUnavailable');
      await r.tick(plan);
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.naturalHaptics, 1);
      expect(r.env.armedEpochSec, _tSec);
    });

    test('permission lost (suppressed by channel policy) is a recorded '
        'non-delivery, never a retry', () async {
      final r = _Rig();
      r.env.hapticResult = const WakeHapticResult(
          delivered: [], suppressionReason: 'channelSuppressed');
      await r.tick(plan);
      final row = (await r.trace.forWake(_tSec))
          .where((e) => e.kind == 'natural_haptic' && e.data['phase'] == 'result')
          .single;
      expect(row.data['suppression'], 'channelSuppressed');
      expect(row.data['result'], 'notDelivered');
    });

    test('BLE disconnect before the native-alarm check: the tick records the '
        'error and still reaches the haptic decision', () async {
      final r = _Rig();
      final env = _ThrowingStatusEnv()..armedEpochSec = _tSec;
      final orch = WakeOrchestrator(
        env: env,
        observer: r.observer,
        stateStore: r.state,
        traceStore: r.trace,
        now: r.clock.call,
        opTimeout: const Duration(milliseconds: 60),
      );
      final out = await orch.tick(plan);
      expect(out.coalesced, isFalse);
      expect((await r.trace.forWake(_tSec)).any((e) => e.kind == 'error'), isTrue);
    });
  });

  group('duplicates, restart, clock', () {
    test('overlapping ticks (a duplicate timer fire) send one haptic', () async {
      final r = _Rig();
      final results = await Future.wait([r.tick(plan), r.tick(plan)]);
      expect(results.where((o) => o.coalesced), hasLength(1));
      expect(r.naturalHaptics, 1);
    });

    test('process kill after the fired flag was saved: the restarted '
        'orchestrator does not fire', () async {
      final r = _Rig();
      await r.tick(plan);
      r.orchestrator = r.build();
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(plan);
      expect(r.naturalHaptics, 1);
    });

    test('the phone clock stepping backwards neither throws nor refires',
        () async {
      final r = _Rig();
      await r.tick(plan);
      r.clock.advance(const Duration(minutes: -20)); // NTP correction
      await r.tick(plan);
      r.clock.advance(const Duration(minutes: 21));
      await r.tick(plan);
      expect(r.naturalHaptics, 1);
      expect(r.env.armedEpochSec, _tSec);
    });

    test('a clock that jumps past T closes the wake with no haptic', () async {
      final r = _Rig();
      r.clock.at(_t.add(const Duration(hours: 2)));
      final out = await r.tick(plan);
      expect(r.naturalHaptics, 0);
      expect(out.naturalFired, isFalse);
    });

    test('a clock far in the past does nothing and touches no store', () async {
      final r = _Rig(at: _t.subtract(const Duration(days: 3)));
      await r.tick(plan);
      expect(r.state.inner.value, isNull);
      expect(r.env.haptics, isEmpty);
    });
  });

  group('corrupt frames (observations)', () {
    test('NaN confidence and run length never fire', () async {
      final r = _Rig();
      r.observer.next = NaturalObservation(
        stage: 'rem',
        confidence: double.nan,
        evidenceAgeMs: 30000,
        abstention: null,
        runSec: double.nan,
        epochStartMs: 1,
        note: null,
      );
      await r.tick(plan);
      expect(r.naturalHaptics, 0);
    });

    test('an observation with a NaN next-state is not fatal and not stored',
        () async {
      final r = _Rig();
      final bad = _BadStateObserver();
      final orch = WakeOrchestrator(
        env: r.env,
        observer: bad,
        stateStore: r.state,
        traceStore: r.trace,
        now: r.clock.call,
        opTimeout: const Duration(milliseconds: 60),
      );
      final out = await orch.tick(plan);
      expect(out.coalesced, isFalse);
      expect(r.env.armedEpochSec, _tSec);
      // The fired flag survived even though the stager state could not be kept.
      expect(r.state.inner.value?['naturalFired'], isTrue);
      expect(r.state.inner.value?['stager'], isNull);
    });

    test('unreadable persisted state starts fresh, T is still verified',
        () async {
      final r = _Rig();
      r.state.inner.value = {'wakeEpoch': _tSec, 'gradualNext': 'x', 'stager': 7};
      final out = await r.tick(plan);
      expect(out.coalesced, isFalse);
      expect(r.env.armedEpochSec, _tSec);
    });
  });

  group('the native alarm survives each failure', () {
    test('the band lost the alarm (reboot) AND the state store is down: it is '
        're-armed', () async {
      final r = _Rig()
        ..state.failLoad = true
        ..state.failSave = true;
      r.env.armedEpochSec = null;
      await r.tick(plan);
      expect(r.env.armCalls, [_tSec]);
    });

    test('acknowledgement with a failing store still verifies the alarm',
        () async {
      final r = _Rig()
        ..state.failLoad = true
        ..state.failSave = true;
      r.env.armedEpochSec = null;
      final out = await r.orchestrator.acknowledge(plan);
      expect(out.fallbackArmed, isTrue);
    });
  });
}

class _HangingHaptic extends FakeWakeEnv {
  _HangingHaptic(FakeWakeEnv base) {
    armedEpochSec = base.armedEpochSec;
  }
  int hapticCalls = 0;
  @override
  Future<WakeHapticResult> haptic(WakeHapticRequest r) {
    hapticCalls++;
    return Completer<WakeHapticResult>().future;
  }
}

class _ThrowingStatusEnv extends FakeWakeEnv {
  @override
  Future<FallbackStatus> fallbackStatus(DateTime wakeAt) async =>
      throw StateError('gatt disconnected');
}

class _BadStateObserver implements NaturalStageObserver {
  @override
  Future<NaturalObserveResult> observe(NaturalObserveRequest r) async =>
      NaturalObserveResult(
        observation: remObs(),
        nextState: {'bad': double.nan},
      );
}
