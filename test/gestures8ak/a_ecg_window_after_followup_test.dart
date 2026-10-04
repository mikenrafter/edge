// 8AK A (red): the ECG touch windows open AFTER the follow-up cue has played.
//
// USER RULE: "ECG timings start off the FOLLOW-UP haptics, not the start
// haptics". The window that waits for the next touch (3 -> 4 -> 5) opens once
// the follow-up cue of the previous increment has been DELIVERED and its plan
// has ENDED (the band queue's completion, not the write), never from the
// moment the touch was seen. Until then the window is not open: it neither
// counts a touch nor runs out, so the wearer who is still feeling the
// follow-up is not counted out (the log shows a follow-up written 244 to 526
// ms after it was asked for, and a plan runs another second after that).
//
// The FIRST window (the one that waits for the first touch after the double
// tap) is NOT anchored to the start cue: it keeps opening off the steady
// stream and the sensor settle, and a start cue that hangs never holds it
// (8AI: the start cue is never waited for). Only the windows after a
// follow-up wait for a cue.
//
// ASSUMED API (lib/gestures/ecg_tap_session.dart, EcgTapSession):
//   * New optional `Future<void> Function()? bandIdle` (see
//     support/ak_ecg_rig.dart): completes when the band has finished playing
//     everything queued so far. The session awaits it after a follow-up cue
//     was requested (and written, or refused: a cue that could not be written
//     does not hold the window), then opens the next window at the sample
//     time the idle moment maps to (the session's own sample clock, never
//     the phone clock raw): the window runs `confirm` from there, as every
//     window after a lift does today. Bounded by `buzzTimeout`: a plan that
//     never ends opens the window at the timeout.
//   * Unchanged: the counter's own rules (a touch must start inside an open
//     window; contact already there when the window opens counts).
//
// Rig timeline (support/ak_ecg_rig.dart): packet N covers [N-1, N) on the
// sample clock and reaches the phone at the end of its second, so "the band
// became idle after frame(N)" is sample time N.0. [steady] opens the first
// window at 1001.5. touchThree engages at 1001.8 and lifts at 1002.0.
//
// Failure mode today: no `bandIdle` is accepted (the rig drops it), so the
// next window opens at the lift as before: the gesture is ended after packet
// 1003 and a touch during the follow-up is counted.

import 'package:flutter_test/flutter_test.dart';

import 'support/ak_ecg_rig.dart';

void main() {
  group('the first window is not held by the start cue', () {
    test('regression guard (passes today): a start cue that never returns '
        'does not hold the first window', () async {
      final r = AkEcgRig(max: 5, useBandIdle: true, startHangs: true);
      await r.tap();
      await r.steady();
      expect(r.steps.where((s) => s.startsWith('Touch window open')), hasLength(1),
          reason: 'the first window opened off the stream, not off the cue');
      await r.touchThree();
      expect(r.names, ['start', 'follow']);
    });

    test('regression guard (passes today): the start cue is requested before '
        'the stream is asked to start', () async {
      final r = AkEcgRig(max: 5, useBandIdle: true);
      await r.tap();
      expect(r.log.take(2), ['start', 'begin']);
    });
  });

  group('the window after a follow-up waits for the cue to be played', () {
    test('while the follow-up plays nothing ends the gesture; once its plan '
        'ended the window opens and a quiet second closes it at 3', () async {
      final r = AkEcgRig(max: 5, useBandIdle: true, holdFollowUps: true);
      await r.tap();
      await r.steady();
      await r.touchThree();
      expect(r.names, ['start', 'follow']);
      await r.frame(1003);
      await r.frame(1004);
      await r.frame(1005);
      expect(r.results, isEmpty,
          reason: 'the follow-up is still playing: the next window is not open, '
              'so it cannot run out');
      expect(r.names, ['start', 'follow'], reason: 'no confirm yet');
      await r.endCue(); // the band became idle at sample time 1005.0
      await r.frame(1006);
      expect(r.results, [(3, null)]);
      expect(r.names, ['start', 'follow', 'confirm']);
    });

    test('a touch that starts and ends while the follow-up plays is not the '
        'next tap', () async {
      final r = AkEcgRig(max: 5, useBandIdle: true, holdFollowUps: true);
      await r.tap();
      await r.steady();
      await r.touchThree();
      await r.touchFour(); // 1002.25 to 1003.0: the follow-up is still playing
      await r.frame(1004);
      await r.endCue(); // idle at 1004.0, well after that touch ended
      await r.frame(1005);
      await r.frame(1006);
      expect(r.results, [(3, null)],
          reason: 'the early touch did not count; the gesture ended at 3');
      expect(r.names, ['start', 'follow', 'confirm']);
    });

    test('a touch that starts in the window after the plan ended counts',
        () async {
      final r = AkEcgRig(max: 5, useBandIdle: true, holdFollowUps: true);
      await r.tap();
      await r.steady();
      await r.touchThree();
      await r.frame(1003);
      await r.frame(1004);
      await r.endCue(); // idle at 1004.0
      // Touch from 1004.1 (inside the window that opened at 1004.0), engaged
      // at 1004.3.
      await r.frame(1005, [(10, 100)]);
      expect(r.names, ['start', 'follow', 'follow']);
      expect(r.results, isEmpty, reason: 'count 4, still below the max');
    });

    test('the second follow-up holds the window after it the same way',
        () async {
      final r = AkEcgRig(max: 5, useBandIdle: true, holdFollowUps: true);
      await r.tap();
      await r.steady();
      await r.touchThree();
      await r.frame(1003);
      await r.endCue(); // idle at 1003.0: the window for touch 4 opens
      await r.frame(1004, [(10, 100)]); // touch 4 from 1003.1, engaged 1003.3
      expect(r.names, ['start', 'follow', 'follow']);
      await r.frame(1005);
      await r.frame(1006);
      expect(r.results, isEmpty,
          reason: 'follow-up 2 is playing: the window for touch 5 is not open');
      await r.endCue(); // idle at 1006.0
      await r.frame(1007);
      expect(r.results, [(4, null)]);
      expect(r.names, ['start', 'follow', 'follow', 'confirm']);
    });

    test('regression guard (passes today): a follow-up plan that never ends '
        'does not freeze the gesture: the window opens at the timeout',
        () async {
      final r = AkEcgRig(
        max: 5,
        useBandIdle: true,
        holdFollowUps: true,
        buzzTimeout: const Duration(milliseconds: 30),
      );
      await r.tap();
      await r.steady();
      await r.touchThree();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await r.settle();
      await r.frame(1003);
      await r.frame(1004);
      expect(r.results, [(3, null)],
          reason: 'the cue never reported its end; the timeout released it');
      expect(r.session.active, isFalse);
    });

    test('regression guard (passes today): the gesture that reaches the max '
        'ends at once with the follow-up and the confirm, in that order',
        () async {
      final r = AkEcgRig(max: 3, useBandIdle: true, holdFollowUps: true);
      await r.tap();
      await r.steady();
      await r.touchThree();
      expect(r.results, [(3, null)]);
      expect(r.names, ['start', 'follow', 'confirm']);
    });
  });
}
