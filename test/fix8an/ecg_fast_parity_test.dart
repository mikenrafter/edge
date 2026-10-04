// Parity with 8AK (8AN C, hybrid): a synthetic presence trace for each count
// 2..5 must give the cue sequence the accurate path gives: [start, follow x
// (n - 2), confirm], and the count n. Touches are whole packets of moving
// samples with presence set (r17 flags 0x08, test/support/ecg_trace.dart), one
// packet a second, and the band queue is played by the test: a follow-up cue
// plays between the lift and the next touch, so the next touch counts only
// after it (8AK, "ECG timings start off the follow-up haptics").
//
// ASSUMED API: see support/fast_rig.dart, ecg_fast_session_test.dart and
// ecg_presence_gate_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_mode.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';

import '../support/ecg_trace.dart';
import 'support/fast_rig.dart';
import 'support/presence_packets.dart';

void main() {
  for (var n = 2; n <= 5; n++) {
    test('count $n: [start, follow x ${n - 2}, confirm], decided $n', () async {
      final r = FastRig();
      await r.begin();
      await r.playCount(n);
      expect(r.cues, [
        'start',
        for (var i = 0; i < n - 2; i++) 'follow',
        'confirm',
      ], reason: r.steps.join('\n'));
      expect(r.results, [(n, null)], reason: r.steps.join('\n'));
      expect(r.ended, 1);
      expect(r.beganFast, 1);
      expect(r.beganAccurate, 0);
    });
  }

  test('packets that went through the lab export and back give the same '
      'cues', () async {
    final sent = [
      presencePacket(1000, presence: true, contactFrom: 5, contactTo: 25),
    ];
    final text = labLogText(
      entries: const [],
      steps: const [],
      sessions: const [],
      packets: [
        for (final p in sent) LabPacket.of(p, t0, 'tap 08:00:00.300'),
      ],
      at: t0,
    );
    final back = Trace.parse(text).packets;
    expect(back.single.r.presence, isTrue);
    final r = FastRig(max: 3);
    await r.begin();
    r.now = t0.add(const Duration(milliseconds: 2800));
    r.session.onFrame(back.single.r);
    await r.settle();
    expect(r.cues, ['start', 'follow', 'confirm']);
    expect(r.results, [(3, null)]);
  });

  test('a touch before the follow-up cue has played is not counted', () async {
    final r = FastRig();
    await r.begin();
    await r.feed(1000, presence: true, contact: true); // count 3, cue playing
    await r.feed(1001); // lift
    await r.feed(1002, presence: true, contact: true); // cue still playing
    await r.feed(1003); // lift again
    expect(r.cues, ['start', 'follow'], reason: 'no second follow-up');
    expect(r.results, isEmpty, reason: 'held: no window runs');
    await r.cuePlayed();
    for (var i = 0; i < 4 && r.results.isEmpty; i++) {
      await r.feed(1004 + i);
    }
    expect(r.cues, ['start', 'follow', 'confirm']);
    expect(r.results, [(3, null)]);
  });

  test('accurate mode is unchanged: it still waits for the sensor to settle',
      () async {
    final r = FastRig(mode: EcgTapMode.accurate, bandQueue: false);
    await r.begin();
    await r.feed(1000, presence: true, from: 5, to: 25);
    expect(r.cues, ['start'], reason: 'no touch counted this early');
    expect(r.beganAccurate, 1);
    expect(r.beganFast, 0);
  });
}
