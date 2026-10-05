// 8AK B (red): the plain double-tap windows start AFTER the haptics went
// through and were confirmed.
//
// USER: "for normal double taps, the timings should start after the haptics go
// through and are confirmed: tap -> confirm -> tap -> confirm ... the altered
// timing remains for the ECG route."
//
// ASSUMED BEHAVIOUR (lib/gestures/double_tap_repeat.dart,
// DoubleTapRepeatSession; `bandIdle` and `cueTimeout` are described in
// support/ak_repeat_rig.dart):
//   * WITH `bandIdle` (AppState's wiring) the pause window (`window()`, 2500
//     ms by default) is armed only after the cue of the tap that opens/extends
//     it has been DELIVERED (the cue callback returned) and the band reported
//     idle (its plan ended). It is never measured from the tap time.
//   * While the cue is still playing the window is not running: it cannot
//     run out, whatever the elapsed time.
//   * A cue that never ends or never answers cannot freeze the gesture: after
//     `cueTimeout` (default 15 s) the window is armed anyway.
//   * Reaching the max ends the gesture at once; it does not wait for a cue.
//   * Everything the window does once armed is as today (a further tap inside
//     it counts and re-arms it after ITS cue).
//   * WITHOUT `bandIdle` (every existing caller and test) nothing changes: the
//     window is armed at the tap, whatever a cue does (the phase7 test "a buzz
//     that never answers cannot hold the window open" stands, and is repeated
//     here as a guard).
// The ECG route keeps its own (altered) timing, see a_ecg_window_*.
//
// Rig band model: a cue is written `deliverMs` after the band can take it and
// its plan ends `planMs` after that; cues queue behind each other.
//
// Failure mode today: the window is armed at the tap time (2500 ms after the
// tap), whatever the cue is doing.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';

import 'support/double_tap_repeat_rig.dart';

void main() {
  test('the window runs from the end of the start cue, not from the tap: '
      'cue written at 600 ms, plan ends at 1600 ms, window out at 4100 ms',
      () {
    fakeAsync((async) {
      final r = AkRepeatRig(deliverMs: 600, planMs: 1000, useBandIdle: true)
        ..begin(repTap());
      async.elapse(const Duration(milliseconds: 4099));
      expect(r.result, isNull, reason: 'the window opened at 1600 ms');
      expect(r.session.open, isTrue);
      async.elapse(const Duration(milliseconds: 1));
      expect(r.result, 2);
    });
  });

  test('a long plan outlasting the old window: the tap is not timed out '
      'while its own confirmation is still playing', () {
    fakeAsync((async) {
      // Plan 3000 ms > the 2500 ms window: the old timer would have fired at
      // 2500 ms, in the middle of the cue.
      final r = AkRepeatRig(deliverMs: 100, planMs: 3000, useBandIdle: true)
        ..begin(repTap());
      async.elapse(const Duration(milliseconds: 2600));
      expect(r.result, isNull);
      expect(r.session.open, isTrue);
      async.elapse(const Duration(milliseconds: 3000));
      expect(r.result, 2);
    });
  });

  test('tap -> confirm -> tap -> confirm: each follow-up re-arms the window '
      'after its own cue ended', () {
    fakeAsync((async) {
      final r = AkRepeatRig(deliverMs: 600, planMs: 1000, useBandIdle: true)
        ..begin(repTap());
      // The start cue ended at 1600 ms; the wearer taps again at 2800 ms.
      async.elapse(const Duration(milliseconds: 2800));
      expect(r.session.add(repTap(sec: 2)), isTrue);
      expect(r.session.count, 3);
      // The follow-up is written at 3400 ms and ends at 4400 ms: the window
      // runs out 2500 ms after that.
      async.elapse(const Duration(milliseconds: 6899 - 2800));
      expect(r.result, isNull, reason: 'at 6899 ms, one ms before it ends');
      async.elapse(const Duration(milliseconds: 1));
      expect(r.result, 3);
    });
  });

  test('while the start cue is still playing the window is not running at '
      'all, however long that takes', () {
    fakeAsync((async) {
      final r = AkRepeatRig(manualIdle: true, useBandIdle: true, cueTimeout: const Duration(minutes: 5))
        ..begin(repTap());
      async.elapse(const Duration(seconds: 30));
      expect(r.result, isNull);
      expect(r.session.open, isTrue);
      r.bandBecameIdle(); // the plan ended at 30 s
      async.elapse(const Duration(milliseconds: 2499));
      expect(r.result, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(r.result, 2);
    });
  });

  test('a cue that never ends is bounded by cueTimeout: the window arms at '
      'the timeout', () {
    fakeAsync((async) {
      final r = AkRepeatRig(
        manualIdle: true,
        useBandIdle: true,
        cueTimeout: const Duration(seconds: 5),
      )..begin(repTap());
      async.elapse(const Duration(milliseconds: 7499));
      expect(r.result, isNull, reason: 'timeout 5 s + window 2.5 s');
      async.elapse(const Duration(milliseconds: 1));
      expect(r.result, 2);
    });
  });

  test('a start cue that is never answered is bounded by cueTimeout too',
      () {
    fakeAsync((async) {
      final r = AkRepeatRig(
        startHangs: true,
        useBandIdle: true,
        cueTimeout: const Duration(seconds: 5),
      )..begin(repTap());
      async.elapse(const Duration(milliseconds: 7499));
      expect(r.result, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(r.result, 2);
    });
  });

  test('reaching the max ends the gesture at once, with no wait for the '
      'cue', () {
    fakeAsync((async) {
      final r = AkRepeatRig(
        max: 3,
        manualIdle: true,
        useBandIdle: true,
        cueTimeout: const Duration(minutes: 5),
      )..begin(repTap());
      async.elapse(const Duration(seconds: 1));
      r.bandBecameIdle();
      async.elapse(const Duration(milliseconds: 200));
      r.session.add(repTap(sec: 1));
      async.flushMicrotasks();
      expect(r.result, 3);
      expect(r.names.take(2), ['start', 'follow']);
    });
  });

  test('stopped early while the start cue still plays: finished once, no '
      'late window, no late confirm', () {
    fakeAsync((async) {
      final r = AkRepeatRig(
        manualIdle: true,
        useBandIdle: true,
        cueTimeout: const Duration(minutes: 5),
      )..begin(repTap());
      async.elapse(const Duration(seconds: 1));
      r.session.dispose();
      expect(r.session.open, isFalse);
      expect(r.finished, [2]);
      r.bandBecameIdle(); // the old cue ends after the gesture did
      async.elapse(const Duration(seconds: 30));
      expect(r.finished, [2], reason: 'no second finish from a stale window');
      expect(r.names, ['start'], reason: 'an abandoned gesture confirms nothing');
    });
  });

  test('regression guard (passes today): without bandIdle a buzz that never '
      'answers cannot hold the window open (the phase7 rule)', () {
    fakeAsync((async) {
      final session = DoubleTapRepeatSession(
        maxTaps: () => 5,
        window: () => const Duration(seconds: 2),
        buzz: (_) => Completer<bool>().future,
      );
      int? count;
      session.begin(repTap()).then((c) => count = c);
      session.add(repTap(sec: 1));
      async.elapse(const Duration(seconds: 3));
      expect(count, 3);
      expect(session.open, isFalse);
    });
  });

  test('regression guard (passes today): with no cue wiring the window runs '
      'from the tap, as before', () {
    fakeAsync((async) {
      final r = AkRepeatRig()..begin(repTap());
      async.elapse(const Duration(milliseconds: 2499));
      expect(r.result, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(r.result, 2);
    });
  });
}
