// assumed_water.dart — "Assume I drank water".
//
// When the water reminder's assume toggle is on, every reminder slot that fires
// logs ONE assumed glass on the slot's local day, timed at the slot, and marked
// assumed in its own table (`assumed_water`), because a journal_metric day total
// cannot say which part of it was never confirmed. The glass also adds to the
// day's `water_ml` total, so every existing reader sees it; removing it
// subtracts exactly what it added. No gap filling: only slots, never "the hours
// in between".
//
// RED-phase stub: behaviour throws until the GREEN phase implements it.

import '../notify/notification_prefs.dart';
import '../state/units_controller.dart' show UnitSystem;

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

  /// The slots due at [now]: every water slot (NotificationCenter.waterSlotMinutes)
  /// on every local day from [lookbackDays] ago to today whose wall-clock time is
  /// not before the toggle's `waterAssumeSinceMs` and not after [now]. Empty when
  /// the reminder or the toggle is off, or when no turn-on time is known.
  static List<DateTime> dueSlots(NotificationPrefs prefs, {required DateTime now}) =>
      throw UnimplementedError('AssumedWater.dueSlots');

  /// Logs every due slot not already logged (ever, even if later removed) and
  /// returns how many were newly logged. Each slot logs at most once. The glass
  /// is [system]'s step. Independent of the marked-moment follow-up setting.
  static Future<int> catchUp(
    NotificationPrefs prefs, {
    required DateTime now,
    required UnitSystem system,
  }) =>
      throw UnimplementedError('AssumedWater.catchUp');
}

/// Where keep / remove land. Overridable so the follow-up screen is testable
/// without a database.
class AssumedWaterWriter {
  const AssumedWaterWriter();

  /// Acknowledge: the glass stays in the total, leaves the follow-up list.
  Future<void> keep(AssumedGlass g) =>
      throw UnimplementedError('AssumedWaterWriter.keep');

  /// Remove: subtract exactly [g]'s ml, leave a tombstone.
  Future<void> remove(AssumedGlass g) =>
      throw UnimplementedError('AssumedWaterWriter.remove');
}
