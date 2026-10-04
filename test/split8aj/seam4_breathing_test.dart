// 8AJ seam 4 characterization: the guided-breathing session and its quiet
// windows through AppState: start / stop / window transitions, the frame
// buffer (only R-R-bearing frames, only while a session or window is open,
// capped at 8000), the 20 s coherence recompute, the Live Activity, history,
// and the notify counts. Must pass before and after the WorkoutController
// move.
//
// The buffer is private; what it holds is read through what the recompute
// hands the repo. A session shorter than 60 s is never banked (a wall-clock
// rule, so the banked path has its own file: seam4_breathing_banked_test.dart).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show BandProfile;

import 'support/live_harness.dart';
import 'support/workout_harness.dart';

const _db = 'split8aj_seam4_breathing.db';

// Fixed strap timestamp: the builders default to the wall-clock second, so a
// frame built twice (once to feed, once to compare) differs when the second
// rolls over in between.
const _ts = 1790000000;
String _hr28() => hexOf(hr28Inner(rr: const [800, 810], ts: _ts));
String _r10() => hexOf(r10LiveInner(ts: _ts));
String _r21() => hexOf(r21LiveInner(unix: _ts));
String _imu33() => hexOf(imu33Inner(ts: _ts));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    spies = PlatformSpies();
  });
  tearDown(() async {
    // Fire-and-forget device-row writes of the fake link settle first.
    await settleMs(300);
    spies.dispose();
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  Future<AppState> connected({BreathRepo? repo}) async {
    final app = AppState.forTesting();
    app.device.connection = 'connected';
    if (repo != null) app.repo = repo;
    return app;
  }

  void feed(AppState app, String hex, int pt, [int n = 1]) {
    for (var i = 0; i < n; i++) {
      app.debugOnLiveFrame(pt, hex, 1790000000 + i);
    }
  }

  group('session start / stop', () {
    test('without a band: an error, one notify, nothing started', () async {
      final app = AppState.forTesting();
      final ticks = TickCounter(app);
      await app.startBreathingSession();
      expect(app.breathingActive, isFalse);
      expect(app.breathingError, 'Connect your band first.');
      expect(app.breathingStartedAt, isNull);
      expect(ticks.ticks, 1);
      expect(spies.breathingActivity, isEmpty);
      ticks.stop();
      await finish(app);
    });

    test('a window without a band is the same refusal', () async {
      final app = AppState.forTesting();
      final ticks = TickCounter(app);
      await app.openBreathingWindow();
      expect(app.breathingWindowOpen, isFalse);
      expect(app.breathingError, 'Connect your band first.');
      expect(ticks.ticks, 1);
      ticks.stop();
      await finish(app);
    });

    test('start: active, pattern and target held, result and error cleared, '
        'one notify, Live Activity started with "calibrating"', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = await connected();
        app.breathingError = 'old error';
        app.breathingResult = {'ok': true, 'score': 1.0};
        final ticks = TickCounter(app);
        final before = DateTime.now();
        final box = kBreathPatternsByKey['box']!;
        await app.startBreathingSession(
            pattern: box, target: const Duration(minutes: 5));
        expect(app.breathingActive, isTrue);
        expect(app.breathingPattern, same(box));
        expect(app.breathingTarget, const Duration(minutes: 5));
        expect(app.breathingResult, isNull);
        expect(app.breathingError, isNull);
        expect(app.breathingStartedAt!.isBefore(before), isFalse);
        expect(ticks.ticks, 1);
        expect(spies.breathingMethods, ['start']);
        expect((spies.breathingActivity.single.args as Map)['coherenceScore'],
            -1.0);
        expect(probe.active(kBreathRecompute), hasLength(1));
        ticks.stop();
        await finish(app);
      });
    });

    test('with no pattern given the last pattern is kept (it starts as the '
        'first one)', () async {
      final app = await connected();
      expect(app.breathingPattern, same(kBreathPatterns.first));
      await app.startBreathingSession();
      expect(app.breathingPattern, same(kBreathPatterns.first));
      await app.stopBreathingSession();
      final box = kBreathPatternsByKey['box']!;
      await app.startBreathingSession(pattern: box);
      await app.stopBreathingSession();
      await app.startBreathingSession();
      expect(app.breathingPattern, same(box),
          reason: 'sticky across sessions');
      await finish(app);
    });

    test('a second start while active is a no-op', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = await connected();
        await app.startBreathingSession(target: const Duration(minutes: 2));
        final startedAt = app.breathingStartedAt;
        final ticks = TickCounter(app);
        await app.startBreathingSession(target: const Duration(minutes: 9));
        expect(app.breathingStartedAt, startedAt);
        expect(app.breathingTarget, const Duration(minutes: 2));
        expect(ticks.ticks, 0);
        expect(spies.breathingMethods, ['start']);
        expect(probe.periodics, hasLength(1));
        ticks.stop();
        await finish(app);
      });
    });

    test('stop under a minute: ended and cleared, one notify, Live Activity '
        'ended, and NOT banked', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = await connected();
        await app.startBreathingSession(target: const Duration(minutes: 3));
        final ticks = TickCounter(app);
        await app.stopBreathingSession();
        expect(app.breathingActive, isFalse);
        expect(app.breathingStartedAt, isNull);
        expect(app.breathingTarget, isNull);
        expect(probe.active(kBreathRecompute), isEmpty);
        expect(ticks.ticks, 1);
        expect(spies.breathingMethods, ['start', 'end']);
        expect(await app.breathingHistory(), isEmpty,
            reason: 'shorter than a minute is not a session');
        ticks.stop();
        await finish(app);
      });
    });

    test('stop with nothing active is a no-op', () async {
      final app = AppState.forTesting();
      final ticks = TickCounter(app);
      await app.stopBreathingSession();
      expect(ticks.ticks, 0);
      expect(spies.breathingActivity, isEmpty);
      ticks.stop();
      await finish(app);
    });

    test('the last result survives stop (the screen shows it after the end)',
        () async {
      final app = await connected(repo: BreathRepo());
      await app.startBreathingSession();
      app.breathingResult = {'ok': true, 'score': 55.0};
      await app.stopBreathingSession();
      expect(app.breathingResult, {'ok': true, 'score': 55.0});
      await app.startBreathingSession();
      expect(app.breathingResult, isNull, reason: 'cleared by the next start');
      await finish(app);
    });
  });

  group('the quiet window', () {
    test('open: flag set, error and buffer reset, one notify; a repeat is a '
        'no-op', () async {
      final app = await connected();
      final ticks = TickCounter(app);
      await app.openBreathingWindow();
      expect(app.breathingWindowOpen, isTrue);
      expect(ticks.ticks, 1);
      await app.openBreathingWindow();
      expect(ticks.ticks, 1);
      ticks.stop();
      await finish(app);
    });

    test('a window cannot open while a session is active', () async {
      final app = await connected();
      await app.startBreathingSession();
      final ticks = TickCounter(app);
      await app.openBreathingWindow();
      expect(app.breathingWindowOpen, isFalse);
      expect(ticks.ticks, 0);
      ticks.stop();
      await finish(app);
    });

    test('close: flag cleared, one notify; closing with none open is a no-op',
        () async {
      final app = await connected();
      await app.closeBreathingWindow();
      await app.openBreathingWindow();
      final ticks = TickCounter(app);
      await app.closeBreathingWindow();
      expect(app.breathingWindowOpen, isFalse);
      expect(ticks.ticks, 1);
      await app.closeBreathingWindow();
      expect(ticks.ticks, 1);
      ticks.stop();
      await finish(app);
    });

    test('stop with a window open keeps the window open and notifies once',
        () async {
      final app = await connected();
      await app.openBreathingWindow();
      await app.startBreathingSession();
      final ticks = TickCounter(app);
      await app.stopBreathingSession();
      expect(app.breathingActive, isFalse);
      expect(app.breathingWindowOpen, isTrue);
      expect(ticks.ticks, 1);
      ticks.stop();
      await finish(app);
    });
  });

  group('the frame buffer (read through what the recompute hands the repo)',
      () {
    test('only R-R-bearing frames are kept: 0x28 and an R10 0x2B; not a '
        'rev-21 IMU 0x2B, not 0x33', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = BreathRepo();
        final app = await connected(repo: repo);
        await app.startBreathingSession();
        feed(app, _hr28(), 0x28);
        feed(app, _r10(), 0x2B);
        feed(app, _r21(), 0x2B);
        feed(app, _imu33(), 0x33);
        probe.active(kBreathRecompute).single.fire();
        await settleMs(50);
        expect(repo.coherenceCalls, hasLength(1));
        expect(repo.coherenceCalls.single.frames, [_hr28(), _r10()]);
        await finish(app);
      });
    });

    test('frames outside a session or window are not buffered, and an empty '
        'buffer is not handed to the repo', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = BreathRepo();
        final app = await connected(repo: repo);
        feed(app, _hr28(), 0x28, 3); // nobody listening
        await app.startBreathingSession();
        probe.active(kBreathRecompute).single.fire();
        await settleMs(50);
        expect(repo.coherenceCalls, isEmpty,
            reason: 'an empty buffer is not handed over');
        feed(app, _hr28(), 0x28, 2);
        probe.active(kBreathRecompute).single.fire();
        await settleMs(50);
        expect(repo.coherenceCalls.single.frames, hasLength(2));
        await finish(app);
      });
    });

    test('a window buffers too, and a session that starts inside it clears '
        'the buffer (the window\'s frames become the pre window)', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = BreathRepo();
        final app = await connected(repo: repo);
        await app.openBreathingWindow();
        feed(app, _hr28(), 0x28, 4);
        await app.startBreathingSession();
        feed(app, _hr28(), 0x28, 1);
        probe.active(kBreathRecompute).single.fire();
        await settleMs(50);
        expect(repo.coherenceCalls.single.frames, hasLength(1));
        await finish(app);
      });
    });

    test('the buffer stops growing at 8000 frames', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = BreathRepo();
        final app = await connected(repo: repo);
        await app.startBreathingSession();
        feed(app, _hr28(), 0x28, 8005);
        probe.active(kBreathRecompute).single.fire();
        await settleMs(100);
        expect(repo.coherenceCalls.single.frames, hasLength(8000));
        await finish(app);
      });
    });

    test('feeding frames never notifies (the buffer is not UI state)',
        () async {
      final app = await connected();
      await app.startBreathingSession();
      final ticks = TickCounter(app);
      feed(app, _hr28(), 0x28, 20);
      expect(ticks.ticks, 0);
      ticks.stop();
      await finish(app);
    });
  });

  group('the 20 s recompute', () {
    test('hands the repo the frames so far and the pattern\'s own paced '
        'frequency, stores the answer, notifies once and pushes the score',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = BreathRepo();
        final app = await connected(repo: repo);
        final box = kBreathPatternsByKey['box']!;
        await app.startBreathingSession(pattern: box);
        feed(app, _hr28(), 0x28, 3);
        final ticks = TickCounter(app);
        probe.active(kBreathRecompute).single.fire();
        await until(() => spies.breathingMethods.length >= 2);
        expect(repo.coherenceCalls.single.pacedHz, box.pacedHz);
        expect(app.breathingResult, repo.result);
        expect(ticks.ticks, 1);
        expect(spies.breathingMethods, ['start', 'update']);
        expect((spies.breathingActivity.last.args as Map)['coherenceScore'],
            72.0);
        // The FULL series so far, not a window: a second fire sees more.
        feed(app, _hr28(), 0x28, 2);
        probe.active(kBreathRecompute).single.fire();
        await settleMs(50);
        expect(repo.coherenceCalls.last.frames, hasLength(5));
        ticks.stop();
        await finish(app);
      });
    });

    test('a not-ok answer is shown, and pushes "calibrating" (-1), never a '
        'made-up score', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = BreathRepo()..result = {'ok': false, 'note': 'too few'};
        final app = await connected(repo: repo);
        await app.startBreathingSession();
        feed(app, _hr28(), 0x28);
        probe.active(kBreathRecompute).single.fire();
        await until(() => spies.breathingMethods.length >= 2);
        expect(app.breathingResult, {'ok': false, 'note': 'too few'});
        expect((spies.breathingActivity.last.args as Map)['coherenceScore'],
            -1.0);
        await finish(app);
      });
    });

    test('a repo that throws keeps the last good result and does not notify',
        () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = BreathRepo();
        final app = await connected(repo: repo);
        await app.startBreathingSession();
        feed(app, _hr28(), 0x28);
        probe.active(kBreathRecompute).single.fire();
        await settleMs(50);
        final good = app.breathingResult;
        repo.throwsOnCoherence = StateError('boom');
        final ticks = TickCounter(app);
        probe.active(kBreathRecompute).single.fire();
        await settleMs(50);
        expect(app.breathingResult, good);
        expect(ticks.ticks, 0);
        ticks.stop();
        await finish(app);
      });
    });

    test('an answer that lands after the session ended is dropped', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final repo = BreathRepo()..gate = Completer<void>();
        final app = await connected(repo: repo);
        await app.startBreathingSession();
        feed(app, _hr28(), 0x28);
        probe.active(kBreathRecompute).single.fire();
        await settleMs(30);
        expect(repo.coherenceCalls, hasLength(1));
        await app.stopBreathingSession();
        final updates =
            spies.breathingMethods.where((m) => m == 'update').length;
        final ticks = TickCounter(app);
        repo.gate!.complete();
        await settleMs(50);
        expect(app.breathingResult, isNull);
        expect(ticks.ticks, 0);
        expect(spies.breathingMethods.where((m) => m == 'update').length, updates);
        ticks.stop();
        await finish(app);
      });
    });

    test('with no repo the timer fires and nothing happens', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = await connected();
        await app.startBreathingSession();
        feed(app, _hr28(), 0x28);
        final ticks = TickCounter(app);
        probe.active(kBreathRecompute).single.fire();
        await settleMs(30);
        expect(app.breathingResult, isNull);
        expect(ticks.ticks, 0);
        ticks.stop();
        await finish(app);
      });
    });

    test('a start after a stop arms a fresh timer; the old one stays '
        'cancelled', () async {
      final probe = TimerProbe();
      await probe.run(() async {
        final app = await connected();
        await app.startBreathingSession();
        final first = probe.active(kBreathRecompute).single;
        await app.stopBreathingSession();
        expect(first.cancelled, isTrue);
        await app.startBreathingSession();
        final live = probe.active(kBreathRecompute);
        expect(live, hasLength(1));
        expect(identical(live.single, first), isFalse);
        await finish(app);
      });
    });
  });

  group('history and Live Activity flags', () {
    test('breathingHistory reads the stored sessions newest first, with a '
        'limit', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      for (var i = 1; i <= 3; i++) {
        await LocalDb.putBreathingSession(
            startedAt: i * 1000,
            endedAt: i * 1000 + 90000,
            pattern: 'box',
            seconds: 90);
      }
      final all = await app.breathingHistory();
      expect([for (final r in all) r['started_at']], [3000, 2000, 1000]);
      final one = await app.breathingHistory(limit: 1);
      expect(one.single['started_at'], 3000);
    });

    test('the Live Activity "end" flag stops a session AND closes its '
        'window, and is consumed', () async {
      final app = await connected();
      await app.openBreathingWindow();
      await app.startBreathingSession();
      spies.widgetFlags['end_breathing_session'] = true;
      await app.maybeStopBreathingFromLiveActivity();
      expect(app.breathingActive, isFalse);
      expect(app.breathingWindowOpen, isFalse);
      expect(spies.widgetFlags['end_breathing_session'], false);
      await finish(app);
    });

    test('with the flag unset nothing is touched (the window stays)',
        () async {
      final app = await connected();
      await app.openBreathingWindow();
      await app.startBreathingSession();
      await app.maybeStopBreathingFromLiveActivity();
      expect(app.breathingActive, isTrue);
      expect(app.breathingWindowOpen, isTrue);
      await finish(app);
    });

    test('a set flag with nothing running is consumed and does nothing',
        () async {
      final app = AppState.forTesting();
      spies.widgetFlags['end_breathing_session'] = true;
      final ticks = TickCounter(app);
      await app.maybeStopBreathingFromLiveActivity();
      expect(spies.widgetFlags['end_breathing_session'], false);
      expect(ticks.ticks, 0);
      ticks.stop();
      await finish(app);
    });

    test('the workout Live Activity flag stops the workout; a flag with no '
        'workout is consumed and the NEXT workout is not ended by it',
        () async {
      final app = AppState.forTesting();
      spies.widgetFlags['end_session'] = true;
      await app.maybeFinishFromLiveActivity();
      expect(spies.widgetFlags['end_session'], false);
      app.startWorkout(workoutId: 'w4-la1', type: 'strength');
      await app.maybeFinishFromLiveActivity();
      expect(app.activeWorkout, isNotNull, reason: 'the stale tap was spent');
      spies.widgetFlags['end_session'] = true;
      await app.maybeFinishFromLiveActivity();
      expect(app.activeWorkout, isNull);
      expect((await sessionRow('w4-la1'))!['status'], 'done');
      await finish(app);
    });
  });

  group('session cues over the band', () {
    // One rig per cue: the haptics queue holds a second cue until the band
    // reports the first one ended, which a bare fake link never does.
    Future<String> bodyOf(void Function(AppState) cue,
        {BandProfile band = BandProfile.gen4}) async {
      final rig = G6Rig(band: band);
      cue(rig.app);
      await until(() => rig.writes.isNotEmpty);
      await settleMs(50);
      final writes = [for (final w in rig.writes) w];
      await finish(rig.app);
      BleEngine.resetBandClaimForTest();
      expect(writes, hasLength(1));
      return '${writes.single.opcode}:${writes.single.body}';
    }

    test('connected: each phase kind maps to a pattern (inhale = work, '
        'exhale = rest, the two holds alike), and the session-complete cue '
        'is its own', () async {
      final inhale = await bodyOf((a) => a.buzzBreathPhase(BreathPhaseKind.inhale));
      final work = await bodyOf((a) => a.buzzBreathPhase(BreathPhaseKind.work));
      final exhale = await bodyOf((a) => a.buzzBreathPhase(BreathPhaseKind.exhale));
      final rest = await bodyOf((a) => a.buzzBreathPhase(BreathPhaseKind.rest));
      final holdIn = await bodyOf((a) => a.buzzBreathPhase(BreathPhaseKind.holdIn));
      final holdOut = await bodyOf((a) => a.buzzBreathPhase(BreathPhaseKind.holdOut));
      final complete = await bodyOf((a) => a.buzzSessionComplete());
      expect(inhale, work);
      expect(exhale, rest);
      expect(holdIn, holdOut);
      expect({inhale, exhale, holdIn, complete}, hasLength(4),
          reason: 'four distinguishable cues');
    });

    test('on a gen5 link every kind writes the same buzz today (the phase '
        'index only shapes a gen4 pattern)', () async {
      final a = await bodyOf((a) => a.buzzBreathPhase(BreathPhaseKind.inhale),
          band: BandProfile.gen5);
      final b = await bodyOf((a) => a.buzzBreathPhase(BreathPhaseKind.exhale),
          band: BandProfile.gen5);
      final c = await bodyOf((a) => a.buzzSessionComplete(),
          band: BandProfile.gen5);
      expect({a, b, c}, hasLength(1));
    });

    test('disconnected: a phase cue and the session-complete cue write '
        'nothing', () async {
      final rig = G6Rig(connected: false);
      rig.app.buzzBreathPhase(BreathPhaseKind.inhale);
      rig.app.buzzSessionComplete();
      await settleMs(300);
      expect(rig.writes, isEmpty);
      await finish(rig.app);
      BleEngine.resetBandClaimForTest();
    });
  });
}
