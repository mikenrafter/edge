// The pure rule for what a stopped main alarm becomes. RED: AlarmStopPolicy and
// AlarmStopCause.parse are stubs that throw.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/alarm_stop_policy.dart';

final _stop = DateTime(2026, 10, 7, 6, 0);
DateTime _at(int ms) => _stop.add(Duration(milliseconds: ms));

AlarmStopDecision _decide({
  AlarmStopCause cause = AlarmStopCause.userDoubleTap,
  List<int> tapsMs = const [],
  int nowMs = 0,
  bool confirmed = false,
  int n = 2,
  int windowMs = 4000,
}) =>
    AlarmStopPolicy(requiredTaps: n, window: Duration(milliseconds: windowMs))
        .decide(
      cause: cause,
      stoppedAt: _stop,
      taps: [for (final t in tapsMs) _at(t)],
      confirmedWake: confirmed,
      now: _at(nowMs),
    );

void main() {
  group('AlarmStopCause.parse', () {
    test('the engine strings', () {
      expect(AlarmStopCause.parse('user_double_tap'), AlarmStopCause.userDoubleTap);
      expect(AlarmStopCause.parse('expired'), AlarmStopCause.expired);
      expect(AlarmStopCause.parse('error'), AlarmStopCause.error);
    });

    test('anything else is error: no snooze from a cause nobody understands',
        () {
      for (final s in ['unknown', 'code_9', '', null, 'reAlarm']) {
        expect(AlarmStopCause.parse(s), AlarmStopCause.error, reason: '$s');
      }
    });
  });

  group('user_double_tap: the stopping tap is tap 1', () {
    test('n=2: one more tap inside the window dismisses AT ONCE (early)', () {
      expect(_decide(tapsMs: [1000], nowMs: 1000), AlarmStopDecision.dismissed,
          reason: 'confirmed as soon as the n-th tap arrives, window not over');
    });

    test('n=2: no further tap yet is pending until the window ends', () {
      expect(_decide(nowMs: 0), AlarmStopDecision.pending);
      expect(_decide(nowMs: 3999), AlarmStopDecision.pending);
    });

    test('n=3: two further taps are needed; the second one decides', () {
      expect(_decide(n: 3, tapsMs: [500], nowMs: 500), AlarmStopDecision.pending);
      expect(_decide(n: 3, tapsMs: [500, 1500], nowMs: 1500),
          AlarmStopDecision.dismissed);
    });

    test('n=5 needs four further taps', () {
      expect(_decide(n: 5, tapsMs: [100, 200, 300], nowMs: 300),
          AlarmStopDecision.pending);
      expect(_decide(n: 5, tapsMs: [100, 200, 300, 400], nowMs: 400),
          AlarmStopDecision.dismissed);
    });

    test('n=1: the stopping tap alone dismisses, with no tap at all', () {
      expect(_decide(n: 1, nowMs: 0), AlarmStopDecision.dismissed);
    });

    test('fewer than n by the window end is a snooze', () {
      expect(_decide(nowMs: 4000), AlarmStopDecision.snooze);
      expect(_decide(n: 3, tapsMs: [500], nowMs: 4000), AlarmStopDecision.snooze);
      expect(_decide(nowMs: 9000), AlarmStopDecision.snooze,
          reason: 'a late decision is the same decision');
    });

    test('a window of its own length: 6 s is not over at 5 s', () {
      expect(_decide(windowMs: 6000, nowMs: 5000), AlarmStopDecision.pending);
      expect(_decide(windowMs: 6000, nowMs: 6000), AlarmStopDecision.snooze);
    });
  });

  group('window boundaries', () {
    test('a tap exactly at the window end still counts', () {
      expect(_decide(tapsMs: [4000], nowMs: 4000), AlarmStopDecision.dismissed);
    });

    test('a tap 1 ms after the window end does not', () {
      expect(_decide(tapsMs: [4001], nowMs: 4001), AlarmStopDecision.snooze);
    });

    test('a tap at the instant of the stop counts', () {
      expect(_decide(tapsMs: [0], nowMs: 0), AlarmStopDecision.dismissed);
    });

    test('taps before the stop are ignored', () {
      expect(_decide(tapsMs: [-1], nowMs: 1000), AlarmStopDecision.pending);
      expect(_decide(tapsMs: [-5000, -1], nowMs: 4000), AlarmStopDecision.snooze);
      expect(_decide(n: 3, tapsMs: [-100, 500], nowMs: 500),
          AlarmStopDecision.pending,
          reason: 'one in-window tap is not two');
    });

    test('taps after now (not yet happened) are ignored', () {
      expect(_decide(tapsMs: [2000], nowMs: 1000), AlarmStopDecision.pending);
    });

    test('in-window taps still dismiss when the decision is made late', () {
      expect(_decide(tapsMs: [1000], nowMs: 8000), AlarmStopDecision.dismissed);
    });
  });

  group('expired', () {
    test('snoozes at once; taps do not make it a dismissal', () {
      expect(_decide(cause: AlarmStopCause.expired, nowMs: 0),
          AlarmStopDecision.snooze);
      expect(
          _decide(cause: AlarmStopCause.expired, tapsMs: [500, 1000], nowMs: 1000),
          AlarmStopDecision.snooze);
    });

    test('n=1 does not turn an expiry into a dismissal', () {
      expect(_decide(cause: AlarmStopCause.expired, n: 1),
          AlarmStopDecision.snooze);
    });
  });

  group('error', () {
    test('no snooze, no window: error', () {
      for (final ms in [0, 2000, 4000, 9000]) {
        expect(_decide(cause: AlarmStopCause.error, nowMs: ms),
            AlarmStopDecision.error,
            reason: 'at $ms ms');
      }
      expect(_decide(cause: AlarmStopCause.error, tapsMs: [100], n: 2, nowMs: 100),
          AlarmStopDecision.error);
    });
  });

  group('a confirmed wake', () {
    test('means awake, never a snooze, whatever the cause or time', () {
      for (final c in [AlarmStopCause.userDoubleTap, AlarmStopCause.expired]) {
        for (final ms in [0, 1000, 4000, 9000]) {
          expect(_decide(cause: c, confirmed: true, nowMs: ms),
              AlarmStopDecision.confirmedAwake,
              reason: '$c at $ms ms');
        }
      }
    });

    test('wins over taps too (nothing left to dismiss)', () {
      expect(_decide(confirmed: true, tapsMs: [500], nowMs: 500),
          AlarmStopDecision.confirmedAwake);
    });

    test('n=1 and confirmed: confirmedAwake, not dismissed', () {
      expect(_decide(n: 1, confirmed: true), AlarmStopDecision.confirmedAwake);
    });
  });

  group('reAlarm (the app\'s own re-alarm): no implicit stopping tap', () {
    AlarmStopDecision re({List<int> tapsMs = const [], int nowMs = 0, int n = 2}) =>
        _decide(cause: AlarmStopCause.reAlarm, tapsMs: tapsMs, nowMs: nowMs, n: n);

    test('n taps dismiss, early on the n-th', () {
      expect(re(tapsMs: [500], nowMs: 500), AlarmStopDecision.pending);
      expect(re(tapsMs: [500, 1500], nowMs: 1500), AlarmStopDecision.dismissed);
    });

    test('n=1 needs one real tap (nothing stopped it)', () {
      expect(re(n: 1, nowMs: 0), AlarmStopDecision.pending);
      expect(re(n: 1, tapsMs: [300], nowMs: 300), AlarmStopDecision.dismissed);
    });

    test('none or fewer by the end is the next snooze', () {
      expect(re(nowMs: 4000), AlarmStopDecision.snooze);
      expect(re(tapsMs: [500], nowMs: 4000), AlarmStopDecision.snooze);
    });

    test('a confirmed wake ends it as confirmedAwake', () {
      expect(_decide(cause: AlarmStopCause.reAlarm, confirmed: true, nowMs: 1000),
          AlarmStopDecision.confirmedAwake);
    });
  });
}
