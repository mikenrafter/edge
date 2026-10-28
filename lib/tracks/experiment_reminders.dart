// Morning reminders for a running N-of-1 experiment, armed through the same OS
// scheduler as the water and medication reminders. The assignments come from
// TracksStore.experimentReminders (the one query, with its own
// running/stopped filter). Sleep is respected exactly as for the other
// reminders: quiet hours, expected sleep and detected sleep (ReminderSleepGate).
import 'dart:convert';
import 'package:clock/clock.dart';
import '../data/day_label.dart';
import '../data/db.dart';
import '../data/tracks_store.dart';
import '../notify/notification_center.dart';
import '../notify/notification_prefs.dart';
import '../notify/notification_service.dart';
import '../notify/reminder_sleep_gate.dart';

class ExperimentReminders {
  const ExperimentReminders._();

  /// First try at 08:00, then every half hour until noon: the earliest moment
  /// the wearer is awake and not in quiet hours. Later than that, no reminder
  /// for the day rather than one in the afternoon.
  static const firstMinute = 8 * 60, lastMinute = 12 * 60, stepMinutes = 30;

  /// Days looked ahead (today included): the whole band, so one foreground
  /// pass arms every remaining assignment of a 4 week experiment and an app left
  /// closed (headless sync cannot re-arm) still reminds on every day.
  // CLAIM(reminders-arm-all): horizon = the OS band = the longest experiment
  // [review R2-8; tracks_experiment_reminders_test.dart].
  static const horizonDays = NotificationService.maxExperimentSlots;

  /// Install-local record of the instant armed for [date]. A day whose armed
  /// instant has passed is DELIVERED and is never armed again.
  // CLAIM(reminder-delivered-guard) [review R2-7; tracks_experiment_reminders_test.dart]
  static String _armedKey(String date) => 'experiment_reminder:$date';

  static Future<DateTime?> _armedAt(String date) async {
    final raw = await LocalDb.computeFreshnessStringField(_armedKey(date), r'$.at');
    return raw == null ? null : DateTime.tryParse(raw);
  }

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
      // ↳ CLAIM(reminder-delivered-guard)
      final armedBefore = await _armedAt(date);
      if (armedBefore != null && !armedBefore.isAfter(now)) continue;
      final at = instantFor(date, prefs, gate, now);
      if (at == null) continue;
      // One interruption per day, however many experiments are assigned.
      slots.add((at: at, route: due.first['route'] as String));
      await LocalDb.putComputeFreshness(
        _armedKey(date),
        jsonEncode({'at': at.toIso8601String()}),
      );
    }
    await center.armExperimentReminders(slots);
  }
}
