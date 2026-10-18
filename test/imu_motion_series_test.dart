import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/motion/imu_series.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

import 'support/motion_synth.dart';

void main() {
  test('packets become one continuous 100 Hz series', () {
    final s = ImuSeries.fromPackets(
        Scene().quiet(3).packets(deviceStartup: false));
    expect(s.length, 300);
    expect(s.dt, closeTo(0.01, 1e-12));
    expect(s.runs.length, 1);
    expect(s.runs.single.start, 0);
    expect(s.runs.single.end, 300);
  });

  test('the band startup marker (-2000 on all gyro axes) is invalid, not motion',
      () {
    final s = ImuSeries.fromPackets(Scene().quiet(3).packets());
    // 99 + 100 + 100 samples; the first four gyro samples are the marker.
    expect(s.length, 299);
    for (var i = 0; i < 4; i++) {
      expect(s.isValid(i), isFalse, reason: 'sample $i');
    }
    expect(s.isValid(4), isTrue);
    expect(s.runs.single.start, 4);
    expect(s.gyroClipped(4), isFalse);
  });

  test('one axis pinned at -2000 with the others live is a clipped sample', () {
    final scene = Scene().quiet(1).pulse(outAxis, 400, 0.1).quiet(1);
    final s = ImuSeries.fromPackets(scene.packets(deviceStartup: false));
    final clipped = [for (var i = 0; i < s.length; i++) if (s.gyroClipped(i)) i];
    expect(clipped, isNotEmpty);
    expect(clipped.every(s.isValid), isTrue);
  });

  test('accel at the 8 g rail is flagged', () {
    final scene = Scene().quiet(1).impulse(v3(0, 0, 20)).quiet(1);
    final s = ImuSeries.fromPackets(scene.packets(deviceStartup: false));
    final hits = [for (var i = 0; i < s.length; i++) if (s.accelClipped(i)) i];
    expect(hits, [100]);
  });

  test('unequal accel and gyro counts use the aligned prefix only', () {
    final base = Scene().quiet(2).packets(deviceStartup: false);
    final p = base.first;
    final unequal = ImuPacket(
      deviceId: p.deviceId,
      connectionGeneration: p.connectionGeneration,
      kind: p.kind,
      recordIndex: p.recordIndex,
      deviceUnixSeconds: p.deviceUnixSeconds,
      deviceSubseconds: p.deviceSubseconds,
      receivedAt: p.receivedAt,
      monotonicReceipt: p.monotonicReceipt,
      accelSamples: p.accelSamples,
      gyroSamples: p.gyroSamples.sublist(0, 60),
      accelSampleCount: 100,
      gyroSampleCount: 60,
      nominalSampleSpacing: p.nominalSampleSpacing,
      quality: const ImuPacketQuality(partialBlock: true),
    );
    final s = ImuSeries.fromPackets([unequal, base[1]]);
    expect(s.length, 160);
  });

  test('a packet flagged as following a gap splits the series into runs', () {
    final s = ImuSeries.fromPackets(Scene()
        .quiet(3)
        .packets(deviceStartup: false, gapBefore: {1}));
    expect(s.runs.map((r) => (r.start, r.end)), [(0, 100), (100, 300)]);
  });

  test('a short packet after the first splits the series: it is never stretched',
      () {
    final s = ImuSeries.fromPackets(Scene()
        .quiet(3)
        .packets(deviceStartup: false, shortPackets: {1: 90}));
    expect(s.runs.map((r) => (r.start, r.end)).first, (0, 190));
    expect(s.runs.length, 2);
  });

  test('an empty or one-sided packet list gives an empty series', () {
    expect(ImuSeries.fromPackets(const []).length, 0);
    expect(ImuSeries.fromPackets(const []).runs, isEmpty);
  });

  test('a bias is subtracted without touching accel', () {
    final s = ImuSeries.fromPackets(Scene().quiet(1).packets(deviceStartup: false));
    final b = s.withGyroBias(v3(1, -2, 3));
    expect(b.gyroAt(5).x, closeTo(s.gyroAt(5).x - 1, 1e-9));
    expect(b.accelAt(5).z, s.accelAt(5).z);
  });
}
