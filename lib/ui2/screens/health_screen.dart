// HEALTH — organised by the question being asked, one time scope per tab.
// "How was last night? How is today going? How have things been trending?"
//
// Rows, not a wall of cards. A card is a claim that something deserves your
// attention; forty of them side by side is a claim about nothing. Last night is
// one night and nothing else, Today is the day so far, Trends is where change
// lives and is a list of every measure that has a history, and Labs is what a
// laboratory measured — the only numbers in this app that are absolute.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../compute/findings.dart';
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/lab_catalogue.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/recalc_state.dart';
import '../activity/day_strain.dart' show DayStrainDetail;
import '../ui2.dart';
import 'circadian_detail.dart';
import 'day_timeline.dart' show DayTimelineScreen;
import 'day_steps.dart' show DayStepsDetail;
import 'ecg.dart' show EcgEntryCard;
import 'findings_log.dart';
import 'home_screen.dart';
import 'illness_observation.dart';
import 'metric_detail.dart';
import 'naps.dart';
import 'readiness_detail.dart';
import 'sleep_detail.dart';

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

  /// The newest day among the stored series and when those series were last
  /// computed (the reader's max `computed_at`) — what Trends says "As of"
  /// while a pass recalculates that day. Null when no reader gave a time.
  final String? chartsNewestDay;
  final DateTime? chartsComputedAt;

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
    this.chartsNewestDay,
    this.chartsComputedAt,
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
  /// place so Last night cannot disagree with itself. Trends is a different
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

  static Future<HealthData> load(LocalRepository repo) async {
    final today = await repo.getToday();
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

    return HealthData(
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
      chartsComputedAt: chartsAt,
      chartsNewestDay: newestT == null
          ? null
          : dayLabelOf(DateTime.fromMillisecondsSinceEpoch(newestT * 1000)),
    );
  }
}

/// What the Today sub-tab reads for its heart rate range and wear time.
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
    final today = await repo.getToday();
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
int? _behind(String? dayId) {
  final d = dayId == null ? null : DateTime.tryParse(dayId);
  return d == null ? null : calendarDaysBetween(d, DateTime.now());
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
// TRENDS LIST. The app persists 39 daily series and carries 25 written metric
// specs — title, unit, colour, icon, method, citation — and until this list
// existed `MetricDetail` was constructed with SEVEN keys anywhere in the tree.
// Sixteen finished screens had no navigation edge at all. That is a routing
// gap, not a content gap, and this is the routing.
//
// It is an index, not a dashboard: nothing here computes, nothing here is a
// number about you. It says what this app can tell you, groups it the way a
// person would look for it, and says for each one whether it has any history —
// which is the only honest answer to "is there anything in there".

/// One catalogue entry: the [MetricSpec] key (which is what [MetricDetail]
/// takes), the `metric_series` key its history is stored under, and the single
/// line that says what it answers.
///
/// Icon, colour and title are NOT here — they come off the spec. A second copy
/// is how two screens end up disagreeing about what a metric is called.
class _CatRow {
  final String key, series, blurb;
  const _CatRow(this.key, this.series, this.blurb);
}

class _Cat {
  final String title;
  final List<_CatRow> rows;
  const _Cat(this.title, this.rows);
}

/// The families, in the order a person looks for them.
///
/// What is deliberately NOT here:
/// - SpO2, ODI and anything apnea-shaped. Refused outright — a capability this
///   app does not produce has no entry, no card and no key. The one exception
///   is a single line under Breathing (see `_family`) saying why there is no
///   SpO2, because people look for it there; it is a sentence, not a row.
/// - Cycle. It is a Wellness tab with its own door and its own on/off switch;
///   a second entrance from Health would be a duplicate route, not a feature.
/// - `rmssd_whole`, `stress_si`, `brv_slope`. Real numbers, but single-night
///   with no series ever. They had written specs for a while and nothing could
///   open them; the specs are gone now, so there is nothing to route to either.
///   `stress` and `brv` below are the charted forms of two of the three.
/// - Body clock, zones, Nerd stats. Each already has a door at the same depth
///   as this one; adding a second is navigation debt.
const _catalogue = <_Cat>[
  // Readiness and stress both have stored histories and were missing from this
  // list, so the one place that lists every measure with a history left out the
  // two most looked-at ones. Each is a composite, not a sensor reading, so they
  // sit in a family of their own.
  _Cat('Recovery', [
    _CatRow('readiness', 'readiness', 'How ready your body looks for strain, against your own usual'),
    _CatRow('stress', 'stress', 'Beat-interval clustering over your most restful stretch'),
  ]),
  _Cat('Heart & rhythm', [
    _CatRow('resting_hr', 'rhr', 'The lowest sustained rate of the night'),
    _CatRow('hrv', 'rmssd', 'RMSSD (beat-to-beat variation) over the cleanest stretch of sleep'),
    _CatRow('hrv_cv', 'hrv_cv', 'How much HRV varies from night to night'),
    _CatRow('lf_hf', 'lf_hf', 'Beat-to-beat variation split by frequency band'),
    _CatRow('dip', 'dip_pct', 'How far your heart rate falls while you sleep'),
    _CatRow('hrr', 'hrr_bpm', 'How fast your heart rate drops in the minute after exercise'),
  ]),
  _Cat('Sleep', [
    _CatRow('sleep', 'tst_min', 'Time asleep, from motion and beat timing'),
    _CatRow('efficiency', 'efficiency', 'Asleep as a share of time in bed'),
    _CatRow('deep', 'deep_min', 'Heart-rate steadiness during non-REM sleep'),
    _CatRow('rem', 'rem_min', 'Sleep stages from beat variability and movement'),
    _CatRow('nap_min', 'nap_min', 'Sleep detected outside the main night'),
  ]),
  _Cat('Breathing', [
    _CatRow('resp_rate', 'resp_rate', 'Breaths per minute, estimated from beat timing'),
    _CatRow('brv', 'brv_cv', 'How much that rate varies across the night'),
  ]),
  _Cat('Movement & load', [
    _CatRow('steps', 'steps', 'Counted by a pedometer'),
    _CatRow('active_min', 'active_min', 'Minutes of body movement, walking or not'),
    _CatRow('calories', 'calories', 'Active energy from heart rate and your profile'),
    _CatRow('strain', 'strain', 'Cardiovascular load over the day, on 0–21'),
    _CatRow('trimp', 'trimp', 'Minutes weighted by heart-rate reserve, harder minutes count more'),
  ]),
  _Cat('Body & wear', [
    _CatRow('skin_temp', 'skin_temp_z', 'Skin temperature vs your recent nights, in standard deviations'),
    _CatRow('wear', 'worn_min', 'Minutes the band recorded data'),
  ]),
];

/// Catalogue category titles and row blurbs are read off a top-level `const`
/// list, which cannot call `AppLocalizations.of(context)` itself — so the
/// lookup happens here, at render time, keyed off the same literal English
/// text/row key the const list already carries as its fallback.
String _catTitle(AppLocalizations? l, String title) => switch (title) {
      'Recovery' => l?.healthCatRecovery ?? title,
      'Heart & rhythm' => l?.healthCatHeartRhythm ?? title,
      'Sleep' => l?.healthRowSleep ?? title,
      'Breathing' => l?.healthCatBreathing ?? title,
      'Movement & load' => l?.healthCatMovementLoad ?? title,
      'Body & wear' => l?.healthCatBodyWear ?? title,
      _ => title,
    };

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
  /// which rows have history and which are named in the folded card.
  final Map<String, int> counts;
  const ExploreData({this.counts = const {}});

  static Future<ExploreData> load() async => ExploreData(
        counts: await LocalDb.metricSeriesCounts([
          for (final f in _catalogue)
            for (final r in f.rows) r.series,
        ]),
      );
}

/// Prior days a trend average needs before a delta is drawn against it.
const _minBaselineDays = 7;

class HealthScreen extends StatefulWidget {
  final HealthData? data;
  final VitalsData? vitals;
  final LabsData? labs;
  final ExploreData? explore;

  /// Which sub-tab to open on, in the four-tab order: 0 Last night, 1 Today,
  /// 2 Trends, 3 Labs. Goldens use it; production starts at 0, which is also
  /// where a deep link or a notification lands.
  final int tab;

  const HealthScreen(
      {super.key,
      this.data,
      this.vitals,
      this.labs,
      this.explore,
      this.tab = 0});

  /// A sub-tab index remembered from the five-tab Health (Overview, Explore,
  /// Trends, Vitals, Labs) → the same place in the four-tab one. Overview was
  /// the night, Explore the catalogue that Trends now lists, Vitals the day so
  /// far. Anything that was never a valid index lands on Last night.
  static int tabFromLegacy(int old) => switch (old) {
        0 => 0,
        1 || 2 => 2,
        3 => 1,
        4 => 3,
        _ => 0,
      };

  /// A deep link asking for one of the sub-tabs — -1 for the ordinary case.
  /// Wellness > Recovery writes 0 (Last night) here and asks the shell to
  /// switch to Health.
  ///
  /// NOT A CONSTRUCTOR ARGUMENT, for the reason `WellnessScreen.tabRequest`
  /// gives: the shell keeps this screen alive in its IndexedStack, so a tap
  /// that lands on a Health already on screen builds nothing. The request
  /// reaches a live state through its listener and a fresh one (the shell
  /// re-keyed to switch domain) through `initState`. The shell clears it a
  /// frame later rather than the screen consuming it on read.
  static final ValueNotifier<int> tabRequest = ValueNotifier<int>(-1);

  /// A tab index `domainForTab` sends to the Health domain, for callers that
  /// ask the shell to switch to Health through `AppState.navRequest`.
  static const int shellTab = 1;

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> with RevisionReload {
  // Four chips fit a 360 pt frame at 1× with nothing clipped by the edge. The
  // order is the order of the questions: the night just gone, the day so far,
  // how things have been going, and what a laboratory measured.
  List<String> _tabsOf(AppLocalizations? l) => [
        l?.healthTabLastNight ?? 'Last night',
        l?.healthTabToday ?? 'Today',
        l?.healthTabTrends ?? 'Trends',
        l?.healthTabLabs ?? 'Labs',
      ];
  late int _tab = widget.tab;

  HealthData? _d;
  VitalsData? _v;
  LabsData? _l;
  ExploreData? _e;
  bool _loading = true;

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
  /// Last night has none of its own: it is drawn from the main read.
  void _enter(int i) {
    if (!mounted) return;
    if (i == 1) _loadVitals();
    if (i == 2) _loadExplore();
    if (i == 3) _loadLabs();
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final t = beginRead(#day);
    try {
      final d = await HealthData.load(repo);
      if (stillNewest(#day, t)) setState(() => (_d = d, _loading = false));
    } catch (_) {
      if (stillNewest(#day, t)) setState(() => _loading = false);
    }
  }

  /// A tab's read THREW. `_v`/`_l` stay null on that path and null renders the
  /// spinner, so swallowing the error left the tab spinning silently for as
  /// long as the user stayed on it — there was no absent state on that path at
  /// all, whatever the old comment here said.
  bool _vFailed = false, _lFailed = false, _eFailed = false;

  Future<void> _loadVitals({bool force = false}) async {
    final repo = repoOf(context);
    if (repo == null || (_v != null && !force)) return;
    // Keyed per sub-tab, so a re-read of one never cancels another's.
    final t = beginRead(#vitals);
    try {
      final v = await VitalsData.load(repo);
      if (stillNewest(#vitals, t)) setState(() => (_v = v, _vFailed = false));
    } catch (_) {
      if (stillNewest(#vitals, t)) setState(() => _vFailed = true);
    }
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
          'The stored rows failed to load. Nothing was deleted.',
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
    return ListView(padding: pad, children: [
      ScreenTitle(l?.healthTitle ?? 'Health'),
      SubTabs(_tabsOf(l), _tab, _select, color: C.blue),
      const SizedBox(height: S.x5),
      if (_loading && _d == null)
        const InlineLoading()
      else
        switch (_tab) {
          0 => _lastNight(c, d),
          1 => _today(c, d),
          2 => _trends(c, d),
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

  // ─────────────── LAST NIGHT ───────────────
  //
  // One night, and nothing else: no sparklines and no trend arrows, because a
  // direction is a history and this tab has none. Every row is a number from
  // the night the day's derivation used, and when that night is not last night
  // the tab says which one it is.
  Widget _lastNight(BuildContext c, HealthData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final rows = <Widget>[];
    final gaps = <Widget>[];

    // Every row here is read from the night, so every absent one takes the same
    // measured gap. A row that is not (none on this tab) would pass
    // `overnight: false`: a hole at 2 AM says nothing about a daytime number.
    //
    // No judgement and no arrow on any row. Whether a number is good news is a
    // question about change, and change lives on Trends.
    void row(Metric m, IconData icon, Color col, String name, String sub,
        String value, String unit, VoidCallback onTap,
        {String? whyAbsent}) {
      if (m.isEmpty) {
        // EVERY ABSENCE CARD STATES A REASON. A row with no specific one (stress
        // on a night that had sleep) got the card's own "no record of why"
        // fallback, which says the app does not know instead of naming the gap.
        // The pipeline's own note and a measured wear gap still outrank this.
        final s = StatusCard.forMetric(
            l?.healthNoMetric(name.toLowerCase()) ?? 'No ${name.toLowerCase()}',
            m,
            why: (whyAbsent == null || whyAbsent.isEmpty)
                ? (l?.healthWhyNotEnoughOvernight ??
                    'Not enough overnight data for this one')
                : whyAbsent,
            gap: d.nightGap);
        if (s != null) gaps.add(s);
        return;
      }
      rows.add(MetricRow(icon, col, name, value,
          sub: sub, unit: unit, onTap: onTap));
    }

    // Most of these rows come off the overnight block, and `getToday` holds that
    // block over until today's settles. A days-old night used to be stated as
    // last night's, so the tab names the night whenever it is not last night.
    final night = heldOverNightOf(d.today);
    final sleepMin = d.sleepMin;
    final noNight = sleepMin.isEmpty
        ? (l?.healthWhyReadOnlyFromSleep ??
            'Comes from sleep only. No night has been scored.')
        : '';

    final ready = d.daily('readiness');
    row(ready, LucideIcons.batteryCharging, C.green,
        l?.healthRowReadiness ?? 'Readiness', '',
        ready.value == null ? '' : '${ready.value!.round()}', '/100',
        () => go(c, ReadinessDetail(day: night)),
        whyAbsent: noNight);

    row(sleepMin, LucideIcons.moon, C.blue,
        l?.healthRowSleep ?? MetricLabels.sleep,
        l?.healthTimeAsleep ?? MetricLabels.timeAsleep, hm(sleepMin.value), '',
        // The night the day used, opened directly: no scrubbing back from today
        // to find it.
        () => go(c, SleepDetail(day: night)),
        whyAbsent: l?.healthWhySleepNotLongEnough ??
            'No sleep period long enough to score was recorded.');

    final hrvMetric = d.hrv;
    row(hrvMetric, LucideIcons.activity, C.green, l?.healthRowHrv ?? MetricLabels.hrv,
        l?.healthSubRmssdAsleep ?? 'RMSSD, asleep',
        hrvMetric.value == null ? '' : '${hrvMetric.value!.round()}', 'ms',
        () => go(c, MetricDetail('hrv', initialDay: night)),
        // Blaming signal quality unconditionally told a day-one user their
        // sensor produced dirty data on a night that never happened.
        whyAbsent: noNight);

    final rhr = d.daily('resting_hr');
    row(rhr, LucideIcons.heart, C.red,
        l?.healthRowRestingHr ?? MetricLabels.restingHr,
        l?.healthSubOvernight ?? 'Overnight',
        rhr.value == null ? '' : '${rhr.value!.round()}', 'bpm',
        () => go(c, MetricDetail('resting_hr', initialDay: night)),
        // Sleep duration and nocturnal RHR are gated separately, so "no night
        // was scored" is often the wrong reason. Only the branch this screen can
        // SEE is stated.
        whyAbsent: sleepMin.isEmpty
            ? (l?.healthWhyReadFromSleep ??
                'Comes from sleep only. No night has been scored.')
            : '');

    final respMetric = d.resp;
    row(respMetric, LucideIcons.wind, C.teal,
        l?.healthRowRespRate ?? MetricLabels.respRate,
        l?.healthSubAsleep ?? 'Asleep',
        respMetric.value == null ? '' : respMetric.value!.toStringAsFixed(1),
        'br/min',
        () => go(c, MetricDetail('resp_rate', initialDay: night)),
        // THE ESTIMATOR'S OWN REASON when it left one, not a guess written
        // here. `respiration.rsa` records which gate it failed, and the
        // repository carries that note through.
        whyAbsent: respMetric.note?.isNotEmpty == true
            ? respMetric.note!
            : (sleepMin.isEmpty
                ? (l?.healthWhyReadOnlyFromSleep ??
                    'Comes from sleep only. No night has been scored.')
                : (l?.healthWhyNoReadingLastNight ??
                    'No reading from last night.')));

    final stressBlock = d.today['stress'];
    final stressScore =
        stressBlock is Map ? (stressBlock['score'] as num?) : null;
    row(
        d.stress,
        LucideIcons.brain,
        C.purple,
        l?.healthRowOvernightStress ?? MetricLabels.overnightStress,
        (stressBlock is Map ? stressBlock['level']?.toString() : null) ?? '',
        stressScore == null ? '' : '${stressScore.round()}',
        // 0–100, and the scale has to be on the row. Wellness has always shown
        // it for the same number.
        '/100',
        () => go(c, MetricDetail('stress', initialDay: night)),
        // Was 'No resting stretch long enough last night.' — one of several
        // gates stress abstains on, asserted for all of them.
        whyAbsent: sleepMin.isEmpty
            ? (l?.healthWhyReadFromNight ??
                'Comes from sleep only. No night has been scored.')
            : '');

    // NAME THE QUANTITY. This is `skin_temp_z`: standard deviations from the
    // user's own usual level. It printed signed and unitless beside a heart rate
    // in bpm, so it read as degrees; the caption under the rows says what SD is.
    final skinTemp = metricOf(d.today['skin_temp']);
    row(skinTemp, LucideIcons.thermometer, C.orange,
        l?.healthRowSkinTemp ?? MetricLabels.skinTemp,
        l?.healthVsYourUsual ?? 'vs your usual',
        skinTemp.value == null
            ? ''
            : '${skinTemp.value! >= 0 ? '+' : '−'}'
                '${skinTemp.value!.abs().toStringAsFixed(2)}',
        'SD', () => go(c, MetricDetail('skin_temp', initialDay: night)));

    final illness = d.today['illness'];
    final illnessDay = illness is Map ? illness['date']?.toString() : null;
    final illnessBehind = _behind(illnessDay);
    // The CUSUM watch runs on NOCTURNAL RESTING HEART RATE ALONE, and the card
    // is the one Home draws (illness_observation.dart). The payload carries the
    // night it is about: it is one entry per DERIVED day, so after a gap "Last
    // night" named a night the user did not wear the band for.
    final illnessCard = illnessObservation(
      c,
      state: illness is Map ? illness['state']?.toString() : null,
      sameNight: illnessBehind == null || illnessBehind <= 0,
      day: illnessDay,
      z: illness is Map ? (illness['z'] as num?) : null,
    );

    final status = d.today['status'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Every row above comes off the overnight row, whichever night it is.
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
      if (night != null) ...[
        Text(l?.healthNightOf(prettyDay(night, l)) ?? 'Night of ${prettyDay(night, l)}',
            style: F.cap.copyWith(color: p.ink2)),
        const SizedBox(height: S.x3),
      ],
      if (rows.isNotEmpty)
        Surface(
          pad: const EdgeInsets.symmetric(horizontal: S.x4),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(color: p.line, height: 1),
              rows[i],
            ],
          ]),
        ),
      if (skinTemp.value != null) ...[
        const SizedBox(height: S.x2),
        Text(
            l?.healthSkinTempSdNote ??
                'Skin temperature is a deviation from your own usual level, in '
                    'standard deviations (SD). It is not a temperature in '
                    'degrees.',
            style: F.over.copyWith(color: p.ink3, height: 1.6)),
      ],
      for (final g in gaps) ...[const SizedBox(height: S.x3), g],

      // OBSERVATIONS — the illness watch, wrapped, plus a door to the other
      // three detectors.
      //
      // The illness card is the one finding with copy specific enough to be
      // worth a card of its own. What this section adds is a title over it and a
      // way through to the anomaly, skin temperature and resting-HR findings,
      // which fired for months and reached no screen at all. NOT a feed — see
      // findings_log.dart. Nothing here is unread, badged or dismissible.
      if (illnessCard != null || d.findings.isNotEmpty) ...[
        const SizedBox(height: S.x4),
        Section(
          l?.healthObservationsTitle ?? 'Observations',
          illnessCard ??
              // No live illness, but the log is not empty: the newest entry in
              // place and the rest one tap away. ONE row — a wall of findings
              // on the tab you land on is the feed this is not.
              Surface(
                onTap: () => go(c, FindingsLog(d.findings)),
                child: FindingRow(d.findings.first),
              ),
          action: d.findings.isEmpty ? null : (l?.healthSeeAll ?? 'See all'),
          onAction:
              d.findings.isEmpty ? null : () => go(c, FindingsLog(d.findings)),
        ),
      ],
      // NAPS — the display and the correction, which are one feature. The
      // section is here on a day with no naps too, because the door to logging
      // one has to exist on exactly the day the detector found nothing.
      Section(
        l?.healthNapsTitle ?? 'Naps',
        d.napCount == null
            // `napDay` defaults to '' and `prettyDay` returns '' for anything
            // it cannot parse, so this printed "No nap reading for" with the
            // sentence hanging off the end of the word "for". Name the day only
            // when there is one to name.
            ? StatusCard(
                prettyDay(d.napDay).isEmpty
                    ? (l?.healthNoNapReading ?? 'No nap reading')
                    : (l?.healthNoNapReadingFor(prettyDay(d.napDay)) ??
                        'No nap reading for ${prettyDay(d.napDay)}'),
                l?.healthNapsBody ??
                    'Naps are detected from the same second-by-second recording '
                    'as the rest of the day. This day has too little '
                    'of it.',
                icon: LucideIcons.sun,
              )
            : Surface(
                pad: const EdgeInsets.symmetric(horizontal: S.x4),
                child: MetricRow(
                  LucideIcons.sun,
                  C.indigo,
                  l?.healthDaytimeSleep ?? MetricLabels.daytimeSleep,
                  // A MEASURED zero, not a dash: the day was judged and held
                  // no nap. The two are different answers and read as two.
                  d.napCount == 0 ? (l?.healthValueNone ?? 'None') : hm(d.napMin),
                  sub: d.napCount == 0
                      ? (l?.healthNoneDetectedOn(prettyDay(d.napDay)) ??
                          'None detected · ${prettyDay(d.napDay)}')
                      : '${l?.healthNapCountLabel(d.napCount!) ?? '${d.napCount} '
                              'nap${d.napCount == 1 ? '' : 's'}'} · '
                          '${prettyDay(d.napDay)}',
                  onTap: () => go(c, NapsScreen(day: d.napDay)),
                ),
              ),
        action: l?.healthAddOrCorrect ?? 'Add or correct',
        onAction: () => go(c, NapsScreen(day: d.napDay)),
      ),

      // WHOOP MG only: the Heart Screener door appears once the paired band has
      // positively identified itself as an MG, and stays while it is away. It is
      // the last thing on the tab, below everything this night produced.
      if (c.caps.has(Feature.ecgEntry)) ...[
        const SizedBox(height: S.x3),
        const EcgEntryCard(),
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

  // ─────────────── TODAY ───────────────
  //
  // Today so far. The six rows are totals and ranges for the day, none of them
  // is an overnight number, and every one opens its own detail.
  Widget _today(BuildContext c, HealthData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final v = _v;

    // Rows and the cards for rows with no value, in the order the tab shows
    // them. A row with no value is never a dash in a list: it is a card that
    // says so and says why.
    final rows = <Widget>[];
    final gaps = <Widget>[];
    var anyValue = false;

    void row(Metric m, IconData icon, Color col, String name, String sub,
        String value, String unit, VoidCallback onTap) {
      if (m.isEmpty) {
        final s = StatusCard.forMetric(
            l?.healthNoMetric(name.toLowerCase()) ?? 'No ${name.toLowerCase()}',
            m,
            why: l?.healthWhyNotMeasuredToday ?? 'Not measured yet today.');
        if (s != null) gaps.add(s);
        return;
      }
      anyValue = true;
      rows.add(MetricRow(icon, col, name, value,
          sub: sub, unit: unit, onTap: onTap));
    }

    final strain = d.daily('strain');
    row(strain, LucideIcons.zap, C.purple,
        l?.healthRowStrain ?? MetricLabels.strain, '',
        strain.value == null ? '' : strain.value!.toStringAsFixed(1), '/21',
        () => go(c, const DayStrainDetail()));

    final steps = d.daily('steps');
    row(steps, LucideIcons.footprints, C.green,
        l?.healthRowSteps ?? MetricLabels.steps, '', thousands(steps.value), '',
        () => go(c, const DayStepsDetail()));

    final active = d.daily('active_min');
    row(active, LucideIcons.activity, C.green,
        l?.healthRowActiveMinutes ?? 'Active minutes', '',
        active.value == null ? '' : '${active.value!.round()}', 'min',
        () => go(c, const MetricDetail('active_min')));

    final calories = d.daily('calories');
    row(calories, LucideIcons.flame, C.orange,
        l?.healthRowCalories ?? 'Calories', '',
        calories.value == null ? '' : '${calories.value!.round()}', 'kcal',
        () => go(c, const MetricDetail('calories')));

    // The vitals describe today only when they are for today: the loader falls
    // back to the newest derived day when today has none. That day's heart
    // rate range is a different day's number, so it is an absence here and not
    // a range under another day's caption.
    final vitalsToday = v != null && (_behind(v.day) ?? 1) <= 0;
    final coverage = vitalsToday ? v.wear['coverage_pct'] as num? : null;

    if (v != null) {
      final highs = vitalsToday ? v.timeline['highs'] : null;
      num? high(String k) {
        final e = highs is Map ? highs[k] : null;
        return e is Map ? e['v'] as num? : null;
      }

      final lo = high('low_hr'), hi = high('peak_hr');
      if (lo != null && hi != null) {
        anyValue = true;
        rows.add(MetricRow(LucideIcons.heart, C.red,
            l?.healthRowHeartRate ?? 'Heart rate', '${lo.round()} – ${hi.round()}',
            sub: l?.healthToday ?? 'Today',
            unit: 'bpm',
            // The day's own heart rate, for the day this row describes. It used
            // to open the RESTING heart rate screen, which is the night's
            // lowest sustained rate and says nothing about this range.
            onTap: () => go(c, DayTimelineScreen(day: v.day))));
      } else {
        gaps.add(StatusCard(
          l?.healthNoMetric((l.healthRowHeartRate).toLowerCase()) ??
              'No heart rate range',
          l?.healthWhyNotMeasuredToday ?? 'Not measured yet today.',
          icon: LucideIcons.heart,
        ));
      }
    }

    // WEAR TIME is today's own envelope, read with the rest of the day's totals.
    // The loader's wear block describes whichever derived day it fell back to,
    // which after a sync gap is days ago, so it is not the source of this row.
    final wear = d.daily('wear_min');
    row(wear, LucideIcons.watch, C.green,
        l?.healthRowWearTime ?? 'Wear time',
        // `83.33333333333333% of the day` shipped. It is a percentage.
        coverage == null
            ? ''
            : (l?.healthCoverageOf(coverage.round(), l.healthTheDay) ??
                '${coverage.round()}% of the day'),
        hm(wear.value), '', () => go(c, const MetricDetail('wear')));

    final status = d.today['status'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Strain, steps and the rest of the day so far come off today's row.
      _asOf(
          d,
          (recalc) => asOfFor(
              shownDay: status is Map ? status['activity_day']?.toString() : null,
              computedAt: computedAtOf(
                  status is Map ? status['activity_computed_at'] : null),
              recalc: recalc),
          day: status is Map ? status['activity_day']?.toString() : null,
          computedAt: computedAtOf(
              status is Map ? status['activity_computed_at'] : null)),
      if (rows.isNotEmpty)
        Surface(
          pad: const EdgeInsets.symmetric(horizontal: S.x4),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(color: p.line, height: 1),
              rows[i],
            ],
          ]),
        ),
      if (v != null && !anyValue)
        // Nothing at all for the day: one card, with the one thing that changes
        // it, rather than six cards that each say the same.
        StatusCard(
          l?.healthNothingMeasuredDay ?? 'Nothing measured for this day',
          l?.healthNoBandRecordings ?? 'No band recordings reached this day.',
          fix: syncOf(c) == null ? '' : (l?.healthSyncTheBand ?? 'Sync the band'),
          icon: LucideIcons.watch,
          onFix: syncOf(c),
        )
      else
        for (final g in gaps) ...[const SizedBox(height: S.x3), g],
      if (v == null)
        // The two rows that need the day's timeline are still on their way, or
        // their read threw. A thrown read is not an empty day.
        _vFailed
            ? _readFailed(l?.healthWhatVitals ?? 'vitals', () {
                setState(() => _vFailed = false);
                _loadVitals();
              })
            : const Padding(
                padding: EdgeInsets.only(top: S.x3), child: InlineLoading()),
    ]);
  }

  // ─────────────── TRENDS ───────────────
  //
  // How things have been going: the two cards about your rhythm, the three
  // measures that say how they sit against your own average, then every other
  // measure that has a history, grouped by what it is about. Each one opens the
  // measure's own screen on 30 days.
  Widget _trends(BuildContext c, HealthData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final cd = d.insights;
    final chrono = envValue(cd['chronotype']) ?? const {};
    final sjl = envValue(cd['social_jetlag']) ?? const {};
    final reg = envValue(cd['regularity']) ?? const {};
    final sjlH = sjl['abs_hours'] as num?;
    final sri = reg['sri'] as num?;
    final stale = staleInsightsCard(d.insightsStale, syncOf(c));
    final e = _e;

    /// [against] is the number the card compares the latest reading TO. Pass it
    /// and the delta is measured against that; leave it null and the delta is
    /// measured against the trailing mean of what is stored.
    ///
    /// It exists because the sleep card used to caption itself "vs your 7h 45m
    /// need" while still subtracting the 28-day AVERAGE — so the arrow and the
    /// figure under it read as sleep debt and were not. One of the two had to
    /// become true; the debt is the more useful of the pair.
    ///
    /// Null when nothing is stored for [key]: the family list below says so for
    /// that measure, in its folded card, instead of a card of its own.
    // No `Metric` argument: this card is drawn entirely from the stored
    // series, so taking the envelope only implied a cross-check that was
    // never made.
    Widget? trend(String key, String label, String unit, Color col,
        {bool higherBetter = true,
        double? against,
        String? againstLabel,
        String subLabel = ''}) {
      final pts = d.points(key);
      // Statistics off the STORED values; the painter gets the dense window.
      final s = valuesOf(pts);
      if (s.isEmpty) return null;
      final prior = s.length > 1
          ? s.sublist(s.length - 1 - (s.length - 1).clamp(0, 28), s.length - 1)
          : const <double>[];
      // "vs your 1-day average" was printed from the SECOND stored value, over
      // a mean of one, with an arrow and a hue on top. An average of fewer than
      // [_minBaselineDays] prior days is a coin flip, not a baseline, so below
      // that the card shows the value alone and says how far along it is. A
      // computed need is a different comparison (not an average of prior days),
      // so the rule is about averages only.
      final mean = prior.length < _minBaselineDays
          ? null
          : prior.reduce((a, b) => a + b) / prior.length;
      final base = against ?? mean;
      final window = against != null
          ? (againstLabel ?? '')
          : prior.length >= _minBaselineDays
              ? (l?.healthVsDayAverage(prior.length) ??
                  'vs your ${prior.length}-day average')
              : prior.isEmpty
                  ? (l?.healthFirstReadings ?? 'first readings')
                  : (l?.healthBuildingBaseline(prior.length) ??
                      'Building your baseline (${prior.length} of '
                          '$_minBaselineDays days)');
      final delta = base == null ? 0.0 : s.last - base;
      final win = denseDays(pts, 30);
      // The hero number is the newest STORED point, which after a sync gap is
      // not today's. Say when it is from rather than let the card imply now.
      final behind = daysBehind(pts.last.t) ?? 0;
      final asOf = behind <= 0
          ? ''
          : (l?.healthAsOf(axisDay(pts.last.t)) ?? ' · as of ${axisDay(pts.last.t)}');
      return TrendCard(
        label,
        key == 'sleep' ? hm(s.last) : metricValue(unit, s.last),
        // Sleep has no unit; its slot carries "Time asleep" so the card can be
        // named "Sleep" like everywhere else and still say what the figure is.
        key == 'sleep' ? subLabel : unit,
        base == null
            ? (l?.healthNoBaseline ?? 'no baseline')
            : (key == 'sleep' ? hm(delta.abs()) : metricValue(unit, delta.abs())),
        '$window$asOf',
        win,
        col,
        up: delta >= 0,
        // Null with no baseline: an arrow and a good/bad hue about a
        // comparison the card has just said it cannot make.
        good: base == null ? null : (delta >= 0) == higherBetter,
        onTap: () => go(c, MetricDetail(key, initialRange: 30)),
      );
    }

    // The three measures whose card says how the latest reading sits against
    // your own average (or, for sleep, against your need). Each is drawn here
    // OR in its family below, never both: a measure with a stored series gets
    // the card, one without gets its row or its place in the folded card.
    final cards = <String, Widget>{
      for (final (key, card) in <(String, Widget?)>[
        ('resting_hr',
            trend('resting_hr', l?.healthRowRestingHr ?? MetricLabels.restingHr, 'bpm',
                C.red, higherBetter: false)),
        ('hrv', trend('hrv', l?.healthRowHrv ?? MetricLabels.hrv, 'ms', C.green)),
        (
          'sleep',
          // `need` here is `crossday.sleep_coach.need` — the COMPUTED need. It
          // is never `sleep.need_min`, which is a hardcoded 480.
          //
          // Named "Sleep" like everywhere else; "Time asleep" is what the
          // figure is, so it rides as the sub-label.
          d.need.value == null
              ? trend('sleep', l?.healthRowSleep ?? MetricLabels.sleep, '', C.blue,
                  subLabel: l?.healthTimeAsleep ?? MetricLabels.timeAsleep)
              : trend('sleep', l?.healthRowSleep ?? MetricLabels.sleep, '', C.blue,
                  subLabel: l?.healthTimeAsleep ?? MetricLabels.timeAsleep,
                  against: d.need.value!.toDouble(),
                  againstLabel: l?.healthVsNeed(hm(d.need.value)) ??
                      'vs your ${hm(d.need.value)} need')
        ),
      ])
        key: ?card,
    };

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The trends are the stored series, and chronotype and regularity are
      // the cross-day rollup: either being recalculated says when it was last
      // computed.
      _asOf(
          d,
          (recalc) =>
              asOfFor(
                  shownDay: d.chartsNewestDay,
                  computedAt: d.chartsComputedAt,
                  recalc: recalc) ??
              asOfFor(
                  shownDay: null,
                  computedAt: computedAtOf(cd['computed_at']),
                  recalc: recalc,
                  dependsOnCrossDay: true)),
      // Chronotype, jetlag and regularity ALL come out of the cross-day
      // rollup. When it is withheld, the section says why rather than showing
      // the cold-start "it takes a few weeks" line, which would be a lie.
      if (stale != null)
        Section(l?.healthBodyClockTitle ?? 'Body clock', stale)
      else
        Section(
          l?.healthBodyClockTitle ?? 'Body clock',
          Surface(
            onTap: () => go(c, const CircadianDetail()),
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: Text(
                      l?.healthChronotypeJetlagRegularity ??
                          'Chronotype, jetlag and regularity',
                      style: F.cap.copyWith(color: p.ink2)),
                ),
                Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
              ]),
              if (chrono.isNotEmpty || sjlH != null || sri != null) ...[
                const SizedBox(height: S.x4),
                InlineMetrics([
                  if (chrono['type_label'] != null)
                    (l?.healthChronotypeLabel ?? 'CHRONOTYPE',
                        chrono['type_label'].toString(), C.indigo),
                  if (sjlH != null)
                    (l?.healthSocialJetlagLabel ?? 'SOCIAL JETLAG',
                        _hoursHm(sjlH), C.orange),
                  if (sri != null)
                    (l?.healthRegularityLabel ?? 'REGULARITY',
                        '${sri.round()} / 100', C.green),
                ]),
              ],
            ]),
          ),
        ),

      Section(
        l?.healthConsistencyTitle ?? 'Consistency',
        Surface(
          child: Consistency(
            // Already windowed to the last 30 calendar days by `HealthData.load`
            // — the clamp is a floor for a bad count, not the window.
            d.daysWithData.clamp(0, 30),
            30,
            l?.healthDaysWithRecord ??
                'Days with analysed data in the last 30 days',
            C.domHealth,
          ),
        ),
      ),

      for (final card in cards.values) ...[
        const SizedBox(height: S.x3),
        card,
      ],

      if (e == null)
        _eFailed
            ? _readFailed(l?.healthMeasuresUnit ?? 'measures', () {
                setState(() => _eFailed = false);
                _loadExplore();
              })
            : const Padding(
                padding: EdgeInsets.only(top: S.x3), child: InlineLoading())
      else ...[
        // Not a promise of insight — a statement of what a tap gets you. Every
        // row below opens the same drill-down: the chart, your own range, the
        // method in full, and the paper it came from.
        const SizedBox(height: S.x2),
        Text(
            l?.healthEachOneOpens ??
                'Each one opens its chart, your range and how it is calculated.',
            style: F.over.copyWith(color: p.ink3, height: 1.6)),
        for (final f in _catalogue) _family(c, p, f, e.counts, cards.keys.toSet()),
      ],
    ]);
  }

  String _hoursHm(num h) {
    final m = (h * 60).round();
    return m < 60 ? '${m}m' : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }


  /// [covered] is the keys already drawn as a card above the list. They are
  /// left out here entirely, so a measure shows once on the tab.
  Widget _family(BuildContext c, P p, _Cat f, Map<String, int> counts,
      Set<String> covered) {
    final l = AppLocalizations.of(c);
    final have = [
      for (final r in f.rows)
        if (!covered.contains(r.key) && (counts[r.series] ?? 0) > 0) r,
    ];
    final none = [
      for (final r in f.rows)
        if (!covered.contains(r.key) && (counts[r.series] ?? 0) == 0) r,
    ];
    if (have.isEmpty && none.isEmpty) return const SizedBox.shrink();

    return Section(
      _catTitle(l, f.title),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (have.isNotEmpty)
          Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4),
            child: Column(children: [
              for (var i = 0; i < have.length; i++) ...[
                if (i > 0) Divider(color: p.line, height: 1),
                Builder(builder: (c) {
                  final r = have[i];
                  final s = specOf(r.key);
                  // NO NUMBER IN THE VALUE SLOT, on purpose.
                  //
                  // This used to print the day count. It read as a score: nine
                  // days of breathing rate beside seventeen of resting HR looks
                  // like the app is worse at breathing, when what it means is
                  // that the estimator abstains more — which is the behaviour
                  // we want. It also collapsed three different causes into one
                  // number: genuinely rare, key shipped last week, substrate
                  // pruned. `midsleep_sec` is forward-only and can never be
                  // backfilled, so it would sit at 1 next to everything else's
                  // 17 and mean nothing of the sort.
                  //
                  // And it was redundant. Rows with history sort above rows
                  // without, and the empty ones are named in the StatusCard
                  // below. Has / hasn't is the only thing an index owes you,
                  // and the layout already says it.
                  // 30 days, not Today: this is a list of histories, and a
                  // history is what the row was picked for.
                  return MetricRow(s.icon, s.color, s.title, '',
                      sub: _rowBlurb(l, r.key, r.blurb),
                      onTap: () => go(c, MetricDetail(r.key, initialRange: 30)));
                }),
              ],
            ]),
          ),
        if (none.isNotEmpty) ...[
          if (have.isNotEmpty) const SizedBox(height: S.x3),
          StatusCard(
            have.isEmpty
                ? (l?.healthNothingMeasuredHere ?? 'Nothing measured here yet')
                : (l?.healthNotMeasuredYet ?? 'Not measured yet'),
            // No cause is named, because none is known here: this screen reads
            // a row count, and a count of zero says the day never produced one
            // — never why. No `fix:` either; there is no button that makes a
            // derive happen for a night that has already been scored.
            '${none.map((r) => specOf(r.key).title).join(' · ')}. '
                '${l?.healthNoDayProduced ?? 'No day on this device has '
                    'produced one yet.'}',
            icon: LucideIcons.chartLine,
          ),
        ],
        if (f.title == 'Breathing') ...[
          const SizedBox(height: S.x2),
          Text(
              l?.healthWhyNoSpo2 ??
                  'No SpO2 here: this app does not estimate blood oxygen.',
              style: F.over.copyWith(color: p.ink3, height: 1.6)),
        ],
      ]),
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
          : const InlineLoading();
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
      if (rows.isEmpty)
        StatusCard(
          loc?.healthNoLabResults ?? 'No lab results',
          loc?.healthNoLabResultsBody ??
              'Nothing logged yet. Results you add stay on this device. '
              'Removing a result deletes it from the device.',
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
      if (mine.isNotEmpty) _myMarkers(p, mine, counts),
      const SizedBox(height: S.x4),
      BigButton(loc?.healthAddAResult ?? 'Add a result',
          icon: LucideIcons.plus,
          color: C.blue,
          soft: true,
          onTap: () => _addLab(c, l)),
      const SizedBox(height: S.x4),
      // The app never prints "abnormal" anywhere, so it does not need to say
      // it does not. What the user cannot know without being told is that the
      // range shown here is not the range their own lab used.
      Text(loc?.healthRangesDifferByLab ??
              'Ranges differ by lab. Use the one on your report.',
          style: F.over.copyWith(color: p.ink3, height: 1.6)),
    ]);
  }

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
      semanticLabel: l?.healthRemoveMarkerFrom(
              (m?.label ?? r['marker']).toString(), r['taken_on'].toString()) ??
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m?.label ?? r['marker'].toString(),
                  style: F.body.copyWith(color: p.ink)),
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
    final label = m?.label ?? marker;
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
              'This deletes the ${m?.format(v) ?? _num(v)} $unit you logged for that draw. '
              'You cannot undo it.') +
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
                '${results == 1 ? 'result' : 'results'}. Remove those first. '
                'Each result is labelled by its marker.'),
      ));
      return;
    }
    final ok = await confirmRemove(
      context,
      title: l?.healthRemoveMarkerQ(m.label) ?? 'Remove ${m.label}?',
      body: l?.healthRemoveMarkerBody ??
          'Deleting it removes the marker from the list, so you can no longer log results for it. '
          'It has no results, so no measurements are deleted.',
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
    final value = TextEditingController();
    final now = DateTime.now();
    final takenOn = TextEditingController(
        text: '${now.year.toString().padLeft(4, '0')}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')}');

    try {
      final ok = await showDialog<bool>(
        context: c,
        builder: (dc) => StatefulBuilder(
          builder: (dc, setLocal) => AlertDialog(
            title: Text(loc?.healthAddAResult ?? 'Add a result'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Unlabelled it announces only its current value — a marker
                // name, with no statement of what the field is.
                Semantics(
                  label: loc?.healthMarkerLabel ?? 'Marker',
                  child: DropdownButton<LabMarker>(
                    isExpanded: true,
                    value: marker,
                    items: [
                      for (final m in l.markers)
                        DropdownMenuItem(value: m, child: Text(m.label)),
                    ],
                    onChanged: (m) => setLocal(() => marker = m ?? marker),
                  ),
                ),
                TextField(
                  controller: value,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: loc?.healthValueUnit(marker.unit) ??
                          'Value (${marker.unit})'),
                ),
                TextField(
                  controller: takenOn,
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
      final v = Typed.of(value.text);
      final date = takenOn.text.trim();
      if (v.value == null || DateTime.tryParse(date) == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(v.value == null
              ? (loc?.healthValueMustBeNumber ??
                  'Enter the value as a number without the unit. '
                  'Nothing was saved.')
              : (loc?.healthDateFormatError ??
                  'The date needs to be YYYY-MM-DD. Nothing was saved.')),
        ));
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
                  'Could not save the result: $e')));
        }
        return;
      }
      _l = null;
      await _loadLabs();
    } finally {
      value.dispose();
      takenOn.dispose();
    }
  }
}
