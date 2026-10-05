// 8AJ seam 3 characterization: a strap double tap travels the real path
// (engine event frame -> AppState -> GestureDispatcher -> sessions -> cues) and
// these tests pin which actions and cues fire, and in what order, for each
// route. Must pass before and after the GestureController move.
//
// Routes (decided in GestureDispatcher.handle, wired in AppState):
//  * immediate: a plain double tap runs the 2-tap actions at once; the 8H ack
//    (the confirm cue) follows when one RAN;
//  * repeated double taps (any band without ECG, or by choice): the start cue,
//    one follow-up per added tap, the confirm; the count picks the actions;
//  * ECG touches (WHOOP MG): the same cues from the ECG session, packets
//    through the ECG controller's onFrame;
//  * the two Device-lab benches run nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'split8aj_seam3_dispatch.db';

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
          reason: 'the action first, then the 8H ack (no start / follow-up)');
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

  group('repeated double taps (a band without ECG)', () {
    Future<GestureRig> repeatRig() async {
      final rig = await newRig();
      await mapActions(rig.app, [2, 3, 4, 5]);
      await rig.app.gestureSettings.setRepeatTapWindowMs(1000);
      return rig;
    }

    // Count [n]: the opening tap plus n - 2 more, each sent once the cue before
    // it was written.
    Future<void> tapCount(GestureRig rig, int n) async {
      rig.doubleTap();
      await until(() => rig.cues.isNotEmpty);
      for (var i = 0; i < n - 2; i++) {
        rig.doubleTap();
        await until(() => rig.cues.length >= 2 + i);
      }
      await until(
          () => channel.performed.isNotEmpty && rig.cues.contains('confirm'),
          within: const Duration(seconds: 8));
      await settleMs(150);
    }

    for (final n in [2, 3, 4, 5]) {
      test('count $n: start, ${n - 2} follow-up(s), confirm; the $n-tap '
          'action runs; no extra ack', () async {
        final rig = await repeatRig();
        await tapCount(rig, n);
        expect(channel.performed, [kActionFor[n]!.id]);
        expect(rig.cues, [
          'start',
          for (var i = 0; i < n - 2; i++) 'followUp',
          'confirm',
        ]);
        expect(order.first, 'cue:start');
        expect(order.where((e) => e.startsWith('action:')).length, 1);
        expect(rig.app.gestureFailures.all, isEmpty);
        expect(labText(rig), contains('More double taps'));
      });
    }

    test('the Device lab bench counts to 5 and runs no action', () async {
      final rig = await newRig();
      await mapActions(rig.app, [2, 3]);
      await rig.app.gestureSettings.setRepeatTapWindowMs(1000);
      await rig.app.gestureSettings.setRepeatTapsLab(true);
      rig.doubleTap();
      await until(() => rig.cues.isNotEmpty);
      rig.doubleTap();
      await until(() => rig.cues.length >= 2);
      await until(() => rig.cues.contains('confirm'),
          within: const Duration(seconds: 8));
      await settleMs(300);
      expect(rig.cues, ['start', 'followUp', 'confirm']);
      expect(channel.performed, isEmpty);
      expect(labText(rig), contains('This is a draft; no action was run.'));
    });
  });

  group('ECG touches (WHOOP MG)', () {
    Future<GestureRig> ecgRig() async {
      final rig = await newRig(mg: true);
      await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
      await mapActions(rig.app, [2, 3, 4, 5]);
      return rig;
    }

    for (final n in [2, 3, 4, 5]) {
      test('count $n: start cue, stream start, ${n - 2} follow-up(s), confirm; '
          'the $n-tap action runs', () async {
        final rig = await ecgRig();
        rig.doubleTap();
        await until(() => order.contains('band:generation'));
        await playEcgCount(rig, n);
        await until(() => channel.performed.isNotEmpty,
            within: const Duration(seconds: 8));
        await until(() => rig.cues.contains('confirm'));
        await settleMs(200);
        expect(channel.performed, [kActionFor[n]!.id]);
        expect(rig.cues, [
          'start',
          for (var i = 0; i < n - 2; i++) 'followUp',
          'confirm',
        ]);
        // The start cue goes out before the stream's first command.
        expect(order.first, 'cue:start');
        expect(order.indexOf('band:selectWrist'), greaterThan(0));
        expect(labText(rig), contains('Final count $n'));
        expect(rig.app.gestureFailures.all, isEmpty);
      });
    }

    test('the stream is stopped when the gesture ends (cleanup written)',
        () async {
      final rig = await ecgRig();
      rig.doubleTap();
      await until(() => order.contains('band:generation'));
      await playEcgCount(rig, 2);
      await until(() => channel.performed.isNotEmpty,
          within: const Duration(seconds: 8));
      await settleMs(300);
      final gens = order.where((e) => e == 'band:generation').length;
      expect(gens, 2, reason: 'one START, one STOP');
      expect(rig.app.ecg.isCapturing, isFalse);
    });
  });

  group('ECG touches (WHOOP MG), a stream paced like the band\'s', () {
    test('no finger on the sensor: the stream settles on the wall clock, then '
        'the count is 2 (the plain double tap)', () async {
      final rig = await newRig(mg: true);
      await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
      await mapActions(rig.app, [2, 3]);
      rig.doubleTap();
      await until(() => order.contains('band:generation'));
      // The session waits for a steady stream: packets in step with the
      // clock, one a second, until the touch window has run out.
      for (var i = 0; i < 12 && labCount(rig, 'Final count') == 0; i++) {
        rig.feedEcg(presencePacket(1000 + i));
        await settleMs(1000);
      }
      await until(() => channel.performed.isNotEmpty,
          within: const Duration(seconds: 8));
      await until(() => rig.cues.contains('confirm'));
      expect(channel.performed, ['media_play_pause']);
      expect(rig.cues, ['start', 'confirm']);
      expect(order.where((e) => e == 'band:rawSave').length, 2,
          reason: 'raw-save ON in PREPARE and OFF in CLEANUP');
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  group('ECG route when the stream cannot start', () {
    test('no wrist remembered: start cue, a retry, the failure cue; the '
        'double-tap fallback runs the 2-tap action; one ECG failure is kept',
        () async {
      final rig = await newRig(mg: true);
      await mapActions(rig.app, [2, 3]);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      await until(() => rig.cues.contains('failed'));
      await settleMs(200);
      expect(rig.cues, ['start', 'failed']);
      expect(channel.performed, ['media_play_pause'],
          reason: 'fallback: the count is 2');
      expect(order.contains('band:selectWrist'), isFalse,
          reason: 'nothing was written to the stream');
      final f = rig.app.gestureFailures.all.single;
      expect(f.kind, GestureFailureKind.ecg);
      expect(f.reason, 'start_failed');
      expect(labText(rig), contains('trying the ECG once more'));
      expect(labText(rig), contains('The failure buzz written.'));
    });

    test('the Device lab ECG bench: the stream is started, no action runs, a '
        'failed start is still recorded', () async {
      final rig = await newRig(mg: true);
      await mapActions(rig.app, [2]);
      await rig.app.gestureSettings.setEcgOnDoubleTap(true);
      rig.doubleTap();
      await until(() => rig.cues.contains('failed'));
      await settleMs(300);
      expect(channel.performed, isEmpty,
          reason: 'the lab suspends the mapped actions');
      expect(rig.cues, ['start', 'failed']);
      expect(rig.app.gestureFailures.all.single.kind, GestureFailureKind.ecg);
    });
  });
}
