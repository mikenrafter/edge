// Clap impulses: the one-or-two-sample spike of |accel| when the hands meet.
//
// Owner recordings: 1x, 2x and 3x claps show exactly 1, 2 and 3 spikes of
// 5.3-8.8 g, each at the end of a hand swing (gyro 400-540 dps just before,
// dropping abruptly). A spike while the gyro is above [clapMaxConcurrentDps]
// is the centripetal kick of a fast twist (a rotation recording reaches 8 g
// at 2000 dps) and is not a clap. A spike with no approach is a knock.
//
// Pure Dart, isolate-safe.
import 'dart:math' as math;

import 'imu_series.dart';
import 'motion_config.dart';

class ClapImpulse {
  const ClapImpulse(this.index, this.peakG, this.hasApproach);
  final int index;
  final double peakG;
  final bool hasApproach;
}

List<ClapImpulse> findClapImpulses(ImuSeries s,
    {required int from, required int to, MotionConfig config = const MotionConfig()}) {
  final sep = (config.clapMinSeparationSec / s.dt).round();
  final approachN = (config.clapApproachSec / s.dt).round();
  final out = <ClapImpulse>[];
  var i = math.max(0, from);
  final hi = math.min(s.length, to);
  while (i < hi) {
    if (!s.isValid(i) || s.accelAt(i).magnitude < config.clapImpulseG) {
      i++;
      continue;
    }
    // One impulse: the strongest sample within [sep] of the first one over
    // the threshold.
    var best = i;
    for (var j = i; j < math.min(hi, i + sep); j++) {
      if (s.isValid(j) && s.accelAt(j).magnitude > s.accelAt(best).magnitude) {
        best = j;
      }
    }
    i += sep;
    var concurrent = 0.0, approach = 0.0;
    for (var j = math.max(0, best - 3); j <= math.min(s.length - 1, best + 3); j++) {
      if (s.isValid(j)) concurrent = math.max(concurrent, s.speedAt(j));
    }
    if (concurrent >= config.clapMaxConcurrentDps) continue;
    // A spike stands out from its surroundings: a broad bump to 4 g (a fast
    // circle reached it once in the owner's data) does not.
    final around = math.max(
        s.accelAt(math.max(0, best - 4)).magnitude,
        s.accelAt(math.min(s.length - 1, best + 4)).magnitude);
    if (s.accelAt(best).magnitude - around < config.clapProminenceG) continue;
    for (var j = math.max(0, best - approachN); j < best; j++) {
      if (s.isValid(j)) approach = math.max(approach, s.speedAt(j));
    }
    out.add(ClapImpulse(best, s.accelAt(best).magnitude,
        approach >= config.clapApproachDps));
  }
  return out;
}
