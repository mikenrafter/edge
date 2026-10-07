
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/imu_readiness.dart';
import 'package:openstrap_edge/state/live_stream_buffer.dart';
import 'package:openstrap_edge/state/live_stream_controller.dart';

import 'support/app_state_live_harness.dart';

void main() {
  test('one decoded packet fans out to graphs and the packet stream', () async {
    final buffer = LiveStreamBuffer();
    final controller = LiveStreamController(
      buffer: buffer,
      isBackground: () => false,
      activeWorkoutType: () => null,
      breathing: () => false,
      reconcile: () async {},
      clearRadioFallbackAndReconcile: () async {},
      notify: () {},
    );
    addTearDown(controller.dispose);
    final packets = <Object>[];
    final sub = controller.imuPackets.listen(packets.add);
    addTearDown(sub.cancel);

    final packet = controller.decodeAndFanoutImu(
      packetType: 0x2B,
      hex: hexOf(r21LiveInner(ax: 4096, gx: 16384)),
      deviceId: '',
      connectionGeneration: 7,
      includeAccel: true,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(1790000000000),
      monotonicReceipt: const Duration(milliseconds: 8),
    );

    await Future<void>.delayed(Duration.zero);
    expect(packet, isNotNull);
    expect(packets, [same(packet)]);
    expect(buffer.retained('', 'accel_x'), hasLength(100));
    expect(buffer.retained('', 'gyro_x'), hasLength(100));
    expect(buffer.retained('', 'accel_x').first.value, 1.0);
    expect(buffer.retained('', 'gyro_x').first.value, 1000.0);
  });

  test('the dedicated accel-only stream does not publish a gyro packet', () {
    final controller = LiveStreamController(
      buffer: LiveStreamBuffer(),
      isBackground: () => false,
      activeWorkoutType: () => null,
      breathing: () => false,
      reconcile: () async {},
      clearRadioFallbackAndReconcile: () async {},
      notify: () {},
    );
    addTearDown(controller.dispose);
    expect(
      controller.decodeAndFanoutImu(
        packetType: 0x33,
        hex: hexOf(imu33Inner()),
        deviceId: '',
        connectionGeneration: 1,
        includeAccel: true,
      ),
      isNull,
    );
  });

  group('the ready seam on the IMU stream', () {
    LiveStreamController make() {
      final c = LiveStreamController(
        buffer: LiveStreamBuffer(),
        isBackground: () => false,
        activeWorkoutType: () => null,
        breathing: () => false,
        reconcile: () async {},
        clearRadioFallbackAndReconcile: () async {},
        notify: () {},
      );
      addTearDown(c.dispose);
      return c;
    }

    void feed(LiveStreamController c, {bool invalid = false, int gen = 1}) =>
        c.decodeAndFanoutImu(
          packetType: 0x2B,
          hex: hexOf(invalid
              ? r21LiveInner(gx: -32768, gy: -32768, gz: -32768)
              : r21LiveInner()),
          deviceId: '',
          connectionGeneration: gen,
          includeAccel: true,
          monotonicReceipt: const Duration(milliseconds: 5),
        );

    test('not armed: the detector stays idle and no callback runs', () {
      final c = make();
      feed(c);
      expect(c.imuReadiness.state, ImuReadyState.idle);
    });

    test('armed: an invalid-gyro packet is not ready; the first valid one '
        'calls back once with the detector', () {
      final c = make();
      final calls = <ImuReadiness>[];
      c.awaitImuReady(calls.add);
      expect(c.imuReadiness.state, ImuReadyState.waiting);
      feed(c, invalid: true);
      expect(calls, isEmpty);
      feed(c);
      expect(calls, [same(c.imuReadiness)]);
      expect(c.imuReadiness.isReady, isTrue);
      expect(c.imuReadiness.skippedSamples, 100);
      feed(c);
      expect(calls, hasLength(1));
    });

    test('a new connection generation is a new wait and calls back again', () {
      final c = make();
      var calls = 0;
      c.awaitImuReady((_) => calls++);
      feed(c, gen: 1);
      feed(c, gen: 2);
      expect(calls, 2);
    });

    test('cancelled: no callback, and a throwing callback does not stop the '
        'packet stream', () {
      final c = make();
      var calls = 0;
      c.awaitImuReady((_) => calls++);
      c.cancelImuReady();
      feed(c);
      expect(calls, 0);
      final seen = <Object>[];
      final sub = c.imuPackets.listen(seen.add);
      addTearDown(sub.cancel);
      c.awaitImuReady((_) => throw StateError('boom'));
      expect(() => feed(c), returnsNormally);
    });
  });
}
