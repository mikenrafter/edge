// 8AJ seam 3: what is still in flight when AppState is disposed. A gesture's
// slow parts (a native action that answers late, the cue load, the ECG
// post-roll) must not act for an app that is gone: no confirm buzz, and the
// ECG stream is stopped and its lease released at once, not after the lab's
// 3 s watch.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/ecg_tap_mode.dart';

import 'support/gesture_harness.dart';

const _db = 'split8aj_seam3_dispose_races.db';

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

  group('the tap acknowledgement', () {
    test('an action that finishes after dispose buzzes nothing', () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      channel.hold = Completer<void>();
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      await rig.dispose();
      channel.hold!.complete(); // the action answers: it ran
      await settleMs(600);
      expect(rig.cues, isEmpty, reason: 'no ack for a tap whose app is gone');
    });

    test('an action that finishes in time still gets its ack (the guard is '
        'not a mute)', () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      rig.doubleTap();
      await until(() => rig.cues.isNotEmpty);
      expect(rig.cues, ['confirm']);
    });

    test('an app disposed while the cue assignments load buzzes nothing',
        () async {
      final rig = await newRig();
      expect(rig.app.haptics.profile, isNotNull,
          reason: 'the load only happens with a haptic profile');
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      // The lab entry is written right before the cue load starts: dispose
      // from its listener, so the load resumes into a disposed app.
      void disposeOnEntry() {
        if (rig.app.deviceLab.entries.isNotEmpty) {
          rig.app.deviceLab.removeListener(disposeOnEntry);
          rig.dispose();
        }
      }

      rig.app.deviceLab.addListener(disposeOnEntry);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      await settleMs(600);
      expect(rig.app.deviceLab.entries, isNotEmpty,
          reason: 'the tap reached the entry, so the dispose ran');
      expect(rig.cues, isEmpty);
    });
  });

  group('the ECG post-roll', () {
    test('dispose during the lab post-roll stops the stream at once, once, '
        'and the lease is free again', () async {
      final rig = await newRig(mg: true);
      await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
      await rig.app.gestureSettings.setEcgTapMode(EcgTapMode.fast);
      await rig.app.gestureSettings.setEcgOnDoubleTap(true);
      int stops() => order.where((o) => o == 'band:generation').length;
      rig.doubleTap();
      await until(() => order.contains('band:generation'));
      await playEcgCount(rig, 2);
      await until(() => labCount(rig, 'Keeping the stream on') > 0,
          within: const Duration(seconds: 8));
      expect(stops(), 1, reason: 'only the start so far: the stream is kept on');
      await rig.dispose();
      await until(() => stops() == 2, within: const Duration(seconds: 1));
      await settleMs(300);
      expect(stops(), 2, reason: 'stopped once, long before the 3 s end');
      expect(rig.app.ecg.isCapturing, isFalse);
    });
  });
}
