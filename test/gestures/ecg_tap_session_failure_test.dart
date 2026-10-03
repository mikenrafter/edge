// 8X — when the ECG fails: the failure buzz, the double-tap fallback, the retry.
//
// "ECG failed" means the gesture would end abandoned: start_failed (the stream
// start refused, threw or timed out), no_stream, stalled, link_lost or
// sample_gap.
//
//  * Failure buzz (any mode): one long buzz per failed gesture, injected as
//    `failBuzz` with event id `<gesture id>:failed`, queued behind any count
//    buzz in the same tail (so it respects the band's quiet gap).
//  * fallbackToDoubleTap ON (default) and no touch counted yet (count 2): the
//    gesture ends with count 2 and reason 'fallback: <reason>' so the double-tap
//    action runs. A stream start that fails does not throw. No retry.
//  * fallbackToDoubleTap OFF: a failure BEFORE the touch window opened stops the
//    stream, resets the attempt and starts the stream once more inside the same
//    gesture. A second failure, or any failure after the window opened, ends
//    the gesture abandoned (count null) with the failure buzz.
//  * A failure after a touch was counted (count 3 or more) is abandoned
//    whatever the toggle.
//
// Rig timeline as in ecg_tap_session_test.dart: [_Rig.steady] feeds two flat
// packets (1000 and 1001), the window opens at 1001.5 and closes at 1001.8;
// packet 1002 covers [1001.0, 1002.0).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../support/ecg_trace.dart' show r17;

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

StrapEvent _tap({int sec = 0}) => StrapEvent(
      eventId: 14,
      tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000 + sec,
      receivedAt: _t0.add(Duration(seconds: sec, milliseconds: 300)),
      hex: '',
      deviceId: 'band',
    );

LabradorR17 _pkt(int sec, List<int> samples) =>
    r17(strapSeconds: sec, samples: samples, sequence: sec);

List<int> _flat() => List.filled(100, 0);

/// A trace that moves on every sample: contact all through the packet.
List<int> _moving() => [for (var i = 0; i < 100; i++) i.isEven ? 100 : -100];

final _fallbackOff = EcgTapThresholds(fallbackToDoubleTap: false);

/// What one call of beginStream does: true or false is returned, an Exception
/// or Error is thrown, a Completer is awaited (it never answers unless the
/// test completes it).
typedef _Begin = Object;

class _Rig {
  _Rig({
    this.max = 3,
    this.th,
    this.begins = const <_Begin>[true],
    this.failBuzzThrows = false,
    this.failBuzzHangs = false,
    this.failBuzzResult = true,
    Duration? buzzTimeout,
  }) {
    session = EcgTapSession(
      beginStream: () async {
        began++;
        log.add('begin');
        final b = begins[(began - 1).clamp(0, begins.length - 1)];
        if (b is Completer<bool>) return await b.future;
        if (b is Exception) throw b;
        if (b is Error) throw b;
        return b as bool;
      },
      endStream: () async {
        ended++;
        log.add('end');
      },
      isStreamAlive: () => alive,
      buzz: (pulses, id) async {
        buzzes.add((pulses, id));
        order.add('count:$pulses');
        return true;
      },
      failBuzz: (id) async {
        failIds.add(id);
        order.add('fail');
        if (failBuzzHangs) return Completer<bool>().future;
        if (failBuzzThrows) throw StateError('haptic transport failed');
        return failBuzzResult;
      },
      maxTaps: () => max,
      thresholds: () => th ?? EcgTapThresholds(),
      onFinished: (count, reason) => results.add((count, reason)),
      onStarted: (tap, settings) => started.add(settings),
      recordSession: (r) async => records.add(r),
      step: steps.add,
      now: () => now,
      wait: (d) async => waits.add(d),
      pollEvery: const Duration(hours: 1),
      sensorReacquire: Duration.zero,
      beginTimeout: const Duration(milliseconds: 40),
      endTimeout: const Duration(milliseconds: 40),
      recordTimeout: const Duration(milliseconds: 40),
      buzzTimeout: buzzTimeout ?? const Duration(seconds: 15),
    );
  }

  final int max;
  final EcgTapThresholds? th;
  final List<_Begin> begins;
  final bool failBuzzThrows, failBuzzHangs, failBuzzResult;
  late final EcgTapSession session;
  bool alive = true;
  DateTime now = _t0;
  int began = 0, ended = 0;
  final log = <String>[];
  final order = <String>[];
  final buzzes = <(int, String)>[];
  final failIds = <String>[];
  final results = <(int?, String?)>[];
  final started = <String>[];
  final records = <EcgGestureRecord>[];
  final steps = <String>[];
  final waits = <Duration>[];

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Two flat packets: the stream is steady and the window opens at 1001.5.
  Future<void> steady({int sec = 1000}) async {
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_pkt(sec, _flat()));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_pkt(sec + 1, _flat()));
    await settle();
  }
}

/// A way for the ECG to fail once the stream is up, with the reason it ends
/// with and whether the touch window had opened by then.
typedef _Failure = ({
  String reason,
  bool afterWindow,
  Future<void> Function(_Rig) drive,
});

final List<_Failure> _failures = [
  (
    reason: 'link_lost',
    afterWindow: false,
    drive: (r) async {
      r.alive = false;
      r.session.poll();
      await r.settle();
    },
  ),
  (
    reason: 'no_stream',
    afterWindow: false,
    drive: (r) async {
      r.now = _t0.add(const Duration(seconds: 21));
      r.session.poll();
      await r.settle();
    },
  ),
  (
    reason: 'link_lost',
    afterWindow: true,
    drive: (r) async {
      await r.steady();
      r.alive = false;
      r.session.poll();
      await r.settle();
    },
  ),
  (
    reason: 'stalled',
    afterWindow: true,
    drive: (r) async {
      await r.steady();
      r.now = r.now.add(const Duration(seconds: 4));
      r.session.poll();
      await r.settle();
    },
  ),
  (
    reason: 'sample_gap',
    afterWindow: true,
    drive: (r) async {
      await r.steady();
      // Packet 1002 never arrives: the hole swallows the window's deadline.
      r.now = _t0.add(const Duration(seconds: 3));
      r.session.onFrame(_pkt(1003, _flat()));
      await r.settle();
    },
  ),
];

String _name(_Failure f) =>
    '${f.reason}${f.afterWindow ? ' after the window opened' : ' before the window opened'}';

void main() {
  group('the failure buzz: one long buzz per failed gesture, any mode', () {
    for (final fallback in [true, false]) {
      for (final f in _failures.where((f) => f.afterWindow || fallback)) {
        // With the fallback off a failure before the window is retried first;
        // that is pinned below, here only the final failure is asked about.
        test('${_name(f)} (fallback ${fallback ? 'on' : 'off'}): failBuzz '
            'once, with the failed event id', () async {
          final r = _Rig(
              th: EcgTapThresholds(fallbackToDoubleTap: fallback),
              begins: const [true]);
          final tap = _tap();
          await r.session.start(tap);
          await f.drive(r);
          expect(r.failIds, hasLength(1));
          expect(r.failIds.single, startsWith(tap.identity));
          expect(r.failIds.single, endsWith(':failed'));
          expect(r.steps,
              contains('ECG failed (${f.reason}): one long buzz.'));
          expect(r.buzzes, isEmpty, reason: 'no count buzz for a failed ECG');
        });
      }
    }

    test('a second poll (or a late event) after the failure does not buzz '
        'again', () async {
      final r = _Rig(th: _fallbackOff);
      await r.session.start(_tap());
      await r.steady();
      r.alive = false;
      r.session.poll();
      r.session.poll();
      await r.settle();
      expect(r.failIds, hasLength(1));
    });

    test('a gesture that ends normally never buzzes the failure', () async {
      final r = _Rig(max: 3);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_pkt(1002, _flat()));
      await r.settle();
      expect(r.results, [(2, null)]);
      expect(r.failIds, isEmpty);
    });

    test('it is queued behind the count buzzes and waits out the quiet gap',
        () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_pkt(1002, _moving())); // tap 3: x3 as three commands
      await r.settle();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.order, ['count:1', 'count:1', 'count:1', 'fail']);
      expect(r.waits, [
        const Duration(milliseconds: 1800),
        const Duration(milliseconds: 1800),
        const Duration(milliseconds: 1800),
      ], reason: 'two between the count commands, one before the failure buzz');
    });

    test('a failure buzz that throws or is refused is logged and nothing '
        'else: the gesture ended and the next one works', () async {
      for (final throws in [true, false]) {
        final r = _Rig(
            failBuzzThrows: throws, failBuzzResult: false, th: _fallbackOff);
        await r.session.start(_tap());
        await r.steady();
        r.alive = false;
        r.session.poll();
        await r.settle();
        expect(r.results, [(null, 'link_lost')], reason: 'throws $throws');
        expect(r.session.active, isFalse);
        r.alive = true;
        await r.session.start(_tap(sec: 9));
        expect(r.session.active, isTrue);
      }
    });

    test('a failure buzz that never answers is bounded: the next failed '
        'gesture still gets its own', () async {
      final r = _Rig(
        th: _fallbackOff,
        failBuzzHangs: true,
        buzzTimeout: const Duration(milliseconds: 40),
      );
      await r.session.start(_tap());
      await r.steady();
      r.alive = false;
      r.session.poll();
      await r.settle();
      r.alive = true;
      await r.session.start(_tap(sec: 9));
      await r.steady(sec: 2000);
      r.alive = false;
      r.session.poll();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(r.failIds, hasLength(2));
      expect(r.failIds.toSet(), hasLength(2), reason: 'each gesture its own id');
    });
  });

  group('fallback ON (the default): the double-tap action runs', () {
    for (final f in _failures) {
      test('${_name(f)}: ends with count 2 and the reason, no retry',
          () async {
        final r = _Rig(begins: const [true]);
        await r.session.start(_tap());
        await f.drive(r);
        expect(r.results, [(2, 'fallback: ${f.reason}')]);
        expect(r.began, 1, reason: 'no second stream start');
        expect(r.session.active, isFalse);
        expect(r.ended, 1, reason: 'the stream is stopped');
        expect(r.records, hasLength(1), reason: 'the interval is still written');
        expect(
            r.steps,
            contains('ECG failed (${f.reason}). Fallback: the count is 2 '
                '(double-tap action).'));
        expect(r.failIds, hasLength(1));
      });
    }

    test('the stream refusing to start does not throw: count 2', () async {
      final r = _Rig(begins: const [false]);
      await r.session.start(_tap()); // must not throw
      expect(r.results, [(2, 'fallback: start_failed')]);
      expect(r.began, 1);
      expect(r.ended, 0, reason: 'nothing was started, nothing to stop');
      expect(r.session.active, isFalse);
      expect(r.failIds, hasLength(1));
      expect(r.steps,
          contains('ECG failed (start_failed). Fallback: the count is 2 '
              '(double-tap action).'));
    });

    test('the stream start throwing does not throw either', () async {
      final r = _Rig(begins: [StateError('radio went away')]);
      await r.session.start(_tap());
      expect(r.results, [(2, 'fallback: start_failed')]);
      expect(r.session.active, isFalse);
      expect(r.failIds, hasLength(1));
    });

    test('the stream start timing out does not throw; the late stream is '
        'stopped', () async {
      final r = _Rig(begins: [Completer<bool>()]);
      await r.session.start(_tap());
      expect(r.results, [(2, 'fallback: start_failed')]);
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
    });

    test('a failure after tap 3 was counted is abandoned, not a double tap',
        () async {
      final r = _Rig(max: 5);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_pkt(1002, _moving())); // count 3
      await r.settle();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.results, [(null, 'link_lost')]);
      expect(r.failIds, hasLength(1));
      expect(r.began, 1);
    });

    test('a count of 2 that was decided normally is not a fallback', () async {
      final r = _Rig(max: 3);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_pkt(1002, _flat()));
      await r.settle();
      expect(r.results, [(2, null)]);
    });
  });

  group('fallback OFF: one retry before the window opened', () {
    test('link lost before the window: stop, start again once, same gesture',
        () async {
      final r = _Rig(th: _fallbackOff);
      final tap = _tap();
      await r.session.start(tap);
      final gen = r.session.generation;
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.log, ['begin', 'end', 'begin'],
          reason: 'the stream is stopped, then started again');
      expect(r.began, 2);
      expect(r.session.active, isTrue, reason: 'still the same gesture');
      expect(r.results, isEmpty, reason: 'nothing is reported while retrying');
      expect(r.failIds, isEmpty, reason: 'no failure buzz for a retried try');
      expect(r.session.generation, gen);
      expect(r.started, hasLength(1), reason: 'one lab session');
      expect(r.steps,
          contains('ECG failed (link_lost); trying the ECG once more.'));
    });

    test('active stays true while the retry is still starting', () async {
      final gate = Completer<bool>();
      final r = _Rig(th: _fallbackOff, begins: [true, gate]);
      await r.session.start(_tap());
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.began, 2);
      expect(r.session.active, isTrue);
      expect(r.results, isEmpty);
      r.alive = true;
      gate.complete(true);
      await r.settle();
      expect(r.session.active, isTrue);
      expect(r.results, isEmpty);
    });

    test('the retry can succeed: the gesture counts as if nothing happened, '
        'with no failure buzz', () async {
      final r = _Rig(th: _fallbackOff);
      await r.session.start(_tap());
      r.alive = false;
      r.session.poll();
      await r.settle();
      r.alive = true;
      await r.steady(sec: 2000);
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_pkt(2002, _moving()));
      await r.settle();
      expect(r.results, [(3, null)]);
      expect(r.failIds, isEmpty);
      expect(r.began, 2);
    });

    test('a second failure ends it abandoned, with the failure buzz',
        () async {
      final r = _Rig(th: _fallbackOff);
      await r.session.start(_tap());
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.session.active, isTrue);
      r.session.poll(); // still not alive: the retry's stream is gone too
      await r.settle();
      expect(r.results, [(null, 'link_lost')]);
      expect(r.began, 2, reason: 'only one retry');
      expect(r.session.active, isFalse);
      expect(r.failIds, hasLength(1));
      expect(r.steps.where((s) => s.contains('trying the ECG once more')),
          hasLength(1));
    });

    test('no_stream is retried once too, then abandoned', () async {
      final r = _Rig(th: _fallbackOff);
      await r.session.start(_tap());
      r.now = _t0.add(const Duration(seconds: 21));
      r.session.poll();
      await r.settle();
      expect(r.began, 2);
      expect(r.session.active, isTrue);
      expect(r.results, isEmpty);
      // The retry's stream does not deliver either, 21 s later.
      r.now = _t0.add(const Duration(seconds: 43));
      r.session.poll();
      await r.settle();
      expect(r.results, [(null, 'no_stream')]);
      expect(r.began, 2);
      expect(r.failIds, hasLength(1));
    });

    test('the stream refusing to start is retried once; the second refusal '
        'throws as before, abandoned, with the failure buzz', () async {
      final r = _Rig(th: _fallbackOff, begins: const [false, false]);
      await expectLater(r.session.start(_tap()), throwsStateError);
      await r.settle();
      expect(r.began, 2);
      expect(r.results, [(null, 'start_failed')]);
      expect(r.session.active, isFalse);
      expect(r.failIds, hasLength(1));
      expect(r.failIds.single, endsWith(':failed'));
    });

    test('the stream start throwing twice is the same', () async {
      final r = _Rig(
          th: _fallbackOff,
          begins: [StateError('radio went away'), StateError('and again')]);
      await expectLater(r.session.start(_tap()), throwsStateError);
      await r.settle();
      expect(r.began, 2);
      expect(r.results, [(null, 'start_failed')]);
      expect(r.failIds, hasLength(1));
    });

    test('a refused start that works the second time carries on: start '
        'returns, the gesture is live, no failure buzz', () async {
      final r = _Rig(th: _fallbackOff, begins: const [false, true]);
      await r.session.start(_tap());
      expect(r.began, 2);
      expect(r.session.active, isTrue);
      expect(r.results, isEmpty);
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_pkt(1002, _moving()));
      await r.settle();
      expect(r.results, [(3, null)]);
      expect(r.failIds, isEmpty);
    });

    test('a start that threw once and works the second time carries on',
        () async {
      final r = _Rig(
          th: _fallbackOff, begins: [StateError('radio went away'), true]);
      await r.session.start(_tap());
      expect(r.began, 2);
      expect(r.session.active, isTrue);
      expect(r.results, isEmpty);
      expect(r.failIds, isEmpty);
    });
  });

  group('fallback OFF: no retry once the window opened', () {
    for (final f in _failures.where((f) => f.afterWindow)) {
      test('${_name(f)}: abandoned at once, one stream start, failure buzz',
          () async {
        final r = _Rig(th: _fallbackOff);
        await r.session.start(_tap());
        await f.drive(r);
        expect(r.results, [(null, f.reason)]);
        expect(r.began, 1);
        expect(r.session.active, isFalse);
        expect(r.failIds, hasLength(1));
        expect(r.steps.where((s) => s.contains('trying the ECG once more')),
            isEmpty);
      });
    }

    test('a failure after tap 3 was counted: abandoned, failure buzz, no '
        'retry', () async {
      final r = _Rig(max: 5, th: _fallbackOff);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_pkt(1002, _moving()));
      await r.settle();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.results, [(null, 'link_lost')]);
      expect(r.began, 1);
      expect(r.failIds, hasLength(1));
    });
  });

  group('nothing is sticky between gestures (AGENTS 4.3)', () {
    test('fallback on: every failed gesture buzzes its own failure and falls '
        'back', () async {
      final r = _Rig(begins: const [true]);
      for (var k = 0; k < 3; k++) {
        r.alive = true;
        r.log.clear();
        await r.session.start(_tap(sec: k * 10));
        r.alive = false;
        r.session.poll();
        await r.settle();
      }
      expect(r.results, [for (var k = 0; k < 3; k++) (2, 'fallback: link_lost')]);
      expect(r.failIds, hasLength(3));
      expect(r.failIds.toSet(), hasLength(3));
    });

    test('fallback off: the retry counter and the failed-buzz flag reset for '
        'each gesture', () async {
      final r = _Rig(th: _fallbackOff);
      for (var k = 0; k < 2; k++) {
        r.alive = true;
        await r.session.start(_tap(sec: k * 10));
        r.alive = false;
        r.session.poll(); // pre-window: retried
        await r.settle();
        r.session.poll(); // the retry fails too: abandoned
        await r.settle();
        expect(r.session.active, isFalse, reason: 'gesture $k');
      }
      expect(r.began, 4, reason: 'one retry per gesture, not one in total');
      expect(r.results, [(null, 'link_lost'), (null, 'link_lost')]);
      expect(r.failIds, hasLength(2));
      expect(r.failIds.toSet(), hasLength(2));
    });

    test('a retried gesture that then succeeds leaves no flag behind: the '
        'next gesture\'s failure still buzzes', () async {
      // Gesture 1: refused, retried, works. Gesture 2: refused twice.
      final r = _Rig(th: _fallbackOff, begins: const [false, true, false, false]);
      await r.session.start(_tap());
      await r.steady();
      r.now = _t0.add(const Duration(seconds: 2));
      r.session.onFrame(_pkt(1002, _moving()));
      await r.settle();
      expect(r.results, [(3, null)]);
      expect(r.failIds, isEmpty);
      await expectLater(r.session.start(_tap(sec: 10)), throwsStateError);
      await r.settle();
      expect(r.began, 4, reason: 'gesture 2 got its own single retry');
      expect(r.results.last, (null, 'start_failed'));
      expect(r.failIds, hasLength(1));
    });
  });
}
