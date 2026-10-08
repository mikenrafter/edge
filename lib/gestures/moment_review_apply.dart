// moment_review_apply.dart — Save: applies every queued decision. RED stubs.
//
// Each decision goes through the EXISTING writer (MomentAnswerWriter.answer /
// skip / answerSymptom, AssumedWaterWriter.keep / remove, ReviewRangeWriter for
// ranges). One item failing does not lose the others: it stays queued and is
// reported. Applied items are handed to Tasker (one broadcast each) only after
// their write landed. Skips and assumed-glass decisions are not exported.

import '../data/assumed_water.dart';
import '../platform/tasker_moment_export.dart';
import 'moment_follow_ups.dart';
import 'moment_review_queue.dart';
import 'moment_review_range.dart';

class ReviewSaveReport {
  const ReviewSaveReport({
    this.applied = const [],
    this.alreadyAnswered = const [],
    this.failed = const {},
    this.remaining = MomentReviewQueue.empty,
  });

  /// Review keys (a range: `ReviewKey.range`) whose write landed.
  final List<String> applied;

  /// Moments that were answered elsewhere meanwhile: nothing was written, no
  /// broadcast was sent, and they leave the queue.
  final List<String> alreadyAnswered;

  /// Review key -> what went wrong. These stay in [remaining].
  final Map<String, Object> failed;

  /// The queue after Save: failed items only (stale items are dropped).
  final MomentReviewQueue remaining;
}

class MomentReviewApplier {
  MomentReviewApplier({
    this.writer = const MomentAnswerWriter(),
    this.assumedWriter = const AssumedWaterWriter(),
    this.ranges = const ReviewRangeWriter(),
    this.exporter,
  });

  final MomentAnswerWriter writer;
  final AssumedWaterWriter assumedWriter;
  final ReviewRangeWriter ranges;

  /// Null: a default `TaskerMomentExport()`.
  final TaskerMomentExport? exporter;

  /// Applies [queue] oldest first (a range sits at its start). Items whose
  /// moment or glass is not in [moments] / [glasses] are stale: dropped, not
  /// applied, not failed. A range is validated (`validateReviewRange`, against
  /// the writer's existing naps / spans PLUS ranges already applied in this
  /// run) before anything is written; a failure there is a failed item. A range
  /// that applies also labels both of its moments with the range's choice.
  Future<ReviewSaveReport> apply(
    MomentReviewQueue queue, {
    required List<PendingMoment> moments,
    required List<AssumedGlass> glasses,
    required DateTime now,
  }) =>
      throw UnimplementedError('RED stub');
}
