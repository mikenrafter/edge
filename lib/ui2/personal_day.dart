import '../data/day_label.dart';

// Display projection only. No mutable state, persistence or metric computation.
enum PersonalDayMode { calendarOffset, wakeToWake, sleepToSleep }
enum PersonalDayTotals { first, last }

// Keep the pilot's noon boundary until the owner decides S1. Set to 0 for
// local midnight-to-midnight calendar cycles.
const _calendarDayStartHour = 12;

/// CLAIM(personal-totals-default): before any completed cycle is available,
/// wake-to-wake starts with first and sleep-to-sleep with last
/// [owner 2026-11-18; test/wake_days/round4_test.dart].
PersonalDayTotals defaultTotalsFor(PersonalDayMode mode) =>
    mode == PersonalDayMode.sleepToSleep ? PersonalDayTotals.last : PersonalDayTotals.first;

class MainSleep {
  const MainSleep(this.onset, this.wake);
  final DateTime onset;
  final DateTime? wake;
}

class PersonalWake {
  const PersonalWake(this.onset, this.at);
  final DateTime onset, at;
}

// Navigation identity only. Calendar-owned writers require a date or instant.
extension type const PersonalDayId(String value) {}

class PersonalDay {
  const PersonalDay(this.start, this.end, this.label, this.scoreDay);
  final DateTime start, end;
  final String label;
  final String? scoreDay;
  PersonalDayId get id => PersonalDayId(start.toIso8601String());
  bool contains(DateTime at) => !at.isBefore(start) && at.isBefore(end);

  Set<String> get calendarDays {
    final dates = <String>{};
    var cursor = start.toLocal();
    while (cursor.isBefore(end)) {
      dates.add(dayLabelOf(cursor));
      cursor = nextMidnight(cursor);
    }
    return dates;
  }

  /// Shared half-open clipping for stored and pending timeline rows.
  bool overlapsSeconds(int at, [int? until]) {
    final first = start.millisecondsSinceEpoch ~/ 1000;
    final last = end.millisecondsSinceEpoch ~/ 1000;
    return at < last && (until == null ? at >= first : until > first);
  }
}

/// CLAIM(personal-days): owner rules 2026-11-16, proved by
/// test/wake_days/personal_day_test.dart. Calendar arithmetic defines dates;
/// elapsed time defines the 12/36 hour limits. Invalid windows are ignored.
List<PersonalDay> personalDays({
  required DateTime from,
  required DateTime until,
  required List<MainSleep> sleeps,
  List<PersonalWake> wakes = const [],
  required PersonalDayMode mode,
  PersonalDayTotals? totals,
}) {
  if (!until.isAfter(from)) return const [];
  final valid = sleeps.where((s) => s.wake == null || s.wake!.isAfter(s.onset))
      .toList()..sort((a, b) => a.onset.compareTo(b.onset));
  final anchors = <DateTime>[];
  DateTime? lastOnset;
  for (var i = 0; i < valid.length; i++) {
    final sleep = valid[i];
    // CLAIM(personal-split-onsets): choose by main onset spacing first;
    // projecting wakes must not turn a split block into a new anchor.
    // [owner rules 2026-11-16; personal_day_test.dart]
    if (lastOnset != null &&
        sleep.onset.difference(lastOnset) < const Duration(hours: 20)) { continue; }
    lastOnset = sleep.onset;
    DateTime? wake = sleep.wake;
    for (final evidence in wakes) {
      if (evidence.onset != sleep.onset || evidence.at.isBefore(sleep.onset) ||
          (i + 1 < valid.length && !evidence.at.isBefore(valid[i + 1].onset))) { continue; }
      if (wake == null || evidence.at.isBefore(wake)) wake = evidence.at;
    }
    final anchor = mode == PersonalDayMode.sleepToSleep ? sleep.onset : wake;
    if (anchor != null &&
        (anchors.isEmpty || anchor.difference(anchors.last) >= const Duration(hours: 12))) {
      anchors.add(anchor);
    }
  }
  final calendar = mode == PersonalDayMode.calendarOffset;
  final local = from.toLocal();
  var start = calendar
      ? DateTime(local.year, local.month, local.day, _calendarDayStartHour)
      : DateTime(local.year, local.month, local.day);
  if (calendar && start.isAfter(from)) start = DateTime(local.year, local.month, local.day - 1, _calendarDayStartHour);
  if (!calendar) {
    for (final anchor in anchors) {
      if (!anchor.isAfter(from)) start = anchor;
    }
  }
  final spans = <(DateTime, DateTime)>[];
  while (start.isBefore(until)) {
    final next = anchors.where((a) => a.isAfter(start)).firstOrNull;
    DateTime end;
    if (calendar) {
      end = DateTime(start.year, start.month, start.day + 1, _calendarDayStartHour);
    } else if (anchors.isEmpty || (anchors.first.isAfter(start))) {
      end = nextMidnight(start);
      if (next != null && next.isBefore(end)) end = next;
    } else {
      end = next ?? until;
      if (end.difference(start) > const Duration(hours: 36)) {
        final minimum = start.add(const Duration(hours: 12));
        final midnight = nextMidnight(start);
        end = midnight.isAfter(minimum) ? midnight : minimum;
      }
    }
    if (end.isAfter(until) && !calendar && next == null) end = until;
    if (!end.isAfter(start)) break;
    if (!calendar && anchors.isNotEmpty && end == anchors.first &&
        end.difference(start) < const Duration(hours: 12)) {
      if (spans.isNotEmpty) {
        final previous = spans.removeLast();
        spans.add((previous.$1, end));
      }
      // Without an earlier cycle, this is a clipped query prefix, not a
      // complete personal day. The first known anchor starts the first day.
    } else { spans.add((start, end)); }
    start = end;
  }
  final cycles = <PersonalDay>[];
  // Reserve the current cycle's date before closed first/last choices can take
  // it. A closed cycle losing the claim abstains [fix_r3_test.dart].
  // ↳ CLAIM(personal-open-cycle)
  final openScore = spans.isNotEmpty && !spans.last.$2.isBefore(until)
      ? _majorityDay(spans.last.$1, spans.last.$2) : null;
  final claimed = <String>{?openScore};
  final choice = totals ?? defaultTotalsFor(mode);
  for (final (start, end) in spans) {
    final first = dayLabelOf(start);
    final last = dayLabelOf(end.subtract(const Duration(microseconds: 1)));
    // CLAIM(personal-open-cycle): the cycle still running scores its majority
    // day, so the current day neither vanishes nor moves at midnight
    // [test/wake_days/fix_r2_test.dart; test/wake_days/fix_r3_test.dart].
    final open = !end.isBefore(until);
    final score = open ? openScore!
        : choice == PersonalDayTotals.first ? first : last;
    final scoreDay = open || claimed.add(score) ? score : null;
    if (end.isAfter(from)) cycles.add(PersonalDay(start, end, _majorityDay(start, end), scoreDay));
  }
  return List.unmodifiable(cycles);
}

/// CLAIM(personal-global-totals): the latest completed cycle chooses one
/// first/last setting for all history [round4_test.dart; owner 2026-11-18].
/// Query-prefix and 36-hour fallback spans cannot teach a sleep boundary.
PersonalDayTotals? latestPersonalDayTotals({required DateTime now,
    required List<MainSleep> sleeps, required List<PersonalWake> wakes,
    required PersonalDayMode mode}) {
  if (sleeps.isEmpty) return null;
  final local = now.toLocal();
  final cycles = personalDays(from: DateTime(local.year, local.month, local.day - 7),
      until: now.add(const Duration(minutes: 1)), sleeps: sleeps, wakes: wakes, mode: mode);
  final anchors = <DateTime>{
    for (final sleep in sleeps)
      if (mode == PersonalDayMode.sleepToSleep) sleep.onset
      else if (sleep.wake != null) sleep.wake!,
    if (mode == PersonalDayMode.wakeToWake) ...wakes.map((w) => w.at),
  };
  final completed = cycles.where((d) => !d.end.isAfter(now) &&
      (mode == PersonalDayMode.calendarOffset ||
        anchors.contains(d.start) && anchors.contains(d.end))).lastOrNull;
  if (completed == null) return null;
  return completed.label == dayLabelOf(completed.start)
      ? PersonalDayTotals.first : PersonalDayTotals.last;
}

/// Wake evidence for the latest main sleep ends its pre-sleep presentation.
bool personalDayAwake(List<MainSleep> sleeps, List<PersonalWake> wakes,
    DateTime now) {
  final latest = sleeps.where((s) => !s.onset.isAfter(now) &&
      (s.wake == null || s.wake!.isAfter(s.onset))).toList()
    ..sort((a, b) => b.onset.compareTo(a.onset));
  if (latest.isEmpty) return false;
  final sleep = latest.first;
  return (sleep.wake != null && !sleep.wake!.isAfter(now)) || wakes.any((w) =>
      w.onset == sleep.onset && !w.at.isBefore(sleep.onset) && !w.at.isAfter(now));
}

DateTime nextMidnight(DateTime at) {
  final local = at.toLocal();
  return DateTime(local.year, local.month, local.day + 1);
}

String _majorityDay(DateTime start, DateTime end) {
  var cursor = start.toLocal();
  var label = dayLabelOf(cursor);
  var longest = Duration.zero;
  while (cursor.isBefore(end)) {
    final midnight = nextMidnight(cursor);
    final stop = midnight.isBefore(end) ? midnight : end;
    final duration = stop.difference(cursor);
    if (duration > longest) { longest = duration; label = dayLabelOf(cursor); }
    cursor = stop;
  }
  return label;
}

/// The learned sleep window bounds the alarm horizon. The half-window grace
/// permits a later alarm without treating the next afternoon as this night.
bool personalAlarmFits(DateTime now, DateTime alarm, int? onsetMin, int? wakeMin) {
  if (!alarm.isAfter(now)) return false;
  final localNow = now.toLocal();
  final afterTomorrow = DateTime(localNow.year, localNow.month, localNow.day + 2);
  if (!alarm.isBefore(afterTomorrow)) return false;
  if (onsetMin == null || wakeMin == null) return true;
  final a = alarm.toLocal();
  final wake = DateTime(a.year, a.month, a.day, wakeMin ~/ 60, wakeMin % 60);
  final onset = personalClockBefore(wake, onsetMin);
  final grace = Duration(microseconds: wake.difference(onset).inMicroseconds ~/ 2);
  return alarm.isBefore(wake.add(grace)) && alarm.isAfter(onset.subtract(grace));
}

DateTime nextPersonalClock(DateTime from, int minuteOfDay) {
  final local = from.toLocal();
  final today = DateTime(local.year, local.month, local.day,
      minuteOfDay ~/ 60, minuteOfDay % 60);
  return today.isAfter(from) ? today : DateTime(local.year, local.month,
      local.day + 1, minuteOfDay ~/ 60, minuteOfDay % 60);
}

DateTime personalClockBefore(DateTime wake, int minuteOfDay) {
  final local = wake.toLocal();
  final same = DateTime(local.year, local.month, local.day,
      minuteOfDay ~/ 60, minuteOfDay % 60);
  return same.isBefore(wake) ? same : DateTime(local.year, local.month,
      local.day - 1, minuteOfDay ~/ 60, minuteOfDay % 60);
}
