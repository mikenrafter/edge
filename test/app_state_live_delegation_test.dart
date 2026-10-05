// Live-stream area: every AppState member in the live-stream area is still there with
// its original type and forwards. The annotations are compile-time checks of
// the public surface; the behaviour checks pin that what the engine reads
// through its liveOwners callback is what AppState reports, and that the
// buffer AppState exposes is the one the frame path feeds.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart' show LiveStreamOwners;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/live_stream_buffer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_live_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  test('every member in the live-stream area is present with its original '
      'type', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final LiveStreamBuffer buffer = app.liveStreams;
    final Future<void> Function(String) start = app.startLiveFeed;
    final Future<void> Function(String) stop = app.stopLiveFeed;
    final bool Function(String) on = app.isLiveFeedOn;
    final void Function() retain = app.retainLiveHrView;
    final void Function() release = app.releaseLiveHrView;
    final void Function(bool) sampling = app.setMovementSamplingWindow;
    final LiveStreamOwners owners = app.debugLiveOwners;
    final void Function(int, String, int?) onFrame = app.debugOnLiveFrame;
    final bool Function(String, int?, int?) appendHr = app.debugAppendLiveHr;
    final void Function(List<double>, {int? recTs, required int atMs}) feed =
        app.debugFeedLiveAccel;
    expect([buffer, start, stop, on, retain, release, sampling, owners,
      onFrame, appendHr, feed], isNotEmpty);
  });

  test('the engine\'s liveOwners callback and AppState.debugLiveOwners agree '
      'field by field, through every owner change', () async {
    final rig = G6Rig();
    addTearDown(rig.dispose);
    void same(String when) {
      final a = rig.engine.liveOwners!();
      final b = rig.app.debugLiveOwners;
      expect(a.visibleLiveHrView, b.visibleLiveHrView, reason: when);
      expect(a.activeWorkout, b.activeWorkout, reason: when);
      expect(a.foregroundGaitWorkout, b.foregroundGaitWorkout, reason: when);
      expect(a.breathing, b.breathing, reason: when);
      expect(a.movementSampling, b.movementSampling, reason: when);
      expect(a.passiveStrapSteps, b.passiveStrapSteps, reason: when);
      expect(a.foreground, b.foreground, reason: when);
      expect(a.developerLiveFeed, b.developerLiveFeed, reason: when);
    }

    same('fresh');
    await rig.app.startLiveFeed(kBandId);
    same('feed on');
    rig.app.retainLiveHrView();
    same('viewer');
    rig.app.setMovementSamplingWindow(true);
    same('sampling');
    rig.app.breathingActive = true;
    same('breathing');
    await rig.app.pauseForBackground();
    same('background');
    expect(rig.engine.liveOwners!().developerLiveFeed, isFalse);
    await rig.settle();
  });

  test('the buffer AppState exposes is the one the engine frame path feeds',
      () {
    final rig = G6Rig();
    addTearDown(rig.dispose);
    rig.feed(hr28Inner(hr: 66, rr: [850]));
    expect(rig.app.liveStreams.retained(kBandId, 'hr').single.value, 66.0);
    expect(rig.app.liveStreams.retained(kBandId, 'rr').single.value, 850.0);
  });
}
