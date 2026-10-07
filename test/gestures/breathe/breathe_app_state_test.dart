// The Breathing exercise gesture through AppState (RED): a real strap double
// tap on a fake gen5 link, the real dispatcher, claims over sqflite_ffi and
// the real BreathingController. Pins the wiring (AGENTS 4.7: a capability
// wired into one call path but not all N):
//   * AppState's in-app slot handler routes `breathe` to the toggle (today it
//     answers "in-app with no handler" and the gesture FAILS);
//   * the slot's own pattern and length reach the controller as the session's
//     pattern and target;
//   * the second tap ends the session (also one the screen started);
//   * AppState.dispose and a link drop end the pacing and clear the latch.
// Real timers here, so the sessions stay short of their first phase boundary
// except where a test says so; the cue-by-cue timing is in breath_pacer_test.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/device_action.dart';

import '../../support/app_state_gesture_harness.dart';
import '../../support/app_state_workout_harness.dart' show PlatformSpies;

const _db = 'breathe_app_state.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    await resetGesturePrefs();
    spies = PlatformSpies();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });
  tearDown(() async {
    await settleMs(400); // the rig's device-row and haptic-ack writes
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    spies.dispose();
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  Future<GestureRig> rig({
    String pattern = 'box',
    int minutes = 1,
    Set<DeviceAction> onDouble = const {DeviceAction.breathe},
  }) async {
    final r = GestureRig(mg: false);
    addTearDown(r.dispose);
    await r.measureCues();
    final g = r.app.gestureSettings;
    await g.setDoubleTapActions(onDouble);
    await g.setBreathePatternFor('double', pattern);
    await g.setBreatheMinutesFor('double', minutes);
    return r;
  }

  test('a double tap starts a paced session with the slot\'s pattern and '
      'length; the next double tap ends it', () async {
    final r = await rig(pattern: 'four_seven_eight', minutes: 5);
    r.doubleTap();
    await until(() => r.app.breathingActive, what: 'the session starts');
    expect(r.app.breathingPattern.key, 'four_seven_eight');
    expect(r.app.breathingTarget, const Duration(minutes: 5));
    expect(r.app.breathingPacedByBand, isTrue);
    expect(r.app.breathPacer.running, isTrue);
    await settleMs(150);
    r.doubleTap();
    await until(() => !r.app.breathingActive, what: 'the session ends');
    expect(r.app.breathPacer.running, isFalse);
    expect(r.app.breathingPacedByBand, isFalse);
  });

  test('the gesture is reported as ran, not as a failed gesture ("breathe: '
      'StateError: ... in-app with no handler")', () async {
    final r = await rig();
    r.doubleTap();
    // Wait for the outcome rather than a fixed time: under suite load the
    // dispatch took longer than 400 ms and the test flaked.
    await until(() => r.app.breathingActive, what: 'the session starts');
    await settleMs(150); // a failure would be recorded by now
    expect(r.app.gestureFailures.all, isEmpty);
    expect(r.app.breathingActive, isTrue);
  });

  test('a session the screen started is ended by the gesture', () async {
    final r = await rig();
    await r.app.startBreathingSession();
    expect(r.app.breathingActive, isTrue);
    expect(r.app.breathingPacedByBand, isFalse);
    r.doubleTap();
    await until(() => !r.app.breathingActive, what: 'the gesture stops it');
    expect(r.app.breathPacer.running, isFalse);
  });

  test('AppState.dispose ends the pacing and clears the latch', () async {
    final r = await rig();
    r.doubleTap();
    await until(() => r.app.breathPacer.running, what: 'pacing armed');
    await r.dispose();
    expect(r.app.breathPacer.running, isFalse);
    expect(r.app.breathingPacedByBand, isFalse);
  });

  test('the link dropping ends the pacing: not running, latch clear, the '
      'session ended', () async {
    final r = await rig();
    r.engine.onState(r.engine.state); // the app has seen "connected"
    r.doubleTap();
    await until(() => r.app.breathPacer.running, what: 'pacing armed');
    r.engine.state.connection = 'disconnected';
    r.engine.onState(r.engine.state);
    await until(() => !r.app.breathPacer.running, what: 'pacing ended');
    expect(r.app.breathingPacedByBand, isFalse);
    expect(r.app.breathingActive, isFalse);
  });
}
