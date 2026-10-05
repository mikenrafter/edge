// 8AJ seam 3: every AppState member in the gesture area is still there with
// its original type, and the shared collaborators the gesture machinery is
// built on keep the identity and behaviour the controller will be handed. The
// annotations are compile-time checks of the public surface. There is no
// @visibleForTesting member in this area: the sessions, the dispatcher, the cue
// helpers and the failure recorder are private, so the tests in this folder
// drive them through a real engine event (see support/gesture_harness.dart).
// Passes before and after the GestureController move.
//
// Public AppState members in scope today:
//   gestureSettings  final GestureSettings          (screens: gestures.dart, device_lab.dart)
//   gestureFailures  late final GestureFailureStore (screens: home_screen.dart, gesture_failures.dart)
//   gestureCues      late final GestureCues
// Shared with other concerns (stay on AppState, the controller is handed them):
//   haptics, alertDispatcher, deviceLab, hardwareProbes, ecg, engine

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/haptics/gesture_cues.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'split8aj_seam3_delegation.db';

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

  test('every member in the gesture area is present with its original type',
      () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final GestureSettings settings = app.gestureSettings;
    final GestureFailureStore failures = app.gestureFailures;
    final GestureCues cues = app.gestureCues;
    final HapticsService haptics = app.haptics;
    final AlertDispatcher dispatcher = app.alertDispatcher;
    final DeviceLabLog lab = app.deviceLab;
    final HardwareProbeRunner probes = app.hardwareProbes;
    final EcgController ecg = app.ecg;
    final BleEngine engine = app.engine;
    expect([settings, failures, cues, haptics, dispatcher, lab, probes, ecg,
      engine], everyElement(isNotNull));
  });

  test('the cues are built over the same haptics service the app delivers '
      'everything else through', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    expect(identical(app.gestureCues.haptics, app.haptics), isTrue);
  });

  test('the settings object is the one the Device lab and the gestures '
      'screen edit and the dispatcher reads: a change is seen by the next tap',
      () async {
    final order = <String>[];
    final ch = ActionChannel(order: order);
    final rig = GestureRig(mg: false, order: order);
    addTearDown(() async {
      await rig.dispose();
      ch.dispose();
    });
    await rig.measureCues();
    rig.doubleTap(); // nothing mapped yet
    await settleMs(300);
    expect(ch.performed, isEmpty);
    await rig.app.gestureSettings.setDoubleTapActions(
        {kActionFor[2]!}); // the screen's own edit
    await settleMs(1100); // a distinct strap second for the next tap
    rig.doubleTap();
    await until(() => ch.performed.isNotEmpty);
    expect(ch.performed, ['media_play_pause']);
  });
}
