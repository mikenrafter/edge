// Decisions belong to the open day breakdown. Persistence belongs to the
// existing activity and moment stores, joined by LocalRepository.saveDayReview.
import '../gestures/moment_follow_ups.dart';
import '../gestures/moment_review_queue.dart';
import '../models/activity_suggestion.dart';

class ActivityDecision {
  const ActivityDecision(this.suggestion, {required this.keep, this.startTs,
      this.endTs, this.workoutType});
  final int? startTs, endTs;
  final String? workoutType;
  final ActivitySuggestion suggestion;
  final bool keep;
}

class MomentDecision {
  const MomentDecision(this.moment, this.decision);
  final PendingMoment moment;
  final ReviewDecision decision;
}

class DayReviewReceipt {
  const DayReviewReceipt({this.followUpFailed = false});
  /// The DB committed, but a refresh or export needs another attempt.
  final bool followUpFailed;
}

class WorkoutWindow {
  const WorkoutWindow(this.startTs, this.endTs, this.type);
  final int startTs, endTs;
  final String type;
}

class MomentWorkoutDecision {
  const MomentWorkoutDecision(this.moment, this.window);
  final PendingMoment moment;
  final WorkoutWindow window;
}
