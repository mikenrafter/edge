// assumed_water.dart — "Assume I drank water".
//
// When the water reminder's assume toggle is on, every reminder slot that fires
// logs ONE assumed glass on the slot's local day, timed at the slot, and marked
// assumed in its own table (`assumed_water`), because a journal_metric day total
// cannot say which part of it was never confirmed. The glass also adds to the
// day's `water_ml` total, so every existing reader sees it; removing it
// subtracts exactly what it added. No gap filling: only slots, never "the hours
// in between".

import 'package:sqflite/sqflite.dart' show Transaction;
import '../notify/notification_center.dart';
import '../notify/notification_prefs.dart';
import '../notify/reminder_sleep_gate.dart';
import '../state/units_controller.dart' show UnitSystem;
import 'day_label.dart';
import 'db.dart';
import 'water_units.dart';

enum AssumedState {
  /// Logged by a slot, not yet reviewed.
  assumed,

  /// Reviewed and kept: still in the total, still shown as assumed, leaves the
  /// follow-up list.
  kept,

  /// Removed: its ml was subtracted. The row stays as a tombstone so a later
  /// catch-up cannot log the same slot again.
  removed,
}

class AssumedGlass {
  const AssumedGlass({
    required this.date,
    required this.atMin,
    required this.ml,
    this.state = AssumedState.assumed,
    this.loggedAtMs = 0,
  });

  /// 'YYYY-MM-DD', local.
  final String date;

  /// Local minutes past midnight of the slot.
  final int atMin;

  /// What this glass ACTUALLY added to the day total (less than a full glass
  /// when the day was at its ceiling).
  final double ml;
  final AssumedState state;
  final int loggedAtMs;

  /// 'HH:mm', local.
  String get hhmm =>
      '${(atMin ~/ 60).toString().padLeft(2, '0')}:${(atMin % 60).toString().padLeft(2, '0')}';

  /// '$date $hhmm' — the slot, and the table's primary key.
  String get key => '$date $hhmm';

  /// The slot as a LOCAL DateTime (calendar fields, DST-safe).
  DateTime get local {
    final d = date.split('-').map(int.parse).toList();
    return DateTime(d[0], d[1], d[2], atMin ~/ 60, atMin % 60);
  }
}

class AssumedWater {
  const AssumedWater._();

  /// How far back a missed slot is still caught up, in local calendar days.
  static const int lookbackDays = 7;

  /// The slots due at [now]: every water slot (NotificationCenter.waterCadenceMinutes)
  /// on every local day from [lookbackDays] ago to today whose wall-clock time is
  /// not before the toggle's `waterAssumeSinceMs` and not after [now]. Empty when
  /// the reminder or the toggle is off, or when no turn-on time is known.
  static List<DateTime> dueSlots(
    NotificationPrefs prefs, {
    required DateTime now,
    ReminderSleepGate? sleep,
    void Function(SuppressedReminderSlot)? onSuppressed,
  }) {
    if (!prefs.waterAssumeDrank || !prefs.waterEnabled) return const [];
    final sinceMs = prefs.waterAssumeSinceMs;
    if (sinceMs == null) return const []; // never guess when it was switched on
    final slots = NotificationCenter.waterCadenceMinutes(prefs);
    if (slots.isEmpty) return const [];
    final gate = sleep ?? const ReminderSleepGate();
    final n = now.toLocal();
    final since = DateTime.fromMillisecondsSinceEpoch(sinceMs);
    // Same wall minute, [lookbackDays] calendar days back (DST-safe: built from
    // calendar fields, never from a 24 h multiple).
    final cutoff = DateTime(
      n.year,
      n.month,
      n.day - lookbackDays,
      n.hour,
      n.minute,
    );
    final from = since.isAfter(cutoff) ? since : cutoff;
    final out = <DateTime>[];
    for (
      var day = DateTime(from.year, from.month, from.day);
      !day.isAfter(DateTime(n.year, n.month, n.day));
      day = DateTime(day.year, day.month, day.day + 1)
    ) {
      for (final m in slots) {
        final at = DateTime(day.year, day.month, day.day, m ~/ 60, m % 60);
        if (at.isBefore(from) || at.isAfter(n)) continue;
        final reason = gate.reasonAt(prefs, at);
        if (reason == null) {
          out.add(at);
        } else {
          reportSuppressedReminder(onSuppressed, at, reason);
        }
      }
    }
    return out;
  }

  /// Logs every due slot not already logged (ever, even if later removed) and
  /// returns how many were newly logged. Each slot logs at most once. The glass
  /// is [system]'s step. Independent of the marked-moment follow-up setting.
  static Future<int> catchUp(
    NotificationPrefs prefs, {
    required DateTime now,
    required UnitSystem system,
    ReminderSleepGate? sleep,
    void Function(SuppressedReminderSlot)? onSuppressed,
  }) async {
    final gate = sleep ?? await ReminderSleepGate.load(now: now);
    final local = now.toLocal();
    final since = dayLabelOf(
      DateTime(local.year, local.month, local.day - lookbackDays),
    );
    // Withdraw only unreviewed guesses. Kept glasses remain explicit decisions.
    for (final g in await LocalDb.assumedWater(sinceDate: since)) {
      if (g.state != AssumedState.assumed) continue;
      final reason = gate.reasonAt(prefs, g.local);
      if (reason == null) continue;
      await LocalDb.removeAssumedWater(g, onlyUnreviewed: true);
      reportSuppressedReminder(onSuppressed, g.local, reason);
    }
    // Enumerate the original cadence so every rejected slot has a diagnostic.
    final due = dueSlots(
      prefs,
      now: now,
      sleep: gate,
      onSuppressed: onSuppressed,
    );
    if (due.isEmpty) return 0;
    final ml = WaterUnits.stepMl(system);
    var logged = 0;
    for (final slot in due) {
      final reason = gate.reasonAt(prefs, slot);
      if (reason != null) {
        reportSuppressedReminder(onSuppressed, slot, reason);
        continue;
      }
      final fresh = await LocalDb.logAssumedWater(
        date: dayLabelOf(slot),
        atMin: slot.hour * 60 + slot.minute,
        ml: ml,
        loggedAtMs: now.millisecondsSinceEpoch,
      );
      if (fresh) logged++;
    }
    return logged;
  }
}

/// Where keep / remove land. Overridable so the follow-up screen is testable
/// without a database.
class AssumedWaterWriter {
  const AssumedWaterWriter({this.transaction});
  final Transaction? transaction;

  /// Acknowledge: the glass stays in the total, leaves the follow-up list.
  Future<void> keep(AssumedGlass g) async {
    await LocalDb.keepAssumedWater(g, transaction: transaction);
  }

  /// Remove: subtract exactly [g]'s ml, leave a tombstone.
  Future<void> remove(AssumedGlass g) async {
    await LocalDb.removeAssumedWater(g, transaction: transaction);
  }
}
