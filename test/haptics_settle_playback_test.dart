// The band is held after a delivered pattern for its estimated
// playback when the band's ended event (100) does not come, not just the
// default 1.5 s.
//
// USER: "after the previous buzz has played" — does it include the estimated
// playtime? A band that never sends event 100 (gen 4 often) must not be written
// into while a long pattern (a 3.3 s one, SOS) still plays.
//
// What the code did: a compiled plan was held for its LAST phrase's span plus
// 1.5 s, where a command no profile phrase matches counts for a flat 3 s. A
// stored plan of 3.3 s made of such a command was released at 3.0 s, 0.3 s
// before it stopped. The stored runtime (`bakedRuntimeMs`, the estimator
// `bakedRuntimeMsFor` reads) was never consulted for the hold.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

class _Port implements BandHapticsPort {
  _Port(this.async);
  final FakeAsync async;
  final patternAt = <int>[];

  @override
  bool get isConnected => true;
  @override
  String? get generation => 'gen5';
  @override
  Future<bool> buzzBand({int holdMs = 0}) async => true;
  @override
  Future<bool> buzzMaverickPattern(List<int> effects, int loop) async {
    patternAt.add(async.elapsed.inMilliseconds);
    return true;
  }
}

/// One stored command no phrase of the MG profile matches (so the player
/// cannot size it) whose recorded runtime is [runtimeMs].
BuzzSequence _plan(int runtimeMs, {int steps = 1}) => BuzzSequence(
      const [0],
      durationsMs: const [500],
      profileId: _mg.id,
      profileVersion: _mg.version,
      bakedSteps: [
        for (var i = 0; i < steps; i++)
          BakedStep(effects: const [99], loop: 1, delayMs: 0),
      ],
      bakedRuntimeMs: runtimeMs,
    );

StrapEvent _ended() {
  final now = DateTime.now();
  return StrapEvent(
    eventId: 100,
    tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
    receivedAt: now,
    hex: '',
    deviceId: 'dev',
  );
}

void main() {
  group('no ended event: the band is held for the pattern\'s playback', () {
    test('a 3.3 s plan: the next job is written no earlier than 3.3 s after '
        'the first', () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = HapticsService(port: port, allowLong: () => false);
        final plan = _plan(3300);
        expect(bakedRuntimeMsFor(plan, _mg), 3300);
        svc.deliver(plan);
        svc.deliver(plan);
        async.elapse(const Duration(seconds: 30));
        expect(port.patternAt, hasLength(2));
        expect(port.patternAt[1] - port.patternAt[0],
            greaterThanOrEqualTo(3300),
            reason: 'the band was written into while it still played');
      });
    });

    test('a plan shorter than one buzz is still held 1.5 s, never less', () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = HapticsService(port: port, allowLong: () => false);
        final plan = _plan(200);
        svc.deliver(plan);
        svc.deliver(plan);
        async.elapse(const Duration(seconds: 30));
        expect(port.patternAt[1] - port.patternAt[0],
            greaterThanOrEqualTo(kBandBuzzPlayback.inMilliseconds));
      });
    });

    test('the hold is bounded, even for an absurd stored runtime', () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = HapticsService(port: port, allowLong: () => true);
        final plan = _plan(40000);
        svc.deliver(plan);
        svc.deliver(plan);
        async.elapse(const Duration(minutes: 5));
        expect(port.patternAt, hasLength(2));
        expect(port.patternAt[1] - port.patternAt[0],
            greaterThan(kBandBuzzPlayback.inMilliseconds));
        expect(port.patternAt[1] - port.patternAt[0],
            lessThanOrEqualTo(kBandSettleMax.inMilliseconds + 100));
      });
    });

    test('whenIdle (the gesture cue windows\' bandIdle) waits it out', () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = HapticsService(port: port, allowLong: () => false);
        svc.deliver(_plan(3300));
        async.flushMicrotasks();
        var idleAt = -1;
        svc.whenIdle().then((_) => idleAt = async.elapsed.inMilliseconds);
        async.elapse(const Duration(seconds: 30));
        expect(idleAt, greaterThanOrEqualTo(port.patternAt.first + 3300));
      });
    });

    test('bandSequenceSettle for the plan covers its stored runtime', () {
      final settle = bandSequenceSettle(_plan(3300), _mg);
      expect(settle.inMilliseconds, greaterThanOrEqualTo(3300));
      expect(settle, lessThanOrEqualTo(kBandSettleMax));
    });
  });

  group('the ended event still ends the wait early', () {
    test('event 100 at 2 s releases the next job at 2 s, not at the estimate',
        () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = HapticsService(port: port, allowLong: () => false);
        final plan = _plan(3300);
        svc.deliver(plan);
        svc.deliver(plan);
        async.elapse(const Duration(seconds: 2));
        svc.onBandEvent(_ended());
        async.elapse(const Duration(seconds: 30));
        expect(port.patternAt, hasLength(2));
        final gap = port.patternAt[1] - port.patternAt[0];
        expect(gap, greaterThanOrEqualTo(2000));
        expect(gap, lessThan(2500), reason: 'released by the event');
      });
    });
  });
}
