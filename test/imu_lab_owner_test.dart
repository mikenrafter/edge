// The Device lab's IMU recorder owns the IMU stream through its own owner flag
// (`imuLab`): IMU only on gen5, the coupled bundle on gen4, never HR, and
// released on its own without disturbing another owner.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/state/live_stream_buffer.dart';
import 'package:openstrap_edge/state/live_stream_controller.dart';

const _imuOnly = LiveStreamIntent(hr: false, imu: true);
const _both = LiveStreamIntent(hr: true, imu: true);
const _hrOnly = LiveStreamIntent(hr: true, imu: false);

LiveStreamIntent _gen5(LiveStreamOwners o, {bool fallback = false}) =>
    desiredLiveStreams(o, gen5: true, standardHrFallback: fallback);
LiveStreamIntent _gen4(LiveStreamOwners o, {bool fallback = false}) =>
    desiredLiveStreams(o, gen5: false, standardHrFallback: fallback);

LiveStreamController _controller({
  bool Function()? background,
  void Function()? onReconcile,
}) =>
    LiveStreamController(
      buffer: LiveStreamBuffer(),
      isBackground: background ?? () => false,
      activeWorkoutType: () => null,
      breathing: () => false,
      reconcile: () async => onReconcile?.call(),
      clearRadioFallbackAndReconcile: () async {},
      notify: () {},
    );

void main() {
  group('desiredLiveStreams with the imuLab owner', () {
    test('gen5: IMU only, no HR, with or without the app in the foreground', () {
      expect(_gen5(const LiveStreamOwners(imuLab: true)), _imuOnly);
      expect(_gen5(const LiveStreamOwners(imuLab: true, foreground: true)),
          _imuOnly);
    });

    test('gen4: IMU intent only (the engine turns the whole bundle on for it)',
        () {
      expect(_gen4(const LiveStreamOwners(imuLab: true)), _imuOnly);
      expect(
        nextLiveStreamStep(
            applied: LiveStreamIntent.off, desired: _gen4(const LiveStreamOwners(imuLab: true))),
        LiveStreamStep.imuOn,
      );
    });

    test('gen4 in the foreground keeps its legacy bundle and HR', () {
      expect(_gen4(const LiveStreamOwners(imuLab: true, foreground: true)),
          _both);
    });

    test('the marginal-radio fallback suppresses it like every IMU owner', () {
      expect(_gen5(const LiveStreamOwners(imuLab: true), fallback: true),
          LiveStreamIntent.off);
    });

    test('it adds IMU to another owner\'s HR and leaves HR alone when released',
        () {
      expect(
          _gen5(const LiveStreamOwners(
              imuLab: true, visibleLiveHrView: true, foreground: true)),
          _both);
      expect(
          _gen5(const LiveStreamOwners(
              visibleLiveHrView: true, foreground: true)),
          _hrOnly);
    });

    test('another IMU owner keeps the stream when this one lets go', () {
      expect(
          _gen5(const LiveStreamOwners(imuLab: true, movementSampling: true)),
          _imuOnly);
      expect(_gen5(const LiveStreamOwners(movementSampling: true)), _imuOnly);
    });

    test('it is not the developer feed: HR is not requested by it', () {
      expect(_gen5(const LiveStreamOwners(imuLab: true)).hr, isFalse);
      expect(_gen5(const LiveStreamOwners(developerLiveFeed: true)).hr, isTrue);
    });

    test('toString names it', () {
      expect(const LiveStreamOwners(imuLab: true).toString(),
          contains('imuLab: true'));
    });
  });

  group('LiveStreamController.setImuLab', () {
    test('sets the owner, nudges once, and is idempotent', () {
      var nudges = 0;
      final c = _controller(onReconcile: () => nudges++);
      expect(c.owners().imuLab, isFalse);
      c.setImuLab(true);
      expect(c.owners().imuLab, isTrue);
      expect(nudges, 1);
      c.setImuLab(true);
      expect(nudges, 1, reason: 'no second nudge for the same state');
      c.setImuLab(false);
      expect(c.owners().imuLab, isFalse);
      expect(nudges, 2);
      c.setImuLab(false);
      expect(nudges, 2);
    });

    test('a bounded lab recording is not dropped when the app backgrounds', () {
      var background = false;
      final c = _controller(background: () => background);
      c.setImuLab(true);
      background = true;
      expect(c.owners().imuLab, isTrue);
    });

    test('it does not turn on the other owners', () {
      final c = _controller()..setImuLab(true);
      final o = c.owners();
      expect(o.developerLiveFeed, isFalse);
      expect(o.movementSampling, isFalse);
      expect(o.passiveStrapSteps, isFalse);
      expect(o.visibleLiveHrView, isFalse);
    });
  });
}
