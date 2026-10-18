import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/imu_timing.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

ImuPacket packetAt(int milliseconds,
        {int generation = 1, int count = 3, bool gap = false}) =>
    ImuPacket(
      deviceId: 'band',
      connectionGeneration: generation,
      kind: ImuPacketKind.gen5R21,
      recordIndex: 1,
      deviceUnixSeconds: 1790000000,
      deviceSubseconds: 0,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(1790000000000),
      monotonicReceipt: Duration(milliseconds: milliseconds),
      accelSamples: List.filled(count, const ImuVector(0, 0, 1)),
      gyroSamples: List.filled(count, const ImuVector(0, 0, 0)),
      accelSampleCount: count,
      gyroSampleCount: count,
      nominalSampleSpacing: const Duration(milliseconds: 10),
      quality: ImuPacketQuality(gapFromPrevious: gap),
    );

void main() {
  test('startup timing reports all five latency measurements', () {
    final recorder = ImuTimingRecorder(usableSampleTarget: 5);
    recorder.begin(
      receivedAt: const Duration(milliseconds: 100),
      bandEventAge: const Duration(milliseconds: 17),
    );
    recorder.imuOnWriteIssued(const Duration(milliseconds: 145));
    recorder.packet(packetAt(220));
    recorder.packet(packetAt(230));
    recorder.actionRan(const Duration(milliseconds: 360));

    final latency = recorder.latency;
    expect(latency.bandEventAge, const Duration(milliseconds: 17));
    expect(latency.tapToImuOn, const Duration(milliseconds: 45));
    expect(latency.imuOnToFirstPacket, const Duration(milliseconds: 75));
    expect(latency.firstPacketToUsableSamples, const Duration(milliseconds: 10));
    expect(latency.tapToAction, const Duration(milliseconds: 260));
  });

  test('generation changes and gaps do not manufacture usable evidence', () {
    final recorder = ImuTimingRecorder(usableSampleTarget: 4);
    recorder.begin(
      receivedAt: Duration.zero,
      bandEventAge: Duration.zero,
    );
    recorder.imuOnWriteIssued(const Duration(milliseconds: 1));
    recorder.packet(packetAt(10, count: 3));
    recorder.packet(packetAt(20, generation: 2, count: 3));
    expect(recorder.latency.firstPacketToUsableSamples, isNull);
    recorder.packet(packetAt(30, gap: true, count: 3));
    expect(recorder.latency.firstPacketToUsableSamples, isNull,
        reason: 'a packet after a gap adds no usable samples');
  });

  test('only a currently active lab session receives plain timing lines', () {
    final log = DeviceLabLog();
    final recorder = ImuTimingRecorder(onLine: (line) {
      if (log.isSessionActive) log.addStep(line);
    });
    recorder.begin(receivedAt: Duration.zero, bandEventAge: Duration.zero);
    expect(log.steps, isEmpty);
    log.beginSession(
      method: 'timing',
      settings: 'test',
      tapAt: DateTime.fromMillisecondsSinceEpoch(1790000000000),
    );
    recorder.imuOnWriteIssued(const Duration(milliseconds: 10));
    expect(log.steps.single, contains('tap receipt to IMU ON 10 ms'));
    log.endSession(result: 'done');
    recorder.packet(packetAt(20));
    expect(log.steps.where((line) => line.contains('first valid packet')), isEmpty);
  });
}
