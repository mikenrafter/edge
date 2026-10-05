
import 'package:flutter_test/flutter_test.dart';
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
}
