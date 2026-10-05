// Packets, markers and recordings for the IMU lab recorder tests.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/imu_recording.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

/// A packet received [ms] after the process clock started. [accel] and [gyro]
/// are valid counts, which may differ (a gen5 buffer can say so); the sample
/// values are distinct per packet and axis so a mixed-up round trip shows.
ImuPacket labPacket(
  int ms, {
  int accel = 3,
  int gyro = 3,
  int generation = 1,
  String deviceId = 'band-a',
  ImuPacketKind kind = ImuPacketKind.gen5R21,
  bool gap = false,
  bool clipped = false,
  int? recordIndex,
  int? unix = 1790000000,
  int? subsec,
}) =>
    ImuPacket(
      deviceId: deviceId,
      connectionGeneration: generation,
      kind: kind,
      recordIndex: recordIndex ?? (kind == ImuPacketKind.gen5R21 ? ms : null),
      deviceUnixSeconds: unix,
      deviceSubseconds: subsec ?? (kind == ImuPacketKind.gen5R21 ? ms * 3 : null),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(1790000000000 + ms,
          isUtc: true),
      monotonicReceipt: Duration(milliseconds: ms),
      accelSamples: [
        for (var i = 0; i < accel; i++)
          ImuVector(0.1 * i + ms / 7, -0.25 * i, 1.0 / 3 + i),
      ],
      gyroSamples: [
        for (var i = 0; i < gyro; i++)
          ImuVector(12.5 * i - ms / 3, 0.001 * i, -2000.0 / 32768 * (i + 1)),
      ],
      accelSampleCount: accel,
      gyroSampleCount: gyro,
      nominalSampleSpacing: const Duration(milliseconds: 10),
      quality: ImuPacketQuality(
        gapFromPrevious: gap,
        accelClipped: clipped,
        partialBlock: accel != 100 || gyro != 100,
      ),
    );

ImuRecordingMeta labMeta({
  String id = 'imu-20261005T120000Z-ab12',
  ImuRecordingKind kind = ImuRecordingKind.action,
  String label = 'wrist rotation out',
  ImuWrist? wrist = ImuWrist.left,
  String? firmware = '50.41.1.0',
}) =>
    ImuRecordingMeta(
      id: id,
      kind: kind,
      label: label,
      bandModel: 'WHOOP MG',
      bandFirmware: firmware,
      deviceId: 'band-a',
      wrist: wrist,
      mounting: 'logo toward the elbow',
      posture: 'sitting',
      environment: 'car',
      appVersion: '0.10.0+67',
      protocolVersion: 'bc7d8d0df706e40a2546ffde4545263f09d0fecb',
      createdAt: DateTime.utc(2026, 10, 5, 12, 0, 0, 123, 456),
      requestedDuration: const Duration(seconds: 5),
      maxPackets: 600,
    );

ImuMarker labMarker(ImuMarkerKind kind, int ms,
        {Duration? age, String? note}) =>
    ImuMarker(
      kind: kind,
      mono: Duration(milliseconds: ms),
      at: DateTime.fromMillisecondsSinceEpoch(1790000000000 + ms, isUtc: true),
      bandEventAge: age,
      note: note,
    );

/// Field-by-field equality of two packets (ImuPacket has no `==`).
void expectSamePacket(ImuPacket a, ImuPacket b) {
  expect2(a.deviceId, b.deviceId, 'deviceId');
  expect2(a.connectionGeneration, b.connectionGeneration, 'generation');
  expect2(a.kind, b.kind, 'kind');
  expect2(a.recordIndex, b.recordIndex, 'recordIndex');
  expect2(a.deviceUnixSeconds, b.deviceUnixSeconds, 'unix');
  expect2(a.deviceSubseconds, b.deviceSubseconds, 'subsec');
  expect2(a.receivedAt, b.receivedAt, 'receivedAt');
  expect2(a.monotonicReceipt, b.monotonicReceipt, 'monotonic');
  expect2(a.accelSampleCount, b.accelSampleCount, 'accelCount');
  expect2(a.gyroSampleCount, b.gyroSampleCount, 'gyroCount');
  expect2(a.nominalSampleSpacing, b.nominalSampleSpacing, 'spacing');
  expect2(a.quality.gapFromPrevious, b.quality.gapFromPrevious, 'gap');
  expect2(a.quality.accelClipped, b.quality.accelClipped, 'accelClipped');
  expect2(a.quality.gyroClipped, b.quality.gyroClipped, 'gyroClipped');
  expect2(a.quality.partialBlock, b.quality.partialBlock, 'partial');
  for (final (x, y) in [
    (a.accelSamples, b.accelSamples),
    (a.gyroSamples, b.gyroSamples),
  ]) {
    expect2(x.length, y.length, 'sample count');
    for (var i = 0; i < x.length; i++) {
      expect2(x[i].x, y[i].x, 'x[$i]');
      expect2(x[i].y, y[i].y, 'y[$i]');
      expect2(x[i].z, y[i].z, 'z[$i]');
    }
  }
}

void expect2(Object? a, Object? b, String what) =>
    expect(a, b, reason: what);
