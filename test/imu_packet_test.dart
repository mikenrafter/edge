import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

import 'support/app_state_live_harness.dart';

void main() {
  ImuPacket? decode(ImuPacketAdapter adapter, Uint8List bytes,
          {int generation = 1, int packetType = 0x2B}) =>
      adapter.decode(
        packetType: packetType,
        hex: hexOf(bytes),
        deviceId: 'band-a',
        connectionGeneration: generation,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(1790000000000),
        monotonicReceipt: const Duration(milliseconds: 50),
      );

  test('gen4 R10 has scaled six-axis samples and device time', () {
    final packet = decode(ImuPacketAdapter(),
        r10LiveInner(ax: 4096, gx: 16384, ts: 1790000000))!;
    expect(packet.kind, ImuPacketKind.gen4R10);
    expect(packet.deviceUnixSeconds, 1790000000);
    expect(packet.recordIndex, isNull);
    expect(packet.accelSampleCount, 100);
    expect(packet.gyroSampleCount, 100);
    expect(packet.accelSamples.first.x, closeTo(1.0, 1e-9));
    expect(packet.gyroSamples.first.x, closeTo(1000.0, 1e-9));
    expect(packet.nominalSampleSpacing, const Duration(milliseconds: 10));
  });

  test('gen5 preserves unequal declared sensor counts without unused capacity',
      () {
    final packet = decode(
      ImuPacketAdapter(),
      r21LiveInner(
        ax: 4096,
        gx: 16384,
        recordIndex: 41,
        accelCount: 3,
        gyroCount: 2,
        unix: 1790000001,
      ),
    )!;
    expect(packet.kind, ImuPacketKind.gen5R21);
    expect(packet.recordIndex, 41);
    expect(packet.accelSampleCount, 3);
    expect(packet.gyroSampleCount, 2);
    expect(packet.accelSamples, hasLength(3));
    expect(packet.gyroSamples, hasLength(2));
    expect(packet.alignedSampleCount, 2);
    expect(packet.accelSamples.first.x, closeTo(1.0, 1e-9));
    expect(packet.gyroSamples.first.x, closeTo(1000.0, 1e-9));
    expect(packet.quality.partialBlock, isTrue);
  });

  test('short, malformed, and accel-only packets are absent rather than errors',
      () {
    final adapter = ImuPacketAdapter();
    final short = Uint8List.fromList([0x2B, 10]);
    expect(() => decode(adapter, short), returnsNormally);
    expect(decode(adapter, short), isNull);
    expect(
      adapter.decode(
        packetType: 0x2B,
        hex: 'not hex',
        deviceId: 'band-a',
        connectionGeneration: 1,
      ),
      isNull,
    );
    expect(decode(adapter, imu33Inner(), packetType: 0x33), isNull,
        reason: '0x33 has no gyro and is not a six-axis gesture packet');
  });

  test('gap and clipping flags describe this generation only', () {
    final adapter = ImuPacketAdapter();
    final first = decode(adapter,
        r21LiveInner(recordIndex: 1, unix: 1790000000, ax: 32767));
    final gap = decode(adapter,
        r21LiveInner(recordIndex: 3, unix: 1790000002, gx: -32768));
    final reset = decode(adapter,
        r21LiveInner(recordIndex: 1, unix: 1790000003), generation: 2);
    expect(first!.quality.gapFromPrevious, isFalse);
    expect(first.quality.accelClipped, isTrue);
    expect(gap!.quality.gapFromPrevious, isTrue);
    expect(gap.quality.gyroClipped, isTrue);
    expect(reset!.quality.gapFromPrevious, isFalse,
        reason: 'a reconnect begins a fresh packet-order sequence');
  });
}
