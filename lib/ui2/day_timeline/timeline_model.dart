// THE DAY TIMELINE, as rules (pilot: day-timeline, edge.research/
// day-timeline-pilot-spec.md §1-§3). Pure: no widgets, no clock, no database,
// so every rule here is pinned by test/ui2/day_timeline_model_test.dart
// without a frame. The widget (timeline_chart.dart) only draws what these
// return.
//
// Units: every time is epoch SECONDS (double for a view edge, int for a block
// edge). Nothing here assumes a day is 86400 s.

import 'dart:math' as math;

import '../charts.dart' show SleepStage;

// ── lanes (spec §1 "Lanes and proportions") ─────────────────────────────────

/// The chart's lanes, top to bottom.
enum TimelineLane { heartRate, stages, movement }

/// Each lane's share of the plot height, in sixths: heart rate 3/6, stages
/// 2/6, movement 1/6.
const Map<TimelineLane, int> kLaneSixths = {
  TimelineLane.heartRate: 3,
  TimelineLane.stages: 2,
  TimelineLane.movement: 1,
};

/// The lanes of a [plotHeight] plot, top to bottom, as (lane, top, height).
/// A lane a screen does not use gives its share to heart rate, so the plot is
/// always filled and heart rate is always the tallest lane.
List<({TimelineLane lane, double top, double height})> laneLayout(
    double plotHeight, Set<TimelineLane> lanes) {
  final out = <({TimelineLane lane, double top, double height})>[];
  var top = 0.0;
  for (final lane in TimelineLane.values) {
    if (!lanes.contains(lane)) continue;
    var sixths = kLaneSixths[lane]!;
    if (lane == TimelineLane.heartRate) {
      for (final other in TimelineLane.values) {
        if (!lanes.contains(other)) sixths += kLaneSixths[other]!;
      }
    }
    final h = plotHeight * sixths / 6;
    out.add((lane: lane, top: top, height: h));
    top += h;
  }
  return out;
}

// ── the view window and zoom (spec §1 "Zoom") ───────────────────────────────

/// Never narrower than 30 minutes.
const double kMinViewSec = 30 * 60;

/// A double tap zooms in by about 30%: the new span is 70% of the old one.
const double kDoubleTapZoom = .7;

/// What the chart shows: [start] .. [end], epoch seconds.
class TimelineView {
  const TimelineView(this.start, this.end);
  final double start, end;
  double get span => end - start;
  double get center => (start + end) / 2;

  /// [t]'s place across the view, 0 (left edge) .. 1 (right edge).
  double fraction(double t) => span <= 0 ? 0 : (t - start) / span;
  double at(double fraction) => start + span * fraction;

  /// This view made legal inside [domainStart] .. [domainEnd]: at least
  /// [kMinViewSec] wide (widened about its centre), then shifted (not
  /// squeezed) back inside the domain. A domain narrower than the floor is
  /// shown whole.
  TimelineView clampTo(double domainStart, double domainEnd) {
    final domain = domainEnd - domainStart;
    if (domain <= kMinViewSec) return TimelineView(domainStart, domainEnd);
    var s = start, e = end;
    if (e - s < kMinViewSec) {
      final c = (s + e) / 2;
      s = c - kMinViewSec / 2;
      e = c + kMinViewSec / 2;
    }
    if (e - s > domain) return TimelineView(domainStart, domainEnd);
    if (s < domainStart) {
      e += domainStart - s;
      s = domainStart;
    }
    if (e > domainEnd) {
      s -= e - domainEnd;
      e = domainEnd;
    }
    return TimelineView(s, e);
  }

  /// The double-tap zoom: [kDoubleTapZoom] of this span, centred on [t],
  /// then made legal ([clampTo]).
  TimelineView zoomAt(double t, double domainStart, double domainEnd) {
    final s = span * kDoubleTapZoom;
    return TimelineView(t - s / 2, t + s / 2).clampTo(domainStart, domainEnd);
  }

  TimelineView lerp(TimelineView to, double k) =>
      TimelineView(start + (to.start - start) * k, end + (to.end - end) * k);

  @override
  bool operator ==(Object other) =>
      other is TimelineView && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'TimelineView($start, $end)';
}

/// How long a zoom from [from] to [to] glides: 1.5 s, up to 2 s for a big
/// change of scale (a factor of 8 or more). A pan at the same scale is 1.5 s.
Duration zoomDuration(TimelineView from, TimelineView to) {
  if (from.span <= 0 || to.span <= 0) return const Duration(milliseconds: 1500);
  final ratio = (math.log(from.span / to.span) / math.ln2).abs();
  return Duration(milliseconds: 1500 + (500 * math.min(1.0, ratio / 3)).round());
}

/// Ease-in-out (cubic), the zoom's curve. Pure, so the frames are testable.
double easeInOut(double t) {
  final x = t.clamp(0.0, 1.0);
  return x < .5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3) / 2;
}

/// The view that frames [start] .. [end] with half its length either side
/// (at least 30 minutes each side): what a double tap on a block glides to.
TimelineView framing(int start, int end, double domainStart, double domainEnd) {
  final pad = math.max(30 * 60.0, (end - start) / 2);
  return TimelineView(start - pad, end + pad).clampTo(domainStart, domainEnd);
}

// ── the stage wave (spec §1 "Stage wave") ───────────────────────────────────

/// Height of a stage in the wave: Awake on top, Deep at the bottom.
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

// ── blocks (spec §3 "Blocks") ───────────────────────────────────────────────

enum BlockKind { main, nap }

/// One sleep block on the night: the main sleep or a nap.
class SleepBlock {
  const SleepBlock(this.id, this.kind, this.start, this.end);
  final String id;
  final BlockKind kind;
  final int start, end;
  int get length => end - start;
  SleepBlock copyWith({int? start, int? end}) =>
      SleepBlock(id, kind, start ?? this.start, end ?? this.end);
  bool contains(double t) => t >= start && t < end;
  @override
  bool operator ==(Object other) =>
      other is SleepBlock && other.id == id && other.kind == kind &&
      other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(id, kind, start, end);
  @override
  String toString() => 'SleepBlock($id, ${kind.name}, $start, $end)';
}

/// A block is never shorter than this (a nap must last 5 minutes; the editor
/// keeps a little more so both handles stay grabbable).
const int kMinBlockSec = 10 * 60;

/// Which end of a block a handle moves.
enum BlockEnd { start, end }

/// [blocks] with [id]'s [which] end moved to [to], clamped: never across the
/// neighbouring block's edge (blocks never overlap), never shorter than
/// [kMinBlockSec], never outside [domainStart] .. [domainEnd]. Returns the
/// list unchanged when [id] is not in it.
List<SleepBlock> moveBlockEnd(List<SleepBlock> blocks, String id, BlockEnd which,
    int to, {required int domainStart, required int domainEnd}) {
  final b = blocks.where((x) => x.id == id).firstOrNull;
  if (b == null) return blocks;
  final others = blocks.where((x) => x.id != id);
  int lo, hi;
  if (which == BlockEnd.start) {
    lo = domainStart;
    for (final o in others) {
      if (o.end <= b.start) lo = math.max(lo, o.end);
    }
    hi = b.end - kMinBlockSec;
  } else {
    hi = domainEnd;
    for (final o in others) {
      if (o.start >= b.end) hi = math.min(hi, o.start);
    }
    lo = b.start + kMinBlockSec;
  }
  final v = hi < lo ? (which == BlockEnd.start ? b.start : b.end) : to.clamp(lo, hi);
  final moved = which == BlockEnd.start ? b.copyWith(start: v) : b.copyWith(end: v);
  return [for (final x in blocks) x.id == id ? moved : x];
}

/// Whether any two of [blocks] overlap (touching edges do not).
bool blocksOverlap(List<SleepBlock> blocks) {
  final s = [...blocks]..sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < s.length; i++) {
    if (s[i].start < s[i - 1].end) return true;
  }
  return false;
}

/// Where "Add sleep block" puts a new nap: an hour (shorter when the gap is
/// short) in the free stretch [before] or after the main sleep, away from the
/// main sleep and any other nap. Null when that side has no room.
SleepBlock? placeNap(List<SleepBlock> blocks, {required bool before,
    required int domainStart, required int domainEnd, required String id}) {
  final main = blocks.firstWhere((b) => b.kind == BlockKind.main);
  // The free stretch on that side nearest the main sleep.
  var lo = before ? domainStart : main.end, hi = before ? main.start : domainEnd;
  for (final o in blocks) {
    if (o.id == main.id) continue;
    if (before && o.end <= main.start) lo = math.max(lo, o.end);
    if (!before && o.start >= main.end) hi = math.min(hi, o.start);
  }
  // A 30-minute margin from the main sleep, when there is room for it.
  const margin = 30 * 60;
  if (before && hi - lo > kMinBlockSec + margin) hi -= margin;
  if (!before && hi - lo > kMinBlockSec + margin) lo += margin;
  if (hi - lo < kMinBlockSec) return null;
  final len = math.min(60 * 60, hi - lo);
  // Before: the hour that ends at the margin; after: the hour a few hours
  // into the day (mid-afternoon on a 24-hour night), never past the gap.
  final start = before ? hi - len : math.min(lo + 6 * 3600, hi - len);
  final s = (start ~/ 300) * 300;
  return SleepBlock(id, BlockKind.nap, math.max(s, lo), math.max(s, lo) + len);
}

// ── the magnifier drag (spec §3 "Magnifier drag of an end") ─────────────────

/// Held still this long, a drag switches to 1-minute steps.
const Duration kFineHold = Duration(milliseconds: 600);

/// In 1-minute steps the end moves at this share of the finger's speed.
const double kFineSpeed = .25;

/// One handle drag. Coarse: the end follows the finger, rounded to 5 minutes.
/// After [hold] (the widget calls it when the finger has been still for
/// [kFineHold]): 1-minute steps at a quarter of the finger's speed, from
/// where the end was.
class MagnifierDrag {
  MagnifierDrag(this.value);

  /// The end's time, epoch seconds.
  int value;
  bool fine = false;
  double? _anchorPx;
  int _anchorValue = 0;

  /// The finger at [px] over a view of [secPerPx] seconds per pixel, where
  /// [tAtPx] is the view's time under the finger. Returns the new [value].
  int update(double px, double tAtPx, double secPerPx) {
    if (!fine) {
      value = (tAtPx / 300).round() * 300;
    } else {
      _anchorPx ??= px;
      final dt = (px - _anchorPx!) * secPerPx * kFineSpeed;
      value = _anchorValue + (dt / 60).round() * 60;
    }
    return value;
  }

  /// The finger has been still: switch to 1-minute steps from [value]. The
  /// next [update] sets the anchor. Returns false when already fine.
  bool hold() {
    if (fine) return false;
    fine = true;
    _anchorValue = value;
    _anchorPx = null;
    return true;
  }
}

/// How strongly a value landing on a minute is felt (spec: a weak tick per
/// minute; strong at 5, 10, 30 and 60 minutes).
enum HapticTier { minute, five, ten, thirty, hour }

/// The tier for a local [minuteOfDay] (0 .. 1439): the coarsest round number
/// it lands on.
HapticTier hapticTier(int minuteOfDay) {
  final m = minuteOfDay % 1440;
  if (m % 60 == 0) return HapticTier.hour;
  if (m % 30 == 0) return HapticTier.thirty;
  if (m % 10 == 0) return HapticTier.ten;
  if (m % 5 == 0) return HapticTier.five;
  return HapticTier.minute;
}

// ── zoom selection (spec §4 "⌕") ────────────────────────────────────────────

/// The two ⌕ handles: [a] .. [b], at least [kMinViewSec] apart. Moving one
/// never passes the other.
class ZoomSelection {
  const ZoomSelection(this.a, this.b);
  final double a, b;

  /// The selection that starts as the middle 40% of [v] around [t].
  factory ZoomSelection.around(TimelineView v, double t) {
    final half = math.max(kMinViewSec / 2, v.span * .2);
    var a = math.max(v.start, t - half), b = math.min(v.end, t + half);
    if (b - a < kMinViewSec) {
      if (a == v.start) {
        b = a + kMinViewSec;
      } else {
        a = b - kMinViewSec;
      }
    }
    return ZoomSelection(a, b);
  }

  ZoomSelection move(bool first, double t) => first
      ? ZoomSelection(math.min(t, b - kMinViewSec), b)
      : ZoomSelection(a, math.max(t, a + kMinViewSec));

  /// Which handle is nearer [t]: true for [a].
  bool nearerA(double t) => (t - a).abs() <= (t - b).abs();
}
