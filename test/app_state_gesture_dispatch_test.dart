// Gesture area: a strap double tap travels the real path
// (engine event frame -> AppState -> GestureDispatcher -> sessions -> cues) and
// these tests pin which actions and cues fire, and in what order, for each
// route.
//
// Routes (decided in GestureDispatcher.handle, wired in AppState):
//  * immediate: a plain double tap runs the 2-tap actions at once; the tap ack
//    (the confirm cue) follows when one RAN;
//  * repeated double taps (any band without ECG, or by choice): the start cue,
//    one follow-up per added tap, the confirm; the count picks the actions;
//  * ECG touches (WHOOP MG): the same cues from the ECG session, packets
//    through the ECG controller's onFrame;
//  * the two Device-lab benches run nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'app_state_gesture_dispatch.db';

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
  Future<GestureRig> newRig({bool mg = false, bool? dev}) async {
    order = <String>[];
    channel = ActionChannel(order: order);
    addTearDown(channel.dispose);
    final rig = GestureRig(mg: mg, dev: dev, order: order);
    addTearDown(rig.dispose);
    await rig.measureCues();
    return rig;
  }

  group('immediate double tap (no 3-5 mapping)', () {
    test('a mapped action runs, then the confirm cue acknowledges it', () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      rig.doubleTap();
      await until(() => rig.cues.isNotEmpty);
      await settleMs(100);
      expect(channel.performed, ['media_play_pause']);
      expect(order, ['action:media_play_pause', 'cue:confirm'],
          reason: 'the action first, then the tap ack (no start / follow-up)');
      expect(rig.app.gestureFailures.all, isEmpty);
    });

    test('several mapped actions run in enum order, one ack for the tap',
        () async {
      final rig = await newRig();
      await rig.app.gestureSettings.setDoubleTapActions(
          {DeviceAction.torch, DeviceAction.mediaPlayPause});
      rig.doubleTap();
      await until(() => rig.cues.isNotEmpty);
      await settleMs(100);
      expect(channel.performed, ['media_play_pause', 'torch']);
      expect(order, [
        'action:media_play_pause',
        'action:torch',
        'cue:confirm',
      ]);
    });

    test('nothing mapped: nothing runs, nothing buzzes, nothing is recorded',
        () async {
      final rig = await newRig();
      rig.doubleTap();
      await settleMs(500);
      expect(order, isEmpty);
      expect(rig.app.gestureFailures.all, isEmpty);
    });

    test('a native action that fails: no ack, one failure naming the action',
        () async {
      final rig = await newRig();
      channel.ok = false;
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      rig.doubleTap();
      await until(() => rig.app.gestureFailures.all.isNotEmpty);
      await settleMs(300);
      expect(channel.performed, ['media_play_pause']);
      expect(rig.cues, isEmpty, reason: 'an ack only follows an action that ran');
      final f = rig.app.gestureFailures.all.single;
      expect(f.kind, GestureFailureKind.doubleTap);
      expect(f.reason, startsWith('media_play_pause:'));
      expect(labText(rig), contains('Gesture failed (media_play_pause:'),
          reason: 'the lab trace says it, so the saved log tells the story');
    });

    test('a tap that reached the phone late is skipped (stale), silently',
        () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      rig.doubleTap(atSec: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120);
      await settleMs(500);
      expect(order, isEmpty);
      expect(rig.app.gestureFailures.all, isEmpty);
    });

    test('the same tap delivered twice runs once (once-ever claim)', () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      rig.doubleTap();
      await until(() => rig.cues.isNotEmpty);
      rig.doubleTap(resend: true);
      await settleMs(400);
      expect(channel.performed, ['media_play_pause']);
      expect(rig.cues, ['confirm']);
    });

    test('on a WHOOP MG with only the 2-tap action mapped it is also '
        'immediate (no counting)', () async {
      final rig = await newRig(mg: true);
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      rig.doubleTap();
      await until(() => rig.cues.isNotEmpty);
      await settleMs(100);
      expect(order, ['action:media_play_pause', 'cue:confirm']);
      expect(order, isNot(contains('band:selectWrist')),
          reason: 'no ECG stream for a plain double tap');
    });
  });

}
