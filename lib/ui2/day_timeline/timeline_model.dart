// Shared elapsed-time chart math. No clock or persistence owner lives here.
import '../../data/day_label.dart';

class TimelineView {
  const TimelineView(this.start, this.end);
  final double start, end;
  double get span => end - start;
  double get center => (start + end) / 2;
  double fraction(double t) => span <= 0 ? 0 : (t - start) / span;
  double at(double fraction) => start + span * fraction;
  TimelineView clampTo(double start, double end) => this;
  TimelineView zoomAt(double t, double start, double end) => this;
  TimelineView lerp(TimelineView to, double k) => this;
  @override
  bool operator ==(Object o) => o is TimelineView && o.start == start && o.end == end;
  @override
  int get hashCode => Object.hash(start, end);
}
Duration zoomDuration(TimelineView from, TimelineView to) => Duration.zero;
double easeInOut(double t) => t;

// CLAIM(timeline-whole-domain): home includes every editable interval
// [sleep-structural spec §4.2; sleep_shared_timeline_test].
TimelineView timelineHome(String dayId, {({int start, int end})? main,
    List<({int start, int end})> entries = const []}) =>
    TimelineView(localDayStartSec(dayId)!.toDouble(), localDayEndSec(dayId)!.toDouble());
