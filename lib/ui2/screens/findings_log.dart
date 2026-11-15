// Observations are a dated projection of the existing findings, never a new
// detector or a permanent notification ledger.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../compute/findings.dart';
import '../../data/day_label.dart';
import '../../l10n/app_localizations.dart';
import '../../models/chart_point.dart';
import '../ui2.dart';
import '../why_row.dart';
import 'home_screen.dart' show prettyDay;
import 'metric_detail.dart' show detailScaffold;

Color findingColor(FindingKind kind) => switch (kind) {
  FindingKind.illness => C.orange,
  FindingKind.anomaly => C.teal,
  FindingKind.tempElevated => C.pink,
  FindingKind.irregularRhythm => C.red,
  FindingKind.lowReadiness => C.purple,
  FindingKind.rhrShift => C.blue,
};
Color _ink(P p, Finding f) => p.on(findingColor(f.kind));
IconData _icon(Finding f) => switch (f.kind) {
  FindingKind.illness => LucideIcons.stethoscope,
  FindingKind.anomaly => LucideIcons.waves,
  FindingKind.tempElevated => LucideIcons.thermometer,
  FindingKind.irregularRhythm => LucideIcons.heartPulse,
  FindingKind.lowReadiness => LucideIcons.batteryLow,
  FindingKind.rhrShift => LucideIcons.trendingUp,
};

List<String> observationWeek(String end, int week) => [
  for (var i = 6; i >= 0; i--) dayLabelBefore(end, week * 7 + i)!,
];

class FindingsLog extends StatefulWidget {
  const FindingsLog(this.findings, {super.key, this.rhr = const [], this.today});
  final List<Finding> findings;
  final List<ChartPoint> rhr;
  final String? today;
  @override
  State<FindingsLog> createState() => _FindingsLogState();
}

class _FindingsLogState extends State<FindingsLog> {
  int _week = 0;
  String? _focus;
  late final String _end = widget.today ?? todayLabel();
  List<Finding> on(String day) => widget.findings.where((f) => f.date == day).toList();
  void move(int delta) => setState(() { _week += delta; _focus = null; });
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final days = observationWeek(_end, _week);
    final latest = observationWeek(_end, 0);
    final weekEvents = widget.findings.where((f) => latest.contains(f.date)).toList();
    final kinds = FindingKind.values.where((k) => widget.findings.any((f) => f.kind == k)).toList();
    final focus = _focus ?? days.lastWhere((d) => on(d).isNotEmpty, orElse: () => days.last);
    final counts = [for (final day in days) on(day).length.toDouble()];
    final maximum = math.max(1.0, counts.reduce(math.max));
    final earliest = widget.findings.fold(_end, (String d, f) => f.date.compareTo(d) < 0 ? f.date : d);
    return detailScaffold(c, l.findingsLogTitle, [
      Padding(key: const ValueKey('observations-latest-week'), padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.observationsLatestWeek(prettyDay(latest.first), prettyDay(latest.last)), style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          const SizedBox(height: S.x2),
          if (weekEvents.isEmpty) Text(l.observationsNoWeek, style: F.cap.copyWith(color: p.ink2)),
          Wrap(spacing: S.x3, runSpacing: S.x2, children: [for (final k in kinds)
            if (weekEvents.any((f) => f.kind == k)) Text('${weekEvents.where((f) => f.kind == k).length} · ${findingTitle(l, Finding(k, _end))}',
              style: F.cap.copyWith(color: p.on(findingColor(k))))]),
        ])),
      Surface(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          IconButton(tooltip: l.observationsEarlierWeek, onPressed: earliest.compareTo(days.first) < 0 ? () => move(1) : null, icon: const Icon(LucideIcons.chevronLeft)),
          Expanded(child: Text('${prettyDay(days.first)} – ${prettyDay(days.last)}', textAlign: TextAlign.center, style: F.cap.copyWith(color: p.ink2))),
          IconButton(tooltip: l.observationsLaterWeek, onPressed: _week > 0 ? () => move(-1) : null, icon: const Icon(LucideIcons.chevronRight)),
        ]),
        ChartFrame(title: l.findingsLogTitle, unit: l.observationsEventsUnit, height: 130,
          yAxis: AxisSpec.of([0, maximum], floor: 0, ticks: 3, format: (v) => '${v.round()}'),
          panel: ChartKeyReadout(time: prettyDay(focus), timeSpan: days.map((d) => prettyDay(d)).toList(), scrubbed: true,
            cells: [for (final k in kinds) ChartCell(findingTitle(l, Finding(k, focus)), p.on(findingColor(k)), value: '${on(focus).where((f) => f.kind == k).length}')]),
          child: Scrubber(hold: true, label: l.findingsLogTitle, step: 1 / 7,
            value: (days.indexOf(focus) + .5) / 7,
            describe: (v) => l.observationsDayCount(prettyDay(days[ChartScrub.slotAt(7, v, bars: true)]), counts[ChartScrub.slotAt(7, v, bars: true)].round()),
            onChanged: (v) => setState(() => _focus = days[ChartScrub.slotAt(7, v, bars: true)]),
            onEnd: () {}, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final day in days) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: S.x2),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [for (final f in on(day))
                  Container(height: (130 - 2 * maximum) / maximum, margin: const EdgeInsets.only(top: 2), decoration: BoxDecoration(color: p.on(findingColor(f.kind)), borderRadius: R.rSm))]))),
            ]))),
        Row(children: [for (final day in days) Expanded(child: TextButton(key: ValueKey('observation-day:$day'),
          onPressed: () => setState(() => _focus = day), child: Text(day.substring(8), style: F.cap.copyWith(color: day == focus ? p.ink : p.ink3))))]),
      ])),
      const SizedBox(height: S.x3),
      if (on(focus).isEmpty) Padding(padding: const EdgeInsets.all(S.x3), child: Text(l.observationsNoDay, style: F.body.copyWith(color: p.ink2))),
      for (final f in on(focus)) Padding(padding: const EdgeInsets.only(bottom: S.x2),
        child: WhyRow(id: 'finding:${f.kind.name}:${f.date}', title: findingTitle(l, f), body: findingDetail(l, f),
          color: findingColor(f.kind), icon: _icon(f), fullText: true,
          onTap: f.kind == FindingKind.rhrShift ? () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => RhrChangesScreen(findings: widget.findings, points: widget.rhr))) : null)),
      if (widget.findings.any((f) => f.kind == FindingKind.rhrShift)) TextButton.icon(
        onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => RhrChangesScreen(findings: widget.findings, points: widget.rhr))),
        icon: const Icon(LucideIcons.chartLine), label: Text(l.rhrChangesTitle)),
      const SizedBox(height: S.x3),
      Text(l.findingsLogDerivedNote, style: F.cap.copyWith(color: p.ink3, height: 1.5)),
    ]);
  }
}

class RhrChangesScreen extends StatelessWidget {
  const RhrChangesScreen({super.key, required this.findings, required this.points});
  final List<Finding> findings;
  final List<ChartPoint> points;
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final byDay = {for (final q in points) if (q.v.isFinite) dayLabelOf(DateTime.fromMillisecondsSinceEpoch(q.t * 1000)): q.v};
    final dates = {...byDay.keys, for (final f in findings) if (f.kind == FindingKind.rhrShift) f.date}.toList()..sort();
    final end = dates.isEmpty ? todayLabel() : dates.last;
    final start = dates.isEmpty ? end : dates.first;
    final days = <String>[];
    // Calendar labels, not elapsed 24-hour durations: DST must not move a mark.
    for (var day = start; day.compareTo(end) <= 0; day = dayLabelBefore(day, -1)!) { days.add(day); }
    if (days.length == 1) days.insert(0, dayLabelBefore(start, 1)!);
    final values = [for (final d in days) byDay[d]];
    final axis = AxisSpec.of(values.whereType<double>().toList(), ticks: 3, format: (v) => '${v.round()}');
    final marks = dailyAnnotations(rhrChangeAnnotations(findings, l: l), days);
    return detailScaffold(c, l.rhrChangesTitle, [
      Surface(child: ChartFrame(title: l.healthRowRestingHr, unit: 'bpm', height: 180, yAxis: axis, series: values,
        xLabels: [prettyDay(days.first), prettyDay(days.last)],
        annotations: marks.isEmpty ? null : AnnotationSet(items: marks, domainStart: 0, domainEnd: (days.length - 1).toDouble()),
        panel: byDay.isEmpty ? ChartKeyReadout(cells: [ChartCell(l.healthRowRestingHr, p.on(C.red))]) : null,
        footnote: byDay.isEmpty ? l.rhrNoReadings : null,
        child: ChartScrub(label: l.healthRowRestingHr, keys: [ChartKey.slots(l.healthRowRestingHr, p.on(C.red), values, (i, v) => '${v.round()} bpm')],
          slots: days.length, gaps: true, time: (v) => prettyDay(days[ChartScrub.slotAt(days.length, v)]),
          child: CustomPaint(size: Size.infinite, painter: LineChart(values, p.on(C.red), axis: axis, fill: false))))),
      const SizedBox(height: S.x3),
      for (final f in findings.where((f) => f.kind == FindingKind.rhrShift)) Padding(padding: const EdgeInsets.only(bottom: S.x2),
        child: WhyRow(id: 'rhr:${f.date}', title: '${prettyDay(f.date)} · ${findingTitle(l, f)}', body: findingDetail(l, f), color: C.blue, icon: _icon(f), fullText: true)),
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
    final l = AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final title = findingTitle(l, f);
    final detail = findingDetail(l, f);
    return Semantics(
      label: '$title. $detail',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: S.x1),
                child: Icon(_icon(f), size: 16, color: ink),
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(title,
                    style: F.body.copyWith(
                        color: p.ink, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: S.x2),
          Text(detail, style: F.cap.copyWith(color: p.ink2, height: 1.5)),
        ],
      ),
    );
  }
}
