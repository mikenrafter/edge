// The one carried prune-safety cursor of the official export (profile row
// `sync_cursor`, name `decoded_pruned_before`). Pure: no database, no clock.
//
// STUB for the red phase: `chooseDecodedPrunedBefore` returns the fork's cursor
// unchanged, which is the "obsolete fork-live cursor" the tests must reject.
import '../day_label.dart';

/// Why the exporter emits (or omits) the cursor row.
enum PrunedBeforeReason {
  /// The fork has no cursor: nothing was ever pruned, so emit no row.
  noForkCursor,

  /// The mapped decoded tables hold no exact second: keep the fork's value.
  noExactInput,

  /// The first local midnight at or after the oldest exact second.
  oldestExactMidnight,

  /// That midnight lies above the fork's cursor, so the fork's value is kept.
  cappedAtForkCursor,
}

/// The cursor row to emit and why.
class PrunedBeforeChoice {
  const PrunedBeforeChoice(this.sec, this.reason);

  /// Epoch seconds, or null when no row is emitted.
  final int? sec;
  final PrunedBeforeReason reason;
}

/// Local-midnight arithmetic in one explicit zone. Production uses
/// [DayLabelCalendar]; tests pass a zone-database calendar.
abstract interface class LocalCalendar {
  /// Epoch seconds of the first local midnight at or after [sec].
  int midnightAtOrAfter(int sec);
}

/// The canonical calendar-day API (`day_label.dart`) in the process zone.
class DayLabelCalendar implements LocalCalendar {
  const DayLabelCalendar();
  @override
  int midnightAtOrAfter(int sec) {
    final at = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    final label = dayLabelOf(at);
    final start = localDayStartSec(label)!;
    return start >= sec ? start : localDayEndSec(label)!;
  }
}

/// First local midnight at or after [oldestExactSec], capped at [forkCursorSec].
PrunedBeforeChoice chooseDecodedPrunedBefore({
  required int? forkCursorSec,
  required int? oldestExactSec,
  LocalCalendar calendar = const DayLabelCalendar(),
}) => PrunedBeforeChoice(forkCursorSec, PrunedBeforeReason.noForkCursor);
