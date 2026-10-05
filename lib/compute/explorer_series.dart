// explorer_series.dart — the Data Explorer's pure half: the shared time grid,
// the line a metric becomes on it, normalisation, baselines, and the codec the
// picks and range are remembered in.
//
// PURE DART. No UI framework, no database and no clock (every date is a
// parameter), so it also runs under `Isolate.run` if a range ever makes the
// alignment heavy. Measured once (see the Explorer's header): it is not.
//
// TWO SCALES, ONE RULE. Daily lines are laid on a grid of LOCAL calendar days;
// intraday lines on one real local day (23, 24 or 25 h). Either way x is a
// 0..1 fraction of that grid, so every line shares one time axis and nothing
// is resampled. A day or a stretch with no reading is a GAP: the line breaks
// there, nothing is drawn in it and nothing reads from it. Nothing here
// interpolates, fills or substitutes (AGENTS §3.3).

import 'dart:math' as math;

import '../data/day_label.dart';

/// Metrics that can be laid over each other at once.
const int kExploreMaxMetrics = 4;

/// The fewest real readings a baseline needs, and how many of the newest it
/// uses. Fewer than the first and there is nothing to be "usual" against.
const int kExploreMinBaselineDays = 7;
const int kExploreBaselineDays = 28;

/// A step wider than this many times the series' OWN median step is a hole.
/// One-minute heart rate breaks at 90 s; five-minute HRV at 7.5 min.
const double kExploreGapFactor = 1.5;

/// z is clipped to this many standard deviations before it is drawn.
const double _zClip = 3;

enum ExploreRange { d7, d30, m6, y1, custom }

extension ExploreRangeDays on ExploreRange {
  /// Length of the trailing window; null for a custom span.
  int? get days => switch (this) {
        ExploreRange.d7 => 7,
        ExploreRange.d30 => 30,
        ExploreRange.m6 => 180,
        ExploreRange.y1 => 365,
        ExploreRange.custom => null,
      };
}

/// A stored reading: [t] epoch SECONDS, [v] the real value. Structurally the
/// same record as the screens' `ChartPoint`.
typedef ExplorePoint = ({int t, double v});

/// A drawn point: [at] 0..1 across the axis, [y] 0..1 up the plot.
typedef ExploreXY = ({double at, double y});

/// The shared DAY grid. Days come from calendar arithmetic on the label, never
/// from adding 86 400 s, so a DST week is still seven consecutive days.
class ExploreWindow {
  final String from, to;

  /// Inclusive local labels, oldest first.
  final List<String> days;

  /// Epoch seconds of each day's local midnight, then the end of the last day:
  /// `days.length + 1` entries. A reading belongs to the day whose midnight is
  /// the latest one at or before it, which finds its day with no calendar work
  /// per reading (that work dominated the cost of a one-year window).
  final List<int> bounds;

  ExploreWindow._(List<DateTime> midnights)
      : days = [for (final d in midnights.take(midnights.length - 1)) dayLabelOf(d)],
        bounds = [for (final d in midnights) d.millisecondsSinceEpoch ~/ 1000],
        from = dayLabelOf(midnights.first),
        to = dayLabelOf(midnights[midnights.length - 2]);

  int get length => days.length;

  /// The [r] days ending on [today].
  factory ExploreWindow.trailing(ExploreRange r, {required String today}) {
    final n = r.days!;
    final p = today.split('-').map(int.parse).toList();
    return ExploreWindow._([
      for (var i = n - 1; i >= -1; i--) DateTime(p[0], p[1], p[2] - i),
    ]);
  }

  /// [a] to [b] inclusive. A reversed pair is swapped, never an empty window.
  factory ExploreWindow.custom(String a, String b) {
    final lo = a.compareTo(b) <= 0 ? a : b, hi = a.compareTo(b) <= 0 ? b : a;
    final p = lo.split('-').map(int.parse).toList();
    final n = calendarDaysBetween(DateTime.parse(lo), DateTime.parse(hi)) + 1;
    return ExploreWindow._([
      for (var i = 0; i <= n; i++) DateTime(p[0], p[1], p[2] + i),
    ]);
  }

  /// The grid slot of epoch second [t], or null outside the window.
  int? slotOf(int t) {
    if (t < bounds.first || t >= bounds.last) return null;
    var lo = 0, hi = bounds.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (bounds[mid] <= t) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

/// A metric's usual level: mean and sample standard deviation.
class ExploreBaseline {
  final double mean, sd;
  const ExploreBaseline(this.mean, this.sd);
}

/// The baseline of [history], OLDEST FIRST: mean and sample sd of the newest
/// [kExploreBaselineDays] finite readings. Null with fewer than
/// [kExploreMinBaselineDays] of them, or when they do not vary: a flat history
/// has no spread to measure against and a divide by it would invent a score.
ExploreBaseline? exploreBaseline(Iterable<double> history) {
  final v = [
    for (final x in history)
      if (x.isFinite) x
  ];
  if (v.length < kExploreMinBaselineDays) return null;
  final w = v.length > kExploreBaselineDays
      ? v.sublist(v.length - kExploreBaselineDays)
      : v;
  final mean = w.reduce((a, b) => a + b) / w.length;
  final ss = w.fold<double>(0, (a, b) => a + (b - mean) * (b - mean));
  final sd = math.sqrt(ss / (w.length - 1));
  return sd <= 1e-9 ? null : ExploreBaseline(mean, sd);
}

double exploreZ(double v, ExploreBaseline b) => (v - b.mean) / b.sd;

/// z clipped to +-3 sd and mapped to 0..1: the mean is the middle.
double exploreZ01(double v, ExploreBaseline b) =>
    (exploreZ(v, b).clamp(-_zClip, _zClip) + _zClip) / (2 * _zClip);

/// Why z is not on offer for [key], or null when it is. The text is shown as
/// is, beside the disabled toggle.
String? exploreZUnavailable(String key, Iterable<double> history,
    {bool intraday = false}) {
  if (intraday) return 'Baselines are daily';
  // Already a distance from a baseline, or a score built against one.
  if (key == 'skin_temp' || key == 'readiness') {
    return 'Already measured against your baseline';
  }
  final v = [
    for (final x in history)
      if (x.isFinite) x
  ];
  if (v.length < kExploreMinBaselineDays) {
    return 'Needs at least $kExploreMinBaselineDays days of history';
  }
  return exploreBaseline(v) == null ? 'Your readings do not vary enough' : null;
}

/// One metric on the grid.
class ExploreLine {
  final String key;

  /// Unbroken stretches of real readings, oldest first: [at] is 0..1 across
  /// the axis and [v] is the REAL value, never a normalised one.
  final List<List<({double at, double v})>> runs;

  // Daily: the reading of each grid slot. Intraday: every point in time order.
  final int _slots;
  final Map<int, double> _bySlot;
  final List<({double at, double v})> _flat;
  final double _tol;

  ExploreLine._(this.key, this.runs, this._slots, this._bySlot, this._flat,
      this._tol);

  /// [pts] laid on the day grid [w] by LOCAL day. A day outside the window or
  /// with a non-finite value is dropped; two readings on one day keep the
  /// later; a day with none breaks the line.
  factory ExploreLine.daily(
      String key, Iterable<ExplorePoint> pts, ExploreWindow w) {
    final by = <int, double>{}, newest = <int, int>{};
    for (final p in pts) {
      final i = p.v.isFinite ? w.slotOf(p.t) : null;
      if (i == null) continue;
      final seen = newest[i];
      if (seen == null || p.t >= seen) {
        newest[i] = p.t;
        by[i] = p.v;
      }
    }
    final runs = <List<({double at, double v})>>[];
    int? prev;
    for (final i in by.keys.toList()..sort()) {
      if (prev == null || i != prev + 1) runs.add([]);
      runs.last.add((at: (i + .5) / w.length, v: by[i]!));
      prev = i;
    }
    return ExploreLine._(key, runs, w.length, by, const [], 0);
  }

  /// [pts] on the real local day [dayStart, dayEnd) (epoch seconds). The line
  /// breaks wherever the step between readings is more than
  /// [kExploreGapFactor] times the series' own median step.
  factory ExploreLine.intraday(String key, Iterable<ExplorePoint> pts,
      {required int dayStart, required int dayEnd}) {
    final s = [
      for (final p in pts)
        if (p.v.isFinite && p.t >= dayStart && p.t < dayEnd) p
    ]..sort((a, b) => a.t.compareTo(b.t));
    // One reading has no step of its own; a minute-ish default keeps it a dot.
    var gap = 90.0;
    if (s.length >= 2) {
      final steps = [
        for (var i = 1; i < s.length; i++) (s[i].t - s[i - 1].t).toDouble()
      ]..sort();
      gap = kExploreGapFactor * steps[steps.length ~/ 2];
    }
    final span = dayEnd - dayStart;
    final runs = <List<({double at, double v})>>[];
    final flat = <({double at, double v})>[];
    for (var i = 0; i < s.length; i++) {
      if (i == 0 || s[i].t - s[i - 1].t > gap) runs.add([]);
      final p = (at: (s[i].t - dayStart) / span, v: s[i].v);
      runs.last.add(p);
      flat.add(p);
    }
    return ExploreLine._(key, runs, 0, const {}, flat, gap / 2 / span);
  }

  bool get isEmpty => runs.isEmpty;

  /// The lowest and highest real value, null for an empty line.
  ({double min, double max})? get extent {
    double? lo, hi;
    for (final r in runs) {
      for (final p in r) {
        lo = lo == null ? p.v : math.min(lo, p.v);
        hi = hi == null ? p.v : math.max(hi, p.v);
      }
    }
    return lo == null ? null : (min: lo, max: hi!);
  }

  /// The REAL value at [at] (0..1, clamped), or null where nothing was read:
  /// the day under the position for a daily line, the nearest sample within
  /// half a gap for an intraday one.
  double? valueAt(double at) {
    if (_slots > 0) return _bySlot[(at * _slots).floor().clamp(0, _slots - 1)];
    if (_flat.isEmpty) return null;
    // Nearest by binary search: `_flat` is in time order.
    var lo = 0, hi = _flat.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_flat[mid].at < at) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var best = _flat[lo];
    if (lo > 0 && (at - _flat[lo - 1].at).abs() <= (best.at - at).abs()) {
      best = _flat[lo - 1];
    }
    return (best.at - at).abs() <= _tol ? best.v : null;
  }

  /// The runs as drawn: y 0..1 over this line's own min..max (a flat line sits
  /// mid-band), or against [z] when given. The break structure and every x are
  /// unchanged.
  List<List<ExploreXY>> normalised({ExploreBaseline? z}) {
    final e = extent;
    if (e == null) return const [];
    final flat = (e.max - e.min).abs() < 1e-12;
    double y(double v) =>
        z != null ? exploreZ01(v, z) : (flat ? .5 : (v - e.min) / (e.max - e.min));
    return [
      for (final r in runs) [for (final p in r) (at: p.at, y: y(p.v))],
    ];
  }
}

enum ExploreBandKind { sleep, nap, workout }

/// A stretch of the day: [from]..[to] as fractions of its real length.
class ExploreBand {
  final ExploreBandKind kind;
  final double from, to;
  const ExploreBand(this.kind, this.from, this.to);
}

/// Sleep, naps and workouts of a `getDayTimeline` map as bands on the day
/// [dayStart, dayEnd), clipped to it (a night that began yesterday is a band
/// from midnight). Reversed, empty and outside spans make nothing.
List<ExploreBand> exploreBands(Map<String, dynamic> timeline,
    {required int dayStart, required int dayEnd}) {
  final out = <ExploreBand>[];
  void add(ExploreBandKind k, Object? a, Object? b) {
    final s = (a as num?)?.toInt(), e = (b as num?)?.toInt();
    if (s == null || e == null || e <= s) return;
    final lo = s.clamp(dayStart, dayEnd), hi = e.clamp(dayStart, dayEnd);
    if (hi <= lo) return;
    final span = dayEnd - dayStart;
    out.add(ExploreBand(k, (lo - dayStart) / span, (hi - dayStart) / span));
  }

  for (final s in (timeline['sleep'] as List?) ?? const []) {
    if (s is Map) add(ExploreBandKind.sleep, s['onset_ts'], s['wake_ts']);
  }
  for (final s in (timeline['naps'] as List?) ?? const []) {
    if (s is Map) add(ExploreBandKind.nap, s['start'], s['end']);
  }
  for (final s in (timeline['sessions'] as List?) ?? const []) {
    if (s is Map) add(ExploreBandKind.workout, s['start_ts'], s['end_ts']);
  }
  out.sort((a, b) => a.from.compareTo(b.from));
  return out;
}

/// One intraday metric: where it is stored and how it is named and coloured.
class ExploreIntradaySource {
  /// The pick key (and the `getDayTimeline` lane, except calories).
  final String key;
  final String timelineKey;

  /// The `MetricSpec` the colour comes from.
  final String specKey;
  final String label, unit;

  /// Stored value x [scale] is what the readout says (activity is stored as a
  /// 0..1 share of time moving and read as a percentage, as the day screen does).
  final double scale;

  const ExploreIntradaySource(
      this.key, this.timelineKey, this.specKey, this.label, this.unit,
      {this.scale = 1});
}

/// The intraday metrics, in picker order.
const List<ExploreIntradaySource> kExploreIntraday = [
  ExploreIntradaySource('hr', 'hr', 'resting_hr', 'Heart rate', 'bpm'),
  ExploreIntradaySource('hrv', 'hrv', 'hrv', 'HRV', 'ms'),
  ExploreIntradaySource('resp', 'resp', 'resp_rate', 'Respiratory rate', 'br/min'),
  ExploreIntradaySource(
      'skin_temp', 'skin_temp', 'skin_temp', 'Skin temperature (relative)', ''),
  ExploreIntradaySource('activity', 'activity', 'active_min', 'Movement', '%',
      scale: 100),
  ExploreIntradaySource(
      'calories', 'calories', 'calories', 'Active energy', 'kcal/min'),
];

/// The stored readings of intraday metric [key]: a lane of `getDayTimeline`, or
/// the minutes of the calorie curve for `calories` (active energy; a minute
/// nobody measured has null figures and is not a point). Anything absent is no
/// points, never a placeholder.
List<ExplorePoint> exploreIntradayPoints(String key,
    {Map<String, dynamic>? timeline, Map<String, dynamic>? calories}) {
  if (key == 'calories') {
    return [
      for (final m in (calories?['minutes'] as List?) ?? const [])
        if (m is Map && m['t'] is num && m['active'] is num)
          (t: (m['t'] as num).toInt(), v: (m['active'] as num).toDouble()),
    ];
  }
  return [
    for (final e in (timeline?[key] as List?) ?? const [])
      // hr 0 is the pipeline's "no lock", not a heart that stopped.
      if (e is Map &&
          e['t'] is num &&
          e['v'] is num &&
          (key != 'hr' || (e['v'] as num) > 0))
        (t: (e['t'] as num).toInt(), v: (e['v'] as num).toDouble()),
  ];
}

// ── what the Explorer remembers ──

/// The remembered pick keys: unknown and repeated keys dropped, capped at
/// [kExploreMaxMetrics]. Whatever is stored is distrusted.
List<String> decodeExploreKeys(String? raw, {required Set<String> valid}) {
  final out = <String>[];
  for (final k in (raw ?? '').split(',')) {
    if (valid.contains(k) && !out.contains(k) && out.length < kExploreMaxMetrics) {
      out.add(k);
    }
  }
  return out;
}

String encodeExploreKeys(List<String> keys) => keys.join(',');

/// A strict 'YYYY-MM-DD' that is a real calendar day.
bool _isDay(String s) {
  final d = DateTime.tryParse(s);
  return d != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s) && dayLabelOf(d) == s;
}

/// The remembered range; anything unreadable is 30 days.
({ExploreRange range, String? from, String? to}) decodeExploreRange(String? raw) {
  switch (raw) {
    case 'd7':
      return (range: ExploreRange.d7, from: null, to: null);
    case 'm6':
      return (range: ExploreRange.m6, from: null, to: null);
    case 'y1':
      return (range: ExploreRange.y1, from: null, to: null);
  }
  if (raw != null && raw.startsWith('custom:')) {
    final p = raw.substring(7).split('..');
    if (p.length == 2 && _isDay(p[0]) && _isDay(p[1])) {
      return (range: ExploreRange.custom, from: p[0], to: p[1]);
    }
  }
  return (range: ExploreRange.d30, from: null, to: null);
}

String encodeExploreRange(ExploreRange r, {String? from, String? to}) =>
    switch (r) {
      ExploreRange.d7 => 'd7',
      ExploreRange.d30 => 'd30',
      ExploreRange.m6 => 'm6',
      ExploreRange.y1 => 'y1',
      ExploreRange.custom => 'custom:$from..$to',
    };
