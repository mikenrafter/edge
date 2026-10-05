// 8AJ seam 4 characterization: the workout's steps. `workoutStepsMeasured` is
// the live pedometer's count FOR THIS WORKOUT (null = never measured, which is
// not the same as zero), and the stop banks `steps` / `cadence_spm` from it.
// The pedometer itself (the minute chunks, the rate gate) stays in AppState;
// what these pin is the workout-scoped bookkeeping around it: the base
// snapshot at start, the "saw samples" latch, the rebase across a pedometer
// reset, the per-minute cadence list, and the gait gate. Must pass before and
// after the WorkoutController move.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_workout_harness.dart';

const _db = 'split8aj_seam4_steps.db';
const _t0 = 1790000000000; // ms; any instant, the frames carry their own clock

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    await deriveDbSetUp(_db);
    spies = PlatformSpies();
  });
  tearDown(() async {
    spies.dispose();
    await deriveDbTearDown(_db);
  });

  /// [minutes] of a textbook walk at a true 100 Hz (10 samples / 100 ms),
  /// starting at frame [from]. Returns the next frame index.
  int walk(AppState app, int minutes, {int from = 0, int at = 0}) {
    final frames = minutes * 600;
    for (var f = from; f < from + frames; f++) {
      app.debugFeedLiveAccel(walkFrame(f, 10),
          recTs: _t0 ~/ 1000, atMs: _t0 + at + f * 100);
    }
    return from + frames;
  }

  int still(AppState app, int minutes, {int from = 0}) {
    final frames = minutes * 600;
    for (var f = from; f < from + frames; f++) {
      app.debugFeedLiveAccel(List<double>.filled(10, 1.0),
          recTs: _t0 ~/ 1000, atMs: _t0 + f * 100);
    }
    return from + frames;
  }

  group('workoutStepsMeasured', () {
    test('null with no workout, whatever the pedometer has counted', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      walk(app, 1);
      expect(app.workoutStepsMeasured, isNull);
    });

    test('null on a gait workout until a gait-capable sample has arrived, '
        'then a count from zero', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-s1', type: 'running');
      expect(app.workoutStepsMeasured, isNull);
      app.debugFeedLiveAccel(walkFrame(0, 10), recTs: 1, atMs: _t0);
      expect(app.workoutStepsMeasured, 0,
          reason: 'samples arrived, no step completed: measured zero');
      await finish(app);
    });

    test('counts only the steps taken since THIS workout began (the base is '
        'snapshotted at start)', () async {
      final app = AppState.forTesting();
      // Two minutes of walking before the workout: committed, not the
      // workout's.
      final next = walk(app, 2);
      app.startWorkout(workoutId: 'w4-s2', type: 'walking');
      expect(app.workoutStepsMeasured, isNull,
          reason: 'no sample since the start');
      app.debugFeedLiveAccel(List<double>.filled(10, 1.0),
          recTs: 1, atMs: _t0 + next * 100);
      expect(app.workoutStepsMeasured, 0);
      walk(app, 2, from: next + 1);
      final steps = app.workoutStepsMeasured!;
      expect(steps, greaterThan(100));
      // Control: the same two minutes on an app whose workout began first.
      final control = AppState.forTesting();
      control.startWorkout(workoutId: 'w4-s2-control', type: 'walking');
      walk(control, 2);
      expect(steps, closeTo(control.workoutStepsMeasured!, 15),
          reason: 'the earlier two minutes are not in the workout count');
      await finish(control);
      await finish(app);
    });

    test('a non-gait workout is never billed pedometer samples: stays null, '
        'and says why', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-s3', type: 'strength');
      walk(app, 1);
      expect(app.workoutStepsMeasured, isNull);
      expect(app.liveStepsAbsentReason,
          startsWith('The strap counts steps only while you are on foot'));
      await finish(app);
    });

    test('a gait workout has no absence reason while the stream is healthy',
        () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-s4', type: 'trail_running');
      walk(app, 1);
      expect(app.liveStepsAbsentReason, isNull);
      expect(app.workoutStepsMeasured, greaterThan(0));
      await finish(app);
    });

    test('the type match is case-insensitive', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-s5', type: 'Running');
      walk(app, 1);
      expect(app.workoutStepsMeasured, greaterThan(0));
      await finish(app);
    });

    test('a pedometer reset mid-workout (reconnect) carries the accrued '
        'steps through: the count neither drops nor restarts', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-s6', type: 'running');
      final next = walk(app, 2);
      final before = app.workoutStepsMeasured!;
      expect(before, greaterThan(100));
      await app.debugFinalizeLivePedometer();
      expect(app.workoutStepsMeasured, before,
          reason: 'rebased negative against the zeroed counter');
      walk(app, 1, from: next, at: 5000);
      expect(app.workoutStepsMeasured!, greaterThan(before));
      await finish(app);
    });

    test('a reset before any sample keeps the workout unmeasured (the latch '
        'is about samples, not about the counter)', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-s7', type: 'running');
      await app.debugFinalizeLivePedometer();
      expect(app.workoutStepsMeasured, isNull);
      await finish(app);
    });

    test('the latch survives a reset: samples seen before it keep the count '
        'a number, never a dash', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-s8', type: 'running');
      app.debugFeedLiveAccel(walkFrame(0, 10), recTs: 1, atMs: _t0);
      await app.debugFinalizeLivePedometer();
      expect(app.workoutStepsMeasured, 0);
      await finish(app);
    });
  });

  group('what stop banks', () {
    test('a walked workout banks steps and a measured cadence', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-b1', type: 'walking');
      walk(app, 5);
      final live = app.workoutStepsMeasured!;
      await app.stopWorkout();
      await settleMs(200);
      final row = (await sessionRow('w4-b1'))!;
      expect(row['steps'], live);
      expect(row['cadence_spm'], isNotNull);
      expect((row['cadence_spm'] as num) > 60, isTrue,
          reason: 'a 2 Hz gait is ~120 steps a minute');
      await finish(app);
    });

    test('stopping clears the count and the next workout starts from a '
        'fresh base', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-b2', type: 'walking');
      final next = walk(app, 2);
      await app.stopWorkout();
      expect(app.workoutStepsMeasured, isNull);
      app.startWorkout(workoutId: 'w4-b3', type: 'walking');
      expect(app.workoutStepsMeasured, isNull);
      app.debugFeedLiveAccel(List<double>.filled(10, 1.0),
          recTs: 1, atMs: _t0 + next * 100);
      expect(app.workoutStepsMeasured, 0,
          reason: 'the first workout\'s steps are not the second\'s');
      await finish(app);
    });

    test('samples with no steps in them bank no steps column and no cadence '
        '(a zero is not banked)', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-b4', type: 'walking');
      still(app, 3);
      expect(app.workoutStepsMeasured, 0);
      await app.stopWorkout();
      final row = (await sessionRow('w4-b4'))!;
      expect(row['steps'], isNull);
      expect(row['cadence_spm'], isNull);
      await finish(app);
    });

    test('a workout that never saw a sample banks nothing for steps',
        () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-b5', type: 'walking');
      await app.stopWorkout();
      final row = (await sessionRow('w4-b5'))!;
      expect(row['steps'], isNull);
      expect(row['cadence_spm'], isNull);
      await finish(app);
    });

    test('a non-gait workout banks none even beside a walking signal',
        () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-b6', type: 'rowing');
      walk(app, 3);
      await app.stopWorkout();
      final row = (await sessionRow('w4-b6'))!;
      expect(row['steps'], isNull);
      expect(row['cadence_spm'], isNull);
      await finish(app);
    });

    test('a delete teardown (no save) clears the steps state too', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-b7', type: 'walking');
      walk(app, 1);
      expect(app.workoutStepsMeasured, isNotNull);
      await app.deleteWorkout('w4-b7');
      expect(app.workoutStepsMeasured, isNull);
      app.startWorkout(workoutId: 'w4-b8', type: 'walking');
      expect(app.workoutStepsMeasured, isNull);
      await finish(app);
    });
  });
}
