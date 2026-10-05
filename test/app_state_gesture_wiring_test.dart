// 8AJ seam 3 characterization: the plumbing between the gesture sessions and
// the rest of the app, read through behaviour: settings the sessions read
// live (thresholds, repeat window), the session's strap-clock interval written
// to the database (8N), the ECG controller's frame fan-out, and the Device
// lab's "ECG is busy" test that asks the gesture session. These are the
// callbacks a GestureController will need from AppState. Passes before and
// after the move.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'split8aj_seam3_wiring.db';

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

  Future<List<Map<String, Object?>>> sessionRows() async =>
      (await LocalDb.instance).query('ecg_gesture_session');

  /// The session rows once [ready] accepts them (the row is written after the
  /// gesture's action runs, so it lands in its own time), or whatever is
  /// there when [within] runs out.
  Future<List<Map<String, Object?>>> sessionRowsWhen(
      bool Function(List<Map<String, Object?>>) ready,
      {Duration within = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(within);
    var rows = await sessionRows();
    while (!ready(rows) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      rows = await sessionRows();
    }
    return rows;
  }

  group('settings the sessions read live', () {
    test('the ECG thresholds in force are the ones the session reports', () async {
      final rig = await newRig();
      await mapActions(rig.app, [2, 3]);
      await rig.app.gestureSettings.setEcgTapThresholds(
          EcgTapThresholds(startMs: 500, gapMs: 300, confirmMs: 400));
      rig.doubleTap(); // no wrist remembered: fails to start, session ends
      await until(() => channel.performed.isNotEmpty);
      const line =
          'ECG sensor touches | start 500 ms, gap 300 ms, confirm 400 ms';
      await until(() => labText(rig).contains(line));
      expect(labText(rig), contains(line));
      await sessionRowsWhen((r) => r.isNotEmpty); // its row, before teardown
    });

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

    test('the ECG session\'s count ceiling is the highest mapped count: with '
        'only 3 mapped, the third count ends it at once', () async {
      final rig = await newRig();
      await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
      await mapActions(rig.app, [3]);
      rig.doubleTap();
      await until(() => order.contains('band:generation'));
      // A steady stream with the finger on the sensor.
      await feedEcgOpening(rig.feedEcg);
      await until(() => channel.performed.isNotEmpty,
          within: const Duration(seconds: 8));
      expect(channel.performed, ['media_next']);
      expect(labText(rig), contains('Final count 3'));
      expect(labText(rig), isNot(contains('Packet 4:')),
          reason: 'it stops counting at the most taps anything is set to, '
              'on the packet that settles the sensor');
      await sessionRowsWhen((r) => r.isNotEmpty); // its row, before teardown
    });
  });

  group('the strap-clock interval of a gesture is written (8N)', () {
    test('a counted ECG gesture leaves a counted row', () async {
      final rig = await newRig();
      await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
      await mapActions(rig.app, [2, 3]);
      rig.doubleTap();
      await until(() => order.contains('band:generation'));
      await playEcgCount(rig, 3);
      await until(() => channel.performed.isNotEmpty,
          within: const Duration(seconds: 8));
      await until(() => rig.cues.contains('confirm'));
      final rows = await sessionRowsWhen(
          (r) => r.isNotEmpty && r.first['strap_end'] != null);
      expect(rows, hasLength(1));
      expect(rows.single['final_count'], 3);
      expect(rows.single['outcome'], 'counted');
      expect(rows.single['device_id'], LocalDb.kPrimaryDeviceId);
      expect(rows.single['reason'], isNull);
      expect(rows.single['strap_start'], isNotNull);
      expect(rows.single['strap_end'], isNotNull);
    });

    test('an ECG gesture that could not start leaves an abandoned row with '
        'the reason (and no count, though the action fell back to 2)',
        () async {
      final rig = await newRig();
      await mapActions(rig.app, [2, 3]);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      final rows = await sessionRowsWhen((r) => r.isNotEmpty);
      expect(rows, hasLength(1));
      expect(rows.single['final_count'], isNull);
      expect(rows.single['outcome'], 'abandoned');
      expect(rows.single['reason'], 'start_failed');
    });

    test('a repeated-double-tap gesture writes none (no ECG stream)', () async {
      final rig = await newRig(mg: false);
      await mapActions(rig.app, [2, 3]);
      await rig.app.gestureSettings.setRepeatTapWindowMs(1000);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty,
          within: const Duration(seconds: 8));
      await settleMs(300);
      expect(await sessionRows(), isEmpty);
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
    test('canRunEcg is true when idle, false while a gesture holds the '
        'stream, true again when it ended', () async {
      final rig = await newRig();
      await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
      await mapActions(rig.app, [2, 3]);
      expect(rig.app.hardwareProbes.canRunEcg, isTrue);
      rig.doubleTap();
      await until(() => order.contains('band:generation'));
      expect(rig.app.hardwareProbes.canRunEcg, isFalse);
      await playEcgCount(rig, 2);
      await until(() => channel.performed.isNotEmpty,
          within: const Duration(seconds: 8));
      await until(() => rig.app.hardwareProbes.canRunEcg);
      expect(rig.app.hardwareProbes.canRunEcg, isTrue);
      await sessionRowsWhen((r) => r.isNotEmpty); // its row, before teardown
    });

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
