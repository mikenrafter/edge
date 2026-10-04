// EcgTapSession.stop() (the owner is going away) in the states the plain
// "gesture in flight" case does not cover: the lab post-roll after a counted
// gesture (no longer active, but the stream is still on and a stop is in
// flight), and a start that is waiting on that stop.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 4, 8);

StrapEvent _tap() => StrapEvent(
      eventId: 14,
      tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000,
      receivedAt: _t0.add(const Duration(milliseconds: 300)),
      hex: '',
      deviceId: 'band',
    );

LabradorR17 _packet(int sec) => LabradorR17(
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
      samples: Int16List(100),
      tail: Uint8List(0),
      inner: Uint8List(0),
    );

class _Rig {
  _Rig() {
    session = EcgTapSession(
      beginStream: () async {
        began++;
        return true;
      },
      endStream: () async {
        ended++;
        await endGate?.future;
      },
      isStreamAlive: () => true,
      buzz: (_, _) async => true,
      maxTaps: () => 3,
      thresholds: EcgTapThresholds.new,
      onFinished: (c, r) => results.add((c, r)),
      recordSession: (r) async => records.add(r),
      now: () => now,
      // The lab's 3 s post-roll wait: never ends on its own here.
      wait: (_) => postRollWait.future,
      postRoll: () => const Duration(seconds: 3),
      pollEvery: const Duration(hours: 1),
    );
  }

  late final EcgTapSession session;
  final postRollWait = Completer<void>();
  Completer<void>? endGate;
  DateTime now = _t0;
  int began = 0, ended = 0;
  final results = <(int?, String?)>[];
  final records = <EcgGestureRecord>[];

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Start a gesture and drive it to a final count of 2: the session is then
  /// inactive and waiting out the post-roll with the stream on.
  Future<void> countedAndPostRolling() async {
    await session.start(_tap());
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_packet(1000));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_packet(1001));
    now = _t0.add(const Duration(seconds: 2));
    session.onFrame(_packet(1002)); // no touch: ends at 2
    await settle();
    expect(results, [(2, null)]);
    expect(session.active, isFalse);
    expect(ended, 0, reason: 'the stream is still on during the post-roll');
  }
}

void main() {
  test('stop during the post-roll stops the stream now, awaited, once',
      () async {
    final r = _Rig();
    await r.countedAndPostRolling();
    await r.session.stop();
    expect(r.ended, 1, reason: 'stopped without waiting out the 3 s');
    expect(r.records, hasLength(1), reason: 'the interval is still written');
    r.postRollWait.complete(); // the wait that was cut ends later
    await r.settle();
    expect(r.ended, 1, reason: 'the late wait does not stop it a second time');
  });

  test('stop while a stop is already running waits for that stop', () async {
    final r = _Rig();
    r.endGate = Completer<void>();
    await r.countedAndPostRolling();
    r.postRollWait.complete(); // the post-roll ends: the stop is now running
    await r.settle();
    expect(r.ended, 1);
    var done = false;
    final stopping = r.session.stop().then((_) => done = true);
    await r.settle();
    expect(done, isFalse, reason: 'the stream stop has not answered yet');
    r.endGate!.complete();
    await stopping;
    expect(r.ended, 1, reason: 'one stop, not two');
  });

  test('a start waiting on the stop in flight begins nothing once the owner '
      'has stopped', () async {
    final r = _Rig();
    await r.countedAndPostRolling();
    final waiting = r.session.start(_tap());
    await r.settle();
    expect(r.began, 1, reason: 'the new start waits behind the stop');
    await r.session.stop();
    await waiting.timeout(const Duration(seconds: 2));
    expect(r.began, 1, reason: 'no second stream after stop()');
    expect(r.session.active, isFalse);
  });

  test('stop with nothing running does nothing', () async {
    final r = _Rig();
    await r.session.stop();
    expect(r.ended, 0);
    expect(r.records, isEmpty);
  });
}
