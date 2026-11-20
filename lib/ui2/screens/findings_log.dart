// OBSERVATIONS — a dated timeline of the existing health watches.
//
// Named for the card it is a history of: the Observation widget has printed
// "HEALTH OBSERVATION" over the illness card since the design system existed,
// and these six detectors are what that card is. Deliberately NOT "what
// changed", which is the nightly sweep's screen and a different question — the
// sweep measures every metric against your own trailing history, while these
// are standing watches with their own thresholds.
//
// Stored detector results and pulse episodes share one calendar-day detail.
// The focused day keeps each detector's wording, uncertainty and date.
//
// A LOG YOU GO TO, NOT A FEED THAT COMES TO YOU. notification_center.dart
// records that the in-app notifications feed was removed deliberately, because
// it duplicated the OS notification with no independent value, and Home bans
// observation cards. Both of those hold here: nothing on this screen is
// unread-marked, nothing badges a tab, nothing is dismissible, and the only
// way to it is a section on Health that you chose to open. It is a place to
// look something up, not a second place to be interrupted from.
//
// It is also DETECTION, NEVER DIAGNOSIS, all the way down. Every sentence is
// the detector's own, written once in findings.dart, and the medical-class
// entries carry the same "this is a screen, see a clinician" wording they
// carry in the notification.

// Standard day scrub and canonical rows in its detail.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../compute/findings.dart';
import '../../data/day_label.dart';
import '../../data/pulse_ep/pulse_ep_summary.dart';
import '../../pilot/pilot_flags.dart';
import 'pulse_episode.dart';
import '../../l10n/app_localizations.dart';
import '../../models/chart_point.dart';
import '../../state/clock_format.dart' show formatClockOf;
import '../ui2.dart';
import '../why_row.dart';
import '../finding_presentation.dart';
import '../observation_history.dart';
export '../finding_presentation.dart' show findingColor;
import 'home_screen.dart' show prettyDay;
import 'metric_detail.dart' show detailScaffold;

Color _ink(P p, Finding f) => p.on(findingColor(f.kind));

List<String> observationWeek(String end, int week) => [
  for (var i = 6; i >= 0; i--) dayLabelBefore(end, week * 7 + i)!,
];

class FindingsLog extends StatelessWidget {
  const FindingsLog(this.findings, {super.key, this.rhr=const [], this.today,
    this.episodes=const [], this.loadEpisodes});
  final List<Finding> findings;
  final List<ChartPoint> rhr;
  final String? today;
  final List<PulseEpisodeSummary> episodes;
  final Future<List<PulseEpisodeSummary>> Function()? loadEpisodes;
  @override Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable:PilotFlags.revision, builder:(context,_,_) => PilotFlag.observations.enabled
      ? SimplifiedFindingsLog(findings, rhr:rhr, today:today, episodes:episodes, loadEpisodes:loadEpisodes)
      : LegacyFindingsLog(findings, rhr:rhr, today:today));
}
List<Finding> uniqueObservations(List<Finding> findings) =>
  [for(final entry in observationHistory(findings, const []))
    if(entry case DailyObservation(:final finding)) finding];

class SimplifiedFindingsLog extends StatefulWidget {
  const SimplifiedFindingsLog(
    this.findings, {
    super.key,
    this.rhr = const [],
    this.today,
    this.episodes = const [],
    this.loadEpisodes,
  });
  final List<Finding> findings;
  final List<ChartPoint> rhr;
  final String? today;

  /// Metadata already loaded by Health; opening the log needs no second read.
  final List<PulseEpisodeSummary> episodes;

  /// Optional retry after a failed Health read. Called once at mount, then
  /// only on explicit retry. Failure keeps daily findings and exposes retry.
  final Future<List<PulseEpisodeSummary>> Function()? loadEpisodes;
  @override
  State<SimplifiedFindingsLog> createState() => _FindingsLogState();
}

class _FindingsLogState extends State<SimplifiedFindingsLog> {
  int _week = 0;
  String? _focus;
  late final String _end = widget.today ?? todayLabel();
  late List<PulseEpisodeSummary> _episodes = widget.episodes;
  bool _pending = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.loadEpisodes != null) _loadEpisodes();
  }

  // Owner: this state holds one episode read, independent of chart rebuilds.
  Future<void> _loadEpisodes() async {
    if (_pending) return;
    setState(() {
      _pending = true;
      _failed = false;
    });
    try {
      final episodes = await widget.loadEpisodes!();
      if (mounted) setState(() => _episodes = episodes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  void move(int delta) => setState(() {
    _week += delta;
    _focus = null;
  });
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l =
        AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final days = observationWeek(_end, _week);
    final history = observationHistory(widget.findings,
        PilotFlag.observations.enabled ? _episodes : const []);
    List<ObservationEntry> on(String day) =>
        history.where((entry) => entry.occursOn(day)).toList();
    final kinds = FindingKind.values
        .where((k) => history.any((f) => f.kind == k))
        .toList();
    final focus =
        _focus ??
        days.lastWhere((d) => on(d).isNotEmpty, orElse: () => days.last);
    final counts = [for (final day in days) on(day).length.toDouble()];
    final maximum = math.max(1, counts.reduce(math.max).toInt());
    final axisTop = maximum <= 4 ? maximum : (maximum / 2).ceil() * 2;
    final focused = on(focus);
    final focusedKinds = kinds.where((k) => focused.any((f) => f.kind == k));
    final earliest = history.fold(
      _end,
      (String d, f) => f.day.compareTo(d) < 0 ? f.day : d,
    );
    return detailScaffold(c, l.findingsLogTitle, [
      Padding(padding:const EdgeInsets.symmetric(vertical:S.x3),child:TextSlot(
        sizingText:l.observationsLoading,style:F.cap.copyWith(color:p.ink2),
        child:_pending?Semantics(liveRegion:true,child:Text(l.observationsLoading,style:F.cap.copyWith(color:p.ink2))):null)),
      if (_failed)
        TextButton(
          onPressed: _loadEpisodes,
          child: const Text('Pulse recordings could not be loaded. Try again.'),
        ),
      PendingContent(pending:_pending,child:Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: l.observationsEarlierWeek,
                  onPressed: earliest.compareTo(days.first) < 0
                      ? () => move(1)
                      : null,
                  icon: const Icon(LucideIcons.chevronLeft),
                ),
                Expanded(
                  child: Text(
                    '${prettyDay(days.first, l)} – ${prettyDay(days.last, l)}',
                    textAlign: TextAlign.center,
                    style: F.cap.copyWith(color: p.ink2),
                  ),
                ),
                IconButton(
                  tooltip: l.observationsLaterWeek,
                  onPressed: _week > 0 ? () => move(-1) : null,
                  icon: const Icon(LucideIcons.chevronRight),
                ),
              ],
            ),
            ChartFrame(
              title: l.findingsLogTitle,
              unit: l.observationsEventsUnit,
              height: _observationPlotHeight,
              yAxis: _pending || _failed
                  ? null
                  : AxisSpec(
                      min: 0,
                      max: axisTop.toDouble(),
                      ticks: maximum <= 4 ? maximum + 1 : 3,
                      format: axisInt,
                    ),
              panel: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PendingContent(
                    pending: _pending,
                    child: ChartKeyReadout(
                      time: prettyDay(focus, l),
                      timeSpan: days.map((d) => prettyDay(d, l)).toList(),
                      scrubbed: true,
                      cells: [
                        ChartCell(
                          l.observationsEventsUnit,
                          p.ink,
                          value: _failed ? null : '${focused.length}',
                        ),
                        for (final k in focusedKinds)
                          ChartCell(
                            k == FindingKind.irregularRhythm
                                ? l.observationsPulsePattern
                                : findingTitle(l, Finding(k, focus)),
                            p.on(findingColor(k)),
                            value:
                                '${focused.where((f) => f.kind == k).length}',
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: S.x2),
                  if (!_pending && !_failed && focused.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(S.x3),
                      child: Text(
                        l.observationsNoDay,
                        style: F.body.copyWith(color: p.ink2),
                      ),
                    ),
                  if (_pending)
                    PendingContent(
                      pending: true,
                      child: WhyRow(
                        id: 'pending-observation',
                        title: l.findingsLogTitle,
                        body: l.findingsLogDerivedNote,
                        color: C.red,
                        icon: LucideIcons.heartPulse,
                        fullText: true,
                      ),
                    ),
                  for (final entry in focused)
                    if (_pending &&
                        entry is DailyObservation &&
                        entry.kind == FindingKind.irregularRhythm)
                      const SizedBox.shrink()
                    else if (entry case PulseObservation(:final episode))
                      PulseEpisodeRow(
                        episode,
                        key: ValueKey('observation-episode:${episode.id}'),
                      )
                    else if (entry case DailyObservation(finding: final f))
                      Padding(
                        padding: const EdgeInsets.only(top: S.x2),
                        child: WhyRow(
                          id: 'finding:${f.kind.name}:${f.date}',
                          title:
                              '${prettyDay(f.date, l)} · ${findingTitle(l, f)}',
                          body: findingDetail(l, f),
                          color: findingColor(f.kind),
                          icon: findingIcon(f),
                          fullText: true,
                          onTap: f.kind == FindingKind.rhrShift
                              ? () => Navigator.of(c).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => RhrChangesScreen(
                                      findings: widget.findings,
                                      points: widget.rhr,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                ],
              ),
              // Slot-centred dates share the plot cells and precede its readout.
              axisFooter: Row(
                children: [
                  for (final day in days)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: S.x2),
                        child: Text(
                          day.substring(8),
                          key: ValueKey('observation-day:$day'),
                          textAlign: TextAlign.center,
                          style: F.cap.copyWith(
                            color: day == focus ? p.ink : p.ink3,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              child: ChartScrub(
                key: ValueKey('observations-week:$_week'),
                label: l.findingsLogTitle,
                step: 1 / 7,
                slots: 7,
                slotBars: true,
                snapToSlots: true,
                keys: _pending || _failed
                    ? const []
                    : [
                        ChartKey.slots(
                          l.observationsEventsUnit,
                          p.ink,
                          counts,
                          (i, v) => '${v.round()}',
                          bars: true,
                        ),
                      ],
                time: (v) =>
                    prettyDay(days[ChartScrub.slotAt(7, v, bars: true)], l),
                onChanged: (v) => setState(
                  () => _focus = days[ChartScrub.slotAt(7, v, bars: true)],
                ),
                child: PendingContent(
                  pending: _pending,
                  child: _pending
                      ? const PendingPlot(shape: PendingChartShape.bars)
                      : _DayMarkers(
                          days: days,
                          events: history,
                          top: axisTop,
                          p: p,
                        ),
                ),
              ),
            ),
          ],
        ),
      )),
      if (widget.findings.any((f) => f.kind == FindingKind.rhrShift))
        TextButton.icon(
          onPressed: () => Navigator.of(c).push(
            MaterialPageRoute<void>(
              builder: (_) => RhrChangesScreen(
                findings: widget.findings,
                points: widget.rhr,
              ),
            ),
          ),
          icon: const Icon(LucideIcons.chartLine),
          label: Text(l.rhrChangesTitle),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => Navigator.of(c).push(
            MaterialPageRoute<void>(
              builder: (_) => PulseEpisodesScreen(episodes: _episodes),
            ),
          ),
          child: const Text('Recent pulse episodes'),
        ),
      ),
      const SizedBox(height: S.x3),
      Text(
        l.findingsLogDerivedNote,
        style: F.cap.copyWith(color: p.ink3, height: 1.5),
      ),
    ]);
  }
}

const _observationPlotHeight = 130.0;

class _DayMarkers extends StatelessWidget {
  const _DayMarkers({
    required this.days,
    required this.events,
    required this.top,
    required this.p,
  });
  final List<String> days;
  final List<ObservationEntry> events;
  final int top;
  final P p;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      for (final day in days)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x2),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final kind in FindingKind.values)
                  for (final event in events.where(
                    (f) => f.occursOn(day) && f.kind == kind,
                  ))
                    SizedBox(
                      height: _observationPlotHeight / top,
                      child: Center(
                        child: Icon(
                          findingIcon(switch (event) {
                            DailyObservation(:final finding) => finding,
                            PulseObservation() => Finding(event.kind, day),
                          }),
                          size: math.min(20, _observationPlotHeight / top - 2),
                          color: p.on(findingColor(kind)),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
    ],
  );
}

class RhrChangesScreen extends StatelessWidget {
  const RhrChangesScreen({
    super.key,
    required this.findings,
    required this.points,
  });
  final List<Finding> findings;
  final List<ChartPoint> points;
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l =
        AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final byDay = {
      for (final q in points)
        if (q.v.isFinite)
          dayLabelOf(DateTime.fromMillisecondsSinceEpoch(q.t * 1000)): q.v,
    };
    final dates = {
      ...byDay.keys,
      for (final f in findings)
        if (f.kind == FindingKind.rhrShift) f.date,
    }.toList()..sort();
    final end = dates.isEmpty ? todayLabel() : dates.last;
    final start = dates.isEmpty ? end : dates.first;
    final days = <String>[];
    // Calendar labels, not elapsed 24-hour durations: DST must not move a mark.
    for (
      var day = start;
      day.compareTo(end) <= 0;
      day = dayLabelBefore(day, -1)!
    ) {
      days.add(day);
    }
    if (days.length == 1) days.insert(0, dayLabelBefore(start, 1)!);
    final values = [for (final d in days) byDay[d]];
    final axis = AxisSpec.of(
      values.whereType<double>().toList(),
      ticks: 3,
      format: (v) => '${v.round()}',
    );
    final marks = dailyAnnotations(rhrChangeAnnotations(findings, l: l), days);
    return detailScaffold(c, l.rhrChangesTitle, [
      Surface(
        child: ChartFrame(
          title: l.healthRowRestingHr,
          unit: 'bpm',
          height: 180,
          yAxis: axis,
          series: values,
          xLabels: [prettyDay(days.first, l), prettyDay(days.last, l)],
          annotations: marks.isEmpty
              ? null
              : AnnotationSet(
                  items: marks,
                  domainStart: 0,
                  domainEnd: (days.length - 1).toDouble(),
                ),
          panel: byDay.isEmpty
              ? ChartKeyReadout(
                  cells: [ChartCell(l.healthRowRestingHr, p.on(C.red))],
                )
              : null,
          footnote: byDay.isEmpty ? l.rhrNoReadings : null,
          child: ChartScrub(
            label: l.healthRowRestingHr,
            keys: [
              ChartKey.slots(
                l.healthRowRestingHr,
                p.on(C.red),
                values,
                (i, v) => '${v.round()} bpm',
              ),
            ],
            slots: days.length,
            gaps: true,
            time: (v) => prettyDay(days[ChartScrub.slotAt(days.length, v)], l),
            child: CustomPaint(
              size: Size.infinite,
              painter: LineChart(values, p.on(C.red), axis: axis, fill: false),
            ),
          ),
        ),
      ),
      const SizedBox(height: S.x3),
      for (final f in findings.where((f) => f.kind == FindingKind.rhrShift))
        Padding(
          padding: const EdgeInsets.only(bottom: S.x2),
          child: WhyRow(
            id: 'rhr:${f.date}',
            title: '${prettyDay(f.date, l)} · ${findingTitle(l, f)}',
            body: findingDetail(l, f),
            color: C.blue,
            icon: findingIcon(f),
            fullText: true,
          ),
        ),
    ]);
  }
}

/// One finding, as an icon, its title and the detector's own sentence. Public
/// because Health shows the newest one in place — the alternative was a second
/// hand-built row that would drift from this one.
class FindingRow extends StatelessWidget {
  const FindingRow(this.f, {super.key});

  final Finding f;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = _ink(p, f);
    // A view built without localizations (a bare test host) still says it in
    // English rather than not at all.
    final l =
        AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final title = PilotFlag.observations.enabled && f.kind == FindingKind.irregularRhythm
        ? 'Historical daily flag: episode recording unavailable'
        : findingTitle(l, f);
    final detail = findingDetail(l, f);
    final note = switch (f.alert) {
      final a? => a.note(l, time: formatClockOf(a.at)),
      _ => null,
    };
    return Semantics(
      label: note == null ? '$title. $detail' : '$title. $detail. $note',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: S.x1),
                child: Icon(findingIcon(f), size: 16, color: ink),
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(
                  title,
                  style: F.body.copyWith(
                    color: p.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: S.x2),
          Text(detail, style: F.cap.copyWith(color: p.ink2, height: 1.5)),
          if (note != null) ...[
            const SizedBox(height: S.x2),
            Text(note, style: F.cap.copyWith(color: p.ink3)),
          ],
        ],
      ),
    );
  }
}

class LegacyFindingsLog extends StatefulWidget {
  const LegacyFindingsLog(
    this.findings, {
    super.key,
    this.rhr = const [],
    this.today,
  });
  final List<Finding> findings;
  final List<ChartPoint> rhr;
  final String? today;
  @override
  State<LegacyFindingsLog> createState() => _LegacyFindingsLogState();
}

class _LegacyFindingsLogState extends State<LegacyFindingsLog> {
  int _week = 0;
  String? _focus;
  late final String _end = widget.today ?? todayLabel();
  List<Finding> on(String day) =>
      widget.findings.where((f) => f.date == day).toList();
  void move(int delta) => setState(() {
    _week += delta;
    _focus = null;
  });
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l =
        AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final days = observationWeek(_end, _week);
    final latest = observationWeek(_end, 0);
    final weekEvents = widget.findings
        .where((f) => latest.contains(f.date))
        .toList();
    final kinds = FindingKind.values
        .where((k) => widget.findings.any((f) => f.kind == k))
        .toList();
    final focus =
        _focus ??
        days.lastWhere((d) => on(d).isNotEmpty, orElse: () => days.last);
    final counts = [for (final day in days) on(day).length.toDouble()];
    final maximum = math.max(1, counts.reduce(math.max).toInt());
    final axisTop = maximum <= 4 ? maximum : (maximum / 2).ceil() * 2;
    final focused = on(focus);
    final focusedKinds = kinds.where((k) => focused.any((f) => f.kind == k));
    final earliest = widget.findings.fold(
      _end,
      (String d, f) => f.date.compareTo(d) < 0 ? f.date : d,
    );
    return detailScaffold(c, l.findingsLogTitle, [
      Padding(
        key: const ValueKey('observations-latest-week'),
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.observationsLatestWeek(
                prettyDay(latest.first, l),
                prettyDay(latest.last, l),
              ),
              style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: S.x2),
            if (weekEvents.isEmpty)
              Text(l.observationsNoWeek, style: F.cap.copyWith(color: p.ink2)),
            Wrap(
              spacing: S.x3,
              runSpacing: S.x2,
              children: [
                for (final k in kinds)
                  if (weekEvents.any((f) => f.kind == k))
                    Text(
                      '${weekEvents.where((f) => f.kind == k).length} · ${findingTitle(l, Finding(k, _end))}',
                      style: F.cap.copyWith(color: p.on(findingColor(k))),
                    ),
              ],
            ),
          ],
        ),
      ),
      Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: l.observationsEarlierWeek,
                  onPressed: earliest.compareTo(days.first) < 0
                      ? () => move(1)
                      : null,
                  icon: const Icon(LucideIcons.chevronLeft),
                ),
                Expanded(
                  child: Text(
                    '${prettyDay(days.first, l)} – ${prettyDay(days.last, l)}',
                    textAlign: TextAlign.center,
                    style: F.cap.copyWith(color: p.ink2),
                  ),
                ),
                IconButton(
                  tooltip: l.observationsLaterWeek,
                  onPressed: _week > 0 ? () => move(-1) : null,
                  icon: const Icon(LucideIcons.chevronRight),
                ),
              ],
            ),
            ChartFrame(
              title: l.findingsLogTitle,
              unit: l.observationsEventsUnit,
              height: _observationPlotHeight,
              yAxis: AxisSpec(
                min: 0,
                max: axisTop.toDouble(),
                ticks: maximum <= 4 ? maximum + 1 : 3,
                format: axisInt,
              ),
              panel: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ChartKeyReadout(
                    time: prettyDay(focus, l),
                    timeSpan: days.map((d) => prettyDay(d, l)).toList(),
                    scrubbed: true,
                    cells: [
                      ChartCell(
                        l.observationsEventsUnit,
                        p.ink,
                        value: '${focused.length}',
                      ),
                      for (final k in focusedKinds)
                        ChartCell(
                          findingTitle(l, Finding(k, focus)),
                          p.on(findingColor(k)),
                          value: '${focused.where((f) => f.kind == k).length}',
                        ),
                    ],
                  ),
                  const SizedBox(height: S.x2),
                  if (focused.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(S.x3),
                      child: Text(
                        l.observationsNoDay,
                        style: F.body.copyWith(color: p.ink2),
                      ),
                    ),
                  for (final f in focused)
                    Padding(
                      padding: const EdgeInsets.only(top: S.x2),
                      child: WhyRow(
                        id: 'finding:${f.kind.name}:${f.date}',
                        title:
                            '${prettyDay(f.date, l)} · ${findingTitle(l, f)}',
                        body: findingDetail(l, f),
                        color: findingColor(f.kind),
                        icon: findingIcon(f),
                        fullText: true,
                        onTap: f.kind == FindingKind.rhrShift
                            ? () => Navigator.of(c).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => RhrChangesScreen(
                                    findings: widget.findings,
                                    points: widget.rhr,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                ],
              ),
              // Slot-centred dates share the plot cells and precede its readout.
              axisFooter: Row(
                children: [
                  for (final day in days)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: S.x2),
                        child: Text(
                          day.substring(8),
                          key: ValueKey('observation-day:$day'),
                          textAlign: TextAlign.center,
                          style: F.cap.copyWith(
                            color: day == focus ? p.ink : p.ink3,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              child: ChartScrub(
                key: ValueKey('observations-week:$_week'),
                label: l.findingsLogTitle,
                step: 1 / 7,
                slots: 7,
                slotBars: true,
                snapToSlots: true,
                keys: [
                  ChartKey.slots(
                    l.observationsEventsUnit,
                    p.ink,
                    counts,
                    (i, v) => '${v.round()}',
                    bars: true,
                  ),
                ],
                time: (v) =>
                    prettyDay(days[ChartScrub.slotAt(7, v, bars: true)], l),
                onChanged: (v) => setState(
                  () => _focus = days[ChartScrub.slotAt(7, v, bars: true)],
                ),
                child: _DayMarkers(
                  days: days,
                  events: [for(final f in widget.findings) DailyObservation(f)],
                  top: axisTop,
                  p: p,
                ),
              ),
            ),
          ],
        ),
      ),
      if (widget.findings.any((f) => f.kind == FindingKind.rhrShift))
        TextButton.icon(
          onPressed: () => Navigator.of(c).push(
            MaterialPageRoute<void>(
              builder: (_) => RhrChangesScreen(
                findings: widget.findings,
                points: widget.rhr,
              ),
            ),
          ),
          icon: const Icon(LucideIcons.chartLine),
          label: Text(l.rhrChangesTitle),
        ),
      const SizedBox(height: S.x3),
      Text(
        l.findingsLogDerivedNote,
        style: F.cap.copyWith(color: p.ink3, height: 1.5),
      ),
    ]);
  }
}
