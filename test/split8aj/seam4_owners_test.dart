// 8AJ seam 4 characterization: the workout and the breathing session / window
// as live-stream OWNERS, what each asks of the engine, and what they hold or
// block elsewhere (the derive warmer, an ECG capture). Driven by the real
// start / stop calls on a fake link, not by assigning the fields. Must pass
// before and after the WorkoutController move.
//
// The callbacks other code takes from this area, as the tests see them:
//   - LiveStreamController: activeWorkoutType() and breathing()
//     (debugLiveOwners.activeWorkout / foregroundGaitWorkout / breathing);
//   - DeriveCoordinator: warmHeld (a live session holds the artifact warmer);
//   - EcgController: busyReason ('workout' beats 'breathing').

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart' show EcgCapturePhase;
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../perf/support/p3_warmer_support.dart';
import 'support/derive_harness.dart' show deriveHook;
import 'support/gesture_harness.dart' show GestureRig;
import 'support/live_harness.dart';
import 'support/workout_harness.dart';

const _db = 'split8aj_seam4_owners.db';
const _hr = Cmd.toggleRealtimeHr;
const _imu = Cmd.toggleImuMode;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    SharedPreferences.setMockInitialValues({});
    spies = PlatformSpies();
  });
  tearDown(() async {
    // Fire-and-forget device-row writes of the fake link settle first.
    await settleMs(300);
    spies.dispose();
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  Future<void> done(G6Rig rig) async {
    await finish(rig.app);
    BleEngine.resetBandClaimForTest();
  }

  group('the workout as a live owner', () {
    test('a non-gait workout owns HR only; stopping releases it', () async {
      final rig = G6Rig();
      rig.app.startWorkout(workoutId: 'w4-o1', type: 'strength');
      await rig.settle();
      final o = rig.app.debugLiveOwners;
      expect(o.activeWorkout, isTrue);
      expect(o.foregroundGaitWorkout, isFalse);
      expect(rig.ops, [(_hr, 1)]);
      rig.writes.clear();
      await rig.app.stopWorkout();
      await rig.settle();
      expect(rig.app.debugLiveOwners.activeWorkout, isFalse);
      expect(rig.ops.where((o) => o.$1 == _hr || o.$1 == _imu).toList(),
          [(_hr, 0)]);
      await done(rig);
    });

    test('a gait workout owns HR and IMU; stopping drops IMU then HR',
        () async {
      final rig = G6Rig();
      rig.app.startWorkout(workoutId: 'w4-o2', type: 'running');
      await rig.settle();
      expect(rig.app.debugLiveOwners.foregroundGaitWorkout, isTrue);
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
      rig.writes.clear();
      await rig.app.stopWorkout();
      await rig.settle();
      expect(rig.ops.where((o) => o.$1 == _hr || o.$1 == _imu).toList(),
          [(_imu, 0), (_hr, 0)]);
      await done(rig);
    });

    test('a delete-teardown of the live workout releases its ownership too',
        () async {
      final rig = G6Rig();
      rig.app.startWorkout(workoutId: 'w4-o3', type: 'running');
      await rig.settle();
      rig.writes.clear();
      await rig.app.deleteWorkout('w4-o3');
      await rig.settle();
      expect(rig.app.debugLiveOwners.activeWorkout, isFalse);
      expect(rig.ops.where((o) => o.$1 == _hr || o.$1 == _imu).toList(),
          [(_imu, 0), (_hr, 0)]);
      await done(rig);
    });

    test('starting a workout clears the sticky standard-HR fallback (an '
        'explicit start is a user action)', () async {
      final rig = G6Rig();
      rig.engine.state.standardHrFallback = true;
      rig.app.startWorkout(workoutId: 'w4-o4', type: 'running');
      await rig.settle();
      expect(rig.engine.state.standardHrFallback, isFalse);
      await done(rig);
    });
  });

  group('breathing as a live owner', () {
    test('a session owns HR for its length and releases it on stop',
        () async {
      final rig = G6Rig();
      await rig.app.startBreathingSession();
      await rig.settle();
      expect(rig.app.debugLiveOwners.breathing, isTrue);
      expect(rig.ops, [(_hr, 1)]);
      rig.writes.clear();
      await rig.app.stopBreathingSession();
      await rig.settle();
      expect(rig.app.debugLiveOwners.breathing, isFalse);
      expect(rig.ops, [(_hr, 0)]);
      await done(rig);
    });

    test('an open quiet window owns HR on its own, and survives the paced '
        'block: stop does not turn the stream off, closing does', () async {
      final rig = G6Rig();
      await rig.app.openBreathingWindow();
      await rig.settle();
      expect(rig.app.debugLiveOwners.breathing, isTrue);
      expect(rig.ops, [(_hr, 1)]);
      await rig.app.startBreathingSession();
      await rig.settle();
      expect(rig.ops, [(_hr, 1)], reason: 'already on: no second write');
      rig.writes.clear();
      await rig.app.stopBreathingSession();
      await rig.settle();
      expect(rig.app.debugLiveOwners.breathing, isTrue,
          reason: 'the window still owns it');
      expect(rig.ops, isEmpty);
      await rig.app.closeBreathingWindow();
      await rig.settle();
      expect(rig.app.debugLiveOwners.breathing, isFalse);
      expect(rig.ops, [(_hr, 0)]);
      await done(rig);
    });

    test('a workout and a breathing session share HR: stopping one keeps '
        'the stream for the other', () async {
      final rig = G6Rig();
      rig.app.startWorkout(workoutId: 'w4-o5', type: 'strength');
      await rig.settle();
      await rig.app.startBreathingSession();
      await rig.settle();
      rig.writes.clear();
      await rig.app.stopBreathingSession();
      await rig.settle();
      expect(rig.ops, isEmpty, reason: 'the workout still owns HR');
      await rig.app.stopWorkout();
      await rig.settle();
      expect(rig.ops.where((o) => o.$1 == _hr).toList(), [(_hr, 0)]);
      await done(rig);
    });
  });

  group('a live session holds the derive warmer (DeriveCoordinator.warmHeld)',
      () {
    Future<(AppState, FakeArtifactSource)> rig(String key) async {
      final src = FakeArtifactSource()
        ..keys = [key]
        ..sigs[key] = 's';
      final app = AppState.forTesting();
      app.debugArtifactSource = src;
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      app.debugDeriveRun = deriveHook(days: ['d1']);
      return (app, src);
    }

    test('a real start holds it; the real stop releases it', () async {
      final (app, src) = await rig('hold-a');
      app.startWorkout(workoutId: 'w4-h1', type: 'strength');
      await app.debugAfterDrain();
      await settleMs(200);
      expect(src.computeStarted, isEmpty);
      await app.stopWorkout();
      await app.debugAfterDrain();
      await until(() => src.computeStarted.isNotEmpty);
      expect(src.computeStarted, ['hold-a']);
      await finish(app);
    });

    test('a real breathing session holds it; the real stop releases it',
        () async {
      final (app, src) = await rig('hold-b');
      app.device.connection = 'connected';
      await app.startBreathingSession();
      await app.debugAfterDrain();
      await settleMs(200);
      expect(src.computeStarted, isEmpty);
      await app.stopBreathingSession();
      await app.debugAfterDrain();
      await until(() => src.computeStarted.isNotEmpty);
      expect(src.computeStarted, ['hold-b']);
      await finish(app);
    });

    test('an open breathing window holds it until it is closed', () async {
      final (app, src) = await rig('hold-c');
      app.device.connection = 'connected';
      await app.openBreathingWindow();
      await app.debugAfterDrain();
      await settleMs(200);
      expect(src.computeStarted, isEmpty);
      await app.closeBreathingWindow();
      await app.debugAfterDrain();
      await until(() => src.computeStarted.isNotEmpty);
      expect(src.computeStarted, ['hold-c']);
      await finish(app);
    });

    test('the workout hold on the SCHEDULER is separate: it is released by '
        'the stop even if a breathing session is still open', () async {
      final (app, _) = await rig('hold-d');
      app.device.connection = 'connected';
      await app.startBreathingSession();
      app.startWorkout(workoutId: 'w4-h4', type: 'strength');
      expect(app.logLines,
          contains('[derive-scheduler] workout live — holding derive work'));
      await app.stopWorkout();
      expect(app.logLines,
          contains('[derive-scheduler] workout ended — derive may run'));
      await finish(app);
    });
  });

  group('the workout and breathing block an ECG capture (busyReason)', () {
    Future<GestureRig> ecgRig() async {
      final r = GestureRig(mg: true);
      await settleMs(100);
      await r.app.ecg.guard.setWrist('5AM0000000', EcgWrist.left);
      return r;
    }

    test('a live workout makes a capture attempt busy with "workout"',
        () async {
      final r = await ecgRig();
      r.app.startWorkout(workoutId: 'w4-e1', type: 'strength');
      await r.app.ecg.begin(EcgWrist.left);
      expect(r.app.ecg.state.phase, EcgCapturePhase.busy);
      expect(r.app.ecg.state.reason, 'workout');
      await finish(r.app, dispose: false);
      await r.dispose();
    });

    test('a breathing session or window makes it busy with "breathing", and '
        'the workout wins when both are on', () async {
      final r = await ecgRig();
      await r.app.openBreathingWindow();
      await r.app.ecg.begin(EcgWrist.left);
      expect(r.app.ecg.state.reason, 'breathing');
      r.app.startWorkout(workoutId: 'w4-e2', type: 'strength');
      await r.app.ecg.begin(EcgWrist.left);
      expect(r.app.ecg.state.reason, 'workout');
      await finish(r.app, dispose: false);
      await r.dispose();
    });
  });
}
