// 8AJ seam 2 characterization: live-stream owner bookkeeping through AppState
// (developer live feed, mounted live-HR views, movement-sampling window,
// background) and what each change asks of the engine. Must pass before and
// after the LiveStreamController move.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_derive_harness.dart' show TickCounter;
import 'support/app_state_live_harness.dart';

const _hr = Cmd.toggleRealtimeHr;
const _imu = Cmd.toggleImuMode;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  group('developer live feed', () {
    test('a fresh app: feed off, owner set is just "foreground"', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(app.isLiveFeedOn(kBandId), isFalse);
      final o = app.debugLiveOwners;
      expect(o.developerLiveFeed, isFalse);
      expect(o.foreground, isTrue);
      expect(o.visibleLiveHrView, isFalse);
      expect(o.activeWorkout, isFalse);
      expect(o.breathing, isFalse);
      expect(o.movementSampling, isFalse);
    });

    test('start sets the owner and asks the engine for HR then IMU; stop '
        'releases it and the engine turns them off', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await rig.app.startLiveFeed(kBandId);
      await rig.settle();
      expect(rig.app.isLiveFeedOn(kBandId), isTrue);
      expect(rig.app.debugLiveOwners.developerLiveFeed, isTrue);
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
      rig.writes.clear();
      await rig.app.stopLiveFeed(kBandId);
      await rig.settle();
      expect(rig.app.isLiveFeedOn(kBandId), isFalse);
      expect(rig.app.debugLiveOwners.developerLiveFeed, isFalse);
      expect(rig.ops, [(_imu, 0), (_hr, 0)]);
    });

    test('only the band (primary id) has a feed: another id is ignored, no '
        'notify, no engine write', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      final ticks = TickCounter(rig.app)..ticks = 0;
      await rig.app.startLiveFeed('polar-1');
      await rig.app.stopLiveFeed('polar-1');
      await rig.settle();
      expect(rig.app.isLiveFeedOn('polar-1'), isFalse);
      expect(rig.app.debugLiveOwners.developerLiveFeed, isFalse);
      expect(ticks.ticks, 0);
      expect(rig.writes, isEmpty);
      ticks.stop();
    });

    test('notifyListeners: one tick on the first start, none when already on; '
        'one tick on stop, none on a stop without start', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      final ticks = TickCounter(rig.app);
      await rig.app.stopLiveFeed(kBandId);
      expect(ticks.ticks, 0, reason: 'stop without start');
      await rig.app.startLiveFeed(kBandId);
      expect(ticks.ticks, 1);
      await rig.app.startLiveFeed(kBandId);
      expect(ticks.ticks, 1, reason: 'idempotent: no second notify');
      await rig.app.stopLiveFeed(kBandId);
      expect(ticks.ticks, 2);
      await rig.app.stopLiveFeed(kBandId);
      expect(ticks.ticks, 2);
      ticks.stop();
    });

    test('start twice is one arming on the wire', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await rig.app.startLiveFeed(kBandId);
      await rig.app.startLiveFeed(kBandId);
      await rig.settle();
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
    });

    test('start clears the sticky radio fallback (the engine request is '
        'clearRadioFallbackAndReconcile)', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.engine.state.standardHrFallback = true;
      await rig.app.startLiveFeed(kBandId);
      expect(rig.engine.state.standardHrFallback, isFalse);
    });

    test('stop clears the owner BEFORE its first await (a caller that never '
        'awaits, e.g. a screen dispose, cannot leave it set)', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await rig.app.startLiveFeed(kBandId);
      final pending = rig.app.stopLiveFeed(kBandId); // not awaited yet
      expect(rig.app.isLiveFeedOn(kBandId), isFalse);
      expect(rig.app.debugLiveOwners.developerLiveFeed, isFalse);
      await pending;
    });

    test('the feed is not persisted as a preference (a restart never re-arms '
        'it)', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await rig.app.startLiveFeed(kBandId);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.toLowerCase().contains('live')),
          isEmpty);
    });

    test('the default forTesting engine reads the owners through the same '
        'callback: start is requested of it', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ops = <(int, int)>[];
      app.engine.debugInstallFakeLink(
        band: BandProfile.gen5,
        listening: true,
        onWrite: (frame) async {
          final inner = parseFrame(frame, profile: BandProfile.gen5)!.inner;
          if (inner[2] == _hr) ops.add((_hr, inner[3]));
          if (inner[2] == _imu) ops.add((_imu, inner[4]));
          return true;
        },
      );
      await app.startLiveFeed(kBandId);
      expect(ops, [(_hr, 1), (_imu, 1)]);
    });
  });

  group('overlapping owners', () {
    test('a mounted live-HR view and the developer feed: stopping the feed '
        'keeps HR on until the view is released', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.app.retainLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 1)]);
      await rig.app.startLiveFeed(kBandId);
      await rig.settle();
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
      rig.writes.clear();
      await rig.app.stopLiveFeed(kBandId);
      await rig.settle();
      expect(rig.ops, [(_imu, 0)], reason: 'IMU off, HR still owned by the view');
      rig.writes.clear();
      rig.app.releaseLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 0)]);
    });

    test('a movement-sampling window and the developer feed: stopping the '
        'feed keeps IMU on, drops HR', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.app.setMovementSamplingWindow(true);
      await rig.settle();
      expect(rig.ops, [(_imu, 1)]);
      await rig.app.startLiveFeed(kBandId);
      await rig.settle();
      expect(rig.ops, [(_imu, 1), (_hr, 1)]);
      rig.writes.clear();
      await rig.app.stopLiveFeed(kBandId);
      await rig.settle();
      expect(rig.ops, [(_hr, 0)]);
      rig.writes.clear();
      rig.app.setMovementSamplingWindow(false);
      await rig.settle();
      expect(rig.ops, [(_imu, 0)]);
    });

    test('a workout and the developer feed: the workout keeps HR on after '
        'the feed stops', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.app.activeWorkout = LiveWorkoutState(
          startTime: DateTime.now(), targetKcal: 0, type: 'Strength');
      await rig.app.startLiveFeed(kBandId);
      await rig.settle();
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
      rig.writes.clear();
      await rig.app.stopLiveFeed(kBandId);
      await rig.settle();
      expect(rig.ops, [(_imu, 0)]);
      expect(rig.app.debugLiveOwners.activeWorkout, isTrue);
    });
  });

  group('live-HR views', () {
    test('counted: the last release drops the owner; an extra release cannot '
        'go negative', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.retainLiveHrView();
      app.retainLiveHrView();
      app.releaseLiveHrView();
      expect(app.debugLiveOwners.visibleLiveHrView, isTrue);
      app.releaseLiveHrView();
      expect(app.debugLiveOwners.visibleLiveHrView, isFalse);
      app.releaseLiveHrView();
      app.releaseLiveHrView();
      app.retainLiveHrView();
      expect(app.debugLiveOwners.visibleLiveHrView, isTrue,
          reason: 'one retain after surplus releases is one viewer');
      app.releaseLiveHrView();
      expect(app.debugLiveOwners.visibleLiveHrView, isFalse);
    });

    test('retain / release never notifyListeners; each nudges the engine '
        '(HR on, then off)', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      final ticks = TickCounter(rig.app);
      rig.app.retainLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 1)]);
      rig.writes.clear();
      rig.app.releaseLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 0)]);
      expect(ticks.ticks, 0);
      ticks.stop();
    });

    test('a second viewer is not a second arming', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.app.retainLiveHrView();
      rig.app.retainLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 1)]);
      rig.app.releaseLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 1)], reason: 'one viewer still holds HR');
    });
  });

  group('background', () {
    test('backgrounding drops the developer owner and the view owner from '
        'the owner set but not the flag itself', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await rig.app.startLiveFeed(kBandId);
      rig.app.retainLiveHrView();
      await rig.settle();
      rig.writes.clear();
      await rig.app.pauseForBackground();
      await rig.settle();
      final o = rig.app.debugLiveOwners;
      expect(o.foreground, isFalse);
      expect(o.developerLiveFeed, isFalse);
      expect(o.visibleLiveHrView, isFalse);
      expect(rig.app.isLiveFeedOn(kBandId), isTrue,
          reason: 'the user-held flag survives; only the owner input drops');
      expect(rig.ops, [(_imu, 0), (_hr, 0)],
          reason: 'the nudge turned the streams off');
    });
  });
}
