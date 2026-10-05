// THE DATA EXPLORER — up to four metrics laid over one time axis.
//
// Time is the one shared axis and every line is NORMALISED onto it, because
// bpm, milliseconds and steps cannot share a y axis. The picture compares
// shapes; the readout under it (touch or drag the chart) carries the REAL value
// and unit of each metric at that moment, "—" where it has none. The chart says
// "Normalised" in words, so nobody reads a height as a value.
//
// TWO SCALES. Daily: the Trends catalogue (`kMetricCatalogue`) over 7 d, 30 d,
// 6 mo, 1 y or a custom span, one point per local day. Day: one day's lanes
// (heart rate, HRV, breathing, skin temperature, movement, active energy) on a
// clock, with sleep and workout bands behind them.
//
// GAPS STAY GAPS. A day or a stretch with no reading breaks the line there:
// nothing is interpolated, and a metric with nothing in view draws no line at
// all (it is named under the chart instead). Each line is scaled to its own
// lowest and highest over what is on screen, or against its own baseline (z)
// where one exists; where it does not, the toggle is off and says why.
//
// COST, measured once (a one-year window of four metrics with three years
// stored, aligned and normalised; JIT, so slower than a release build): about
// 3 ms for the lines plus 7 ms to build the window, which is kept across
// frames. One minute-resolution intraday day of four lanes (what
// `getDayTimeline` serves) is 0.4 ms. That is inside a frame, so it runs on the
// UI isolate. The pure half (compute/explorer_series.dart) imports no Flutter
// and is tested under `Isolate.run`, so moving it is a one-line change.
//
// ponytail: a raw 1 Hz lane (86 400 points, ~50 ms per lane) would need that
// move. Nothing serves one: the stored lanes are per-minute and 1 Hz is never
// read back (AGENTS §3.14).

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../compute/explorer_series.dart';
import '../../data/day_label.dart';
import '../../l10n/app_localizations.dart';
import '../../state/prefs.dart';
import '../ui2.dart';
import 'home_screen.dart';
import 'metric_catalogue.dart';
import 'metric_detail.dart' show specOf;

/// What the Explorer remembers, in the app prefs with the other UI selections.
/// '' is unset. The chosen DAY is deliberately not remembered.
const kExploreMetricsPref = 'ui.explore_metrics';
const kExploreIntradayPref = 'ui.explore_intraday';
const kExploreRangePref = 'ui.explore_range';
const kExploreScalePref = 'ui.explore_scale'; // 'daily' | 'day'
const kExploreZPref = 'ui.explore_z';

/// One metric as drawn: its own colour and its runs, already NORMALISED (0..1
/// up the plot, 0..1 along the axis). A metric with nothing to draw has no line.
class ExplorePlotLine {
  final String key;
  final Color color;
  final List<List<ExploreXY>> runs;
  const ExplorePlotLine(this.key, this.color, this.runs);
}

/// The plot: sleep and workout bands, then each line. A run breaks wherever
/// the data does; a run of one point is a dot, since a polyline cannot show it.
class ExplorePlotPainter extends CustomPainter {
  final List<ExplorePlotLine> lines;
  final List<ExploreBand> bands;
  final P p;

  /// A rule across the middle: where "usual" sits when a line is against its
  /// baseline.
  final bool midline;

  ExplorePlotPainter(
      {required this.lines,
      required this.p,
      this.bands = const [],
      this.midline = false});

  /// Room above and below so a line at 0 or 1 is not half clipped.
  static const _pad = 4.0;

  @override
  void paint(Canvas cv, Size s) {
    if (s.width <= 0 || s.height <= 0) return;
    double x(double f) => f.clamp(0.0, 1.0) * s.width;
    double y(double f) => s.height - _pad - f * (s.height - _pad * 2);

    for (final b in bands) {
      final l = x(b.from), r = x(b.to);
      if (b.kind == ExploreBandKind.workout) {
        // A block on the top edge, as the Day timeline draws it.
        cv.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(l, 0, (r - l).clamp(2, s.width), 5),
                const Radius.circular(2)),
            Paint()..color = C.orange);
      } else {
        cv.drawRect(Rect.fromLTRB(l, 0, r, s.height),
            Paint()..color = C.blue.withValues(alpha: p.dark ? .20 : .13));
      }
    }
    if (midline) {
      cv.drawLine(Offset(0, y(.5)), Offset(s.width, y(.5)),
          Paint()..color = p.line..strokeWidth = 1);
    }
    for (final l in lines) {
      final ink = p.on(l.color);
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = ink;
      for (final r in l.runs) {
        if (r.isEmpty) continue;
        if (r.length == 1) {
          cv.drawCircle(Offset(x(r.first.at), y(r.first.y)), 2.4, Paint()..color = ink);
          continue;
        }
        final path = Path()..moveTo(x(r.first.at), y(r.first.y));
        for (final pt in r.skip(1)) {
          path.lineTo(x(pt.at), y(pt.y));
        }
        cv.drawPath(path, stroke);
      }
    }
  }

  @override
  bool shouldRepaint(covariant ExplorePlotPainter o) =>
      !identical(o.lines, lines) ||
      !identical(o.bands, bands) ||
      o.midline != midline ||
      o.p.dark != p.dark;
}

/// The catalogue keys that may be charted: a metric whose spec says it must not
/// be (skin temperature has no trend to draw) is not offered.
final Set<String> _dailyKeys = {
  for (final c in kMetricCatalogue)
    for (final r in c.rows)
      if (specOf(r.key).suppress == null) r.key,
};

/// A value as the readout says it: one rule for precision, unit beside it.
String _say(String unit, double v) {
  final n = metricValue(unit, v);
  final u = unitBeside(unit);
  return u.isEmpty ? n : (u == '%' ? '$n%' : '$n $u');
}

/// One picked metric, ready to draw and to read.
class _Pick {
  final String key, label, unit;
  final Color color;
  final double scale;

  /// Null until its data has been read.
  final ExploreLine? line;

  /// Why z is not on offer, or null when it is (or the data is not here yet).
  final String? zReason;
  final ExploreBaseline? baseline;
  const _Pick(this.key, this.label, this.unit, this.color, this.scale, this.line,
      this.zReason, this.baseline);

  bool get hasData => line != null && !line!.isEmpty;
}

/// The Explorer as a pushed screen: a NavBar over [ExplorerView], scrolling.
/// It is not a Health tab (it is not ready for everyone); the only way in is
/// the Developer group in Settings.
class ExplorerScreen extends StatelessWidget {
  const ExplorerScreen({super.key});

  @override
  Widget build(BuildContext c) => Scaffold(
        backgroundColor: P.of(c).bg,
        body: SafeArea(
          child: Column(children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar('Data Explorer'),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
                children: const [ExplorerView()],
              ),
            ),
          ]),
        ),
      );
}

class ExplorerView extends StatefulWidget {
  /// [today] ('YYYY-MM-DD', local) is injectable for tests; null is the real one.
  const ExplorerView({super.key, this.today});
  final String? today;

  /// The RepaintBoundary around the plot painter (§4.11). The scrub cursor sits
  /// OUTSIDE it, so dragging a finger repaints the cursor and never the plot.
  static const plotKey = ValueKey('explore-plot');

  static const limitMessage =
      'You can compare up to 4 metrics. Remove one to add another.';

  @override
  State<ExplorerView> createState() => _ExplorerViewState();
}

class _ExplorerViewState extends State<ExplorerView> with RevisionReload {
  late bool _day = Prefs.getString(kExploreScalePref, '') == 'day';
  late ExploreRange _range;
  String? _from, _to;
  late final List<String> _daily, _intra;
  late final Set<String> _z;
  late String _dayLabel = _today;
  bool _full = false, _loading = false, _failed = false;

  // What has been read. A daily metric's WHOLE stored series, oldest first (the
  // window cuts it and a baseline needs what is outside it); one day's timeline
  // and calorie curve.
  final Map<String, List<ChartPoint>> _hist = {};
  final Map<String, Map<String, dynamic>> _timelines = {};
  final Map<String, Map<String, dynamic>?> _cals = {};

  // The day grid is expensive to build and the same for every frame.
  ExploreWindow? _win;
  String _winFor = '';

  String get _today => widget.today ?? todayLabel();

  @override
  void initState() {
    super.initState();
    _daily = decodeExploreKeys(Prefs.getString(kExploreMetricsPref, ''),
        valid: _dailyKeys);
    _intra = decodeExploreKeys(Prefs.getString(kExploreIntradayPref, ''),
        valid: {for (final s in kExploreIntraday) s.key});
    final r = decodeExploreRange(Prefs.getString(kExploreRangePref, ''));
    _range = r.range;
    _from = r.from;
    _to = r.to;
    _z = {
      for (final k in Prefs.getString(kExploreZPref, '').split(','))
        if (_dailyKeys.contains(k)) k
    };
    // The remembered picks are on the first frame; their data follows it.
    _loading = _picks.isNotEmpty;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  List<String> get _picks => _day ? _intra : _daily;

  ExploreWindow get _window {
    final custom = _range == ExploreRange.custom && _from != null && _to != null;
    final id = custom ? '$_from..$_to' : '${_range.name}|$_today';
    if (_win == null || _winFor != id) {
      _win = custom
          ? ExploreWindow.custom(_from!, _to!)
          : ExploreWindow.trailing(
              _range == ExploreRange.custom ? ExploreRange.d30 : _range,
              today: _today);
      _winFor = id;
    }
    return _win!;
  }

  // ─────────────── reading ───────────────

  /// Reads what the picks on screen need and has not been read; [refresh]
  /// re-reads all of it without showing a spinner (a derive landed under it).
  ///
  /// Every call claims a token and only the newest commits, so an older read
  /// finishing late cannot put older data back (see [RevisionReload.beginRead]).
  /// The loading flag is cleared on every path that commits or fails.
  Future<void> _load({bool refresh = false}) async {
    final t = beginRead(#explore);
    final day = _dayLabel;
    final charts = <String, List<ChartPoint>>{};
    Map<String, dynamic>? timeline, cal;
    var readTimeline = false, readCal = false;
    try {
      final repo = repoOf(context);
      final need = <Future<void>>[];
      if (repo != null) {
        // `Future.sync`: a repository that throws before it returns a future
        // (the base class's stubs do) fails like any other read.
        if (_day) {
          if (_intra.any((k) => k != 'calories') &&
              (refresh || !_timelines.containsKey(day))) {
            need.add(Future.sync(() => repo.getDayTimeline(day)).then((m) {
              timeline = m;
              readTimeline = true;
            }));
          }
          if (_intra.contains('calories') &&
              (refresh || !_cals.containsKey(day))) {
            need.add(Future.sync(() => repo.getDayCalorieCurve(day)).then((m) {
              cal = m;
              readCal = true;
            }));
          }
        } else {
          for (final k in _daily) {
            if (!refresh && _hist.containsKey(k)) continue;
            need.add(Future.sync(() => repo.getChart(specOf(k).chartKey))
                .then((c) => charts[k] =
                    [...pointsOf(c)]..sort((a, b) => a.t.compareTo(b.t))));
          }
        }
      }
      if (need.isEmpty) {
        if (_loading || _failed) {
          setState(() {
            _loading = false;
            _failed = false;
          });
        }
        return;
      }
      if (!refresh) {
        setState(() {
          _loading = true;
          _failed = false;
        });
      }
      await Future.wait(need);
      if (!stillNewest(#explore, t)) return;
      setState(() {
        _hist.addAll(charts);
        if (readTimeline) _timelines[day] = timeline ?? const {};
        if (readCal) _cals[day] = cal;
        _loading = false;
      });
    } catch (_) {
      if (!stillNewest(#explore, t)) return;
      setState(() {
        // A quiet refresh that fails leaves what was shown; one the user is
        // waiting on is a retryable error, never an empty chart.
        if (!refresh || _loading) _failed = true;
        _loading = false;
      });
    }
  }

  /// A derive or an import landed: what was read may be out of date. The other
  /// scale's reads are dropped (read again when it is shown); this one is
  /// re-read in place.
  @override
  void reload() {
    if (_day) {
      _hist.clear();
    } else {
      _timelines.clear();
      _cals.clear();
    }
    if (_picks.isNotEmpty) _load(refresh: true);
  }

  // ─────────────── choosing ───────────────

  void _savePicks() => Prefs.setString(
      _day ? kExploreIntradayPref : kExploreMetricsPref, encodeExploreKeys(_picks));

  /// Adds [k], or removes it if it is already there. A fifth is refused with a
  /// message and reads nothing.
  void _toggle(String k) {
    if (_picks.contains(k)) return _remove(k);
    if (_picks.length >= kExploreMaxMetrics) {
      setState(() => _full = true);
      return;
    }
    setState(() {
      _picks.add(k);
      _full = false;
    });
    _savePicks();
    _load();
  }

  void _remove(String k) {
    setState(() {
      _picks.remove(k);
      _full = false;
    });
    _savePicks();
  }

  void _setScale(bool day) {
    if (day == _day) return;
    setState(() {
      _day = day;
      _full = false;
    });
    Prefs.setString(kExploreScalePref, day ? 'day' : 'daily');
    _load();
  }

  void _setRange(ExploreRange r) {
    setState(() => _range = r);
    Prefs.setString(kExploreRangePref, encodeExploreRange(r));
  }

  Future<void> _pickCustom() async {
    final today = DateTime.parse(_today);
    final w = _window;
    final span = DateTimeRange(
        start: DateTime.parse(w.from), end: DateTime.parse(w.to));
    final res = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: today,
      initialDateRange: span.end.isAfter(today) ? null : span,
    );
    if (res == null || !mounted) return;
    setState(() {
      _range = ExploreRange.custom;
      _from = dayLabelOf(res.start);
      _to = dayLabelOf(res.end);
    });
    Prefs.setString(
        kExploreRangePref, encodeExploreRange(_range, from: _from, to: _to));
  }

  /// A different day is read afresh each time: a day already seen may have been
  /// derived again since, and the read is one stored row.
  void _setDay(String d) {
    setState(() {
      _dayLabel = d;
      _timelines.clear();
      _cals.clear();
    });
    _load();
  }

  /// [by] calendar days from the shown day: calendar arithmetic, so a DST
  /// change cannot skip or repeat a day.
  String _dayBy(int by) {
    final p = _dayLabel.split('-').map(int.parse).toList();
    return dayLabelOf(DateTime(p[0], p[1], p[2] + by));
  }

  Future<void> _pickDay() async {
    final res = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_dayLabel),
      firstDate: DateTime(2020),
      lastDate: DateTime.parse(_today),
    );
    if (res == null || !mounted) return;
    _setDay(dayLabelOf(res));
  }

  // ─────────────── what the picks are ───────────────

  List<_Pick> _picked() {
    final out = <_Pick>[];
    if (_day) {
      final start = localDayStartSec(_dayLabel)!, end = localDayEndSec(_dayLabel)!;
      for (final k in _intra) {
        final s = kExploreIntraday.singleWhere((s) => s.key == k);
        final read = k == 'calories'
            ? _cals.containsKey(_dayLabel)
            : _timelines.containsKey(_dayLabel);
        out.add(_Pick(
            k,
            s.label,
            s.unit,
            specOf(s.specKey).color,
            s.scale,
            read
                ? ExploreLine.intraday(
                    k,
                    exploreIntradayPoints(k,
                        timeline: _timelines[_dayLabel], calories: _cals[_dayLabel]),
                    dayStart: start,
                    dayEnd: end,
                    cadenceSec: s.cadenceSec)
                : null,
            exploreZUnavailable(k, const [], intraday: true),
            null));
      }
      return out;
    }
    final w = _window;
    for (final k in _daily) {
      final spec = specOf(k);
      final h = _hist[k];
      final values = h == null ? const <double>[] : [for (final p in h) p.v];
      final reason = h == null ? null : exploreZUnavailable(k, values);
      out.add(_Pick(
          k,
          spec.title,
          spec.unit,
          spec.color,
          1,
          h == null ? null : ExploreLine.daily(k, h, w),
          reason,
          h == null || reason != null ? null : exploreBaseline(values)));
    }
    return out;
  }

  // ─────────────── drawing ───────────────

  /// A pill: [dot] colour, text, and an optional trailing mark. Selected pills
  /// wear the metric's wash.
  Widget _pill(P p, Color color, String text,
          {required bool on, Widget? trailing}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x2),
        decoration: BoxDecoration(
            color: on ? p.wash(color) : p.card2, borderRadius: R.rPill),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.on(color),
                  border: Border.all(color: p.line, width: .5))),
          const SizedBox(width: S.x2),
          Flexible(
              child: Text(text,
                  style: F.cap.copyWith(
                      color: on ? p.on(color) : p.ink2,
                      fontWeight: FontWeight.w600))),
          if (trailing != null) ...[const SizedBox(width: S.x2), trailing],
        ]),
      );

  /// A picked metric: its chip (tap removes it) and its baseline toggle, with
  /// the reason under the toggle where it is off.
  Widget _chosenRow(BuildContext c, P p, AppLocalizations? l, _Pick m) {
    final on = _z.contains(m.key) && m.baseline != null;
    final canZ = m.line != null && m.zReason == null && m.baseline != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: S.x2, children: [
        Pressable(
          key: ValueKey('explore-chip:${m.key}'),
          onTap: () => _remove(m.key),
          semanticLabel: l?.exploreRemoveSemantics(m.label) ?? 'Remove ${m.label}',
          child: _pill(p, m.color, m.label,
              on: true,
              trailing: Icon(LucideIcons.x, size: 14, color: p.on(m.color))),
        ),
        Pressable(
          key: ValueKey('explore-z:${m.key}'),
          onTap: canZ
              ? () {
                  setState(() => on ? _z.remove(m.key) : _z.add(m.key));
                  Prefs.setString(kExploreZPref, _z.join(','));
                }
              : null,
          semanticLabel: l?.exploreBaselineSemantics(m.label) ??
              '${m.label} against your baseline',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x2),
            decoration: BoxDecoration(
                color: on ? p.wash(m.color) : (canZ ? null : p.card2),
                border: canZ && !on ? Border.all(color: p.line) : null,
                borderRadius: R.rPill),
            child: Text(l?.exploreBaselineToggle ?? 'Baseline',
                style: F.cap.copyWith(
                    color: on ? p.on(m.color) : (canZ ? p.ink2 : p.ink3),
                    fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
      if (m.zReason != null)
        Padding(
          padding: const EdgeInsets.only(left: S.x3, bottom: S.x1),
          child: Text(m.zReason!,
              key: ValueKey('explore-z-reason:${m.key}'),
              style: F.over.copyWith(color: p.ink3)),
        ),
    ]);
  }

  Widget _message(P p, String text, {Key? key}) => Surface(
        child: Text(text,
            key: key, style: F.cap.copyWith(color: p.ink3, height: 1.5)),
      );

  Widget _chart(BuildContext c, P p, AppLocalizations? l, List<_Pick> picked) {
    if (picked.isEmpty) {
      return Surface(
          child: NoData(
              message: l?.exploreHint ??
                  'Pick up to 4 metrics below. They share one time axis, each on its own scale.'));
    }
    if (_failed) {
      return Surface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l?.exploreFailedTitle ?? 'Could not read these metrics',
              style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          const SizedBox(height: S.x1),
          Text(
              l?.healthReadFailedBody ??
                  'The stored rows failed to load. Nothing was deleted.',
              style: F.cap.copyWith(color: p.ink3)),
          Pressable(
            key: const ValueKey('explore-retry'),
            onTap: _load,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x2),
              child: Text(l?.healthTryAgain ?? 'Try again',
                  style: F.cap.copyWith(
                      color: p.on(C.blue), fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      );
    }
    if (_loading) return const InlineLoading();

    final lines = <ExplorePlotLine>[
      for (final m in picked)
        if (m.hasData)
          ExplorePlotLine(
              m.key,
              m.color,
              m.line!.normalised(
                  z: !_day && _z.contains(m.key) ? m.baseline : null)),
    ];
    if (lines.isEmpty) {
      return _message(
          p,
          _day
              ? (l?.exploreNoDataDay ?? 'Nothing recorded for these on this day.')
              : (l?.exploreNoDataRange ?? 'Nothing recorded for these in this range.'),
          key: const ValueKey('explore-no-data'));
    }
    final zOn = lines.any((x) => !_day && _z.contains(x.key));

    // The axis: one real day, or the window of days.
    final w = _day ? null : _window;
    final int dayStart = _day ? localDayStartSec(_dayLabel)! : 0;
    final int dayEnd = _day ? localDayEndSec(_dayLabel)! : 0;
    final timeline = _timelines[_dayLabel];
    final bands = _day && timeline != null
        ? exploreBands(timeline, dayStart: dayStart, dayEnd: dayEnd)
        : const <ExploreBand>[];
    final asleep = bands.where((b) => b.kind != ExploreBandKind.workout).toList();
    final worked = bands.where((b) => b.kind == ExploreBandKind.workout).toList();
    final asleepLabel = l?.dayTimelineAsleep ?? 'Asleep';
    final workoutLabel = l?.dayTimelineWorkout ?? 'Workout';

    ChartKey shade(String label, Color color, List<ExploreBand> spans) =>
        ChartKey(label, p.on(color),
            (at) => spans.any((b) => at >= b.from && at < b.to) ? 'Yes' : 'No',
            latest: null, data: false);

    String day(String d) => ChartScrub.day(DateTime.parse(d));
    final xLabels = _day
        ? [
            l?.dayTimelineMidnight ?? 'Midnight',
            l?.dayTimelineNoon ?? 'Noon',
            l?.dayTimelineMidnight ?? 'Midnight',
          ]
        : w!.length <= 1
            ? [day(w.from)]
            : w.length == 2
                ? [day(w.from), day(w.to)]
                : [day(w.from), day(w.days[w.length ~/ 2]), day(w.to)];
    final title = _day
        ? (_dayLabel == _today
            ? (l?.exploreToday ?? 'Today')
            : day(_dayLabel))
        : (w!.length <= 1 ? day(w.from) : '${day(w.from)} – ${day(w.to)}');

    String timeAt(double at) {
      if (!_day) {
        return day(w!.days[(at * w.length).floor().clamp(0, w.length - 1)]);
      }
      // The wall clock at that instant, so a DST day reads its own hours.
      final sec = (at * (dayEnd - dayStart)).floor().clamp(0, dayEnd - dayStart - 1);
      final t = DateTime.fromMillisecondsSinceEpoch((dayStart + sec) * 1000);
      return ChartScrub.clock(t.hour * 60 + t.minute);
    }

    final notes = [
      for (final m in picked)
        if (!m.hasData)
          Padding(
            padding: const EdgeInsets.only(top: S.x1),
            child: Text(
                l?.exploreNoDataFor(m.label) ?? 'No data for ${m.label}',
                key: ValueKey('explore-empty:${m.key}'),
                style: F.over.copyWith(color: p.ink3)),
          ),
    ];

    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ChartFrame(
          title: title,
          unit: l?.exploreUnitNormalised ?? 'Normalised',
          height: 200,
          xLabels: xLabels,
          legend: [
            for (final m in picked) (m.label, p.on(m.color)),
            if (asleep.isNotEmpty) (asleepLabel, p.on(C.blue)),
            if (worked.isNotEmpty) (workoutLabel, p.on(C.orange)),
          ],
          child: ChartScrub(
            label: title,
            time: timeAt,
            keys: [
              for (final m in picked)
                ChartKey(m.label, p.on(m.color), (at) {
                  final v = m.line?.valueAt(at);
                  return v == null ? null : _say(m.unit, v * m.scale);
                },
                    latest: m.hasData ? m.line!.runs.last.last.at : null),
              if (asleep.isNotEmpty) shade(asleepLabel, C.blue, asleep),
              if (worked.isNotEmpty) shade(workoutLabel, C.orange, worked),
            ],
            // The boundary holds the painter and not the cursor, which the
            // scrub draws above it.
            child: RepaintBoundary(
              key: ExplorerView.plotKey,
              child: CustomPaint(
                size: Size.infinite,
                painter: ExplorePlotPainter(
                    lines: lines, bands: bands, p: p, midline: zOn),
              ),
            ),
          ),
        ),
        const SizedBox(height: S.x3),
        Text(
            zOn
                ? (l?.exploreNormalisedBaseline ??
                    'Normalised. Lines in baseline mode show distance from your usual level (the middle is usual, the top and bottom are 3 standard deviations away); the others span their own lowest to highest. Touch the chart for the real values.')
                : (l?.exploreNormalised ??
                    'Normalised: each line spans its own lowest to highest, so shapes compare and values do not. Touch the chart for the real values.'),
            key: const ValueKey('explore-normalised-note'),
            style: F.over.copyWith(color: p.ink3, height: 1.5)),
        ...notes,
      ]),
    );
  }

  Widget _picker(BuildContext c, P p, AppLocalizations? l) {
    Widget pick(String k, String label, Color color) {
      final on = _picks.contains(k);
      return Semantics(
        selected: on,
        child: Pressable(
          key: ValueKey('explore-pick:$k'),
          onTap: () => _toggle(k),
          child: _pill(p, color, label, on: on),
        ),
      );
    }

    if (_day) {
      return Wrap(spacing: S.x1, children: [
        for (final s in kExploreIntraday) pick(s.key, s.label, specOf(s.specKey).color),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final cat in kMetricCatalogue) ...[
        Padding(
          padding: const EdgeInsets.only(top: S.x3, bottom: S.x1),
          child: Text(metricCategoryTitle(l, cat.title),
              style: F.over.copyWith(color: p.ink3, fontWeight: FontWeight.w600)),
        ),
        Wrap(spacing: S.x1, children: [
          for (final r in cat.rows)
            if (_dailyKeys.contains(r.key))
              pick(r.key, specOf(r.key).title, specOf(r.key).color),
        ]),
      ],
    ]);
  }

  Widget _dayStepper(BuildContext c, P p, AppLocalizations? l) {
    Widget arrow(Key key, IconData icon, String label, VoidCallback? on) =>
        Opacity(
          opacity: on == null ? .35 : 1,
          child: Pressable(
            key: key,
            onTap: on,
            semanticLabel: label,
            child: Icon(icon, size: 20, color: p.ink),
          ),
        );
    final isToday = _dayLabel == _today;
    return Container(
      decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
      child: Row(children: [
        arrow(const ValueKey('explore-day-prev'), LucideIcons.chevronLeft,
            l?.metricDetailPreviousDay ?? 'Previous day', () => _setDay(_dayBy(-1))),
        Expanded(
          child: Pressable(
            onTap: _pickDay,
            child: Text(
                isToday
                    ? (l?.exploreToday ?? 'Today')
                    : ChartScrub.day(DateTime.parse(_dayLabel)),
                key: const ValueKey('explore-day-label'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          ),
        ),
        arrow(const ValueKey('explore-day-next'), LucideIcons.chevronRight,
            l?.metricDetailNextDay ?? 'Next day',
            isToday ? null : () => _setDay(_dayBy(1))),
      ]),
    );
  }

  static const _ranges = [
    ExploreRange.d7,
    ExploreRange.d30,
    ExploreRange.m6,
    ExploreRange.y1,
    ExploreRange.custom,
  ];

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final picked = _picked();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SubTabs(
        [l?.exploreScaleDaily ?? 'Daily', l?.exploreScaleDay ?? 'Day'],
        _day ? 1 : 0,
        (i) => _setScale(i == 1),
        color: C.blue,
        dense: true,
        itemKeys: const [
          ValueKey('explore-scale:daily'),
          ValueKey('explore-scale:day'),
        ],
      ),
      const SizedBox(height: S.x2),
      if (_day)
        _dayStepper(c, p, l)
      else
        SubTabs(
          [
            l?.exploreRange7 ?? '7 d',
            l?.exploreRange30 ?? '30 d',
            l?.exploreRange6m ?? '6 mo',
            l?.exploreRange1y ?? '1 y',
            l?.exploreRangeCustom ?? 'Custom',
          ],
          _ranges.indexOf(_range),
          (i) => _ranges[i] == ExploreRange.custom
              ? _pickCustom()
              : _setRange(_ranges[i]),
          color: C.blue,
          dense: true,
          itemKeys: [
            for (final r in _ranges) ValueKey('explore-range:${r.name}'),
          ],
        ),
      const SizedBox(height: S.x3),
      for (final m in picked) _chosenRow(c, p, l, m),
      if (_full)
        Padding(
          padding: const EdgeInsets.only(bottom: S.x2),
          child: Text(l?.exploreLimit ?? ExplorerView.limitMessage,
              style: F.cap.copyWith(color: p.on(C.orange))),
        ),
      const SizedBox(height: S.x2),
      _chart(c, p, l, picked),
      const SizedBox(height: S.x2),
      _picker(c, p, l),
    ]);
  }
}
