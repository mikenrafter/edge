// Motion windows: where the arm is moving, found with onset/offset hysteresis
// on smoothed angular speed.
//
// A window opens when smoothed speed reaches [MotionConfig.onsetDps] and
// closes after [MotionConfig.quietHoldSec] below [MotionConfig.offsetDps].
// Windows never cross a run boundary (a gap or invalid samples). A window
// that is still open at the end of its run says so ([MotionWindow.touchesEnd]):
// its end is the data's end, not the motion's. One that is open at the first
// sample says so too ([MotionWindow.touchesStart]): the stream began mid-motion.
//
// Pure Dart, isolate-safe.
import 'dart:math' as math;

import 'imu_series.dart';
import 'motion_config.dart';

class MotionWindow {
  const MotionWindow({
    required this.start,
    required this.end,
    required this.run,
    required this.touchesStart,
    required this.touchesEnd,
    required this.peakDps,
  });

  /// Samples [start, end).
  final int start;
  final int end;
  final MotionRun run;
  final bool touchesStart;
  final bool touchesEnd;
  final double peakDps;

  int get length => end - start;
}

List<MotionWindow> segmentMotion(ImuSeries s,
    {MotionConfig config = const MotionConfig()}) {
  final hold = (config.quietHoldSec / s.dt).round();
  final out = <MotionWindow>[];
  for (final run in s.runs) {
    final sm = _smoothed(s, run, config.smoothSamples);
    int? start;
    var last = 0;
    var peak = 0.0;
    void close(int i, bool open) {
      out.add(MotionWindow(
        start: start!,
        end: last + 1,
        run: run,
        touchesStart: start == run.start,
        touchesEnd: open,
        peakDps: peak,
      ));
      start = null;
    }

    for (var i = run.start; i < run.end; i++) {
      final v = sm[i - run.start];
      if (start == null) {
        if (v >= config.onsetDps) {
          start = i;
          last = i;
          peak = 0;
        }
      } else if (v >= config.offsetDps) {
        last = i;
      } else if (i - last >= hold) {
        close(i, false);
      }
      if (start != null) peak = math.max(peak, s.speedAt(i));
    }
    if (start != null) close(run.end, run.end - 1 - last < hold);
  }
  return out;
}

/// Windows close enough together to be one attempt, in order.
List<List<MotionWindow>> groupWindows(List<MotionWindow> windows, ImuSeries s,
    {MotionConfig config = const MotionConfig()}) {
  final gap = (config.mergeGapSec / s.dt).round();
  final groups = <List<MotionWindow>>[];
  for (final w in windows) {
    if (groups.isNotEmpty &&
        groups.last.last.run.start == w.run.start &&
        w.start - groups.last.last.end <= gap) {
      groups.last.add(w);
    } else {
      groups.add([w]);
    }
  }
  return groups;
}

List<double> _smoothed(ImuSeries s, MotionRun run, int width) {
  final out = List<double>.filled(run.length, 0);
  var sum = 0.0;
  for (var i = 0; i < run.length; i++) {
    sum += s.speedAt(run.start + i);
    if (i >= width) sum -= s.speedAt(run.start + i - width);
    out[i] = sum / math.min(i + 1, width);
  }
  return out;
}
