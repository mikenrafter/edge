// 8AJ seam 3 characterization: notifyListeners counts. A gesture today never
// ticks AppState itself, whatever route it takes and however it ends: the
// screens that care listen to the settings object, the failures store, the
// Device lab log and the ECG controller instead. These tests count the ticks
// of AppState, GestureSettings and GestureFailureStore around each kind of
// gesture, so a controller that starts calling AppState's notify callback (or
// stops notifying its own store) fails here. Passes before and after the
// GestureController move.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/ecg_tap_mode.dart';

import 'support/gesture_harness.dart';

class _Ticks {
  _Ticks(GestureRig rig)
      : app = TickCounter(rig.app),
        _rig = rig {
    rig.app.gestureSettings.addListener(_settings);
    rig.app.gestureFailures.addListener(_failures);
    rig.app.deviceLab.addListener(_lab);
  }
  final TickCounter app;
  final GestureRig _rig;
  int settings = 0, failures = 0, lab = 0;
  void _settings() => settings++;
  void _failures() => failures++;
  void _lab() => lab++;
  void stop() {
    app.stop();
    _rig.app.gestureSettings.removeListener(_settings);
    _rig.app.gestureFailures.removeListener(_failures);
    _rig.app.deviceLab.removeListener(_lab);
  }
}

const _db = 'split8aj_seam3_notify.db';

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
  Future<GestureRig> newRig({bool mg = false, bool ok = true}) async {
    order = <String>[];
    channel = ActionChannel(order: order, ok: ok);
    addTearDown(channel.dispose);
    final rig = GestureRig(mg: mg, order: order);
    addTearDown(rig.dispose);
    await rig.measureCues();
    return rig;
  }

  test('an immediate double tap that ran: AppState 0, settings 0, failures 0',
      () async {
    final rig = await newRig();
    await rig.app.gestureSettings
        .setDoubleTapActions({DeviceAction.mediaPlayPause});
    final t = _Ticks(rig);
    rig.doubleTap();
    await until(() => rig.cues.isNotEmpty);
    await settleMs(400);
    expect((t.app.ticks, t.settings, t.failures), (0, 0, 0));
    expect(t.lab, greaterThan(0), reason: 'the Device lab log hears the tap');
    t.stop();
  });

  test('a failed action: AppState 0, the failures store 1', () async {
    final rig = await newRig(ok: false);
    await rig.app.gestureSettings
        .setDoubleTapActions({DeviceAction.mediaPlayPause});
    final t = _Ticks(rig);
    rig.doubleTap();
    await until(() => rig.app.gestureFailures.all.isNotEmpty);
    await settleMs(400);
    expect((t.app.ticks, t.settings, t.failures), (0, 0, 1));
    t.stop();
  });

  test('a repeated-double-tap gesture (count 3): AppState 0, failures 0',
      () async {
    final rig = await newRig();
    await mapActions(rig.app, [2, 3]);
    await rig.app.gestureSettings.setRepeatTapWindowMs(1000);
    final t = _Ticks(rig);
    rig.doubleTap();
    await until(() => rig.cues.isNotEmpty);
    rig.doubleTap();
    await until(
        () => channel.performed.isNotEmpty && rig.cues.contains('confirm'),
        within: const Duration(seconds: 8));
    await settleMs(400);
    expect((t.app.ticks, t.settings, t.failures), (0, 0, 0));
    expect(t.lab, greaterThan(0));
    t.stop();
  });

  test('an ECG gesture that counted 3: AppState 0, failures 0', () async {
    final rig = await newRig(mg: true);
    await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
    await mapActions(rig.app, [2, 3]);
    await rig.app.gestureSettings.setEcgTapMode(EcgTapMode.fast);
    final t = _Ticks(rig);
    rig.doubleTap();
    await until(() => order.contains('band:generation'));
    await playEcgCount(rig, 3);
    await until(() => channel.performed.isNotEmpty,
        within: const Duration(seconds: 8));
    await settleMs(400);
    expect((t.app.ticks, t.settings, t.failures), (0, 0, 0));
    t.stop();
  });

  test('an ECG gesture that could not start (fallback): AppState 0, '
      'failures 1', () async {
    final rig = await newRig(mg: true);
    await mapActions(rig.app, [2, 3]);
    final t = _Ticks(rig);
    rig.doubleTap();
    await until(() => channel.performed.isNotEmpty);
    await settleMs(400);
    expect((t.app.ticks, t.settings, t.failures), (0, 0, 1));
    t.stop();
  });

  test('a gesture setting changed: the settings object ticks, AppState does '
      'not', () async {
    final rig = await newRig();
    final t = _Ticks(rig);
    await rig.app.gestureSettings.setDoubleTapActions({DeviceAction.torch});
    await rig.app.gestureSettings.setEcgTapMode(EcgTapMode.fast);
    await rig.app.gestureSettings.setRepeatTapWindowMs(1500);
    await settleMs(100);
    expect((t.app.ticks, t.settings, t.failures), (0, 3, 0));
    t.stop();
  });

  test('a failure dismissed: the store ticks, AppState does not', () async {
    final rig = await newRig(ok: false);
    await rig.app.gestureSettings
        .setDoubleTapActions({DeviceAction.mediaPlayPause});
    rig.doubleTap();
    await until(() => rig.app.gestureFailures.all.isNotEmpty);
    await settleMs(200);
    final t = _Ticks(rig);
    await rig.app.gestureFailures
        .dismiss(rig.app.gestureFailures.all.single.gestureId);
    expect((t.app.ticks, t.settings, t.failures), (0, 0, 1));
    t.stop();
  });
}
