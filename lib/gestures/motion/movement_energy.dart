// How much the arm moved over an interval, for the later movement veto.
//
// Three numbers, none of them a verdict: gyro RMS speed, the fraction of the
// interval above [activeDps], and the RMS of gravity-removed acceleration
// (absent when gravity is not known). [coverage] is the share of the interval
// that is valid data; below [minCoverage] the whole measure is null, so a
// mostly-missing window reads as unknown rather than as calm. A threshold on
// these is a product decision that needs ambient recordings.
//
// Pure Dart, isolate-safe.
import 'dart:math' as math;

import 'gravity.dart';
import 'imu_series.dart';
import 'motion_config.dart';

class MovementEnergy {
  const MovementEnergy({
    required this.gyroRmsDps,
    required this.activeFraction,
    required this.dynAccelRmsG,
    required this.coverage,
  });

  final double gyroRmsDps;
  final double activeFraction;
  final double? dynAccelRmsG;
  final double coverage;
}

MovementEnergy? measureMovementEnergy(
  ImuSeries s, {
  required int from,
  required int to,
  GravityTrack? gravity,
  double? minCoverage,
  MotionConfig config = const MotionConfig(),
}) {
  final lo = math.max(0, from), hi = math.min(s.length, to);
  if (hi <= lo) return null;
  var valid = 0, active = 0, dynN = 0;
  var g2 = 0.0, d2 = 0.0;
  for (var i = lo; i < hi; i++) {
    if (!s.isValid(i)) continue;
    valid++;
    final sp = s.speedAt(i);
    g2 += sp * sp;
    if (sp >= config.energyActiveDps) active++;
    final d = gravity?.dynamicAccelAt(i);
    if (d != null) {
      d2 += d * d;
      dynN++;
    }
  }
  final coverage = valid / (hi - lo);
  if (valid == 0 || coverage < (minCoverage ?? config.energyMinCoverage)) {
    return null;
  }
  return MovementEnergy(
    gyroRmsDps: math.sqrt(g2 / valid),
    activeFraction: active / valid,
    // Gravity-removed energy only when most of the interval had gravity.
    dynAccelRmsG: dynN >= valid * 0.8 ? math.sqrt(d2 / dynN) : null,
    coverage: coverage,
  );
}
