// The one carried prune-safety cursor of the official export (profile row
// `sync_cursor`, name `decoded_pruned_before`). Pure: no database, no clock.
//
// The fork's live cursor says "decoded rows below here were deleted". The
// official file carries a recomputed one so that (a) a mapped history starting
// mid-day marks its oldest partial day deleted, and (b) complete days restored
// from the exact archive well below the fork's live edge stay eligible. It never
// rises above the fork's value. Not `LocalDb._reconcilePrunedCursor`: its first
// two-hour-gap stop would turn an ordinary band-off night into a permanent edge.
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

  /// The `YYYY-MM-DD` label of the local day containing [sec]. The day
  /// inventory labels days through this, so labels and the cursor share a zone.
  String dayLabel(int sec);

  /// Epoch seconds of the local midnight that starts [label] (null if malformed).
  int? dayStartSec(String label);

  /// Epoch seconds of the local midnight that ends [label] (null if malformed).
  int? dayEndSec(String label);
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

  @override
  String dayLabel(int sec) => dayLabelOf(DateTime.fromMillisecondsSinceEpoch(sec * 1000));
  @override
  int? dayStartSec(String label) => localDayStartSec(label);
  @override
  int? dayEndSec(String label) => localDayEndSec(label);
}

/// The cursor row for the official file (spec §4.3).
///
/// [forkCursorSec] is the fork's `decoded_pruned_before`, null when it has none.
/// [oldestExactSec] is the oldest exact second present in the MAPPED decoded
/// tables: MIN(rec_ts) WHERE rec_ts > 0 after archive expansion, live-winner
/// resolution and deletion windows. NULL/non-positive input means no exact
/// second survives. The fork cursor, when present, must be positive.
PrunedBeforeChoice chooseDecodedPrunedBefore({
  required int? forkCursorSec,
  required int? oldestExactSec,
  LocalCalendar calendar = const DayLabelCalendar(),
}) {
  if (forkCursorSec != null && forkCursorSec <= 0) {
    throw ArgumentError.value(forkCursorSec, 'forkCursorSec', 'must be positive');
  }
  if (forkCursorSec == null) {
    return const PrunedBeforeChoice(null, PrunedBeforeReason.noForkCursor);
  }
  if (oldestExactSec == null || oldestExactSec <= 0) {
    return PrunedBeforeChoice(forkCursorSec, PrunedBeforeReason.noExactInput);
  }
  final edge = calendar.midnightAtOrAfter(oldestExactSec);
  return edge > forkCursorSec
      ? PrunedBeforeChoice(forkCursorSec, PrunedBeforeReason.cappedAtForkCursor)
      : PrunedBeforeChoice(edge, PrunedBeforeReason.oldestExactMidnight);
}
