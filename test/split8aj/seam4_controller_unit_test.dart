// 8AJ seam 4: WorkoutController and BreathingController in isolation, with
// fake collaborators. The same behaviours are pinned through AppState in the
// characterization tests; these prove the controllers stand on their own and
// never reach for AppState. The session rows, the tally row and the breathing
// history are still the real LocalDb (static), and the Live Activity, display
// wake and Health plugin are the platform channels PlatformSpies answers, so
// the tests share the temporary database and the spies the AppState tests use.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/gps/screen_wake.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/state/breathing_controller.dart';
import 'package:openstrap_edge/state/workout_controller.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

import 'support/workout_harness.dart';

const _db = 'split8aj_seam4_controller_unit.db';

/// A repo that records the row deletes the workout controller asks for.
class DeleteRepo extends BreathRepo {
  final deleted = <String>[];

  @override
  Future<void> deleteWorkout(String id) async => deleted.add(id);
}

/// Every collaborator of the workout controller, as a recorder.
class WorkoutHost {
  WorkoutHost({this.sync = false, Map<String, dynamic>? user})
      : user = user ?? {'age': 30} {
    controller = WorkoutController(
      user: () => this.user,
      linkDeviceFamily: () => family,
      clearRadioFallbackAndReconcile: () async => calls.add('radio'),
      nudgeLive: () => calls.add('nudge'),
      setWorkoutActive: (a) => holds.add(a),
      notify: () => notifies++,
      log: logs.add,
      liveHr: () => hr,
      liveRaw: () => raw,
      zoneAlertTargetZone: () => 3,
      refreshNightlyRhr: () async => calls.add('rhr'),
      restingHr: () => 60,
      liveRestingHr: () => null,
      observedCeilingBpm: () => null,
      rhr28: () => const [],
      bumpInsights: () => calls.add('insights'),
      forceResync: () async => calls.add('resync'),
      dismissSupersededSuggestions: ({required startSec, required endSec}) async =>
          calls.add('dismiss'),
      healthSyncEnabled: () => sync,
      exportToHealth: (row) async {
        exported.add(row);
        return true;
      },
      dispatchBandAlert: (rule) async {
        alerts.add(rule);
        return const AlertDeliveryOutcome([], 'test');
      },
      repo: () => repo,
    );
  }

  late final WorkoutController controller;
  Map<String, dynamic>? user;
  String? family = 'gen4';
  int? hr;
  int raw = 0;
  bool sync;
  LocalRepository? repo;
  int notifies = 0;
  final holds = <bool>[];
  final calls = <String>[];
  final logs = <String>[];
  final alerts = <String>[];
  final exported = <Map<String, Object?>>[];
}

/// Every collaborator of the breathing controller, as a recorder.
class BreathHost {
  BreathHost({this.connected = true}) {
    controller = BreathingController(
      isConnected: () => connected,
      reconcileLiveStreams: () async => calls.add('reconcile'),
      nudgeLive: () => calls.add('nudge'),
      repo: () => repo,
      dispatchBandAlert: (rule, {pattern}) async {
        cues.add((rule, pattern));
        return const AlertDeliveryOutcome([], 'test');
      },
      notify: () => notifies++,
    );
  }

  late final BreathingController controller;
  bool connected;
  LocalRepository? repo = BreathRepo();
  int notifies = 0;
  final calls = <String>[];
  final cues = <(String, int?)>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    await deriveDbSetUp(_db);
    spies = PlatformSpies();
  });
  tearDown(() async {
    spies.dispose();
    await ScreenWake.releaseOwner('workout');
    await deriveDbTearDown(_db);
  });

  group('WorkoutController: start', () {
    test('a start holds the derive scheduler and the display, arms the 1 Hz '
        'tick, lights the Live Activity, writes the live row and notifies once',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = WorkoutHost();
        h.controller.startWorkout(workoutId: 'u4-a', type: 'strength');
        final w = h.controller.activeWorkout!;
        expect(w.workoutId, 'u4-a');
        expect(w.type, 'strength');
        expect(w.targetKcal, 300);
        expect(w.zoneSet, isNotNull, reason: 'pinned from the age at start');
        expect(h.holds, [true]);
        expect(h.calls, containsAll(['rhr', 'radio']));
        expect(h.notifies, 1);
        expect(probe.active(kTick), hasLength(1));
        expect(ScreenWake.owners, contains('workout'));
        await sessionLanded('u4-a');
        expect((await sessionRow('u4-a'))!['status'], 'live');
        expect((await sessionRow('u4-a'))!['device_family'], 'gen4');
        expect(spies.liveActivityMethods, ['start']);
        await h.controller.stopWorkout();
        h.controller.dispose();
        await settleMs(250);
      });
    });

    test('a second start while one is live changes nothing', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = WorkoutHost();
        h.controller.startWorkout(workoutId: 'u4-b', type: 'strength');
        final first = h.controller.activeWorkout;
        h.controller.startWorkout(workoutId: 'u4-b2', type: 'running');
        expect(identical(h.controller.activeWorkout, first), isTrue);
        expect(h.holds, [true]);
        expect(h.notifies, 1);
        expect(probe.active(kTick), hasLength(1));
        await sessionLanded('u4-b');
        await h.controller.stopWorkout();
        h.controller.dispose();
        await settleMs(250);
      });
    });
  });

  group('WorkoutController: tick', () {
    test('a fresh reading is billed as one zone second; the '
        'Live Activity is pushed once per 4 s and the tally snapshotted once '
        'per 30 s', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = WorkoutHost();
        h.controller.startWorkout(workoutId: 'u4-c', type: 'strength');
        await sessionLanded('u4-c');
        final before = h.notifies;
        h.hr = 130;
        h.controller.debugTickWorkout();
        final w = h.controller.activeWorkout!;
        expect(w.currentHr, 130);
        expect(w.zoneSeconds.reduce((a, b) => a + b), 1);
        expect(h.notifies, before + 1);
        expect(spies.liveActivityMethods, ['start', 'update']);
        await tallyLanded('u4-c');
        final first = (await LocalDb.liveWorkoutTally('u4-c'))!['updated_ts'];
        h.controller.debugTickWorkout();
        expect(spies.liveActivityMethods, ['start', 'update'],
            reason: 'inside the 4 s push throttle');
        await settleMs(50);
        expect((await LocalDb.liveWorkoutTally('u4-c'))!['updated_ts'], first,
            reason: 'inside the 30 s snapshot throttle');
        await h.controller.stopWorkout();
        h.controller.dispose();
        await settleMs(250);
      });
    });

    test('an absent reading bills nothing, pushes nothing and still notifies',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = WorkoutHost();
        h.controller.startWorkout(workoutId: 'u4-d', type: 'strength');
        await sessionLanded('u4-d');
        h.hr = null;
        final before = h.notifies;
        h.controller.debugTickWorkout();
        final w = h.controller.activeWorkout!;
        expect(w.currentHr, isNull);
        expect(w.zoneSeconds.every((s) => s == 0), isTrue);
        expect(w.maxHrSeen, 0);
        expect(h.notifies, before + 1);
        expect(spies.liveActivityMethods, ['start']);
        await h.controller.stopWorkout();
        h.controller.dispose();
        await settleMs(250);
      });
    });

    test('with no session a tick is a no-op', () {
      final h = WorkoutHost();
      h.controller.debugTickWorkout();
      expect(h.notifies, 0);
      expect(h.alerts, isEmpty);
    });
  });

  group('WorkoutController: stop and delete', () {
    test('stop banks the finished row, releases both holds and the tick, '
        'bumps the insights once, resyncs and exports when the sync is on',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = WorkoutHost(sync: true);
        h.controller.startWorkout(workoutId: 'u4-e', type: 'strength');
        await sessionLanded('u4-e');
        final before = h.notifies;
        await h.controller.stopWorkout();
        expect(h.controller.activeWorkout, isNull);
        expect(h.holds, [true, false]);
        expect(probe.active(kTick), isEmpty);
        expect(ScreenWake.owners, isNot(contains('workout')));
        final row = (await sessionRow('u4-e'))!;
        expect(row['status'], 'done');
        expect(row['device_family'], 'gen4');
        expect(h.calls.where((c) => c == 'insights'), hasLength(1));
        expect(h.calls, containsAll(['dismiss', 'resync']));
        expect(h.exported, hasLength(1));
        expect(h.exported.single['id'], 'u4-e');
        expect(h.exported.single['status'], 'done');
        expect(h.notifies, before + 1);
        expect(spies.liveActivityMethods, ['start', 'end']);
        h.controller.dispose();
        await settleMs(250);
      });
    });

    test('with the health sync off nothing is exported', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = WorkoutHost();
        h.controller.startWorkout(workoutId: 'u4-f', type: 'strength');
        await sessionLanded('u4-f');
        await h.controller.stopWorkout();
        expect(h.exported, isEmpty);
        h.controller.dispose();
        await settleMs(250);
      });
    });

    test('stop with nothing live does nothing', () async {
      final h = WorkoutHost(sync: true);
      await h.controller.stopWorkout();
      expect(h.holds, isEmpty);
      expect(h.notifies, 0);
      expect(h.calls, isEmpty);
    });

    test('deleting the live session tears it down without banking or '
        'exporting; deleting another id leaves it running', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = DeleteRepo();
        final h = WorkoutHost(sync: true)..repo = repo;
        h.controller.startWorkout(workoutId: 'u4-g', type: 'strength');
        await sessionLanded('u4-g');
        await h.controller.deleteWorkout('somebody-else');
        expect(repo.deleted, ['somebody-else']);
        expect(h.controller.activeWorkout, isNotNull);
        expect(h.holds, [true]);
        final before = h.notifies;
        await h.controller.deleteWorkout('u4-g');
        expect(h.controller.activeWorkout, isNull);
        expect(h.holds, [true, false]);
        expect(probe.active(kTick), isEmpty);
        expect(ScreenWake.owners, isNot(contains('workout')));
        expect(h.exported, isEmpty);
        expect(h.calls, isNot(contains('insights')));
        expect(h.notifies, before + 1);
        expect(repo.deleted, ['somebody-else', 'u4-g']);
        expect((await sessionRow('u4-g'))!['status'], 'live',
            reason: 'the row delete is the repo\'s job, not the teardown\'s');
        h.controller.dispose();
        await settleMs(250);
      });
    });
  });

  group('WorkoutController: reconcile', () {
    test('a recent live row is resumed and takes the same holds a start does',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        await LocalDb.putSession({
          'id': 'u4-h',
          'start_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600,
          'end_ts': null,
          'type': 'strength',
          'status': 'live',
          'source': 'manual',
          'created_at': DateTime.now().millisecondsSinceEpoch - 600000,
        });
        final h = WorkoutHost();
        await h.controller.reconcileOrphanedLiveWorkout();
        expect(h.controller.activeWorkout!.workoutId, 'u4-h');
        expect(h.holds, [true]);
        expect(probe.active(kTick), hasLength(1));
        expect(ScreenWake.owners, contains('workout'));
        expect(h.notifies, 1);
        expect(h.calls, contains('nudge'));
        expect(spies.liveActivityMethods, isEmpty,
            reason: 'a resumed session does not restart the Live Activity');
        await h.controller.stopWorkout();
        h.controller.dispose();
        await settleMs(250);
      });
    });

    test('a stale row is finalized with a fabricated end stamp, never '
        'resumed', () async {
      await LocalDb.putSession({
        'id': 'u4-i',
        'start_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 8 * 3600,
        'end_ts': null,
        'type': 'strength',
        'status': 'live',
        'source': 'manual',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      final h = WorkoutHost(sync: true);
      await h.controller.reconcileOrphanedLiveWorkout();
      expect(h.controller.activeWorkout, isNull);
      expect(h.holds, isEmpty);
      expect(h.notifies, 0);
      final row = (await sessionRow('u4-i'))!;
      expect(row['status'], 'done');
      expect(row['end_ts_fabricated'], 1);
      expect(h.exported, isEmpty);
      expect(h.calls, contains('dismiss'));
    });

    test('with no live row it does nothing', () async {
      final h = WorkoutHost();
      await h.controller.reconcileOrphanedLiveWorkout();
      expect(h.controller.activeWorkout, isNull);
      expect(h.notifies, 0);
    });
  });

  group('WorkoutController: the live-workout step state', () {
    test('unmeasured until a gait sample arrives, then the raw delta since the '
        'start, and a pedometer reset rebases without losing the steps',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = WorkoutHost()..raw = 100;
        expect(h.controller.workoutStepsMeasured, isNull,
            reason: 'no session');
        h.controller.startWorkout(workoutId: 'u4-j', type: 'running');
        await sessionLanded('u4-j');
        h.raw = 160;
        expect(h.controller.workoutStepsMeasured, isNull,
            reason: 'no gait-capable sample has been seen');
        h.controller.noteWorkoutSample();
        expect(h.controller.workoutStepsMeasured,
            (60 * ana.StepParams.gain).round());
        // The pedometer is about to zero its counter: rebase first.
        h.controller.rebaseWorkoutSteps();
        h.raw = 0;
        expect(h.controller.workoutStepsMeasured,
            (60 * ana.StepParams.gain).round());
        h.raw = 40;
        expect(h.controller.workoutStepsMeasured,
            (100 * ana.StepParams.gain).round());
        await h.controller.stopWorkout();
        final row = (await sessionRow('u4-j'))!;
        expect(row['steps'], (100 * ana.StepParams.gain).round());
        expect(h.controller.workoutStepsMeasured, isNull,
            reason: 'cleared with the session');
        h.controller.dispose();
        await settleMs(250);
      });
    });

    test('minute steps are dropped when no workout is active', () {
      final h = WorkoutHost();
      h.controller.addWorkoutMinuteSteps(100);
      h.controller.rebaseWorkoutSteps();
      expect(h.controller.workoutStepsMeasured, isNull);
      expect(h.notifies, 0);
    });
  });

  group('WorkoutController: dispose', () {
    test('cancels the tick and nothing else; a later tick still runs and '
        'does not throw', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = WorkoutHost();
        h.controller.startWorkout(workoutId: 'u4-k', type: 'strength');
        await sessionLanded('u4-k');
        expect(probe.active(kTick), hasLength(1));
        h.controller.dispose();
        expect(probe.active(kTick), isEmpty);
        expect(h.controller.activeWorkout, isNotNull);
        expect(ScreenWake.owners, contains('workout'));
        expect(h.holds, [true], reason: 'the hold is not given back');
        expect(h.controller.debugTickWorkout, returnsNormally);
        await settleMs(250);
      });
    });

    test('debugArmTimer arms one 1 Hz timer and dispose cancels it', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = WorkoutHost();
        h.controller.debugArmTimer();
        h.controller.debugArmTimer();
        expect(probe.active(kTick), hasLength(1));
        h.controller.dispose();
        expect(probe.active(kTick), isEmpty);
      });
    });
  });

  group('BreathingController: the buffer', () {
    test('frames are kept only while a session or a window is open, and '
        'bounded at 8000', () async {
      final h = BreathHost();
      final c = h.controller;
      c.tapFrame('a');
      expect(c.debugFrames, isEmpty);
      await c.openBreathingWindow();
      for (var i = 0; i < 8100; i++) {
        c.tapFrame('f$i');
      }
      expect(c.debugFrames, hasLength(8000));
      expect(c.debugFrames.first, 'f0');
      expect(c.debugFrames.last, 'f7999');
      await c.closeBreathingWindow();
      expect(c.debugFrames, isEmpty, reason: 'the window close clears it');
      c.tapFrame('after');
      expect(c.debugFrames, isEmpty);
    });

    test('a session start clears the buffer and hands the open window\'s '
        'frames over as the pre window', () async {
      final h = BreathHost();
      final c = h.controller;
      await c.openBreathingWindow();
      c.tapFrame('pre1');
      c.tapFrame('pre2');
      await c.startBreathingSession();
      expect(c.debugFrames, isEmpty);
      c.tapFrame('paced');
      expect(c.debugFrames, ['paced']);
      await c.stopBreathingSession();
      expect(c.debugFrames, isEmpty,
          reason: 'with a window open, stop clears the paced frames');
      await c.closeBreathingWindow();
      c.dispose();
    });
  });

  group('BreathingController: start, stop, windows', () {
    test('disconnected: a start or a window open sets the error, notifies '
        'once and starts nothing', () async {
      final h = BreathHost(connected: false);
      await h.controller.startBreathingSession();
      expect(h.controller.breathingError, 'Connect your band first.');
      expect(h.controller.breathingActive, isFalse);
      expect(h.notifies, 1);
      await h.controller.openBreathingWindow();
      expect(h.controller.breathingWindowOpen, isFalse);
      expect(h.notifies, 2);
      expect(h.calls, isEmpty);
      expect(spies.breathingMethods, isEmpty);
    });

    test('a start arms the 20 s recompute, reconciles the streams, lights '
        'the Live Activity and keeps the pattern and target', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = BreathHost();
        final c = h.controller;
        await c.startBreathingSession(
          pattern: kBreathPatterns.last,
          target: const Duration(minutes: 2),
        );
        expect(c.breathingActive, isTrue);
        expect(c.breathingPattern, same(kBreathPatterns.last));
        expect(c.breathingTarget, const Duration(minutes: 2));
        expect(c.breathingStartedAt, isNotNull);
        expect(h.calls, ['reconcile']);
        expect(h.notifies, 1);
        expect(probe.active(kBreathRecompute), hasLength(1));
        expect(spies.breathingMethods, ['start']);
        await c.startBreathingSession();
        expect(h.calls, ['reconcile'], reason: 'a second start is ignored');
        await c.stopBreathingSession();
        c.dispose();
      });
    });

    test('the recompute scores the buffered frames against the pattern\'s '
        'paced rate, stores the result and notifies; nothing buffered, '
        'nothing asked', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = BreathHost();
        final repo = h.repo as BreathRepo;
        final c = h.controller;
        await c.startBreathingSession();
        final timer = probe.active(kBreathRecompute).single;
        timer.fire();
        await settleMs(30);
        expect(repo.coherenceCalls, isEmpty);
        c.tapFrame('f1');
        c.tapFrame('f2');
        final before = h.notifies;
        timer.fire();
        await settleMs(30);
        expect(repo.coherenceCalls.single.frames, ['f1', 'f2']);
        expect(repo.coherenceCalls.single.pacedHz, c.breathingPattern.pacedHz);
        expect(c.breathingResult!['score'], 72.0);
        expect(h.notifies, before + 1);
        await c.stopBreathingSession();
        c.dispose();
      });
    });

    test('a recompute that fails keeps the last good result', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = BreathHost();
        final repo = h.repo as BreathRepo;
        final c = h.controller;
        await c.startBreathingSession();
        c.tapFrame('f1');
        final timer = probe.active(kBreathRecompute).single;
        timer.fire();
        await settleMs(30);
        final good = c.breathingResult;
        repo.throwsOnCoherence = StateError('boom');
        timer.fire();
        await settleMs(30);
        expect(identical(c.breathingResult, good), isTrue);
        await c.stopBreathingSession();
        c.dispose();
      });
    });

    test('a session under a minute is not banked; stop gives the timer and '
        'the Live Activity back and nudges the streams', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = BreathHost();
        final c = h.controller;
        await c.startBreathingSession();
        await c.stopBreathingSession();
        expect(c.breathingActive, isFalse);
        expect(c.breathingStartedAt, isNull);
        expect(c.breathingTarget, isNull);
        expect(probe.active(kBreathRecompute), isEmpty);
        expect(h.calls, ['reconcile', 'nudge']);
        expect(spies.breathingMethods, ['start', 'end']);
        expect(await c.breathingHistory(), isEmpty);
        c.dispose();
      });
    });

    test('stop with nothing running does nothing; closing a window that is '
        'not open does nothing', () async {
      final h = BreathHost();
      await h.controller.stopBreathingSession();
      await h.controller.closeBreathingWindow();
      expect(h.notifies, 0);
      expect(h.calls, isEmpty);
    });

    test('a window open then close nudges the streams once and notifies on '
        'each edge; an open while a session runs is ignored', () async {
      final h = BreathHost();
      final c = h.controller;
      await c.openBreathingWindow();
      expect(c.breathingWindowOpen, isTrue);
      expect(h.calls, ['reconcile']);
      expect(h.notifies, 1);
      await c.openBreathingWindow();
      expect(h.notifies, 1, reason: 'already open');
      await c.closeBreathingWindow();
      expect(c.breathingWindowOpen, isFalse);
      expect(h.calls, ['reconcile', 'nudge']);
      expect(h.notifies, 2);
      await c.startBreathingSession();
      await c.openBreathingWindow();
      expect(c.breathingWindowOpen, isFalse);
      await c.stopBreathingSession();
      c.dispose();
    });

    test('the Live Activity stop flag ends the session and the window, and '
        'is consumed even when nothing is running', () async {
      final h = BreathHost();
      final c = h.controller;
      spies.widgetFlags['end_breathing_session'] = true;
      await c.maybeStopBreathingFromLiveActivity();
      expect(spies.widgetFlags['end_breathing_session'], false);
      await c.openBreathingWindow();
      await c.startBreathingSession();
      spies.widgetFlags['end_breathing_session'] = true;
      await c.maybeStopBreathingFromLiveActivity();
      expect(c.breathingActive, isFalse);
      expect(c.breathingWindowOpen, isFalse);
      c.dispose();
    });
  });

  group('BreathingController: cues and dispose', () {
    test('each phase kind maps to its own pattern and the session-complete '
        'cue is pattern 4, all through the injected dispatcher', () {
      final h = BreathHost();
      for (final k in BreathPhaseKind.values) {
        h.controller.buzzBreathPhase(k);
      }
      h.controller.buzzSessionComplete();
      expect(h.cues, [
        for (final k in BreathPhaseKind.values)
          (
            'breath',
            switch (k) {
              BreathPhaseKind.inhale || BreathPhaseKind.work => 1,
              BreathPhaseKind.exhale || BreathPhaseKind.rest => 0,
              BreathPhaseKind.holdIn || BreathPhaseKind.holdOut => 2,
            }
          ),
        ('breath', 4),
      ]);
    });

    test('disconnected, no cue is sent', () {
      final h = BreathHost(connected: false);
      h.controller.buzzBreathPhase(BreathPhaseKind.inhale);
      h.controller.buzzSessionComplete();
      expect(h.cues, isEmpty);
    });

    test('dispose cancels the recompute timer but does not end the session, '
        'and debugArmTimer arms exactly one', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final h = BreathHost();
        final c = h.controller;
        await c.startBreathingSession();
        expect(probe.active(kBreathRecompute), hasLength(1));
        c.dispose();
        expect(probe.active(kBreathRecompute), isEmpty);
        expect(c.breathingActive, isTrue);
        expect(spies.breathingMethods, ['start']);
        final h2 = BreathHost();
        h2.controller.debugArmTimer();
        h2.controller.debugArmTimer();
        expect(probe.active(kBreathRecompute), hasLength(1));
        h2.controller.dispose();
        expect(probe.active(kBreathRecompute), isEmpty);
      });
    });
  });
}
