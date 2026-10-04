// EcgTapSession in fast mode (8AN C, hybrid), over fakes. Counting stays
// SAMPLE-timed (EcgTapCounter and its start/gap/confirm ms thresholds on the
// 10 ms ecgContactMask), so quick taps still work. Fast mode differs from
// accurate in four ways: PREPARE has no raw-save (see ecg_fast_prepare_test),
// no steady-stream readiness wait, no sensorSettle, and the band's presence bit
// vetoes sample contact packet by packet (EcgPresenceGate, pinned in
// ecg_presence_gate_test.dart).
//
// ASSUMED API (see support/fast_rig.dart for the session ctor additions):
//  * EcgTapSession(tapMode: ..., beginFastStream: ..., presenceFallbackPackets:
//    ...). Fast mode starts the stream through `beginFastStream` and never
//    calls `beginStream`; accurate mode never calls `beginFastStream`.
//  * Fast mode starts the counter at the FIRST live packet and its first touch
//    window opens at that packet's first sample (no settle, no readiness).
//  * Each packet's ecgContactMask goes through EcgPresenceGate.filter with the
//    packet's presence bit before EcgTapCounter sees it (the existing
//    first-to-last fill of a packet's contact applies to the FILTERED mask).
//  * While gate.holdsFirstWindow, the first touch window does not close (so the
//    default 300 ms window cannot end the gesture on packets the veto hides,
//    and the default fallback of 4 packets is reachable).
//  * Fallback (gate.fellBack): trace line containing 'Presence fallback', no
//    new start, EcgGestureRecord.fellBackToSamples true.
//  * Trace (8AN A): 'Presence on|off, N ms after the tap.' and
//    'Sample contact on|off, N ms after the tap.' as in
//    ecg_fast_measure_test.dart; "Sample contact" is the packet's RAW mask
//    (before the veto), so a vetoed packet still shows it. A step starting
//    'Fast mode' is logged when a fast gesture starts.
//
// Packet geometry: a packet is 100 samples at 10 ms; `from`/`to` are sample
// indexes of the moving trace. Contact 5..25 reads as a 200 ms touch (the mask
// widens it to whole 50 ms blocks, 5..29), long enough for the 200 ms gap
// threshold to engage; 5..15 is a 100 ms blip that must not count.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_presence_gate.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_mode.dart';

import 'support/fast_rig.dart';

EcgTapThresholds get _wide => EcgTapThresholds(startMs: 1100);

int _fallbackLines(FastRig r) =>
    r.steps.where((s) => s.contains('Presence fallback')).length;

void main() {
  group('the fast start', () {
    test('starts the stream through the fast entry only', () async {
      final r = FastRig();
      await r.begin();
      expect(r.beganFast, 1);
      expect(r.beganAccurate, 0);
      expect(r.steps.any((s) => s.startsWith('Fast mode')), isTrue,
          reason: r.steps.join('\n'));
    });

    test('accurate mode never touches the fast entry', () async {
      final r = FastRig(mode: EcgTapMode.accurate);
      await r.begin();
      expect(r.beganAccurate, 1);
      expect(r.beganFast, 0);
    });

    test('no settle wait: a touch inside the very first packet is counted '
        'at once', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      expect(r.cues, ['start']);
      await r.feed(1000, presence: true, from: 5, to: 25);
      expect(r.cues, ['start', 'follow'],
          reason: 'accurate mode would still be settling for 2.5 s');
      expect(r.session.active, isTrue);
    });

    test('no steady-stream wait: ONE packet is enough to decide', () async {
      final r = FastRig(max: 3, th: _wide);
      await r.begin();
      await r.feed(1000, presence: true, from: 5, to: 25);
      expect(r.results, [(3, null)]);
      expect(r.cues, ['start', 'follow', 'confirm']);
    });

    test('a touch in the second packet still counts inside a wide first '
        'window', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000, presence: true);
      expect(r.cues, ['start']);
      expect(r.results, isEmpty, reason: 'the first window is still open');
      await r.feed(1001, presence: true, from: 5, to: 25);
      expect(r.cues, ['start', 'follow']);
    });

    test('with no touch in the first window the gesture is a plain double '
        'tap', () async {
      final r = FastRig();
      await r.begin();
      await r.feed(1000, presence: true);
      expect(r.results, [(2, null)]);
      expect(r.cues, ['start', 'confirm']);
      expect(r.ended, 1);
    });
  });

  group('sample-timed counting with the presence veto', () {
    test('a 200 ms tap inside a presence-true packet counts', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000, presence: true, from: 5, to: 25);
      expect(r.cues, ['start', 'follow']);
    });

    test('a 100 ms blip in a presence-true packet does not count (the ms '
        'thresholds still decide, not whole packets)', () async {
      final r = FastRig(th: _wide, max: 3);
      await r.begin();
      await r.feed(1000, presence: true, from: 5, to: 15);
      await r.feed(1001, presence: true);
      expect(r.cues, isNot(contains('follow')));
      expect(r.results, [(2, null)]);
    });

    test('the same 200 ms tap in a presence-false packet does not count '
        '(before the fallback)', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000, presence: false, from: 5, to: 25);
      expect(r.cues, ['start']);
      expect(r.results, isEmpty,
          reason: 'vetoed contact must not close the first window either');
      expect(_fallbackLines(r), 0);
    });

    test('a vetoed packet does not hide a real touch in the next one',
        () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000, presence: false, from: 5, to: 25); // noise
      await r.feed(1001, presence: true, from: 5, to: 25); // the touch
      expect(r.cues, ['start', 'follow']);
    });

    test('presence says yes but the samples say no: not a touch', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000, presence: true);
      await r.feed(1001, presence: true);
      expect(r.cues, isNot(contains('follow')));
      expect(r.results, [(2, null)]);
    });

    test('once presence has been seen, a later presence-false contact never '
        'counts', () async {
      final r = FastRig(th: _wide, fallbackPackets: 2);
      await r.begin();
      await r.feed(1000, presence: true); // presence works
      await r.feed(1001, presence: false, from: 5, to: 25);
      expect(r.cues, isNot(contains('follow')));
      expect(_fallbackLines(r), 0);
    });
  });

  group('the trace (8AN A, fast mode)', () {
    test('presence and sample-contact transitions carry the ms since the tap',
        () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000);
      await r.feed(1001, presence: true, from: 5, to: 25);
      final lines = r.steps.where((s) =>
          RegExp(r'^(Presence|Sample contact) (on|off), \d+ ms after the tap')
              .hasMatch(s));
      expect(lines.map((s) => s.split(' ms').first), [
        'Presence on, 3500',
        'Sample contact on, 3500',
      ], reason: r.steps.join('\n'));
    });

    test('contact the veto removed is still logged: the measurement needs '
        'the raw samples', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000, presence: false, from: 5, to: 25);
      expect(r.steps.where((s) => s.startsWith('Sample contact on, 2500')),
          hasLength(1),
          reason: r.steps.join('\n'));
      expect(r.steps.where((s) => s.startsWith('Presence on')), isEmpty);
    });
  });

  group('every exit stops the stream once', () {
    test('counted: the stream is stopped and the interval written', () async {
      final r = FastRig(max: 3, th: _wide);
      await r.begin();
      await r.feed(1000, presence: true, from: 5, to: 25);
      expect(r.ended, 1);
      expect(r.records, hasLength(1));
      expect(r.records.single.finalCount, 3);
      expect(r.records.single.fellBackToSamples, isFalse);
      expect(r.session.active, isFalse);
    });

    test('abandoned on a lost link', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000, presence: true);
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
      expect(r.results.single.$2, contains('link_lost'));
      expect(r.records, hasLength(1));
    });

    test('abandoned on a stall', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000, presence: true);
      r.now = r.now.add(const Duration(seconds: 10));
      r.session.poll();
      await r.settle();
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
      expect(r.results.single.$2, contains('stalled'));
    });

    test('a throwing result listener still stops the stream and frees the '
        'session', () async {
      final r = FastRig(max: 3, th: _wide, throwOnFinish: true);
      await r.begin();
      await r.feed(1000, presence: true, from: 5, to: 25);
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
      await r.begin(); // and the next gesture can run
      expect(r.session.active, isTrue);
    });

    test('a fast start that never answers is stopped and the gesture ends',
        () async {
      final r = FastRig(
        beginTimeout: const Duration(milliseconds: 20),
        beginFast: () => Completer<bool>().future,
      );
      await r.begin();
      await r.settle();
      expect(r.session.active, isFalse);
      expect(r.ended, greaterThanOrEqualTo(1),
          reason: 'a late-starting stream is stopped');
      expect(r.beganFast, 2, reason: 'the start is retried once (8AK)');
      expect(r.beganAccurate, 0, reason: 'the retry stays on the fast entry');
      expect(r.results.single.$1, 2, reason: 'double-tap fallback');
    });

    test('a refused fast start is retried once, then ends', () async {
      final r = FastRig(beginFast: () async => false);
      await r.begin();
      await r.settle();
      expect(r.beganFast, 2);
      expect(r.beganAccurate, 0);
      expect(r.session.active, isFalse);
      expect(r.results, hasLength(1));
    });

    test('a session is reusable after every exit (no sticky flag, and a '
        'fresh gate: no fallback or presence carried over)', () async {
      final r = FastRig(max: 3, th: _wide, fallbackPackets: 2);
      await r.begin();
      await r.feed(1000, presence: true, from: 5, to: 25);
      expect(r.session.active, isFalse);
      await r.begin();
      expect(r.session.active, isTrue);
      // A presence-false touch is vetoed again: the first gesture's
      // everPresent must not leak.
      await r.feed(1000, presence: false, from: 5, to: 25);
      expect(r.cues.where((c) => c == 'follow'), hasLength(1));
      expect(r.results, [(3, null)]);
    });
  });

  group('fallback when the band never reports presence', () {
    test('N packets of sample contact with presence never set lift the veto, '
        'without a new start', () async {
      final r = FastRig(fallbackPackets: 2, th: _wide);
      await r.begin();
      await r.feed(1000, presence: false, from: 5, to: 25);
      expect(_fallbackLines(r), 0, reason: 'one packet is not enough');
      await r.feed(1001, presence: false, from: 5, to: 25);
      expect(_fallbackLines(r), 1, reason: r.steps.join('\n'));
      expect(r.beganFast, 1);
      expect(r.beganAccurate, 0, reason: 'no new PREPARE/START');
      expect(r.ended, 0);
    });

    test('with the DEFAULT N and thresholds the fallback is reachable: the '
        'one-packet-wide first window does not close on vetoed contact',
        () async {
      final r = FastRig();
      await r.begin();
      for (var i = 0; i < kEcgPresenceFallbackPackets; i++) {
        expect(r.results, isEmpty, reason: 'packet $i');
        await r.feed(1000 + i, presence: false, from: 5, to: 25);
      }
      expect(_fallbackLines(r), 1, reason: r.steps.join('\n'));
      expect(r.results, isEmpty);
    });

    test('after the fallback the same packet counts: a touch the veto hid '
        'is now a touch, and the record says the gesture fell back', () async {
      final r = FastRig(
        fallbackPackets: 2,
        th: _wide,
        bandQueue: false,
      );
      await r.begin();
      await r.feed(1000, presence: false, from: 5, to: 25); // vetoed
      expect(r.cues, ['start']);
      await r.feed(1001, presence: false, from: 5, to: 25); // triggers
      expect(r.cues, ['start', 'follow'], reason: r.steps.join('\n'));
      for (var i = 0; i < 4 && r.results.isEmpty; i++) {
        await r.feed(1002 + i); // finger lifted
      }
      expect(r.results, [(3, null)], reason: r.steps.join('\n'));
      expect(r.cues, ['start', 'follow', 'confirm']);
      expect(r.records.single.fellBackToSamples, isTrue);
      expect(r.beganFast, 1);
      expect(r.beganAccurate, 0);
      expect(r.ended, 1);
    });

    test('contact that is interrupted does not add up: the packets must be '
        'consecutive', () async {
      final r = FastRig(fallbackPackets: 3, th: _wide);
      await r.begin();
      await r.feed(1000, presence: false, from: 5, to: 25);
      await r.feed(1001, presence: false, from: 5, to: 25);
      await r.feed(1002); // a packet without contact resets the run
      expect(_fallbackLines(r), 0);
    });

    test('once presence has been seen the fallback is off for the gesture',
        () async {
      final r = FastRig(fallbackPackets: 2, th: _wide);
      await r.begin();
      await r.feed(1000, presence: true, from: 5, to: 25); // a real touch
      await r.feed(1001, presence: false, from: 5, to: 25);
      await r.feed(1002, presence: false, from: 5, to: 25);
      await r.feed(1003, presence: false, from: 5, to: 25);
      expect(_fallbackLines(r), 0);
    });

    test('a gesture that never fell back records fellBackToSamples false',
        () async {
      final r = FastRig(max: 3, th: _wide);
      await r.begin();
      await r.feed(1000, presence: true, from: 5, to: 25);
      expect(r.records.single.fellBackToSamples, isFalse);
    });
  });
}
