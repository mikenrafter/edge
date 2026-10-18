// The dispatcher reports a failed action, so the failure record
// has something to store for the plain double-tap and ECG-counted routes. (The
// ECG session's own reporter is in d_failure_hooks_session_test.dart.)
//
// ASSUMED API (lib/gestures/gesture_dispatcher.dart, GestureDispatcher):
//   `void Function(StrapEvent e, GestureFailureKind kind, String reason)?
//   onFailed` (kind from NEW lib/gestures/gesture_failures.dart; read here by
//   its enum name, 'ecg' / 'doubleTap'): once per tap whose mapped action
//   FAILED (a failed outcome: the action threw, answered false or timed out),
//   with kind `ecg` when the tap took the ECG-counting route and `doubleTap`
//   otherwise (immediate or repeated double taps), and a reason that names the
//   action id. Never for an action that ran, a stale skip or a duplicate
//   (those are not failures). The ECG route's own start failures are NOT
//   reported here: the session reports them (the dispatcher only sees "tap
//   counting did not start" and runs the double-tap actions), so one failure
//   is never recorded twice.
//
// Failure mode today: the parameter does not exist (it is passed through
// Function.apply and dropped), so nothing is ever reported.

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('the dispatcher reports a failed action once', () {
    Future<GestureSettings> boot({bool three = false}) async {
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
      return s;
    }

    final fails = <(String, String, String)>[];

    GestureDispatcher make(
      GestureSettings s, {
      bool workoutThrows = false,
      bool mg = false,
      DoubleTapRepeatSession? repeat,
      Future<int?> Function(StrapEvent)? count,
      bool claimOk = true,
    }) {
      final named = <Symbol, dynamic>{
        #settings: s,
        #performNative: (String _) async => true,
        #claim: (String k) async => claimOk,
        #release: (String k) async {},
        #ecgSupported: () => mg,
        #repeatSession: repeat,
        #onCountTaps: count,
        #onWorkoutToggle: (StrapEvent e) async {
          if (workoutThrows) throw StateError('no workout');
        },
        #onMarkMoment: (StrapEvent e) async => throw StateError('no moment'),
        // The kind is an enum of lib/gestures/gesture_failures.dart; it is
        // read by its name ("GestureFailureKind.ecg") so this file needs no
        // import of that library.
        #onFailed: (StrapEvent e, Object k, String reason) =>
            fails.add((e.identity, k.toString().split('.').last, reason)),
      };
      try {
        return Function.apply(GestureDispatcher.new, const [], named)
            as GestureDispatcher;
      } on NoSuchMethodError {
        named.remove(#onFailed);
        return Function.apply(GestureDispatcher.new, const [], named)
            as GestureDispatcher;
      }
    }

    setUp(fails.clear);

    test('an immediate double tap whose action failed: kind double tap, the '
        'action id in the reason', () async {
      final s = await boot();
      final tap = repTap();
      final out = await make(s, workoutThrows: true).handle(tap);
      expect(out.single.status, GestureStatus.failed);
      expect(fails, hasLength(1));
      expect(fails.single.$1, tap.identity);
      expect(fails.single.$2, 'doubleTap');
      expect(fails.single.$3, contains(DeviceAction.workoutToggle.id));
    });

    test('regression guard (passes today): an action that ran is no failure', () async {
      final s = await boot();
      final out = await make(s).handle(repTap());
      expect(out.single.status, GestureStatus.ran);
      expect(fails, isEmpty);
    });

    test('regression guard (passes today): a stale tap is skipped, not failed', () async {
      final s = await boot();
      final out = await make(s)
          .handle(repTap(late: const Duration(minutes: 5)));
      expect(out.single.status, GestureStatus.skippedStale);
      expect(fails, isEmpty);
    });

    test('regression guard (passes today): a duplicate (claim already taken) is '
        'skipped, not failed', () async {
      final s = await boot();
      final out = await make(s, claimOk: false).handle(repTap());
      expect(out.single.status, GestureStatus.skippedDuplicate);
      expect(fails, isEmpty);
    });

    test('a repeated-double-tap gesture whose action failed: kind double tap',
        () async {
      final s = await boot(three: true);
      fakeAsync((async) {
        final repeat = DoubleTapRepeatSession(
          maxTaps: () => s.repeatTapMax,
          window: () => s.repeatTapWindow,
        );
        final d = make(s, workoutThrows: true, repeat: repeat);
        d.handle(repTap());
        async.elapse(const Duration(milliseconds: 2500));
        async.flushMicrotasks();
        expect(fails, hasLength(1));
        expect(fails.single.$2, 'doubleTap');
      });
    });

    test('an ECG-counted gesture whose action failed: kind ECG', () async {
      final s = await boot(three: true);
      await s.setTapMethod(TapCountMethod.ecg);
      final d = make(s, mg: true, count: (e) async => 3);
      final out = await d.handle(repTap());
      expect(out.single.status, GestureStatus.failed);
      expect(fails, hasLength(1));
      expect(fails.single.$2, 'ecg');
      expect(fails.single.$3, contains(DeviceAction.markMoment.id));
    });

    test('regression guard (passes today): an ECG-counted gesture whose count '
        'did not start is the session\'s to report, not the dispatcher\'s (no '
        'double record)', () async {
      final s = await boot(three: true);
      await s.setTapMethod(TapCountMethod.ecg);
      final d = make(s, mg: true, count: (e) async => throw StateError('x'));
      await d.handle(repTap());
      expect(fails, isEmpty);
    });
  });

}
