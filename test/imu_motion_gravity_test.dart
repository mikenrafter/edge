import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/motion/gravity.dart';
import 'package:openstrap_edge/gestures/motion/gyro_bias.dart';
import 'package:openstrap_edge/gestures/motion/imu_series.dart';
import 'package:openstrap_edge/gestures/motion/movement_energy.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

import 'support/motion_synth.dart';

double angleDeg(ImuVector a, ImuVector b) {
  final d = (a.x * b.x + a.y * b.y + a.z * b.z) / (a.magnitude * b.magnitude);
  return math.acos(d.clamp(-1.0, 1.0)) * 180 / math.pi;
}

void main() {
  group('gravity', () {
    test('constant gravity in any orientation is found', () {
      for (final g in [unit(0, 0, 1), unit(1, 2, -3), unit(-0.8, 0.1, 0.4)]) {
        final s = ImuSeries.fromPackets(
            Scene().quiet(3).packets(gravity: g, deviceStartup: false));
        final track = estimateGravity(s);
        final est = track.directionAt(200);
        expect(est, isNotNull);
        expect(angleDeg(est!, g), lessThan(1.0));
        expect(track.dynamicAccelAt(200)!, lessThan(0.05));
      }
    });

    test('a rotating body keeps its gravity estimate through any axis', () {
      final g0 = unit(0.3, -0.2, 0.9);
      for (final axis in [unit(1, 0, 0), unit(0, 1, 1), unit(1, -2, 0.5)]) {
        final scene = Scene().quiet(1).spin(axis, 90, 1).quiet(0.5);
        final (accel, _) = scene.samples(gravity: g0, noiseG: 0);
        final s = ImuSeries.fromPackets(scene.packets(gravity: g0, deviceStartup: false));
        final est = estimateGravity(s).directionAt(245)!;
        // The accel at the end is the true sensor-frame gravity.
        expect(angleDeg(est, accel[245]), lessThan(3.0),
            reason: 'axis $axis');
      }
    });

    test('while accel is untrustworthy the estimate coasts on the gyro', () {
      final scene = Scene()
          .quiet(1)
          .spin(unit(1, 0, 0), 60, 0.3)
          .impulse(v3(0, 0, 4))
          .impulse(v3(0, 0, 4))
          .quiet(0.3);
      final (accel, _) = scene.samples(noiseG: 0);
      final s = ImuSeries.fromPackets(scene.packets(deviceStartup: false));
      final track = estimateGravity(s);
      final i = 131; // inside the burst
      final est = track.directionAt(i);
      expect(est, isNotNull);
      expect(angleDeg(est!, accel[129]), lessThan(4.0));
      // The burst itself shows up as dynamic acceleration.
      expect(track.dynamicAccelAt(130)!, greaterThan(2.0));
    });

    test('with no quiet moment there is no gravity and no dynamic accel', () {
      final scene = Scene().vibration(300, 3);
      final s = ImuSeries.fromPackets(scene.packets(deviceStartup: false));
      final track = estimateGravity(s);
      expect(track.directionAt(150), isNull);
      expect(track.dynamicAccelAt(150), isNull);
    });
  });

  group('gyro bias', () {
    test('a still stretch gives the bias', () {
      final s = ImuSeries.fromPackets(Scene()
          .quiet(2)
          .packets(bias: v3(3, -2, 1.5), deviceStartup: false));
      final b = estimateGyroBias(s)!;
      expect(b.dps.x, closeTo(3, 0.3));
      expect(b.dps.y, closeTo(-2, 0.3));
      expect(b.dps.z, closeTo(1.5, 0.3));
      expect(b.samples, greaterThan(100));
    });

    test('moving the whole time gives no estimate, not a guess', () {
      final s = ImuSeries.fromPackets(
          Scene().sine(unit(0, 1, 0), 200, 1, 3).packets(deviceStartup: false));
      expect(estimateGyroBias(s), isNull);
    });

    test('the motion in between does not leak into the estimate', () {
      final s = ImuSeries.fromPackets(Scene()
          .quiet(1)
          .flick(outAxis)
          .quiet(1)
          .packets(bias: v3(2, 2, 2), deviceStartup: false));
      final b = estimateGyroBias(s)!;
      expect(b.dps.x, closeTo(2, 0.4));
    });

    test('the startup marker is not read as a bias', () {
      final s = ImuSeries.fromPackets(Scene().quiet(2).packets());
      final b = estimateGyroBias(s)!;
      expect(b.dps.x.abs(), lessThan(0.5));
    });
  });

  group('movement energy', () {
    test('stillness is near zero, shaking is not', () {
      final still = ImuSeries.fromPackets(Scene().quiet(3).packets(deviceStartup: false));
      final shake = ImuSeries.fromPackets(
          Scene().sine(unit(0, 1, 0), 400, 3, 3).packets(deviceStartup: false));
      final e0 = measureMovementEnergy(still, from: 0, to: still.length)!;
      final e1 = measureMovementEnergy(shake, from: 0, to: shake.length)!;
      expect(e0.gyroRmsDps, lessThan(2));
      expect(e0.activeFraction, 0);
      expect(e1.gyroRmsDps, greaterThan(200));
      expect(e1.activeFraction, greaterThan(0.7));
    });

    test('an energy that is mostly missing data is unknown, not low', () {
      final s = ImuSeries.fromPackets(Scene().quiet(3).packets(
          deviceStartup: false, sentinelAt: {for (var i = 50; i < 250; i++) i}));
      expect(measureMovementEnergy(s, from: 0, to: s.length, minCoverage: 0.9),
          isNull);
    });

    test('dynamic acceleration is reported only when gravity is known', () {
      final s = ImuSeries.fromPackets(Scene().quiet(2).packets(deviceStartup: false));
      final withGravity = measureMovementEnergy(s,
          from: 0, to: s.length, gravity: estimateGravity(s))!;
      expect(withGravity.dynAccelRmsG, isNotNull);
      final without = measureMovementEnergy(s, from: 0, to: s.length)!;
      expect(without.dynAccelRmsG, isNull);
    });
  });
}
