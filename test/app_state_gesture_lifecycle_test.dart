// Gesture area: lifetime of the gesture machinery. Identity of
// the exposed objects, what AppState.dispose does and does not touch in this
// area, timers left behind, listeners, and what a gesture does after dispose.
// Dispose stops a gesture in flight (the repeat window, the ECG session) and
// ends the dispatcher: a tap after dispose does nothing.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_gesture_harness.dart';

bool _hasListeners(Listenable n) =>
    // ignore: invalid_use_of_protected_member
    (n as ChangeNotifier).hasListeners;

const _db = 'app_state_gesture_lifecycle.db';

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

  group('a gesture in flight at dispose is stopped', () {
    test('a repeated-double-tap window armed at dispose never fires: no '
        'action, no confirm cue, no pending gesture timer', () async {
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
        await settleMs(2500); // past the window and the band queue's settle
        expect(ch.performed, isEmpty);
        expect(rig.cues, ['start']);
        expect(rig.app.gestureFailures.all, isEmpty);
        expect(spy.live, isEmpty,
            reason: 'live: ${spy.live.length} of ${spy.created} created');
        ch.dispose();
      });
    });

    test('a tap that arrives after dispose is ignored: no action, no ack, no '
        'band write', () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      await rig.dispose();
      final writesBefore = order.length;
      rig.doubleTap();
      await settleMs(800);
      expect(channel.performed, isEmpty);
      expect(rig.cues, isEmpty);
      expect(order.length, writesBefore);
    });

    // Last on purpose: a regression leaves the session's timer running.

  });
}
