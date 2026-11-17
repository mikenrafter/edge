import '../../l10n/decimal_text.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart' show whyFromNote;
import '../screens/rhr_annotations.dart';
import '../screens/home_screen.dart';
import '../screens/metric_detail.dart';
import '../ui2.dart';
import 'catalogue.dart' show zonesWhy;
import 'zones.dart' show ZonesDetail;



// DAY STRAIN — when the day's effort actually happened.
//
// `getDayStrain` was fully implemented and called by nothing. Everything drawn
// here was already computed and persisted: `series.strain_curve` (one point per
// WAKE MINUTE), the zone minutes, and `max_hr_used` — the ceiling the pipeline
// actually integrated against, printed rather than laundered into the score.
//
// The CURVE leads. The 0–21 is a summary of the curve, not the other way round:
// two days can land on the same number with completely different shapes, and
// the shape is the thing you can act on.
//
// What this screen deliberately does NOT draw:
//   * CTL/ATL/TSB. That is a fortnight of history and it already has a card one
//     tap away on the Workout tab. A day screen repeating it is noise.
//   * the resting heart rate TRIMP was anchored on. `getDayHeart`'s
//     `resting_hr` is now that same nocturnal number (`scalars.rhr` no longer
//     falls back to daytime HR), so it COULD be printed — it just does not earn
//     a line on a day screen whose subject is the curve. Naming the input in a
//     sentence is enough.




/// Below this the day is not comparable to a full one and the screen says so.
/// Wear coverage is a percentage of the whole day, so a normal night off the
/// wrist already costs ~30 points — this is "most of the waking day", not
/// "nearly all of it".
const _lowCoveragePct = 60;

/// The trace, the score, and everything needed to say what the score is made
/// of. Every field is nullable: a day the band never saw renders its absence.
class DayStrainData {
  /// The local day the curve actually came from. `getDayStrain` falls back to
  /// the last settled bundle while today is still deriving, so this is read off
  /// the curve's own timestamps rather than off the label we asked for.
  final DateTime? day;

  /// One slot per minute of [day], null where nothing was recorded. A compacted
  /// curve under a 00:00–24:00 axis draws a sync gap as though it were measured.
  final List<double?> curve;

  final double? strain;
  final int? olderVersion;
  final String? olderReason;

  /// Five zone minutes, or null when the day banked no split.
  final List<int>? zoneMin;

  /// The HR ceiling the pipeline integrated against — `max_hr_used`, the same
  /// number the maths saw.
  final num? maxHrUsed;

  /// TS-04 — which anchors THIS day's zone bars were binned on: 'karvonen'
  /// (observed ceiling + measured resting HR), 'observed' (measured ceiling
  /// only) or 'tanaka' (the age estimate). The bar's footnote states what the
  /// bar IS, rather than what it usually is.
  final String? zoneSource;
  final num? zoneMaxHr;

  /// The five lower zone edges, in bpm, of the set this day was binned with.
  final List<num>? zoneLowerBpm;

  final int? peakHr, wornMin, coveragePct;

  /// WHY the day has no strain, as the bundle said it — never a sentence
  /// written on this screen. Null means nothing came back with the absence, and
  /// the screen then says exactly that.
  final String? note;

  final List<ChartAnnotation> rhrMarks;

  const DayStrainData({
    this.day,
    this.rhrMarks = const [],
    this.curve = const [],
    this.strain,
    this.olderVersion,
    this.olderReason,
    this.zoneMin,
    this.maxHrUsed,
    this.zoneSource,
    this.zoneMaxHr,
    this.zoneLowerBpm,
    this.peakHr,
    this.wornMin,
    this.coveragePct,
    this.wearAsOf,
    this.note,
    this.days = const [],
  });

  bool get hasCurve => curve.any((v) => v != null);

  static Future<DayStrainData> load(LocalRepository repo, {String? forDay}) async {
    final daysRead = repo.availableDays();
    final flagsRead = loadRhrAnnotations(repo);
    final asked = forDay ?? todayLabel();
    final s = await repo.getDayStrain(asked);
    final days = await daysRead;
    if (s.isEmpty) return DayStrainData(days: days);

    final pts = <(int, double)>[
      for (final e in (s['curve'] as List? ?? const []))
        if (e is Map && e['t'] is num && e['v'] is num)
          ((e['t'] as num).toInt(), (e['v'] as num).toDouble()),
    ];

    final (day, grid) = gridCurve(pts);

    // Wear for THE DAY THE CURVE CAME FROM, not the day we asked for — both
    // reads fall back the same way, so asking for the resolved label is what
    // keeps the coverage figure and the trace describing one day.
    //
    // Read even when there is NO curve, which it did not used to be. Whether
    // the band saw the day is what decides if "wear the band through the day"
    // is an instruction or an insult, and a day with no strain is exactly the
    // day that question gets asked on.
    Map<String, dynamic> wear = const {};
    try {
      wear = await repo.getDayWear(day == null ? asked : dayLabelOf(day));
    } catch (_) {
      wear = const {};
    }

    final z = s['zones'];
    final zoneMin = z is Map &&
            [for (var i = 1; i <= 5; i++) z['z$i']].every((v) => v is num)
        ? [for (var i = 1; i <= 5; i++) (z['z$i'] as num).toInt()]
        : null;

    final hr = s['hr'];
    return DayStrainData(
      rhrMarks: await flagsRead,
      day: day,
      curve: grid,
      strain: (s['strain'] as num?)?.toDouble(),
      olderVersion: s['strain'] is num && s['from_older_version'] is Map && (s['from_older_version'] as Map)['strain'] is Map ? (((s['from_older_version'] as Map)['strain'] as Map)['version'] as num?)?.toInt() : null,
      olderReason: s['from_older_version'] is Map && (s['from_older_version'] as Map)['strain'] is Map ? (((s['from_older_version'] as Map)['strain'] as Map)['reason']?.toString()) : null,
      zoneMin: zoneMin,
      maxHrUsed: s['max_hr_used'] as num?,
      zoneSource: s['zone_source'] as String?,
      zoneMaxHr: s['zone_max_hr'] as num?,
      zoneLowerBpm: switch (s['zone_lower_bpm']) {
        final List e when e.length == 5 && e.every((v) => v is num) =>
          e.cast<num>(),
        _ => null,
      },
      peakHr: hr is Map ? (hr['max'] as num?)?.toInt() : null,
      wornMin: (wear['worn_min'] as num?)?.toInt(),
      coveragePct: (wear['coverage_pct'] as num?)?.toInt(),
      wearAsOf: (wear['as_of'] as num?)?.toInt(),
      // The headline absence's reason, at the top level of the payload — the
      // same string as `absent.strain`.
      note: s['note'] as String?,
      days: days,
    );
  }


  /// When [wornMin] and [coveragePct] were last computed, if an earlier
  /// derive's wear was carried forward (#450). Null when they are current.
  final int? wearAsOf;

  /// The days that derived, NEWEST FIRST, for the day stepper. Empty when the
  /// screen was handed its data (goldens) or the list could not be read; with
  /// fewer than two the stepper draws nothing.
  final List<String> days;

  /// The local label of the day this screen shows (today when [day] is null).
  String get shownDay => day == null ? todayLabel() : dayLabelOf(day!);

  /// Lays the curve's epoch-second points onto the fixed 00:00–24:00 axis,
  /// one slot per WALL-CLOCK minute of the first point's local day.
  ///
  /// The slot is the local `hour * 60 + minute`, not minutes elapsed since
  /// midnight: a fall-back day is 1500 minutes long and a spring-forward day
  /// 1380, so elapsed minutes pushed everything after the transition an hour
  /// off the axis labels, and on fall-back cut 23:00–24:00 — the end of a
  /// cumulative curve, which left the trace short of the day strain printed
  /// under it. On the repeated hour the later sample wins (points arrive in
  /// time order), which is the right one for a running total.
  static (DateTime?, List<double?>) gridCurve(List<(int, double)> pts) {
    if (pts.isEmpty) return (null, const <double?>[]);
    final first = DateTime.fromMillisecondsSinceEpoch(pts.first.$1 * 1000);
    final day = DateTime(first.year, first.month, first.day);
    final out = List<double?>.filled(1440, null);
    for (final p in pts) {
      final t = DateTime.fromMillisecondsSinceEpoch(p.$1 * 1000);
      if (t.year != day.year || t.month != day.month || t.day != day.day) {
        continue;
      }
      out[t.hour * 60 + t.minute] = p.$2;
    }
    return (day, out);
  }
}


class DayStrainDetail extends StatefulWidget {
  /// Preloaded, for goldens. Null means read the repo on open.
  final DayStrainData? data;
  const DayStrainDetail({super.key, this.data, this.day});

  @override
  State<DayStrainDetail> createState() => _DayStrainDetailState();


  /// The day to read, as a local label. Null means today.
  final String? day;
}

class _DayStrainDetailState extends State<DayStrainDetail> {
  DayStrainData? _d;
  bool _loading = true;
  bool _hasWear = false;

  @override
  void initState() {
    super.initState();
    _day = widget.day;
    _shownDay = widget.day;
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final day = _day;
      final wearRead = repo.getDayWear(day ?? todayLabel()).then((wear) {
        if (mounted && token == _loadToken) {
          setState(() => _hasWear = (wear['worn_min'] as num? ?? 0) > 0);
        }
      });
      final (_, d) = await (wearRead, DayStrainData.load(repo, forDay: day)).wait;
      if (mounted && token == _loadToken) setState(() => (_d = d, _shownDay = day, _loading = false));
    } catch (_) {
      // A step that could not be read stays on the day whose data is still
      // on screen, so the stepper never names a day the curve is not.
      if (mounted && token == _loadToken) {
        setState(() => (_day = _shownDay, _loading = false));
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final d = _d ?? const DayStrainData();
    // DayNav is always present, including the one-day and pending cases.
    // It owns the date; a second changing date line would move the title.

    return detailScaffold(
      c,
      l?.dayStrainTitle ?? 'Day strain',
      [
        ...dayNavRow(_day ?? d.shownDay, d.days, _goDay),
        if (_loading && _d != null)
          const Center(child: PendingMark())
        else PendingContent(
        memoryKey: 'day-strain:body',
        pending: _loading && _d == null,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ..._trace(p, l, d),
          Section(l?.dayStrainInputsSection ?? 'What this is made of',
              _inputs(p, l, d)),
          ..._zones(p, l, d),
        ])),
      ],

    );
  }

  // ── the curve, and only then the number ────────────────────────────────────
  List<Widget> _trace(P p, AppLocalizations? l, DayStrainData d) {
    if (!d.hasCurve && !_loading) {
      // THE BUNDLE'S REASON, or none. This card used to state one — "it needs a
      // resting heart rate from a scored night and a day the band was on your
      // wrist" — and it printed that on a day with a scored night (RHR 56.8)
      // and 89 % wear, because the sentence was written here rather than
      // handed over. A cause the screen did not receive is a guess.
      final why = whyFromNote(d.note, unit: 'days');
      // And "wear the band" is only an instruction on a day the band did not
      // see. Offered on a day it was on the wrist all along it is worse than
      // no button, because the user spends trust doing it.
      final saw = (d.wornMin ?? 0) > 0 || (d.coveragePct ?? 0) > 0;
      // A day CAN carry a strain with no trace behind it: `backfillStrainScale`
      // rescales the stored headline onto the current scale and DROPS the
      // per-minute curve, which cannot be rescaled with it. Measured on
      // whoop-4, that is 6 of 17 days — and on every one of them this card said
      // "this day produced no strain" directly above a day that produced 10.8.
      // The absence is the TRACE, so that is what the card is allowed to name;
      // why the trace is not stored is not something this screen was told.
      final s = d.strain;
      return [
        StatusCard(
          s == null
              ? (l?.dayStrainNoTraceTitle ?? 'No strain trace for this day')
              : (l?.dayStrainNoMinuteTraceTitle ??
                  'No minute-by-minute trace for this day'),
          s == null
              ? why ??
                  (l?.dayStrainNoReasonBody ?? 'No reading.')
              : (l?.dayStrainScoredNoTraceBody(displayFixed(s, 1)) ??
                  'Day strain is ${displayFixed(s, 1)}. The minute-by-minute detail isn\'t stored.'),
          fix: (s == null && !saw)
              ? (l?.dayStrainWearBandFix ?? 'Wear the band through the day')
              : '',
          icon: LucideIcons.trendingUp,
        ),
        if (s != null && d.olderVersion != null) ...[
          OlderVersionMark(id: 'strain', version: d.olderVersion, reason: d.olderReason, speak: false),
          OlderVersionNote(id: 'strain', version: d.olderVersion, reason: d.olderReason),
        ],
      ];
    }
    // The whole 0–21 scale the header names, so the ticks and the header
    // agree and two days can be compared by eye.
    const axis = AxisSpec(min: 0, max: 21, ticks: 4, format: axisInt);
    final drawn = d.curve.where((v) => v != null).length;
    return [
      Surface(
        child: Column(children: [
          ChartFrame(
              key: const ValueKey('day-strain-primary'),
              panel: _loading && _d == null
                  ? ChartKeyReadout(
                      time: '—',
                      cells: [
                        ChartCell('Strain (0–21)', p.on(C.purple)),
                        const ChartCell(
                          ChartKeyReadout.notRecorded,
                          null,
                          hasValue: false,
                        ),
                      ],
                    )
                  : null,
              title: l?.dayStrainChartTitle ?? 'Strain through the day',
            unit: '0–21',
            height: 170,
            yAxis: axis,
            xLabels: const ['00:00', '12:00', '24:00'],
            series: d.curve,
            footnote: l?.dayStrainChartFootnote(drawn) ??
                'Effort above your usual waking pace, from $drawn recorded minutes.',
            child: ChartScrub(
              label: l?.dayStrainChartTitle ?? 'Strain through the day',
              // One slot per minute of the local day, as the grid was built.
              gaps: hasChartGaps([d.curve]),
              time: (at) =>
                  ChartScrub.clock(ChartScrub.slotAt(d.curve.length, at)),
              keys: [
                ChartKey.slots('Strain (0–21)', p.on(C.purple), d.curve,
                    (i, v) => displayFixed(v, 1)),
              ],
              child: CustomPaint(
                size: Size.infinite,
                painter: LineChart(d.curve, p.on(C.purple),
                    axis: axis, t: animate(context, 1)),
              ),
            ),
          ),
          if (d.strain != null || d.peakHr != null || d.wornMin != null) ...[
            const SizedBox(height: S.x4),
            InlineMetrics([
              if (d.strain != null)
                (l?.dayStrainTitle ?? 'Day strain', displayFixed(d.strain!, 1),
                    C.purple),
              if (d.peakHr != null)
                (l?.dayStrainPeakHr ?? 'Peak HR', '${d.peakHr} bpm', C.red),
              if (d.wornMin != null)
                // #450: a carried figure says where it stops, or a frozen
                // morning reads as the whole day so far.
                (
                  d.wearAsOf == null
                      ? (l?.dayStrainWorn ?? 'Worn')
                      : (l?.dayStrainWornAsOf(
                              asOfText(d.wearAsOf!, d.shownDay, l)) ??
                          'Worn as of ${asOfText(d.wearAsOf!, d.shownDay, l)}'),
                  '${d.wornMin} min',
                  C.teal,
                ),
            ]),
            if (d.olderVersion != null) ...[
              OlderVersionMark(id: 'strain', version: d.olderVersion, reason: d.olderReason, speak: false),
              OlderVersionNote(id: 'strain', version: d.olderVersion, reason: d.olderReason),
            ],
          ],
        ],
        ),
      ),
      DayRhrNotice(d.rhrMarks, d.day == null ? null : dayLabelOf(d.day!),
      ),
      if (d.coveragePct != null && d.coveragePct! < _lowCoveragePct)
        Padding(
          padding: const EdgeInsets.only(top: S.x4),
          child: StatusCard(
            l?.dayStrainLowCoverageTitle(d.coveragePct!) ??
                'The band saw ${d.coveragePct}% of this day',
            l?.dayStrainLowCoverageBody ??
                'Strain counts recorded minutes only, so a partly worn day reads lower.',
            icon: LucideIcons.watch,
          ),
        ),
    ];
  }

  // ── where the effort sat ───────────────────────────────────────────────────
  List<Widget> _zones(P p, AppLocalizations? l, DayStrainData d) {
    final z = d.zoneMin;
    if (z == null && _loading && _hasWear) {
      return [
        Section(
          l?.dayStrainTimeInZonesSection ?? 'Time in zones',
          Surface(
            child: ZoneRows(
              List.filled(5, 0.0),
              title: l?.dayStrainZonesChartTitle ?? 'Time in zones',
            ),
          ),
        ),
      ];
    }
    if (z == null) return const [];
    final total = z.fold<int>(0, (a, b) => a + b);
    if (total <= 0) return const [];
    return [
      Section(
        l?.dayStrainTimeInZonesSection ?? 'Time in zones',
        Surface(
          child: ZoneRows(
            [for (final v in z) v.toDouble()],
            lowerBpm: d.zoneLowerBpm,
            title: l?.dayStrainZonesChartTitle ?? 'Time in zones',
            // TS-03/TS-04 — the edges, and where THIS day's came from. Stated
            // per day, not as a standing hedge: the same screen tomorrow can be
            // banded on a measured ceiling, and a footnote that still said
            // "estimated from your age" would then be false. The 28-day
            // distribution is NOT here — it lives one tap away and is gated on
            // the same anchors (TS-05).
            footnote: zonesWhy(d.zoneSource, d.zoneMaxHr, l),
          ),
        ),
        // Progressive disclosure: this day screen gains a LINK, not a row. The
        // ceiling, the edges in bpm and the 28-day distribution are all one tap
        // behind it.
        action: l?.dayStrainHowSet ?? 'How these are set',
        onAction: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ZonesDetail())),
      ),
    ];
  }

  // ── the inputs, named ──────────────────────────────────────────────────────
  Widget _inputs(P p, AppLocalizations? l, DayStrainData d) {
    final max = d.maxHrUsed;
    return Surface(
      elevation: 0,
      color: p.card2,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: double.infinity),
        child: Text(
        [
          l?.dayStrainInputsBase ??
              'How hard your heart worked while awake, by minutes in each heart-rate zone, on a 0–21 scale.',
          if (max != null)
            l?.dayStrainInputsMaxHr(max.round()) ??
                'Based on an estimated maximum of ${max.round()} bpm.',
        ].join(' '),
        style: F.cap.copyWith(color: p.ink3, height: 1.5),
      )),
    );
  }


  /// The day being shown, as a label; null is today. Starts as the caller's
  /// and moves with the stepper.
  String? _day;

  /// The day whose data `_d` holds. A step that cannot be read returns here,
  /// not to the day the stepper named before it, which may itself have been
  /// overtaken before it loaded.
  String? _shownDay;

  // A quick second tap on the stepper starts a second load; the first can
  // finish last and must not paint the old day under the new label.
  int _loadToken = 0;

  void _goDay(String day) {
    setState(() {
      _day = day;
      _loading = true;
    });
    _load();
  }
}

