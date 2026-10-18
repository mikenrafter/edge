// Turns about one axis, one lobe per sign: a lobe is a stretch where the
// angular rate along the axis keeps its sign and stays above [edgeDps].
//
// The angle of a lobe is the integral of that rate over the lobe (degrees),
// which is why a twist out and back shows as two lobes of roughly equal and
// opposite angle: travel is large, net angle near zero. A lobe that touches the
// first sample of its run began before the data, and one that touches the last
// sample was cut by the end of the data; neither tells the whole turn.
//
// Pure Dart, isolate-safe.
import '../../state/imu_packet.dart';
import 'imu_series.dart';

class Lobe {
  const Lobe({
    required this.start,
    required this.end,
    required this.peakDps,
    required this.angleDeg,
    required this.truncatedStart,
    required this.truncatedEnd,
    required this.clipped,
  });

  /// Samples [start, end).
  final int start;
  final int end;

  /// Signed, along the axis. A clipped lobe's peak and angle are lower bounds.
  final double peakDps;
  final double angleDeg;
  final bool truncatedStart;
  final bool truncatedEnd;
  final bool clipped;

  int get sign => angleDeg >= 0 ? 1 : -1;
  bool get truncated => truncatedStart || truncatedEnd;
}

List<Lobe> findLobes(ImuSeries s, ImuVector axis, MotionRun run,
    {required int from, required int to, required double edgeDps}) {
  final out = <Lobe>[];
  int? start;
  var sign = 0, peak = 0.0, angle = 0.0;
  var clipped = false;
  final lo = from < run.start ? run.start : from;
  final hi = to > run.end ? run.end : to;

  void close(int end) {
    out.add(Lobe(
      start: start!,
      end: end,
      peakDps: peak,
      angleDeg: angle,
      truncatedStart: start == run.start,
      truncatedEnd: end == run.end,
      clipped: clipped,
    ));
    start = null;
  }

  for (var i = lo; i < hi; i++) {
    final w = s.gyroAt(i);
    final v = w.x * axis.x + w.y * axis.y + w.z * axis.z;
    final sg = v >= edgeDps ? 1 : (v <= -edgeDps ? -1 : 0);
    if (start != null && sg != sign) close(i);
    if (sg != 0) {
      if (start == null) {
        start = i;
        sign = sg;
        peak = 0;
        angle = 0;
        clipped = false;
      }
      if (v.abs() > peak.abs()) peak = v;
      angle += v * s.dt;
      clipped = clipped || s.gyroClipped(i);
    }
  }
  if (start != null) close(hi);
  return out;
}
