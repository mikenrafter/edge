// Read-only projection of stored sleep entries and wake observations.
// Mutable sleep state belongs to the separate SleepTimelineEditor.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../../state/clock_format.dart';
import '../../wake/wake_outcome.dart';
import '../../wake/wake_timeline.dart';
import '../theme.dart';

class SleepSummaryInterval {
  const SleepSummaryInterval({required this.id, required this.start,
    required this.end, this.nap = false, this.source, this.durationMin});
  final String id;
  final DateTime start, end;
  final bool nap;
  final String? source;
  final num? durationMin;
}

class SleepSummaryEvent {
  const SleepSummaryEvent(this.at, this.label, {this.detail, this.ack = false});
  final DateTime at;
  final String label;
  final String? detail;
  final bool ack;
}

/// CLAIM(sleep-summary-intervals): grouping changes only connector lines;
/// touching/overlapping entries retain every boundary [sleep_summary_test].
List<List<SleepSummaryInterval>> sleepSummaryGroups(List<SleepSummaryInterval> entries) {
  final sorted = [...entries]..sort((a, b) => a.start.compareTo(b.start));
  final groups = <List<SleepSummaryInterval>>[];
  DateTime? end;
  for (final entry in sorted) {
    if (end == null || entry.start.isAfter(end)) {
      groups.add([entry]);
      end = entry.end;
    } else {
      groups.last.add(entry);
      if (entry.end.isAfter(end)) end = entry.end;
    }
  }
  return groups;
}

String _duration(num minutes, AppLocalizations l) {
  final m = minutes.round();
  return l.sleepSummaryDuration(m ~/ 60, (m % 60).toString().padLeft(2, '0'));
}

String _elapsed(Duration time, AppLocalizations l) {
  final seconds = time.inSeconds;
  return l.sleepSummaryElapsed(seconds ~/ 60, seconds % 60);
}

List<SleepSummaryEvent> sleepSummaryEvents(List<SleepSummaryInterval> intervals,
    WakeNightTimeline wake, {AppLocalizations? localizations}) {
  final l = localizations ?? lookupAppLocalizations(const Locale('en'));
  final events = <SleepSummaryEvent>[];
  for (final interval in intervals) {
    if (interval.nap) {
      final manual = interval.source == 'manual';
      events.add(SleepSummaryEvent(interval.start, l.sleepSummaryNapStarted, detail: [
        manual ? l.sleepSummaryLogged : interval.source == 'confirmed'
            ? l.sleepSummaryConfirmed : interval.source == 'legacy'
            ? l.sleepSummaryRecorded : l.sleepSummaryDetected,
        if (interval.durationMin != null)
          manual ? _duration(interval.durationMin!, l) : l.sleepSummaryNapAsleep(_duration(interval.durationMin!, l)),
      ].join(' · ')));
      events.add(SleepSummaryEvent(interval.end, l.sleepSummaryNapEnded));
      continue;
    }
    events.add(SleepSummaryEvent(interval.start, l.sleepSummaryFellAsleep, detail: l.sleepSummaryMainSleep));
    final actual = (wake.deliveries.isEmpty ? wake.events : wake.deliveries).where((e) => e.confirmedDelivery && switch (e.kind) {
      WakeNightEventKind.natural || WakeNightEventKind.repeat ||
      WakeNightEventKind.gradual || WakeNightEventKind.alarm => true,
      _ => false,
    }).toList()..sort((a, b) => a.at.compareTo(b.at));
    for (final event in [...actual, ...wake.events.where((e) => e.kind == WakeNightEventKind.ack)]) {
      if (event.kind == WakeNightEventKind.ack) {
        final answer = event.dream;
        // An epoch's acknowledgement must never borrow another epoch's buzz.
        final ownFires = actual.where((e) => event.wakeEpochSec != null &&
            e.wakeEpochSec == event.wakeEpochSec &&
            !e.at.isAfter(event.at));
        final elapsed = ownFires.isEmpty ? null : event.at.difference(ownFires.first.at);
        events.add(SleepSummaryEvent(event.at, switch (answer?.answer) {
          DreamAnswer.dream => l.sleepSummaryUpDream,
          DreamAnswer.normal => l.sleepSummaryUpNormal,
          null => l.wakeJournalImUp,
        }, detail: [
          if (elapsed != null) ownFires.first.kind == WakeNightEventKind.alarm
              ? l.sleepSummaryAfterAlarm(_elapsed(elapsed, l))
              : l.sleepSummaryAfterAlert(_elapsed(elapsed, l)),
          if (answer == null) l.sleepSummaryUnanswered,
        ].join(' · '), ack: true));
      } else if (event.confirmedDelivery) {
        final label = switch (event.kind) {
          WakeNightEventKind.natural => l.sleepSummaryNaturalSent,
          WakeNightEventKind.repeat => l.sleepSummaryRepeatSent,
          WakeNightEventKind.gradual => l.sleepSummaryGradualSent,
          WakeNightEventKind.alarm => l.sleepSummaryAlarmReported,
          WakeNightEventKind.snooze => l.wakeJournalSnooze,
          WakeNightEventKind.snoozeStop => l.wakeJournalSnoozeStopped,
          WakeNightEventKind.ack => l.wakeJournalImUp,
        };
        events.add(SleepSummaryEvent(event.at, event.technologyVersion == null
            ? label : '$label · ${event.technologyVersion}'));
      }
    }
    // CLAIM(sleep-summary-end): compare instants, including sub-minute differences
    // [sleep_summary_test]; formatted clock labels cannot erase an event.
    if (!wake.events.any((e) => e.kind == WakeNightEventKind.ack &&
        e.at.isAtSameMomentAs(interval.end))) {
      events.add(SleepSummaryEvent(interval.end, l.sleepSummarySleepEnded));
    }
  }
  events.sort((a, b) => a.at.compareTo(b.at));
  return events;
}

class SleepSummary extends StatelessWidget {
  const SleepSummary({super.key, this.asleepMin, this.inBedMin, this.efficiency,
    this.unobservedMin, required this.sourceText, this.sourceDetail,
    this.intervals = const [], this.wake = const WakeNightTimeline(),
    required this.onEdit, this.context, this.sourceIcon = LucideIcons.wandSparkles, this.changedAt});
  final num? asleepMin, inBedMin, efficiency, unobservedMin;
  final String sourceText;
  final IconData sourceIcon;
  final String? sourceDetail;
  final DateTime? changedAt;
  final List<SleepSummaryInterval> intervals;
  final WakeNightTimeline wake;
  final VoidCallback? onEdit;
  final Widget? context;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final eff = efficiency;
    final percent = eff == null || !eff.isFinite || eff < 0 || eff > 1 ? null : (eff * 100).round();
    final groups = sleepSummaryGroups(intervals);
    final watched = inBedMin != null && unobservedMin != null && unobservedMin! > 0
        ? (inBedMin! - unobservedMin!).clamp(0, inBedMin!) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        SizedBox(width: 100, height: 100, child: Stack(alignment: Alignment.center, children: [
          SizedBox.expand(child: CircularProgressIndicator(
            key: const ValueKey('sleep-efficiency-ring'),
            value: percent == null ? 0 : eff!.clamp(0, 1).toDouble(),
            strokeWidth: 7, backgroundColor: p.line, color: p.on(C.indigo))),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text(percent == null ? '—' : '$percent%',
              key: const ValueKey('sleep-efficiency-value'),
              style: F.n24.copyWith(color: p.on(C.green), fontSize: 30)),
            Text(l.sleepSummaryAsleep, style: F.over.copyWith(color: p.ink2)),
          ]),
        ])),
        const SizedBox(width: S.x5),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(asleepMin == null ? '—' : _duration(asleepMin!, l),
            style: F.n34.copyWith(color: p.ink)),
          Text(l.sleepDetailTotalSleep, style: F.cap.copyWith(color: p.ink3)),
          const SizedBox(height: S.x2),
          Text(l.sleepSummaryInBed(inBedMin == null ? '—' : _duration(inBedMin!, l)),
            style: F.cap.copyWith(color: p.ink2)),
        ])),
      ]),
      ?context,
      if (watched != null) Padding(padding: const EdgeInsets.only(top: S.x2), child:
        Text(l.sleepSummaryCoverage(_duration(watched, l), _duration(unobservedMin!, l)), style: F.over.copyWith(color: p.ink2))),
      const SizedBox(height: S.x4),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(sourceIcon, size: 16, color: p.ink3)),
        const SizedBox(width: S.x2),
        Expanded(child: Text(sourceText, style: F.cap.copyWith(color: p.ink2))),
      ]),
      if (changedAt case final at?) Text(l.sleepSummaryChanged(
          '${MaterialLocalizations.of(c).formatShortDate(at.toLocal())}, ${formatClockOf(at.toLocal())}'),
        style: F.over.copyWith(color: p.ink3)),
      if (sourceDetail != null) Text(sourceDetail!, style: F.over.copyWith(color: p.ink3)),
      const Divider(height: S.x8),
      Text(l.sleepTabTimelineCardTitle, style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
      if (groups.isEmpty) Padding(padding: const EdgeInsets.only(top: S.x3), child:
        Text(l.sleepSummaryNoWindow, style: F.cap.copyWith(color: p.ink3))),
      for (var g = 0; g < groups.length; g++) Padding(
        key: ValueKey('sleep-summary-group:$g'),
        padding: EdgeInsets.only(top: g == 0 ? S.x4 : S.x6),
        child: _group(c, p, sleepSummaryEvents(groups[g], wake, localizations: l))),
      if (intervals.any((e) => !e.nap) && wake.events.isEmpty)
        Text(l.sleepSummaryNoWake, style: F.over.copyWith(color: p.ink3)),
      const Divider(height: S.x6),
      TextButton(onPressed: onEdit, style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: p.on(C.indigo)),
        child: Row(children: [Expanded(child: Text(l.sleepSummaryEdit)),
          Icon(LucideIcons.chevronRight, size: 16, color: p.on(C.indigo))])),
    ]);
  }


  Widget _group(BuildContext c, P p, List<SleepSummaryEvent> events) => Column(children: [
    for (var i = 0; i < events.length; i++)
      _event(c, p, events[i], i < events.length - 1),
  ]);

  Widget _event(BuildContext c, P p, SleepSummaryEvent event, bool connected) {
    final local = event.at.toLocal();
    final clock = formatClockOf(local);
    final seconds = local.second == 0 ? '' : ' · ${local.second.toString().padLeft(2, '0')}s';
    return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: 10, child: Column(children: [
        const SizedBox(height: 5),
        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
          color: event.ack ? p.on(C.green) : p.on(C.indigo))),
        if (connected) Expanded(child: Container(width: 1, color: p.line)),
      ])),
      const SizedBox(width: S.x2),
      SizedBox(width: 86, child: Text('$clock$seconds\n${MaterialLocalizations.of(c).formatShortDate(local)}',
        style: F.over.copyWith(color: p.ink3))),
      const SizedBox(width: S.x2),
      Expanded(child: Padding(padding: const EdgeInsets.only(bottom: S.x4), child:
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(event.label, style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          if (event.detail != null && event.detail!.isNotEmpty)
            Text(event.detail!, style: F.over.copyWith(color: p.ink3)),
        ]))),
    ]));
  }
}
