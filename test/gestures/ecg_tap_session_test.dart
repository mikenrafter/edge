// The glue between the live ECG stream and EcgTapCounter (8L). The counter's
// timing is pinned in test/phase8/ecg_tap_counter_test.dart; this pins what the
// session adds: sample times from R17 packets, buzzes through one callback, the
// ack that opens the first window, and the latch discipline (every exit resets
// every flag, so a failed or abandoned gesture never swallows the next tap).

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
  _Rig({this.max = 3, this.startOk = true, this.sendBuzz}) {
    session = EcgTapSession(
      beginStream: () async {
        began++;
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
      now: () => now,
      pollEvery: const Duration(hours: 1),
    );
  }

  final Future<bool> Function(int, String)? sendBuzz;
  final int max;
  final bool startOk;
  bool alive = true;
  DateTime now = _t0;
  late final EcgTapSession session;
  int began = 0, ended = 0;
  final buzzes = <(int, String)>[];
  final results = <(int?, String?)>[];

  Future<void> settle() => Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'max 2: the stream starts, the tap is acknowledged, and it ends at once',
    () async {
      final r = _Rig(max: 2);
      await r.session.start(_tap());
      await r.settle();
      expect(r.began, 1);
      expect(r.buzzes.map((b) => b.$1), [2]);
      expect(r.results, [(2, null)]);
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
    },
  );

  test('a touch that holds counts, buzzes once and finishes at max', () async {
    final r = _Rig(max: 3);
    await r.session.start(_tap());
    await r.settle(); // acknowledgement completes before these samples
    r.now = _t0.add(const Duration(seconds: 1));
    r.session.onFrame(_packet(1000, contactFrom: 10));
    await r.settle();
    expect(r.buzzes.map((b) => b.$1), [2, 1]);
    expect(r.results, [(3, null)]);
    expect(r.ended, 1);
    expect(r.session.active, isFalse);
  });

  test(
    'every buzz has its own event id (the dispatcher claims each once)',
    () async {
      final r = _Rig(max: 4);
      await r.session.start(_tap());
      await r.settle();
      r.now = _t0.add(const Duration(seconds: 1));
      r.session.onFrame(_packet(1000, contactFrom: 10));
      await r.settle();
      expect(r.buzzes.map((b) => b.$2).toSet(), hasLength(r.buzzes.length));
    },
  );

  test('no touch: the 2-tap count is confirmed from sample time', () async {
    final r = _Rig(max: 5);
    await r.session.start(_tap());
    await r.settle();
    r.now = _t0.add(const Duration(seconds: 1));
    r.session.onFrame(_packet(1000)); // 100 no-contact samples, 0..990 ms
    await r.settle();
    expect(r.results, [(2, null)]);
    expect(r.buzzes.map((b) => b.$1), [2, 1]);
  });

  test('a stream that goes away abandons with no action, and resets', () async {
    final r = _Rig(max: 5);
    await r.session.start(_tap());
    await r.settle();
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
    await r.settle();
    r.now = _t0.add(const Duration(milliseconds: 100));
    r.session.onFrame(_packet(1000, n: 10)); // 90 ms of quiet, window open
    r.now = r.now.add(const Duration(seconds: 4));
    r.session.poll();
    await r.settle();
    expect(r.results.single.$2, 'stalled');
    expect(r.ended, 1);
    expect(r.session.active, isFalse);
  });

  test(
    'a stream that will not start throws, resets and ends nothing',
    () async {
      final r = _Rig(startOk: false);
      await expectLater(r.session.start(_tap()), throwsStateError);
      expect(r.session.active, isFalse);
      expect(r.ended, 0);
      expect(r.buzzes, isEmpty);
      expect(r.results, [(null, 'start_failed')]);
    },
  );

  test('a second tap while one gesture runs is ignored', () async {
    final r = _Rig(max: 5);
    await r.session.start(_tap());
    await r.session.start(_tap(sec: 2));
    expect(r.began, 1);
  });

  group('acknowledgement round trip and buffered ECG', () {
    test(
      'ECG samples while the acknowledgement is pending count nothing',
      () async {
        final ack = Completer<bool>();
        final r = _Rig(
          sendBuzz: (pulses, _) =>
              pulses == 2 ? ack.future : Future.value(true),
        );
        await r.session.start(_tap());
        r.now = _t0.add(const Duration(milliseconds: 1000));
        r.session.onFrame(_packet(1000, contactFrom: 0));
        await r.settle();
        expect(r.results, isEmpty);
        expect(r.buzzes.map((b) => b.$1), [2]);
        r.alive = false;
        r.session.poll();
        ack.complete(true);
        await r.settle();
      },
    );

    for (final throws in [false, true]) {
      test(
        'a ${throws ? 'thrown' : 'rejected'} acknowledgement abandons and frees the next gesture',
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
          await r.settle();
          expect(r.results, hasLength(1));
          expect(
            r.results.single.$1,
            isNull,
            reason: 'no action after an unconfirmed acknowledgement',
          );
          expect(r.results.single.$2, isNotNull);
          expect(r.session.active, isFalse);
          expect(r.ended, 1);
          await r.session.start(_tap(sec: 5));
          await r.settle();
          expect(r.began, 2);
          expect(r.session.active, isTrue);
          r.alive = false;
          r.session.poll();
          await r.settle();
        },
      );
    }

    test(
      'delayed first packet counts a touch after acknowledgement instead of confirming two',
      () async {
        final ack = Completer<bool>();
        final r = _Rig(
          sendBuzz: (pulses, _) =>
              pulses == 2 ? ack.future : Future.value(true),
        );
        await r.session.start(_tap());
        r.now = _t0.add(const Duration(milliseconds: 300));
        ack.complete(true);
        await r.settle();
        r.now = _t0.add(const Duration(milliseconds: 1000));
        r.session.onFrame(_packet(1000, contactFrom: 40, contactTo: 70));
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
          sendBuzz: (pulses, _) =>
              pulses == 2 ? ack.future : Future.value(true),
        );
        await r.session.start(_tap());
        r.now = _t0.add(const Duration(milliseconds: 300));
        ack.complete(true);
        await r.settle();
        r.now = _t0.add(const Duration(milliseconds: 400));
        r.session.onFrame(_packet(1000, contactFrom: 0, n: 40));
        expect(
          r.results,
          isEmpty,
          reason: 'pre-ack contact does not satisfy the debounce',
        );
        expect(r.buzzes.map((b) => b.$1), [2]);
        r.now = _t0.add(const Duration(milliseconds: 1000));
        r.session.onFrame(_packet(1000, contactFrom: 0));
        await r.settle();
        expect(r.results, [(3, null)]);
        expect(r.buzzes.map((b) => b.$1), [2, 1]);
      },
    );

    test(
      'a completed touch entirely before acknowledgement is excluded',
      () async {
        final ack = Completer<bool>();
        final r = _Rig(
          sendBuzz: (pulses, _) =>
              pulses == 2 ? ack.future : Future.value(true),
        );
        await r.session.start(_tap());
        r.now = _t0.add(const Duration(milliseconds: 300));
        ack.complete(true);
        await r.settle();
        r.now = _t0.add(const Duration(milliseconds: 1000));
        r.session.onFrame(_packet(1000, contactFrom: 0, contactTo: 25));
        await r.settle();
        expect(r.results, [(2, null)]);
      },
    );

    test(
      'packet seen during acknowledgement anchors the following contact packet',
      () async {
        final ack = Completer<bool>();
        final r = _Rig(
          sendBuzz: (pulses, _) =>
              pulses == 2 ? ack.future : Future.value(true),
        );
        await r.session.start(_tap());
        r.now = _t0.add(const Duration(seconds: 1));
        r.session.onFrame(_packet(1000));
        r.now = _t0.add(const Duration(milliseconds: 1300));
        ack.complete(true);
        await r.settle();
        r.now = _t0.add(const Duration(seconds: 2));
        r.session.onFrame(_packet(1001, contactFrom: 40, contactTo: 70));
        await r.settle();
        expect(r.results, [(3, null)]);
      },
    );

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
        r.alive = false;
        r.session.poll();
        await r.settle();
        r.alive = true;
        await r.session.start(_tap(sec: 5));
        oldAck.complete(true);
        await r.settle();
        r.now = _t0.add(const Duration(seconds: 6));
        r.session.onFrame(_packet(1005, contactFrom: 0));
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

    test(
      'three separate electrode touches each send one haptic confirmation',
      () async {
        final ack = Completer<bool>();
        final r = _Rig(
          max: 5,
          sendBuzz: (pulses, _) =>
              pulses == 2 ? ack.future : Future.value(true),
        );
        await r.session.start(_tap());
        r.now = _t0.add(const Duration(milliseconds: 300));
        ack.complete(true);
        await r.settle();
        r.now = _t0.add(const Duration(seconds: 1));
        r.session.onFrame(_packet(1000, contactFrom: 40, contactTo: 70));
        await r.settle();
        expect(r.buzzes.map((b) => b.$1), [2, 1]);
        expect(r.results, isEmpty);
        r.now = _t0.add(const Duration(milliseconds: 1500));
        r.session.onFrame(_packet(1001, contactFrom: 0, contactTo: 30, n: 50));
        await r.settle();
        expect(r.buzzes.map((b) => b.$1), [2, 1, 1]);
        expect(r.results, isEmpty);
        r.now = _t0.add(const Duration(seconds: 2));
        r.session.onFrame(_packet(1001, contactFrom: 60));
        await r.settle();
        expect(r.buzzes.map((b) => b.$1), [2, 1, 1, 1]);
        expect(r.results, [(5, null)]);
        expect(r.buzzes.map((b) => b.$2).toSet(), hasLength(4));
      },
    );
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
      ack.complete(true);
      await r.settle();
      final buffered = _packet(1000, contactFrom: 0, contactTo: 30);
      for (var i = 60; i < 90; i++) {
        buffered.samples[i] = 120;
      }
      r.now = _t0.add(const Duration(seconds: 1));
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
