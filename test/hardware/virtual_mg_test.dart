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
  group('8X: a DC offset on the electrode', () {
    test('the default is none: an untouched stream is all zeros', () {
      final p = VirtualMgEcg(touches: const []).packets(4);
      expect(p.expand((x) => x.r.samples), everyElement(0));
    });

    test('with an offset, every untouched sample reads that level (not zero), '
        'in every packet, and the packets keep their shape', () {
      final plain = VirtualMgEcg(touches: const []).packets(4);
      final p = VirtualMgEcg(touches: const [], dcOffset: 300).packets(4);
      expect(p.map((x) => x.r.samples.length),
          plain.map((x) => x.r.samples.length));
      expect(p.expand((x) => x.r.samples), everyElement(300));
      expect(p.expand((x) => x.r.samples), isNotEmpty);
    });

    test('a touch moves around the offset', () {
      final p = VirtualMgEcg(touches: [(0, 10000)], zeroRate: 0, dcOffset: 300)
          .packets(6);
      final touched = p[4].r.samples; // a full packet well after the settle
      expect(touched.toSet().length, greaterThan(10));
      expect(touched, everyElement(allOf(greaterThan(300 - 360),
          lessThan(300 + 440))));
      expect(p[2].r.samples, everyElement(300),
          reason: 'the blank second packet sits at the offset');
    });
  });

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

    test('a finger back 0.5 s after a lift shows ~1.9 s after it landed, on '
        'the band\'s 100 ms grid', () {
      // Lift at 5.0 s, back at 5.5 s.
      final m = VirtualMgEcg(touches: [(0, 5000), (5500, 9000)], zeroRate: 0);
      final again = m.visible[1];
      expect(again.$1 - 5500, inInclusiveRange(1900, 1999));
      expect(again.$1 % 100, 70, reason: 'sample 6 of a packet, every 100 ms');
    });

    test('how long the lift was does not matter: after 0.4 s and after 2.5 s '
        'a touch shows ~1.9 s after it landed', () {
      final m = VirtualMgEcg(
          touches: [(0, 4000), (4400, 8000), (10500, 14000)], zeroRate: 0);
      final vis = m.visible;
      expect(vis, hasLength(3));
      expect(vis[1].$1 - 4400, inInclusiveRange(1900, 1999));
      expect(vis[2].$1 - 10500, inInclusiveRange(1900, 1999));
    });

    test('a touch shows only if the finger is still there when the check '
        'lands: 300 ms taps never show', () {
      expect(VirtualMgEcg(touches: [(0, 4000), (4500, 4800)]).visible,
          hasLength(1));
      // Landing at 4.5 s: the first check at or after 6.4 s is at 6.47 s.
      expect(VirtualMgEcg(touches: [(0, 4000), (4500, 6460)]).visible,
          hasLength(1));
      expect(VirtualMgEcg(touches: [(0, 4000), (4500, 6480)]).visible,
          hasLength(2));
    });

    test('the latency is a parameter', () {
      final m = VirtualMgEcg(
          touches: [(0, 4000), (4500, 8000)], touchLatencyMs: 1000);
      expect(m.visible[1].$1 - 4500, inInclusiveRange(1000, 1099));
    });

    test('contact starts at sample ≡ 6 (mod 10) of its packet: 6, 16, 46, '
        '56, 66', () {
      final m = VirtualMgEcg(
          touches: [(0, 5000), (5500, 9000), (11300, 14000)], zeroRate: 0);
      final p = m.packets(16);
      final starts = <int>[];
      var zeros = 99; // the trace crossing zero is a lone zero, not a lift
      for (var k = 1; k < p.length; k++) {
        final smp = p[k].r.samples;
        for (var i = 0; i < smp.length; i++) {
          if (smp[i] != 0 && zeros >= 5 && !(k == 1 && i == 36)) starts.add(i);
          zeros = smp[i] == 0 ? zeros + 1 : 0;
        }
      }
      expect(starts, hasLength(3), reason: 'settle, then two re-touches');
      expect(starts.map((i) => i % 10), everyElement(6), reason: '$starts');
    });

    test('a finger on from the start still settles at the first sample + '
        '2.35 s', () {
      final m = VirtualMgEcg(touches: [(0, 10000)]);
      expect(m.visible.single.$1, 520 + 2350);
    });

    test('one command plays; one 300 ms later is swallowed ("pending", not '
        'played) and the next is ignored (no reply)', () {
      final h = VirtualMgHaptics();
      expect([for (final t in [0, 300, 600]) h.command(t)],
          ['pending', 'pending', null]);
      expect(h.played, 1);
      expect(h.log, hasLength(3));
    });

    test('a command after the band\'s 100 plays, even 0.4 s after it', () {
      // The 100 comes ~1.5 s after the 60.
      final h = VirtualMgHaptics();
      expect([for (final t in [0, 1900, 3400]) h.command(t)],
          ['pending', 'pending', 'pending']);
      expect(h.played, 3);
    });

    test('20:40 timings: 0, 1236, 2505 plays the first and third; 0, 1875, '
        '3400 plays all three', () {
      final a = VirtualMgHaptics();
      expect([for (final t in [0, 1236, 2505]) a.command(t)],
          ['pending', 'pending', 'pending']);
      expect(a.played, 2);
      final b = VirtualMgHaptics();
      for (final t in [0, 1875, 3400]) {
        b.command(t);
      }
      expect(b.played, 3);
    });

    test('after a swallowed command the band ignores the next for ~1.1 s: '
        '0.95 s later nothing, 1.27 s later it plays', () {
      final h = VirtualMgHaptics()..command(0);
      expect(h.command(1200), 'pending', reason: 'swallowed while playing');
      expect(h.command(1200 + 950), isNull);
      expect(h.command(1200 + 1270), 'pending');
      expect(h.played, 2);
      expect(h.log, hasLength(4));
    });

    test('busy and deaf windows are parameters', () {
      final h = VirtualMgHaptics(busyMs: 1000, deafMs: 500)..command(0);
      expect(h.command(800), 'pending'); // swallowed, deaf until 1300
      expect(h.command(1000), isNull, reason: 'idle again, but still deaf');
      expect(h.command(1300), 'pending');
      expect(h.played, 2);
    });
  });

  // A whole gesture on the virtual band, on a virtual clock: the session's
  // waits move time, its buzzes go into the virtual haptic queue.
  Future<({List<(int?, String?)> results, VirtualMgHaptics haptics, List<String> steps})>
      gesture(List<(int, int)> touches,
          {Duration? reacquire,
          EcgTapThresholds? th,
          int seconds = 16,
          int dcOffset = 0}) async {
    final ecg = VirtualMgEcg(touches: touches, dcOffset: dcOffset);
    final packets = ecg.packets(seconds);
    final haptics = VirtualMgHaptics();
    final results = <(int?, String?)>[];
    final steps = <String>[];
    var now = packets.first.receivedAt.subtract(const Duration(seconds: 1));
    final t0 = now;
    int ms() => now.difference(t0).inMilliseconds;
    final s = EcgTapSession(
      // The pacing rig: one pulse per call, as 8W measured the band (a count is
      // one call by default since 8AF.6).
      maxPulsesPerBurst: 1,
      beginStream: () async => true,
      endStream: () async {},
      isStreamAlive: () => true,
      buzz: (pulses, _) async {
        // One call is one band command, whatever it asks for (a command is
        // felt as one bzz-bzz); ~100 ms to write it.
        haptics.command(ms() + 100);
        now = now.add(const Duration(milliseconds: 150));
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

    test('every command the gesture sends is played: one per pulse, each '
        'after the band\'s quiet', () async {
      final g = await gesture(fourTaps);
      // x3 for tap 3 (three commands), x1 for tap 4, x1 confirmation.
      expect(g.haptics.log, hasLength(5));
      expect(g.haptics.played, 5, reason: g.haptics.log.toString());
    });

    test('a 300 ms tap after a lift is never seen, so it is not counted',
        () async {
      final g = await gesture([(0, 4000), (4500, 4800)]);
      expect(g.results, [(3, null)]);
    });

    test('8X: a flat DC level is no contact: with no finger the count is 2, '
        'not a finger that never lets go', () async {
      final g = await gesture(const [], dcOffset: 300);
      expect(g.results, [(2, null)]);
    });

    test('8X: a DC level under a real touch does not hide the lifts', () async {
      final g = await gesture(fourTaps, dcOffset: 300);
      expect(g.results, [(4, null)]);
    });

    test('8X: quick start with no finger: the count is 2 from the first '
        'sampled packet', () async {
      final g = await gesture(const [],
          th: EcgTapThresholds(
              startMs: 500, confirmMs: 1000, tolerantStartup: false));
      expect(g.results, [(2, null)]);
      expect(
          g.steps,
          contains('Quick start: no finger in the first sampled packet; the '
              'count is 2.'));
      expect(g.steps.where((s) => s.startsWith('Touch window open')), isEmpty,
          reason: 'decided before the window opened');
    });

    test('8X: quick start with the finger already on carries on like '
        'tolerant startup', () async {
      final g = await gesture(fourTaps,
          th: EcgTapThresholds(
              startMs: 500, confirmMs: 1000, tolerantStartup: false));
      expect(g.results, [(4, null)]);
      expect(g.steps.where((s) => s.startsWith('Quick start')), isEmpty);
    });
  });
}
