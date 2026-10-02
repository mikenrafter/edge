// EcgTapSession and the ECG sample clock (review findings E and F).
//
// Receipt time is not sample time: BLE can hold packets back by a second or
// more. The session therefore (1) only calls the stream steady when the sample
// clock is continuous AND advancing in step with the wall clock, and (2) opens
// the first touch window at the acknowledgement time mapped through the
// least-delayed recent packet (EcgSampleClock), not through "the end of the last
// packet plus the wall time since it arrived", which anchors the window behind
// the true sample clock by however late that packet was. It also logs, for the
// Device lab, how far each packet sits behind the freshest one.

import 'dart:async';
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

/// A packet starting at strap second [sec] + [subMs]; contact is the sample
/// range [contactFrom, contactTo).
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
          i >= contactFrom && (contactTo == null || i < contactTo) ? 120 : 0,
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
      buzz: (pulses, id) {
        buzzes.add((pulses, id));
        return pulses == 2 ? ack.future : Future.value(true);
      },
      maxTaps: () => max,
      thresholds: EcgTapThresholds.new,
      onFinished: (count, reason) => results.add((count, reason)),
      step: steps.add,
      now: () => now,
      pollEvery: const Duration(hours: 1),
    );
  }

  final int max = 3;
  final Completer<bool> ack = Completer<bool>();
  DateTime now = _t0;
  late final EcgTapSession session;
  int ended = 0;
  final buzzes = <(int, String)>[];
  final results = <(int?, String?)>[];
  final steps = <String>[];

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Deliver [p] at [ms] after t0.
  void deliver(LabradorR17 p, int ms) {
    now = _t0.add(Duration(milliseconds: ms));
    session.onFrame(p);
  }

  Future<void> ackAt(int ms) async {
    now = _t0.add(Duration(milliseconds: ms));
    ack.complete(true);
    await settle();
  }
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
      expect(r.buzzes, isEmpty, reason: 'back-to-back packets are not flow');
      // The first genuinely live packet: 1 s of samples after 1 s of wall time.
      r.deliver(_packet(1003), 1320);
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2]);
    });

    test('a touch right after the buzz counts: the window is anchored to the '
        'least-delayed packet, not to the stale burst', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 300);
      r.deliver(_packet(1001), 310);
      r.deliver(_packet(1002), 320);
      r.deliver(_packet(1003), 1320);
      await r.ackAt(1500); // boundary = 1500 ms mapped = sample time 1004.18
      r.deliver(_packet(1004, contactFrom: 30, contactTo: 60), 2320);
      await r.settle();
      expect(r.results, [(3, null)]);
      expect(r.buzzes.map((b) => b.$1), [2, 1]);
    });
  });

  group('a late packet before the acknowledgement', () {
    test('does not drag the window back (old: receipt + elapsed, 1 s behind)',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 1000); // on time: delay -1000
      r.deliver(_packet(1001), 2000);
      await r.settle();
      expect(r.buzzes.map((b) => b.$1), [2]);
      r.deliver(_packet(1002), 4000); // BLE hiccup: this one is 1 s late
      await r.ackAt(4005); // boundary should be 1004.005, not 1003.005
      r.deliver(_packet(1003), 4010); // backlog, nothing in it after boundary
      // The wearer touches 100 ms after the buzz.
      r.deliver(_packet(1004, contactFrom: 10, contactTo: 50), 5000);
      await r.settle();
      expect(r.results, [(3, null)],
          reason: 'the touch starts 95 ms into a 300 ms window');
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

    test('the window line names the mapping and how far it moved the boundary',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 1000);
      r.deliver(_packet(1001), 2000);
      r.deliver(_packet(1002), 4000);
      await r.ackAt(4005);
      final all = r.steps.join('\n');
      expect(all, contains('Touch window open at sample time 1004005 ms'));
      expect(
        all,
        matches(RegExp(r'Sample clock: .*3 packets.*1000 ms later than the '
            r'receipt-time estimate')),
      );
    });
  });

  group('missing samples (finding E)', () {
    test('contact already present at the ack counts after 200 ms of OBSERVED '
        'contact', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 500);
      r.deliver(_packet(1001), 1500);
      await r.settle();
      await r.ackAt(1800); // window opens at 1002.3
      // 1002.3..1002.4 contact (90 ms), the packet ends; the next one is
      // contiguous (1002.4) and continues the contact.
      r.deliver(_packet(1002, contactFrom: 0, n: 40), 2200);
      expect(r.results, isEmpty);
      r.deliver(_packet(1002, subMs: 400, contactFrom: 0, n: 60), 3000);
      await r.settle();
      expect(r.results, [(3, null)]);
      expect(r.buzzes.map((b) => b.$1), [2, 1]);
    });

    test('the same contact across a 600 ms unobserved gap abandons instead of '
        'counting', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 500);
      r.deliver(_packet(1001), 1500);
      await r.settle();
      await r.ackAt(1800); // window opens at 1002.3, deadline 1002.6
      r.deliver(_packet(1002, contactFrom: 0, n: 40), 2200); // to 1002.4
      r.deliver(_packet(1003, contactFrom: 0), 3000); // next starts 1003.0
      await r.settle();
      expect(r.results, [(null, 'sample_gap')]);
      expect(r.buzzes.map((b) => b.$1), [2], reason: 'no count buzz');
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
    });

    test('a lost packet inside a long no-contact window abandons, not '
        'confirm-2', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.deliver(_packet(1000), 500);
      r.deliver(_packet(1001), 1500);
      await r.settle();
      await r.ackAt(1800); // window [1002.3, 1002.6)
      r.deliver(_packet(1003), 3000); // packet 1002 never arrived
      await r.settle();
      expect(r.results, [(null, 'sample_gap')]);
    });
  });
}
