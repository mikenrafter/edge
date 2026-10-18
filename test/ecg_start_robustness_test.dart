// Making the ECG connection as robust as possible.
//
// The log (see a_log_replay_test.dart) shows the stream START being refused
// in four of five gestures. This file pins the robustness rules the session
// and the readiness detector get:
//
//  1. RETRY (EcgTapSession): a start that is refused, throws or times out is
//     retried ONCE, inside the same gesture, before the double-tap fallback,
//     also with the fallback on. Bounded (two attempts in all). A start that
//     timed out stops the late stream BEFORE the retry starts (so the retry
//     never meets its own first attempt). The start cue is not repeated.
//     Only the stream START is retried: a failure after the stream was up
//     (link_lost, stalled, ...) keeps today's rules (fallback: no retry).
//     The session still only calls its injected begin/end: no opcode, and in
//     particular no dangerous one (force-trim, reboot, power-cycle, firmware
//     load; invariant 15), is ever sent by the retry.
//  2. NO FLAG LEFT SET (invariant 4.3): after a gesture that failed twice,
//     after one whose retry threw, and after a retried one that then
//     counted, `active` is false and the next tap starts a gesture.
//  3. STEADY DETECTION TOLERATES THE FIRST NOISY PACKETS
//     (EcgStreamReadiness.offer in lib/gestures/ecg_stream_readiness.dart):
//     the log's stream opened with two packets of 0 samples and then the
//     short 49-sample one. A packet with no samples carries no sample clock
//     to be contiguous with, but it does arrive in step with the wall clock;
//     the first SAMPLED packet that arrives in step with a run of AT LEAST
//     TWO such empty packets (within [pairWindow] of the last, advancing in
//     step with the wall clock within [stepTolerance]) makes the stream
//     steady, instead of waiting for a second sampled packet. One empty
//     packet is not a run (the quick start's rule, pinned by
//     test/ecg_tap_session_contact_test.dart, stands: the first
//     sampled packet after ONE empty one is not yet "steady"). Never from
//     empty packets alone, never from a burst (a second of strap time
//     delivered in tens of milliseconds).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_stream_readiness.dart';

import 'support/dart_source_lexical.dart';
import 'support/ecg_tap_session_failure_rig.dart';

void main() {
  group('retry of the stream start (fallback on, the default)', () {
    test('refused once, accepted the second time: the gesture carries on to '
        'a count of 5', () async {
      final r = AkEcgRig(max: 5, begins: const [false, true]);
      await r.tap();
      expect(r.began, 2);
      await r.steady();
      await r.touchThree();
      await r.touchFour();
      await r.touchFive();
      expect(r.results, [(5, null)]);
      expect(r.names,
          ['start', 'follow', 'follow', 'follow', 'confirm'],
          reason: 'no failure cue, and the start cue was not repeated');
    });

    test('the retry does not repeat the start cue', () async {
      final r = AkEcgRig(max: 5, begins: const [false, true]);
      await r.tap();
      expect(r.names.where((n) => n == 'start'), hasLength(1));
      expect(r.steps, contains(contains('trying the ECG once more')));
    });

    test('a start that throws once is retried the same way', () async {
      final r = AkEcgRig(max: 5, begins: [StateError('radio'), true]);
      await r.tap();
      expect(r.began, 2);
      expect(r.session.active, isTrue);
      expect(r.results, isEmpty);
    });

    test('a start that times out: the late stream is stopped BEFORE the '
        'retry starts', () async {
      final r = AkEcgRig(max: 5, begins: [Completer<bool>(), true]);
      await r.tap();
      expect(r.log.where((l) => l == 'begin' || l == 'end'),
          ['begin', 'end', 'begin']);
      expect(r.session.active, isTrue);
    });

    test('refused twice: exactly two attempts, then the fallback with ONE '
        'failure cue', () async {
      final r = AkEcgRig(max: 5, begins: const [false, false]);
      await r.tap();
      expect(r.began, 2);
      expect(r.results, [(2, 'fallback: start_failed')]);
      expect(r.names, ['start', 'fail']);
      expect(r.session.active, isFalse);
    });

    test('never more than two attempts, whatever the stream does', () async {
      final r = AkEcgRig(max: 5, begins: [
        false,
        StateError('again'),
        true,
        true,
      ]);
      await r.tap();
      expect(r.began, 2);
      expect(r.session.active, isFalse);
    });

    test('a retried gesture that then counts leaves nothing set: the next '
        'tap starts a gesture', () async {
      final r = AkEcgRig(max: 3, begins: const [false, true, true]);
      await r.tap();
      await r.steady();
      await r.touchThree();
      expect(r.results, [(3, null)]);
      expect(r.session.active, isFalse);
      await r.session.start(akDoubleTap(sec: 20));
      expect(r.session.active, isTrue);
    });

    test('regression guard: a failure after the stream was up '
        'is not retried with the fallback on', () async {
      final r = AkEcgRig(max: 5);
      await r.tap();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.began, 1);
      expect(r.results, [(2, 'fallback: link_lost')]);
      expect(r.session.active, isFalse);
    });

    test('regression guard: a failure after a touch was '
        'counted is abandoned, never retried', () async {
      final r = AkEcgRig(max: 5);
      await r.tap();
      await r.steady();
      await r.touchThree();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.began, 1);
      expect(r.results, [(null, 'link_lost')]);
    });
  });

  group('the retry sends no command of its own', () {
    test('regression guard: the session names no opcode, so '
        'no dangerous one can be sent from it', () {
      final src = codeOnly(
          File('lib/gestures/ecg_tap_session.dart').readAsStringSync());
      expect(src, isNot(contains('Cmd.')));
      for (final bad in const [
        'forceTrim',
        'reboot',
        'powerCycle',
        'firmwareLoad',
        'dangerousCmds',
      ]) {
        expect(src, isNot(contains(bad)), reason: bad);
      }
    });
  });

  group('steady-stream detection tolerates the first noisy packets', () {
    // The log's first packets (ms after the tap, strap time of the newest
    // sample, samples): 2838 / ...225.480 / 0, 3366 / ...226.480 / 0,
    // 4377 / ...227.490 / 49, 5378 / ...228.490 / 100.
    final t0 = DateTime.utc(2026, 10, 4, 2, 7, 4, 700);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('two empty packets in step, then the short sampled one: steady on '
        'that one (packet 3), not a packet later', () {
      final r = EcgStreamReadiness();
      expect(r.offer(at: at(2838), strapTime: 1791101225.480, sampleCount: 0),
          isFalse);
      expect(r.offer(at: at(3366), strapTime: 1791101226.480, sampleCount: 0),
          isFalse);
      expect(r.offer(at: at(4377), strapTime: 1791101227.490, sampleCount: 49),
          isTrue);
      expect(r.ready, isTrue);
    });

    test('regression guard: ONE empty packet then the sampled '
        'one is not steady yet (what the quick start relies on)', () {
      final r = EcgStreamReadiness();
      expect(r.offer(at: at(0), strapTime: 1790990000.0, sampleCount: 0),
          isFalse);
      expect(r.offer(at: at(1010), strapTime: 1790990001.01, sampleCount: 49),
          isFalse);
    });

    test('regression guard: the log\'s packet 4 completes it '
        'for sure', () {
      final r = EcgStreamReadiness();
      r.offer(at: at(2838), strapTime: 1791101225.480, sampleCount: 0);
      r.offer(at: at(3366), strapTime: 1791101226.480, sampleCount: 0);
      r.offer(at: at(4377), strapTime: 1791101227.490, sampleCount: 49);
      expect(r.offer(at: at(5378), strapTime: 1791101228.490, sampleCount: 100),
          isTrue);
    });

    test('regression guard: two contiguous sampled packets a '
        'second apart are steady, as before', () {
      final r = EcgStreamReadiness();
      expect(r.offer(at: at(0), strapTime: 1000.0), isFalse);
      expect(r.offer(at: at(1000), strapTime: 1001.0), isTrue);
    });

    test('regression guard: empty packets alone are never '
        'steady', () {
      final r = EcgStreamReadiness();
      for (var i = 0; i < 6; i++) {
        expect(
            r.offer(at: at(i * 1000), strapTime: 1000.0 + i, sampleCount: 0),
            isFalse,
            reason: 'packet ${i + 1}');
      }
    });

    test('regression guard: a burst is not steady, empty '
        'packets or not (a second of strap time in tens of ms)', () {
      final r = EcgStreamReadiness();
      expect(r.offer(at: at(0), strapTime: 100.0, sampleCount: 0), isFalse);
      expect(r.offer(at: at(20), strapTime: 101.0, sampleCount: 0), isFalse);
      expect(r.offer(at: at(40), strapTime: 102.0, sampleCount: 49), isFalse);
    });

    test('regression guard: the sampled packet must still '
        'arrive within the pair window of the empty one', () {
      final r = EcgStreamReadiness();
      expect(r.offer(at: at(0), strapTime: 1000.0, sampleCount: 0), isFalse);
      expect(r.offer(at: at(5000), strapTime: 1005.0, sampleCount: 49), isFalse,
          reason: 'five seconds apart is not a flowing stream');
    });
  });
}
