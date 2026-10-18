// Which sensor axis is the wrist's twist axis, and which way is "out".
//
// A calibration is a unit vector: a positive turn about it is "out". Without
// one, the default is what the owner's MG on the right wrist ("logo toward the
// elbow") showed in all six out-recordings: out is a negative turn about the
// sensor X axis. A different band, wrist or strap orientation needs a
// calibration: one or more deliberate "out" twists, from which the axis is the
// principal axis of the fast rotation and the sign is the lead lobe's.
//
// Pure Dart, isolate-safe.
import 'dart:math' as math;

import '../../state/imu_packet.dart';
import 'gyro_bias.dart';
import 'imu_series.dart';
import 'motion_config.dart';
import 'twist_lobes.dart';

class TwistCalibration {
  const TwistCalibration(this.axis);

  /// Unit vector; a positive turn about it is "out".
  final ImuVector axis;

  static const TwistCalibration mgRightWrist =
      TwistCalibration(ImuVector(-1, 0, 0));

  /// From packets of the wearer twisting "out" (once or repeatedly). Null when
  /// the recording holds no clear twist: too little fast rotation, rotation
  /// spread over several axes, or no complete lead lobe to take the sign from.
  static TwistCalibration? fromPackets(Iterable<ImuPacket> packets,
      {MotionConfig config = const MotionConfig()}) {
    var s = ImuSeries.fromPackets(packets);
    final bias = estimateGyroBias(s, config: config);
    if (bias != null) s = s.withGyroBias(bias.dps);
    final m = List.generate(3, (_) => List.filled(3, 0.0));
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      if (!s.isValid(i) || s.speedAt(i) < config.concentrationFloorDps) continue;
      final w = [s.gx[i], s.gy[i], s.gz[i]];
      for (var a = 0; a < 3; a++) {
        for (var b = 0; b < 3; b++) {
          m[a][b] += w[a] * w[b];
        }
      }
      n++;
    }
    if (n < 10) return null;
    var v = [1.0, 1.0, 1.0];
    for (var it = 0; it < 100; it++) {
      final w = [
        for (var a = 0; a < 3; a++) m[a][0] * v[0] + m[a][1] * v[1] + m[a][2] * v[2],
      ];
      final len = math.sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]);
      if (len == 0) return null;
      v = [w[0] / len, w[1] / len, w[2] / len];
    }
    final trace = m[0][0] + m[1][1] + m[2][2];
    var lambda = 0.0;
    for (var a = 0; a < 3; a++) {
      lambda += v[a] * (m[a][0] * v[0] + m[a][1] * v[1] + m[a][2] * v[2]);
    }
    if (lambda / trace < config.minTwistConcentration) return null;
    final axis = ImuVector(v[0], v[1], v[2]);
    for (final run in s.runs) {
      final lobes = findLobes(s, axis, run,
          from: run.start, to: run.end, edgeDps: config.lobeEdgeDps);
      for (final l in lobes) {
        if (l.truncated ||
            l.angleDeg.abs() < config.strongAngleDeg ||
            l.peakDps.abs() < config.strongPeakDps) {
          continue;
        }
        return l.sign > 0
            ? TwistCalibration(axis)
            : TwistCalibration(ImuVector(-axis.x, -axis.y, -axis.z));
      }
    }
    return null;
  }
}
