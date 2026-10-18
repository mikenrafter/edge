// DoubleTapRepeatSession groups taps by the BAND's time (review finding I).
//
// Receipt time only says when the phone heard about a tap; a link that was down
// delivers several taps in one burst. Grouping on `clock.now()` made two taps
// that happened 3 s apart a "triple" if they arrived together, and counted older
// events delivered out of order. Now, while the strap clock is believable:
//   * an event joins the group only if its own time is within the window of a
//     member (adjacent; the window is inclusive);
//   * an event LATER than that ends the group and starts the next one;
//   * an event EARLIER than every member by more than the window is unrelated;
//   * an older event inside the window (bounded reordering) is a member.
// Receipt time is the fallback only for an implausible strap clock.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

/// A tap at strap second [sec] (+[ms]) received [lateMs] after it happened.
StrapEvent _tap(int sec, {int ms = 0, int lateMs = 1000}) {
  final subsec = (ms * 32768 / 1000).round();
  final at = DateTime.fromMillisecondsSinceEpoch(
      (_t0Sec + sec) * 1000 + ms,
      isUtc: true);
  return StrapEvent(
    eventId: 14,
    tsEpoch: _t0Sec + sec,
    tsSubsec: subsec,
    receivedAt: at.add(Duration(milliseconds: lateMs)),
    hex: '',
    deviceId: 'band',
  );
}

class _Rig {
  _Rig({this.max = 5}) {
    session = DoubleTapRepeatSession(
      maxTaps: () => max,
      window: () => Duration(milliseconds: windowMs),
      step: steps.add,
      onFinished: finished.add,
    );
  }
  int max;
  int windowMs = 2500;
  late final DoubleTapRepeatSession session;
  final steps = <String>[];
  final finished = <int>[];
  int? result;
  void begin(StrapEvent e) => session.begin(e).then((c) => result = c);
}

void main() {
  test('taps 3 s apart by the band clock are not a triple even when they '
      'arrive together', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap(0, lateMs: 4000));
      // 3 s of band time later, delivered 10 ms after the first.
      async.elapse(const Duration(milliseconds: 10));
      expect(
        r.session.offer(_tap(3, lateMs: 1010)),
        RepeatOffer.newGroup,
        reason: '3 s > the 2.5 s window',
      );
      async.flushMicrotasks();
      expect(r.result, 2, reason: 'the first group is a plain double tap');
      expect(r.finished, [2]);
      expect(r.session.open, isFalse);
    });
  });

  test('add() reports false for a tap that starts the next group', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap(0, lateMs: 4000));
      expect(r.session.add(_tap(3, lateMs: 1010)), isFalse);
      expect(r.session.count, 0, reason: 'closed');
    });
  });

  test('taps exactly one window apart still group (the window is inclusive)',
      () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap(0));
      expect(r.session.offer(_tap(2, ms: 500)), RepeatOffer.counted);
      expect(r.session.count, 3);
    });
  });

  test('a chain where each tap is within the window of the previous groups, '
      'however long the whole chain', () {
    fakeAsync((async) {
      final r = _Rig(max: 9)..begin(_tap(0));
      for (var i = 1; i <= 4; i++) {
        expect(r.session.offer(_tap(i * 2)), RepeatOffer.counted);
      }
      expect(r.session.count, 6);
    });
  });

  test('an out-of-order older tap within the window is a member', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap(10));
      expect(r.session.offer(_tap(12)), RepeatOffer.counted);
      expect(r.session.offer(_tap(8, ms: 500)), RepeatOffer.counted,
          reason: '1.5 s before the first member: bounded reordering');
      expect(r.session.count, 4);
    });
  });

  test('an older tap beyond the window of every member is unrelated and not '
      'counted', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap(10));
      expect(r.session.offer(_tap(12)), RepeatOffer.counted);
      expect(r.session.offer(_tap(5)), RepeatOffer.ignored);
      expect(r.session.count, 3);
      expect(r.session.open, isTrue, reason: 'the group carries on');
      expect(r.steps.join('\n'), contains('older'));
    });
  });

  test('the same event twice is still one tap', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap(0));
      expect(r.session.offer(_tap(1)), RepeatOffer.counted);
      expect(r.session.offer(_tap(1)), RepeatOffer.ignored);
      expect(r.session.count, 3);
    });
  });

  test('a late (not live) tap is ignored, as before', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap(0));
      expect(r.session.offer(_tap(1, lateMs: 600000)), RepeatOffer.ignored);
      expect(r.session.count, 2);
    });
  });

  test('offer() on a closed session is ignored', () {
    final r = _Rig();
    expect(r.session.offer(_tap(0)), RepeatOffer.ignored);
  });

  group('an implausible strap clock falls back to receipt time', () {
    StrapEvent unset({required int receivedMs}) => StrapEvent(
          eventId: 14,
          tsEpoch: 0,
          receivedAt: _t0.add(Duration(milliseconds: receivedMs)),
          hex: '',
          deviceId: 'band',
        );

    test('taps are counted by when the phone received them', () {
      fakeAsync((async) {
        final r = _Rig()..begin(unset(receivedMs: 0));
        async.elapse(const Duration(seconds: 1));
        expect(r.session.offer(unset(receivedMs: 1000)), RepeatOffer.counted);
        expect(r.session.count, 3);
      });
    });

    test('an implausible tap joins a plausible group by receipt', () {
      fakeAsync((async) {
        final r = _Rig()..begin(_tap(0));
        async.elapse(const Duration(seconds: 1));
        expect(r.session.offer(unset(receivedMs: 3000)), RepeatOffer.counted);
      });
    });

    test('a plausible tap joins an implausible group by receipt', () {
      fakeAsync((async) {
        final r = _Rig()..begin(unset(receivedMs: 0));
        async.elapse(const Duration(seconds: 1));
        expect(r.session.offer(_tap(1)), RepeatOffer.counted);
      });
    });
  });

  test('the trace names the band-clock gap between taps', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap(0));
      r.session.offer(_tap(2));
      expect(r.steps.join('\n'),
          contains('2000 ms after the nearest earlier tap by the band clock'));
    });
  });
}
