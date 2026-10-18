// Rule 4 of the haptic budget, at the gesture dispatch / action seam: when the
// band's haptic limit is already spent as a live gesture starts, the gesture is
// not acted on at all. The wearer must never get an action without its
// confirmation haptic, and every gesture route ends in one (the tap ack after a
// plain double tap, the start / follow-up / confirm cues of a counted one).
//
// New API pinned: `GestureDispatcher(hapticsAvailable: bool Function()?)`.
// Read on EVERY live double tap (so a limit that frees up, or runs out, takes
// effect at once), before any claim is taken. False means: no action runs, no
// claim is taken (a re-send of the same tap can still run once there is room),
// no counting session or ECG capture starts, no start cue is requested, and
// nothing is reported as a failed gesture (it was not attempted). Null (every
// existing caller) is no gate. Events that are not double taps never read it.
//
// Not pinned (ambiguous, see the phase report): a stale tap replayed for Mark
// moment (it plays no haptic), and the Device lab's ECG-on-double-tap bench.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/double_tap_repeat_rig.dart' show repTap;

const _channel = MethodChannel('openstrap/device_actions');

Future<GestureSettings> _boot({bool three = false, bool ecg = false}) async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  await s.setDoubleTapActions({DeviceAction.workoutToggle});
  if (three) await s.setActionsForTaps(3, {DeviceAction.markMoment});
  if (ecg) await s.setTapMethod(TapCountMethod.ecg);
  return s;
}

class _Rig {
  _Rig(this.settings, {this.mg = false, this.open = false}) {
    repeat = DoubleTapRepeatSession(
      maxTaps: () => settings.repeatTapMax,
      window: () => settings.repeatTapWindow,
      startBuzz: (id) async {
        cues.add('start:$id');
        return true;
      },
      buzz: (id) async {
        cues.add('follow:$id');
        return true;
      },
      confirmBuzz: (id) async {
        cues.add('confirm:$id');
        return true;
      },
    );
    dispatcher = GestureDispatcher(
      settings: settings,
      performNative: (_) async => true,
      claim: (k) async => claims.add(k),
      release: (k) async => claims.remove(k),
      ecgSupported: () => mg,
      onCountTaps: (e) async {
        counting.add(e);
        return 3;
      },
      repeatSession: repeat,
      onWorkoutToggle: (e) async => ran.add('workout'),
      onMarkMoment: (e) async => ran.add('moment'),
      onFailed: (e, kind, reason) => failed.add(reason),
      hapticsAvailable: () {
        gateReads++;
        return open;
      },
    );
  }

  final GestureSettings settings;
  final bool mg;

  /// What the gate answers; change it between taps.
  bool open;
  int gateReads = 0;
  late final DoubleTapRepeatSession repeat;
  late final GestureDispatcher dispatcher;
  final claims = <String>{};
  final ran = <String>[];
  final cues = <String>[];
  final failed = <String>[];
  final counting = <StrapEvent>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('a plain double tap (no 3-5 slot mapped)', () {
    test('no haptic budget: no action, no claim, no failure', () async {
      final r = _Rig(await _boot());
      final out = await r.dispatcher.handle(repTap());
      expect(out, isEmpty);
      expect(r.ran, isEmpty, reason: 'the action must not run');
      expect(r.claims, isEmpty, reason: 'and the occurrence is not burned');
      expect(r.failed, isEmpty, reason: 'not attempted, so not failed');
      expect(r.gateReads, greaterThan(0), reason: 'the gate was consulted');
    });

    test('with budget it runs as always (control)', () async {
      final r = _Rig(await _boot(), open: true);
      final out = await r.dispatcher.handle(repTap());
      expect(out.map((o) => o.status), [GestureStatus.ran]);
      expect(r.ran, ['workout']);
      expect(r.claims, hasLength(1));
    });

    test('the gate is read on every tap; the tap that found no room left '
        'nothing behind, so the same tap runs once there is room', () async {
      final r = _Rig(await _boot());
      expect(await r.dispatcher.handle(repTap()), isEmpty);
      expect(r.ran, isEmpty);
      r.open = true;
      final again = await r.dispatcher.handle(repTap());
      expect(again.single.status, GestureStatus.ran);
      expect(r.ran, ['workout']);
      r.open = false;
      expect(await r.dispatcher.handle(repTap(sec: 5)), isEmpty,
          reason: 'and a later tap with the budget gone again is not acted on');
      expect(r.ran, ['workout']);
    });
  });

  group('a counted gesture on an ECG band', () {
    test('no haptic budget: the touch counter does not start (so no start '
        'cue), and no action runs', () async {
      final r = _Rig(await _boot(three: true, ecg: true), mg: true);
      final out = await r.dispatcher.handle(repTap());
      expect(out, isEmpty);
      expect(r.counting, isEmpty, reason: 'no session, no capture, no cue');
      expect(r.ran, isEmpty);
      expect(r.claims, isEmpty);
      expect(r.failed, isEmpty);
    });

    test('with budget it counts and runs the final count\'s action (control)',
        () async {
      final r = _Rig(await _boot(three: true, ecg: true), mg: true, open: true);
      final out = await r.dispatcher.handle(repTap());
      expect(out.single.taps, 3);
      expect(r.counting, hasLength(1));
      expect(r.ran, ['moment']);
    });
  });

  group('a counted gesture by repeated double taps', () {
    test('no haptic budget: no window opens, no start cue is requested, no '
        'action runs, now or later', () async {
      final s = await _boot(three: true);
      fakeAsync((async) {
        final r = _Rig(s);
        List<GestureOutcome>? out;
        r.dispatcher.handle(repTap()).then((o) => out = o);
        async.flushMicrotasks();
        expect(out, isEmpty, reason: 'answered at once, nothing to wait for');
        expect(r.repeat.open, isFalse);
        expect(r.cues, isEmpty, reason: 'no start cue');
        async.elapse(const Duration(seconds: 10));
        expect(r.cues, isEmpty);
        expect(r.ran, isEmpty);
        expect(r.claims, isEmpty);
        expect(r.failed, isEmpty);
      });
    });

    test('with budget the window opens, the start cue is asked for and the '
        'action runs at the end (control)', () async {
      final s = await _boot(three: true);
      fakeAsync((async) {
        final r = _Rig(s, open: true);
        List<GestureOutcome>? out;
        r.dispatcher.handle(repTap()).then((o) => out = o);
        async.flushMicrotasks();
        expect(r.repeat.open, isTrue);
        expect(r.cues.single, startsWith('start:'));
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(out!.single.taps, 2);
        expect(r.ran, ['workout']);
      });
    });

    test('a follow-up tap inside an open window is not blocked by a spent '
        'budget: the gesture has started and runs to its end', () async {
      final s = await _boot(three: true);
      fakeAsync((async) {
        final r = _Rig(s, open: true);
        List<GestureOutcome>? out;
        r.dispatcher.handle(repTap()).then((o) => out = o);
        async.elapse(const Duration(milliseconds: 800));
        r.open = false; // the budget runs out mid-gesture
        r.dispatcher.handle(repTap(sec: 1));
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(out!.single.taps, 3,
            reason: 'the second tap still counted: rule 1 for a started '
                'gesture, the gate only guards its start');
        expect(r.ran, ['moment']);
      });
    });
  });

  group('what is not a gesture', () {
    test('an event that is not a double tap never reads the gate', () async {
      final r = _Rig(await _boot());
      final e = StrapEvent(
        eventId: 7,
        tsEpoch: repTap().tsEpoch,
        receivedAt: repTap().receivedAt,
        hex: '',
        deviceId: 'band',
      );
      expect(await r.dispatcher.handle(e), isEmpty);
      expect(r.gateReads, 0);
    });

    test('no gate (the default) changes nothing', () async {
      final s = await _boot();
      final ran = <String>[];
      final d = GestureDispatcher(
        settings: s,
        performNative: (_) async => true,
        claim: (_) async => true,
        release: (_) async {},
        onWorkoutToggle: (e) async => ran.add('workout'),
      );
      expect((await d.handle(repTap())).single.status, GestureStatus.ran);
      expect(ran, ['workout']);
    });
  });
}
