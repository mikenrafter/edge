// BODY CLOCK — the highest-value thing the pipeline already knew and nothing
// ever asked it for.
//
// Chronotype, social jetlag and the sleep-regularity index are computed every
// cross-day rollup and, until this screen, were read by nothing. The actogram
// is built here from the per-night sleep windows: one column per night, noon
// to noon, so a night reads as one continuous block instead of being cut in
// half at midnight.
//
// The non-parametric rhythm family (interdaily stability, intradaily
// variability, relative amplitude, L5/M10) and the 24 h cosinor ARE computed —
// `crossday_pipeline.dart:_crossDayCircadian` emits `circadian_rhythm`,
// `circadian_cosinor` and `circadian_coverage` on every rollup. Their substrate
// is not the textbook one: the 1 Hz accelerometry is pruned after three days,
// so the battery runs on the per-day HOURLY HEART-RATE profile that `day_result`
// keeps forever. That makes M10/L5 the highest- and lowest-HR windows rather
// than step counts, and the card says so out loud rather than letting the
// numbers imply accelerometry.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../../data/circadian_artifact.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart';
import '../../state/recalc_state.dart';
import '../ui2.dart';
import 'home_screen.dart';
import 'metric_detail.dart';

class CircadianData {
  /// Newest last. One entry per night: 24 hourly fractions from local noon, or
  /// null when that night has no window.
  final List<List<double>?> actogram;
  final List<String> labels;
  final Metric jetlag, regularity;

  /// Chronotype is a CLASS, not a number — a label, never a value.
  final String chronotypeLabel;
  final num? midFreeH, midWorkH, nFree, nWork;

  /// The non-parametric battery, carried as the envelope's IS so the whole
  /// family has one presence gate and one `need_baseline:` note to render.
  final Metric rhythm;
  final Map<String, dynamic> rhythmV, cosinorV, coverage;

  /// CV-09 — daytime RMSSD by hour of day, one slot per hour, `null` for an
  /// hour with too few quiet stretches behind it to be a reading. The WEEKLY
  /// median, never a value for today: a single day's hour is two or three
  /// five-minute windows.
  final List<double?> hourly;

  /// How the hourly row was built: derived days walked, how many quiet
  /// 5-minute stretches EACH hour is made of (24 slots, parallel to [hourly]),
  /// and the estimator's own note when it refused — an unknown strap family has
  /// no ENMO cut we can stand behind, so it gets none rather than gen4's.
  final int hourlyDays;
  final List<int> hourlyN;
  final String? hourlyNote;

  /// SLP-08 — the adjacent-night pairs the regularity index was averaged over,
  /// WORST FIRST. Each entry is `{prev_date, date, sri, cases}`.
  ///
  /// The analytics never sees a date; `crossday_pipeline` resolves each pair's
  /// day index into the two nights it compared, and drops any pair the validity
  /// mask left too thin — so a half-unobserved weekend cannot top this list for
  /// having no data. Empty until the rollup carries pairs at all.
  final List<Map<String, dynamic>> sriPairs;

  /// MIND-11 — the shape of today, forecast from last night. Absent whenever
  /// the night is missing or was never judged; the analytics gate does that and
  /// this screen only draws what it published.
  final ana.Metric<ana.AlertnessForecast> alertness;

  /// When the cross-day rollup this screen reads was written — what "As of"
  /// says while the cross-day step recalculates it. Null when the reader gave
  /// none.
  final DateTime? computedAt;

  const CircadianData({
    this.actogram = const [],
    this.labels = const [],
    this.jetlag = Metric.empty,
    this.regularity = Metric.empty,
    this.chronotypeLabel = '',
    this.midFreeH,
    this.midWorkH,
    this.nFree,
    this.nWork,
    this.rhythm = Metric.empty,
    this.rhythmV = const {},
    this.cosinorV = const {},
    this.coverage = const {},
    this.hourly = const [],
    this.hourlyDays = 0,
    this.hourlyN = const [],
    this.hourlyNote,
    this.sriPairs = const [],
    this.alertness = const ana.Metric<ana.AlertnessForecast>.absent(
      tier: ana.Tier.estimate,
      inputs_used: [],
      note: 'no night loaded',
    ),
    this.computedAt,
  });

  /// The middle value of [xs], which must be non-empty. A median, not a mean:
  /// one bin of a stairwell would drag an hour's average and nothing about the
  /// motion gate catches a slow climb.
  static double _median(List<double> xs) {
    final s = [...xs]..sort();
    return s[s.length ~/ 2];
  }

  /// Reads the artifact fresh from the repository's own readers: what the
  /// warmer stores under `circadian` and a screen handed a bare repository
  /// builds from.
  static Future<CircadianData> load(LocalRepository repo) async =>
      CircadianData.fromArtifact(await buildCircadianArtifact(repo));

  /// The screen's data from the `circadian` artifact (`buildCircadianArtifact`):
  /// the rollup's envelopes plus the actogram and hourly rows it carries. Both
  /// the in-memory map and one read back from the store (lists of `dynamic`)
  /// are accepted.
  factory CircadianData.fromArtifact(Map<String, dynamic> art) {
    final cd = art;
    final scr = (art[kCircadianScreenKey] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final chrono = cd['chronotype'];
    final sjl = cd['social_jetlag'];
    final reg = cd['regularity'];
    final chronoV = envValue(chrono) ?? const {};
    final sjlV = envValue(sjl) ?? const {};
    final regV = envValue(reg) ?? const {};
    final np = cd['circadian_rhythm'];
    final cos = cd['circadian_cosinor'];
    final npV = envValue(np) ?? const {};

    final cols = <List<double>?>[
      for (final c in (scr['actogram'] as List? ?? const []))
        c is List ? [for (final x in c) (x as num).toDouble()] : null,
    ];
    final labels = [
      for (final l in (scr['labels'] as List? ?? const [])) l.toString(),
    ];
    // An hour built from one or two stretches is not an hour. It goes absent
    // rather than being drawn faintly or averaged with its neighbours.
    final byHour = [
      for (final h in (scr['hourly_samples'] as List? ?? const []))
        [for (final x in (h as List)) (x as num).toDouble()],
    ];
    final hourly = [
      for (final xs in byHour) xs.length < 3 ? null : _median(xs),
    ];
    final hourlyNote = scr['hourly_note']?.toString();
    final week = (scr['hourly_days'] as num?)?.toInt() ?? 0;

    final cosV = envValue(cos) ?? const {};
    // MIND-11. Both inputs are REQUIRED by the analytics gate and neither has a
    // default here: a missing night abstains rather than assuming eight hours,
    // which is the gate the item says gets quietly removed later if it is not
    // pinned. Naps are not passed — the forecast is for today and today's naps
    // have not happened; the card says it only knows last night.
    final wake = (scr['latest_wake_ts'] as num?)?.round();
    final wakeLocal = wake == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(wake * 1000);
    final tstMin = (scr['latest_duration_min'] as num?)?.toDouble();

    return CircadianData(
      actogram: cols,
      labels: labels,
      alertness: ana.alertnessForecast(
        wakeLocalHour:
            wakeLocal == null ? null : wakeLocal.hour + wakeLocal.minute / 60.0,
        sleepDurationHours: tstMin == null ? null : tstMin / 60.0,
        circadianAcrophaseHours: (cosV['acrophase_hours'] as num?)?.toDouble(),
      ),
      hourly: hourly,
      hourlyDays: week,
      hourlyN: [for (final xs in byHour) xs.length],
      hourlyNote: hourlyNote,
      chronotypeLabel: (chronoV['type_label'] ?? '').toString(),
      jetlag: envMetric(sjl, sjlV['abs_hours'] as num?),
      regularity: envMetric(reg, regV['sri'] as num?),
      // SLP-08. Worst first — the one row this can support is "these two
      // agreed least", so the list is sorted for that and nothing else reads
      // past the head of it.
      sriPairs: <Map<String, dynamic>>[
        for (final e in (regV['pairs'] as List? ?? const []))
          if (e is Map && e['sri'] is num && e['date'] != null &&
              e['prev_date'] != null)
            e.cast<String, dynamic>(),
      ]..sort((a, b) => (a['sri'] as num).compareTo(b['sri'] as num)),
      midFreeH: sjlV['mid_sleep_free_h'] as num?,
      midWorkH: sjlV['mid_sleep_work_h'] as num?,
      nFree: sjlV['n_free'] as num?,
      nWork: sjlV['n_work'] as num?,
      rhythm: envMetric(np, npV['IS'] as num?),
      rhythmV: npV,
      cosinorV: cosV,
      coverage: (cd['circadian_coverage'] as Map?)?.cast<String, dynamic>() ??
          const {},
      computedAt: computedAtOf(cd['computed_at']),
    );
  }
}

/// Hours past midnight → a wall clock, in the app's one clock format.
String _hourClock(num? h) => h == null ? '' : clock(((h % 24) * 60).round());

/// `'YYYY-MM-DD'` → `'9 Aug'`. Built off [prettyDay] rather than a second month
/// table: two dates spelled "Saturday, 9 August" do not fit one table row, and
/// this screen's own actogram axis already prints bare dates.
String _shortDay(Object? day) {
  final parts = prettyDay(day?.toString()).split(', ');
  if (parts.length < 2) return '';
  final dm = parts.last.split(' ');
  return dm.length < 2 ? parts.last : '${dm[0]} ${dm[1].substring(0, 3)}';
}

class CircadianDetail extends StatefulWidget {
  final CircadianData? data;
  const CircadianDetail({super.key, this.data});

  @override
  State<CircadianDetail> createState() => _CircadianDetailState();
}

class _CircadianDetailState extends State<CircadianDetail> with RevisionReload {
  CircadianData? _d;
  bool _loading = true;

  /// Whether the non-parametric battery is unfolded. Off by default.
  bool _showStrength = false;

  /// SLP-08 — whether the two rows naming the least-alike pair of nights are
  /// unfolded. Off by default: the regularity index is one row today, and the
  /// decomposition of it is two more that nobody asked for until they did.
  bool _showNights = false;

  @override
  void initState() {
    super.initState();
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Handed its data (golden, gallery): nothing behind it to read again.
  /// Otherwise a new cross-day rollup is read again, which is also what clears
  /// the "As of" label.
  @override
  bool get revisionReloads => widget.data == null;

  @override
  void reload() => _load();

  /// Set while the page shows the last stored result, stale, while the warmer
  /// prepares a fresh one; null once the fresh one has replaced it.
  DateTime? _cachedAt;

  /// Opens from the stored `circadian` artifact: a fresh one is drawn as is,
  /// with no day bundle read on this isolate. With none, the page is the shell
  /// and an InlineLoading, the warm is requested, and the result is drawn when
  /// it lands (the warm moves the revision, which reads again). Nothing is
  /// computed here. A stale stored one is drawn under an "As of" label
  /// meanwhile.
  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final warm = warmRequesterOf(context);
    final t = beginRead(#circadian);
    const key = 'circadian';
    try {
      final art = await LastResultCache.instance.loadWarmed<Map<String, dynamic>>(
        key,
        signature: () => repo.artifactSignature(key),
        warm: () => warm == null ? Future<void>.value() : warm(key),
        onLast: (hit) {
          if (!stillNewest(#circadian, t) || _d != null) return;
          setState(() => (
                _d = CircadianData.fromArtifact(hit.value),
                _cachedAt = hit.cachedAt,
                _loading = false,
              ));
        },
      );
      if (!stillNewest(#circadian, t) || art == null) return;
      setState(() => (
            _d = CircadianData.fromArtifact(art),
            _cachedAt = null,
            _loading = false,
          ));
    } catch (_) {
      if (stillNewest(#circadian, t)) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final d = _d ?? const CircadianData();
    final drawn = d.actogram.where((e) => e != null).length;

    return detailScaffold(c, l?.circadianDetailTitle ?? 'Body clock', [
      if (_loading && _d == null) ...[
        const SizedBox(height: S.x4),
        const InlineLoading(),
      ] else ...[
        // Chronotype, jet lag, regularity and the rhythm battery all come off
        // the cross-day rollup, so the label follows that step, not a day.
        if (_cachedAt case final at?)
          Padding(
              padding: const EdgeInsets.only(bottom: S.x2),
              child: AsOfLabel(at: at))
        else
          AsOfHold(
            shown: d,
            asOf: (recalc) => asOfFor(
                shownDay: null,
                computedAt: d.computedAt,
                recalc: recalc,
                dependsOnCrossDay: true),
            builder: (c, at) => Padding(
                padding: const EdgeInsets.only(bottom: S.x2),
                child: AsOfLabel(at: at)),
          ),
        if (drawn == 0)
          StatusCard(
            l?.circadianDetailNoNightsTitle ?? 'No nights to plot yet',
            l?.circadianDetailNoNightsBody ?? '0 nights scored.',
            fix: l?.circadianDetailNoNightsFix ?? 'Wear the band overnight',
            icon: LucideIcons.calendarClock,
          )
        else
          Surface(
            child: ChartFrame(
              title: l?.circadianDetailSleepTitle ?? 'Sleep, night by night',
              // Hour of day is what the vertical axis IS. The old card replaced
              // the axis with a sentence describing it.
              unit: 'hour of day',
              height: 190,
              yAxis: AxisSpec(
                  min: 0,
                  max: 24,
                  ticks: 3,
                  // Rows run noon → noon, so 0 and 24 are both midday and 12 is
                  // midnight — read straight off the anchor the columns use.
                  format: (v) => clock(((12 + v) * 60).round())),
              xLabels: d.labels.isEmpty
                  ? const []
                  : [d.labels.first, d.labels.last],
              legend: [(l?.circadianDetailAsleep ?? 'Asleep', C.indigo)],
              footnote: l?.circadianDetailSleepFootnote(drawn) ??
                  '$drawn night${drawn == 1 ? '' : 's'}, one column each. '
                      'Darker is more of that hour asleep.',
              // A grid: the finger selects the night (column) it is over. Each
              // column is 24 hourly shares of that hour asleep, so the sum is
              // the hours asleep that the shading adds up to. A night with no
              // column is a night that was not recorded.
              child: ChartScrub(
                label: l?.circadianDetailSleepTitle ?? 'Sleep, night by night',
                mode: ChartScrubMode.nearest,
                // A night with no column was not recorded: the "Not recorded"
                // entry, only when there is one.
                gaps: hasChartGaps([
                  [for (final col in d.actogram) col == null ? null : 1.0]
                ], trailing: true),
                time: (at) {
                  final i = ChartScrub.slotAt(d.actogram.length, at, bars: true);
                  return i < d.labels.length ? d.labels[i] : null;
                },
                keys: [
                  ChartKey(
                    l?.circadianDetailAsleep ?? 'Asleep',
                    C.indigo,
                    (at) {
                      final n = d.actogram.length;
                      if (n == 0) return null;
                      final col = d.actogram[ChartScrub.slotAt(n, at, bars: true)];
                      if (col == null) return null;
                      final asleep = col
                          .where((v) => v.isFinite)
                          .fold<double>(0, (a, v) => a + v.clamp(0.0, 1.0));
                      return axisHm(asleep * 60);
                    },
                    latest: () {
                      final last = d.actogram.lastIndexWhere((col) => col != null);
                      return last < 0 ? null : (last + .5) / d.actogram.length;
                    }(),
                  ),
                ],
                child: CustomPaint(
                  size: Size.infinite,
                  painter: Actogram(d.actogram, p.on(C.indigo)),
                ),
              ),
            ),
          ),

        // SLP-08 rides in this section's action, so the screen gains a tap
        // rather than two permanent rows.
        Section(
          l?.circadianDetailYourRhythm ?? 'Your rhythm',
          _rhythm(c, p, d),
          action: d.sriPairs.isEmpty || d.regularity.value == null
              ? null
              : (_showNights
                  ? (l?.circadianDetailHide ?? 'Hide')
                  : (l?.circadianDetailWhichNights ?? 'Which nights')),
          onAction: d.sriPairs.isEmpty || d.regularity.value == null
              ? null
              : () => setState(() => _showNights = !_showNights),
        ),

        // MIND-11 sits directly under the measured rhythm because it is built
        // on it — and directly above the battery it borrows the acrophase from.
        if (_forecast(c, p, d) case final f?)
          Section(l?.circadianDetailTodayPredicted ?? 'Today, predicted', f),

        // COLLAPSED BY DEFAULT, and that is how the screen paid for the card
        // above. Interdaily stability, intradaily variability, relative
        // amplitude and an adjusted R² are density-3 numbers that were sitting
        // at density 2 with eight rows and no tap between them and the reader.
        // Nothing is lost: the section, its title and its own empty state are
        // unchanged one tap away.
        Section(
          l?.circadianDetailRhythmStrength ?? 'Rhythm strength',
          _showStrength ? _strength(c, p, d) : const SizedBox.shrink(),
          action: _showStrength
              ? (l?.circadianDetailHide ?? 'Hide')
              : (l?.circadianDetailShow ?? 'Show'),
          onAction: () => setState(() => _showStrength = !_showStrength),
        ),

        // The social-jetlag InsightCard that used to sit here restated three
        // rows of the table above it as a sentence. Its one extra fact — the
        // DIRECTION, which is the sign of free minus work and not the unsigned
        // magnitude the card used to assert "later" from — is on the Social
        // jetlag row itself now, and the night counts are beside it. One card
        // off, so the hourly row below can go on.
        Section(l?.circadianDetailWhenStill ?? 'When you are still',
            _stillness(c, p, d)),
      ],
    ]);
  }

  String _hm(num hours) {
    final m = (hours * 60).round();
    return m < 60 ? '${m}m' : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }

  /// CV-09 — daytime HRV by hour of day, motion-gated.
  ///
  /// THE GATE IS THE FEATURE. The estimator pairs only beats whose own second
  /// was still — a real gravity vector, ENMO under that strap family's quiet
  /// cut — so a bin of walking cannot enter as low variability. An unknown
  /// strap family has no cut we can stand behind and the whole block refuses
  /// rather than borrowing gen4's.
  ///
  /// IT IS NOT STRESS, and the copy has to survive being read by someone who
  /// wants it to be: posture, digestion, temperature, talking, caffeine and a
  /// warm room move this as much as anything psychological. So: a weekly
  /// median and never today's, no colour, no band, no verdict, and an hour
  /// with too few quiet stretches behind it is absent rather than drawn faint.
  Widget _stillness(BuildContext c, P p, CircadianData d) {
    final l = AppLocalizations.of(c);
    final have = [for (final v in d.hourly) ?v];
    if (have.isEmpty) {
      return StatusCard(
        l?.circadianDetailNoStillTitle ?? 'No still moments to read yet',
        d.hourlyNote?.isNotEmpty == true
            ? d.hourlyNote!
            : (l?.circadianDetailNoStillBody(d.hourlyDays) ??
                'This reads beat timing only from the seconds you were not '
                    'moving, and the last '
                    '${d.hourlyDays} day${d.hourlyDays == 1 ? '' : 's'} had '
                    'too few of them to build an hour from.'),
        icon: LucideIcons.activity,
      );
    }
    final axis = AxisSpec.of(have, ticks: 3, floor: 0, format: axisInt);
    final drawn = d.hourly.where((v) => v != null).length;
    // The per-hour depth, as a range. A bar chart has nowhere to print 24
    // counts and "how many quiet stretches is this hour?" is the question that
    // decides whether an hour means anything.
    final counts = [
      for (var h = 0; h < d.hourly.length && h < d.hourlyN.length; h++)
        if (d.hourly[h] != null) d.hourlyN[h],
    ]..sort();
    final lo = counts.isEmpty ? 0 : counts.first;
    final hi = counts.isEmpty ? 0 : counts.last;
    return Surface(
      child: ChartFrame(
        title: l?.circadianDetailStillnessTitle ??
            'Beat-to-beat variability while still',
        unit: 'ms',
        height: 120,
        yAxis: axis,
        // The row is 24 hours of the local clock, so both edges and the middle
        // are wall-clock times rather than positions in an array.
        xLabels: [clock(0), clock(12 * 60), clock(23 * 60)],
        series: d.hourly,
        footnote: l?.circadianDetailStillnessFootnote(lo, hi, d.hourlyDays, drawn) ??
            'Each hour is the middle value of $lo–$hi five-minute '
                'stretches you were actually still, over the last '
                '${d.hourlyDays} day${d.hourlyDays == 1 ? '' : 's'}. Today alone is never used. $drawn of 24 hours had at least three '
                'stretches; the rest are blank. Not a stress score: sitting up, '
                'a warm room or a coffee moves it just as much.',
        child: ChartScrub(
          label: l?.circadianDetailStillnessTitle ??
              'Beat-to-beat variability while still',
          // 24 bars, one per local hour; an hour without three stretches is
          // blank on the chart and reads "No data here".
          gaps: hasChartGaps([d.hourly], trailing: true),
          time: (at) => ChartScrub.clock(
              ChartScrub.slotAt(d.hourly.length, at, bars: true) * 60),
          keys: [
            ChartKey.slots('HRV while still (ms)', p.ink3, d.hourly,
                (h, v) => '${v.round()} ms',
                bars: true),
          ],
          child: CustomPaint(
            size: Size.infinite,
            // Uncoloured. A hue here would be a verdict about an hour of your
            // day, and there is no verdict available.
            painter: Bars(d.hourly, p.ink3, axis: axis, t: animate(c, 1)),
          ),
        ),
      ),
    );
  }

  /// MIND-11 — the shape of today, and the window it bottoms out in.
  ///
  /// NO NUMBER LEAVES THIS CARD. Not a score, not a percentage, not an axis
  /// tick: the chart is drawn without a y axis and the frame is handed no series
  /// to read aloud, because the only quantity here is a unitless curve
  /// normalised inside its own day and any figure taken off it would be the
  /// thing that gets screenshotted and quoted back. What the card publishes is a
  /// shape and a named two-hour window, which is the resolution a group model
  /// fitted to laboratory sleep restriction actually supports.
  ///
  /// The safety refusal is COPY ON THE CARD, not a note in a file. And the card
  /// is absent — not empty, not a placeholder — whenever the night was missing
  /// or unjudged: the analytics gate refuses rather than assuming eight hours,
  /// and this returns null rather than explaining an absence nobody asked about.
  Widget? _forecast(BuildContext c, P p, CircadianData d) {
    final l = AppLocalizations.of(c);
    final v = d.alertness.value;
    if (v == null) return null;
    final assumedPhase = d.cosinorV['acrophase_hours'] == null;
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ChartFrame(
          title: l?.circadianDetailForecastTitle ??
              'Predicted alertness curve for today',
          // There is no unit. Saying so is more honest than borrowing one, and
          // the frame renders it in the slot a unit would have occupied.
          unit: 'shape only',
          height: 96,
          xLabels: [
            _hourClock(v.startHour),
            _hourClock(v.startHour + 9),
            _hourClock(v.startHour + 18),
          ],
          // No `series:`. A shape has no reading; handing the frame one would
          // have it speak numbers off a curve that deliberately has none.
          footnote: l?.circadianDetailForecastFootnote ??
              'The curve has no scale. Read its shape only.',
          // The readout keeps the card's rule: a time and, inside the named
          // window, that it is the flattest stretch. No figure comes off a
          // curve that has no scale. The span is the 0 / +9 / +18 h the x
          // labels above print.
          child: ChartScrub(
            label: l?.circadianDetailForecastTitle ??
                'Predicted alertness curve for today',
            gaps: hasChartGaps([v.shape]),
            time: (at) => _hourClock(v.startHour +
                18 * ChartScrub.slotAt(v.shape.length, at) / (v.shape.length - 1)),
            keys: [
              ChartKey.slots(
                  'Predicted alertness',
                  p.ink3,
                  v.shape, (i, _) {
                final h = v.startHour + 18 * i / (v.shape.length - 1);
                final inTrough = h >= v.troughStartHour && h <= v.troughEndHour;
                return inTrough ? 'Flattest stretch' : 'Shape only';
              }),
            ],
            child: CustomPaint(
              size: Size.infinite,
              // p.ink3, like every other mark on this screen that is not a
              // verdict. A colour would make the trough a warning.
              painter: LineChart(v.shape, p.ink3,
                  fill: false, t: animate(c, 1)),
            ),
          ),
        ),
        const SizedBox(height: S.x3),
        Text(
          l?.circadianDetailTroughText(
                v.troughLabel,
                _hourClock(v.troughStartHour),
                _hourClock(v.troughEndHour),
              ) ??
              'The flattest stretch lands in ${v.troughLabel}, around '
                  '${_hourClock(v.troughStartHour)}–${_hourClock(v.troughEndHour)}.',
          style: F.body.copyWith(color: p.ink, height: 1.5),
        ),
        const SizedBox(height: S.x3),
        Text(
          '${l?.circadianDetailPredictionDisclaimer ?? 'This is a prediction, not a reading. Nothing on the band measures '
              'how alert you are, and it knows last night and nothing else — a '
              'nap, coffee, or anything that happens today never reaches it.'}'
          '${assumedPhase ? ' ${l?.circadianDetailAssumedPhaseNote ?? 'The app has not calculated your own clock peak yet, so this uses an average peak.'}' : ''}',
          style: F.cap.copyWith(color: p.ink2, height: 1.6),
        ),
        const SizedBox(height: S.x3),
        Text(
          l?.circadianDetailNotADrivingCheck ??
              'Do not use it to decide whether you can drive or work a shift safely. '
              'It does not measure impairment.',
          style: F.cap.copyWith(color: p.ink2, height: 1.6),
        ),
      ]),
    );
  }

  Widget _rhythm(BuildContext c, P p, CircadianData d) {
    final l = AppLocalizations.of(c);
    final worst = d.sriPairs.isEmpty ? null : d.sriPairs.first;
    final showNights = _showNights && worst != null;
    final rows = <(String, String)>[
      if (d.chronotypeLabel.isNotEmpty)
        (l?.circadianDetailChronotype ?? 'Chronotype', d.chronotypeLabel),
      if (d.midFreeH != null)
        (l?.circadianDetailMidSleepFree ?? 'Mid-sleep, free days',
            _hourClock(d.midFreeH)),
      if (d.midWorkH != null)
        (l?.circadianDetailMidSleepWork ?? 'Mid-sleep, working days',
            _hourClock(d.midWorkH)),
      // `abs_hours` is UNSIGNED. Whether the free-day clock runs later or
      // earlier is the sign of free minus work; the card that used to say
      // "later" read it off the magnitude.
      if (d.jetlag.value != null)
        (
          l?.circadianDetailSocialJetlag ?? 'Social jetlag',
          '${_hm(d.jetlag.value!)}'
              '${d.midFreeH == null || d.midWorkH == null ? '' : (d.midFreeH! >= d.midWorkH! ? ' ${l?.circadianDetailLater ?? 'later'}' : ' ${l?.circadianDetailEarlier ?? 'earlier'}')}',
        ),
      if (d.nFree != null && d.nWork != null)
        (l?.circadianDetailNightsCompared ?? 'Free / working nights compared',
            '${d.nFree!.round()} / ${d.nWork!.round()}'),
      if (d.regularity.value != null)
        (l?.circadianDetailRegularityIndex ?? 'Regularity index',
            '${d.regularity.value!.round()} / 100'),
      // SLP-08 — the same arithmetic, one level down. The index above is the
      // average agreement across every adjacent pair of nights; these two rows
      // name the pair that agreed least and print it on the same scale.
      if (showNights)
        (l?.circadianDetailNightsLeastAlike ?? 'Nights least alike',
            '${_shortDay(worst['prev_date'])} → ${_shortDay(worst['date'])}'),
      if (showNights)
        (l?.circadianDetailSamePairScale ?? 'That pair, same scale',
            '${(worst['sri'] as num).round()} / 100'),
    ];

    if (rows.isEmpty) {
      // No `why:`. "Takes a few weeks of both" is one reason SRI abstains and
      // it is not the one the measured run hit — `no valid epoch pairs` was,
      // on both gen5 databases, and that note was being overwritten here.
      return StatusCard.forMetric(
              l?.circadianDetailRhythmNotEstablished ??
                  'Your rhythm is not established yet',
              d.regularity) ??
          const SizedBox.shrink();
    }

    if (!showNights) return _table(p, rows);
    // The caption is not decoration. SRI's evidence is a population-level
    // mortality association; it does not license telling one person that their
    // Saturday is harming them, and two dates in a table are exactly the shape
    // that gets read as a verdict unless the card says otherwise.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _table(p, rows),
      const SizedBox(height: S.x3),
      Text(
        l?.circadianDetailPairFootnote(d.sriPairs.length) ??
            'The pair that matched least, out of ${d.sriPairs.length}. A late '
            'weekend shows up here as a schedule difference. '
            'Pairs with too little recorded on either day '
            'are left out.',
        style: F.over.copyWith(color: p.ink3, height: 1.5),
      ),
    ]);
  }

  /// The non-parametric battery and the cosinor fit, with what they were
  /// computed FROM on the same card. Hourly heart-rate means are a legitimate
  /// input to this battery, but they are not accelerometry, and the numbers
  /// mean something different because of it — so the footnote is not optional
  /// decoration, it is the unit.
  Widget _strength(BuildContext c, P p, CircadianData d) {
    final l = AppLocalizations.of(c);
    final np = d.rhythmV, cos = d.cosinorV;
    num? n(Map<String, dynamic> m, String k) => m[k] as num?;

    final rows = <(String, String)>[
      if (n(np, 'IS') != null)
        (l?.circadianDetailStability ?? 'Day-to-day stability',
            n(np, 'IS')!.toStringAsFixed(2)),
      if (n(np, 'IV') != null)
        (l?.circadianDetailFragmentation ?? 'Hour-to-hour fragmentation',
            n(np, 'IV')!.toStringAsFixed(2)),
      if (n(np, 'RA') != null)
        (l?.circadianDetailAmplitude ?? 'Relative amplitude',
            n(np, 'RA')!.toStringAsFixed(2)),
      if (n(np, 'm10_start_epoch') != null)
        (l?.circadianDetailM10Start ?? 'Highest-HR 10 hours start',
            _hourClock(n(np, 'm10_start_epoch'))),
      if (n(np, 'l5_start_epoch') != null)
        (l?.circadianDetailL5Start ?? 'Lowest-HR 5 hours start',
            _hourClock(n(np, 'l5_start_epoch'))),
      if (n(cos, 'acrophase_hours') != null)
        (l?.circadianDetailRhythmPeak ?? 'Rhythm peak',
            _hourClock(n(cos, 'acrophase_hours'))),
      if (n(cos, 'amplitude') != null)
        (l?.circadianDetailPeakSwing ?? 'Peak-to-mean swing',
            '${n(cos, 'amplitude')!.toStringAsFixed(1)} bpm'),
      if (n(cos, 'r2_adj') != null)
        (l?.circadianDetailFitCurve ?? 'Fit to a 24 h curve',
            n(cos, 'r2_adj')!.toStringAsFixed(2)),
    ];

    if (rows.isEmpty) {
      return StatusCard.forMetric(
              l?.circadianDetailStrengthNotMeasured ??
                  'Rhythm strength is not measured yet',
              d.rhythm,
              unit: 'days',
              why: l?.circadianDetailStrengthWhy ??
                  'Needs consecutive days with all 24 hours recorded.') ??
          const SizedBox.shrink();
    }

    final used = (d.coverage['days_used'] as num?)?.round();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _table(p, rows),
      const SizedBox(height: S.x3),
      Text(
        used == null
            ? (l?.circadianDetailStrengthFootnoteUnknown ??
                'From a run of days with every hour of heart rate recorded. '
                'The hours shown have your highest and lowest heart rate.')
            : (l?.circadianDetailStrengthFootnoteKnown(used) ??
                'From $used fully-recorded day${used == 1 ? '' : 's'} of heart rate. The hours shown have your highest and '
                'lowest heart rate.'),
        style: F.over.copyWith(color: p.ink3, height: 1.5),
      ),
    ]);
  }

  Widget _table(P p, List<(String, String)> rows) => Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(color: p.line, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: Row(children: [
                Expanded(
                    child:
                        Text(rows[i].$1, style: F.body.copyWith(color: p.ink))),
                const SizedBox(width: S.x3),
                // Flexible, like every other two-column row in the app: at 3.1x
                // text the label wraps inside its Expanded and the value's
                // natural width then runs 400 pt off the right edge. This
                // overflowed on the rows that were already here — "Regularity
                // index / 62 / 100" is enough on its own — so it is not the
                // SLP-08 rows that need it, it is the table.
                Flexible(
                  child: Text(rows[i].$2,
                      textAlign: TextAlign.right,
                      style: F.body
                          .copyWith(color: p.ink2, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ],
        ]),
      );
}
