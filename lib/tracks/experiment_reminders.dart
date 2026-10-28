// Morning reminders for a running N-of-1 experiment, armed through the same OS
// scheduler as the water and medication reminders. The assignments come from
// TracksStore.experimentReminders (the one query, with its own
// running/stopped filter). Sleep is respected exactly as for the other
// reminders: quiet hours, expected sleep and detected sleep (ReminderSleepGate).
import 'package:clock/clock.dart';
import '../data/day_label.dart';
import '../data/db.dart';
import '../data/tracks_store.dart';
import '../notify/notification_center.dart';
import '../notify/notification_prefs.dart';
import '../notify/reminder_sleep_gate.dart';

class ExperimentReminders {
  const ExperimentReminders._();

  /// First try at 08:00, then every half hour until noon: the earliest moment
  /// the wearer is awake and not in quiet hours. Later than that, no reminder
  /// for the day rather than one in the afternoon.
  static const firstMinute = 8 * 60, lastMinute = 12 * 60, stepMinutes = 30;

  /// Days looked ahead (today included), so a few missed app opens still
  /// leave the next mornings armed.
  static const horizonDays = 3;

  static DateTime? instantFor(
    String date,
    NotificationPrefs prefs,
    ReminderSleepGate gate,
    DateTime now,
  ) {
    final day = DateTime.parse(date);
    for (var m = firstMinute; m <= lastMinute; m += stepMinutes) {
      final at = DateTime(day.year, day.month, day.day, m ~/ 60, m % 60);
      if (!at.isAfter(now)) continue;
      if (gate.reasonAt(prefs, at) == null) return at;
    }
    return null;
  }

  /// Re-arms the band from the stored assignments. Safe to call on every
  /// foreground pass: it always rewrites the whole band.
  static Future<void> refresh(
    NotificationPrefs prefs, {
    ReminderSleepGate? sleep,
  }) async {
    final now = clock.now();
    final center = NotificationCenter.instance;
    if (!prefs.phoneDeliveryEnabled('reminders')) {
      return center.armExperimentReminders(const []);
    }
    final gate = sleep ?? await ReminderSleepGate.load(now: now);
    final store = TracksStore(await LocalDb.instance);
    final slots = <({DateTime at, String route})>[];
    for (var d = 0; d < horizonDays; d++) {
      final date = dayLabelOf(DateTime(now.year, now.month, now.day + d));
      final due = await store.experimentReminders(date: date);
      if (due.isEmpty) continue;
      final at = instantFor(date, prefs, gate, now);
      if (at == null) continue;
      // One interruption per day, however many experiments are assigned.
      slots.add((at: at, route: due.first['route'] as String));
    }
    await center.armExperimentReminders(slots);
  }
}
