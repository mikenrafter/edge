// Gyro sensor bias from a measured still interval, or nothing.
//
// A still interval is [biasWindowSec] in which angular speed stays under
// [biasMaxSpeedDps] and |accel| stays within [biasMaxAccelDevG] of 1 g. Every
// such window of the series contributes; the estimate is the mean of their
// samples. Owner recordings show 0.5-2 dps of noise and sub-3 dps bias, small
// next to a 1000 dps twist but large against a 60 degree angle threshold over
// seconds, so it is removed when measurable and left alone when not. Slow
// vehicle turns are environment, not bias, and are never estimated here.
//
// Pure Dart, isolate-safe.
import '../../state/imu_packet.dart';
import 'imu_series.dart';
import 'motion_config.dart';

class GyroBias {
  const GyroBias(this.dps, this.samples);
  final ImuVector dps;
  final int samples;
}

GyroBias? estimateGyroBias(ImuSeries s, {MotionConfig config = const MotionConfig()}) {
  final win = (config.biasWindowSec / s.dt).round();
  var sx = 0.0, sy = 0.0, sz = 0.0, n = 0;
  for (final run in s.runs) {
    if (run.length < win) continue;
    var from = run.start;
    for (var i = run.start; i < run.end; i++) {
      final still = s.speedAt(i) <= config.biasMaxSpeedDps &&
          (s.accelAt(i).magnitude - 1).abs() <= config.biasMaxAccelDevG;
      if (!still) {
        from = i + 1;
        continue;
      }
      if (i - from + 1 == win) {
        // A full still window ends here: take it once, when it first fills,
        // then keep adding samples one at a time.
        for (var j = from; j <= i; j++) {
          sx += s.gx[j];
          sy += s.gy[j];
          sz += s.gz[j];
          n++;
        }
      } else if (i - from + 1 > win) {
        sx += s.gx[i];
        sy += s.gy[i];
        sz += s.gz[i];
        n++;
      }
    }
  }
  if (n == 0) return null;
  return GyroBias(ImuVector(sx / n, sy / n, sz / n), n);
}
