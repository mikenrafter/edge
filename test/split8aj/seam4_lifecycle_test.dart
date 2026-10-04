// 8AJ seam 4 characterization: the live workout's start / stop / delete
// transitions through AppState, what each persists, releases and announces, and
// how many times it notifies. Must pass before and after the WorkoutController
// move.
//
// There is no pause or resume in this area today: a workout is live or it is
// not. (A "resume" is only the cold-start reconcile, pinned in
// seam4_reconcile_test.dart.)

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/workout_harness.dart';

const _db = 'split8aj_seam4_lifecycle.db';

/// A repo that records the workout calls AppState forwards to it.
class _WorkoutRepo extends LocalRepository {
  final calls = <String>[];
  Object? deleteThrows;

  @override
  Future<void> deleteWorkout(String id) async {
    calls.add('delete:$id');
    if (deleteThrows != null) throw deleteThrows!;
  }

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}

const _user = {
  'age': 30,
  'weight_kg': 70.0,
  'height_cm': 175.0,
  'sex': 'male',
  'resting_hr': 55,
};

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

  group('a fresh app', () {
    test('has no workout, no breathing session and no route state', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(app.activeWorkout, isNull);
      expect(app.workoutStepsMeasured, isNull);
      expect(app.liveZone, isNull);
      expect(app.liveDistanceKm, isNull);
      expect(app.routeTracker, isNull);
      expect(app.routeTracking, isFalse);
      expect(app.routeLocationIssue, isNull);
      expect(app.breathingActive, isFalse);
      expect(app.breathingWindowOpen, isFalse);
      expect(app.breathingResult, isNull);
      expect(app.breathingError, isNull);
      expect(app.breathingStartedAt, isNull);
      expect(app.breathingTarget, isNull);
    });
  });

  group('startWorkout', () {
    test('builds the live state from its arguments and the profile, and '
        'notifies twice (hold + start)', () async {
      final app = AppState.forTesting();
      app.user = {..._user};
      app.engine.state.generation = 'gen4';
      final ticks = TickCounter(app);
      final before = DateTime.now();
      app.startWorkout(workoutId: 'w4-start', type: 'strength', targetKcal: 450);
      final w = app.activeWorkout!;
      expect(w.workoutId, 'w4-start');
      expect(w.type, 'strength');
      expect(w.targetKcal, 450);
      expect(w.startTime.isBefore(before), isFalse);
      expect(w.elapsed, Duration.zero);
      expect(w.currentHr, isNull);
      expect(w.profile.weightKg, 70.0);
      expect(w.hrMax, isNotNull, reason: 'age 30 on a stamped gen4 band');
      expect(w.zoneSet, isNotNull);
      expect(w.restingHr, 55, reason: 'the profile RHR until a night lands');
      // Two, synchronously: the scheduler's hold announces itself through its
      // onChanged (= notifyListeners), then startWorkout's own notify.
      expect(ticks.ticks, 2);
      await finish(app);
      ticks.stop();
    });

    test('an unlinked, profile-less start pins no ceiling and no zone set '
        '(absent, never a default)', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-bare');
      final w = app.activeWorkout!;
      expect(w.type, 'other');
      expect(w.targetKcal, 300);
      expect(w.hrMax, isNull);
      expect(w.zoneSet, isNull);
      expect(w.restingHr, isNull);
      expect(app.liveZone, isNull);
      await finish(app);
    });

    test('an omitted id becomes w<start epoch ms>', () async {
      final app = AppState.forTesting();
      app.startWorkout();
      final w = app.activeWorkout!;
      expect(w.workoutId, 'w${w.startTime.millisecondsSinceEpoch}');
      await finish(app);
    });

    test('a second start while one is live is a no-op: same state, no notify, '
        'no second timer, no second Live Activity', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.startWorkout(workoutId: 'w4-first', type: 'strength');
        final first = app.activeWorkout;
        final ticks = TickCounter(app);
        final timers = probe.periodics.length;
        final activity = spies.liveActivity.length;
        app.startWorkout(workoutId: 'w4-second', type: 'running');
        expect(identical(app.activeWorkout, first), isTrue);
        expect(app.activeWorkout!.workoutId, 'w4-first');
        expect(ticks.ticks, 0);
        expect(probe.periodics.length, timers);
        expect(spies.liveActivity.length, activity);
        ticks.stop();
        await finish(app);
      });
    });

    test('arms a 1 s tick, holds the display, starts the Live Activity and '
        'logs the goal', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.startWorkout(workoutId: 'w4-arms', type: 'strength', targetKcal: 410);
        expect(probe.active(kTick), hasLength(1));
        expect(app.logLines, contains('Live session started. Goal: 410 kcal'));
        await until(() =>
            spies.keepAwake.isNotEmpty && spies.liveActivity.isNotEmpty);
        expect(spies.keepAwake, [true]);
        expect(spies.liveActivityMethods, ['start']);
        final args = spies.liveActivity.single.args as Map;
        expect(args['targetKcal'], 410);
        expect(args['hr'], 0);
        expect(args['strain'], isNull, reason: 'nothing measured yet');
        expect(args['calories'], isNull);
        await finish(app);
      });
    });

    test('holds derivation for the session: the scheduler says so, and says '
        'so again when it ends', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-hold', type: 'strength');
      expect(app.logLines,
          contains('[derive-scheduler] workout live — holding derive work'));
      expect(
          app.logLines,
          isNot(contains('[derive-scheduler] workout ended — derive may run')));
      await app.stopWorkout();
      const release = '[derive-scheduler] workout ended — derive may run';
      expect(app.logLines, contains(release));
      // logLines is newest first: the summary line comes after the release.
      expect(
          app.logLines.indexWhere((l) => l.startsWith('Live session ended')),
          lessThan(app.logLines.indexOf(release)));
      await finish(app);
    });

    test('writes the live session row: status live, no end, the strap stamp',
        () async {
      final app = AppState.forTesting();
      app.engine.state.generation = 'gen5';
      final started = DateTime.now();
      app.startWorkout(workoutId: 'w4-row', type: 'running');
      await sessionLanded('w4-row');
      final row = (await sessionRow('w4-row'))!;
      expect(row['status'], 'live');
      expect(row['end_ts'], isNull);
      expect(row['type'], 'running');
      expect(row['source'], 'manual');
      expect(row['device_family'], 'gen5');
      expect(row['start_ts'],
          inInclusiveRange(started.millisecondsSinceEpoch ~/ 1000 - 1,
              started.millisecondsSinceEpoch ~/ 1000 + 1));
      expect(row['created_at'],
          (app.activeWorkout!.startTime.millisecondsSinceEpoch));
      expect(row['calories'], isNull);
      await finish(app);
    });

    test('an unlinked start stamps no strap family (unknown, not gen4)',
        () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-nofam', type: 'strength');
      await sessionLanded('w4-nofam');
      expect((await sessionRow('w4-nofam'))!['device_family'], isNull);
      await finish(app);
    });
  });

  group('stopWorkout', () {
    test('with nothing live it is a no-op: no notify, no write, no release',
        () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ticks = TickCounter(app);
      await app.stopWorkout();
      expect(ticks.ticks, 0);
      expect(app.logLines, isEmpty);
      expect(spies.liveActivity, isEmpty);
      expect(spies.keepAwake, isEmpty);
      ticks.stop();
    });

    test('an unmeasured session banks status done, nullable measures left '
        'null, and clears every live field', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.engine.state.generation = 'gen5';
        app.startWorkout(workoutId: 'w4-stop', type: 'strength');
        final startMs = app.activeWorkout!.startTime.millisecondsSinceEpoch;
        await sessionLanded('w4-stop');
        final ticks = TickCounter(app);
        final rev = app.insightsRevision.value;
        await app.stopWorkout();
        await settleMs(300);
        expect(app.activeWorkout, isNull);
        expect(app.workoutStepsMeasured, isNull);
        expect(probe.active(kTick), isEmpty, reason: 'the tick is cancelled');
        expect(app.insightsRevision.value, rev + 1,
            reason: 'the Workout tab hears the session landed');
        // Three, once everything has landed: the scheduler's hold release,
        // the scheduler's own queue re-read that follows it, and stop's.
        expect(ticks.ticks, 3);
        final row = (await sessionRow('w4-stop'))!;
        expect(row['status'], 'done');
        expect(row['type'], 'strength');
        expect(row['source'], 'manual');
        expect(row['device_family'], 'gen5');
        expect(row['created_at'], startMs);
        expect(row['start_ts'], startMs ~/ 1000);
        expect(row['end_ts'] as int, greaterThanOrEqualTo(startMs ~/ 1000));
        expect(row['calories'], isNull);
        expect(row['strain'], isNull);
        expect(row['max_hr'], isNull);
        expect(row['steps'], isNull);
        expect(row['cadence_spm'], isNull);
        expect(row['duration_min'], 0);
        expect(row['zone_min_json'], '[]');
        expect(app.logLines,
            contains('Live session ended. No calorie anchors in the profile.'));
        ticks.stop();
        await finish(app);
      });
    });

    test('releases the display, ends the Live Activity and ends the '
        'workout\'s hold on the display wake', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-rel', type: 'strength');
      await app.stopWorkout();
      await until(() =>
          spies.keepAwake.length >= 2 && spies.liveActivity.length >= 2);
      expect(spies.keepAwake, [true, false]);
      expect(spies.liveActivityMethods, ['start', 'end']);
      await finish(app);
    });

    test('stop keeps the strap stamp when the link has dropped (the row is '
        'INSERT OR REPLACE)', () async {
      final app = AppState.forTesting();
      app.engine.state.generation = 'gen5';
      app.startWorkout(workoutId: 'w4-stamp', type: 'strength');
      await sessionLanded('w4-stamp');
      app.engine.state.generation = null;
      await app.stopWorkout();
      expect((await sessionRow('w4-stamp'))!['device_family'], 'gen5');
      await finish(app);
    });

    test('a measured session banks its peak, zone minutes and kcal; the '
        'duration is wall clock (0 min here)', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.user = {..._user};
        app.engine.state.generation = 'gen4';
        app.startWorkout(workoutId: 'w4-meas', type: 'strength');
        setLiveHr(app, 150);
        final tick = probe.active(kTick).single;
        for (var i = 0; i < 90; i++) {
          tick.fire();
        }
        final w = app.activeWorkout!;
        expect(w.currentHr, 150);
        expect(w.zoneSeconds.reduce((a, b) => a + b), 90);
        await app.stopWorkout();
        final row = (await sessionRow('w4-meas'))!;
        expect(row['max_hr'], isNotNull);
        expect((row['max_hr'] as num) > 0, isTrue);
        expect(row['zone_min_json'], isNot('[]'));
        expect(row['calories'], isNotNull);
        expect(row['strain'], isNotNull);
        expect(row['duration_min'], 0);
        await finish(app);
      });
    });

    // The save's own failure and a failure of the strap-stamp read that comes
    // just before it are different paths today: the read sits OUTSIDE the
    // try, so the "could not save" log line and the failure notify belong only
    // to the write.
    for (final family in ['gen5', null]) {
      test('a failed save (link ${family ?? 'unstamped'}) keeps the session '
          'live, rethrows, leaves the tick cancelled, and the retry banks it',
          () async {
        final probe = TimerProbe();
        await probe.run(() async {
          final app = AppState.forTesting();
          app.engine.state.generation = family;
          app.startWorkout(workoutId: 'w4-fail', type: 'strength');
          await sessionLanded('w4-fail');
          final db = await LocalDb.instance;
          await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
          final ticks = TickCounter(app);
          await expectLater(app.stopWorkout(), throwsA(anything));
          expect(app.activeWorkout, isNotNull);
          // Today's behaviour, pinned: the teardown that ran before the write
          // is not undone, so the still-"live" session no longer ticks and no
          // longer holds derivation.
          expect(probe.active(kTick), isEmpty);
          expect(app.logLines,
              contains('[derive-scheduler] workout ended — derive may run'));
          expect(spies.liveActivityMethods, ['start'],
              reason: 'the Live Activity is not ended by a failed stop');
          final saveFailed = app.logLines.any(
              (l) => l.startsWith('[workout] could not save session w4-fail'));
          expect(saveFailed, family != null,
              reason: 'only the write failure is logged');
          // The hold release notifies (and the scheduler's queue re-read after
          // it); the write failure notifies once more.
          await settleMs(300);
          expect(ticks.ticks, family != null ? 3 : 2);
          await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
          await app.stopWorkout();
          expect(app.activeWorkout, isNull);
          expect((await sessionRow('w4-fail'))!['status'], 'done');
          ticks.stop();
          await finish(app);
        });
      });
    }

    test('a second stop right after the first is a no-op', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-twice', type: 'strength');
      await app.stopWorkout();
      final rev = app.insightsRevision.value;
      final ticks = TickCounter(app);
      await app.stopWorkout();
      expect(ticks.ticks, 0);
      expect(app.insightsRevision.value, rev);
      ticks.stop();
      await finish(app);
    });

    test('a workout can be started again after a stop, with a fresh state',
        () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-one', type: 'strength');
      final one = app.activeWorkout;
      await app.stopWorkout();
      app.startWorkout(workoutId: 'w4-two', type: 'running');
      expect(identical(app.activeWorkout, one), isFalse);
      expect(app.activeWorkout!.workoutId, 'w4-two');
      expect(app.activeWorkout!.zoneSeconds.every((s) => s == 0), isTrue);
      await finish(app);
    });
  });

  group('deleteWorkout', () {
    test('deleting a stored workout that is not live only asks the repo',
        () async {
      final app = AppState.forTesting();
      final repo = _WorkoutRepo();
      app.repo = repo;
      app.startWorkout(workoutId: 'w4-live', type: 'strength');
      final ticks = TickCounter(app);
      await app.deleteWorkout('some-other');
      expect(repo.calls, ['delete:some-other']);
      expect(app.activeWorkout!.workoutId, 'w4-live');
      expect(ticks.ticks, 0);
      ticks.stop();
      await finish(app);
    });

    test('deleting the live one tears the session down WITHOUT saving it: '
        'tick cancelled, display released, Live Activity ended, three notifies (hold release '
        'twice over + the delete)',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        final repo = _WorkoutRepo();
        app.repo = repo;
        app.startWorkout(workoutId: 'w4-del', type: 'strength');
        await sessionLanded('w4-del');
        final rev = app.insightsRevision.value;
        final ticks = TickCounter(app);
        await app.deleteWorkout('w4-del');
        await settleMs(300);
        expect(repo.calls, ['delete:w4-del']);
        expect(app.activeWorkout, isNull);
        expect(probe.active(kTick), isEmpty);
        expect(ticks.ticks, 3);
        expect(app.insightsRevision.value, rev,
            reason: 'nothing was saved, so no sessions bump');
        await until(() =>
            spies.keepAwake.length >= 2 && spies.liveActivity.length >= 2);
        expect(spies.keepAwake, [true, false]);
        expect(spies.liveActivityMethods, ['start', 'end']);
        expect(app.logLines,
            contains('[derive-scheduler] workout ended — derive may run'));
        expect((await sessionRow('w4-del'))!['status'], 'live',
            reason: 'the fake repo deleted nothing, and the teardown writes '
                'no row of its own');
        ticks.stop();
        await finish(app);
      });
    });

    test('a repo that throws leaves the live session untouched', () async {
      final app = AppState.forTesting();
      final repo = _WorkoutRepo()..deleteThrows = StateError('nope');
      app.repo = repo;
      app.startWorkout(workoutId: 'w4-delthrow', type: 'strength');
      await expectLater(app.deleteWorkout('w4-delthrow'), throwsStateError);
      expect(app.activeWorkout, isNotNull);
      await finish(app);
    });

    test('with no repo the live session is still torn down', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-norepo', type: 'strength');
      await app.deleteWorkout('w4-norepo');
      expect(app.activeWorkout, isNull);
      await finish(app);
    });
  });
}
