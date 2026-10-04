// 8AK B (red): "delivered AND its plan ended" as one awaitable moment.
//
// Both sessions wait for a cue to be delivered AND played before the next
// window opens (a_ecg_window_after_followup_test.dart, b_double_tap_timing_
// test.dart). A cue's own future completes when its last command was WRITTEN;
// the band keeps playing for another second or so, and the band queue holds the
// next job until the band's "ended" event (100) plus the vocabulary's minimum
// gap. The session gets that moment from the haptics service.
//
// ASSUMED API (lib/haptics/haptics_service.dart, HapticsService):
//   `Future<void> whenIdle()`: completes when the band queue has nothing
//   pending: every job queued BEFORE the call has been delivered, its plan has
//   ended (the band's event 100, or the bounded playback time when the band
//   sends none, as the queue already waits) and the minimum gap after it has
//   passed. Completes at once when nothing is queued. Never throws, never
//   waits for jobs queued after the call, and is bounded by the queue's own
//   bounds (a band that never answers cannot hold it forever).
// AppState wires this as the session's `bandIdle`.
//
// Failure mode today: HapticsService has no `whenIdle`.

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/gesture_cues.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';

import '../support/virtual_mg.dart';

(VirtualMgBand, HapticsService) _rig() {
  final band = VirtualMgBand();
  final svc = HapticsService(port: band, allowLong: () => false);
  band.onEvent = svc.onBandEvent;
  return (band, svc);
}

// Through `dynamic`, so a build without the method fails the test that needs
// it (NoSuchMethodError) and not the whole file at compile time.
Future<void> _idle(HapticsService s) =>
    (s as dynamic).whenIdle() as Future<void>;

void main() {
  test('completes only after the cue was delivered AND its plan ended',
      () {
    fakeAsync((async) {
      final (band, svc) = _rig();
      final t0 = clock.now();
      var delivered = false, idle = false;
      Duration? idleAt;
      GestureCues(haptics: svc).start().then((_) => delivered = true);
      _idle(svc).then((_) {
        idle = true;
        idleAt = clock.now().difference(t0);
      });
      async.elapse(const Duration(milliseconds: 100));
      expect(delivered, isTrue, reason: 'the write landed');
      expect(idle, isFalse, reason: 'the band is still playing it');
      async.elapse(const Duration(seconds: 10));
      expect(idle, isTrue);
      final w = band.writes.single;
      final planEnd = w.atMs + band.writeToFiredMs + w.playback.envelopeMs;
      expect(idleAt!.inMilliseconds, greaterThanOrEqualTo(planEnd),
          reason: 'not before the band\'s event 100');
    });
  });

  test('waits for every job queued before the call (start, follow-up, '
      'confirm), not just the first', () {
    fakeAsync((async) {
      final (band, svc) = _rig();
      final cues = GestureCues(haptics: svc);
      cues.start();
      cues.followUp();
      cues.confirm();
      var idle = false;
      _idle(svc).then((_) => idle = true);
      async.elapse(const Duration(milliseconds: 1500));
      expect(idle, isFalse, reason: 'the second and third cue are still due');
      async.elapse(const Duration(seconds: 30));
      expect(idle, isTrue);
      expect(band.played, hasLength(3));
      final last = band.played.last;
      expect(last.atMs + band.writeToFiredMs + last.playback.envelopeMs,
          lessThanOrEqualTo(band.nowMs));
    });
  });

  test('completes at once when nothing is queued', () {
    fakeAsync((async) {
      final (_, svc) = _rig();
      var idle = false;
      _idle(svc).then((_) => idle = true);
      async.flushMicrotasks();
      expect(idle, isTrue);
    });
  });

  test('a band that is not connected does not hold it: the rejected cue is '
      'over at once', () {
    fakeAsync((async) {
      final (band, svc) = _rig();
      band.connected = false;
      GestureCues(haptics: svc).start();
      var idle = false;
      _idle(svc).then((_) => idle = true);
      async.elapse(const Duration(seconds: 2));
      expect(idle, isTrue);
    });
  });

  test('a job queued after the call is not waited for', () {
    fakeAsync((async) {
      final (_, svc) = _rig();
      var idle = false;
      _idle(svc).then((_) => idle = true);
      GestureCues(haptics: svc).start(); // queued AFTER the call
      async.flushMicrotasks();
      expect(idle, isTrue);
    });
  });
}
