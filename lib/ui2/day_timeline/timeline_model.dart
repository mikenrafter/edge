// Shared elapsed-time chart math. Based on pilot/day-timeline's TimelineView.
import 'dart:math' as math;
import '../../data/sleep_ownership.dart';
import '../charts.dart' show SleepStage;

class TimelineView {
  const TimelineView(this.start, this.end);
  final double start, end;
  double get span => end - start;
  double get center => (start + end) / 2;
  double fraction(double t) => span <= 0 ? 0 : (t - start) / span;
  double at(double fraction) => start + span * fraction;
  TimelineView clampTo(double lo, double hi) {
    final floor = math.min(1800.0, hi - lo);
    if (span >= hi - lo) return TimelineView(lo, hi);
    var s = start, e = end;
    if (span < floor) {
      s = center - floor / 2;
      e = center + floor / 2;
    }
    if (s < lo) {
      e += lo - s;
      s = lo;
    }
    if (e > hi) {
      s -= e - hi;
      e = hi;
    }
    return TimelineView(s, e);
  }

  TimelineView zoomAt(double t, double lo, double hi) =>
      TimelineView(t - (span * .7) / 2, t + (span * .7) / 2).clampTo(lo, hi);
  TimelineView lerp(TimelineView to, double k) =>
      TimelineView(start + (to.start - start) * k, end + (to.end - end) * k);
  @override
  bool operator ==(Object other) =>
      other is TimelineView && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
}

int zoomGlideMilliseconds(TimelineView from, TimelineView to) {
  final ratio = (math.log(from.span / to.span) / math.ln2).abs();
  return 1500 + (500 * math.min(1, ratio / 3)).round();
}

double easeInOut(double t) {
  final x = t.clamp(0.0, 1.0);
  return x < .5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3) / 2;
}

// CLAIM(timeline-whole-domain): home includes every editable interval
// [sleep-structural spec §4.2; sleep_shared_timeline_test]. Membership is
// supplied by the canonical read; context visible in the window is not membership.
TimelineView timelineHome(
  String dayId, {
  ({int start, int end})? main,
  List<({int start, int end})> entries = const [],
}) {
  final span = SleepOwnership.framingSpan(dayId, main: main, entries: entries);
  return TimelineView(span.start.toDouble(), span.end.toDouble());
}

int stageDepth(SleepStage s) => switch (s) {
  SleepStage.awake => 0,
  SleepStage.rem => 1,
  SleepStage.light => 2,
  SleepStage.deep => 3,
};

/// One point of the wave: epoch [index], smoothed [depth] 0 (Awake) .. 3
/// (Deep), and the epoch's own [stage] (its colour).
typedef WavePoint = ({int index, double depth, SleepStage stage});

/// The stage wave over [stages] (one per epoch, null outside any block).
///
/// Each sleep epoch is the mean depth of its neighbours within [radius]
/// epochs, but the window STOPS at an Awake epoch and at a gap: smoothing
/// never reaches across a wake-up, so a short one stays a spike to the top
/// and the sleep either side of it is not pulled up by it. An Awake epoch is
/// exactly 0. A null epoch breaks the wave (a new run starts after it).
List<List<WavePoint>> stageWave(List<SleepStage?> stages, {int radius = 2}) {
  final runs = <List<WavePoint>>[];
  List<WavePoint>? run;
  for (var i = 0; i < stages.length; i++) {
    final s = stages[i];
    if (s == null) {
      run = null;
      continue;
    }
    if (run == null) runs.add(run = []);
    if (s == SleepStage.awake) {
      run.add((index: i, depth: 0, stage: s));
      continue;
    }
    var sum = stageDepth(s).toDouble(), n = 1;
    for (final dir in const [-1, 1]) {
      for (var k = 1; k <= radius; k++) {
        final j = i + dir * k;
        if (j < 0 || j >= stages.length) break;
        final o = stages[j];
        if (o == null || o == SleepStage.awake) break;
        sum += stageDepth(o);
        n++;
      }
    }
    run.add((index: i, depth: sum / n, stage: s));
  }
  return runs;
}
