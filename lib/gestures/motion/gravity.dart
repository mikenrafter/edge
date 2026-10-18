// The direction of resting acceleration in the sensor frame ("gravity"),
// tracked through motion, and the dynamic acceleration left once it is
// removed.
//
// A complementary filter. It starts from a quiet moment, carries the vector
// with the gyro (a world-fixed vector seen from a body turning at w moves as
// dv/dt = -w x v; this sign convention was checked on the owner's recordings:
// 2-5 degrees of error against 6-25 for the opposite sign), and pulls it toward
// the measured accel whenever |accel| is close to 1 g. Where accel has been
// untrustworthy for longer than the coast limit, or the gyro was pinned at its
// rail, there is no estimate: callers get null and must leave gravity-based
// features absent rather than guess.
//
// Pure Dart, isolate-safe.
import 'dart:math' as math;

import '../../state/imu_packet.dart';
import 'imu_series.dart';
import 'motion_config.dart';

class GravityTrack {
  GravityTrack._(this._dir, this._dyn);

  final List<ImuVector?> _dir;
  final List<double?> _dyn;

  /// Unit vector of the resting-accel direction at sample [i], or null.
  ImuVector? directionAt(int i) => _dir[i];

  /// |accel - gravity| in g at sample [i], or null without gravity.
  double? dynamicAccelAt(int i) => _dyn[i];
}

GravityTrack estimateGravity(ImuSeries s, {MotionConfig config = const MotionConfig()}) {
  final n = s.length;
  final dir = List<ImuVector?>.filled(n, null);
  final dyn = List<double?>.filled(n, null);
  final initN = (config.gravityInitSec / s.dt).round();
  final coastMax = (config.gravityMaxCoastSec / s.dt).round();
  final k = s.dt / config.gravityTauSec;
  for (final run in s.runs) {
    var gx = 0.0, gy = 0.0, gz = 0.0;
    var have = false;
    var quiet = 0, sinceTrusted = 0;
    var ix = 0.0, iy = 0.0, iz = 0.0;
    for (var i = run.start; i < run.end; i++) {
      final a = s.accelAt(i);
      final am = a.magnitude;
      final trusted = !s.accelClipped(i) && (am - 1).abs() <= config.gravityTrustG;
      final slow = s.speedAt(i) <= config.gravityInitMaxDps && !s.gyroClipped(i);
      if (!have) {
        if (trusted && slow) {
          quiet++;
          ix += a.x / am;
          iy += a.y / am;
          iz += a.z / am;
          if (quiet >= initN) {
            final m = math.sqrt(ix * ix + iy * iy + iz * iz);
            gx = ix / m;
            gy = iy / m;
            gz = iz / m;
            have = true;
            sinceTrusted = 0;
          }
        } else {
          quiet = 0;
          ix = iy = iz = 0;
        }
        if (!have) continue;
      } else {
        // Carry with the gyro, then correct toward trusted accel.
        if (s.gyroClipped(i)) {
          have = false;
          quiet = 0;
          ix = iy = iz = 0;
          continue;
        }
        final w = s.gyroAt(i);
        final wx = w.x * math.pi / 180, wy = w.y * math.pi / 180, wz = w.z * math.pi / 180;
        final vx = gx, vy = gy, vz = gz;
        var nx = vx - (wy * vz - wz * vy) * s.dt;
        var ny = vy - (wz * vx - wx * vz) * s.dt;
        var nz = vz - (wx * vy - wy * vx) * s.dt;
        if (trusted) {
          nx += k * (a.x / am - nx);
          ny += k * (a.y / am - ny);
          nz += k * (a.z / am - nz);
          sinceTrusted = 0;
        } else {
          sinceTrusted++;
        }
        final m = math.sqrt(nx * nx + ny * ny + nz * nz);
        gx = nx / m;
        gy = ny / m;
        gz = nz / m;
        if (sinceTrusted > coastMax) {
          have = false;
          quiet = 0;
          ix = iy = iz = 0;
          continue;
        }
      }
      dir[i] = ImuVector(gx, gy, gz);
      dyn[i] = ImuVector(a.x - gx, a.y - gy, a.z - gz).magnitude;
    }
  }
  return GravityTrack._(dir, dyn);
}
