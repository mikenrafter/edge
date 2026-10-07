// The IMU lab recorder inside AppState, on the real path: a band double tap
// (engine event frame -> AppState -> dispatcher) begins an armed recording,
// the `imuLab` owner reaches the engine's reconciler (IMU opcode 106 on a gen5
// link, never an opcode from the UI), normal tap actions stay suspended while
// it is armed or running, and the stream is released however it ends.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/models.dart' show DeviceState;
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/imu_recorder.dart';
import 'package:openstrap_edge/gestures/imu_recording.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show Cmd;

import 'support/app_state_gesture_harness.dart';
import 'support/app_state_live_harness.dart' show r21LiveInner, hexOf;

const _db = 'imu_lab_wiring.db';

const _setup = ImuLabSetup(
  kind: ImuRecordingKind.action,
  duration: Duration(seconds: 5),
  label: 'rotate',
);

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
  Future<GestureRig> newRig() async {
    order = <String>[];
    channel = ActionChannel(order: order);
    addTearDown(channel.dispose);
    final rig = GestureRig(mg: false, order: order);
    addTearDown(rig.dispose);
    await rig.measureCues();
    await rig.app.gestureSettings
        .setDoubleTapActions({DeviceAction.mediaPlayPause});
    return rig;
  }

  // The engine's state callback, as it reports a link that was up and went away.
  void linkDropped(GestureRig rig) {
    rig.app.debugFeedEngineState('', DeviceState()..connection = 'connected');
    rig.app.debugFeedEngineState('', DeviceState()..connection = 'disconnected');
  }

  List<int> imuWrites(GestureRig rig) => [
        for (final w in rig.writes)
          if (w.opcode == Cmd.toggleImuMode) w.body[1],
      ];

  test('without a recording armed, a double tap still runs its action',
      () async {
    final rig = await newRig();
    rig.doubleTap();
    await until(() => rig.cues.isNotEmpty);
    expect(channel.performed, ['media_play_pause']);
    expect(rig.app.debugLiveOwners.imuLab, isFalse);
    expect(imuWrites(rig), isEmpty);
  });

  test('armed: nothing is requested until the tap; the tap runs no action, '
      'starts the stream through the owner, and stays quiet', () async {
    final rig = await newRig();
    rig.app.imuLab.arm(_setup);
    expect(rig.app.imuLab.phase, ImuLabPhase.armed);
    await settleMs(50);
    expect(imuWrites(rig), isEmpty, reason: 'arming does not start the stream');
    expect(rig.app.debugLiveOwners.imuLab, isFalse);

    rig.doubleTap();
    await until(() => imuWrites(rig).isNotEmpty);
    expect(rig.app.imuLab.phase, ImuLabPhase.starting);
    expect(rig.app.debugLiveOwners.imuLab, isTrue);
    expect(imuWrites(rig), [1], reason: 'one IMU ON, from the reconciler');
    await settleMs(300);
    expect(channel.performed, isEmpty, reason: 'the tap action is suspended');
    expect(rig.cues, isEmpty, reason: 'no ack or cue for a suspended tap');
    expect(rig.app.gestureFailures.all, isEmpty);
  });

  test('real packets from the live frame path are recorded; Stop releases '
      'the owner and the reconciler turns IMU off', () async {
    final rig = await newRig();
    rig.app.imuLab.arm(_setup);
    rig.doubleTap();
    await until(() => imuWrites(rig).isNotEmpty);
    rig.app.debugOnLiveFrame(
        0x2B, hexOf(r21LiveInner(accelCount: 3, gyroCount: 2)), null);
    await settleMs(5); // the packet stream delivers on a microtask
    expect(rig.app.imuLab.phase, ImuLabPhase.recording);
    // The ready buzz goes out on its own; let it land before the test ends.
    await until(() => rig.cues.isNotEmpty);
    expect(rig.app.imuLab.packetCount, 1);
    rig.app.imuLab.stop();
    expect(rig.app.imuLab.phase, ImuLabPhase.review);
    final p = rig.app.imuLab.recording!.packets.single;
    expect([p.accelSampleCount, p.gyroSampleCount], [3, 2]);
    expect(rig.app.debugLiveOwners.imuLab, isFalse);
    await until(() => imuWrites(rig).length == 2);
    expect(imuWrites(rig), [1, 0]);
  });

  test('the ready cue goes to the band: nothing for an invalid-gyro packet, '
      'one short buzz when valid data arrives, never a second', () async {
    final rig = await newRig();
    rig.app.imuLab.arm(_setup);
    rig.doubleTap();
    await until(() => imuWrites(rig).isNotEmpty);
    // The band's invalid marker: raw -32768 on all three gyro axes.
    rig.app.debugOnLiveFrame(
        0x2B,
        hexOf(r21LiveInner(gx: -32768, gy: -32768, gz: -32768)),
        null);
    await settleMs(200);
    expect(rig.cues, isEmpty, reason: 'data is flowing but not usable');
    expect(rig.app.imuLab.phase, ImuLabPhase.starting);

    rig.app.debugOnLiveFrame(0x2B, hexOf(r21LiveInner(recordIndex: 2)), null);
    await until(() => rig.cues.isNotEmpty);
    expect(rig.cues, ['followUp'],
        reason: 'the short single buzz, not the double of the gesture start');
    rig.app.debugOnLiveFrame(0x2B, hexOf(r21LiveInner(recordIndex: 3)), null);
    await settleMs(300);
    expect(rig.cues, ['followUp']);
    expect(rig.app.imuLab.phase, ImuLabPhase.recording);
    rig.app.imuLab.stop();
    expect(
        rig.app.imuLab.recording!.markers.map((m) => m.kind),
        contains(ImuMarkerKind.gyroReady));
  });

  test('the recording is described: band model, firmware slot, versions',
      () async {
    final rig = await newRig();
    rig.app.imuLab.arm(_setup);
    rig.doubleTap();
    await until(() => imuWrites(rig).isNotEmpty);
    rig.app.imuLab.stop();
    final m = rig.app.imuLab.recording!.meta;
    expect(m.bandModel, 'WHOOP 5.0');
    expect(m.protocolVersion, 'bc7d8d0df706e40a2546ffde4545263f09d0fecb');
    expect(m.label, 'rotate');
    expect(m.kind, ImuRecordingKind.action);
  });

  test('cancel while recording: owner released, actions run again', () async {
    final rig = await newRig();
    rig.app.imuLab.arm(_setup);
    rig.doubleTap();
    await until(() => imuWrites(rig).isNotEmpty);
    rig.app.imuLab.cancel();
    expect(rig.app.debugLiveOwners.imuLab, isFalse);
    await until(() => imuWrites(rig).length == 2);
    rig.doubleTap();
    await until(() => rig.cues.isNotEmpty);
    expect(channel.performed, ['media_play_pause']);
  });

  test('disconnect while recording ends it as disconnected and releases',
      () async {
    final rig = await newRig();
    rig.app.imuLab.arm(_setup);
    rig.doubleTap();
    await until(() => imuWrites(rig).isNotEmpty);
    rig.app.debugOnLiveFrame(0x2B, hexOf(r21LiveInner()), null);
    await settleMs(5);
    await until(() => rig.cues.isNotEmpty); // the ready buzz, let it land
    linkDropped(rig);
    expect(rig.app.imuLab.phase, ImuLabPhase.review);
    expect(rig.app.imuLab.recording!.status, ImuRecordingStatus.disconnected);
    expect(rig.app.imuLab.recording!.packetCount, 1);
    expect(rig.app.debugLiveOwners.imuLab, isFalse);
  });

  test('disconnect while only armed puts the lab back to idle', () async {
    final rig = await newRig();
    rig.app.imuLab.arm(_setup);
    linkDropped(rig);
    expect(rig.app.imuLab.phase, ImuLabPhase.idle);
    rig.doubleTap();
    await until(() => rig.cues.isNotEmpty);
    expect(channel.performed, ['media_play_pause']);
  });

  test('disposing the app mid-recording releases the owner', () async {
    final rig = await newRig();
    rig.app.imuLab.arm(_setup);
    rig.doubleTap();
    await until(() => imuWrites(rig).isNotEmpty);
    final recorder = rig.app.imuLab;
    await rig.dispose();
    expect(recorder.holdsActions, isFalse);
    expect(rig.app.debugLiveOwners.imuLab, isFalse);
  });

  test('the recorder is one object for the whole lifetime', () async {
    final rig = await newRig();
    expect(identical(rig.app.imuLab, rig.app.imuLab), isTrue);
  });
}
