// 8X — what the session does with the contact mask, and the quick start.
//
// A: EcgTapSession turns each R17 packet into contact with ecgContactMask (50 ms
// blocks, a moving signal), not "the sample is non-zero". A constant non-zero
// packet (a DC offset) is no contact; the packet line, the counting and the lab
// post-roll all use the mask. The extra-sensitive fill (everything from the
// first to the last contact sample of a packet is one touch) is applied on the
// mask.
//
// C: with tolerantStartup OFF, the first sampled packet (the 49-sample one)
// decides: no contact in it means the count is 2 right away, with no wait for
// the steady stream or the sensor to settle. Contact in it carries on as with
// tolerant startup.
//
// Rig timeline for the 100-sample packets, as in ecg_tap_session_test.dart:
// [_Rig.steady] feeds packets 1000 and 1001 (all flat), so the first sample is
// at 999.0, the window opens at 1001.5 and (start 300) closes at 1001.8.
// `_pkt(1002, ...)` covers [1001.0, 1002.0).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../support/ecg_trace.dart' show r17;

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

StrapEvent _tap() => StrapEvent(
      eventId: 14,
      tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000,
      receivedAt: _t0.add(const Duration(milliseconds: 300)),
      hex: '',
      deviceId: 'band',
    );

/// A packet whose NEWEST sample is at strap second [sec].
LabradorR17 _pkt(int sec, List<int> samples, {int subMs = 0}) => r17(
      strapSeconds: sec,
      subseconds: (subMs * 32768 / 1000).round(),
      samples: samples,
      sequence: sec,
    );

/// A packet whose newest sample is [endMs] after strap second 1790990000
/// (the virtual band's clock).
LabradorR17 _pktMs(int endMs, List<int> samples) {
  final ms = 1790990000 * 1000 + endMs;
  return r17(
    strapSeconds: ms ~/ 1000,
    subseconds: ((ms % 1000) * 32768 / 1000).round(),
    samples: samples,
  );
}

/// [n] samples that start at [base] and HOLD their last value except inside
/// the [moving] ranges, where they alternate +100, -100.
List<int> _samples(int n, {int base = 0, List<(int, int)> moving = const []}) {
  final out = <int>[];
  var held = base;
  for (var i = 0; i < n; i++) {
    final r = moving.where((m) => i >= m.$1 && i < m.$2);
    if (r.isNotEmpty) held = (i - r.first.$1).isEven ? 100 : -100;
    out.add(held);
  }
  return out;
}

class _Rig {
  _Rig({
    this.max = 3,
    EcgTapThresholds? th,
    this.postRoll,
    this.onWait,
  }) {
    session = EcgTapSession(
      beginStream: () async => true,
      endStream: () async => ended++,
      isStreamAlive: () => true,
      buzz: (pulses, id) async {
        buzzes.add((pulses, id));
        return true;
      },
      maxTaps: () => max,
      thresholds: () => th ?? EcgTapThresholds(),
      onFinished: (count, reason) => results.add((count, reason)),
      step: steps.add,
      now: () => now,
      wait: (d) async {
        onWait?.call(this, d);
      },
      pollEvery: const Duration(hours: 1),
      sensorReacquire: Duration.zero,
      postRoll: postRoll == null ? null : () => postRoll!,
    );
  }

  final int max;
  final Duration? postRoll;
  final void Function(_Rig, Duration)? onWait;
  DateTime now = _t0;
  late final EcgTapSession session;
  int ended = 0;
  final buzzes = <(int, String)>[];
  final results = <(int?, String?)>[];
  final steps = <String>[];

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Two flat packets one second apart: the window opens at 1001.5.
  Future<void> steady() async {
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_pkt(1000, List.filled(100, 0)));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_pkt(1001, List.filled(100, 0)));
    await settle();
  }

  /// Packet 1002 ([1001.0, 1002.0)) at wall 2 s.
  void deliver1002(List<int> samples) {
    now = _t0.add(const Duration(seconds: 2));
    session.onFrame(_pkt(1002, samples));
  }

  String line(int n) => steps.firstWhere((s) => s.startsWith('Packet $n:'));
}

void main() {
  group('the session counts contact with the block mask', () {
    test('a packet of constant non-zero samples is no contact: the count '
        'stays 2', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.deliver1002(List.filled(100, 120));
      await r.settle();
      expect(r.line(3), startsWith('Packet 3: 100 samples, 0 with contact, '));
      expect(r.results, [(2, null)]);
      expect(r.buzzes.map((b) => b.$1), [1, 1]);
    });

    test('a constant negative level is no contact either', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.deliver1002(List.filled(100, -300));
      await r.settle();
      expect(r.results, [(2, null)]);
    });

    test('a moving trace is contact: the touch counts as tap 3', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.deliver1002(_samples(100, moving: [(0, 100)]));
      await r.settle();
      expect(r.line(3), startsWith('Packet 3: 100 samples, 100 with contact '
          '(samples 0–99), '));
      expect(r.steps, contains('Buzz x3 requested at sample time 1001700 ms.'));
    });

    test('the packet line counts mask samples and places them', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      // Moves at 40..69, then holds its last (non-zero) value: not contact.
      r.deliver1002(_samples(100, moving: [(40, 70)]));
      expect(r.line(3), contains('30 with contact (samples 40–69)'));
    });

    test('a lone moving block (under 100 ms) in the middle of a packet is '
        'debounced away and does not count', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.deliver1002(_samples(100, moving: [(60, 65)]));
      await r.settle();
      expect(r.line(3), startsWith('Packet 3: 100 samples, 0 with contact, '));
      expect(r.results, [(2, null)]);
    });

    test('contact that moves for 250 ms engages after the 200 ms gap, from '
        'sample time', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.deliver1002(_samples(100, moving: [(50, 75)])); // 1001.50 .. 1001.75
      await r.settle();
      expect(r.steps, contains('Buzz x3 requested at sample time 1001700 ms.'));
    });

    test('a packet that only starts contact in its last block keeps it (it '
        'may continue in the next packet)', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.deliver1002(_samples(100, moving: [(95, 100)]));
      expect(r.line(3), contains('5 with contact (samples 95–99)'));
    });

    test('a first-sample step into a flat level is not contact (the sensor '
        'jumping to a DC level)', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.deliver1002([for (var i = 0; i < 100; i++) i < 55 ? 0 : 300]);
      await r.settle();
      expect(r.line(3), startsWith('Packet 3: 100 samples, 0 with contact, '));
      expect(r.results, [(2, null)]);
    });
  });

  group('extra sensitive is applied on the mask', () {
    // Contact blocks at 50..59 and 85..99 with a flat 25 samples (250 ms)
    // between. The packet line counts the mask either way.
    List<int> liftInsideAPacket() =>
        _samples(100, moving: [(50, 60), (85, 100)]);

    Future<_Rig> run(EcgTapThresholds th) async {
      final r = _Rig(max: 5, th: th);
      await r.session.start(_tap());
      await r.steady();
      r.deliver1002(liftInsideAPacket());
      // A flat packet after it, so a touch that is still held is released and
      // confirmed.
      r.now = _t0.add(const Duration(seconds: 3));
      r.session.onFrame(_pkt(1003, List.filled(100, 0)));
      await r.settle();
      return r;
    }

    test('the packet line is the mask, filled or not', () async {
      for (final x in [false, true]) {
        final r = await run(EcgTapThresholds(extraSensitive: x));
        expect(r.line(3), contains('25 with contact (samples 50–99)'),
            reason: 'extraSensitive $x');
      }
    });

    test('off: first to last contact sample is one touch, so the flat stretch '
        'in the middle does not break it', () async {
      final r = await run(EcgTapThresholds());
      expect(r.steps, contains('Buzz x3 requested at sample time 1001700 ms.'),
          reason: 'filled: contact from 1001.5 holds 200 ms');
      expect(r.results, [(3, null)]);
    });

    test('on: the mask as is, so the first 100 ms touch is too short to engage '
        'and the window closes at 2', () async {
      final r = await run(EcgTapThresholds(extraSensitive: true));
      expect(r.results, [(2, null)]);
      expect(r.steps, contains('Final count 2 at sample time 1001800 ms.'));
    });

    test('on: a single zero reading inside a moving trace does not restart the '
        'hold (the mask sees movement)', () async {
      Future<List<String>> held(List<int> samples) async {
        final r = _Rig(max: 3, th: EcgTapThresholds(extraSensitive: true));
        await r.session.start(_tap());
        await r.steady();
        r.deliver1002(samples);
        await r.settle();
        return r.steps.where((s) => s.startsWith('Buzz x3 requested')).toList();
      }

      final moving = _samples(100, moving: [(0, 100)]);
      final zero = [...moving]..[69] = 0;
      expect(await held(zero), ['Buzz x3 requested at sample time 1001700 ms.'],
          reason: 'a zero between moving samples is still movement');
    });
  });

  group('the lab post-roll uses the mask too', () {
    test('after the count a constant plateau is no contact; the moving block '
        'after it is', () async {
      final packet = _samples(100, moving: [(80, 100)]);
      for (var i = 60; i < 80; i++) {
        packet[i] = 120; // a plateau the old non-zero rule called contact
      }
      final r = _Rig(
        postRoll: const Duration(seconds: 3),
        onWait: (rig, d) {
          if (d == const Duration(seconds: 3)) {
            rig.session.onFrame(_pkt(1003, packet));
          }
        },
      );
      await r.session.start(_tap());
      await r.steady();
      r.deliver1002(List.filled(100, 0)); // no touch: ends at 2
      await r.settle();
      expect(r.results, [(2, null)]);
      expect(
          r.steps,
          contains(startsWith('After the count, packet 1: 100 samples, 20 with '
              'contact (samples 80–99)')));
    });
  });

  group('quick start (tolerant startup off)', () {
    final quick = EcgTapThresholds(tolerantStartup: false);
    const quickLine = 'Quick start: no finger in the first sampled packet; '
        'the count is 2.';

    /// The stream's first packets as the band sends them: one with no samples,
    /// then the short 49-sample one 1.01 s later.
    Future<_Rig> firstPackets(EcgTapThresholds th, List<int> first49,
        {int max = 3}) async {
      final r = _Rig(max: max, th: th);
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(milliseconds: 150));
      r.session.onFrame(_pktMs(0, const []));
      await r.settle();
      r.now = _t0.add(const Duration(milliseconds: 1160));
      r.session.onFrame(_pktMs(1010, first49));
      await r.settle();
      return r;
    }

    test('no contact in the first sampled packet: the count is 2 at once, two '
        'buzzes, before the stream is even steady', () async {
      final r = await firstPackets(quick, List.filled(49, 0));
      expect(r.results, [(2, null)]);
      expect(r.buzzes.map((b) => b.$1), [1, 1],
          reason: 'x2, as two one-pulse commands');
      expect(r.steps, contains(quickLine));
      expect(r.steps, isNot(contains(startsWith('Stream is steady'))));
      expect(r.session.active, isFalse);
      expect(r.ended, 1, reason: 'the stream is stopped');
    });

    test('a constant non-zero first packet is no contact: quick start too',
        () async {
      final r = await firstPackets(quick, List.filled(49, 300));
      expect(r.results, [(2, null)]);
      expect(r.steps, contains(quickLine));
    });

    test('a debounced blip (one moving block) in the first packet is no '
        'contact: quick start', () async {
      final r = await firstPackets(quick, _samples(49, moving: [(15, 20)]));
      expect(r.results, [(2, null)]);
      expect(r.steps, contains(quickLine));
    });

    test('the extra-sensitive fill does not hide the quick start: the mask is '
        'read before it', () async {
      final r = await firstPackets(
          EcgTapThresholds(tolerantStartup: false, extraSensitive: true),
          List.filled(49, 0));
      expect(r.results, [(2, null)]);
    });

    test('max 2: one count, not two', () async {
      final r = await firstPackets(quick, List.filled(49, 0), max: 2);
      expect(r.results, [(2, null)]);
      expect(r.buzzes.map((b) => b.$1), [1, 1]);
    });

    test('nothing is decided before a packet with samples arrives', () async {
      final r = _Rig(th: quick);
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(milliseconds: 150));
      r.session.onFrame(_pktMs(0, const []));
      await r.settle();
      expect(r.results, isEmpty);
      expect(r.buzzes, isEmpty);
      expect(r.steps, isNot(contains(quickLine)));
      expect(r.session.active, isTrue);
    });

    test('the next gesture starts clean (nothing sticky)', () async {
      final r = await firstPackets(quick, List.filled(49, 0));
      expect(r.results, hasLength(1));
      await r.session.start(_tap());
      expect(r.session.active, isTrue);
    });

    group('contact in the first sampled packet: carries on as tolerant', () {
      // The measured blip: samples 36..48 of the short packet show a finger
      // that was already on.
      final blip = _samples(49, moving: [(36, 49)]);

      Future<_Rig> run(EcgTapThresholds th) async {
        final r = await firstPackets(th, blip);
        // The second packet is flat (the sensor re-zeroes), as measured.
        r.now = _t0.add(const Duration(milliseconds: 2160));
        r.session.onFrame(_pktMs(2010, List.filled(100, 0)));
        await r.settle();
        expect(r.results, isEmpty, reason: 'no early decision');
        expect(r.buzzes, isEmpty);
        // First sample 0.52 s, the window opens 2.5 s later at 3.02 s. The
        // finger shows again from the start of the fourth packet.
        r.now = _t0.add(const Duration(milliseconds: 3160));
        r.session.onFrame(_pktMs(3010, List.filled(100, 0)));
        r.now = _t0.add(const Duration(milliseconds: 4160));
        r.session.onFrame(_pktMs(4010, _samples(100, moving: [(0, 100)])));
        await r.settle();
        return r;
      }

      test('quick start off: the finger that was on still counts as tap 3',
          () async {
        final r = await run(quick);
        expect(r.steps, isNot(contains(quickLine)));
        expect(r.results, [(3, null)]);
        expect(r.buzzes.map((b) => b.$1), [1, 1, 1]);
      });

      test('the same packets with tolerant startup give the same result',
          () async {
        final quickRun = await run(quick);
        final tolerantRun = await run(EcgTapThresholds());
        expect(tolerantRun.results, quickRun.results);
        expect(tolerantRun.buzzes.map((b) => b.$1),
            quickRun.buzzes.map((b) => b.$1));
      });
    });
  });

  group('tolerant startup on (the default) is unchanged', () {
    test('a first packet with no contact waits for the settle window, then '
        'ends at 2 on its own', () async {
      final r = _Rig(max: 3);
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(milliseconds: 150));
      r.session.onFrame(_pktMs(0, const []));
      r.now = _t0.add(const Duration(milliseconds: 1160));
      r.session.onFrame(_pktMs(1010, List.filled(49, 0)));
      await r.settle();
      expect(r.results, isEmpty, reason: 'one packet decides nothing');
      expect(r.steps.where((s) => s.startsWith('Quick start')), isEmpty);
      r.now = _t0.add(const Duration(milliseconds: 2160));
      r.session.onFrame(_pktMs(2010, List.filled(100, 0)));
      r.now = _t0.add(const Duration(milliseconds: 3160));
      r.session.onFrame(_pktMs(3010, List.filled(100, 0)));
      r.now = _t0.add(const Duration(milliseconds: 4160));
      r.session.onFrame(_pktMs(4010, List.filled(100, 0)));
      await r.settle();
      expect(r.results, [(2, null)]);
      expect(r.steps.where((s) => s.startsWith('Quick start')), isEmpty);
    });
  });
}
