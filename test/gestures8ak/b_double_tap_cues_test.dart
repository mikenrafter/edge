// 8AK B (red): the plain double-tap route plays the same additive cues as the
// ECG route.
//
// USER: "non ECG gestures don't have the same haptics call/response cadence.
// When I do a 2-tap (one double tap) I need it to give me the start and
// confirmation. It's giving neither. The 3 tap gives the follow up, but
// nothing else."
//
// ASSUMED BEHAVIOUR (lib/gestures/double_tap_repeat.dart,
// DoubleTapRepeatSession; parameters in support/ak_repeat_rig.dart):
//   * START cue once, in the same turn the first live double tap opens the
//     window (`begin`), id `<gesture id>:rep:start`.
//   * one FOLLOW-UP cue (the existing `buzz`) per further counted double tap,
//     ids `<gesture id>:rep:<n>`; an ignored/late/duplicate tap plays nothing.
//   * the CONFIRM cue once when the gesture ends counted (window ran out, or
//     the max was reached), id `<gesture id>:rep:confirm`, queued BEHIND the
//     last follow-up, even when no action is mapped to the count.
//   * an abandoned gesture (`dispose`, "Stopped early") plays no confirm and
//     no follow-up beyond what already happened.
//   * a cue that throws or is not written is logged and changes nothing: the
//     count, the window and the cues after it are unaffected.
//
// Failure mode today: the session has no start and no confirm cue (and no
// parameters for them), so a count of 2 is silent and a count of 3 is
// [follow].

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';

import 'support/ak_repeat_rig.dart';

void main() {
  test('the first double tap plays the start cue at once, id ...:rep:start',
      () {
    fakeAsync((async) {
      final r = AkRepeatRig()..begin(repTap());
      // No microtask has run: the cue was requested inside `begin` itself (as
      // the ECG session does, and as the follow-up always was: the existing
      // double_tap_repeat_test.dart reads the buzz right after `add`).
      expect(r.names, ['start']);
      expect(r.cues.single.$2, endsWith(':rep:start'));
      expect(r.cues.single.$3, 0, reason: 'in the turn the tap was accepted');
    });
  });

  test('one double tap alone: start, then the confirm when the window ran '
      'out (a count of 2)', () {
    fakeAsync((async) {
      final r = AkRepeatRig()..begin(repTap());
      async.elapse(const Duration(seconds: 3));
      expect(r.result, 2);
      expect(r.names, ['start', 'confirm']);
      expect(r.cues.last.$2, endsWith(':rep:confirm'));
    });
  });

  test('two double taps: start, follow-up, confirm', () {
    fakeAsync((async) {
      final r = AkRepeatRig()..begin(repTap());
      async.elapse(const Duration(milliseconds: 800));
      expect(r.session.add(repTap(sec: 1)), isTrue);
      expect(r.names, ['start', 'follow'],
          reason: 'the follow-up is requested in the turn the tap is counted');
      async.elapse(const Duration(seconds: 3));
      expect(r.result, 3);
      expect(r.names, ['start', 'follow', 'confirm']);
    });
  });

  test('three double taps: start, follow-up, follow-up, confirm', () {
    fakeAsync((async) {
      final r = AkRepeatRig()..begin(repTap());
      async.elapse(const Duration(milliseconds: 800));
      r.session.add(repTap(sec: 1));
      async.elapse(const Duration(milliseconds: 800));
      r.session.add(repTap(sec: 2));
      async.elapse(const Duration(seconds: 3));
      expect(r.result, 4);
      expect(r.names, ['start', 'follow', 'follow', 'confirm']);
    });
  });

  test('four double taps reach the max of 5 and end at once: start, '
      'follow-up x3, confirm', () {
    fakeAsync((async) {
      final r = AkRepeatRig(max: 5)..begin(repTap());
      for (var k = 1; k <= 3; k++) {
        async.elapse(const Duration(milliseconds: 700));
        r.session.add(repTap(sec: k));
      }
      async.flushMicrotasks();
      expect(r.result, 5, reason: 'the max ends it at once, no window wait');
      expect(r.names, ['start', 'follow', 'follow', 'follow', 'confirm']);
    });
  });

  test('every cue has its own event id, all of this gesture, the confirm '
      'last', () {
    fakeAsync((async) {
      final r = AkRepeatRig()..begin(repTap());
      async.elapse(const Duration(milliseconds: 500));
      r.session.add(repTap(sec: 1));
      async.elapse(const Duration(seconds: 3));
      final ids = [for (final c in r.cues) c.$2];
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.first, endsWith(':rep:start'));
      expect(ids.last, endsWith(':rep:confirm'));
    });
  });

  test('the confirm is requested after the follow-up it closes (max reached '
      'in the same turn)', () {
    fakeAsync((async) {
      final r = AkRepeatRig(max: 3, deliverMs: 400)..begin(repTap());
      async.elapse(const Duration(milliseconds: 1000));
      r.session.add(repTap(sec: 1)); // 3 = the max: follow-up, then confirm
      async.elapse(const Duration(seconds: 5));
      expect(r.names, ['start', 'follow', 'confirm']);
      final follow = r.cues[1].$3, confirm = r.cues[2].$3;
      expect(confirm, greaterThanOrEqualTo(follow));
    });
  });

  group('abandoned and ignored taps play nothing extra', () {
    test('stopped early (the app is going away): the start already played, '
        'no confirm', () {
      fakeAsync((async) {
        final r = AkRepeatRig()..begin(repTap());
        async.elapse(const Duration(milliseconds: 500));
        r.session.dispose();
        async.elapse(const Duration(seconds: 5));
        expect(r.names, ['start']);
      });
    });

    test('stopped early after a follow-up: start and follow-up only', () {
      fakeAsync((async) {
        final r = AkRepeatRig()..begin(repTap());
        async.elapse(const Duration(milliseconds: 500));
        r.session.add(repTap(sec: 1));
        async.elapse(const Duration(milliseconds: 500));
        r.session.dispose();
        async.elapse(const Duration(seconds: 5));
        expect(r.names, ['start', 'follow']);
      });
    });

    test('a late tap and a re-delivered tap play no follow-up', () {
      fakeAsync((async) {
        final r = AkRepeatRig()..begin(repTap());
        async.elapse(const Duration(milliseconds: 500));
        expect(
            r.session.offer(repTap(sec: 1, late: const Duration(minutes: 5))),
            RepeatOffer.ignored);
        expect(r.session.offer(repTap()), RepeatOffer.ignored,
            reason: 'the opening tap seen again');
        async.elapse(const Duration(seconds: 3));
        expect(r.result, 2);
        expect(r.names, ['start', 'confirm']);
      });
    });
  });

  group('a cue that fails changes nothing else', () {
    test('a start cue the band did not take: the count and the cues after it '
        'are unaffected', () {
      fakeAsync((async) {
        final r = AkRepeatRig(startOk: false)..begin(repTap());
        async.elapse(const Duration(milliseconds: 500));
        r.session.add(repTap(sec: 1));
        async.elapse(const Duration(seconds: 3));
        expect(r.result, 3);
        expect(r.names, ['start', 'follow', 'confirm']);
        expect(r.steps, contains(contains('could not be written')));
      });
    });

    test('a start cue that throws is the same', () {
      fakeAsync((async) {
        final r = AkRepeatRig(startThrows: true)..begin(repTap());
        async.elapse(const Duration(seconds: 3));
        expect(r.result, 2);
        expect(r.names, ['start', 'confirm']);
        expect(r.session.open, isFalse);
      });
    });
  });
}
