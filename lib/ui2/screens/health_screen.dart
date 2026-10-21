import '../../l10n/display_text.dart';
// HEALTH — observation-oriented. "What is happening, what is changing, is
// anything unusual?"
//
// Rows, not a wall of cards. A card is a claim that something deserves your
// attention; forty of them side by side is a claim about nothing. Overview is
// a list you scan, Trends is where change lives, Vitals is what the sensor
// measured, and Labs is what a laboratory measured — the only numbers in this
// app that are absolute.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../compute/findings.dart';
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/lab_catalogue.dart';
import '../../data/local_repository.dart';
import '../../import/journal_csv_import.dart' show isValidDayLabel;
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart';
import '../../models/payloads.dart' show todayHeadlineOf;
import '../../state/app_state.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/recalc_state.dart';
import '../profile/profile.dart' show ProfileAvatar;
import '../profile/wearable_numbers.dart'
    show WearableCells, kHealthWearableRows, wearableName;
import '../ui2.dart';
import 'advanced.dart';
import 'ecg.dart' show EcgEntryCard;
import 'findings_log.dart';
import 'home_screen.dart';
import 'investigate.dart';
import 'metric_catalogue.dart';
import 'metric_detail.dart';
import 'wellness_screen.dart';

/// A read this screen can live without. The wear block and the nap block are
/// ADDITIONS to the repository interface, so an implementation written before
/// them throws `UnimplementedError` from the base class — and neither is worth
/// taking every number on Health down for. An empty map is what both readers
/// already treat as "we never looked", which is the truth in that case.
///
/// Deliberately not applied to the metric reads above it: a failure there IS
/// the screen failing, and it must not be swallowed into a page of blanks.
/// Takes a CALLBACK, not a future: the base class's stub is `=> throw`, which
/// fires synchronously at the call site and never becomes a future to await.
Future<Map<String, dynamic>> _soft(
    Future<Map<String, dynamic>> Function() read) async {
  try {
    return await read();
  } catch (_) {
    return const {};
  }
}

class HealthData {
  final Map<String, dynamic> today, insights, profile;

  /// Read before the freshness refresh ran: today's figures are absent, not yet
  /// worked out. The screen asks for the refresh after painting and reads again.
  bool get refreshPending =>
      (today['status'] as Map?)?['refresh_pending'] == true;

  /// Timestamped. The x axis and the "how old is this number" line are both
  /// read off the points' own dates — `metric_series` has one row per DERIVED
  /// day, so the newest stored point can be a week old.
  final Map<String, List<ChartPoint>> charts;

  /// Derived days INSIDE THE LAST 30 CALENDAR DAYS — see [load].
  final int daysWithData;
  final Metric need;

  /// Non-null when the cross-day rollup was withheld — see [staleInsightsCard].
  final Map<String, dynamic>? insightsStale;

  /// THE MEASURED REASON THE OVERNIGHT ROWS ARE EMPTY, or null.
  ///
  /// Five of the rows below are read from the night, and when the band was on a
  /// charger through it they are all absent for one reason that is already on
  /// disk. `_wearBlock` has written the off-wrist stretches on every derive
  /// since it existed and nothing has ever read them. See [wearGapWhy] for what
  /// disqualifies a gap from being the answer.
  final String? nightGap;

  /// The newest derived day's naps — minutes, how many, and whether the day
  /// produced a nap answer at all. `nap_min` has been written on every judged
  /// day and read by nothing; the `naps` block behind it had no reader either.
  final int? napMin;
  final int? napCount;
  final String napDay;

  /// EVERYTHING THE APP HAS EVER NOTICED, newest first — see findings.dart.
  /// Recomputed from the rollup on every load rather than logged, so the
  /// history is there from the first run instead of starting empty today.
  final List<Finding> findings;

  /// The newest day bundle's personal `baselines` block — the usual range the
  /// trend cards draw for resting HR and HRV. Null when it could not be read.
  final Map<String, dynamic>? baselines;

  /// The newest day among the stored series and when those series were last
  /// computed (the reader's max `computed_at`) — what Trends says "As of"
  /// while a pass recalculates that day. Null when no reader gave a time.
  final String? chartsNewestDay;
  final DateTime? chartsComputedAt;

  /// The active wearable's cells for today, read with the overview so its card
  /// starts in its final place instead of landing after the first paint.
  /// Null: no active wearable, no cells, or the read failed (nothing drawn).
  final WearableDay? wearable;

  const HealthData({
    this.today = const {},
    this.insights = const {},
    this.profile = const {},
    this.charts = const {},
    this.daysWithData = 0,
    this.need = Metric.empty,
    this.insightsStale,
    this.nightGap,
    this.napMin,
    this.napCount,
    this.napDay = '',
    this.findings = const [],
    this.baselines,
    this.chartsNewestDay,
    this.chartsComputedAt,
    this.wearable,
  });

  /// The stored points for [key].
  List<ChartPoint> points(String key) => charts[key] ?? const [];

  /// [days] slots ending today, `null` where nothing was derived — the shape
  /// every painter in this app takes.
  List<double?> spark(String key, int days) => denseDays(points(key), days);

  Metric daily(String k) {
    final d = today['daily'];
    return metricOf(d is Map ? d[k] : null);
  }

  /// Every one of these is a real envelope from the pipeline, read in one
  /// place so Overview cannot disagree with itself. Trends is a different
  /// question — it plots what is STORED, and dates its hero when the newest
  /// stored point is not today's.
  Metric get hrv {
    final b = today['hrv'];
    final rmssd = b is Map ? b['rmssd'] as num? : null;
    if (rmssd == null || b is! Map) return Metric.empty;
    return Metric.parse(
        {...b.cast<String, dynamic>(), 'value': rmssd, 'unit': 'ms'});
  }

  Metric get sleepMin {
    final b = today['sleep'];
    return metricOf(b is Map ? b['duration_min'] : null);
  }

  Metric get stress => metricOf(today['stress']);
  Metric get resp => metricOf(today['resp']);

  static Future<WearableDay?> _wearableOrNull(LocalRepository repo) async {
    try {
      return await repo.wearableDay(todayLabel());
    } catch (_) {
      return null;
    }
  }

  static Future<HealthData> load(LocalRepository repo) async {
    // Started first and awaited last: first paint waits for the slowest read,
    // not the sum. A failed read is null (no card), never a failed load.
    final wearableRead = _wearableOrNull(repo);
    final today = await repo.getTodayStored();
    final cd = await repo.getInsights();
    final profile = await repo.getProfile();
    final days = await repo.availableDays();

    final charts = <String, List<ChartPoint>>{};
    DateTime? chartsAt;
    int? newestT;
    for (final k in const [
      'resting_hr',
      'hrv',
      'sleep',
      'stress',
      'resp_rate',
    ]) {
      final chart = await repo.getChart(k);
      charts[k] = pointsOf(chart);
      final at = computedAtOf(chart['computed_at']);
      if (at != null && (chartsAt == null || at.isAfter(chartsAt))) {
        chartsAt = at;
      }
      for (final pt in charts[k]!) {
        if (newestT == null || pt.t > newestT) newestT = pt.t;
      }
    }

    final coach = cd['sleep_coach'];
    final needEnv = coach is Map ? coach['need'] : null;
    final needSec = envValue(needEnv)?['need_sec'] as num?;

    // The last 30 CALENDAR days, not the newest 30 rows. `availableDays()` is
    // unbounded — every derived day since install — so `daysWithData` was the
    // whole history and `.clamp(0, 30)` painted "30 of 30" for anyone past
    // their first month, however many days they had actually missed.
    // `DateTime(y, m, d - 29)` and not `subtract(Duration(days: 29))`: the
    // duration form lands at 23:00 the day before across a DST boundary.
    final n = DateTime.now();
    final from = dayLabelOf(DateTime(n.year, n.month, n.day - 29));

    // The night the overnight rows describe, and the evening before it: a gap
    // that starts at 11:20 PM is filed under the previous calendar day's wear
    // block, and asking only about the night's own day would report it as
    // beginning at midnight. The window is 8 PM → 10 AM, which is wide enough
    // to hold any bedtime this app would score and narrow enough that an
    // afternoon on the charger is not offered as the reason a night is missing.
    final nightDay = heldOverNightOf(today) ?? todayLabel();
    final nd = DateTime.tryParse(nightDay);
    // `day - 1`, not a subtracted duration: calendar arithmetic, which lands
    // on the right date across a DST boundary where 24 h does not.
    final prevDay = nd == null
        ? nightDay
        : dayLabelOf(DateTime(nd.year, nd.month, nd.day - 1));
    final nightStart = localDayStartSec(prevDay);
    final dayStart = localDayStartSec(nightDay);
    final gap = (nightStart == null || dayStart == null)
        ? null
        : wearGapWhy(
            [await _soft(() => repo.getDayWear(prevDay)),
             await _soft(() => repo.getDayWear(nightDay))],
            fromSec: nightStart + 20 * 3600,
            toSec: dayStart + 10 * 3600,
          );

    // The two inputs the rollup's `recent[]` does not carry. Both come off
    // `metric_series`, which keeps one value per derived day for as long as the
    // day exists — the same store the trend charts draw, so the log cannot
    // disagree with the chart a tap away about which mornings were low.
    String labelAt(int t) =>
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(t * 1000));
    final ready = {
      for (final p in pointsOf(await repo.getChart('recovery')))
        labelAt(p.t): p.v,
    };
    final irregular = {
      for (final p in pointsOf(await repo.getChart('irregular_rhythm_flag')))
        if (p.v == 1) labelAt(p.t),
    };

    // The newest DERIVED day, not today: `getDayNaps` reads the exact day it is
    // asked for (an editable list must not be served off another day), and
    // today has usually not derived yet.
    final napDay = days.isEmpty ? todayLabel() : days.first;
    final naps = await _soft(() => repo.getDayNaps(napDay));
    final heart = await _soft(() => repo.getDayHeart(todayLabel()));
    final wearable = await wearableRead;

    return HealthData(
      wearable: wearable,
      today: today,
      insights: cd,
      profile: profile,
      charts: charts,
      daysWithData: days.where((d) => d.compareTo(from) >= 0).length,
      need: envMetric(needEnv, needSec == null ? null : needSec / 60,
          unit: 'min'),
      insightsStale: staleReasonOf(cd),
      nightGap: gap,
      napMin: (naps['nap_min'] as num?)?.round(),
      napCount: (naps['naps'] as List?)?.length,
      napDay: napDay,
      findings:
          findingsHistory(cd, readiness: ready, irregularDays: irregular),
      baselines: heart['baselines'] is Map
          ? (heart['baselines'] as Map).cast<String, dynamic>()
          : null,
      chartsComputedAt: chartsAt,
      chartsNewestDay: newestT == null
          ? null
          : dayLabelOf(DateTime.fromMillisecondsSinceEpoch(newestT * 1000)),
    );
  }
}

class VitalsData {
  /// The day these four blocks describe. When today has no derived record the
  /// loader falls back to the newest one there is, which is routinely days ago
  /// — and every row was captioned "Today" regardless.
  final String? day;

  /// Every derived day, newest first — what [DayNav] steers over.
  final List<String> days;

  final Map<String, dynamic> timeline, lungs, wear, hrv;
  const VitalsData({
    this.day,
    this.days = const [],
    this.timeline = const {},
    this.lungs = const {},
    this.wear = const {},
    this.hrv = const {},
  });

  static Future<VitalsData> load(LocalRepository repo, {String? want}) async {
    final today = await repo.getTodayStored();
    final days = await repo.availableDays();
    final day = pickDay(
        days, want, (today['status'] as Map?)?['today_day']?.toString());
    if (day == null) return VitalsData(days: days);
    final timeline = await repo.getDayTimeline(day);
    return VitalsData(
      // The repository stamps the bundle it actually served; prefer it over the
      // day we asked for, which is what its own comment says to do.
      day: timeline['date']?.toString() ?? day,
      days: days,
      timeline: timeline,
      lungs: await repo.getDayLungs(day),
      wear: await repo.getDayWear(day),
      hrv: await repo.getDayHrv(day),
    );
  }
}

/// Whole calendar days between a `'YYYY-MM-DD'` day id and today, or null when
/// there is no day. Zero or less means the day IS today.
int? _behind(String? dayId, [DateTime? now]) {
  final d = dayId == null ? null : DateTime.tryParse(dayId);
  return d == null ? null : calendarDaysBetween(d, now ?? DateTime.now());
}

class LabsData {
  final List<Map<String, dynamic>> results;
  final List<LabMarker> markers;
  const LabsData({this.results = const [], this.markers = const []});

  static Future<LabsData> load() async {
    final rows = await LocalDb.labResults();
    final defs = await LocalDb.labMarkerDefs();
    return LabsData(
      results: rows,
      markers: [
        ...kLabMarkers,
        for (final d in defs)
          if (!kLabMarkersByKey.containsKey(d['key']))
            LabMarker(
              key: d['key'].toString(),
              label: (d['label'] ?? d['key']).toString(),
              unit: (d['unit'] ?? '').toString(),
              category: LabCategory.blood,
              decimals: (d['decimals'] as num?)?.toInt() ?? 1,
              ranges: [
                if (d['ref_low'] is num && d['ref_high'] is num)
                  LabRefRange(
                      low: (d['ref_low'] as num).toDouble(),
                      high: (d['ref_high'] as num).toDouble()),
              ],
              custom: true,
            ),
      ],
    );
  }
}

// ═══════════════════ the catalogue ═══════════════════
//
// EXPLORE. The app persists 39 daily series and carries 25 written metric
// specs — title, unit, colour, icon, method, citation — and until this tab
// existed `MetricDetail` was constructed with SEVEN keys anywhere in the tree.
// Sixteen finished screens had no navigation edge at all. That is a routing
// gap, not a content gap, and this is the routing.
//
// It is an index, not a dashboard: nothing here computes, nothing here is a
// number about you. It says what this app can tell you, groups it the way a
// person would look for it, and says for each one how many days it actually
// has — which is the only honest answer to "is there anything in there".

// The list itself is `kMetricCatalogue` (metric_catalogue.dart), shared with
// the Data Explorer; what is local here is the localised one-line blurb.

/// [f]'s rows as this screen lists them: the shared catalogue's, minus any
/// import-only row no import has written history for (left out entirely
/// instead of being listed as not measured yet).
List<MetricCatalogueRow> _rowsOf(MetricCategory f, Map<String, int> counts) => [
      for (final r in f.rows)
        if (!r.importOnly || (counts[r.series] ?? 0) > 0) r,
    ];

String _rowBlurb(AppLocalizations? l, String key, String blurb) =>
    switch (key) {
      'readiness' => l?.healthBlurbReadiness ?? blurb,
      'stress' => l?.healthBlurbStress ?? blurb,
      'resting_hr' => l?.healthBlurbRestingHr ?? blurb,
      'hrv' => l?.healthBlurbHrv ?? blurb,
      'hrv_cv' => l?.healthBlurbHrvCv ?? blurb,
      'lf_hf' => l?.healthBlurbLfHf ?? blurb,
      'dip' => l?.healthBlurbDip ?? blurb,
      'hrr' => l?.healthBlurbHrr ?? blurb,
      'sleep' => l?.healthBlurbSleep ?? blurb,
      'efficiency' => l?.healthBlurbEfficiency ?? blurb,
      'deep' => l?.healthBlurbDeep ?? blurb,
      'rem' => l?.healthBlurbRem ?? blurb,
      'nap_min' => l?.healthBlurbNapMin ?? blurb,
      'resp_rate' => l?.healthBlurbRespRate ?? blurb,
      'brv' => l?.healthBlurbBrv ?? blurb,
      'spo2' => l?.healthBlurbSpo2 ?? blurb,
      'steps' => l?.healthBlurbSteps ?? blurb,
      'active_min' => l?.healthBlurbActiveMin ?? blurb,
      'calories' => l?.healthBlurbCalories ?? blurb,
      'strain' => l?.healthBlurbStrain ?? blurb,
      'trimp' => l?.healthBlurbTrimp ?? blurb,
      'skin_temp' => l?.healthBlurbSkinTemp ?? blurb,
      'wear' => l?.healthBlurbWear ?? blurb,
      _ => blurb,
    };

class ExploreData {
  /// Non-null `metric_series` rows per key — used ONLY as has / hasn't.
  ///
  /// The number itself is never rendered per row (see `_family`): as a value
  /// beside a metric it reads as a score, and it collapses "rare", "new key"
  /// and "substrate pruned" into one figure. What it is good for is the split —
  /// which rows have history, which are named in the empty card, and the
  /// "N of M measures" header, where the aggregate is honest because it is
  /// about the DEVICE and not about any one metric.
  final Map<String, int> counts;
  const ExploreData({this.counts = const {}});

  static Future<ExploreData> load() async => ExploreData(
        counts: await LocalDb.metricSeriesCounts([
          for (final f in kMetricCatalogue)
            for (final r in f.rows) r.series,
        ]),
      );
}

class HealthScreen extends StatefulWidget {
  final HealthData? data;
  final VitalsData? vitals;
  final LabsData? labs;
  final ExploreData? explore;

  /// Which sub-tab to open on. Goldens use it; production always starts at 0.
  final int tab;

  /// The wall clock, injected only by tests. The illness watch ages by the
  /// calendar, so a test of "a day later" needs to move it.
  final DateTime? now;

  const HealthScreen(
      {super.key,
      this.data,
      this.vitals,
      this.labs,
      this.explore,
      this.tab = 0,
      this.now});

  /// A deep link asking for one of the sub-tabs — -1 for the ordinary case.
  ///
  /// NOT A CONSTRUCTOR ARGUMENT, for the reason `WellnessScreen.tabRequest`
  /// gives: the shell keeps this screen alive in its IndexedStack, so a tap
  /// that lands on a Health already on screen builds nothing. The request
  /// reaches a live state through its listener and a fresh one (the shell
  /// re-keyed to switch domain) through `initState`. The shell clears it a
  /// frame later rather than the screen consuming it on read.
  static final ValueNotifier<int> tabRequest = ValueNotifier<int>(-1);

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> with RevisionReload {
  // EXPLORE SITS SECOND, not last. Five chips do not fit a 390 pt frame at 1×:
  // the fifth is clipped by the edge, and a half-visible chip is exactly the
  // discoverability failure this tab exists to fix. Labs takes the clip instead
  // — it is the manual-entry tab, the one a user goes looking for on purpose,
  // and the only one here that holds numbers this app did not measure.
  List<String> _tabsOf(AppLocalizations? l) => [
        l?.healthTabOverview ?? 'Overview',
        l?.healthTabExplore ?? 'Explore',
        l?.healthTabTrends ?? 'Trends',
        l?.healthTabVitals ?? 'Vitals',
        l?.healthTabLabs ?? 'Labs',
      ];
  late int _tab = widget.tab;

  HealthData? _d;
  VitalsData? _v;
  LabsData? _l;
  ExploreData? _e;
  bool _loading = true;

  /// The overview read threw: show the retry card, not an empty-data screen.
  bool _dFailed = false;

  @override
  void initState() {
    super.initState();
    final asked = HealthScreen.tabRequest.value;
    if (asked >= 0 && asked < _tabsOf(null).length) _tab = asked;
    HealthScreen.tabRequest.addListener(_onTabRequest);
    _d = widget.data;
    _v = widget.vitals;
    _l = widget.labs;
    _e = widget.explore;
    if (widget.data != null) {
      _loading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _enter(_tab));
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _enter(_tab);
    });
  }

  /// Health was already on screen when another screen asked for a sub-tab.
  void _onTabRequest() {
    final t = HealthScreen.tabRequest.value;
    if (t < 0 || t >= _tabsOf(null).length || t == _tab || !mounted) return;
    _select(t);
  }

  @override
  void dispose() {
    HealthScreen.tabRequest.removeListener(_onTabRequest);
    super.dispose();
  }

  /// Handed its data (golden, gallery) — nothing behind it to re-read.
  @override
  bool get revisionReloads => widget.data == null;

  /// A tab kept alive by the IndexedStack for the life of the process: it read
  /// the database once at launch, so an import or a derive that landed after
  /// that was invisible here until the app was relaunched. The already-loaded
  /// sub-tabs are re-read too — they cache on `!= null`, which is the same
  /// load-once bug one level down.
  ///
  /// EVERY SUB-TAB THAT HAS EVER READ, not every sub-tab that holds data. This
  /// gated on `!= null` and so skipped the one case that matters most — a
  /// sub-tab whose first read is still in flight when the revision lands, which
  /// is the ordinary state of the first load after an import. See [hasRead].
  @override
  void reload() {
    _refresh.reset();
    _refreshGaveUp = false;
    _load();
    if (hasRead(#vitals)) _loadVitals(force: true);
    if (hasRead(#labs)) {
      _l = null;
      _loadLabs();
    }
    if (hasRead(#explore)) {
      _e = null;
      _loadExplore();
    }
  }

  /// Starts the read the sub-tab at [i] needs, if it has not been read yet.
  /// Overview and Trends have none of their own: they are drawn from the main
  /// read.
  void _enter(int i) {
    if (!mounted) return;
    if (i == 1) _loadExplore();
    if (i == 3) _loadVitals();
    if (i == 4) _loadLabs();
  }

  final _refresh = TodayRefreshLatch();

  /// The refresh was asked and did not land (it failed, or the read after it
  /// is still pending): stop holding the building layout and say what is
  /// absent. Cleared by every reload, which asks again.
  bool _refreshGaveUp = false;

  /// Today's row is still being worked out. The overview list then holds dash
  /// rows and shows nothing under it, because everything under it moves when
  /// the figures land (absence cards become rows, or the reverse).
  bool _building(HealthData d) => d.refreshPending && !_refreshGaveUp;

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final t = beginRead(#day);
    try {
      final d = await HealthData.load(repo);
      if (stillNewest(#day, t)) {
        setState(() => (_d = d, _loading = false, _dFailed = false));
        _refresh.afterPaint(repo, d.refreshPending).then((landed) {
          if (!mounted) return;
          if (landed) {
            _load();
          } else if (d.refreshPending) {
            setState(() => _refreshGaveUp = true);
          }
        });
      }
    } catch (_) {
      if (stillNewest(#day, t)) {
        setState(() => (_loading = false, _dFailed = _d == null));
      }
    }
  }

  /// A tab's read THREW. `_v`/`_l` stay null on that path and null renders the
  /// spinner, so swallowing the error left the tab spinning silently for as
  /// long as the user stayed on it — there was no absent state on that path at
  /// all, whatever the old comment here said.
  bool _vFailed = false, _lFailed = false, _eFailed = false;

  /// The day the Vitals tab is showing, once the user has steered off the
  /// default. Null means "whatever the loader resolves", which is today.
  String? _vDay;

  Future<void> _loadVitals({bool force = false}) async {
    final repo = repoOf(context);
    if (repo == null || (_v != null && !force)) return;
    // Keyed per sub-tab: steering to another day starts a read that must beat
    // the one already in flight, and neither may cancel Labs or Explore.
    final t = beginRead(#vitals);
    try {
      final v = await VitalsData.load(repo, want: _vDay);
      if (stillNewest(#vitals, t)) setState(() => (_v = v, _vFailed = false));
    } catch (_) {
      if (stillNewest(#vitals, t)) setState(() => _vFailed = true);
    }
  }

  void _goVitalsDay(String day) {
    setState(() => _vDay = day);
    _loadVitals(force: true);
  }

  Future<void> _loadLabs() async {
    if (_l != null) return;
    final t = beginRead(#labs);
    try {
      final l = await LabsData.load();
      if (stillNewest(#labs, t)) setState(() => (_l = l, _lFailed = false));
    } catch (_) {
      if (stillNewest(#labs, t)) setState(() => _lFailed = true);
    }
  }

  /// The one card both failed reads render. Not "nothing logged yet" — a read
  /// that went wrong and an empty table are different states.
  StatusCard _readFailed(String what, VoidCallback retry) {
    final l = AppLocalizations.of(context);
    return StatusCard(
      l?.healthCouldNotRead(what) ?? 'Could not read your $what',
      l?.healthReadFailedBody ??
          'Couldn’t load your data. Nothing was deleted.',
      fix: l?.healthTryAgain ?? 'Try again',
      icon: LucideIcons.databaseZap,
      onFix: retry,
    );
  }

  Future<void> _loadExplore() async {
    if (_e != null) return;
    final t = beginRead(#explore);
    try {
      final e = await ExploreData.load();
      if (stillNewest(#explore, t)) setState(() => (_e = e, _eFailed = false));
    } catch (_) {
      if (stillNewest(#explore, t)) setState(() => _eFailed = true);
    }
  }

  void _select(int i) {
    setState(() => _tab = i);
    _enter(i);
  }

  @override
  Widget build(BuildContext c) {
    final d = _d ?? const HealthData();
    final l = AppLocalizations.of(c);
    return tabRootList(padding: kTabRootPad, children: [
      ScreenTitle(l?.healthTitle ?? 'Health',
          avatar: const ProfileAvatar(accent: C.domHealth)),
      const HeaderRows(todayId: null),
      SubTabs(_tabsOf(l), _tab, _select, color: C.blue),
      const SizedBox(height: S.x5),
      if (_loading && _d == null)
        InlineLoading(
            status: l?.loadingHealthOverview ?? 'Reading today and your trends')
      else
        switch (_tab) {
          0 || 2 when _dFailed && _d == null =>
            _readFailed(l?.healthWhatOverview ?? 'overview', () {
              setState(() => (_dFailed = false, _loading = true));
              _load();
            }),
          0 => _overview(c, d),
          1 => _explore(c),
          2 => _trends(c, d),
          3 => _vitals(c, d),
          _ => _labs(c),
        },
    ]);
  }

  /// "As of <time>" at the top of a sub-tab while the day its rows are read
  /// from is being recalculated. The rows stay; see [AsOfHold].
  Widget _asOf(HealthData d, DateTime? Function(RecalcState recalc) at,
          {String? day, DateTime? computedAt}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AsOfHold(
          shown: d,
          day: day,
          computedAt: computedAt,
          asOf: at,
          builder: (c, t) => Padding(
              padding: const EdgeInsets.only(bottom: S.x3),
              child: AsOfLabel(at: t)),
        ),
      ]);

  // ─────────────── OVERVIEW ───────────────
  Widget _overview(BuildContext c, HealthData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final rows = <Widget>[];
    final building = _building(d);

    // Five of these rows come off the overnight block, and `getToday` holds
    // that block over until today's settles. "Last night" / "Overnight" were
    // fixed literals, so a days-old night was stated as last night's — while
    // the Trends tab one tap away correctly said "as of 4 days ago" about the
    // same numbers. A row's detail opens on that same night.
    final night = heldOverNightOf(d.today);

    // ALL FIVE ROWS ARE READ FROM THE NIGHT, so all five take the same
    // measured gap. `overnight: false` is for a row that is not — a hole at
    // 2 AM says nothing about a daytime number, and offering it as the reason
    // would be the invented cause the whole absence layer refuses.
    // `rising` is the ONE value judgement a row makes, and it is per metric:
    // resting heart rate falling is good news, HRV rising is. A metric this
    // project makes no directional claim about takes [Rising.neither] and
    // draws its arrow in ink — the direction is stated, the verdict is not
    // invented.
    void row(Metric m, IconData icon, Color col, String name, String sub,
        String value, String unit, List<double?> series, String metricKey,
        {String? whyAbsent,
        bool overnight = true,
        Rising rising = Rising.neither}) {
      void open() => go(c, MetricDetail(metricKey, initialDay: night));
      if (m.isEmpty && building) {
        // Today's row is still being worked out, so this is not yet an absence
        // to explain: hold the landed row's box with a dash. A tall absence
        // card swapping for a short row moved everything under it when the
        // refresh landed. Never another day's number.
        rows.add(MetricRow(icon, col, name, '—',
            sub: sub, unit: '', series: series, onTap: open,
            subMaxLines: 1));
        return;
      }
      if (m.isEmpty) {
        // An absent metric keeps its row, in the rows surface, so the card is
        // the same card first launch and loaded: a dash for the value and the
        // reason (or what it needs) as the row's one-line status. It used to
        // be a StatusCard BELOW the surface, which made first launch a
        // different layout from the loaded one.
        final s = StatusCard.forMetric(
            l?.healthNoMetric(nounInSentence(l, name)) ??
                'No ${name.toLowerCase()}',
            m,
            // EVERY ABSENCE CARD STATES A REASON. A row with no specific one
            // got the card's own "no record of why" fallback, which says the
            // app does not know instead of naming the gap. The pipeline's own
            // note and a measured wear gap still outrank this.
            why: (whyAbsent == null || whyAbsent.isEmpty)
                ? (l?.healthWhyNotEnoughOvernight ??
                    'Not enough overnight data for this one')
                : whyAbsent,
            gap: overnight ? d.nightGap : null);
        rows.add(MetricRow(icon, col, name, '—',
            sub: s == null
                ? sub
                : (s.fix.isNotEmpty ? s.fix : s.why),
            unit: '',
            series: series,
            onTap: open,
            subMaxLines: 1));
        return;
      }
      rows.add(MetricRow(icon, col, name, value,
          sub: sub,
          unit: unit,
          series: series,
          rising: rising,
          onTap: open));
    }

    String ofNight(String s) =>
        night == null ? s : '$s · ${prettyDay(night, l)}';

    final sleepMin = d.sleepMin;

    final rhr = d.daily('resting_hr');
    row(rhr, LucideIcons.heart, C.red, l?.healthRowRestingHr ?? 'Resting heart rate',
        ofNight(l?.healthSubOvernight ?? 'Overnight'),
        rhr.value == null ? '' : '${rhr.value!.round()}', 'bpm',
        d.spark('resting_hr', 24), 'resting_hr',
        // Sleep duration and nocturnal RHR are gated separately, so "no night
        // was scored" is often the wrong reason and contradicts the Sleep row
        // sitting two lines down. Only the branch this screen can SEE is
        // stated — the other named a beat-quality gate it never read.
        // Nocturnal resting heart rate: lower is the direction every part of
        // this app already treats as better — it is what the illness CUSUM
        // watches for a RISE, and what readiness scores as `lowerIsBetter`.
        rising: Rising.bad,
        whyAbsent: sleepMin.isEmpty
            ? (l?.healthWhyReadFromSleep ??
                'Read from sleep, and no night was scored.')
            : '');

    final hrvMetric = d.hrv;
    row(hrvMetric, LucideIcons.activity, C.green, l?.healthRowHrv ?? 'HRV',
        ofNight(l?.healthSubRmssdAsleep ?? 'HRV, asleep'),
        hrvMetric.value == null ? '' : '${hrvMetric.value!.round()}', 'ms',
        d.spark('hrv', 24), 'hrv',
        rising: Rising.good,
        // Blaming signal quality unconditionally told a day-one user their
        // sensor produced dirty data on a night that never happened.
        whyAbsent: sleepMin.isEmpty
            ? (l?.healthWhyReadOnlyFromSleep ??
                'Read only from sleep, and no night was scored.')
            : '');

    row(
      sleepMin,
      LucideIcons.moon,
      C.blue,
      l?.healthRowSleep ?? 'Sleep',
      night == null
          ? (l?.healthSubLastNight ?? 'Last night')
          : prettyDay(night, l),
      hm(sleepMin.value),
      '',
      d.spark('sleep', 24),
      'sleep',
      // More sleep is the direction this app coaches towards — `sleepNeed`
      // exists to say you are short of it, never over it.
      rising: Rising.good,
        whyAbsent: l?.healthWhySleepNotLongEnough ??
            'No sleep period long enough to score was recorded.',
    );

    final stressBlock = d.today['stress'];
    final stressScore =
        stressBlock is Map ? (stressBlock['score'] as num?) : null;
    row(
        d.stress,
        LucideIcons.brain,
        C.purple,
        l?.healthRowStress ?? 'Stress',
        ofNight((stressBlock is Map ? stressBlock['level']?.toString() : null) ??
            (l?.healthRowStress ?? 'Stress')),
        stressScore == null ? '' : '${stressScore.round()}',
        // 0–100, and the scale has to be on the row. Wellness has always shown
        // it for the same number.
        '/100',
        d.spark('stress', 24),
        'stress',
        rising: Rising.bad,
        // Was 'No resting stretch long enough last night.' — one of several
        // gates stress abstains on, asserted for all of them.
        whyAbsent: sleepMin.isEmpty
            ? (l?.healthWhyReadFromNight ??
                'Read from the night, and no night was scored.')
            : '');

    final respMetric = d.resp;
    row(respMetric, LucideIcons.wind, C.teal, l?.healthRowRespRate ?? 'Respiratory rate',
        ofNight(l?.healthSubAsleep ?? 'Asleep'),
        respMetric.value == null ? '' : respMetric.value!.toStringAsFixed(1),
        'br/min',
        d.spark('resp_rate', 24), 'resp_rate',
        // DELIBERATELY UNJUDGED. Readiness scores a rise as a cost, but that
        // is a deviation from your own baseline, not a claim that breathing
        // slower is better health — nobody here would tell you a falling
        // respiratory rate is good news. Direction, no verdict.
        // THE ESTIMATOR'S OWN REASON when it left one, not a guess written
        // here. `respiration.rsa` records which gate it failed — too few beats,
        // artifact fraction over the gate, no stable HF peak, or a peak that
        // moved across spectral resolutions — and the repository now carries
        // that note through. This screen guessed "too noisy" for all four,
        // which was right about a quarter of the time.
        whyAbsent: respMetric.note?.isNotEmpty == true
            ? respMetric.note!
            : (sleepMin.isEmpty
                ? (l?.healthWhyReadOnlyFromSleep ??
                    'Read only from sleep, and no night was scored.')
                : (l?.healthWhyNoReadingLastNight ??
                    'No reading from last night.')));

    final illness = d.today['illness'];
    final state = illness is Map ? illness['state']?.toString() : null;
    // The CUSUM watch runs on NOCTURNAL RESTING HEART RATE ALONE. The copy here
    // used to name skin temperature as a second firing signal; the detector has
    // never been given a temperature series. `z` is its own standardised
    // deviation, so the sentence can say how far out the night sat.
    final illnessZ = illness is Map ? (illness['z'] as num?) : null;
    // The payload carries the night it is about. It is one entry per DERIVED
    // day, so after a gap "Last night" named a night the user did not wear the
    // band for.
    final illnessDay = illness is Map ? illness['date']?.toString() : null;
    final illnessBehind = _behind(illnessDay, widget.now);

    // Hoisted out of the tree so the section that now wraps it does not push
    // its copy two levels deeper. The card itself is untouched.
    // Same freshness rule as the push and Home: only today's or yesterday's
    // night, judged by the WALL CLOCK at build time — a payload loaded
    // yesterday and rebuilt today with no new sync has aged a day all the same.
    final illnessCard = state == null ||
            state == 'green' ||
            illnessDay == null ||
            !isRecentFindingDate(illnessDay, today: todayLabel(widget.now))
        ? null
        : Observation(
            state == 'red'
                ? (l?.healthIllnessRedTitle ??
                    'Recent nights add up to a raised resting heart rate')
                : (illnessBehind == null || illnessBehind <= 0
                    ? (l?.healthIllnessLastNightTitle ??
                        'Last night sat outside your normal range')
                      : (l?.healthIllnessDayTitle(prettyDay(illnessDay, l)) ??
                            '${prettyDay(illnessDay, l)} sat outside your normal range')),
            // The RUN is what is above baseline — the accumulator only clears
            // after two nights back under. The stored z is the LATEST night's
            // own deviation and can be negative while the run is still up,
            // which read as "tracking above your own baseline, 1.3 deviations
            // below it".
            illnessZ == null
                ? (l?.homeIllnessBodyNoZ ??
                    'Your resting heart rate has been above your usual over recent nights. A pattern, not a cause.')
                : (illnessZ >= 0
                    ? (l?.homeIllnessBodyAbove ??
                        'Recent nights put your resting heart rate above your usual. That night was above it too. A pattern, not a cause.')
                    : (l?.homeIllnessBodyBelow ??
                        'Recent nights together put your resting heart rate above your usual, though that night alone was below it. A pattern, not a cause.')),
            advice: l?.homeIllnessAdvice ??
                'Worth noting if it continues past a couple of days.',
          );

    final status = d.today['status'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The rows below come off the overnight row, whichever night it is.
      _asOf(
          d,
          (recalc) => asOfFor(
              shownDay: status is Map ? status['overnight_day']?.toString() : null,
              computedAt: computedAtOf(
                  status is Map ? status['overnight_computed_at'] : null),
              recalc: recalc),
          day: status is Map ? status['overnight_day']?.toString() : null,
          computedAt: computedAtOf(
              status is Map ? status['overnight_computed_at'] : null)),
      // WHOOP MG only: the ECG door appears once the paired band has
      // positively identified itself as an MG, and stays while it is away. It
      // depends on the paired device, not on whether data has arrived, so it is
      // in the same place first launch and loaded.
      if (c.caps.has(Feature.ecgEntry)) ...[
        const EcgEntryCard(key: ValueKey('card:ecg')),
        const SizedBox(height: S.x3),
      ],
      // Every metric has its row, present or not: the surface is the same
      // card with the same rows first launch and loaded.
      Surface(
        key: const ValueKey('card:metrics'),
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(color: p.line, height: 1),
            rows[i],
          ],
        ]),
      ),
      // The active wearable's heart rows, each with its class, source line
      // and reason. Nothing on a WHOOP-only install, nor when handed data.
      if (widget.data == null)
        WearableCells.seeded(kHealthWearableRows,
            key: const ValueKey('card:wearables'),
            initialDevice:
                d.wearable == null ? null : wearableName(d.wearable!.adapterId),
            initialCells: d.wearable?.cells ?? const {}),

      // OBSERVATIONS — the illness watch, wrapped, plus a door to the other
      // three detectors.
      //
      // The illness card is unchanged and stays first: it is the one finding
      // with copy specific enough to be worth a card of its own. What it gains
      // is a title over it and a way through to the anomaly, skin temperature
      // and resting-HR findings, which fired for months and reached no screen
      // at all. NOT a feed — see findings_log.dart. Nothing here is unread,
      // badged or dismissible, and it does not appear on Home.
      //
      // ALWAYS PRESENT. With nothing to say it is a one-line empty state in the
      // same card, not an absent section: first launch and loaded show the same
      // cards. It used to be skipped while today's figures were building, but
      // the rows above no longer change shape when they land, so there is
      // nothing left for it to move.
      const SizedBox(height: S.x4),
      Section(
        key: const ValueKey('card:observations'),
        l?.healthObservationsTitle ?? 'Observations',
        illnessCard ??
            // No live illness, but the log is not empty: the newest entry in
            // place and the rest one tap away. ONE row — a wall of findings
            // on the tab you land on is the feed this is not.
            (d.findings.isNotEmpty
                ? Surface(
                    onTap: () => go(c, FindingsLog(d.findings)),
                    child: FindingRow(d.findings.first),
                  )
                : Surface(
                    // Two lines tall in both states: the "not yet" sentence is
                    // longer than the quiet one and wraps on a phone, and the
                    // card must not change height when the watch first runs.
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          minHeight: 2 *
                              MediaQuery.textScalerOf(c)
                                  .scale(F.cap.fontSize!) *
                              F.cap.height!),
                      child: Row(children: [
                      Icon(LucideIcons.check, size: 16, color: p.ink3),
                      const SizedBox(width: S.x2),
                      Expanded(
                        child: Text(
                            // "Nothing stood out" is a claim that the watch
                            // looked. Until it has (no illness state, no
                            // derived day), say why there is nothing instead.
                            state != null || d.daysWithData > 0
                                ? (l?.findingsLogEmptyTitle ??
                                    'Nothing has stood out')
                                : (l?.healthObservationsNotYet ??
                                    'Starts after your first scored night'),
                            style: F.cap.copyWith(color: p.ink2)),
                      ),
                    ]),
                    ),
                  )),
        action: d.findings.isEmpty ? null : (l?.healthSeeAll ?? 'See all'),
        onAction:
            d.findings.isEmpty ? null : () => go(c, FindingsLog(d.findings)),
      ),

      // Naps moved to the Sleep tab, beside the night (the Naps door there).

      // What used to be the Wellness tab: the things you tell the app back.
      // ONE door now, not one per tab: in the contributed data breathing,
      // medication and cycle were each used by a handful of people, so they
      // share a row and the screen behind it keeps its own tabs. Always
      // present: a door, not data.
      Section(
        key: const ValueKey('card:mind'),
        l?.healthWellbeingTitle ?? 'Mind, habits and medication',
        detailLinkRow(
            c,
            LucideIcons.wind,
            l?.wellnessTabMind ?? 'Mind',
            // Cycle is a tab there only while cycle tracking is on.
            _cycleTrackingOn(c)
                ? (l?.healthWellbeingAllSubCycle ??
                    'Breathing, mood, the journal, habits, medication and cycle')
                : (l?.healthWellbeingAllSub ??
                    'Breathing, mood, the journal, habits and medication'),
            () => go(c, const WellnessScreen(initialTab: 0))),
      ),

      // Where today's recovery stands, in Home's words: the overnight rows
      // can be a held-over night while Home greys today's own number. Last,
      // below every card that is always there: it exists only once there is a
      // state to report, and above them it moved everything when it appeared.
      if (recoveryStateLine(todayHeadlineOf(d.today), l) case final note?) ...[
        const SizedBox(height: S.x3),
        Text('${l?.homeRingRecovery ?? 'Recovery'} · $note',
            key: const ValueKey('card:recovery-line'),
            style: F.cap.copyWith(color: p.ink3)),
      ],

      // THERE IS NO "BODY COMPOSITION" SECTION, AND THE NEXT PERSON SHOULD NOT
      // BUILD ONE. It used to print the onboarding weight scalar, and the ask
      // that replaced it was "is their weight normal for the intake and the
      // burn" — a bar like the against-your-usual ones. Three measurements
      // killed it, in order of how hard they kill it:
      //
      //   1. INTAKE. `food_entry` (nutrition_store.dart) does not exist in any
      //      real database on hand, and `journal_metric` exists in one with
      //      zero rows. So the honest fill rate for logged days is 0, and
      //      `DayLogState.partial` is the state a real log lands in most of the
      //      time by design — an occasion with no kcal is a VALID log and makes
      //      the day's energy a floor, not a total. Self-report is also under
      //      by 20-30% in free-living adults, which is the same size as the
      //      deficits anyone would be looking for. A balance computed off that
      //      is not a small error, it is the wrong sign about half the time.
      //
      //   2. BURN. `calories_total` is tier ESTIMATE, confidence 0.5: a Mifflin
      //      floor over the covered day plus a Keytel surplus over the wake
      //      span. On the real export it swings 2 454 - 4 545 kcal across a
      //      fortnight, and a barely-worn day still publishes a confident
      //      1 715 with 0 active. That daily swing alone is bigger than the
      //      imbalance a verdict would be claiming to see.
      //
      //   3. WEIGHT. It is one profile scalar here, not a series, so it can
      //      never be an against-your-usual bar. The trend that IS honest
      //      already exists somewhere better: `weightTrendEwma` drawn by the
      //      Journal weight screen, gaps left as gaps. Read the ceiling written
      //      above it in journal_fields.dart before reopening this — weekly
      //      scale noise is +/-1 kg and a 2 400 kcal weekly imbalance moves
      //      ~0.3 kg, so the residual is several times smaller than the noise
      //      it would have to be read out of. The 7 700 kcal/kg rule is a
      //      population approximation, never a personal constant.
      //
      // A bar drawn from any two of those three is arithmetic on a floor
      // wearing the costume of a measurement, and this screen exists to not do
      // that. If someone logs food completely for months AND weighs in
      // repeatedly, the thing to build is still not a verdict on the person.
    ]);
  }

  // ─────────────── TRENDS ───────────────
  Widget _trends(BuildContext c, HealthData d) {
    final l = AppLocalizations.of(c);

    /// [against] is the number the card compares the latest reading TO. Pass it
    /// and the delta is measured against that; leave it null and the delta is
    /// measured against the trailing mean of what is stored.
    ///
    /// It exists because the sleep card used to caption itself "vs your 7h 45m
    /// need" while still subtracting the 28-day AVERAGE — so the arrow and the
    /// figure under it read as sleep debt and were not. One of the two had to
    /// become true; the debt is the more useful of the pair.
    // No `Metric` argument: this card is drawn entirely from the stored
    // series, so taking the envelope only implied a cross-check that was
    // never made.
    Widget trend(String key, String label, String unit, Color col,
        {bool higherBetter = true, double? against, String? againstLabel}) {
      final pts = d.points(key);
      // Statistics off the STORED values; the painter gets the dense window.
      final s = valuesOf(pts);
      if (s.isEmpty) {
        // The same card, drawn empty: a dash for the value, the reason in the
        // window line and no line. A StatusCard here was a different card in
        // a different height, so the first stored day moved everything below.
        return TrendCard(
          label,
          '—',
          '',
          '',
          l?.healthZeroDaysStored ?? '0 days stored.',
          const [],
          col,
          good: null,
          reserveVerdict: true,
          key: ValueKey('card:trend-$key'),
        );
      }
      String fmt(double v) => key == 'sleep' ? hm(v) : metricValue(unit, v);
      // Your usual range, or nothing. Under two weeks of history the card
      // abstains: no band, no arrow, one short line saying when it arrives.
      final band = usualRangeFor(key, s, d.baselines);
      final prior = s.length - 1;
      final abstain = prior < kUsualMinDays
          ? usualNeedsDaysText(l, s.length)
          : (l?.healthNoBaseline ?? 'no usual range yet');
      final win = denseDays(pts, 30);
      final metricKey = key == 'sleep' ? 'sleep' : key;
      // The hero number is the newest STORED point, which after a sync gap is
      // not today's. Say when it is from rather than let the card imply now.
      final behind = daysBehind(pts.last.t) ?? 0;
      final asOf = behind <= 0
          ? ''
          : (l?.healthAsOf(axisDay(pts.last.t)) ?? ' · as of ${axisDay(pts.last.t)}');
      // [against] is the sleep need. It is a different question from "is this
      // usual for you" and stays as the small print: the debt is the more
      // useful of the two numbers on a sleep card.
      final toNeed = against == null ? null : s.last - against;
      final needLine = toNeed == null
          ? null
          : '${signed(toNeed, fmt(toNeed.abs()))} ${againstLabel ?? ''}'.trim();
      final small = needLine ?? (band == null ? abstain : '');
      final window = small.isEmpty && asOf.startsWith(' · ')
          ? asOf.substring(3)
          : '$small$asOf';
      final n = DateTime.now();
      return TrendCard(
        key: ValueKey('card:trend-$key'),
        reserveVerdict: true,
        label,
        fmt(s.last),
        key == 'sleep' ? '' : unit,
        band != null || toNeed == null ? '' : fmt(toNeed.abs()),
        band == null && toNeed != null ? '${againstLabel ?? ''}$asOf' : window,
        win,
        col,
        up: (toNeed ?? 0) >= 0,
        // Null with no comparison: an arrow and a good/bad hue about a
        // comparison the card has just said it cannot make.
        good: toNeed == null ? null : (toNeed >= 0) == higherBetter,
        band: band,
        latest: s.last,
        higherBetter: higherBetter,
        format: fmt,
        dayOf: (i) => prettyDay(
            dayLabelOf(DateTime(n.year, n.month, n.day - (win.length - 1 - i))),
            l),
        onTap: () => go(c, MetricDetail(metricKey)),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The trends are the stored series, and the sleep need is the cross-day
      // rollup: either being recalculated says when it was last computed.
      _asOf(
          d,
          (recalc) =>
              asOfFor(
                  shownDay: d.chartsNewestDay,
                  computedAt: d.chartsComputedAt,
                  recalc: recalc) ??
              asOfFor(
                  shownDay: null,
                  computedAt: computedAtOf(d.insights['computed_at']),
                  recalc: recalc,
                  dependsOnCrossDay: true)),
      trend('resting_hr', l?.healthRowRestingHr ?? 'Resting heart rate', 'bpm',
          C.red, higherBetter: false),
      const SizedBox(height: S.x3),
      trend('hrv', l?.healthRowHrv ?? 'HRV', 'ms', C.green),
      const SizedBox(height: S.x3),
      if (d.need.value == null)
        trend('sleep', l?.healthTimeAsleep ?? 'Time asleep', '', C.blue)
      else
        // `need` here is `crossday.sleep_coach.need` — the COMPUTED need. It is
        // never `sleep.need_min`, which is a hardcoded 480.
        trend('sleep', l?.healthTimeAsleep ?? 'Time asleep', '', C.blue,
            against: d.need.value!.toDouble(),
            againstLabel: l?.healthVsNeed(hm(d.need.value)) ??
                'vs your ${hm(d.need.value)} need'),

      // Body clock (natural bedtime, weekend shift, consistency) moved to
      // the Sleep tab, beside the night it is about.

      Section(
        key: const ValueKey('card:consistency'),
        l?.healthConsistencyTitle ?? 'Consistency',
        Surface(
          child: Consistency(
            // Already windowed to the last 30 calendar days by `HealthData.load`
            // — the clamp is a floor for a bad count, not the window.
            d.daysWithData.clamp(0, 30),
            30,
            l?.healthDaysWithRecord ??
                'Scored days, last 30',
              C.domHealth,
            ),
          ),
        ),
      ],
    );
  }


  // ─────────────── VITALS ───────────────
  Widget _vitals(BuildContext c, HealthData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final v = _v;
    if (v == null) {
      return _vFailed
          ? _readFailed(l?.healthWhatVitals ?? 'vitals', () {
              setState(() => _vFailed = false);
              _loadVitals();
            })
          : Padding(
              padding: const EdgeInsets.only(top: S.x3),
              child: InlineLoading(
                  status: l?.loadingVitals ?? 'Reading your vitals'));
    }

    // WHICH DAY this tab is showing. Every row here used to say "Today" for a
    // day the loader had fallen back to, which after a sync gap is days ago.
    final behind = _behind(v.day);
    final isToday = behind == null || behind <= 0;
    final dayWord = isToday ? (l?.healthToday ?? 'Today') : prettyDay(v.day, l);
    // Skin temperature comes off the latest OVERNIGHT bundle, not the day the
    // other three rows describe, so it gets its own night when they differ.
    final tempNight = heldOverNightOf(d.today);

    final highs = v.timeline['highs'];
    num? high(String k) {
      final e = highs is Map ? highs[k] : null;
      return e is Map ? e['v'] as num? : null;
    }

    final lo = high('low_hr'), hi = high('peak_hr');
    final respBlock = v.lungs['resp'];
    final resp = respBlock is Map ? respBlock['value'] as num? : null;
    final worn = v.wear['worn_min'] as num?;
    final coverage = v.wear['coverage_pct'] as num?;
    final skinTemp = metricOf(d.today['skin_temp']);
    // WHOOP 5 reads in real °C, so its row says degrees, not SDs.
    final tempDevC = ((d.today['skin_temp'] as Map?)?['dev_c'] as num?)
        ?.toDouble();
    final rmssd = v.hrv['rmssd'] as num?;
    // MetricRow, not a private copy of it. The one this screen used to grow
    // stacked the value over its qualifier in a shrink-wrapped column, so
    // 'bpm today' and 'SD from your own nights' set each row's width and no
    // two values landed on the same x. The qualifier is not a unit and does
    // not belong beside the number: it goes under the name, where every other
    // list in the app already puts it.
    // Every row is always there: an absent one keeps its slot with a dash and
    // the one-line reason, so the card is the same card with or without a
    // recorded day (it used to be replaced by a StatusCard when all four were
    // absent, and grew a row at a time as each landed).
    final none = l?.healthNoBandRecordings ?? 'No band recordings reached this day.';
    final rows = <Widget>[
      if (lo != null && hi != null)
        MetricRow(LucideIcons.heart, C.red, l?.healthRowHeartRate ?? 'Heart rate',
            '${lo.round()} – ${hi.round()}',
            sub: dayWord, unit: 'bpm', subMaxLines: 1)
      else
        MetricRow(LucideIcons.heart, C.red, l?.healthRowHeartRate ?? 'Heart rate',
            '—', sub: none, unit: '', subMaxLines: 1),
      if (resp != null)
        MetricRow(LucideIcons.wind, C.teal, l?.healthRowRespRate ?? 'Respiratory rate',
            resp.toStringAsFixed(1),
            sub: l?.healthSubAsleep ?? 'Asleep', unit: 'br/min', subMaxLines: 1)
      else
        MetricRow(LucideIcons.wind, C.teal, l?.healthRowRespRate ?? 'Respiratory rate',
            '—', sub: none, unit: '', subMaxLines: 1),
      if (skinTemp.value != null || tempDevC != null)
        // NAME THE QUANTITY. This is `skin_temp_z` — standard deviations from
        // the user's own baseline. It printed signed and unitless beside a
        // heart rate in bpm, so it read as °C; and the sleep scrub's
        // "temperature" is a THIRD quantity again (raw ADC minus that day's
        // median), which is why neither may go unlabelled.
        MetricRow(
          LucideIcons.thermometer,
          C.orange,
          l?.healthRowSkinTemp ?? 'Skin temperature',
          tempDevC != null
              ? '${tempDevC >= 0 ? '+' : '−'}${tempDevC.abs().toStringAsFixed(1)}'
              : '${skinTemp.value! >= 0 ? '+' : '−'}'
                  '${skinTemp.value!.abs().toStringAsFixed(2)}',
          sub: [
            if ((d.today['skin_temp'] as Map?)?['provisional'] == true)
              l?.wearableProvisional ?? 'Provisional',
            tempNight == null
                ? (l?.healthVsOwnNights ?? 'vs your own nights')
                : (l?.healthVsOwnNightsOn(prettyDay(tempNight, l)) ??
                      'vs your own nights · ${prettyDay(tempNight, l)}'),
          ].join(' · '),
          unit: tempDevC != null ? '°C' : 'SD',
          subMaxLines: 1,
          // Both this row and the wear row below it carry a FULL, written,
          // cited spec in `metric_detail.dart` that no tap in the app opened.
          // The number was on screen and its method was unreachable.
          onTap: () => go(c, const MetricDetail('skin_temp')),
        )
      else
        MetricRow(LucideIcons.thermometer, C.orange,
            l?.healthRowSkinTemp ?? 'Skin temperature', '—',
            sub: none, unit: '', subMaxLines: 1,
            onTap: () => go(c, const MetricDetail('skin_temp'))),
      if (worn != null)
        MetricRow(LucideIcons.watch, C.green, l?.healthRowWearTime ?? 'Wear time',
            hm(worn),
            // `83.33333333333333% of the day` shipped. It is a percentage.
            sub: coverage == null
                ? dayWord
                : (l?.healthCoverageOf(coverage.round(),
                        isToday ? (l.healthTheDay) : dayWord) ??
                    '${coverage.round()}% of '
                        '${isToday ? 'the day' : dayWord}'),
            subMaxLines: 1,
            onTap: () => go(c, const MetricDetail('wear')))
      else
        MetricRow(LucideIcons.watch, C.green, l?.healthRowWearTime ?? 'Wear time',
            '—', sub: none, unit: '', subMaxLines: 1,
            onTap: () => go(c, const MetricDetail('wear'))),
    ];

    // The day's rows come off that day's derived row. Its compute time is only
    // known for the day today's row was derived from; any other day gets no
    // label rather than another day's time.
    final status = d.today['status'];
    final activityDay =
        status is Map ? status['activity_day']?.toString() : null;
    final dayAt = activityDay != null && activityDay == v.day
        ? computedAtOf(status is Map ? status['activity_computed_at'] : null)
        : null;
    final sync = syncOf(c);
    final nothingMeasured =
        rows.every((r) => r is MetricRow && r.value == '—');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _asOf(
          d,
          (recalc) =>
              asOfFor(shownDay: v.day, computedAt: dayAt, recalc: recalc),
          day: v.day,
          computedAt: dayAt),
      // Always drawn (dimmed with fewer than two days) so the rows below do
      // not move when the second day arrives.
      DayNav(
          key: const ValueKey('card:daynav'),
          alwaysShow: true,
          day: _vDay ?? v.day,
          days: v.days,
          onDay: _goVitalsDay),
      const SizedBox(height: S.x3),
      Surface(
        key: const ValueKey('card:vitals-rows'),
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(color: p.line, height: 1),
            rows[i],
          ],
        ]),
      ),

      // Nothing measured for this day: the way out is a sync. A fixed-height
      // slot, so offering it (or not, with no AppState) moves nothing.
      SizedBox(
        key: const ValueKey('card:vitals-sync'),
        height: 44,
        child: Align(
          alignment: Alignment.centerLeft,
          child: nothingMeasured && sync != null
              ? TextButton(
                  onPressed: sync,
                  child: Text(l?.healthSyncTheBand ?? 'Sync the band'))
              : null,
        ),
      ),

      // No skin-temperature caveat card here. The row's own unit already says
      // the reading is relative, and `metric_detail` carries the method for
      // anyone who taps through — a whole card restating it on the way past is
      // the kind of explanation this screen was asked to stop giving.

      // No "Sleep architecture" deep dive either: Sleep is a tab of its own,
      // and a second door into it from Vitals is a duplicate entry point, not
      // a feature.
      // Always there: an absent HRV is a dash, and the preview says so.
      Section(
          key: const ValueKey('card:deep-dive'),
          l?.healthDeepDivesTitle ?? 'Deep dives',
          DeepDiveCard(
              l?.healthHeartRateVariability ?? 'Heart rate variability',
              rmssd == null ? '—' : '${rmssd.round()}',
              rmssd == null ? '' : 'ms',
              rmssd == null
                  ? none
                  : (l?.healthTimeFrequencyNonLinear ?? 'Detailed HRV measures'),
              C.green,
              preview: _hrvPreview(c, d),
              onTap: () => go(c, const Investigate('hrv'))),
        ),

      // The research charts, all behind one door.
      const SizedBox(height: S.x3),
      KeyedSubtree(
        key: const ValueKey('card:advanced'),
        child: detailLinkRow(
          c,
          LucideIcons.flaskConical,
          l?.healthAdvancedLinkTitle ?? 'Advanced charts',
          l?.healthAdvancedLinkSub ??
              'Beat-to-beat detail and sleep timing',
          () => go(c, const AdvancedScreen())),
      ),
    ]);
  }

  /// The HRV preview inside the deep-dive card. Framed like every other chart:
  /// what it is, what it is measured in, what the heights mean, and how far
  /// back it reaches — all read off the series actually drawn.
  Widget _hrvPreview(BuildContext c, HealthData d) {
    const days = 30;
    final pts = d.points('hrv');
    // The window is thirty CALENDAR nights, dense, ending last night. The list
    // used to be the newest thirty STORED nights, which after a sync gap could
    // span two months while both axis labels — counted off the array — claimed
    // it spanned thirty. Nights with no record are holes, not joined across.
    final win = denseDays(pts, days);
    final have = [for (final v in win) ?v];
    final axis = AxisSpec.of(have, ticks: 2);
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return ChartFrame(
      title: l?.healthRmssdOfLastNights(have.length, days) ??
          'HRV, ${have.length} of the last $days nights',
      unit: 'ms',
      height: 48,
      yAxis: axis,
      xLabels: have.length < 2
          ? const []
          : [
              l?.healthNightsAgo(days - 1) ?? '${days - 1} nights ago',
              l?.healthSubLastNight ?? 'Last night',
            ],
      empty: have.length < 2
          ? NoData(
              message: l?.healthOneNightNotTrend ?? 'One night is not a trend yet')
          : null,
      series: win,
      child: ChartScrub(
        label: l?.healthHeartRateVariability ?? 'Heart rate variability',
        // Thirty calendar nights ending last night; a night with no record is
        // a hole.
        gaps: hasChartGaps([win], trailing: true),
        time: (at) =>
            ChartScrub.dayBack(win.length - 1 - ChartScrub.slotAt(win.length, at)),
        keys: [
          ChartKey.slots('RMSSD (ms)', p.on(C.green), win,
              (i, v) => '${v.round()} ms'),
        ],
        child: CustomPaint(
          size: Size.infinite,
          painter: LineChart(win, p.on(C.green), t: animate(c, 1), axis: axis),
        ),
      ),
    );
  }

  // ─────────────── EXPLORE ───────────────
  Widget _explore(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final e = _e;
    if (e == null) {
      return _eFailed
          ? _readFailed(l?.healthMeasuresUnit ?? 'measures', () {
              setState(() => _eFailed = false);
              _loadExplore();
            })
          : Padding(
              padding: const EdgeInsets.only(top: S.x3),
              child: InlineLoading(
                  status: l?.loadingMeasures ?? 'Reading your measures'));
    }

    var have = 0, total = 0;
    for (final f in kMetricCatalogue) {
      for (final r in _rowsOf(f, e.counts)) {
        total++;
        if ((e.counts[r.series] ?? 0) > 0) have++;
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Surface(
        key: const ValueKey('card:explore-summary'),
        child: Consistency(have, total,
            l?.healthMeasuresWithHistory ??
                'Metrics with history',
            C.domHealth,
            unit: 'measures',
          ),
        ),
        const SizedBox(height: S.x3),
      for (final f in kMetricCatalogue) _family(c, p, f, e.counts),
    ]);
  }

  Widget _family(
      BuildContext c, P p, MetricCategory f, Map<String, int> counts) {
    final l = AppLocalizations.of(c);
    final rows = _rowsOf(f, counts);

    // One card per family with EVERY row in catalogue order, first launch and
    // loaded alike: a metric with no history keeps its slot, dimmed. It used to sort the measured rows above
    // and name the rest in a StatusCard below, so the card was a different
    // height the moment the first day derived.
    return Section(
      key: ValueKey('card:family-${f.title}'),
      metricCategoryTitle(l, f.title),
      Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(color: p.line, height: 1),
              Builder(
                builder: (c) {
                  final r = rows[i];
                  final s = specOf(r.key);
                  // NO NUMBER IN THE VALUE SLOT, on purpose.
                  //
                  // This used to print the day count. It read as a score: nine
                  // days of breathing rate beside seventeen of resting HR looks
                  // like the app is worse at breathing, when what it means is
                  // that the estimator abstains more. It also collapsed three
                  // causes into one number: genuinely rare, key shipped last
                  // week, substrate pruned. Has / hasn't is all an index owes
                  // you, and a dash is the "hasn't".
                  final row = MetricRow(
                    s.icon,
                    s.color,
                    uiText(c, s.title),
                    '',
                    sub: _rowBlurb(l, r.key, r.blurb),
                    onTap: () => go(c, MetricDetail(r.key)),
                  );
                  if ((counts[r.series] ?? 0) > 0) return row;
                  // Dimmed, not reworded: any text in the row (a dash in the
                  // value slot, a different sub) changes how the blurb wraps,
                  // and the card must be the same height with or without
                  // history.
                  return Semantics(
                    hint: l?.healthNotMeasuredYet ?? 'Not measured yet',
                    child: Opacity(opacity: .5, child: row),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─────────────── LABS ───────────────
  Widget _labs(BuildContext c) {
    final p = P.of(c);
    final loc = AppLocalizations.of(c);
    final l = _l;
    if (l == null) {
      return _lFailed
          ? _readFailed(loc?.healthWhatLabResults ?? 'lab results', () {
              setState(() => _lFailed = false);
              _loadLabs();
            })
          : InlineLoading(
              status: loc?.loadingLabs ?? 'Reading your lab results');
    }

    final sex = (_d?.profile['sex'])?.toString();
    // Newest draw per marker. `labResults` is already taken_on DESC.
    final latest = <String, Map<String, dynamic>>{};
    for (final r in l.results) {
      latest.putIfAbsent(r['marker'].toString(), () => r);
    }
    final byKey = {for (final m in l.markers) m.key: m};
    // A stored result with no number is not a measurement — it is dropped, the
    // way MonoTable drops an empty row. A bare em-dash in a lab column reads as
    // "the assay failed", which is a claim about your blood.
    final rows = latest.values.where((r) => r['value'] is num).toList()
      ..sort((a, b) => (byKey[a['marker']]?.label ?? '')
          .compareTo(byKey[b['marker']]?.label ?? ''));
    final lastDraw = l.results.isEmpty ? null : l.results.first['taken_on'];
    // Markers the user named themselves — the only ones whose DEFINITION is
    // theirs to remove. A catalogue marker is the app's and stays.
    final mine = l.markers.where((m) => m.custom).toList();
    final counts = <String, int>{};
    for (final r in l.results) {
      final k = r['marker'].toString();
      counts[k] = (counts[k] ?? 0) + 1;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The entry point leads: the results below are a list that grows, and
      // nothing that must stay put may sit under it.
      KeyedSubtree(
        key: const ValueKey('card:add'),
        child: BigButton(loc?.healthAddAResult ?? 'Add a result',
            icon: LucideIcons.plus,
            color: C.blue,
            soft: true,
            onTap: () => _addLab(c, l)),
      ),
      const SizedBox(height: S.x4),
      // List-shaped: the section is as tall as its entries, so it is keyed
      // 'list:results', not 'card:*' (the first-launch test holds the cards to
      // a fixed size; this one's place is fixed, its body is not).
      Column(
        key: const ValueKey('list:results'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
      if (rows.isEmpty)
        StatusCard(
          loc?.healthNoLabResults ?? 'No lab results',
          loc?.healthNoLabResultsBody ??
              'Nothing logged. Anything you add here stays on this device, '
                  'and anything you remove is gone from it.',
          icon: LucideIcons.testTube,
        )
      else ...[
        Surface(
          pad: const EdgeInsets.symmetric(horizontal: S.x4),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(color: p.line, height: 1),
              _lab(p, byKey[rows[i]['marker'].toString()], rows[i], sex,
                  () => _removeResult(byKey[rows[i]['marker'].toString()],
                      rows[i], l)),
            ],
          ]),
        ),
        const SizedBox(height: S.x3),
        Text(
            loc?.healthLastPanel(lastDraw?.toString() ?? '') ??
                'Last panel ${lastDraw ?? ''} · logged by hand',
            style: F.over.copyWith(color: p.ink3)),
      ],
        ],
      ),
      if (mine.isNotEmpty) _myMarkers(p, mine, counts),
      const SizedBox(height: S.x4),
      // The app never prints "abnormal" anywhere, so it does not need to say
      // it does not. What the user cannot know without being told is that the
      // range shown here is not the range their own lab used.
      Text(loc?.healthRangesDifferByLab ??
              'Ranges differ by lab. Use the one on your report.',
          style: F.over.copyWith(color: p.ink3, height: 1.6)),
    ]);
  }

  String _markerName(LabMarker? m, String fallback) => m == null
      ? fallback
      : m.custom
      ? m.label
      : uiText(context, m.label);

  Widget _lab(P p, LabMarker? m, Map<String, dynamic> r, String? sex,
      VoidCallback onRemove) {
    final l = AppLocalizations.of(context);
    final v = (r['value'] as num?)?.toDouble();
    final unit = (r['unit'] ?? m?.unit ?? '').toString();
    final range = m?.rangeFor(sex);
    final inRange = v == null || m == null ? null : m.inRange(v, sex: sex);

    // The whole row is the control, with the bin as its affordance — the same
    // shape a logged meal takes, and it costs no width, which at 3x text is
    // the difference between a row that fits and one that overflows.
    return Pressable(
      onTap: onRemove,
      semanticLabel:
          l?.healthRemoveMarkerFrom(
            _markerName(m, r['marker'].toString()),
            r['taken_on'].toString(),
          ) ??
          'Remove ${m?.label ?? r['marker']} from ${r['taken_on']}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              // No interval means NO OPINION — a grey dot, never a green one.
              color: inRange == null
                  ? p.ink3
                  : (inRange ? p.on(C.green) : p.on(C.orange)),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _markerName(m, r['marker'].toString()),
                    style: F.body.copyWith(color: p.ink),
                  ),
              Text(
                  range == null
                      ? (l?.healthNoReferenceInterval(r['taken_on'].toString()) ??
                          'No reference interval · ${r['taken_on']}')
                      : (l?.healthTypicalRange(_num(range.low), _num(range.high),
                              r['taken_on'].toString()) ??
                          'Typical ${_num(range.low)}–${_num(range.high)} · '
                              '${r['taken_on']}'),
                  style: F.over.copyWith(color: p.ink3)),
            ]),
          ),
          const SizedBox(width: S.x2),
          Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(v == null ? '' : (m?.format(v) ?? v.toString()),
                    style: F.n17.copyWith(
                        color: inRange == false ? p.on(C.orange) : p.ink)),
                const SizedBox(width: 3),
                Text(unit, style: F.over.copyWith(color: p.ink3)),
              ]),
          // This is the user's own blood work in an app that keeps it on their
          // phone; being able to take it back out is the premise, not a setting.
          const SizedBox(width: S.x2),
          Icon(LucideIcons.trash2, size: 16, color: p.ink3),
        ]),
      ),
    );
  }

  /// One reading of one marker on one date. Named in full before it goes:
  /// there is no undo here, and a generic "are you sure?" over a column of
  /// blood results is how the wrong one is lost.
  Future<void> _removeResult(
      LabMarker? m, Map<String, dynamic> r, LabsData l) async {
    final loc = AppLocalizations.of(context);
    final marker = r['marker'].toString();
    final takenOn = r['taken_on'].toString();
    final label = _markerName(m, marker);
    final v = (r['value'] as num).toDouble();
    final unit = (r['unit'] ?? m?.unit ?? '').toString();
    // The row on screen is the NEWEST draw of its marker, so an earlier one
    // takes its place rather than the marker disappearing — which without
    // being told reads as the delete having failed.
    final older = l.results.firstWhere(
      (o) => o['marker'] == marker && o['taken_on'] != takenOn,
      orElse: () => const <String, dynamic>{},
    )['taken_on'];

    final ok = await confirmRemove(
      context,
      title: loc?.healthRemoveLabelFrom(label, takenOn) ??
          'Remove $label from $takenOn?',
      body: (loc?.healthRemoveLabBody(m?.format(v) ?? _num(v), unit) ??
              'The ${m?.format(v) ?? _num(v)} $unit you logged for that draw. '
                  'It leaves this device and there is no undo.') +
          (older == null
              ? ''
              : (loc?.healthRemoveLabOlderNote(older) ??
                  ' Your $older draw stays, and shows here instead.')),
    );
    if (!ok || !mounted) return;
    await LocalDb.deleteLabResult(marker, takenOn);
    _l = null;
    await _loadLabs();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(older == null
          ? (loc?.healthRemovedNoneLeft(label, takenOn) ??
              'Removed $label from $takenOn. No $label results left.')
          : (loc?.healthRemovedShowingOlder(label, takenOn, older) ??
              'Removed $label from $takenOn. Showing your $older draw now.')),
    ));
  }

  /// Markers the user named. Only the DEFINITION is theirs to remove here —
  /// see [_removeMarker] for why one holding results is refused.
  Widget _myMarkers(P p, List<LabMarker> mine, Map<String, int> counts) {
    final l = AppLocalizations.of(context);
    return Section(
      key: const ValueKey('card:my-markers'),
      l?.healthMarkersYouNamed ?? 'Markers you named',
      Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          for (var i = 0; i < mine.length; i++) ...[
            if (i > 0) Divider(color: p.line, height: 1),
            Pressable(
              semanticLabel: l?.healthRemoveTheMarker(mine[i].label) ??
                  'Remove the ${mine[i].label} marker',
              onTap: () => _removeMarker(mine[i], counts[mine[i].key] ?? 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x3),
                child: Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(mine[i].label,
                              style: F.body.copyWith(color: p.ink)),
                          Text(
                              (counts[mine[i].key] ?? 0) == 0
                                  ? (l?.healthNothingLoggedUnderIt ??
                                      'Nothing logged under it')
                                  : (l?.healthResultsCount(
                                          counts[mine[i].key] ?? 0,
                                          mine[i].unit) ??
                                      '${counts[mine[i].key]} '
                                          '${(counts[mine[i].key] ?? 0) == 1 ? 'result' : 'results'} · '
                                          '${mine[i].unit}'),
                              style: F.over.copyWith(color: p.ink3)),
                        ]),
                  ),
                  const SizedBox(width: S.x2),
                  Icon(LucideIcons.trash2, size: 16, color: p.ink3),
                ]),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  /// Removing a marker DEFINITION, which is not the same act as removing its
  /// readings — `deleteLabMarkerDef` deliberately leaves those alone, because
  /// they were real draws and each row carries its own unit.
  ///
  /// But this screen labels a result THROUGH its marker, so a definition
  /// deleted out from under one leaves the reading rendering as its raw
  /// storage key with no interval. Both ways out of that are worse than this
  /// one: deleting the readings too destroys blood work nobody asked to
  /// destroy, and keeping them degrades a number this app calls absolute. So
  /// a marker that still holds results is refused, and says how to proceed —
  /// the results are one screen up, each removable on its own.
  Future<void> _removeMarker(LabMarker m, int results) async {
    final l = AppLocalizations.of(context);
    if (results > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l?.healthStillHoldsResults(results, m.label) ??
            '${m.label} still holds $results '
                '${results == 1 ? 'result' : 'results'}. Remove those first.'),
      ));
      return;
    }
    final ok = await confirmRemove(
      context,
      title: l?.healthRemoveMarkerQ(m.label) ?? 'Remove ${m.label}?',
      body: l?.healthRemoveMarkerBody ??
          'It leaves the marker list, so you can no longer log it.',
    );
    if (!ok || !mounted) return;
    await LocalDb.deleteLabMarkerDef(m.key);
    _l = null;
    await _loadLabs();
  }

  String _num(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  /// Deliberately plain. Entering blood work is a rare, careful act; it does
  /// not need a designed flow, it needs the marker, the number and the date.
  Future<void> _addLab(BuildContext c, LabsData l) async {
    final loc = AppLocalizations.of(c);
    var marker = l.markers.first;
    // Plain strings, not controllers: the fields own theirs, so nothing here
    // is disposed while the dialog is still animating out.
    var valueText = '';
    var takenOnText = todayLabel();

    final ok = await showDialog<bool>(
      context: c,
      builder: (dc) => StatefulBuilder(
        builder: (dc, setLocal) => AlertDialog(
          title: Text(loc?.healthAddAResult ?? 'Add a result'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Unlabelled it announces only its current value — a marker
                // name, with no statement of what the field is.
                Semantics(
                  label: loc?.healthMarkerLabel ?? 'Marker',
                  child: DropdownButton<LabMarker>(
                    isExpanded: true,
                    value: marker,
                    items: [
                      for (final m in l.markers)
                        DropdownMenuItem(
                          value: m,
                          child: Text(_markerName(m, m.label)),
                        ),
                    ],
                    onChanged: (m) => setLocal(() => marker = m ?? marker),
                  ),
                ),
              TextFormField(
                onChanged: (s) => valueText = s,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: loc?.healthValueUnit(marker.unit) ??
                        'Value (${marker.unit})'),
              ),
              TextFormField(
                initialValue: takenOnText,
                onChanged: (s) => takenOnText = s,
                decoration: InputDecoration(
                    labelText: loc?.healthDateDrawn ?? 'Date drawn (YYYY-MM-DD)'),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dc).pop(false),
                child: Text(loc?.actionCancel ?? 'Cancel')),
            TextButton(
                onPressed: () => Navigator.of(dc).pop(true),
                child: Text(loc?.actionSave ?? 'Save')),
          ],
        ),
      ),
    );

    if (ok != true || !mounted) return;
    // Blood work typed by hand is exactly the input nobody notices is missing,
    // so nothing here fails quietly: the dialog used to close on Save and the
    // result was dropped whenever the value carried its unit ("78 ng/mL") or
    // the date was written the other way round.
    final v = Typed.of(valueText);
    final date = takenOnText.trim();
    // Strict, not DateTime.tryParse: that takes '20250101' and rolls
    // '2026-02-30' into March, and the raw text is the sort key and half the
    // primary key, so a compact date sorted above every dashed one.
    // A future draw is refused like the CSV import does: it is a typo far
    // more often than a real blood test, and as the newest row it would sit
    // on top of every real result.
    final error = v.value == null
        ? (loc?.healthValueMustBeNumber ??
            'The value needs to be a number on its own, without the unit. '
                'Nothing was saved.')
        : !isValidDayLabel(date)
            ? (loc?.healthDateFormatError ??
                'The date needs to be YYYY-MM-DD. Nothing was saved.')
            : date.compareTo(todayLabel()) > 0
                ? (loc?.healthDateInFuture ??
                    'That date is after today. Nothing was saved.')
                : null;
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    try {
      await LocalDb.putLabResult(
        marker: marker.key,
        takenOn: date,
        value: v.value!,
        unit: marker.unit,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(loc?.healthCouldNotSaveIt(e.toString()) ??
                'Could not save it: $e')));
      }
      return;
    }
    _l = null;
    await _loadLabs();
  }
}

/// Whether the wellness screen shows its Cycle tab. False where no AppState
/// is provided (widget tests that build the Health tab on its own).
bool _cycleTrackingOn(BuildContext c) {
  try {
    return c.select<AppState, bool>((a) => a.cycleTrackingEnabled);
  } on ProviderNotFoundException {
    return false;
  }
}
