// Two timing races in the wake orchestrator, each shown with a fake that
// interleaves the way the real device does:
//   K. decoded history lands in chunks (every 61-180 s) while ticks run every
//      30 s, so a tick can read nothing and the data arrives just after.
//   L. "I'm up" lands while a tick is mid-flight holding a stale snapshot.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';

import 'support/wake_fakes.dart';

final _t = DateTime(2026, 10, 5, 7, 0);
int get _tSec => _t.millisecondsSinceEpoch ~/ 1000;

class _Rig {
  _Rig(Duration beforeT)
      : clock = TestClock(_t.subtract(beforeT)),
        state = MemoryWakeStateStore(),
        trace = MemoryWakeTraceStore() {
    env = FakeWakeEnv()..armedEpochSec = _tSec;
    observer = ScriptedObserver()..next = stageObs('nrem');
    orchestrator = WakeOrchestrator(
      env: env,
      observer: observer,
      stateStore: state,
      traceStore: trace,
      now: clock.call,
    );
  }
  final TestClock clock;
  final MemoryWakeStateStore state;
  final MemoryWakeTraceStore trace;
  late final FakeWakeEnv env;
  late final ScriptedObserver observer;
  late final WakeOrchestrator orchestrator;

  Future<List<WakeTraceEntry>> entries(String kind) async =>
      [for (final e in await trace.forWake(_tSec)) if (e.kind == kind) e];
}

void main() {
  setUp(HeadlessSyncGate.resetForTest);

  group('K: a late history flush is fed once, never skipped', () {
    test('an empty tick does not move the watermark past data still to land',
        () async {
      final r = _Rig(const Duration(minutes: 40)); // 06:20:00
      final plan = planFor(_t, natural: 60);
      final t0 = r.clock.now.millisecondsSinceEpoch.toDouble();
      // Everything up to 06:19:59 is already in the database.
      for (var s = 60; s > 0; s--) {
        r.env.store(t0 - s * 1000);
      }
      await r.orchestrator.tick(plan);

      // 06:20:30: the next chunk has not been flushed. The read is empty.
      r.clock.advance(const Duration(seconds: 30));
      await r.orchestrator.tick(plan);

      // 06:20:35: the flush lands 06:20:00..06:20:29 (older than the last tick).
      for (var s = 0; s < 30; s++) {
        r.env.store(t0 + s * 1000);
      }

      // 06:21:00: the next tick must see them.
      r.clock.advance(const Duration(seconds: 30));
      await r.orchestrator.tick(plan);

      final fedHr = [
        for (final q in r.observer.requests)
          for (final h in q.hr) h[0],
      ];
      expect(fedHr.toSet().length, fedHr.length,
          reason: 'the stager must never see a sample twice');
      expect(
        fedHr.toList()..sort(),
        [for (final h in r.env.storedHr) h[0]]..sort(),
        reason: 'and must never permanently miss a late one',
      );
      final fedRr = [
        for (final q in r.observer.requests)
          for (final b in q.rr) b[0],
      ];
      expect(fedRr.toSet().length, fedRr.length);
      expect(fedRr.length, r.env.storedRr.length);
    });

    test('the watermark survives a restart', () async {
      final r = _Rig(const Duration(minutes: 40));
      final plan = planFor(_t, natural: 60);
      final t0 = r.clock.now.millisecondsSinceEpoch.toDouble();
      r.env.store(t0 - 5000);
      await r.orchestrator.tick(plan);
      final rebuilt = WakeOrchestrator(
        env: r.env,
        observer: r.observer,
        stateStore: r.state,
        traceStore: r.trace,
        now: r.clock.call,
      );
      r.env.store(t0 + 1000);
      r.clock.advance(const Duration(seconds: 30));
      await rebuilt.tick(plan);
      final fed = [
        for (final q in r.observer.requests)
          for (final h in q.hr) h[0],
      ];
      expect(fed, [t0 - 5000, t0 + 1000]);
    });
  });

  group('L: acknowledge versus a tick already in flight', () {
    test('Natural: a tick held in the observer does not buzz after "I\'m up"',
        () async {
      final r = _Rig(const Duration(minutes: 40));
      final plan = planFor(_t, natural: 60);
      final gate = Completer<void>();
      final reached = Completer<void>();
      r.observer
        ..next = remObs() // would fire
        ..onObserve = () {
          if (!reached.isCompleted) reached.complete();
          return gate.future;
        };
      final tick = r.orchestrator.tick(plan);
      await reached.future; // the tick holds a snapshot with acknowledged=false
      await r.orchestrator.acknowledge(plan);
      gate.complete();
      final out = await tick;

      expect(r.env.haptics, isEmpty, reason: 'the user said they are up');
      expect(out.naturalFired, isFalse);
      expect(r.state.value!['acknowledged'], isTrue,
          reason: 'the tick must not overwrite the acknowledgement');
    });

    test('Gradual: a tick held before its step does not keep going', () async {
      final r = _Rig(const Duration(minutes: 5)); // inside the 15 min window
      final plan = planFor(_t, gradual: 15, cadenceSec: 60);
      final gate = Completer<void>();
      final reached = Completer<void>();
      r.env.onFallbackStatus = () {
        if (!reached.isCompleted) reached.complete();
        return gate.future;
      };
      final tick = r.orchestrator.tick(plan);
      await reached.future;
      r.env.onFallbackStatus = null;
      await r.orchestrator.acknowledge(plan);
      gate.complete();
      await tick;

      expect(r.env.haptics, isEmpty);
      expect(r.state.value!['acknowledged'], isTrue);
      // And it stays stopped on later ticks.
      r.clock.advance(const Duration(minutes: 2));
      await r.orchestrator.tick(plan);
      expect(r.env.haptics, isEmpty);
    });

    test('the acknowledgement merges: the tick\'s progress is kept too',
        () async {
      final r = _Rig(const Duration(minutes: 40));
      final plan = planFor(_t, natural: 60);
      final t0 = r.clock.now.millisecondsSinceEpoch.toDouble();
      r.env.store(t0 - 2000);
      final gate = Completer<void>();
      final reached = Completer<void>();
      r.observer.onObserve = () {
        if (!reached.isCompleted) reached.complete();
        return gate.future;
      };
      final tick = r.orchestrator.tick(plan);
      await reached.future;
      await r.orchestrator.acknowledge(plan);
      gate.complete();
      await tick;
      expect(r.state.value!['acknowledged'], isTrue);
      expect(r.state.value!['lastFedMs'], t0 - 2000);
      expect(r.state.value!['planLogged'], isTrue);
    });
  });
}
