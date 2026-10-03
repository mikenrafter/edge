// The glue between the live ECG stream and EcgTapCounter (8L). The counter's
// timing is pinned in test/phase8/ecg_tap_counter_test.dart; this pins what the
// session adds: the stream must be really flowing and the sensor settled before
// the first window opens, sample times from R17 packets (strap time = the
// NEWEST sample), contact from first to last signal in a packet unless extra
// sensitive, buzzes through one callback and paced by the band's quiet gap, the
// step-by-step trace, and the latch discipline (every exit resets every flag,
// so a failed or abandoned gesture never swallows the next tap).
//
// Rig timeline: `_packet(sec)` is the second of samples ENDING at strap second
// `sec`. [_Rig.steady] feeds 1000 and 1001, so the first sample is at 999.0,
// the window opens at 999.0 + 2.5 = 1001.5 and (start 300) closes at 1001.8.
// `_packet(1002)` covers [1001.0, 1002.0): its samples 50..99 are in the window.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

StrapEvent _tap({int sec = 0}) => StrapEvent(
  eventId: 14,
  tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000 + sec,
  receivedAt: _t0.add(Duration(seconds: sec, milliseconds: 300)),
  hex: '',
  deviceId: 'band',
);

/// One R17 packet whose NEWEST sample is at strap second [sec] (+ [subMs]);
/// [contactFrom] is the first sample index with signal (earlier samples are
/// zero), [contactTo] the first index after it.
LabradorR17 _packet(
  int sec, {
  int subMs = 0,
  int contactFrom = 100,
  int? contactTo,
  int n = 100,
}) => LabradorR17(
  packetType: 43,
  headerSecondary: 0,
  sequence: sec,
  strapSeconds: sec,
  subseconds: (subMs * 32768 / 1000).round(),
  quality: 0,
  flags: const LabradorFlags(0x0a),
  result: 0,
  s2State: 0,
  progress: 0,
  unreadable: const LabradorUnreadableMask(0),
  averageHr: 0,
  liveHr: 0,
  variabilityRaw: null,
  reserved: 0,
  sampleCount: n,
  samples: Int16List.fromList([
    for (var i = 0; i < n; i++)
      i >= contactFrom && (contactTo == null || i < contactTo) ? 120 : 0,
  ]),
  tail: Uint8List(0),
  inner: Uint8List(0),
);

class _Rig {
  _Rig({
    this.max = 3,
    this.startOk = true,
    this.sendBuzz,
    this.beginGate,
    EcgTapThresholds? th,
    Duration? startTimeout,
    Duration reacquire = Duration.zero,
  }) {
    session = EcgTapSession(
      beginStream: () async {
        began++;
        await beginGate?.future;
        return startOk;
      },
      endStream: () async => ended++,
      isStreamAlive: () => alive,
      buzz: (pulses, id) async {
        buzzes.add((pulses, id));
        return await sendBuzz?.call(pulses, id) ?? true;
      },
      maxTaps: () => max,
      thresholds: () => th ?? EcgTapThresholds(),
      onFinished: (count, reason) => results.add((count, reason)),
      onStarted: (tap, settings) => started.add(settings),
      step: steps.add,
      now: () => now,
      wait: (d) async => waits.add(d),
      pollEvery: const Duration(hours: 1),
      startTimeout: startTimeout ?? const Duration(seconds: 20),
      // Off unless a test is about it: the other timings stay readable.
      sensorReacquire: reacquire,
    );
  }

  final Future<bool> Function(int, String)? sendBuzz;
  final Completer<void>? beginGate;
  final int max;
  final bool startOk;
  bool alive = true;
  DateTime now = _t0;
  late final EcgTapSession session;
  int began = 0, ended = 0;
  final buzzes = <(int, String)>[];
  final results = <(int?, String?)>[];
  final steps = <String>[];
  final started = <String>[];
  final waits = <Duration>[];

  /// A few event-loop turns: a buzz in bursts needs one per burst.
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Two packets one second apart, no contact: the stream is steady and the
  /// window opens at sample time 1001.5 (see the timeline above). Leaves `now`
  /// at 1.5 s.
  Future<void> steady() async {
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_packet(1000));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_packet(1001));
    await settle();
  }

  bool get windowOpen => steps.any((s) => s.startsWith('Touch window open'));
}

void main() {
  test('the defaults: twenty second start, 2.5 s settle, 1.8 s quiet gap', () {
    final s = EcgTapSession(
      beginStream: () async => true,
      endStream: () async {},
      isStreamAlive: () => true,
      buzz: (_, _) async => true,
      maxTaps: () => 3,
      thresholds: EcgTapThresholds.new,
      onFinished: (_, _) {},
    );
    expect(s.startTimeout, const Duration(seconds: 20));
    expect(s.sensorSettle, const Duration(milliseconds: 2500));
    expect(s.buzzQuietGap, const Duration(milliseconds: 1800));
  });

  group('the first window waits for a steady stream and a settled sensor', () {
    test('a started stream command alone opens nothing', () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.settle();
      expect(r.began, 1);
      expect(r.buzzes, isEmpty);
      expect(r.windowOpen, isFalse);
      expect(r.session.active, isTrue);
    });

    test('one packet is not steady; the second one opens the window, which '
        'buzzes nothing yet', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(milliseconds: 500));
      r.session.onFrame(_packet(1000));
      await r.settle();
      expect(r.windowOpen, isFalse);
      r.now = _t0.add(const Duration(milliseconds: 1500));
      r.session.onFrame(_packet(1001));
      await r.settle();
      expect(
        r.steps.where((s) => s.startsWith('Touch window open')).single,
        startsWith('Touch window open at sample time 1001500 ms, 2500 ms '
            'after the first sample'),
      );
      expect(r.buzzes, isEmpty, reason: 'the first window decides the buzz');
    });

    test('two packets too far apart are not steady yet; a late window opens '
        'at the newest packet, not in the past', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(milliseconds: 500));
      r.session.onFrame(_packet(1000));
      r.now = _t0.add(const Duration(milliseconds: 2600));
      r.session.onFrame(_packet(1001));
      await r.settle();
      expect(r.windowOpen, isFalse);
      r.now = _t0.add(const Duration(milliseconds: 3600));
      r.session.onFrame(_packet(1002));
      await r.settle();
      expect(
        r.steps.where((s) => s.startsWith('Touch window open')).single,
        startsWith('Touch window open at sample time 1002000 ms'),
      );
    });

    test('packets that arrive while the start is still pending count, and '
        'the window opens once the start returns', () async {
      final gate = Completer<void>();
      final r = _Rig(beginGate: gate);
      final starting = r.session.start(_tap());
      await r.settle();
      await r.steady();
      expect(r.windowOpen, isFalse, reason: 'the start has not returned yet');
      gate.complete();
      await starting;
      await r.settle();
      expect(r.windowOpen, isTrue);
    });

    test('max 2: steady, two buzzes, and it ends at once', () async {
      final r = _Rig(max: 2);
      await r.session.start(_tap());
      await r.steady();
      expect(r.began, 1);
      expect(r.buzzes.map((b) => b.$1), [2]);
      expect(r.results, [(2, null)]);
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
    });
  });

  group('the trace names every stage with its timing', () {
    test('tap, command written, first packet, steady, window', () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.steady();
      final all = r.steps.join('\n');
      expect(all, contains('Double tap received'));
      expect(all, matches(RegExp(r'ECG stream command written, \d+ ms after the tap')));
      expect(all, matches(RegExp(r'First packet arrived \d+ ms after the tap')));
      expect(all, matches(RegExp(r'Stream is steady, \d+ ms after the tap')));
      expect(all, matches(RegExp(r'Touch window open at sample time')));
      // In that order.
      final order = [
        'Double tap received',
        'ECG stream command written',
        'First packet arrived',
        'Stream is steady',
        'Touch window open',
      ].map(all.indexOf).toList();
      expect(order, everyElement(isNonNegative));
      expect(order, [...order]..sort());
    });

    test('every packet is logged: number, samples, contact, strap time, gap',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.steady();
      final packets = r.steps.where((s) => s.startsWith('Packet ')).toList();
      expect(packets, hasLength(2));
      expect(
        packets[0],
        matches(
          RegExp(r'^Packet 1: 100 samples, 0 with contact, strap time '
              r'\d+\.\d{3} \(newest sample\), first packet'),
        ),
      );
      expect(
        packets[1],
        matches(
          RegExp(r'^Packet 2: 100 samples, 0 with contact, strap time '
              r'\d+\.\d{3} \(newest sample\), 1000 ms since the last packet, '
              r'continuous with the last packet'),
        ),
      );
    });

    test('contact samples are counted and placed in the packet line', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(milliseconds: 2500));
      r.session.onFrame(_packet(1002, contactFrom: 40, contactTo: 70));
      expect(
        r.steps.where((s) => s.startsWith('Packet 3:')).single,
        contains('30 with contact (samples 40–69)'),
      );
    });

    test('a short packet before a full one is continuous (strap time is the '
        'newest sample)', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(milliseconds: 500));
      r.session.onFrame(_packet(1000, n: 49));
      r.now = _t0.add(const Duration(milliseconds: 1500));
      r.session.onFrame(_packet(1001));
      expect(
        r.steps.where((s) => s.startsWith('Packet 2:')).single,
        contains('continuous with the last packet'),
      );
      expect(r.steps, contains(startsWith('Stream is steady')));
    });

    test('the session announces its method and thresholds when it starts',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      expect(r.started.single, contains('start 300 ms'));
      expect(r.started.single, contains('gap 200 ms'));
      expect(r.started.single, contains('confirm 200 ms'));
    });
  });

  group('the start timeout', () {
    test('no packets: still waiting at 19 s, abandoned past 20 s', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(seconds: 19));
      r.session.poll();
      await r.settle();
      expect(r.session.active, isTrue);
      expect(r.results, isEmpty);
      r.now = _t0.add(const Duration(seconds: 21));
      r.session.poll();
      await r.settle();
      expect(r.results, [(null, 'no_stream')]);
      expect(r.ended, 1);
      expect(r.buzzes, isEmpty, reason: 'never buzzed for a stream that was not up');
      expect(r.session.active, isFalse);
    });

    test('a single packet and then silence also times out', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(seconds: 1));
      r.session.onFrame(_packet(1000));
      r.now = _t0.add(const Duration(seconds: 21));
      r.session.poll();
      await r.settle();
      expect(r.results, [(null, 'no_stream')]);
      expect(r.buzzes, isEmpty);
    });

    test('a slow start (steady only at 18 s) still opens its window',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(seconds: 17));
      r.session.poll();
      r.now = _t0.add(const Duration(seconds: 18));
      r.session.onFrame(_packet(1000));
      r.now = _t0.add(const Duration(milliseconds: 19000));
      r.session.onFrame(_packet(1001));
      r.session.poll();
      await r.settle();
      expect(r.results, isEmpty);
      expect(r.windowOpen, isTrue);
    });

    test('a link that is gone before any packet is abandoned, not awaited',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.results, [(null, 'link_lost')]);
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
    });
  });

  group('counting', () {
    test('a finger already on the sensor: three buzzes, done at max 3',
        () async {
      final r = _Rig(max: 3);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002, contactFrom: 0));
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1],
          reason: 'three pulses go out as a pair and then one');
      expect(r.steps, contains('Buzz x3 requested at sample time 1001700 ms.'),
          reason: 'held from the window opening (1001.5) for the gap');
      expect(r.results, [(3, null)]);
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
    });

    test('a touch that starts inside the window counts the same way',
        () async {
      final r = _Rig(max: 3);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002, contactFrom: 60)); // from 1001.6
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1],
          reason: 'three pulses go out as a pair and then one');
      expect(r.results, [(3, null)]);
    });

    test('contact only while the sensor settles (before the window) does not '
        'count', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002, contactFrom: 0, contactTo: 40));
      await r.settle();
      expect(r.results, [(2, null)]);
      expect(r.buzzes.map((b) => b.$1), [2]);
    });

    test('no touch: two buzzes and it ends at 2, from sample time', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002)); // 100 no-contact samples
      await r.settle();
      expect(r.results, [(2, null)]);
      expect(r.buzzes.map((b) => b.$1), [2],
          reason: 'the two-pulse buzz is the confirmation');
      expect(r.steps, contains('Final count 2 at sample time 1001800 ms.'));
    });

    test('every buzz has its own event id (the dispatcher claims each once)',
        () async {
      final r = _Rig(max: 5, th: EcgTapThresholds(extraSensitive: true));
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 3));
      // [1001.0, 1003.0): touch 1001.5–1001.8, lift 300 ms, touch
      // 1002.1–1002.4, then nothing: counts 3, 4, then confirms.
      final p = _packet(1003, n: 200, contactFrom: 50, contactTo: 80);
      for (var i = 110; i < 140; i++) {
        p.samples[i] = 120;
      }
      r.session.onFrame(p);
      await r.settle();
      expect(r.results, [(4, null)]);
      expect(r.buzzes.map((b) => b.$1), [2, 1, 1, 1]);
      expect(r.buzzes.map((b) => b.$2).toSet(), hasLength(4));
    });

    test('a stream that goes away abandons with no action, and resets',
        () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.results, [(null, 'link_lost')]);
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
      // The next tap is not swallowed by a stuck latch.
      r.alive = true;
      await r.session.start(_tap(sec: 5));
      expect(r.began, 2);
      expect(r.session.active, isTrue);
    });

    test('a stalled stream (no packets for a while) abandons', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady(); // window open; no packet after it
      r.now = r.now.add(const Duration(seconds: 4));
      r.session.poll();
      await r.settle();
      expect(r.results.single.$2, 'stalled');
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
    });

    test('a stream that will not start throws, resets and ends nothing',
        () async {
      final r = _Rig(startOk: false);
      await expectLater(r.session.start(_tap()), throwsStateError);
      expect(r.session.active, isFalse);
      expect(r.ended, 0);
      expect(r.buzzes, isEmpty);
      expect(r.results, [(null, 'start_failed')]);
    });

    test('a second tap while one gesture runs is ignored', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.session.start(_tap(sec: 2));
      expect(r.began, 1);
    });
  });

  group('contact inside a packet (extra sensitive off by default)', () {
    // Packet 1002 [1001.0, 1002.0): contact 50..72, a 250 ms lift (73..97),
    // contact again from 98, straight into packet 1003 (to 1002.3), then none.
    Future<_Rig> liftInsideAPacket(EcgTapThresholds th) async {
      final r = _Rig(max: 5, th: th);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      final p = _packet(1002, contactFrom: 50, contactTo: 73);
      p.samples[98] = 120;
      p.samples[99] = 120;
      r.session.onFrame(p);
      r.now = _t0.add(const Duration(seconds: 3));
      r.session.onFrame(_packet(1003, contactFrom: 0, contactTo: 30));
      await r.settle();
      return r;
    }

    test('off: first to last signal in a packet is one touch, so a lift '
        'inside one packet is not a new tap', () async {
      final r = await liftInsideAPacket(EcgTapThresholds());
      expect(r.results, [(3, null)]);
      expect(r.buzzes.map((b) => b.$1), [2, 1, 1]);
    });

    test('on: every reading counts, so the same lift is a fourth tap',
        () async {
      final r = await liftInsideAPacket(EcgTapThresholds(extraSensitive: true));
      expect(r.results, [(4, null)]);
      expect(r.buzzes.map((b) => b.$1), [2, 1, 1, 1]);
    });

    test('off: a single zero reading cannot restart the hold time', () async {
      Future<List<String>> run(EcgTapThresholds th) async {
        final r = _Rig(max: 3, th: th);
        await r.session.start(_tap());
        await r.steady();
        r.now = _t0.add(const Duration(seconds: 2));
        final p = _packet(1002, contactFrom: 0);
        p.samples[69] = 0; // the trace crossing zero at 1001.69
        r.session.onFrame(p);
        await r.settle();
        return r.steps.where((s) => s.startsWith('Buzz x3 requested')).toList();
      }

      expect(await run(EcgTapThresholds()),
          ['Buzz x3 requested at sample time 1001700 ms.']);
      expect(await run(EcgTapThresholds(extraSensitive: true)),
          ['Buzz x3 requested at sample time 1001900 ms.'],
          reason: 'extra sensitive: the zero restarts the 200 ms hold');
    });
  });

  group('buzz pacing', () {
    test('three pulses go out as a pair, then one after the quiet gap',
        () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002, contactFrom: 50, contactTo: 80));
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1]);
      expect(r.waits, [const Duration(milliseconds: 1800)],
          reason: 'the band drops a third pulse 300 ms after a pair');
      expect(r.steps, contains('Buzz x3, pulses 1–2 written, 0 ms after the request.'));
      expect(r.steps, contains(startsWith('Buzz x3, pulse 3 waits 1800 ms')));
      expect(r.buzzes[1].$2, '${r.buzzes[0].$2}:b1',
          reason: 'each burst has its own event id');
    });

    test('a buzz asked for inside the quiet gap waits for the band', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      // Tap 3 engages at 1001.7; its bursts are written at 2.0 s (the rig's
      // clock does not move while it waits): quiet until 3.8 s.
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002, contactFrom: 50, contactTo: 80));
      await r.settle();
      // Released by 1002.0; tap 4 touches from 1002.05 and engages at 1002.25,
      // asked for at 2.5 s: 1300 ms before the band is quiet.
      r.now = _t0.add(const Duration(milliseconds: 2500));
      r.session.onFrame(_packet(1002, subMs: 500, n: 50, contactFrom: 5));
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1, 1]);
      expect(r.waits.last, const Duration(milliseconds: 1300));
      expect(r.steps, contains(startsWith('Buzz x1 waits 1300 ms')));
    });

    test('buzzes stay in order and survive the end of the gesture', () async {
      final feedback = [for (var i = 0; i < 3; i++) Completer<bool>()];
      var delivered = 0;
      final r = _Rig(
        max: 4,
        th: EcgTapThresholds(extraSensitive: true),
        sendBuzz: (_, _) => feedback[delivered++].future,
      );
      await r.session.start(_tap());
      await r.steady();
      // One buffered packet with both touches: counts 3 then 4 (= max).
      final p = _packet(1003, n: 200, contactFrom: 50, contactTo: 80);
      for (var i = 110; i < 140; i++) {
        p.samples[i] = 120;
      }
      r.now = _t0.add(const Duration(seconds: 3));
      r.session.onFrame(p);
      await r.settle();
      expect(r.results, [(4, null)]);
      expect(r.session.active, isFalse);
      expect(r.ended, 1);
      expect(r.buzzes.map((b) => b.$1), [2], reason: 'one burst at a time');
      feedback[0].complete(true);
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1]);
      feedback[1].complete(true);
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1, 1],
          reason: 'queued feedback survives the final count');
      feedback[2].complete(true);
      await r.settle();
      expect(r.results, [(4, null)],
          reason: 'feedback does not finish the gesture twice');
    });

    for (final throws in [false, true]) {
      test('a buzz that could not be written (${throws ? 'thrown' : 'rejected'}) '
          'is logged, sends nothing more, and the count stands', () async {
        final r = _Rig(
          max: 3,
          sendBuzz: (_, _) async {
            if (throws) throw StateError('haptic transport failed');
            return false;
          },
        );
        await r.session.start(_tap());
        await r.steady();
        r.now = _t0.add(const Duration(seconds: 2));
        r.session.onFrame(_packet(1002, contactFrom: 0));
        await r.settle();
        expect(r.results, [(3, null)]);
        expect(r.steps,
            contains(startsWith('Buzz x3, pulses 1–2 could not be written')));
        expect(r.buzzes.map((b) => b.$1), [2],
            reason: 'pulse 3 is not sent after a failed pair');
        await r.session.start(_tap(sec: 5));
        expect(r.began, 2, reason: 'the next gesture is not blocked');
      });
    }
  });

  group('the sensor\'s reacquire time after a lift', () {
    // The 18:17 lab log, session at 18:19:10: lift at 761.82, the finger shows
    // again at 763.78 (sample 76 of its packet). Gap 200, confirm 1000.
    Future<_Rig> liftThenLateTouch(Duration reacquire) async {
      final r = _Rig(
          max: 5,
          reacquire: reacquire,
          th: EcgTapThresholds(confirmMs: 1000));
      await r.session.start(_tap());
      await r.steady(); // window [1001.5, 1001.8)
      r.now = _t0.add(const Duration(seconds: 2));
      // Touch through 1001.82 (tap 3), then a lift.
      r.session.onFrame(_packet(1002, contactFrom: 0, contactTo: 82));
      r.now = _t0.add(const Duration(seconds: 3));
      r.session.onFrame(_packet(1003)); // all zero
      r.now = _t0.add(const Duration(seconds: 4));
      // The returning finger shows at sample 76: 1003.76, 1.94 s after it.
      r.session.onFrame(_packet(1004, contactFrom: 76));
      r.now = _t0.add(const Duration(seconds: 5));
      r.session.onFrame(_packet(1005, contactTo: 30));
      r.now = _t0.add(const Duration(seconds: 6));
      r.session.onFrame(_packet(1006));
      r.session.onFrame(_packet(1007));
      r.session.onFrame(_packet(1008));
      await r.settle();
      return r;
    }

    test('without it, the window closes 1.2 s after the lift: the re-touch '
        'is too late (what the lab saw)', () async {
      final r = await liftThenLateTouch(Duration.zero);
      expect(r.results, [(3, null)]);
    });

    test('with the measured 1.5 s it counts as tap 4', () async {
      final r = await liftThenLateTouch(const Duration(milliseconds: 1500));
      expect(r.results, [(4, null)]);
    });

    test('the session default is 1.5 s', () {
      final s = EcgTapSession(
        beginStream: () async => true,
        endStream: () async {},
        isStreamAlive: () => true,
        buzz: (_, _) async => true,
        maxTaps: () => 3,
        thresholds: EcgTapThresholds.new,
        onFinished: (_, _) {},
      );
      expect(s.sensorReacquire, const Duration(milliseconds: 1500));
      expect(s.maxPulsesPerBurst, 2);
    });
  });

  group('band status and the lab post-roll', () {
    test('every packet line carries the band\'s presence, S2 state and flags',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.steady();
      expect(r.steps.where((s) => s.startsWith('Packet 1:')).single,
          endsWith('; band: presence on, S2 0, flags 0x0a, progress 0, '
              'quality 0'));
    });

    test('a post-roll keeps logging packets after the count, counts nothing, '
        'and stops the stream after it', () async {
      final waits = <Duration>[];
      final ended = <int>[];
      final seen = <LabradorR17>[];
      final steps = <String>[];
      final results = <(int?, String?)>[];
      var now = _t0;
      late final EcgTapSession s;
      s = EcgTapSession(
        beginStream: () async => true,
        endStream: () async => ended.add(1),
        isStreamAlive: () => true,
        buzz: (_, _) async => true,
        maxTaps: () => 3,
        thresholds: EcgTapThresholds.new,
        onFinished: (c, r) => results.add((c, r)),
        step: steps.add,
        onPacket: (r, _) => seen.add(r),
        now: () => now,
        wait: (d) async {
          waits.add(d);
          // A packet arrives while the stream is kept on.
          s.onFrame(_packet(1003, contactFrom: 76));
        },
        pollEvery: const Duration(hours: 1),
        postRoll: () => const Duration(seconds: 3),
      );
      await s.start(_tap());
      now = _t0.add(const Duration(milliseconds: 500));
      s.onFrame(_packet(1000));
      now = _t0.add(const Duration(milliseconds: 1500));
      s.onFrame(_packet(1001));
      now = _t0.add(const Duration(seconds: 2));
      s.onFrame(_packet(1002)); // no touch: ends at 2
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(results, [(2, null)], reason: 'reported at once');
      expect(waits, contains(const Duration(seconds: 3)));
      expect(steps, contains(startsWith('After the count, packet 1: 100 '
          'samples, 24 with contact (samples 76–99)')));
      expect(seen, hasLength(4), reason: 'the post-roll packet is kept too');
      expect(ended, [1], reason: 'the stream stops after the post-roll');
    });

    test('no post-roll after an abandon', () async {
      var asked = 0;
      final s = EcgTapSession(
        beginStream: () async => true,
        endStream: () async {},
        isStreamAlive: () => false,
        buzz: (_, _) async => true,
        maxTaps: () => 3,
        thresholds: EcgTapThresholds.new,
        onFinished: (_, _) {},
        wait: (_) async {},
        pollEvery: const Duration(hours: 1),
        postRoll: () {
          asked++;
          return const Duration(seconds: 3);
        },
      );
      await s.start(_tap());
      s.poll(); // link lost
      await Future<void>.delayed(Duration.zero);
      expect(asked, 0);
    });
  });
}
