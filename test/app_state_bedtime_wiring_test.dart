// Bedtime breathing cues, AppState seam: AppState.buildBedtimeSession hands the
// controller (lib/explore/bedtime) what it needs and nothing else.
//   * the live HR stream is owned while a session runs, released once on every
//     way out (AGENTS 4.3);
//   * the stage estimate comes from the observer the Natural Wake orchestrator
//     uses, not a second stager (AGENTS 3.8);
//   * a cue counts as sent only when the band delivery really happened.
// Evidence for the feature: Tsai et al. 2015, doi:10.1111/psyp.12333.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_pacing_policy.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_session_controller.dart';

import 'support/app_state_live_harness.dart';
import 'support/app_state_workout_harness.dart';
import 'support/wake_fakes.dart';

const _db = 'app_state_bedtime_wiring.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
  });
  tearDown(() async {
    await settleMs(300);
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  Future<void> done(G6Rig rig, [BedtimeSessionController? s]) async {
    s?.dispose();
    await finish(rig.app);
  }

  group('the live HR stream owner', () {
    test('a running session owns HR; stop releases it', () async {
      final rig = G6Rig();
      final s = rig.app.buildBedtimeSession(BedtimePlan());
      expect(rig.app.debugLiveOwners.breathing, isFalse);
      await s.start();
      expect(s.state, BedtimeState.running);
      expect(rig.app.debugLiveOwners.breathing, isTrue);
      await s.stop();
      expect(rig.app.debugLiveOwners.breathing, isFalse);
      await done(rig, s);
    });

    test('disposing a running session releases it, and exactly once', () async {
      final rig = G6Rig();
      final a = rig.app.buildBedtimeSession(BedtimePlan());
      final b = rig.app.buildBedtimeSession(BedtimePlan());
      await a.start();
      await b.start();
      a.dispose();
      expect(rig.app.debugLiveOwners.breathing, isTrue,
          reason: 'the other session still holds it');
      await a.stop(); // already ended: must not release a second time
      expect(rig.app.debugLiveOwners.breathing, isTrue);
      b.dispose();
      expect(rig.app.debugLiveOwners.breathing, isFalse);
      await done(rig);
    });
  });

  group('the stage observer', () {
    test('is the one the wake orchestrator uses, fed from the same samples',
        () async {
      final rig = G6Rig();
      final observer = ScriptedObserver()..next = remObs();
      rig.app.debugWakeObserver = observer;
      final s = rig.app
          .buildBedtimeSession(BedtimePlan(stopOnSleep: true));
      await s.start();
      await s.tick();
      await until(() => observer.requests.isNotEmpty);
      expect(observer.requests, hasLength(1));
      expect(observer.requests.single.priorState, isNull,
          reason: 'the first look at the night starts the stager fresh');
      await until(() => s.sleepEstimate != 'unavailable');
      expect(s.sleepEstimate, 'not yet sustained',
          reason: 'what the shared observer said reaches the screen');
      await s.stop();
      await done(rig, s);
    });

    test('an observer that fails is an unavailable estimate, never awake',
        () async {
      final rig = G6Rig();
      final observer = ScriptedObserver()..failWith = StateError('isolate gone');
      rig.app.debugWakeObserver = observer;
      final s = rig.app
          .buildBedtimeSession(BedtimePlan(stopOnSleep: true));
      await s.start();
      await s.tick();
      await until(() => observer.requests.isNotEmpty);
      await settleMs(50);
      expect(s.sleepEstimate, 'unavailable');
      expect(s.state, BedtimeState.running);
      await s.stop();
      await done(rig, s);
    });
  });

  group('cue delivery', () {
    test('a cue that went out on the band is sent, and is a band write',
        () async {
      final rig = G6Rig();
      final s = rig.app.buildBedtimeSession(BedtimePlan());
      await s.start();
      rig.writes.clear(); // the stream enable is not a cue
      await s.tick();
      expect(s.cuesSent, 1);
      expect(s.cuesMissed, 0);
      expect(rig.writes, isNotEmpty);
      await s.stop();
      await done(rig, s);
    });

    test('a cue the band queue refused is missed, not sent', () async {
      final rig = G6Rig();
      // The shared haptic budget is full: a phase cue is rejected at once.
      rig.app.haptics.ledger.record(30, DateTime.now());
      final s = rig.app.buildBedtimeSession(BedtimePlan());
      await s.start();
      rig.writes.clear(); // the stream enable is not a cue
      await s.tick();
      expect(s.cuesSent, 0);
      expect(s.cuesMissed, 1);
      expect(rig.writes, isEmpty);
      await s.stop();
      await done(rig, s);
    });
  });
}
