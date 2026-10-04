// How GestureDispatcher uses the repeated-double-tap method. The ECG route is
// pinned in test/phase8/ecg_tap_runtime_test.dart; this pins the new route and
// the choice between the two.
//
//  * A single double tap is only delayed when some 3-5 slot is mapped.
//  * Later double taps inside the window return nothing; the FIRST call
//    completes with the actions of the final count.
//  * Only live taps count.
//  * The method is chosen per band: ECG on an MG unless the user picked double
//    taps; double taps on every band without ECG.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('openstrap/device_actions');

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _tap({int sec = 0, Duration late = const Duration(seconds: 1)}) {
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

Future<GestureSettings> _boot(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

/// 2 taps -> log water, 3 taps -> mark moment, 4 taps -> workout toggle.
Future<GestureSettings> _mapped({
  bool three = true,
  bool four = true,
  Map<String, Object> prefs = const {},
}) async {
  final s = await _boot(prefs);
  await s.setDoubleTapActions({DeviceAction.logWater});
  if (three) await s.setActionsForTaps(3, {DeviceAction.markMoment});
  if (four) await s.setActionsForTaps(4, {DeviceAction.workoutToggle});
  return s;
}

class _Rig {
  _Rig(this.settings, {this.mg = false}) {
    repeat = DoubleTapRepeatSession(
      maxTaps: () => settings.repeatTapMax,
      window: () => settings.repeatTapWindow,
      buzz: (id) async {
        buzzes.add(id);
        return true;
      },
      step: steps.add,
      onFinished: finished.add,
    );
    dispatcher = GestureDispatcher(
      settings: settings,
      performNative: (_) async => true,
      claim: (k) async => claims.add(k),
      release: (k) async => claims.remove(k),
      ecgSupported: () => mg,
      onEcgTap: (e) async => labStarts.add(e),
      onCountTaps: (e) async {
        ecgCounted.add(e);
        return 2;
      },
      repeatSession: repeat,
      onLogWater: (e) async => ran.add('water'),
      onMarkMoment: (e) async => ran.add('moment'),
      onWorkoutToggle: (e) async => ran.add('workout'),
    );
  }

  final GestureSettings settings;
  bool mg;
  late final DoubleTapRepeatSession repeat;
  late final GestureDispatcher dispatcher;
  final Set<String> claims = {};
  final ran = <String>[];
  final buzzes = <String>[];
  final steps = <String>[];
  final finished = <int>[];
  final labStarts = <StrapEvent>[];
  final ecgCounted = <StrapEvent>[];

  List<GestureOutcome>? first;

  void tap(StrapEvent e) => dispatcher.handle(e).then((o) => first = o);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('no ECG on the band: repeated double taps', () {
    test('with a 3-5 slot mapped, a single double tap waits out the window',
        () async {
      final s = await _mapped();
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        async.elapse(const Duration(milliseconds: 2499));
        expect(r.ran, isEmpty);
        expect(r.first, isNull);
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(r.ran, ['water']);
        expect(r.first!.single.status, GestureStatus.ran);
        expect(r.first!.single.taps, 2,
            reason: '8AK: the session confirms a count of 2 itself, so the '
                '8H ack stays out');
        expect(r.ecgCounted, isEmpty);
        expect(r.buzzes, isEmpty);
      });
    });

    test('with NO 3-5 slot mapped the single double tap runs at once',
        () async {
      final s = await _mapped(three: false, four: false);
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        async.flushMicrotasks();
        expect(r.ran, ['water']);
        expect(r.repeat.open, isFalse);
      });
    });

    test('two double taps run the 3-slot action once the window ends', () async {
      final s = await _mapped();
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        async.elapse(const Duration(milliseconds: 800));
        List<GestureOutcome>? second;
        r.dispatcher.handle(_tap(sec: 1)).then((o) => second = o);
        async.flushMicrotasks();
        expect(second, isEmpty, reason: 'only the first call reports');
        expect(r.buzzes, hasLength(1));
        expect(r.ran, isEmpty);
        async.elapse(const Duration(milliseconds: 2500));
        async.flushMicrotasks();
        expect(r.ran, ['moment']);
        expect(r.first!.single.taps, 3);
        expect(r.claims,
            contains('gesture:${_tap().identity}:t3:${DeviceAction.markMoment.id}'));
      });
    });

    test('three double taps reach the mapped max and run at once', () async {
      final s = await _mapped(four: false); // max mapped is 3
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        async.elapse(const Duration(milliseconds: 300));
        r.dispatcher.handle(_tap(sec: 1));
        async.flushMicrotasks();
        expect(r.ran, ['moment'], reason: 'no waiting for the window');
        expect(r.repeat.open, isFalse);
      });
    });

    test('a late tap inside the window is not counted and runs the stale rules',
        () async {
      final s = await _mapped();
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        List<GestureOutcome>? late;
        r.dispatcher
            .handle(_tap(sec: 1, late: const Duration(minutes: 5)))
            .then((o) => late = o);
        async.flushMicrotasks();
        expect(late!.map((o) => o.status), [GestureStatus.skippedStale]);
        expect(r.repeat.count, 2);
        expect(r.buzzes, isEmpty);
        async.elapse(const Duration(milliseconds: 2500));
        async.flushMicrotasks();
        expect(r.ran, ['water']);
      });
    });

    test('a late tap never opens a window', () async {
      final s = await _mapped();
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap(late: const Duration(minutes: 5)));
        async.flushMicrotasks();
        expect(r.repeat.open, isFalse);
        expect(r.first!.map((o) => o.status), [GestureStatus.skippedStale]);
      });
    });

    test('a count nothing is mapped to runs nothing', () async {
      final s = await _mapped(three: false); // 4 mapped, 3 not
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        r.dispatcher.handle(_tap(sec: 1));
        async.elapse(const Duration(milliseconds: 2500));
        async.flushMicrotasks();
        expect(r.ran, isEmpty);
        expect(r.first, isEmpty);
      });
    });

    test('a re-sent first tap opens no second window and runs nothing twice',
        () async {
      final s = await _mapped();
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        r.dispatcher.handle(_tap());
        async.elapse(const Duration(milliseconds: 2500));
        async.flushMicrotasks();
        expect(r.ran, ['water']);
        expect(r.finished, [2]);
      });
    });

    test('the window follows the setting', () async {
      final s = await _mapped();
      await s.setRepeatTapWindowMs(1000);
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        async.elapse(const Duration(milliseconds: 1000));
        async.flushMicrotasks();
        expect(r.ran, ['water']);
      });
    });

    test('the stored choice of ECG does not apply to a band without ECG',
        () async {
      final s = await _mapped(prefs: {'gesture_tap_method': 'ecg'});
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        async.elapse(const Duration(milliseconds: 2500));
        async.flushMicrotasks();
        expect(r.ecgCounted, isEmpty);
        expect(r.ran, ['water']);
      });
    });
  });

  group('WHOOP MG: the user can choose', () {
    test('default is ECG: the touch counter is used, not repeated taps',
        () async {
      final s = await _mapped();
      fakeAsync((async) {
        final r = _Rig(s, mg: true)..tap(_tap());
        async.flushMicrotasks();
        expect(r.ecgCounted, hasLength(1));
        expect(r.repeat.open, isFalse);
      });
    });

    test('choosing double taps uses the window and never the ECG counter',
        () async {
      final s = await _mapped();
      await s.setTapMethod(TapCountMethod.repeat);
      fakeAsync((async) {
        final r = _Rig(s, mg: true)..tap(_tap());
        async.elapse(const Duration(milliseconds: 2500));
        async.flushMicrotasks();
        expect(r.ecgCounted, isEmpty);
        expect(r.ran, ['water']);
      });
    });
  });

  group('the Device lab can try the double-tap method', () {
    test('lab on: taps are counted, no action runs, the result is reported',
        () async {
      final s = await _mapped(three: false, four: false);
      await s.setRepeatTapsLab(true);
      fakeAsync((async) {
        final r = _Rig(s)..tap(_tap());
        async.elapse(const Duration(milliseconds: 500));
        r.dispatcher.handle(_tap(sec: 1));
        r.dispatcher.handle(_tap(sec: 2));
        async.elapse(const Duration(milliseconds: 2500));
        async.flushMicrotasks();
        expect(r.finished, [4]);
        expect(r.ran, isEmpty);
        expect(r.first, isEmpty);
        expect(r.buzzes, hasLength(2));
      });
    });

    test('lab on: a late tap is neither counted nor acted on', () async {
      final s = await _mapped();
      await s.setRepeatTapsLab(true);
      fakeAsync((async) {
        final r = _Rig(s)
          ..tap(_tap(late: const Duration(minutes: 5)));
        async.flushMicrotasks();
        expect(r.repeat.open, isFalse);
        expect(r.ran, isEmpty);
      });
    });
  });
}
