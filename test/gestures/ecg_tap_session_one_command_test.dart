// 8W: a count of N is N separate band commands. The 20:40 lab log showed one
// buzz command is felt as ONE "bzz-bzz" however many pulses it was meant to
// hold, and that the band swallows a command written while it still plays.
// So the ECG tap session sends one pulse per command (maxPulsesPerBurst 1),
// each at least buzzQuietGap (1800 ms) after the previous write landed.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 20);

LabradorR17 _packet(int sec, {int contactFrom = 100, int? contactTo}) =>
    LabradorR17(
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
      sampleCount: 100,
      samples: Int16List.fromList([
        for (var i = 0; i < 100; i++)
          // A moving trace: 8X contact is movement, not a non-zero level.
          i >= contactFrom && (contactTo == null || i < contactTo)
              ? (i.isEven ? 120 : -120)
              : 0,
      ]),
      tail: Uint8List(0),
      inner: Uint8List(0),
    );

/// One buzz call: what was asked, when the call started, when its write landed
/// (ms on the virtual clock; the clock moves only through the session's waits
/// and the write time below).
typedef _Call = ({int pulses, int startMs, int landedMs});

class _Rig {
  _Rig({required int max}) {
    session = EcgTapSession(
      beginStream: () async => true,
      endStream: () async {},
      isStreamAlive: () => true,
      buzz: (pulses, id) async {
        final start = _ms;
        now = now.add(const Duration(milliseconds: 60)); // the write
        calls.add((pulses: pulses, startMs: start, landedMs: _ms));
        return true;
      },
      maxTaps: () => max,
      thresholds: EcgTapThresholds.new,
      onFinished: (c, r) => results.add((c, r)),
      now: () => now,
      wait: (d) async => now = now.add(d),
      pollEvery: const Duration(hours: 1),
      sensorReacquire: Duration.zero,
    );
  }

  late final EcgTapSession session;
  DateTime now = _t0;
  final calls = <_Call>[];
  final results = <(int?, String?)>[];
  int get _ms => now.difference(_t0).inMilliseconds;

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// A steady stream, then a finger on from the start of the window.
  Future<void> fingerOn() async {
    await session.start(
      StrapEvent(
        eventId: 14,
        tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000,
        receivedAt: _t0.add(const Duration(milliseconds: 300)),
        hex: '',
        deviceId: 'band',
      ),
    );
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_packet(1000));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_packet(1001));
    await settle();
    now = _t0.add(const Duration(seconds: 2));
    session.onFrame(_packet(1002, contactFrom: 0));
    await settle();
  }
}

void main() {
  test('a count of 3 is three separate buzz calls, one pulse each, every '
      'one at least 1800 ms after the previous write', () async {
    final r = _Rig(max: 3);
    await r.fingerOn();
    expect(r.results, [(3, null)]);
    expect(r.calls.map((c) => c.pulses), [1, 1, 1]);
    for (var i = 1; i < r.calls.length; i++) {
      expect(
        r.calls[i].startMs - r.calls[i - 1].landedMs,
        greaterThanOrEqualTo(1800),
        reason: 'call ${i + 1} follows the write of call $i by the quiet gap',
      );
    }
  });

  test('a count of 2 is two separate calls', () async {
    final r = _Rig(max: 2);
    await r.fingerOn();
    expect(r.results, [(2, null)]);
    expect(r.calls.map((c) => c.pulses), [1, 1]);
    expect(
      r.calls[1].startMs - r.calls[0].landedMs,
      greaterThanOrEqualTo(1800),
    );
  });

  test('the default is one pulse per burst', () {
    final s = EcgTapSession(
      beginStream: () async => true,
      endStream: () async {},
      isStreamAlive: () => true,
      buzz: (_, _) async => true,
      maxTaps: () => 3,
      thresholds: EcgTapThresholds.new,
      onFinished: (_, _) {},
    );
    expect(s.maxPulsesPerBurst, 1);
    expect(s.buzzQuietGap, const Duration(milliseconds: 1800));
  });
}
