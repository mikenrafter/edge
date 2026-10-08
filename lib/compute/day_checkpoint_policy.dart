// When a stored `day_checkpoint` may be resumed from, and the packing of the
// revision vector it carries. Pure Dart: the engine reads the live `input_rev`
// buckets and the context, this decides. No part of this ever guesses: any
// doubt is a full pass.
//
// A checkpoint folds every row with `rec_ts < cpRecTs`, and `cpRecTs` is a
// bucket boundary (a multiple of [kRevBucketSec]) so the folded rows are exactly
// the closed buckets `[firstBucket, cpRecTs ~/ kRevBucketSec)`. Resuming is
// sound only while every one of those buckets has the revision it had when the
// checkpoint was written: the triggers on `decoded_onehz` / `decoded_rr` bump a
// bucket on every INSERT, UPDATE and DELETE (so a replaced earlier `rec_ts`, a
// counter-reset re-key, an eviction and a late-arriving row into an empty hour
// all show up), and the bucket still being appended to is never part of the
// checkpoint.

import 'dart:typed_data';

import '../data/day_checkpoint.dart';

/// Width of one `input_rev` bucket.
const int kRevBucketSec = 900;

/// Layout version of [DayCheckpoint.revVec] and the state blob. 2: the state no
/// longer depends on the sleep window (per-second wake detail instead of wake
/// sums), and carries the motion buckets and the minute bills. 3: also carries
/// the day's streaming RR state (corrector and irregular-rhythm screen) and the
/// three day curves, folded from its beats. 4: the screen state inside it is
/// analytics' version-2 checkpoint (it counts the beats and windows the PRV
/// diagnostics report); a layout-3 blob is not resumed, the day refolds.
const int kDayCheckpointFmt = 4;

/// The checkpoint folds the day's BEATS up to `cpRecTs - kRrFoldGuardSec`, not up
/// to `cpRecTs`: a record's earlier beats sit before its own second (they are
/// placed backwards from the record's sub-second anchor), so cutting the beats at
/// the 1 Hz boundary itself would put beats of a still-open bucket in a state the
/// revision check does not cover. Every folded beat then comes from a closed
/// bucket. Cut by beat TIME rather than by row because the day's beat axis is
/// non-decreasing in time (`monotonizeBeatAxis`), so the folded beats are a
/// prefix of the day's list and the rest is its tail.
const int kRrFoldGuardSec = 30;

/// A resumed pass reads `decoded_rr` rows from `cpRecTs - kRrReadSlackSec`:
/// every beat of the tail has a row at or after `cpRecTs - kRrFoldGuardSec - 1`
/// (a beat is never later than its record's second plus one), and the rest of
/// the slack is for the beats of those rows that the state already holds.
const int kRrReadSlackSec = 60;

/// Epoch ms of the edge between the beats a checkpoint at [cpRecTs] folded and
/// the tail.
double rrFoldEdgeMs(int cpRecTs) => (cpRecTs - kRrFoldGuardSec) * 1000.0;

/// `(bucket, rev)` pairs, big-endian int32 each, in bucket order.
Uint8List encodeRevVec(Map<int, int> revs) {
  final keys = revs.keys.toList()..sort();
  final out = ByteData(keys.length * 8);
  for (var i = 0; i < keys.length; i++) {
    out.setInt32(i * 8, keys[i]);
    out.setInt32(i * 8 + 4, revs[keys[i]]!);
  }
  return out.buffer.asUint8List();
}

/// Inverse of [encodeRevVec]; null for a blob that is not whole pairs.
Map<int, int>? decodeRevVec(Uint8List bytes) {
  if (bytes.length % 8 != 0) return null;
  final data = ByteData.sublistView(bytes);
  return {
    for (var i = 0; i < bytes.length; i += 8)
      data.getInt32(i): data.getInt32(i + 4),
  };
}

/// Everything outside a day's rows that the folded state depends on. Two days
/// with equal parts share a signature; any difference means the state was
/// folded under other rules. The day's start and end are epoch seconds from the
/// DST-aware local-day helpers (never `+ 86400`), and the UTC offset at each end
/// is included so a clock change inside the day moves the signature even where
/// the two epochs alone would not.
///
/// The sleep window's onset and offset are not part of it: the state is folded
/// without reference to the window, which moves on most passes, so
/// [sleepOnsetSec] and [sleepOffsetSec] are accepted (callers that still hold
/// them) and ignored. [sleepSource] (the user's own window or the detector's)
/// is still signed.
String dayContextSig({
  required String profileSig,
  required String priorityKey,
  required String? deviceFamily,
  required int dayStartSec,
  required int dayEndSec,
  required int tzOffsetAtStartMin,
  required int tzOffsetAtEndMin,
  int? sleepOnsetSec,
  int? sleepOffsetSec,
  required String? sleepSource,
  required double? dynFloorG,
}) =>
    [
      profileSig,
      priorityKey,
      deviceFamily ?? '-',
      dayStartSec,
      dayEndSec,
      tzOffsetAtStartMin,
      tzOffsetAtEndMin,
      sleepSource ?? '-',
      dynFloorG ?? '-',
    ].join('|');

/// Whether to resume, and when not, why (for the `[perf]` log).
class ResumeDecision {
  const ResumeDecision.resume() : reason = null;
  const ResumeDecision.full(String this.reason);

  final String? reason;
  bool get resume => reason == null;
}

/// [liveRevs] is the live `input_rev` of the buckets
/// `[firstBucket, cp.cpRecTs ~/ kRevBucketSec)` read just now, only buckets
/// that exist, keyed exactly as [DayCheckpoint.revVec] was when written.
ResumeDecision decideResume({
  required DayCheckpoint? cp,
  required int algoVersion,
  required String ctxSig,
  required Map<int, int> liveRevs,
}) {
  if (cp == null) return const ResumeDecision.full('none');
  if (cp.algoVersion != algoVersion) return const ResumeDecision.full('algo');
  if (cp.fmt != kDayCheckpointFmt) return const ResumeDecision.full('fmt');
  if (cp.cpRecTs <= 0 || cp.cpRecTs % kRevBucketSec != 0) {
    return const ResumeDecision.full('unaligned');
  }
  if (cp.ctxSig != ctxSig) return const ResumeDecision.full('context');
  final stored = decodeRevVec(cp.revVec);
  if (stored == null) return const ResumeDecision.full('unreadable');
  final cpBucket = cp.cpRecTs ~/ kRevBucketSec;
  for (final e in liveRevs.entries) {
    if (e.key >= cpBucket) return const ResumeDecision.full('open_bucket');
    if (stored[e.key] != e.value) return ResumeDecision.full('revised:${e.key}');
  }
  // A bucket the checkpoint had folded that is gone now (evicted, deleted).
  for (final b in stored.keys) {
    if (!liveRevs.containsKey(b)) return ResumeDecision.full('lost:$b');
  }
  return const ResumeDecision.resume();
}
