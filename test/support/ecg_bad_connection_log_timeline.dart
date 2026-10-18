// The sequence of the 2026-10-04 device lab log (edge.research/
// ecg-bad-connection-2026-10-04.log), synthesised from its timestamps and
// events. No raw packet data is copied: each packet is rebuilt from the
// numbers the log's own trace lines print (when the phone got it, the strap
// time of its newest sample, how many samples, where its contact sits) as a
// +120/-120 alternation over the contact run and zeros elsewhere.
//
// What the log shows (the report has the full analysis):
//   * Five ECG gestures (settings: start 200 ms, gap 150 ms, confirm 750 ms,
//     extra sensitive, fallback on). FOUR of them ended "ECG failed
//     (start_failed)": the stream start was refused ("prepare answered
//     (refused)" about 5.1 s after the guard was set, i.e. one PREPARE command
//     not answered within the engine's 5 s timeout), the fallback made it a
//     count of 2 and the failure buzz played 6.1 to 6.6 s after the tap. No
//     packet ever arrived in those four: the "hand not on the sensor yet"
//     suspect does not explain them.
//   * The fifth (tap at 02:07:04.700) started: prepare accepted, start
//     answered, then 15 packets, steady on packet 4 (5378 ms after the tap),
//     first window open at sample time ...229499, three follow-ups and the
//     confirm, final count 5 at 16.4 s.

import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'ecg_trace.dart' show r17;
import 'ecg_tap_session_failure_rig.dart';

/// The log's thresholds line.
EcgTapThresholds logThresholds() => EcgTapThresholds(
      startMs: 200,
      gapMs: 150,
      confirmMs: 750,
      extraSensitive: true,
    );

/// One packet of the good run: when the phone got it (ms after the tap), the
/// strap time of its newest sample, its sample count and its contact run
/// (from, to exclusive; null: no contact).
class LogPacket {
  const LogPacket(this.afterTapMs, this.sec, this.sub, this.n, [this.contact]);
  final int afterTapMs, sec, sub, n;
  final (int, int)? contact;

  LabradorR17 build() {
    final c = contact;
    return r17(
      strapSeconds: sec,
      subseconds: sub,
      sequence: sec,
      flags: n == 0 ? 0 : 0x0a,
      s2State: 1,
      quality: n == 0 ? 0 : 1,
      samples: [
        for (var i = 0; i < n; i++)
          c != null && i >= c.$1 && i < c.$2 ? (i.isEven ? 120 : -120) : 0,
      ],
    );
  }
}

/// Packets 1 to 15 of the 02:07:04 gesture. Packets 1 and 2 carry no samples,
/// packet 3 is the short 49-sample one, the rest are 100 samples a second.
const List<LogPacket> kGoodRun = [
  LogPacket(2838, 1791101225, 15728, 0),
  LogPacket(3366, 1791101226, 15728, 0),
  LogPacket(4377, 1791101227, 16056, 49, (35, 49)),
  LogPacket(5378, 1791101228, 16056, 100),
  LogPacket(6380, 1791101229, 16056, 100, (85, 100)),
  LogPacket(7386, 1791101230, 16056, 100, (0, 100)),
  LogPacket(8376, 1791101231, 16056, 100, (0, 100)),
  LogPacket(9380, 1791101232, 16056, 100, (0, 100)),
  LogPacket(10386, 1791101233, 16056, 100, (0, 35)),
  LogPacket(11394, 1791101234, 16056, 100),
  LogPacket(12380, 1791101235, 16056, 100, (35, 100)),
  LogPacket(13384, 1791101236, 16056, 100, (0, 100)),
  LogPacket(14375, 1791101237, 16056, 100, (0, 55)),
  LogPacket(15380, 1791101238, 16056, 100),
  LogPacket(16400, 1791101239, 16056, 100, (45, 100)),
];

/// The tap that opened the good run: the phone's receipt time is the log's
/// reference ("tap +0 ms").
StrapEvent logTap() => StrapEvent(
      eventId: 14,
      tsEpoch: kAkT0.millisecondsSinceEpoch ~/ 1000,
      receivedAt: kAkT0,
      hex: '',
      deviceId: 'band',
    );

/// Feed the packets of [kGoodRun] (all of them, or the first [count]) to the
/// rig's session on the log's own clock.
Future<void> feedGoodRun(AkEcgRig rig, {int? count}) async {
  for (final p in kGoodRun.take(count ?? kGoodRun.length)) {
    rig.now = kAkT0.add(Duration(milliseconds: p.afterTapMs));
    rig.session.onFrame(p.build());
    await rig.settle();
  }
}

/// A rig on the log's settings. The session keeps its production timings
/// (settle 2.5 s, re-acquire 1.5 s, 3 s stall).
AkEcgRig logRig({
  List<Object> begins = const [true],
  bool reportFailures = false,
}) =>
    AkEcgRig(
      max: 5,
      begins: begins,
      thresholds: logThresholds(),
      reacquire: const Duration(milliseconds: 1500),
      reportFailures: reportFailures,
    );

/// The record the session writes for a finished gesture (re-exported so the
/// tests need no second import).
typedef LogRecord = EcgGestureRecord;
