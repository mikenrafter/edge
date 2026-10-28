// Morning reminders for a running N-of-1 experiment, armed through the same OS
// scheduler as the water and medication reminders. The assignments come from
// TracksStore.experimentReminders (the one query, with its own
// running/stopped filter). Sleep is respected exactly as for the other
// reminders: quiet hours, expected sleep and detected sleep (ReminderSleepGate).
//
// STATE, per assigned date, install-local (compute_freshness key
// `experiment_reminder:<date>`; JSON {state, at, id}):
//   pending   armed successfully at `at` under notification id `id`;
//   delivered `at` passed and the OS no longer holds `id`: it fired;
//   (none)    never armed, or its intention was cancelled (marker removed).
// "Delivered" is read from the OS pending list, not inferred from the clock: a
// slow inexact notification that is still pending is kept, never re-armed.
import 'dart:convert';
import 'dart:math' as math;
import 'package:clock/clock.dart';
import '../data/day_label.dart';
import '../data/db.dart';
import '../data/tracks_store.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/notification_prefs.dart';
import '../notify/notification_service.dart';
import '../notify/reminder_sleep_gate.dart';

/// Slots left for experiments in the shared pending budget.
///
/// PRIORITY (highest first): alarm > medication > wind-down / check-in > water
/// > experiment > other. Higher classes are armed before experiments in each
/// scheduling pass; experiments take what remains, after holding back the slots
/// of higher-priority singletons that are not pending right now.
// CLAIM(notification-budget): experiments never use a slot a higher class
// needs, and fill the rest nearest-first [review R3-3;
// tracks_experiment_reminders_test.dart "shared budget"].
int experimentBudget({
  required int cap,
  required Set<int> pending,
}) {
  final others = pending.where((id) => !NotificationService.isExperimentSlot(id)).length;
  final held = NotificationService.higherPrioritySingletons
      .where((id) => !pending.contains(id))
      .length;
  return math.max(0, math.min(NotificationService.maxExperimentSlots, cap - others - held));
}

class ExperimentReminders {
  const ExperimentReminders._();

  /// First try at 08:00, then every half hour until noon: the earliest moment
  /// the wearer is awake and not in quiet hours. Later than that, no reminder
  /// for the day rather than one in the afternoon.
  static const firstMinute = 8 * 60, lastMinute = 12 * 60, stepMinutes = 30;

  /// Days looked ahead (today included): the longest experiment, so one
  /// foreground pass fills every slot the budget allows.
  static const horizonDays = NotificationService.maxExperimentSlots;

  /// A stable id per date inside the band: consecutive days never collide, and
  /// a kept reminder keeps its id from pass to pass.
  static int idFor(String date) {
    final d = DateTime.parse(date);
    final ordinal = DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(2020)).inDays;
    return NotificationService.idExperimentBase + ordinal % NotificationService.maxExperimentSlots;
  }

  static String _key(String date) => 'experiment_reminder:$date';

  static Future<({String state, DateTime at, int id})?> _read(String date) async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      "SELECT json_extract(payload_json, '\$.state') AS s, "
      "json_extract(payload_json, '\$.at') AS a, "
      "json_extract(payload_json, '\$.id') AS i "
      'FROM compute_freshness WHERE key = ?',
      [_key(date)],
    );
    if (rows.isEmpty) return null;
    final at = DateTime.tryParse('${rows.first['a']}');
    final id = rows.first['i'];
    if (at == null || id is! int || rows.first['s'] is! String) return null;
    return (state: rows.first['s'] as String, at: at, id: id);
  }

  static Future<void> _write(String date, String state, DateTime at, int id) =>
      LocalDb.putComputeFreshness(
        _key(date),
        jsonEncode({'state': state, 'at': at.toIso8601String(), 'id': id}),
      );

  static Future<void> _clear(String date) => LocalDb.deleteComputeFreshness(_key(date));

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

  /// Brings the OS schedule in line with the stored assignments. Safe on every
  /// foreground pass. The whole read, validate, cancel and arm sequence runs
  /// under the scheduling lock.
  // CLAIM(reminders-serialized): one pass at a time, shared with the other
  // scheduling passes [review R3-7; tracks_experiment_reminders_test.dart].
  static Future<void> refresh(
    NotificationPrefs prefs, {
    ReminderSleepGate? sleep,
  }) => NotificationCenter.instance.runScheduling(() => _plan(prefs, sleep));

  static Future<void> _plan(NotificationPrefs prefs, ReminderSleepGate? sleep) async {
    final now = clock.now();
    final svc = NotificationService.instance;
    final pending = await svc.pendingIds();
    final bandIds = {
      for (var i = 0; i < NotificationService.maxExperimentSlots; i++)
        NotificationService.idExperimentBase + i,
    };
    final wanted = <String, ({DateTime at, int id, String route, bool armed})>{};
    if (prefs.phoneDeliveryEnabled('reminders')) {
      final gate = sleep ?? await ReminderSleepGate.load(now: now);
      final store = TracksStore(await LocalDb.instance);
      for (var d = 0; d < horizonDays; d++) {
        final date = dayLabelOf(DateTime(now.year, now.month, now.day + d));
        final due = await store.experimentReminders(date: date);
        if (due.isEmpty) continue;
        final route = due.first['route'] as String;
        final marker = await _read(date);
        if (marker != null && marker.state == 'delivered') continue;
        if (marker != null) {
          // ↳ CLAIM(reminder-revalidated): a retained request is checked against
          // the CURRENT sleep / quiet-hours gate; a suppressed one is moved to
          // the next allowed instant, or dropped when none is left that day
          // [review R4-2]. A request already due is left to fire.
          final suppressed =
              marker.at.isAfter(now) && gate.reasonAt(prefs, marker.at) != null;
          if (pending != null) {
            // ↳ CLAIM(reminder-delivered-guard): still pending (even past its
            // time, an inexact one can be late): keep it. Gone and past: fired.
            if (pending.contains(marker.id)) {
              if (!suppressed) {
                wanted[date] = (at: marker.at, id: marker.id, route: route, armed: true);
                continue;
              }
            } else if (!marker.at.isAfter(now)) {
              await _write(date, 'delivered', marker.at, marker.id);
              continue;
            }
          }
        }
        final at = instantFor(date, prefs, gate, now);
        if (at == null) continue;
        wanted[date] = (at: at, id: idFor(date), route: route, armed: false);
      }
    }
    // The shared budget: nearest dates first.
    final budget = pending == null
        ? math.min(NotificationService.maxExperimentSlots, svc.pendingCap)
        : experimentBudget(cap: svc.pendingCap, pending: pending);
    final ordered = wanted.keys.toList()..sort();
    final keep = ordered.take(budget).toSet();
    final keptIds = {for (final d in keep) if (wanted[d]!.armed) wanted[d]!.id};
    // Cancel what is pending but not kept; with the pending list unknown,
    // clear the whole band and re-arm.
    for (final id in bandIds) {
      if (keptIds.contains(id)) continue;
      if (pending == null || pending.contains(id)) await svc.cancel(id);
    }
    // Cancelled intentions leave no marker, so re-enabling later re-arms.
    for (var d = 0; d < horizonDays; d++) {
      final date = dayLabelOf(DateTime(now.year, now.month, now.day + d));
      if (keep.contains(date) && wanted[date]!.armed) continue;
      final marker = await _read(date);
      if (marker != null && marker.state == 'pending') await _clear(date);
    }
    await svc.ensureTimezone();
    for (final date in ordered.take(budget)) {
      final slot = wanted[date]!;
      if (slot.armed && pending != null) continue;
      final ok = await svc.scheduleOnce(
        id: slot.id,
        category: NotifCategory.reminders,
        // No track name and no arm: this lands on a lock screen. The screen
        // behind the tap says what today's assignment is.
        title: 'Experiment day',
        body: 'Today has an assignment in your experiment.',
        at: slot.at,
        route: slot.route,
      );
      // ↳ CLAIM(reminder-delivered-guard): a marker only for an armed slot.
      if (ok) await _write(date, 'pending', slot.at, slot.id);
    }
  }

  /// Re-arms after a change the foreground pass has not seen: an experiment
  /// started or stopped, a track disabled, deleted or marked prescribed, a
  /// restore. Never throws.
  // CLAIM(reminders-follow-state): every such change goes through the one
  // scheduler [review T8, R2-2; tracks_experiment_reminders_test.dart].
  static Future<void> refreshAfterChange({
    NotificationPrefs? prefs,
    ReminderSleepGate? sleep,
  }) async {
    try {
      await refresh(prefs ?? await NotificationPrefs.load(), sleep: sleep);
    } catch (_) {}
  }
}

/// The app's listener: re-arms the OS schedule after a relevant change.
class ExperimentReminderListener implements ExperimentScheduleListener {
  const ExperimentReminderListener();
  @override
  Future<void> experimentScheduleChanged() =>
      ExperimentReminders.refreshAfterChange();
}
