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

/// The cursor row for the official file (spec §4.3).
///
/// [forkCursorSec] is the fork's `decoded_pruned_before`, null when it has none.
/// [oldestExactSec] is the oldest exact second present in the MAPPED decoded
/// tables (after archive expansion, live-winner resolution and deletion
/// windows), null when none survives. Both are epoch seconds and must be
/// positive: zero would otherwise read as "everything before 1970 was pruned".
PrunedBeforeChoice chooseDecodedPrunedBefore({
  required int? forkCursorSec,
  required int? oldestExactSec,
  LocalCalendar calendar = const DayLabelCalendar(),
}) {
  if (forkCursorSec != null && forkCursorSec <= 0) {
    throw ArgumentError.value(forkCursorSec, 'forkCursorSec', 'must be positive');
  }
  if (oldestExactSec != null && oldestExactSec <= 0) {
    throw ArgumentError.value(oldestExactSec, 'oldestExactSec', 'must be positive');
  }
  if (forkCursorSec == null) {
    return const PrunedBeforeChoice(null, PrunedBeforeReason.noForkCursor);
  }
  if (oldestExactSec == null) {
    return PrunedBeforeChoice(forkCursorSec, PrunedBeforeReason.noExactInput);
  }
  final edge = calendar.midnightAtOrAfter(oldestExactSec);
  return edge > forkCursorSec
      ? PrunedBeforeChoice(forkCursorSec, PrunedBeforeReason.cappedAtForkCursor)
      : PrunedBeforeChoice(edge, PrunedBeforeReason.oldestExactMidnight);
}
