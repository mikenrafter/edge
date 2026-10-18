// Natural Wake is "needy" like the main alarm: once it fires, its plan repeats
// back to back until the wearer acknowledges, double-taps the band, or T is
// reached (the native alarm owns the wake from there, and is never touched).
// Driven entirely through fakes: each delivery stays open until the test
// finishes it, the way the real band queue holds a job while it plays.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';

import 'support/wake_fakes.dart';

final _t = DateTime(2026, 10, 5, 7, 0);
int get _tSec => _t.millisecondsSinceEpoch ~/ 1000;

const _ok = WakeHapticResult(delivered: ['band']);
const _failed = WakeHapticResult(error: 'band not connected');

class _Rig {
  _Rig({Duration? startBeforeT})
      : clock = TestClock(_t.subtract(startBeforeT ?? const Duration(minutes: 40))) {
    env = FakeWakeEnv()..armedEpochSec = _tSec;
    env.onHaptic = (r) {
      final c = Completer<WakeHapticResult>();
      deliveries.add((r, c));
      return c.future;
    };
    orchestrator = WakeOrchestrator(
      env: env,
      observer: ScriptedObserver(),
      stateStore: MemoryWakeStateStore(),
      traceStore: trace,
      now: clock.call,
      repeatNatural: true,
      onNaturalRepeatChanged: changes.add,
      repeatDelay: (d) {
        final c = Completer<void>();
        delays.add((d, c));
        return c.future;
      },
    );
  }

  final TestClock clock;
  final trace = MemoryWakeTraceStore();
  late final FakeWakeEnv env;
  late final WakeOrchestrator orchestrator;
  final deliveries = <(WakeHapticRequest, Completer<WakeHapticResult>)>[];
  final delays = <(Duration, Completer<void>)>[];
  final changes = <bool>[];
  late final plan = planFor(_t, natural: 60);

  Future<void> settle() => pumpEventQueue();

  /// Fire Natural: the tick returns once the FIRST delivery is finished.
  Future<void> fire() async {
    final tick = orchestrator.tick(plan);
    await settle();
    deliveries.single.$2.complete(_ok);
    expect((await tick).naturalFired, isTrue);
    await settle();
  }

  /// Finish the newest open delivery and let the loop move.
  Future<void> finish(WakeHapticResult r) async {
    deliveries.last.$2.complete(r);
    await settle();
  }

  Future<List<WakeTraceEntry>> repeatRows() async => [
        for (final e in await trace.forWake(_tSec))
          if (e.kind == 'natural_repeat') e
      ];

  Future<String?> stopReason() async {
    for (final e in await repeatRows()) {
      if (e.data['phase'] == 'stop') return e.data['reason'] as String?;
    }
    return null;
  }
}

void main() {
  setUp(HeadlessSyncGate.resetForTest);

  test('repeats back to back after the first delivery, until acknowledge',
      () async {
    final r = _Rig();
    await r.fire();
    // The next plan is written the moment the first finished: no wait between.
    expect(r.deliveries, hasLength(2));
    expect(r.delays, isEmpty);
    final again = r.deliveries.last.$1;
    expect(again.kind, WakeHapticKind.natural);
    expect(again.repeat, isTrue);
    expect(again.eventId, 'wake:natural:$_tSec:r1',
        reason: 'a fresh id: the durable ledger would refuse the first one');

    await r.finish(_ok);
    expect(r.deliveries, hasLength(3));

    // A later tick neither re-fires nor starts a second loop.
    r.clock.advance(const Duration(seconds: 30));
    final second = await r.orchestrator.tick(r.plan);
    expect(second.naturalFired, isFalse);
    await r.settle();
    expect(r.deliveries, hasLength(3), reason: 'one loop per occurrence');

    await r.orchestrator.acknowledge(r.plan);
    await r.finish(_ok); // the delivery already in flight lands
    expect(r.deliveries, hasLength(3), reason: 'nothing after the ack');
    expect(await r.stopReason(), 'acknowledged');
    expect(r.env.cancelCalls, isEmpty);
  });

  test('a band double tap after the repeat started stops it; one from before '
      'does not', () async {
    final r = _Rig();
    // The wearer double-tapped during some earlier alert tonight.
    r.env.lastBandDoubleTapAt = r.clock.now.subtract(const Duration(hours: 2));
    await r.fire();
    await r.finish(_ok);
    expect(r.deliveries, hasLength(3), reason: 'an old double tap is not a stop');
    expect(await r.stopReason(), isNull);

    r.clock.advance(const Duration(seconds: 4));
    r.env.lastBandDoubleTapAt = r.clock.now; // the band reports it mid-delivery
    await r.finish(_ok);
    expect(r.deliveries, hasLength(3));
    expect(await r.stopReason(), 'bandDoubleTap');
    // Dismissing the buzz is not a cancellation of the native alarm.
    expect(r.env.cancelCalls, isEmpty);
    expect(r.env.armedEpochSec, _tSec);
  });

  test('stops at T and never touches the native alarm', () async {
    final r = _Rig(startBeforeT: const Duration(minutes: 10));
    await r.fire();
    await r.finish(_ok);
    expect(r.deliveries, hasLength(3));

    r.clock.at(_t); // T: the native alarm owns the wake now
    await r.finish(_ok);
    expect(r.deliveries, hasLength(3));
    expect(await r.stopReason(), 'wakeTime');
    expect(r.env.cancelCalls, isEmpty);
    expect(r.env.armCalls, isEmpty);
    expect(r.env.armedEpochSec, _tSec);
  });

  test('a failed delivery waits a few seconds and retries instead of ending',
      () async {
    final r = _Rig();
    await r.fire();
    await r.finish(_failed);
    expect(r.deliveries, hasLength(2));
    expect(r.delays.map((d) => d.$1), [const Duration(seconds: 5)]);

    r.delays.single.$2.complete();
    await r.settle();
    expect(r.deliveries, hasLength(3), reason: 'retried after the wait');
    expect(await r.stopReason(), isNull);

    // Rejected again, then it lands: still going.
    await r.finish(_failed);
    r.delays.last.$2.complete();
    await r.settle();
    await r.finish(_ok);
    expect(r.deliveries, hasLength(5));
    expect(await r.stopReason(), isNull);
  });

  test('a headless wake tick bounds the repeat by the headless run ceiling',
      () async {
    final r = _Rig();
    final tick = r.orchestrator.tickThroughGate(r.plan);
    await r.settle();
    r.deliveries.single.$2.complete(_ok);
    expect((await tick)!.naturalFired, isTrue);
    await r.settle();
    await r.finish(_ok);
    expect(r.deliveries, hasLength(3));

    r.clock.advance(HeadlessSyncGate.runCeiling + const Duration(seconds: 1));
    await r.finish(_ok);
    expect(r.deliveries, hasLength(3));
    expect(await r.stopReason(), 'headlessBound');
  });

  test('dispose stops the loop', () async {
    final r = _Rig();
    await r.fire();
    r.orchestrator.dispose();
    await r.finish(_ok);
    expect(r.deliveries, hasLength(2));
    expect(await r.stopReason(), 'disposed');
  });

  test('isNaturalRepeating and the change callback follow the loop', () async {
    final r = _Rig();
    expect(r.orchestrator.isNaturalRepeating, isFalse);
    await r.fire();
    expect(r.orchestrator.isNaturalRepeating, isTrue);
    expect(r.changes, [true]);
    await r.orchestrator.acknowledge(r.plan);
    await r.finish(_ok);
    expect(r.orchestrator.isNaturalRepeating, isFalse);
    expect(r.changes, [true, false]);
  });

  test('dismissNaturalRepeat stops a loop with no plan to acknowledge',
      () async {
    final r = _Rig();
    await r.fire();
    r.orchestrator.dismissNaturalRepeat();
    await r.finish(_ok);
    expect(r.deliveries, hasLength(2));
    expect(await r.stopReason(), 'acknowledged');
    expect(r.env.cancelCalls, isEmpty);
  });
}
