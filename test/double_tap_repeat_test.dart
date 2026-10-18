// The slower multi-tap method that needs no ECG: repeated firmware double taps.
// The first live double tap opens a window; each further live double tap inside
// it adds one, buzzes once and restarts the window; when the window runs out the
// count is final. Pure timing: no BLE, no storage.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _tap({
  int sec = 0,
  Duration late = const Duration(seconds: 1),
}) {
  final ts = _t0Sec + sec;
  return StrapEvent(
    eventId: 14,
    tsEpoch: ts,
    receivedAt:
        DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true).add(late),
    hex: '',
    deviceId: 'band',
  );
}

class _Rig {
  _Rig({this.max = 5, this.windowMs = 2500, this.buzzOk = true}) {
    session = DoubleTapRepeatSession(
      maxTaps: () => max,
      window: () => Duration(milliseconds: windowMs),
      buzz: (id) async {
        buzzes.add(id);
        if (!buzzOk) throw StateError('no band');
        return true;
      },
      step: steps.add,
      onStarted: (tap, settings) => started.add(settings),
      onFinished: (count) => finished.add(count),
    );
  }

  int max;
  int windowMs;
  final bool buzzOk;
  late final DoubleTapRepeatSession session;
  final buzzes = <String>[];
  final steps = <String>[];
  final started = <String>[];
  final finished = <int>[];
  int? result;

  void begin(StrapEvent e) => session.begin(e).then((c) => result = c);
}

void main() {
  test('one double tap alone is a count of 2 after the window, with no buzz',
      () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap());
      expect(r.session.open, isTrue);
      async.elapse(const Duration(milliseconds: 2499));
      expect(r.result, isNull);
      expect(r.session.open, isTrue);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(r.result, 2);
      expect(r.finished, [2]);
      expect(r.buzzes, isEmpty);
      expect(r.session.open, isFalse);
    });
  });

  test('each further live double tap adds one, buzzes once and restarts the '
      'window', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap());
      async.elapse(const Duration(milliseconds: 2000));
      expect(r.session.add(_tap(sec: 2)), isTrue);
      expect(r.session.count, 3);
      expect(r.buzzes, hasLength(1));
      async.elapse(const Duration(milliseconds: 2000)); // 4000 ms in total
      expect(r.result, isNull, reason: 'the window restarted at the 2nd tap');
      expect(r.session.add(_tap(sec: 4)), isTrue);
      expect(r.session.count, 4);
      expect(r.buzzes, hasLength(2));
      expect(r.buzzes.toSet(), hasLength(2), reason: 'each buzz is its own event');
      async.elapse(const Duration(milliseconds: 2500));
      async.flushMicrotasks();
      expect(r.result, 4);
      expect(r.finished, [4]);
    });
  });

  test('reaching the max finishes at once, without waiting for the window', () {
    fakeAsync((async) {
      final r = _Rig(max: 3)..begin(_tap());
      async.elapse(const Duration(milliseconds: 500));
      r.session.add(_tap(sec: 1));
      async.flushMicrotasks();
      expect(r.result, 3);
      expect(r.session.open, isFalse);
      expect(r.buzzes, hasLength(1), reason: 'the buzz for the tap that arrived');
    });
  });

  test('the window is read again on every restart (it is adjustable live)',
      () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap());
      r.windowMs = 1000;
      async.elapse(const Duration(milliseconds: 100));
      r.session.add(_tap(sec: 1));
      async.elapse(const Duration(milliseconds: 999));
      expect(r.result, isNull);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(r.result, 3);
    });
  });

  test('only live taps count: a late tap inside the window adds nothing', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap());
      expect(r.session.add(_tap(sec: 1, late: const Duration(minutes: 5))),
          isFalse);
      expect(r.session.count, 2);
      expect(r.buzzes, isEmpty);
      async.elapse(const Duration(milliseconds: 2500));
      async.flushMicrotasks();
      expect(r.result, 2);
    });
  });

  test('a late tap can never open a window', () {
    fakeAsync((async) {
      final r = _Rig();
      expect(
          () => r.session.begin(_tap(late: const Duration(minutes: 5))),
          throwsStateError);
      expect(r.session.open, isFalse);
    });
  });

  test('the same tap delivered twice counts once', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap());
      expect(r.session.add(_tap()), isFalse, reason: 'the opening tap again');
      expect(r.session.add(_tap(sec: 1)), isTrue);
      expect(r.session.add(_tap(sec: 1)), isFalse);
      expect(r.session.count, 3);
    });
  });

  test('taps with no usable strap clock are told apart by receipt time', () {
    fakeAsync((async) {
      StrapEvent unset(int ms) => StrapEvent(
            eventId: 14,
            tsEpoch: 0,
            receivedAt: _t0.add(Duration(milliseconds: ms)),
            hex: '',
            deviceId: 'band',
          );
      final r = _Rig()..begin(unset(0));
      expect(r.session.add(unset(100)), isFalse, reason: 'a re-send');
      expect(r.session.add(unset(900)), isTrue, reason: 'a real second tap');
      expect(r.session.count, 3);
    });
  });

  test('a buzz that throws never stops the count', () {
    fakeAsync((async) {
      final r = _Rig(buzzOk: false)..begin(_tap());
      r.session.add(_tap(sec: 1));
      r.session.add(_tap(sec: 2));
      async.flushMicrotasks();
      expect(r.session.count, 4);
      async.elapse(const Duration(milliseconds: 2500));
      async.flushMicrotasks();
      expect(r.result, 4);
    });
  });

  test('the latch resets: the next gesture opens a fresh window', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap());
      async.elapse(const Duration(milliseconds: 2500));
      async.flushMicrotasks();
      expect(r.session.open, isFalse);
      expect(r.session.add(_tap(sec: 30)), isFalse, reason: 'nothing is open');
      r.result = null;
      r.begin(_tap(sec: 60));
      expect(r.session.open, isTrue);
      expect(r.session.count, 2);
      async.elapse(const Duration(milliseconds: 2500));
      async.flushMicrotasks();
      expect(r.result, 2);
    });
  });

  test('a throw from onFinished still resets the latch', () {
    fakeAsync((async) {
      final s = DoubleTapRepeatSession(
        maxTaps: () => 5,
        window: () => const Duration(seconds: 1),
        onFinished: (_) => throw StateError('listener failed'),
      );
      int? result;
      s.begin(_tap()).then((c) => result = c);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(result, 2);
      expect(s.open, isFalse);
    });
  });

  test('dispose finishes a waiting gesture with the count so far', () {
    fakeAsync((async) {
      final r = _Rig()..begin(_tap());
      r.session.add(_tap(sec: 1));
      r.session.dispose();
      async.flushMicrotasks();
      expect(r.result, 3);
      expect(r.session.open, isFalse);
      async.elapse(const Duration(seconds: 10));
      expect(r.finished, [3], reason: 'the timer is gone; no second finish');
    });
  });

  group('the trace', () {
    test('names the settings, each tap with its timing, and the end', () {
      fakeAsync((async) {
        final r = _Rig(windowMs: 2000)..begin(_tap());
        expect(r.started.single, contains('window 2000 ms'));
        async.elapse(const Duration(milliseconds: 700));
        r.session.add(_tap(sec: 1));
        async.elapse(const Duration(milliseconds: 2000));
        async.flushMicrotasks();
        final all = r.steps.join('\n');
        expect(all, contains('Double tap 1 received'));
        expect(all, matches(RegExp(
            r'Double tap 2 received, 700 ms after the last one\. Count is 3')));
        expect(all, contains('Buzz requested'));
        expect(all, matches(RegExp(
            r'Window ran out 2000 ms after the last tap\. Final count 3')));
      });
    });

    test('says why a tap did not count', () {
      fakeAsync((async) {
        final r = _Rig()..begin(_tap());
        r.session.add(_tap(sec: 1, late: const Duration(minutes: 5)));
        expect(r.steps.join('\n'), contains('late'));
      });
    });
  });
}
