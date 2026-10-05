// Workout area: the band double tap mapped to "workout toggle"
// (the GestureController's onWorkoutToggle callback into this area). With no
// workout live it starts a type 'other' one, otherwise it ends the active one;
// the repo seam is asked first (start) / after (end) and its failures are
// swallowed; a medium haptic closes a clean toggle. Driven by a real strap
// event through the engine, like the gesture dispatch tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/gestures/device_action.dart';

import 'support/app_state_gesture_harness.dart';
import 'support/app_state_workout_harness.dart' show PlatformSpies, sessionRow, sessionLanded;

const _db = 'app_state_workout_gesture_toggle.db';

class _Repo extends LocalRepository {
  final calls = <String>[];
  Object? startThrows;
  Object? endThrows;
  Map<String, dynamic>? startAnswer = {'workout_id': 'srv-1'};

  @override
  Future<Map<String, dynamic>> startWorkout(String type, {String? title}) async {
    calls.add('start:$type');
    if (startThrows != null) throw startThrows!;
    return startAnswer!;
  }

  @override
  Future<Map<String, dynamic>> endWorkout(String workoutId) async {
    calls.add('end:$workoutId');
    if (endThrows != null) throw endThrows!;
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  late List<String> haptics;
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    await resetGesturePrefs();
    spies = PlatformSpies();
    haptics = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add('${call.arguments}');
      return null;
    });
  });
  tearDown(() async {
    // The rig's own device-row writes (hello, haptic acks) are fire-and-forget.
    await settleMs(400);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    spies.dispose();
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  Future<GestureRig> rig({_Repo? repo}) async {
    final r = GestureRig(mg: false);
    addTearDown(r.dispose);
    await r.measureCues();
    if (repo != null) r.app.repo = repo;
    await r.app.gestureSettings
        .setDoubleTapActions({DeviceAction.workoutToggle});
    return r;
  }

  Future<void> tap(GestureRig r, bool Function() until_) async {
    r.doubleTap();
    await until(until_);
    await settleMs(150);
  }

  test('with no repo: a tap starts a type-other workout with a generated id, '
      'the next tap ends and saves it', () async {
    final r = await rig();
    await tap(r, () => r.app.activeWorkout != null);
    final w = r.app.activeWorkout!;
    expect(w.type, 'other');
    expect(w.workoutId, 'w${w.startTime.millisecondsSinceEpoch}');
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
    await tap(r, () => r.app.activeWorkout == null);
    expect((await sessionRow(w.workoutId!))!['status'], 'done');
    expect(haptics, hasLength(2));
  });

  test('with a repo: the repo is asked to start and its workout id is used; '
      'the end is reported back to it after the local stop', () async {
    final repo = _Repo();
    final r = await rig(repo: repo);
    await tap(r, () => r.app.activeWorkout != null);
    expect(r.app.activeWorkout!.workoutId, 'srv-1');
    expect(repo.calls, ['start:other']);
    await tap(r, () => r.app.activeWorkout == null);
    expect(repo.calls, ['start:other', 'end:srv-1']);
    expect((await sessionRow('srv-1'))!['status'], 'done');
  });

  test('a repo that fails to start still starts the workout locally; one '
      'that fails to end is swallowed', () async {
    final repo = _Repo()
      ..startThrows = StateError('no seam')
      ..endThrows = StateError('no seam');
    final r = await rig(repo: repo);
    await tap(r, () => r.app.activeWorkout != null);
    final w = r.app.activeWorkout!;
    expect(w.workoutId, 'w${w.startTime.millisecondsSinceEpoch}');
    await tap(r, () => r.app.activeWorkout == null);
    expect(repo.calls, ['start:other', 'end:${w.workoutId}']);
    expect(r.app.gestureFailures.all, isEmpty,
        reason: 'neither seam failure is a gesture failure');
  });

  test('the toggle ends a workout started from the screen too, whatever its '
      'type', () async {
    final r = await rig();
    r.app.startWorkout(workoutId: 'w4-screen', type: 'running');
    await tap(r, () => r.app.activeWorkout == null);
    expect((await sessionRow('w4-screen'))!['type'], 'running');
    expect((await sessionRow('w4-screen'))!['status'], 'done');
  });

  test('a tap that ends a workout whose save fails logs the failure and '
      'plays no haptic', () async {
    final r = await rig();
    r.app.startWorkout(workoutId: 'w4-gfail', type: 'strength');
    await sessionLanded('w4-gfail');
    final db = await LocalDb.instance;
    await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
    r.doubleTap();
    await until(() => r.app.logLines
        .any((l) => l.startsWith('[gesture] workout toggle failed')));
    await settleMs(100);
    expect(haptics, isEmpty);
    expect(r.app.activeWorkout, isNotNull);
    await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
    await r.app.stopWorkout();
  });
}
