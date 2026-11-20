// Read-only projection of stored sleep entries and wake observations.
// Mutable sleep state belongs to the separate SleepTimelineEditor.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:intl/intl.dart';

import '../../data/day_label.dart';

import '../../l10n/app_localizations.dart';
import '../../state/clock_format.dart';
import '../../wake/wake_outcome.dart';
import '../../wake/wake_timeline.dart';
import '../theme.dart';
import '../charts.dart' show Ring;

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
  const SleepSummaryEvent(this.at, this.label, {this.detail, this.ack = false, this.wakeKind, this.wakeEpochSec, this.technologyVersion});
  final DateTime at;
  final String label;
  final String? detail;
  final bool ack;
  final WakeNightEventKind? wakeKind;
  final int? wakeEpochSec;
  final String? technologyVersion;
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
        events.add(SleepSummaryEvent(event.at, switch (answer?.answer) {
          DreamAnswer.dream => l.sleepSummaryUpDream,
          DreamAnswer.normal => l.sleepSummaryUpNormal,
          null => l.wakeJournalImUp,
        }, detail: [
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
            ? label : '$label · ${event.technologyVersion}', wakeKind: event.kind,
          wakeEpochSec: event.wakeEpochSec, technologyVersion: event.technologyVersion));
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

bool _sent(WakeNightEventKind? kind) => kind == WakeNightEventKind.natural ||
    kind == WakeNightEventKind.repeat || kind == WakeNightEventKind.gradual;

/// CLAIM(sleep-summary-wake-time): only the first sent alert and its own
/// epoch's first acknowledgement define the interval [sleep_summary_round2_test].
/// A band-reported alarm alone cannot prove an alert was sent by this app.
Duration? sleepSummaryTimeToWake(WakeNightTimeline wake) {
  final sent = (wake.deliveries.isEmpty ? wake.events : wake.deliveries)
      .where((e) => e.confirmedDelivery && _sent(e.kind)).toList()
    ..sort((a, b) => a.at.compareTo(b.at));
  if (sent.isEmpty || sent.first.wakeEpochSec == null) return null;
  final acknowledgements = wake.events.where((e) =>
      e.kind == WakeNightEventKind.ack && e.wakeEpochSec == sent.first.wakeEpochSec).toList()
    ..sort((a, b) => a.at.compareTo(b.at));
  if (acknowledgements.isEmpty || acknowledgements.first.at.isBefore(sent.first.at)) return null;
  return acknowledgements.first.at.difference(sent.first.at);
}

WakeNightEventKind? _method(SleepSummaryEvent event) =>
    event.wakeKind == WakeNightEventKind.repeat ? WakeNightEventKind.natural : event.wakeKind;

/// CLAIM(sleep-summary-runs): interleaved methods retain their own ranges.
/// Non-alert events, epoch/version changes, midnight and offset changes break
/// runs [sleep_summary_round2_test]. No stored observation changes.
List<List<SleepSummaryEvent>> sleepSummaryRuns(List<SleepSummaryEvent> events) {
  final runs = <List<SleepSummaryEvent>>[];
  final active = <WakeNightEventKind, List<SleepSummaryEvent>>{};
  SleepSummaryEvent? previous;
  for (final event in events) {
    if (!_sent(event.wakeKind)) {
      active.clear();
      runs.add([event]);
      previous = null;
      continue;
    }
    if (previous != null && (previous.wakeEpochSec != event.wakeEpochSec ||
        dayLabelOf(previous.at.toLocal()) != dayLabelOf(event.at.toLocal()) ||
        previous.at.toLocal().timeZoneOffset != event.at.toLocal().timeZoneOffset)) {
      active.clear();
    }
    final method = _method(event)!;
    final run = active[method];
    if (run != null && run.last.technologyVersion == event.technologyVersion) {
      run.add(event);
    } else {
      final next = [event];
      runs.add(next);
      active[method] = next;
    }
    previous = event;
  }
  return runs;
}

// Overlap grouping affects only the bracket, keeping each method's range/count.
List<List<List<SleepSummaryEvent>>> _overlapGroups(List<List<SleepSummaryEvent>> runs) {
  final groups = <List<List<SleepSummaryEvent>>>[];
  DateTime? end;
  for (final run in runs) {
    if (_sent(run.first.wakeKind) && groups.isNotEmpty &&
        _sent(groups.last.first.first.wakeKind) && end != null && !run.first.at.isAfter(end)) {
      groups.last.add(run);
      if (run.last.at.isAfter(end)) end = run.last.at;
    } else {
      groups.add([run]);
      end = _sent(run.first.wakeKind) ? run.last.at : null;
    }
  }
  return groups;
}

// Midnight rows use calendar construction, never a fixed 24-hour increment.
List<DateTime> _midnights(DateTime before, DateTime after) {
  final localBefore = before.toLocal(), localAfter = after.toLocal();
  final dates = <DateTime>[];
  var date = DateTime(localBefore.year, localBefore.month, localBefore.day + 1);
  while (!date.isAfter(localAfter)) {
    dates.add(date);
    date = DateTime(date.year, date.month, date.day + 1);
  }
  return dates;
}

const _timeColumnWidth = 72.0;
const _railWidth = 18.0;

/// Option B from the owner's day-boundary mock-up. Placement is independent
/// of this small widget so its appearance can change without changing dates.
class SleepSummaryDayBoundary extends StatelessWidget {
  const SleepSummaryDayBoundary({super.key, required this.date, this.connected = true});
  final DateTime date;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Semantics(label: DateFormat.yMMMMEEEEd(locale).format(date),
      excludeSemantics: true, child: SizedBox(height: 30, child: Row(children: [
        SizedBox(width: _timeColumnWidth, child: Text(DateFormat('EEE d', locale).format(date).toUpperCase(),
          style: F.over.copyWith(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .3, color: p.ink2))),
        SizedBox(width: _railWidth, height: 30, child: Stack(alignment: Alignment.center, children: [
          if (connected) Container(width: 1, color: p.line),
          Container(width: 12, height: 2, color: p.on(C.indigo)),
        ])),
      ])));
  }
}

class SleepSummary extends StatelessWidget {
  const SleepSummary({super.key, this.asleepMin, this.inBedMin, this.efficiency,
    this.unobservedMin, required this.sourceText, this.sourceDetail,
    this.intervals = const [], this.wake = const WakeNightTimeline(),
    required this.onEdit, this.context, this.updatedAt, this.sourceIcon = LucideIcons.wandSparkles, this.changedAt});
  final num? asleepMin, inBedMin, efficiency, unobservedMin;
  final String sourceText;
  final IconData sourceIcon;
  final String? sourceDetail;
  final DateTime? changedAt;
  /// Latest recording included in this result, never its calculation time.
  final DateTime? updatedAt;
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
    final eventGroups = [for (final group in groups) sleepSummaryEvents(group, wake, localizations: l)];
    final allEvents = [for (final events in eventGroups) ...events];
    final offsetChanges = allEvents.map((e) => e.at.toLocal().timeZoneOffset).toSet().length > 1;
    final wakeTime = sleepSummaryTimeToWake(wake);
    final window = l.sleepSummaryWindow(inBedMin == null ? '—' : _duration(inBedMin!, l));
    final watched = inBedMin != null && unobservedMin != null && unobservedMin! > 0
        ? (inBedMin! - unobservedMin!).clamp(0, inBedMin!) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        SizedBox(width: 100, height: 100, child: Semantics(
          key: const ValueKey('sleep-efficiency-ring'),
          label: percent == null ? l.supplementUnavailable(l.wearableRowEfficiency) : l.wearableRowEfficiency,
          value: percent == null ? null : '$percent%',
          child: ExcludeSemantics(child: Stack(alignment: Alignment.center, children: [
          SizedBox.expand(child: CustomPaint(painter: Ring(
            percent == null ? 0 : eff!.clamp(0, 1).toDouble(),
            p.on(C.indigo), p.line, stroke:7, solid:true))),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text(percent == null ? '—' : '$percent%',
              key: const ValueKey('sleep-efficiency-value'),
              style: F.n24.copyWith(color: p.on(C.green), fontSize: 30)),
            Text(l.sleepSummaryAsleep, style: F.over.copyWith(color: p.ink2)),
          ]),
        ])))),
        const SizedBox(width: S.x5),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(asleepMin == null ? '—' : _duration(asleepMin!, l),
            style: F.n34.copyWith(color: p.ink)),
          Text(l.sleepDetailTotalSleep, style: F.cap.copyWith(color: p.ink3)),
          const SizedBox(height: S.x3),
          Semantics(key: const ValueKey('sleep-time-to-wake'), container: true,
            label: wakeTime == null ? l.supplementUnavailable(l.sleepSummaryTimeToWake) : l.sleepSummaryTimeToWake,
            value: wakeTime == null ? null : _elapsed(wakeTime, l),
            hint: l.sleepSummaryTimeToWakeExplanation,
            child: ExcludeSemantics(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(wakeTime == null ? '—' : _elapsed(wakeTime, l), style: F.n24.copyWith(color: p.ink)),
                Text(l.sleepSummaryTimeToWake, style: F.cap.copyWith(color: p.ink3)),
              ]))),
        ])),
      ]),
      const SizedBox(height: S.x3),
      Text(updatedAt == null ? window : l.sleepSummaryWindowUpdated(window, formatClockOf(updatedAt!.toLocal())),
        style: F.cap.copyWith(color: p.ink2)),
      ?context,
      Padding(padding: const EdgeInsets.only(top: S.x2), child: Text(l.sleepSummaryPercentageExplanation, style: F.over.copyWith(color: p.ink2))),
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
      if (allEvents.any((e) => _sent(e.wakeKind))) Padding(padding: const EdgeInsets.only(top: S.x2),
        child: Text(l.sleepSummarySentExplanation, style: F.over.copyWith(color: p.ink3))),
      for (var g = 0; g < groups.length; g++) Padding(
        key: ValueKey('sleep-summary-group:$g'),
        padding: EdgeInsets.only(top: g == 0 ? S.x4 : S.x6),
        child: _group(c, p, eventGroups[g], offsetChanges, g == 0 ? null : eventGroups[g - 1].last.at)),
      if (intervals.any((e) => !e.nap) && !allEvents.any((e) => e.ack || e.wakeKind != null))
        Text(l.sleepSummaryNoWake, style: F.over.copyWith(color: p.ink3)),
      const Divider(height: S.x6),
      TextButton(onPressed: onEdit, style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: p.on(C.indigo)),
        child: Row(children: [Expanded(child: Text(l.sleepSummaryEdit)),
          Icon(LucideIcons.chevronRight, size: 16, color: p.on(C.indigo))])),
    ]);
  }


  Widget _group(BuildContext c, P p, List<SleepSummaryEvent> events, bool offsetChanges, DateTime? preceding) {
    final groups = _overlapGroups(sleepSummaryRuns(events));
    final locale = Localizations.localeOf(c).toLanguageTag();
    final children = <Widget>[];
    if (preceding == null && events.isNotEmpty) {
      children.add(Padding(padding: const EdgeInsets.only(bottom: S.x2), child: Text(
        DateFormat('EEE d MMM', locale).format(events.first.at.toLocal()),
        style: F.over.copyWith(color: p.ink3))));
    }
    var previous = preceding;
    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      if (previous != null) {
        for (final date in _midnights(previous, group.first.first.at)) {
          children.add(SleepSummaryDayBoundary(date: date, connected: i > 0));
        }
      }
      bool nearby(SleepSummaryEvent event) => events.any((e) =>
          !e.at.isAtSameMomentAs(event.at) &&
          dayLabelOf(e.at.toLocal()) == dayLabelOf(event.at.toLocal()) &&
          e.at.toLocal().hour == event.at.toLocal().hour &&
          e.at.toLocal().minute == event.at.toLocal().minute);
      if (group.length == 1) {
        children.add(_event(c, p, group.single, i < groups.length - 1, offsetChanges, nearby(group.single.first)));
      } else {
        final l = AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
        children.add(Semantics(container: true, explicitChildNodes: true,
          label: l.sleepSummaryOverlappingAlerts,
          child: Stack(key: const ValueKey('sleep-wake-overlap'), children: [
            Positioned(left: _timeColumnWidth + _railWidth / 2 - 4,
              top: 5, bottom: S.x4, width: 8,
              child: ExcludeSemantics(child: DecoratedBox(
                key: const ValueKey('sleep-wake-overlap-bracket'),
                decoration: BoxDecoration(border: Border(
                  left: BorderSide(color: p.on(C.indigo)),
                  top: BorderSide(color: p.on(C.indigo)),
                  bottom: BorderSide(color: p.on(C.indigo)),
                ))))),
            Column(children: [for (final run in group)
              _event(c, p, run, false, offsetChanges, nearby(run.first), bracketed: true)]),
          ])));
      }
      previous = group.map((run) => run.last.at).reduce((a, b) => a.isAfter(b) ? a : b);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  String _clock(DateTime at, {bool seconds = false, bool offset = false}) {
    final local = at.toLocal();
    var clock = formatClockOf(local);
    if (seconds) {
      // Insert seconds before a localized AM/PM prefix or suffix.
      final minute = RegExp(r':\d{2}');
      clock = clock.replaceFirstMapped(minute, (m) => '${m[0]}:${local.second.toString().padLeft(2, '0')}');
    }
    if (!offset) return clock;
    final minutes = local.timeZoneOffset.inMinutes;
    return '$clock UTC${minutes < 0 ? '−' : '+'}${(minutes.abs() ~/ 60).toString().padLeft(2, '0')}:${(minutes.abs() % 60).toString().padLeft(2, '0')}';
  }

  Widget _event(BuildContext c, P p, List<SleepSummaryEvent> run, bool connected, bool offsetChanges, bool nearby, {bool bracketed = false}) {
    final l = AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final event = run.first;
    final sent = _sent(event.wakeKind);
    final multiple = run.length > 1;
    final clock = _clock(event.at, seconds: !multiple && (sent || event.ack || nearby), offset: offsetChanges);
    final firstLocal = event.at.toLocal(), lastLocal = run.last.at.toLocal();
    final rangeSeconds = firstLocal.hour == lastLocal.hour && firstLocal.minute == lastLocal.minute;
    final range = multiple ? '${_clock(event.at, seconds: rangeSeconds, offset: offsetChanges)}–${_clock(run.last.at, seconds: rangeSeconds, offset: offsetChanges)}' : null;
    final method = event.wakeKind == WakeNightEventKind.gradual ? l.sleepSummaryGradual : l.sleepSummaryNatural;
    final label = sent ? (event.technologyVersion == null ? method : '$method · ${event.technologyVersion}') : event.label;
    return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: _timeColumnWidth, child: Text(multiple ? '' : clock, style: F.over.copyWith(color: p.ink3))),
      SizedBox(width: _railWidth, child: Column(children: [
        const SizedBox(height: 5),
        if (!bracketed) Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
          color: event.ack ? p.on(C.green) : p.on(C.indigo))),
        if (connected && !bracketed) Expanded(child: Container(width: 1, color: p.line)),
      ])),
      const SizedBox(width: S.x2),
      Expanded(child: Padding(padding: const EdgeInsets.only(bottom: S.x4), child:
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          if (range != null) Text(l.sleepSummaryAlertRange(range, run.length), style: F.over.copyWith(color: p.ink3)),
          if (event.detail != null && event.detail!.isNotEmpty)
            Text(event.detail!, style: F.over.copyWith(color: p.ink3)),
        ]))),
    ]));
  }
}
