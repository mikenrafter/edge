import '../data/local_repository.dart';
import '../data/db.dart';
import '../data/day_label.dart';
import '../state/prefs.dart';
import 'personal_day.dart';

// Read boundary for display-only main sleep and qualified wake observations.
// sleepWindows reads day_result.window_json, never the separate naps list.
List<MainSleep> mainSleepsOf(List<Map<String, dynamic>> rows) {
  final out = <MainSleep>[];
  for (final row in rows) {
    if (row['kind'] == 'nap' || row['is_nap'] == true) continue;
    final onset = row['onset_ts'], wake = row['wake_ts'];
    if (onset is! num || !onset.isFinite || onset <= 0 ||
        (wake != null && (wake is! num || !wake.isFinite || wake <= onset))) { continue; }
    out.add(MainSleep(DateTime.fromMillisecondsSinceEpoch(onset.toInt() * 1000),
      wake is num ? DateTime.fromMillisecondsSinceEpoch(wake.toInt() * 1000) : null));
  }
  return out;
}

List<PersonalWake> personalWakesOf(DateTime onset,
    List<Map<String, Object?>> evidence, {int? confirmedAtSec}) {
  final seconds = <int>{?confirmedAtSec};
  for (final row in evidence) {
    if (!const {'alarmAcknowledged', 'bandMovement', 'alarmFired'}.contains(row['kind'])) continue;
    final at = row['at_sec'];
    if (at is num && at.isFinite) seconds.add(at.toInt());
  }
  return [for (final sec in seconds)
    if (sec * 1000 >= onset.millisecondsSinceEpoch)
      PersonalWake(onset, DateTime.fromMillisecondsSinceEpoch(sec * 1000))];
}

class PersonalDayView {
  const PersonalDayView(this.day, this.mode, this.awake, [this.cycles = const []]);
  final PersonalDay day;
  final PersonalDayMode mode;
  final bool awake;
  final List<PersonalDay> cycles;
}

// Bounded repository reads and persisted wake evidence share one decode path.
Future<({List<MainSleep> sleeps, List<PersonalWake> wakes})> _inputs(
    LocalRepository repo, DateTime from, DateTime limit, String before) async {
  final rows = await repo.sleepWindows(days: 12, before: before);
  final sleeps = mainSleepsOf(rows).where((s) =>
    !s.onset.isBefore(DateTime(from.year, from.month, from.day - 2)) &&
    !s.onset.isAfter(limit)).toList();
  final wakes = <PersonalWake>[];
  for (final sleep in sleeps) {
    final row = rows.where((r) => r['onset_ts'] is num &&
      (r['onset_ts'] as num).toInt() * 1000 == sleep.onset.millisecondsSinceEpoch).first;
    final day = row['date'] as String?;
    final confirmation = day == null ? null : await LocalDb.wakeConfirmation(day);
    wakes.addAll(personalWakesOf(sleep.onset,
      await LocalDb.wakeEvidence(sleep.onset.millisecondsSinceEpoch ~/ 1000),
      confirmedAtSec: confirmation?.atSec));
  }
  return (sleeps: sleeps, wakes: wakes);
}

/// A bounded read around the requested date, in the selected boundary mode:
/// Home and the Day screen step the same sequence [owner m301]. Errors propagate.
Future<PersonalDayView?> readPersonalDay(LocalRepository repo, String label,
    {required DateTime now, bool current = false}) async {
  if (!Prefs.personalDayEnabled) return null;
  final date = DateTime.parse(label);
  final from = DateTime(date.year, date.month, date.day - 7);
  final horizon = DateTime(date.year, date.month, date.day + 3);
  final openEnd = now.add(const Duration(minutes: 1));
  final limit = current || horizon.isAfter(openEnd) ? openEnd : horizon;
  final mode = Prefs.personalDayMode;
  final local = now.toLocal();
  final today = DateTime(local.year, local.month, local.day);
  // Initialize from NOW even when the first entry point is an old history day.
  final recent = current || Prefs.personalDayTotalsNeedsCycle
      ? await _inputs(repo, DateTime(today.year, today.month, today.day - 7),
          openEnd, dayLabelOf(DateTime(today.year, today.month, today.day + 4))) : null;
  if (Prefs.personalDayTotalsNeedsCycle && recent != null) {
    final choice = latestPersonalDayTotals(now: now, sleeps: recent.sleeps,
        wakes: recent.wakes, mode: Prefs.personalDayMode);
    if (choice != null && !await Prefs.learnPersonalDayTotals(choice)) {
      throw StateError('Could not save the calendar totals choice');
    }
  }
  final inputs = current ? recent! : await _inputs(repo, from, limit,
      dayLabelOf(DateTime(date.year, date.month, date.day + 4)));
  final sleeps = inputs.sleeps, wakes = inputs.wakes;
  final cycles = personalDays(from: from, until: limit, sleeps: sleeps,
    wakes: wakes, mode: mode, totals: Prefs.personalDayTotals);
  // A date shadowed by a longer cycle matches no label; its local noon still
  // lies in some cycle, so deep links open that one instead of an empty day.
  final noon = label.length > 10 ? null : DateTime(date.year, date.month, date.day, 12);
  final selected = current ? cycles.where((d) => d.contains(now)).firstOrNull
      : cycles.where((d) => label.length > 10 ? d.id.value == label : d.label == label).firstOrNull
        ?? (noon == null ? _sameCycle(cycles, date) : cycles.where((d) => d.contains(noon)).firstOrNull);
  return selected == null ? null : PersonalDayView(selected, mode,
      current && personalDayAwake(sleeps, wakes, now), cycles);
}

/// A cycle id is its start instant, and a finished calculation can move a start
/// by minutes (a refined onset or wake). The screen keeps the day the user
/// picked: the cycle whose start is nearest the old id, never none [owner m301].
PersonalDay? _sameCycle(List<PersonalDay> cycles, DateTime start) {
  PersonalDay? best;
  for (final cycle in cycles) {
    if (best == null || cycle.start.difference(start).abs() <=
        best.start.difference(start).abs()) { best = cycle; }
  }
  return best;
}
