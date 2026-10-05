// EcgTapSession and the ECG sample clock (review findings E and F, and the
// one-clock rule from the 2026-10-02 lab log).
//
// Receipt time is not sample time: BLE can hold packets back by a second or
// more. The session therefore (1) only calls the stream steady when the sample
// clock is continuous AND advancing in step with the wall clock, and (2) opens
// the first touch window on the SAMPLE clock alone ([EcgTapSession.sensorSettle]
// after the stream's first sample), so when packets arrive cannot move it. A
// packet's strap time is its NEWEST sample. It also logs, for the Device lab,
// how far each packet sits behind the freshest one.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

StrapEvent _tap() => StrapEvent(
      eventId: 14,
      tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000,
      receivedAt: _t0.add(const Duration(milliseconds: 300)),
      hex: '',
      deviceId: 'band',
    );

/// A packet whose newest sample is at strap second [sec] + [subMs]; contact is
/// the sample range [contactFrom, contactTo).
LabradorR17 _packet(
  int sec, {
  int subMs = 0,
  int contactFrom = 100,
  int? contactTo,
  int n = 100,
}) =>
    LabradorR17(
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
          // A moving trace: contact is movement, not a non-zero level.
          i >= contactFrom && (contactTo == null || i < contactTo)
              ? (i.isEven ? 120 : -120)
              : 0,
      ]),
      tail: Uint8List(0),
      inner: Uint8List(0),
    );

class _Rig {
  _Rig() {
    session = EcgTapSession(
      beginStream: () async => true,
      endStream: () async => ended++,
      isStreamAlive: () => true,
      buzz: (pulses, id) async {
        buzzes.add((pulses, id));
        return true;
      },
      confirmBuzz: (id) async {
        confirms.add(id);
        return true;
      },
      maxTaps: () => max,
      thresholds: EcgTapThresholds.new,
      onFinished: (count, reason) => results.add((count, reason)),
      step: steps.add,
      now: () => now,
      wait: (_) async {},
      pollEvery: const Duration(hours: 1),
      sensorReacquire: Duration.zero,
    );
  }

  final int max = 3;
  DateTime now = _t0;
  late final EcgTapSession session;
  int ended = 0;
  final buzzes = <(int, String)>[];
  final confirms = <String>[];
  final results = <(int?, String?)>[];
  final steps = <String>[];

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Deliver [p] at [ms] after t0.
  void deliver(LabradorR17 p, int ms) {
    now = _t0.add(Duration(milliseconds: ms));
    session.onFrame(p);
  }

  String get windowLine =>
      steps.where((s) => s.startsWith('Touch window open')).single;
}

void main() {
  group('a stale initial burst', () {
    test('is not a steady stream; the live pair after it is', () async {
      final r = _Rig();
      await r.session.start(_tap());
      // 3 s of buffered samples handed over in 20 ms.
      r.deliver(_packet(1000), 300);
      r.deliver(_packet(1001), 310);
      r.deliver(_packet(1002), 320);
      await r.settle();
      expect(r.steps, isNot(contains(startsWith('Stream is steady'))),
          reason: 'back-to-back packets are not flow');
      // The first genuinely live packet: 1 s of samples after 1 s of wall time.
      r.deliver(_packet(1003), 1320);
      await r.settle();
      expect(r.steps, contains(startsWith('Stream is steady')));
      // First sample 999.0 + 2.5 s settle is already past: open at the newest
      // packet's end.
      expect(r.windowLine, startsWith('Touch window open at sample time '
          '1003000 ms'));
    });

    test('a touch in the next packet counts', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 300);
      r.deliver(_packet(1001), 310);
      r.deliver(_packet(1002), 320);
      r.deliver(_packet(1003), 1320);
      r.deliver(_packet(1004, contactFrom: 10, contactTo: 60), 2320);
      await r.settle();
      expect(r.results, [(3, null)]);
      expect(r.buzzes.map((b) => b.$1), [1], reason: 'one follow-up, for 3');
      expect(r.confirms, hasLength(1));
    });
  });

  group('one clock: when a packet arrives cannot move the window', () {
    test('the same packets received at different times open the same window',
        () async {
      Future<String> run(List<int> receivedMs) async {
        final r = _Rig();
        await r.session.start(_tap());
        r.deliver(_packet(1000), receivedMs[0]);
        r.deliver(_packet(1001), receivedMs[1]);
        await r.settle();
        return r.windowLine;
      }

      final onTime = await run([1000, 2000]);
      expect(onTime, startsWith('Touch window open at sample time 1001500 ms'));
      expect(await run([1400, 2350]), onTime);
    });

    test('a packet held back a second is decided on its own sample times',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 1000);
      r.deliver(_packet(1001), 2000); // window [1001.5, 1001.8)
      // A BLE hiccup: this packet arrives a second late. Its touch starts at
      // sample time 1001.6, inside the window, whatever the phone clock says.
      r.deliver(_packet(1002, contactFrom: 60), 4000);
      await r.settle();
      expect(r.results, [(3, null)]);
    });
  });

  group('the Device lab trace shows the latency estimate', () {
    test('every packet says how far behind the freshest one it arrived',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 1000);
      r.deliver(_packet(1001), 2000);
      r.deliver(_packet(1002), 4000); // 1 s late
      final lines = r.steps.where((s) => s.startsWith('Packet ')).toList();
      expect(lines, hasLength(3));
      expect(lines[0], contains('0 ms behind the freshest packet'));
      expect(lines[1], contains('0 ms behind the freshest packet'));
      expect(lines[2], contains('1000 ms behind the freshest packet'));
    });

    test('continuity with the previous packet is logged', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 1000);
      r.deliver(_packet(1001), 2000);
      r.deliver(_packet(1002, subMs: 600), 3000);
      final lines = r.steps.where((s) => s.startsWith('Packet ')).toList();
      expect(lines[0], contains('first packet'));
      expect(lines[1], contains('continuous with the last packet'));
      expect(lines[2], contains('gap of 600 ms before this packet'));
    });
  });

  group('missing samples (finding E)', () {
    test('contact already there when the window opens counts after 200 ms of '
        'OBSERVED contact', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 500);
      r.deliver(_packet(1001), 1500); // window [1001.5, 1001.8)
      // [1001.0, 1001.6): contact from the start, 100 ms of it in the window.
      r.deliver(_packet(1001, subMs: 600, n: 60, contactFrom: 0), 2100);
      expect(r.results, isEmpty);
      // Contiguous [1001.6, 1002.0) continues it: engaged at 1001.7.
      r.deliver(_packet(1002, n: 40, contactFrom: 0), 2500);
      await r.settle();
      expect(r.results, [(3, null)]);
      expect(r.buzzes.map((b) => b.$1), [1], reason: 'one follow-up, for 3');
      expect(r.confirms, hasLength(1));
    });

    test('the same contact across a 400 ms unobserved gap does not count: the '
        'gesture ends (count 2 by the default fallback, not 3)', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 500);
      r.deliver(_packet(1001), 1500); // window [1001.5, 1001.8)
      r.deliver(_packet(1001, subMs: 600, n: 60, contactFrom: 0), 2100);
      r.deliver(_packet(1003, contactFrom: 0), 3000); // starts at 1002.0
      await r.settle();
      expect(r.results, [(2, 'fallback: sample_gap')]);
      expect(r.buzzes, isEmpty, reason: 'no count buzz');
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
    });

    test('a lost packet inside a long no-contact window ends the gesture as a '
        'failure, not as a confirmed 2', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 500);
      r.deliver(_packet(1001), 1500); // window [1001.5, 1001.8)
      r.deliver(_packet(1003), 3000); // packet 1002 never arrived
      await r.settle();
      expect(r.results, [(2, 'fallback: sample_gap')],
          reason: 'a failure (fallback on), not a normal (2, null)');
    });
  });
}
