// 8AJ seam 4 characterization: the cold-start reconcile of a session row left
// `status='live'` by a killed run. A recent one is RESUMED (the only "resume"
// in this area); a stale or surplus one is finalized with a fabricated end
// stamp. What it arms, holds and notifies is pinned here; the cases the older
// regression file already covers (a race with a fresh start, a 6 h stale row
// never exported, tally restore) are not repeated. Must pass before and after
// the WorkoutController move.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/workout_harness.dart';

const _db = 'split8aj_seam4_reconcile.db';

Future<void> _live(String id, {required int ageSec, String type = 'strength', int? endTs}) =>
    LocalDb.putSession({
      'id': id,
      'start_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000 - ageSec,
      'end_ts': endTs,
      'type': type,
      'status': 'live',
      'source': 'manual',
      'created_at': DateTime.now().millisecondsSinceEpoch - ageSec * 1000,
    });

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

  group('resuming a recent live row', () {
    test('rehydrates the session from the row, arms the tick, holds the '
        'display and derivation, owns the streams, and notifies', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        await _live('w4-r1', ageSec: 600, type: 'strength');
        final app = AppState.forTesting();
        app.user = {'age': 30};
        app.engine.state.generation = 'gen4';
        final ticks = TickCounter(app);
        await app.debugReconcileOrphanedLiveWorkout();
        final w = app.activeWorkout!;
        expect(w.workoutId, 'w4-r1');
        expect(w.type, 'strength');
        expect(w.targetKcal, 300);
        expect(
            DateTime.now().difference(w.startTime).inSeconds, inInclusiveRange(599, 603));
        expect(w.zoneSet, isNotNull, reason: 'the same zone set a fresh start pins');
        expect(w.hrMax, isNotNull);
        expect(probe.active(kTick), hasLength(1));
        expect(app.debugLiveOwners.activeWorkout, isTrue);
        expect(app.logLines.any((l) => l.startsWith(
            '[workout] resumed a live session still running after restart (id=w4-r1)')), isTrue);
        expect(app.logLines,
            contains('[derive-scheduler] workout live — holding derive work'));
        // The scheduler's hold announces itself, then the reconcile's own.
        await settleMs(200);
        expect(ticks.ticks, 2);
        expect(spies.keepAwake, [true]);
        expect(spies.liveActivityMethods, isEmpty,
            reason: 'a resumed session does not restart the Live Activity '
                '(today\'s behaviour)');
        ticks.stop();
        await finish(app);
      });
    });

    test('the resumed session counts steps from zero: measured only once a '
        'gait sample arrives', () async {
      await _live('w4-r2', ageSec: 300, type: 'running');
      final app = AppState.forTesting();
      await app.debugReconcileOrphanedLiveWorkout();
      expect(app.workoutStepsMeasured, isNull);
      app.debugFeedLiveAccel(walkFrame(0, 10), recTs: 1, atMs: 1790000000000);
      expect(app.workoutStepsMeasured, 0);
      await finish(app);
    });

    test('a resumed session can be stopped through the normal path and '
        'banks status done under its own id', () async {
      await _live('w4-r3', ageSec: 900);
      final app = AppState.forTesting();
      await app.debugReconcileOrphanedLiveWorkout();
      await app.stopWorkout();
      expect(app.activeWorkout, isNull);
      final row = (await sessionRow('w4-r3'))!;
      expect(row['status'], 'done');
      expect(row['end_ts_fabricated'], anyOf(isNull, 0),
          reason: 'a real stop, not a reconcile stamp');
      await finish(app);
    });

    test('of two live rows only the newest is resumed; the other is '
        'finalized as stale', () async {
      await _live('w4-old', ageSec: 1200);
      await _live('w4-new', ageSec: 300);
      final app = AppState.forTesting();
      await app.debugReconcileOrphanedLiveWorkout();
      expect(app.activeWorkout!.workoutId, 'w4-new');
      final old = (await sessionRow('w4-old'))!;
      expect(old['status'], 'done');
      expect(old['end_ts_fabricated'], 1);
      expect((await sessionRow('w4-new'))!['status'], 'live');
      await finish(app);
    });

    test('a second reconcile while one is live changes nothing', () async {
      await _live('w4-r4', ageSec: 300);
      final probe = TimerProbe();
      await probe.run(() async {
        final app = AppState.forTesting();
        await app.debugReconcileOrphanedLiveWorkout();
        final w = app.activeWorkout;
        final ticks = TickCounter(app);
        await app.debugReconcileOrphanedLiveWorkout();
        expect(identical(app.activeWorkout, w), isTrue);
        expect(ticks.ticks, 0);
        expect(probe.active(kTick), hasLength(1));
        ticks.stop();
        await finish(app);
      });
    });

    test('a row just inside the 6 h ceiling resumes', () async {
      await _live('w4-edge-in', ageSec: 6 * 3600 - 30);
      final app = AppState.forTesting();
      await app.debugReconcileOrphanedLiveWorkout();
      expect(app.activeWorkout?.workoutId, 'w4-edge-in');
      await finish(app);
    });
  });

  group('finalizing a stale or malformed live row', () {
    test('a row past the ceiling is closed: status done, a fabricated end '
        'stamp flagged as such, no workout, no timer, no notify', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        await _live('w4-stale', ageSec: 6 * 3600 + 60);
        final app = AppState.forTesting();
        final ticks = TickCounter(app);
        await app.debugReconcileOrphanedLiveWorkout();
        expect(app.activeWorkout, isNull);
        expect(probe.livePeriodics, isEmpty);
        expect(ticks.ticks, 0);
        final row = (await sessionRow('w4-stale'))!;
        expect(row['status'], 'done');
        expect(row['end_ts_fabricated'], 1);
        expect(row['end_ts'],
            inInclusiveRange(DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3,
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 1));
        expect(app.logLines.any((l) => l.startsWith(
            '[workout] finalized a stale live-session row from a previous run (id=w4-stale)')), isTrue);
        ticks.stop();
        await finish(app);
      });
    });

    test('a stale row that already had a real end keeps it, unflagged',
        () async {
      final end = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 5 * 3600;
      await _live('w4-realend', ageSec: 8 * 3600, endTs: end);
      final app = AppState.forTesting();
      await app.debugReconcileOrphanedLiveWorkout();
      final row = (await sessionRow('w4-realend'))!;
      expect(row['status'], 'done');
      expect(row['end_ts'], end);
      expect(row['end_ts_fabricated'], anyOf(isNull, 0));
      await finish(app);
    });

    test('a row that starts in the future is not resumable: finalized',
        () async {
      await _live('w4-future', ageSec: -3600);
      final app = AppState.forTesting();
      await app.debugReconcileOrphanedLiveWorkout();
      expect(app.activeWorkout, isNull);
      expect((await sessionRow('w4-future'))!['status'], 'done');
      await finish(app);
    });

    test('a finalized row\'s orphaned tally snapshot is deleted', () async {
      await _live('w4-tallyrow', ageSec: 7 * 3600);
      await LocalDb.saveLiveWorkoutTally({
        'workout_id': 'w4-tallyrow',
        'updated_ts': DateTime.now().millisecondsSinceEpoch,
        'per_minute_hr': jsonEncode(<double>[]),
        'zone_seconds': jsonEncode(List<double>.filled(6, 0)),
        'seconds_by_bpm': jsonEncode(<String, double>{}),
        'max_hr_seen': 0,
      });
      final app = AppState.forTesting();
      await app.debugReconcileOrphanedLiveWorkout();
      await settleMs(100);
      expect(await LocalDb.liveWorkoutTally('w4-tallyrow'), isNull);
      await finish(app);
    });

    test('with no live rows nothing happens at all', () async {
      final app = AppState.forTesting();
      final ticks = TickCounter(app);
      await app.debugReconcileOrphanedLiveWorkout();
      expect(app.activeWorkout, isNull);
      expect(ticks.ticks, 0);
      expect(app.logLines, isEmpty);
      ticks.stop();
      await finish(app);
    });
  });
}
