// 8AJ seam 3 characterization: lifetime of the gesture machinery. Identity of
// the exposed objects, what AppState.dispose does and does not touch in this
// area, timers left behind, listeners, and what a gesture does after dispose.
// Several of these pin TODAY's behaviour even where it looks accidental (the
// gesture sessions are never stopped by AppState.dispose); a GestureController
// that changes one of them must say so. Passes before and after the move.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/ecg_tap_mode.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart' show TapCountMethod;
import 'package:openstrap_edge/state/app_state.dart';

import 'support/gesture_harness.dart';

bool _hasListeners(Listenable n) =>
    // ignore: invalid_use_of_protected_member
    (n as ChangeNotifier).hasListeners;

const _db = 'split8aj_seam3_lifecycle.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    await resetGesturePrefs();
  });
  tearDown(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  late ActionChannel channel;
  late List<String> order;
  Future<GestureRig> newRig({bool mg = false}) async {
    order = <String>[];
    channel = ActionChannel(order: order);
    addTearDown(channel.dispose);
    final rig = GestureRig(mg: mg, order: order);
    addTearDown(rig.dispose);
    await rig.measureCues();
    return rig;
  }

  group('identity', () {
    test('settings, failures store and cues are one object each for the whole '
        'lifetime, dispose included', () async {
      final rig = await newRig();
      final settings = rig.app.gestureSettings;
      final failures = rig.app.gestureFailures;
      final cues = rig.app.gestureCues;
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      rig.doubleTap();
      await until(() => rig.cues.isNotEmpty);
      expect(identical(rig.app.gestureSettings, settings), isTrue);
      expect(identical(rig.app.gestureFailures, failures), isTrue);
      expect(identical(rig.app.gestureCues, cues), isTrue);
      await rig.dispose();
      expect(identical(rig.app.gestureSettings, settings), isTrue);
      expect(identical(rig.app.gestureFailures, failures), isTrue);
      expect(identical(rig.app.gestureCues, cues), isTrue);
    });

    test('two apps share none of them', () {
      final a = AppState.forTesting();
      final b = AppState.forTesting();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      expect(identical(a.gestureSettings, b.gestureSettings), isFalse);
      expect(identical(a.gestureFailures, b.gestureFailures), isFalse);
      expect(identical(a.gestureCues, b.gestureCues), isFalse);
    });
  });

  group('listeners', () {
    test('AppState listens to none of the gesture notifiers, before or after '
        'a gesture', () async {
      final rig = await newRig(mg: true);
      await mapActions(rig.app, [2, 3]);
      bool any() =>
          _hasListeners(rig.app.gestureSettings) ||
          _hasListeners(rig.app.gestureFailures) ||
          _hasListeners(rig.app.deviceLab) ||
          _hasListeners(rig.app.hardwareProbes) ||
          _hasListeners(rig.app.ecg);
      expect(any(), isFalse);
      rig.doubleTap(); // an ECG route that fails to start, then falls back
      await until(() => channel.performed.isNotEmpty);
      await settleMs(300);
      expect(any(), isFalse);
    });

    test('a screen\'s add / remove on the gesture notifiers balances', () async {
      final rig = await newRig();
      void noop() {}
      for (final n in <Listenable>[
        rig.app.gestureSettings,
        rig.app.gestureFailures,
        rig.app.deviceLab,
      ]) {
        n.addListener(noop);
        expect(_hasListeners(n), isTrue);
        n.removeListener(noop);
        expect(_hasListeners(n), isFalse);
      }
    });
  });

  group('dispose', () {
    test('dispose disposes the settings object only: the failures store and '
        'the lab log stay usable', () async {
      final rig = await newRig();
      await rig.dispose();
      void noop() {}
      expect(() => rig.app.gestureSettings.addListener(noop), throwsFlutterError);
      rig.app.gestureFailures.addListener(noop);
      rig.app.gestureFailures.removeListener(noop);
      rig.app.deviceLab.addListener(noop);
      rig.app.deviceLab.removeListener(noop);
      expect(() => rig.app.gestureCues, returnsNormally);
    });

    test('after finished gestures of every route nothing is left running '
        'after dispose (no timers)', () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final order = <String>[];
        final ch = ActionChannel(order: order);
        final rig = GestureRig(mg: true, order: order);
        await rig.measureCues();
        await mapActions(rig.app, [2, 3]);
        await rig.app.gestureSettings.setRepeatTapWindowMs(1000);
        // Immediate route is not available with 3 mapped: use the ECG route
        // (no wrist: fails to start, falls back) then the repeat route.
        rig.doubleTap();
        await until(() => ch.performed.isNotEmpty);
        await rig.app.gestureSettings.setTapMethod(TapCountMethod.repeat);
        await settleMs(300);
        rig.doubleTap();
        await until(() => ch.performed.length == 2,
            within: const Duration(seconds: 8));
        await settleMs(500);
        await rig.dispose();
        await settleMs(500);
        expect(spy.live, isEmpty,
            reason: 'live: ${spy.live.length} of ${spy.created} created');
        ch.dispose();
      });
    });

    test('dispose twice: the only failure is ChangeNotifier\'s own "disposed '
        'more than once" FlutterError', () {
      final app = AppState.forTesting();
      app.dispose();
      Object? thrown;
      try {
        app.dispose();
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<FlutterError>());
    });
  });

  group('TODAY: what is left running when a gesture is in flight at dispose',
      () {
    test('a repeated-double-tap window outlives dispose: its timer is live, '
        'and when it runs out the action still runs and the confirm cue '
        'still plays', () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final order = <String>[];
        final ch = ActionChannel(order: order);
        final rig = GestureRig(mg: false, order: order);
        await rig.measureCues();
        await mapActions(rig.app, [2, 3]);
        await rig.app.gestureSettings.setRepeatTapWindowMs(1000);
        rig.doubleTap();
        await until(() => rig.cues.isNotEmpty);
        await settleMs(150); // the window is armed once the start cue played
        await rig.dispose();
        expect(spy.live, isNotEmpty, reason: 'the window timer is still armed');
        await until(() => ch.performed.isNotEmpty && rig.cues.contains('confirm'),
            within: const Duration(seconds: 8));
        expect(ch.performed, ['media_play_pause']);
        expect(rig.cues, ['start', 'confirm']);
        await settleMs(2500); // the band queue's playback settle
        expect(spy.live, isEmpty, reason: 'and then it drains');
        ch.dispose();
      });
    });

    test('a tap that arrives after dispose still reaches the dispatcher: the '
        'mapped action runs and the ack plays (the engine callbacks outlive '
        'AppState.dispose)', () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      await rig.dispose();
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      await until(() => rig.cues.isNotEmpty);
      expect(channel.performed, ['media_play_pause']);
      expect(rig.cues, ['confirm']);
    });

    // Last on purpose: it leaves the session's timer running.
    test('an ECG session\'s poll timer outlives dispose (nothing stops the '
        'session); it ends on its own at its start timeout, not tested here',
        () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final order = <String>[];
        final ch = ActionChannel(order: order);
        final rig = GestureRig(mg: true, order: order);
        await rig.measureCues();
        await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
        await mapActions(rig.app, [2, 3]);
        await rig.app.gestureSettings.setEcgTapMode(EcgTapMode.fast);
        rig.doubleTap();
        await until(() => order.contains('band:generation'));
        await settleMs(100);
        final before = spy.live.length;
        await rig.dispose();
        await settleMs(800);
        expect(before, greaterThan(0));
        expect(spy.live, isNotEmpty,
            reason: 'the 250 ms poll timer of the session is still running');
        expect(rig.app.gestureFailures.all, isEmpty,
            reason: 'and the gesture has not ended or failed in the meantime');
        expect(ch.performed, isEmpty);
        // Intentionally leaves that timer to expire with the test process: the
        // session ends itself (no_stream) 20 s after its stream command.
      });
    });
  });
}
