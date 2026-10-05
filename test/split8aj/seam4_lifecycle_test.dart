// 8AJ seam 4 characterization: the live workout's start / stop / delete
// transitions through AppState, what each persists, releases and announces, and
// how many times it notifies. Must pass before and after the WorkoutController
// move.
//
// There is no pause or resume in this area today: a workout is live or it is
// not. (A "resume" is only the cold-start reconcile, pinned in
// seam4_reconcile_test.dart.)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';

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
    // The prefs instance is cached for the whole file: load it, and empty the
    // pending-stop row an earlier test may have left.
    await Prefs.ensureLoaded();
    Prefs.setString(Prefs.workoutStopPending, '');
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

    // FIXED (was LATENT). A failed stop used to leave the session live but
    // frozen: the tick was cancelled and the derive hold released, yet the UI
    // still showed a running session and the Live Activity kept counting. And
    // on an unstamped link (the gen4 case: no strap stamp to carry) the
    // strap-stamp read sat outside the try, so a failed save logged no "could
    // not save" line and sent no failure notify; gen5 did both.
    //
    // Decided behaviour, the same for every link: a failed stop is "stop
    // pending". Nothing is lost or fabricated: the finished row (tallies, end
    // stamp) is built once and kept, in memory for a retry and in prefs for a
    // relaunch. The session is not live: no tick, derive hold and display wake
    // released, Live Activity ended, and `workoutStopPending` tells the UI to
    // offer a retry rather than a running session. `activeWorkout` stays only
    // as the retry handle, so the retry banks the SAME row (the stop time does
    // not drift to the retry), exports once, and ends nothing twice. A launch
    // that finds the pending row banks it through the reconcile.
    for (final family in ['gen5', null]) {
      test('a failed save (link ${family ?? 'unstamped'}) leaves the session '
          'stop-pending: logged, notified, not ticking, Live Activity ended, '
          'display released; the retry banks it', () async {
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
          expect(app.activeWorkout, isNotNull,
              reason: 'kept as the retry handle');
          expect(app.workoutStopPending, isTrue);
          expect(app.debugLiveOwners.activeWorkout, isFalse,
              reason: 'a stopped workout held for retry no longer owns streams');
          expect(probe.active(kTick), isEmpty);
          expect(app.logLines,
              contains('[derive-scheduler] workout ended — derive may run'));
          expect(spies.liveActivityMethods, ['start', 'end']);
          expect(spies.keepAwake, [true, false]);
          expect(
              app.logLines.any((l) =>
                  l.startsWith('[workout] could not save session w4-fail')),
              isTrue,
              reason: 'gen4 and gen5 report a failed save alike');
          // The hold release notifies; the write failure notifies once more.
          await settleMs(300);
          expect(ticks.ticks, 3);
          final held = jsonDecode(Prefs.getString(Prefs.workoutStopPending, ''))
              as Map<String, dynamic>;
          expect(held['id'], 'w4-fail');
          expect(held['status'], 'done');
          await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
          await settleMs(1100);
          await app.stopWorkout();
          expect(app.activeWorkout, isNull);
          expect(app.workoutStopPending, isFalse);
          final row = (await sessionRow('w4-fail'))!;
          expect(row['status'], 'done');
          expect(row['end_ts'], held['end_ts'],
              reason: 'the stop time is the stop, not the retry');
          expect(Prefs.getString(Prefs.workoutStopPending, ''), isEmpty);
          expect(spies.liveActivityMethods, ['start', 'end'],
              reason: 'the retry does not end the Live Activity again');
          ticks.stop();
          await finish(app);
        });
      });
    }

    test('a failed stop keeps the tallies and no later tick bills '
        'into the retry', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.user = {..._user};
        app.engine.state.generation = 'gen4';
        app.startWorkout(workoutId: 'w4-keep', type: 'strength');
        await sessionLanded('w4-keep');
        setLiveHr(app, 150);
        final tick = probe.active(kTick).single;
        for (var i = 0; i < 90; i++) {
          tick.fire();
        }
        final db = await LocalDb.instance;
        await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
        await expectLater(app.stopWorkout(), throwsA(anything));
        // A late tick (or a stray timer) must not add to a stopped session.
        app.debugTickWorkout();
        expect(app.activeWorkout!.zoneSeconds.reduce((a, b) => a + b), 90);
        await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
        await app.stopWorkout();
        final row = (await sessionRow('w4-keep'))!;
        expect((row['max_hr'] as num) > 0, isTrue);
        expect(row['zone_min_json'], isNot('[]'));
        expect(row['calories'], isNotNull);
        expect(row['strain'], isNotNull);
        await finish(app);
      });
    });

    test('the app dying after a failed stop: the relaunch banks the finished '
        'row, tallies intact, as a real stop (not a fabricated end), and '
        'exports it once', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        app.user = {..._user};
        app.healthSyncEnabled = true;
        app.engine.state.generation = 'gen4';
        app.startWorkout(workoutId: 'w4-die', type: 'strength');
        await sessionLanded('w4-die');
        setLiveHr(app, 150);
        final tick = probe.active(kTick).single;
        for (var i = 0; i < 90; i++) {
          tick.fire();
        }
        await settleMs(1300);
        final db = await LocalDb.instance;
        await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
        await expectLater(app.stopWorkout(), throwsA(anything));
        app.dispose();
        await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
        expect((await sessionRow('w4-die'))!['status'], 'live');
        spies.health.clear();

        final relaunch = AppState.forTesting();
        relaunch.healthSyncEnabled = true;
        await relaunch.debugReconcileOrphanedLiveWorkout();
        await settleMs(400);
        expect(relaunch.activeWorkout, isNull,
            reason: 'finalized, not resumed as a running session');
        final row = (await sessionRow('w4-die'))!;
        expect(row['status'], 'done');
        expect(row['end_ts_fabricated'], anyOf(isNull, 0));
        expect((row['max_hr'] as num) > 0, isTrue);
        expect(row['zone_min_json'], isNot('[]'));
        expect(row['calories'], isNotNull);
        expect(row['strain'], isNotNull);
        expect(row['device_family'], 'gen4');
        expect(Prefs.getString(Prefs.workoutStopPending, ''), isEmpty);
        expect([for (final c in spies.health) c.method],
            ['delete', 'writeWorkoutData']);
        await finish(relaunch);
      });
    });

    test('a held stop whose cold-start bank fails is restored for retry, never '
        'resumed live, and exports exactly once once the retry lands', () async {
      final app = AppState.forTesting();
      app.healthSyncEnabled = true;
      app.startWorkout(workoutId: 'w4-cold-retry', type: 'strength');
      await sessionLanded('w4-cold-retry');
      // Long enough to be a Health sample (end after start, in seconds).
      await settleMs(1300);
      final db = await LocalDb.instance;
      await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
      await expectLater(app.stopWorkout(), throwsA(anything));
      final held = jsonDecode(Prefs.getString(Prefs.workoutStopPending, ''))
          as Map<String, dynamic>;
      app.dispose();
      await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
      await db.execute("CREATE TRIGGER fail_held_stop_bank "
          "BEFORE INSERT ON sessions WHEN NEW.id = 'w4-cold-retry' "
          "BEGIN SELECT RAISE(FAIL, 'held stop write failed'); END");

      spies.health.clear();
      spies.tracking.clear();
      spies.liveActivity.clear();
      final relaunch = AppState.forTesting();
      relaunch.healthSyncEnabled = true;
      final ticks = TickCounter(relaunch);
      await relaunch.debugReconcileOrphanedLiveWorkout();

      expect(relaunch.activeWorkout?.workoutId, 'w4-cold-retry',
          reason: 'the stopped session is kept only as the retry handle');
      expect(relaunch.workoutStopPending, isTrue);
      expect(relaunch.debugLiveOwners.activeWorkout, isFalse);
      expect(ticks.ticks, 1, reason: 'one notify for the restored retry handle');
      expect(spies.keepAwake, isEmpty,
          reason: 'a stopped session does not hold the display again');
      expect(spies.liveActivity, isEmpty,
          reason: 'nor start a Live Activity for it');
      expect(Prefs.getString(Prefs.workoutStopPending, ''), isNotEmpty);
      expect(spies.health, isEmpty, reason: 'a failed bank exports nothing');

      await db.execute('DROP TRIGGER fail_held_stop_bank');
      await relaunch.stopWorkout();
      await relaunch.stopWorkout();
      await settleMs(300);
      final row = (await sessionRow('w4-cold-retry'))!;
      expect(row['status'], 'done');
      expect(row['end_ts'], held['end_ts'],
          reason: 'a retry banks the original stop, not a later finish');
      expect(Prefs.getString(Prefs.workoutStopPending, ''), isEmpty);
      expect([for (final c in spies.health) c.method],
          ['delete', 'writeWorkoutData']);
      ticks.stop();
      await finish(relaunch);
    });

    test('deleting a held stop restored after a failed cold-start bank clears '
        'its persistent retry marker', () async {
      final app = AppState.forTesting();
      app.startWorkout(workoutId: 'w4-cold-delete', type: 'strength');
      await sessionLanded('w4-cold-delete');
      final db = await LocalDb.instance;
      await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
      await expectLater(app.stopWorkout(), throwsA(anything));
      app.dispose();
      await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
      await db.execute("CREATE TRIGGER fail_held_stop_delete "
          "BEFORE INSERT ON sessions WHEN NEW.id = 'w4-cold-delete' "
          "BEGIN SELECT RAISE(FAIL, 'held stop write failed'); END");

      final relaunch = AppState.forTesting();
      relaunch.repo = _WorkoutRepo();
      await relaunch.debugReconcileOrphanedLiveWorkout();
      expect(relaunch.workoutStopPending, isTrue);
      await relaunch.deleteWorkout('w4-cold-delete');
      expect(relaunch.activeWorkout, isNull);
      expect(relaunch.workoutStopPending, isFalse);
      expect(Prefs.getString(Prefs.workoutStopPending, ''), isEmpty);
      await db.execute('DROP TRIGGER fail_held_stop_delete');
      await finish(relaunch);
    });

    test('a held row is banked even when its live row is gone, and an '
        'unreadable one is left for the next launch', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      Prefs.setString(
          Prefs.workoutStopPending,
          jsonEncode({
            'id': 'w4-gone',
            'start_ts': now - 600,
            'end_ts': now - 60,
            'type': 'strength',
            'status': 'done',
            'max_hr': 150,
            'source': 'manual',
            'created_at': (now - 600) * 1000,
          }));
      final app = AppState.forTesting();
      await app.debugReconcileOrphanedLiveWorkout();
      expect((await sessionRow('w4-gone'))!['max_hr'], 150);
      expect(Prefs.getString(Prefs.workoutStopPending, ''), isEmpty);
      Prefs.setString(Prefs.workoutStopPending, '{not json');
      await app.debugReconcileOrphanedLiveWorkout();
      expect(Prefs.getString(Prefs.workoutStopPending, ''), '{not json');
      Prefs.setString(Prefs.workoutStopPending, '');
      await finish(app);
    });

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
