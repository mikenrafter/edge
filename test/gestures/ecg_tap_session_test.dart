// The glue between the live ECG stream and EcgTapCounter (8L). The counter's
// timing is pinned in test/phase8/ecg_tap_counter_test.dart; this pins what the
// session adds: sample times from R17 packets, buzzes through one callback, the
// ack that opens the first window, and the latch discipline (every exit resets
// every flag, so a failed or abandoned gesture never swallows the next tap).

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
LabradorR17 _packet(int sec, {int contactFrom = 100, int n = 100}) =>
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
      sampleCount: n,
      samples: Int16List.fromList(
          [for (var i = 0; i < n; i++) i >= contactFrom ? 120 : 0]),
      tail: Uint8List(0),
      inner: Uint8List(0),
    );

class _Rig {
  _Rig({this.max = 3, this.startOk = true, this.alive = true}) {
    session = EcgTapSession(
      beginStream: () async {
        began++;
        return startOk;
      },
      endStream: () async => ended++,
      isStreamAlive: () => alive,
      buzz: (pulses, id) async {
        buzzes.add((pulses, id));
        return true;
      },
      maxTaps: () => max,
      thresholds: EcgTapThresholds.new,
      onFinished: (count, reason) => results.add((count, reason)),
      now: () => now,
      pollEvery: const Duration(hours: 1),
    );
  }

  final int max;
  final bool startOk;
  bool alive;
  DateTime now = _t0;
  late final EcgTapSession session;
  int began = 0, ended = 0;
  final buzzes = <(int, String)>[];
  final results = <(int?, String?)>[];

  Future<void> settle() => Future<void>.delayed(Duration.zero);
}

void main() {
  test('max 2: the stream starts, the tap is acknowledged, and it ends at once',
      () async {
    final r = _Rig(max: 2);
    await r.session.start(_tap());
    await r.settle();
    expect(r.began, 1);
    expect(r.buzzes.map((b) => b.$1), [2]);
    expect(r.results, [(2, null)]);
    expect(r.ended, 1);
    expect(r.session.active, isFalse);
  });

  test('a touch that holds counts, buzzes once and finishes at max', () async {
    final r = _Rig(max: 3);
    await r.session.start(_tap());
    await r.settle(); // ack buzz written: the window opens on the first packet
    r.session.onFrame(_packet(1000, contactFrom: 10));
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
    await r.settle();
    r.session.onFrame(_packet(1000, contactFrom: 10));
    await r.settle();
    expect(r.buzzes.map((b) => b.$2).toSet(), hasLength(r.buzzes.length));
  });

  test('no touch: the 2-tap count is confirmed from sample time', () async {
    final r = _Rig(max: 5);
    await r.session.start(_tap());
    await r.settle();
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
    r.session.onFrame(_packet(1000, n: 10)); // 90 ms of quiet, window open
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
}
