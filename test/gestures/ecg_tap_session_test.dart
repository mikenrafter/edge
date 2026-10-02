// The glue between the live ECG stream and EcgTapCounter (8L). The counter's
// timing is pinned in test/phase8/ecg_tap_counter_test.dart; this pins what the
// session adds: the stream must be really flowing before the two-pulse
// acknowledgement is asked for, sample times from R17 packets, buzzes through one
// callback, the ack that opens the first window, the step-by-step trace, and the
// latch discipline (every exit resets every flag, so a failed or abandoned
// gesture never swallows the next tap).

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

/// One R17 packet starting at strap second [sec]; [contactFrom] is the first
/// sample index with signal (earlier samples are zero).
LabradorR17 _packet(
  int sec, {
  int contactFrom = 100,
  int? contactTo,
  int n = 100,
}) => LabradorR17(
  packetType: 43,
  headerSecondary: 0,
  sequence: sec,
  strapSeconds: sec,
  subseconds: 0,
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
    Duration? startTimeout,
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
      thresholds: EcgTapThresholds.new,
      onFinished: (count, reason) => results.add((count, reason)),
      onStarted: (tap, settings) => started.add(settings),
      step: steps.add,
      now: () => now,
      pollEvery: const Duration(hours: 1),
      startTimeout: startTimeout ?? const Duration(seconds: 20),
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

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Two packets one second apart, no contact: the stream is steady, so the
  /// acknowledgement is asked for. Leaves `now` at 1.5 s and the first touch
  /// window opening at strap sample time [sec] + 2.0 once the ack is written.
  Future<void> steady({int sec = 1000}) async {
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_packet(sec));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_packet(sec + 1));
    await settle();
  }
}

void main() {
  test('the default start timeout is twenty seconds', () {
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
  });

  group('the acknowledgement waits for a steady stream', () {
    test('a started stream command alone asks for nothing', () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.settle();
      expect(r.began, 1);
      expect(r.buzzes, isEmpty);
      expect(r.session.active, isTrue);
    });

    test('one packet is not steady; the second one is', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(milliseconds: 500));
      r.session.onFrame(_packet(1000));
      await r.settle();
      expect(r.buzzes, isEmpty);
      r.now = _t0.add(const Duration(milliseconds: 1500));
      r.session.onFrame(_packet(1001));
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2]);
    });

    test('two packets too far apart are not steady yet', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(milliseconds: 500));
      r.session.onFrame(_packet(1000));
      r.now = _t0.add(const Duration(milliseconds: 2600));
      r.session.onFrame(_packet(1001));
      await r.settle();
      expect(r.buzzes, isEmpty);
      r.now = _t0.add(const Duration(milliseconds: 3600));
      r.session.onFrame(_packet(1002));
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2]);
    });

    test('packets that arrive while the start is still pending count, and '
        'the acknowledgement follows the start', () async {
      final gate = Completer<void>();
      final r = _Rig(beginGate: gate);
      final starting = r.session.start(_tap());
      await r.settle();
      r.now = _t0.add(const Duration(milliseconds: 500));
      r.session.onFrame(_packet(1000));
      r.now = _t0.add(const Duration(milliseconds: 1500));
      r.session.onFrame(_packet(1001));
      await r.settle();
      expect(r.buzzes, isEmpty, reason: 'the start has not returned yet');
      gate.complete();
      await starting;
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2]);
    });

    test('max 2: steady, acknowledged, and it ends at once', () async {
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
    test('tap, command written, first packet, steady, ack, window', () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.steady();
      final all = r.steps.join('\n');
      expect(all, contains('Double tap received'));
      expect(all, matches(RegExp(r'ECG stream command written, \d+ ms after the tap')));
      expect(all, matches(RegExp(r'First packet arrived \d+ ms after the tap')));
      expect(all, matches(RegExp(r'Stream is steady, \d+ ms after the tap')));
      expect(
        all,
        matches(RegExp(r'Acknowledgement written, \d+ ms after the tap')),
      );
      expect(all, matches(RegExp(r'Touch window open at sample time')));
      // In that order.
      final order = [
        'Double tap received',
        'ECG stream command written',
        'First packet arrived',
        'Stream is steady',
        'Acknowledgement written',
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
              r'\d+\.\d{3}, first packet'),
        ),
      );
      expect(
        packets[1],
        matches(
          RegExp(r'^Packet 2: 100 samples, 0 with contact, strap time '
              r'\d+\.\d{3}, 1000 ms since the last packet'),
        ),
      );
    });

    test('contact samples are counted in the packet line', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(milliseconds: 2500));
      r.session.onFrame(_packet(1002, contactFrom: 40, contactTo: 70));
      expect(
        r.steps.where((s) => s.startsWith('Packet 3:')).single,
        contains('30 with contact'),
      );
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
      expect(r.buzzes, isEmpty, reason: 'never acknowledged a stream that was not up');
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

    test('a slow start (steady only at 18 s) still gets its acknowledgement',
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
      expect(r.buzzes.map((b) => b.$1), [2]);
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
    test('a touch that holds counts, buzzes once and finishes at max', () async {
      final r = _Rig(max: 3);
      await r.session.start(_tap());
      await r.steady(); // the window opens at sample time 1002.0
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002, contactFrom: 10));
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1]);
      expect(r.results, [(3, null)]);
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
    });

    test('every buzz has its own event id (the dispatcher claims each once)',
        () async {
      final r = _Rig(max: 4);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002, contactFrom: 10));
      await r.settle();
      expect(r.buzzes.map((b) => b.$2).toSet(), hasLength(r.buzzes.length));
    });

    test('no touch: the 2-tap count is confirmed from sample time', () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002)); // 100 no-contact samples
      await r.settle();
      expect(r.results, [(2, null)]);
      expect(r.buzzes.map((b) => b.$1), [2, 1]);
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
      await r.steady();
      r.now = _t0.add(const Duration(milliseconds: 1600));
      r.session.onFrame(_packet(1002, n: 10)); // 90 ms of quiet, window open
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

  group('acknowledgement round trip and buffered ECG', () {
    test('ECG samples while the acknowledgement is pending count nothing',
        () async {
      final ack = Completer<bool>();
      final r = _Rig(
        sendBuzz: (pulses, _) => pulses == 2 ? ack.future : Future.value(true),
      );
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002, contactFrom: 0));
      await r.settle();
      expect(r.results, isEmpty);
      expect(r.buzzes.map((b) => b.$1), [2]);
      r.alive = false;
      r.session.poll();
      ack.complete(true);
      await r.settle();
    });

    for (final throws in [false, true]) {
      test(
        'an acknowledgement that could not be written (${throws ? 'thrown' : 'rejected'}) '
        'abandons and frees the next gesture',
        () async {
          var attempts = 0;
          final r = _Rig(
            sendBuzz: (pulses, _) async {
              if (pulses == 2 && attempts++ == 0) {
                if (throws) throw StateError('haptic transport failed');
                return false;
              }
              return true;
            },
          );
          await r.session.start(_tap());
          await r.steady();
          expect(r.results, hasLength(1));
          expect(r.results.single.$1, isNull);
          expect(r.results.single.$2, 'ack_failed');
          expect(r.session.active, isFalse);
          expect(r.ended, 1);
          await r.session.start(_tap(sec: 5));
          expect(r.began, 2);
          expect(r.session.active, isTrue);
          r.alive = false;
          r.session.poll();
          await r.settle();
        },
      );
    }

    test('a band that merely never answers is not an ack failure', () async {
      // The buzz callback reports the WRITE; a silent band is still delivered.
      final r = _Rig(max: 3, sendBuzz: (_, _) async => true);
      await r.session.start(_tap());
      await r.steady();
      expect(r.results, isEmpty);
      expect(r.session.active, isTrue);
      expect(
        r.steps.join('\n'),
        isNot(contains('ack_failed')),
      );
      r.alive = false;
      r.session.poll();
      await r.settle();
    });

    test(
      'delayed first packet counts a touch after acknowledgement instead of confirming two',
      () async {
        final ack = Completer<bool>();
        final r = _Rig(
          sendBuzz: (pulses, _) => pulses == 2 ? ack.future : Future.value(true),
        );
        await r.session.start(_tap());
        await r.steady(); // packet 2 ends at sample time 1002.0
        r.now = _t0.add(const Duration(milliseconds: 1800));
        ack.complete(true); // window opens at 1002.3, start deadline 1002.6
        await r.settle();
        r.now = _t0.add(const Duration(milliseconds: 2500));
        r.session.onFrame(_packet(1002, contactFrom: 40, contactTo: 70));
        await r.settle();
        expect(r.results, [(3, null)]);
        expect(r.buzzes.map((b) => b.$1), [2, 1]);
      },
    );

    test(
      'contact already present at acknowledgement counts after 200 ms and gets feedback',
      () async {
        final ack = Completer<bool>();
        final r = _Rig(
          sendBuzz: (pulses, _) => pulses == 2 ? ack.future : Future.value(true),
        );
        await r.session.start(_tap());
        await r.steady();
        r.now = _t0.add(const Duration(milliseconds: 1800));
        ack.complete(true); // window opens at 1002.3
        await r.settle();
        r.now = _t0.add(const Duration(milliseconds: 2200));
        r.session.onFrame(_packet(1002, contactFrom: 0, n: 40));
        expect(
          r.results,
          isEmpty,
          reason: 'pre-ack contact does not satisfy the debounce',
        );
        expect(r.buzzes.map((b) => b.$1), [2]);
        r.now = _t0.add(const Duration(milliseconds: 3000));
        r.session.onFrame(_packet(1003, contactFrom: 0));
        await r.settle();
        expect(r.results, [(3, null)]);
        expect(r.buzzes.map((b) => b.$1), [2, 1]);
      },
    );

    test('a completed touch entirely before acknowledgement is excluded',
        () async {
      final ack = Completer<bool>();
      final r = _Rig(
        sendBuzz: (pulses, _) => pulses == 2 ? ack.future : Future.value(true),
      );
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(milliseconds: 1800));
      ack.complete(true); // window opens at 1002.3
      await r.settle();
      r.now = _t0.add(const Duration(milliseconds: 2500));
      r.session.onFrame(_packet(1002, contactFrom: 0, contactTo: 25));
      await r.settle();
      expect(r.results, [(2, null)]);
    });

    test('a packet seen during acknowledgement anchors the following contact '
        'packet', () async {
      final ack = Completer<bool>();
      final r = _Rig(
        sendBuzz: (pulses, _) => pulses == 2 ? ack.future : Future.value(true),
      );
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002)); // seen while the ack is in flight
      r.now = _t0.add(const Duration(milliseconds: 2300));
      ack.complete(true); // window opens at 1003.3, deadline 1003.6
      await r.settle();
      r.now = _t0.add(const Duration(seconds: 3));
      r.session.onFrame(_packet(1003, contactFrom: 40, contactTo: 70));
      await r.settle();
      expect(r.results, [(3, null)]);
    });

    test(
      'late acknowledgement from an abandoned session cannot open a new session',
      () async {
        final oldAck = Completer<bool>();
        final newAck = Completer<bool>();
        var acknowledgements = 0;
        final r = _Rig(
          sendBuzz: (pulses, _) {
            if (pulses != 2) return Future.value(true);
            return acknowledgements++ == 0 ? oldAck.future : newAck.future;
          },
        );
        await r.session.start(_tap());
        await r.steady();
        r.alive = false;
        r.session.poll();
        await r.settle();
        r.alive = true;
        await r.session.start(_tap(sec: 5));
        r.now = _t0.add(const Duration(seconds: 6));
        r.session.onFrame(_packet(1005));
        r.now = _t0.add(const Duration(seconds: 7));
        r.session.onFrame(_packet(1006));
        await r.settle();
        oldAck.complete(true);
        await r.settle();
        r.now = _t0.add(const Duration(seconds: 8));
        r.session.onFrame(_packet(1007, contactFrom: 0));
        await r.settle();
        expect(r.results, [(null, 'link_lost')]);
        expect(r.buzzes.map((b) => b.$1), [2, 2]);
        expect(r.session.active, isTrue);
        r.alive = false;
        r.session.poll();
        newAck.complete(true);
        await r.settle();
      },
    );

    test('three separate electrode touches each send one haptic confirmation',
        () async {
      final ack = Completer<bool>();
      final r = _Rig(
        max: 5,
        sendBuzz: (pulses, _) => pulses == 2 ? ack.future : Future.value(true),
      );
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(milliseconds: 1800));
      ack.complete(true);
      await r.settle();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_packet(1002, contactFrom: 40, contactTo: 70));
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1]);
      expect(r.results, isEmpty);
      r.now = _t0.add(const Duration(milliseconds: 2500));
      r.session.onFrame(_packet(1003, contactFrom: 0, contactTo: 30, n: 50));
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1, 1]);
      expect(r.results, isEmpty);
      r.now = _t0.add(const Duration(seconds: 3));
      r.session.onFrame(_packet(1003, contactFrom: 60));
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2, 1, 1, 1]);
      expect(r.results, [(5, null)]);
      expect(r.buzzes.map((b) => b.$2).toSet(), hasLength(4));
    });
  });

  test(
    'buffered touches send feedback in order after the final count resets the session',
    () async {
      final ack = Completer<bool>();
      final feedback = [for (var i = 0; i < 2; i++) Completer<bool>()];
      var delivered = 0;
      final r = _Rig(
        max: 4,
        sendBuzz: (pulses, _) {
          if (pulses == 2) return ack.future;
          return feedback[delivered++].future;
        },
      );
      await r.session.start(_tap());
      await r.steady();
      ack.complete(true); // window opens at 1002.0
      await r.settle();
      final buffered = _packet(1002, contactFrom: 0, contactTo: 30);
      for (var i = 60; i < 90; i++) {
        buffered.samples[i] = 120;
      }
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(buffered);
      await r.settle();
      expect(r.results, [(4, null)]);
      expect(r.session.active, isFalse);
      expect(r.ended, 1);
      expect(
        r.buzzes.map((b) => b.$1),
        [2, 1],
        reason: 'a buffered packet must not overlap its haptic round trips',
      );
      feedback[0].complete(true);
      await r.settle();
      expect(
        r.buzzes.map((b) => b.$1),
        [2, 1, 1],
        reason: 'queued feedback survives the final count',
      );
      feedback[1].complete(true);
      await r.settle();
      expect(r.buzzes.map((b) => b.$2).toSet(), hasLength(3));
      expect(r.results, [
        (4, null),
      ], reason: 'feedback does not finish the gesture twice');
    },
  );
}
