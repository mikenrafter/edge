// 8V: the virtual WHOOP MG (test/support/virtual_mg.dart). First, that the
// model shows what the lab logs showed; then gesture ideas tried on it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';

import '../support/ecg_trace.dart';
import '../support/virtual_mg.dart';

(int, int, int) _contact(TracePacket p) {
  var n = 0, first = -1, last = -1;
  for (var i = 0; i < p.r.samples.length; i++) {
    if (p.r.samples[i] == 0) continue;
    n++;
    if (first < 0) first = i;
    last = i;
  }
  return (n, first, last);
}

void main() {
  group('the model shows what the lab logs showed', () {
    test('a finger on from the start: blip, a blank packet, then contact '
        'from sample 86 of the third sampled packet', () {
      final p = VirtualMgEcg(touches: [(0, 10000)], zeroRate: 0).packets(6);
      expect(p[0].r.samples, isEmpty);
      expect(_contact(p[1]), (13, 36, 48));
      expect(_contact(p[2]).$1, 0);
      expect(_contact(p[3]), (14, 86, 99));
      expect(_contact(p[4]).$1, 100);
    });

    test('a finger back 0.5 s after a lift shows ~2 s after the lift, at '
        'sample 76', () {
      // Lift at 5.0 s, back at 5.5 s.
      final m = VirtualMgEcg(touches: [(0, 5000), (5500, 9000)], zeroRate: 0);
      final again = m.visible[1];
      expect(again.$1 - 5000, inInclusiveRange(1500, 2500));
      final p = m.packets(9);
      // The first packet whose contact starts mid-packet after the lift.
      final first = p.indexWhere((x) =>
          x.r.strapTime * 1000 - m.strapStart * 1000 > 6000 &&
          _contact(x).$2 > 0);
      expect(_contact(p[first]).$2, 76);
    });

    test('three pulses 300 ms apart: the band plays two', () {
      final h = VirtualMgHaptics();
      for (final t in [0, 300, 600]) {
        h.command(t);
      }
      expect(h.played, 2);
    });

    test('a buzz 1.25 s after a pair is dropped; 2.0 s after, it plays', () {
      final a = VirtualMgHaptics()
        ..command(0)
        ..command(300);
      expect(a.command(1250), isFalse);
      final b = VirtualMgHaptics()
        ..command(0)
        ..command(300);
      expect(b.command(2000), isTrue);
    });
  });

  // A whole gesture on the virtual band, on a virtual clock: the session's
  // waits move time, its buzzes go into the virtual haptic queue.
  Future<({List<(int?, String?)> results, VirtualMgHaptics haptics, List<String> steps})>
      gesture(List<(int, int)> touches,
          {Duration? reacquire, EcgTapThresholds? th, int seconds = 16}) async {
    final ecg = VirtualMgEcg(touches: touches);
    final packets = ecg.packets(seconds);
    final haptics = VirtualMgHaptics();
    final results = <(int?, String?)>[];
    final steps = <String>[];
    var now = packets.first.receivedAt.subtract(const Duration(seconds: 1));
    final t0 = now;
    int ms() => now.difference(t0).inMilliseconds;
    final s = EcgTapSession(
      beginStream: () async => true,
      endStream: () async {},
      isStreamAlive: () => true,
      buzz: (pulses, _) async {
        for (var i = 0; i < pulses; i++) {
          haptics.command(ms() + i * 300 + 100); // ~100 ms to write
        }
        now = now.add(Duration(milliseconds: (pulses - 1) * 300 + 150));
        return true;
      },
      maxTaps: () => 5,
      thresholds: () => th ?? EcgTapThresholds(startMs: 500, confirmMs: 1000),
      onFinished: (c, r) => results.add((c, r)),
      step: steps.add,
      now: () => now,
      wait: (d) async => now = now.add(d),
      pollEvery: const Duration(hours: 1),
      sensorReacquire: reacquire ?? const Duration(milliseconds: 1500),
    );
    await s.start(StrapEvent(
      eventId: 14,
      tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
      receivedAt: now,
      hex: '',
      deviceId: 'band',
    ));
    for (final p in packets) {
      if (p.receivedAt.isAfter(now)) now = p.receivedAt;
      s.onFrame(p.r);
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return (results: results, haptics: haptics, steps: steps);
  }

  group('gestures on the virtual band', () {
    // Finger on from the start (pre-empting, as the wearer does), lift at
    // 4.0 s, back at 4.5 s for a second, then off.
    const fourTaps = [(0, 4000), (4500, 7500)];

    test('a fourth tap after a 0.5 s lift counts with the 1.5 s reacquire',
        () async {
      final g = await gesture(fourTaps);
      expect(g.results, [(4, null)]);
    });

    test('…and is lost without it (what the 18:17 lab run saw)', () async {
      final g = await gesture(fourTaps, reacquire: Duration.zero);
      expect(g.results, [(3, null)]);
    });

    test('every pulse the gesture asks for is played (pair, quiet gap, '
        'single)', () async {
      final g = await gesture(fourTaps);
      // x3 for tap 3, x1 for tap 4, x1 confirmation.
      expect(g.haptics.log, hasLength(5));
      expect(g.haptics.played, 5, reason: g.haptics.log.toString());
    });

    test('a 300 ms tap after a lift never shows: the sensor is still blind',
        () {
      final m = VirtualMgEcg(touches: [(0, 4000), (4500, 4800)]);
      expect(m.visible, hasLength(1));
    });
  });
}
