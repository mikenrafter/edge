// Gesture area: the plumbing between the gesture sessions and
// the rest of the app, read through behaviour: settings the sessions read
// live (thresholds, repeat window), the session's strap-clock interval written
// to the database, the ECG controller's frame fan-out, and the Device
// lab's "ECG is busy" test that asks the gesture session. These are the
// callbacks a GestureController will need from AppState. Passes before and
// after the move.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'app_state_gesture_wiring.db';

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
  Future<GestureRig> newRig({bool mg = true}) async {
    order = <String>[];
    channel = ActionChannel(order: order);
    addTearDown(channel.dispose);
    final rig = GestureRig(mg: mg, order: order);
    addTearDown(rig.dispose);
    await rig.measureCues();
    return rig;
  }

  group('settings the sessions read live', () {

    test('the repeat window in force is the one the session opens', () async {
      final rig = await newRig(mg: false);
      await mapActions(rig.app, [2, 3]);
      await rig.app.gestureSettings.setRepeatTapWindowMs(1250);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty,
          within: const Duration(seconds: 8));
      await until(
          () => labText(rig).contains('More double taps | window 1250 ms'));
      expect(labText(rig), contains('More double taps | window 1250 ms'));
    });

  });

  group('the ECG controller\'s frame fan-out', () {
    test('the controller built over the engine has its onFrame wired; a '
        'packet with no gesture running is ignored without effect', () async {
      final rig = await newRig();
      final ecg = rig.app.ecg;
      expect(ecg.onFrame, isNotNull);
      final before = labText(rig).replaceFirst(RegExp(r'Copied [^\n]*'), '');
      expect(() => ecg.onFrame!(presencePacket(1000, presence: true)),
          returnsNormally);
      await settleMs(50);
      expect(labText(rig).replaceFirst(RegExp(r'Copied [^\n]*'), ''), before);
    });
  });

  group('the Device lab asks the gesture session whether ECG is busy', () {

    test('and false while the ECG screen\'s own reading holds the stream',
        () async {
      final rig = await newRig();
      await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
      expect(rig.app.hardwareProbes.canRunEcg, isTrue);
      final reading = rig.app.ecg.begin(EcgWrist.left);
      await until(() => rig.app.ecg.isCapturing);
      expect(rig.app.hardwareProbes.canRunEcg, isFalse);
      await rig.app.ecg.cancel();
      await reading;
    });
  });
}
