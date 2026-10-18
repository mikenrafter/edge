// The gesture session plays an ADDITIVE sequence of cues:
//
//   start (once, at the tap) . follow-up per increment (3, 4, 5) . confirm
//
// Never a recount, never the start cue again, never an N-pulse call. Each cue
// is its own call, requested as soon as it is decided: the session adds no
// quiet wait of its own (the band queue spaces jobs by the vocabulary's
// minimum gap), and a cue that could not be written never swallows the
// ones after it.
//
// ASSUMED API (lib/gestures/ecg_tap_session.dart, EcgTapSession):
//   * `buzz(int pulses, String eventId)` is the FOLLOW-UP cue; pulses is
//     always 1 (one follow-up per increment).
//   * New optional `Future<bool> Function(String eventId)? confirmBuzz`: the
//     confirm cue, called once when the gesture ends counted, after any
//     follow-up it closes, ids `<gesture id>:ecg:confirm`. Null: no confirm.
//   * `maxPulsesPerBurst`, `pulsesPerBurst` and `buzzQuietGap` are gone.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 3, 8);

/// A 100-sample packet ending at strap second [sec]; each (from, to) pair is a
/// run of moving samples (contact), sample i being at sec - 1 + i / 100.
LabradorR17 _packet(int sec, [List<(int, int)> contact = const []]) =>
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
          contact.any((c) => i >= c.$1 && i < c.$2)
              ? (i.isEven ? 120 : -120)
              : 0,
      ]),
      tail: Uint8List(0),
      inner: Uint8List(0),
    );

class _Rig {
  _Rig({
    int max = 5,
    this.followOk = true,
    this.failBuzzOn = false,
    this.followGate,
  }) {
    session = EcgTapSession(
      beginStream: () async => true,
      endStream: () async {},
      isStreamAlive: () => true,
      startBuzz: (id) async {
        cues.add(('start', id));
        return true;
      },
      buzz: (pulses, id) async {
        pulseArgs.add(pulses);
        cues.add(('follow', id));
        if (followGate != null && cues.where((c) => c.$1 == 'follow').length == 1) {
          return followGate!.future;
        }
        return followOk;
      },
      confirmBuzz: (id) async {
        cues.add(('confirm', id));
        return true;
      },
      failBuzz: failBuzzOn
          ? (id) async {
              cues.add(('fail', id));
              return true;
            }
          : null,
      maxTaps: () => max,
      thresholds: EcgTapThresholds.new,
      onFinished: (c, r) => results.add((c, r)),
      step: steps.add,
      now: () => now,
      wait: (d) async => waits.add(d),
      pollEvery: const Duration(hours: 1),
      sensorReacquire: Duration.zero,
    );
  }

  late final EcgTapSession session;
  final bool followOk, failBuzzOn;
  final Completer<bool>? followGate;
  DateTime now = _t0;
  final cues = <(String, String)>[];
  final pulseArgs = <int>[];
  final results = <(int?, String?)>[];
  final waits = <Duration>[];
  final steps = <String>[];

  List<String> get names => [for (final c in cues) c.$1];

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> frame(int sec, [List<(int, int)> contact = const []]) async {
    now = _t0.add(Duration(milliseconds: 500 + (sec - 1000) * 1000));
    session.onFrame(_packet(sec, contact));
    await settle();
  }

  Future<void> tap() => session.start(StrapEvent(
        eventId: 14,
        tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000,
        receivedAt: _t0.add(const Duration(milliseconds: 300)),
        hex: '',
        deviceId: 'band',
      ));

  /// Two quiet packets: steady, and the first window opens at sample time
  /// 1001.5.
  Future<void> steady() async {
    await frame(1000);
    await frame(1001);
  }

  // The contact mask fills a packet from its first to its last contact sample,
  // so a lift only shows at a packet's edge: each touch is one run reaching
  // the end of its packet, and the next starts 250 ms into the next packet,
  // inside the window that opens 200 ms after the lift.

  /// Touch 3 from 1001.6 (engages 1001.8), lifted at 1002.0.
  Future<void> touchThree() => frame(1002, [(60, 100)]);

  /// Touch 4 from 1002.25 (engages 1002.45), lifted at 1003.0.
  Future<void> touchFour() => frame(1003, [(25, 100)]);

  /// Touch 5 from 1003.25 (engages 1003.45): the max.
  Future<void> touchFive() => frame(1004, [(25, 100)]);
}

void main() {
  test('a gesture that goes to 5: start, follow-up, follow-up, follow-up, '
      'confirm', () async {
    final r = _Rig(max: 5);
    await r.tap();
    await r.steady();
    await r.touchThree();
    await r.touchFour();
    await r.touchFive();
    expect(r.results, [(5, null)]);
    expect(r.names, ['start', 'follow', 'follow', 'follow', 'confirm']);
  });

  test('every follow-up is one pulse, never a recount', () async {
    final r = _Rig(max: 5);
    await r.tap();
    await r.steady();
    await r.touchThree();
    await r.touchFour();
    await r.touchFive();
    expect(r.pulseArgs, [1, 1, 1]);
  });

  test('a follow-up is requested as soon as its increment is detected: '
      'the session waits for nothing', () async {
    final r = _Rig(max: 5);
    await r.tap();
    await r.steady();
    await r.frame(1002, [(60, 100)]); // 3 engages at 1001.8, inside this one
    expect(r.names, ['start', 'follow'],
        reason: 'the follow-up for 3 went out with the packet that showed it');
    expect(r.waits, isEmpty,
        reason: 'no quiet gap: the band queue spaces the jobs');
  });

  test('ending at 3 (a window runs out): start, follow-up, confirm', () async {
    final r = _Rig(max: 5);
    await r.tap();
    await r.steady();
    await r.touchThree();
    await r.frame(1003); // no touch: the window runs out
    expect(r.results, [(3, null)]);
    expect(r.names, ['start', 'follow', 'confirm']);
  });

  test('ending at 2 (no touch): start, then the confirm, no follow-up',
      () async {
    final r = _Rig(max: 5);
    await r.tap();
    await r.steady();
    await r.frame(1002);
    await r.frame(1003);
    expect(r.results, [(2, null)]);
    expect(r.names, ['start', 'confirm']);
  });

  test('max 2: start, confirm', () async {
    final r = _Rig(max: 2);
    await r.tap();
    await r.steady();
    expect(r.results, [(2, null)]);
    expect(r.names, ['start', 'confirm']);
  });

  test('the confirm comes after the follow-up it closes (max 3)', () async {
    final r = _Rig(max: 3);
    await r.tap();
    await r.steady();
    await r.frame(1002, [(60, 100)]);
    expect(r.results, [(3, null)]);
    expect(r.names, ['start', 'follow', 'confirm']);
  });

  test('every cue has its own event id, all of this gesture', () async {
    final r = _Rig(max: 5);
    await r.tap();
    await r.steady();
    await r.touchThree();
    await r.touchFour();
    await r.touchFive();
    final ids = [for (final c in r.cues) c.$2];
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.last, endsWith(':ecg:confirm'));
    expect(ids.first, endsWith(':ecg:start'));
  });

  test('a follow-up the band did not take does not drop the cues after it',
      () async {
    final r = _Rig(max: 5, followOk: false);
    await r.tap();
    await r.steady();
    await r.touchThree();
    await r.touchFour();
    await r.touchFive();
    expect(r.names, ['start', 'follow', 'follow', 'follow', 'confirm']);
  });

  test('cues are called in order even when an earlier one is still pending',
      () async {
    final gate = Completer<bool>();
    final r = _Rig(max: 3, followGate: gate);
    await r.tap();
    await r.steady();
    await r.frame(1002, [(60, 100)]); // 3 = max: follow-up, then confirm
    expect(r.results, [(3, null)]);
    expect(r.names, ['start', 'follow'],
        reason: 'the confirm waits behind the follow-up');
    gate.complete(true);
    await r.settle();
    expect(r.names, ['start', 'follow', 'confirm']);
  });

  test('an abandoned gesture plays no confirm', () async {
    final r = _Rig(max: 5, failBuzzOn: true);
    await r.tap();
    await r.steady();
    r.now = _t0.add(const Duration(minutes: 1));
    r.session.poll(); // the stream stalls
    await r.settle();
    expect(r.names, isNot(contains('confirm')));
    expect(r.names, isNot(contains('follow')));
  });
}
