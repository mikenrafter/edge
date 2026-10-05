// Every gesture session writes its interval (strap start/end, final count
// or abandoned) on EVERY exit path, and a failing writer never wedges the
// latch. The interval is the only thing kept: no samples (invariant 14).

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

LabradorR17 _packet(int sec, {int sub = 0, int contactFrom = 100, int n = 100}) =>
    LabradorR17(
      packetType: 43,
      headerSecondary: 0,
      sequence: sec,
      strapSeconds: sec,
      subseconds: sub,
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
      // A moving trace: contact is movement, not a non-zero level.
      samples: Int16List.fromList([
        for (var i = 0; i < n; i++)
          i >= contactFrom ? (i.isEven ? 120 : -120) : 0,
      ]),
      tail: Uint8List(0),
      inner: Uint8List(0),
    );

class _Rig {
  _Rig({
    this.max = 3,
    this.startOk = true,
    this.throwOnStart = false,
    this.recorderThrows = false,
    this.strapClock,
    EcgTapThresholds? thresholds,
  }) {
    session = EcgTapSession(
      beginStream: () async {
        if (throwOnStart) throw StateError('radio went away');
        return startOk;
      },
      endStream: () async => ended++,
      isStreamAlive: () => alive,
      buzz: (pulses, id) async => true,
      maxTaps: () => max,
      thresholds: () => thresholds ?? EcgTapThresholds(),
      onFinished: (count, reason) => results.add((count, reason)),
      recordSession: (r) async {
        recorded.add(r);
        if (recorderThrows) throw StateError('disk full');
      },
      strapNow: strapClock == null ? null : () => strapClock!(),
      now: () => now,
      pollEvery: const Duration(hours: 1),
    );
  }

  final int max;
  final bool startOk, throwOnStart, recorderThrows;
  bool alive = true;
  int Function()? strapClock;
  DateTime now = _t0;
  late final EcgTapSession session;
  int ended = 0;
  final results = <(int?, String?)>[];
  final recorded = <EcgGestureRecord>[];

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Two packets a second apart: the stream is steady and the first window
  /// opens 2.5 s after the first sample. A packet's strap time is its NEWEST
  /// sample, so packets [sec] and [sec] + 1 cover [sec] - 1 .. [sec] + 1.
  Future<void> steady(int sec, {int sub = 0}) async {
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_packet(sec, sub: sub));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_packet(sec + 1, sub: sub));
    await settle();
  }
}

void main() {
  test('finished: the interval comes from the packets, the count is kept',
      () async {
    final r = _Rig(max: 3);
    await r.session.start(_tap());
    // Packets end at 1000.5 and 1001.5: first sample 999.5, window at 1002.0.
    await r.steady(1000, sub: 16384);
    r.now = _t0.add(const Duration(seconds: 2));
    // [1001.5, 1002.5), contact from 1001.6: held through the window.
    r.session.onFrame(_packet(1002, sub: 16384, contactFrom: 10));
    await r.settle();
    expect(r.results, [(3, null)]);
    expect(r.recorded, hasLength(1));
    final g = r.recorded.single;
    expect(g.finalCount, 3);
    expect(g.reason, isNull);
    expect(g.strapStart, 999, reason: 'floor of 1000.5 - 100 * 10 ms');
    expect(g.strapEnd, 1003, reason: 'ceil of the last packet end, 1002.5');
  });

  // A long quiet window (1.1 s to start + 1 s to confirm) so a few packets
  // arrive before the counter decides on its own.
  final slow = EcgTapThresholds(
      startMs: 1100, confirmMs: 1000, fallbackToDoubleTap: false);

  test('several packets widen the interval to the first start and last end',
      () async {
    final r = _Rig(max: 5, thresholds: slow);
    await r.session.start(_tap());
    await r.steady(2000);
    r.now = _t0.add(const Duration(seconds: 2));
    r.session.onFrame(_packet(2002));
    r.alive = false;
    r.session.poll(); // link lost
    await r.settle();
    final g = r.recorded.single;
    expect(g.strapStart, 1999);
    expect(g.strapEnd, 2002);
  });

  test('abandoned (link lost): written with no count and the reason',
      () async {
    final r = _Rig(max: 4, thresholds: slow);
    await r.session.start(_tap());
    await r.steady(3000);
    r.alive = false;
    r.session.poll();
    await r.settle();
    expect(r.results.single.$1, isNull);
    final g = r.recorded.single;
    expect(g.finalCount, isNull);
    expect(g.reason, isNotNull);
    expect(g.strapStart, 2999);
    expect(r.ended, 1);
  });

  test('start failed (stream refused): written, bounds from the strap clock',
      () async {
    var now = 5000;
    final r = _Rig(
        startOk: false,
        strapClock: () => now++,
        thresholds: EcgTapThresholds(fallbackToDoubleTap: false));
    await expectLater(r.session.start(_tap()), throwsStateError);
    final g = r.recorded.single;
    expect(g.finalCount, isNull);
    expect(g.reason, 'start_failed');
    expect(g.strapStart, isNotNull);
    expect(g.strapEnd, greaterThanOrEqualTo(g.strapStart!));
    expect(r.session.active, isFalse);
  });

  test('start failed (throws): still written, bounds null with no clock',
      () async {
    final r = _Rig(
        throwOnStart: true,
        thresholds: EcgTapThresholds(fallbackToDoubleTap: false));
    await expectLater(r.session.start(_tap()), throwsStateError);
    final g = r.recorded.single;
    expect(g.reason, 'start_failed');
    expect(g.strapStart, isNull);
    expect(g.strapEnd, isNull);
    expect(r.session.active, isFalse);
  });

  test('exactly one record per session, and the next gesture starts clean',
      () async {
    final r = _Rig(max: 2);
    await r.session.start(_tap());
    await r.steady(1000);
    expect(r.recorded, hasLength(1));
    r.session.poll();
    r.session.poll();
    await r.settle();
    expect(r.recorded, hasLength(1));
    await r.session.start(_tap());
    await r.steady(9000);
    expect(r.recorded, hasLength(2));
    expect(r.recorded.last.strapStart, 8999,
        reason: 'nothing carried over from the session before');
  });

  test('a failing writer cannot wedge the latch or skip the stream stop',
      () async {
    final r = _Rig(max: 2, recorderThrows: true);
    await r.session.start(_tap());
    await r.steady(1000);
    expect(r.recorded, hasLength(1));
    expect(r.results, [(2, null)]);
    expect(r.ended, 1, reason: 'the stream is stopped even if the write threw');
    expect(r.session.active, isFalse);
    await r.session.start(_tap());
    await r.steady(1000);
    expect(r.results, hasLength(2));
  });
}
