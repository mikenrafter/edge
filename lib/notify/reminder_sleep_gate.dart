// Owns reminder sleep eligibility. Intervals include start and exclude end.
// Storage failures from load must propagate; unknown sleep must stay unknown.
import '../state/control_operations.dart' show ExpectedSleepSchedule;
import 'notification_prefs.dart';
import '../data/db.dart';
import '../data/day_label.dart';
import '../wake/sleep_onset.dart';
import '../sync/high_freq_wake_window.dart' show loadSavedExpectedSleepSchedule;
import 'package:shared_preferences/shared_preferences.dart';

enum ReminderSuppression { quietHours, sleepSchedule, asleep }

class ReminderSleepPeriod {
  const ReminderSleepPeriod(this.start, [this.end]);
  final DateTime start;
  final DateTime? end;
}

class SuppressedReminderSlot {
  const SuppressedReminderSlot(this.at, this.reason);
  final DateTime at;
  final ReminderSuppression reason;
}

// A diagnostic is a single bounded event, delivered synchronously. Collection
// callbacks preserve the public diagnostic hook without an untyped invocation.
void reportSuppressedReminder(
  void Function(SuppressedReminderSlot)? observer,
  DateTime at,
  ReminderSuppression reason,
) {
  if (observer != null) [SuppressedReminderSlot(at, reason)].forEach(observer);
}

class ReminderSleepGate {
  const ReminderSleepGate({this.schedule, this.periods = const []});
  final ExpectedSleepSchedule? schedule;
  final List<ReminderSleepPeriod> periods;

  ReminderSuppression? reasonAt(NotificationPrefs prefs, DateTime at) {
    final local = at.toLocal();
    if (prefs.inQuietHours(local.hour * 60 + local.minute)) {
      return ReminderSuppression.quietHours;
    }
    final expected = schedule;
    if (expected != null) {
      for (final d in [-1, 0, 1]) {
        final w = expected.windowFor(
          DateTime(local.year, local.month, local.day + d),
        );
        if (!at.isBefore(w.$1) && at.isBefore(w.$2)) {
          return ReminderSuppression.sleepSchedule;
        }
      }
    }
    for (final p in periods) {
      if (!at.isBefore(p.start) && (p.end == null || at.isBefore(p.end!))) {
        return ReminderSuppression.asleep;
      }
    }
    return null;
  }

  static Future<ReminderSleepGate> load({required DateTime now}) async {
    final prefs = await SharedPreferences.getInstance();
    // Seven-day catch-up plus overnight boundaries. No alarm-specific
    // staleness grace: an observed wake ends suppression at that instant.
    final rows = await LocalDb.sleepWindowRows(10);
    final periods = <ReminderSleepPeriod>[];
    final local = now.toLocal();
    final cutoff = DateTime(local.year, local.month, local.day - 8);
    for (final row in rows) {
      final window = storedSleepWindowOf(row['window_json']);
      if (window == null) continue;
      final start = DateTime.fromMillisecondsSinceEpoch(window.onsetMs.round());
      final off = window.offsetMs;
      if (off != null && off <= window.onsetMs) continue;
      final end = off == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(off.round());
      if (start.isAfter(now) || (end != null && end.isBefore(cutoff))) continue;
      periods.add(ReminderSleepPeriod(start, end));
    }
    for (final row in await LocalDb.reminderNapWindows(dayLabelOf(cutoff))) {
      final start = row['start'], end = row['end'];
      if (start is! num ||
          end is! num ||
          !start.isFinite ||
          !end.isFinite ||
          start <= 0 ||
          end <= start ||
          start * 1000 > now.millisecondsSinceEpoch) {
        continue;
      }
      periods.add(
        ReminderSleepPeriod(
          DateTime.fromMillisecondsSinceEpoch((start * 1000).round()),
          DateTime.fromMillisecondsSinceEpoch((end * 1000).round()),
        ),
      );
    }
    return ReminderSleepGate(
      schedule: loadSavedExpectedSleepSchedule(prefs),
      periods: periods,
    );
  }
}
