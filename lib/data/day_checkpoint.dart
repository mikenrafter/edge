import 'dart:typed_data';

/// One stored resume point of a day's incremental derive (`day_checkpoint`).
///
/// Disposable scratch, never a result: it only lets a pass skip re-reading and
/// re-folding what an earlier pass already folded. The day's `day_result` row
/// stays the one place results (and the frozen-row rule) live. A checkpoint is
/// usable only while every field below still matches the live inputs; any
/// mismatch means "run the full pass", never "use it anyway".
class DayCheckpoint {
  const DayCheckpoint({
    required this.dayId,
    required this.algoVersion,
    required this.fmt,
    required this.ctxSig,
    required this.cpRecTs,
    required this.revVec,
    required this.state,
    required this.nightRef,
    required this.computedAt,
  });

  final String dayId;
  final int algoVersion;

  /// Layout version of [state] and [revVec]; a different one is unreadable.
  final int fmt;

  /// Everything outside the day's rows that the folded state depends on
  /// (profile, ownership priority, device family, tz offsets, sleep bounds).
  final String ctxSig;

  /// Everything with `rec_ts` below this is folded into [state].
  final int cpRecTs;

  /// `(bucket, rev)` pairs of the closed `input_rev` buckets at write time.
  final Uint8List revVec;

  /// The packed accumulators.
  final Uint8List state;

  /// Which stored night (candidate + its input digest) the state was built
  /// beside, or null before the night is settled.
  final String? nightRef;

  final int computedAt;
}
