// moment_review_queue.dart — the QUEUED decisions of the marked-moment review.
//
// RED stubs: every method throws until the GREEN phase.
//
// A review decision is queued, not applied, until the wearer presses Save. The
// queue is pure data: it never touches a database. It is keyed by REVIEW KEY
// (`moment:<date hhmm>` / `glass:<date hhmm>`), because a moment and an assumed
// glass can share the same `<date> <hhmm>` and must not collide.
//
// A RANGE pairs two pending moments (a start mark and an end mark of the same
// thing). Only nap and workout are range-capable: they are the two answers that
// already have a start/end writer (the nap edit and the manual workout). The
// earlier moment is always the start. A range counts as ONE item; its two
// moments carry no decision of their own while the range stands.

import '../data/assumed_water.dart';
import '../gestures/symptom_description.dart';
import 'moment_follow_ups.dart';

class ReviewKey {
  const ReviewKey._();

  /// `moment:2026-10-06 09:15`.
  static String moment(PendingMoment m) => throw UnimplementedError('RED stub');

  /// `glass:2026-10-06 08:00`.
  static String glass(AssumedGlass g) => throw UnimplementedError('RED stub');

  /// `range:<startKey>|<endKey>` over the moments' plain keys.
  static String range(ReviewRange r) => throw UnimplementedError('RED stub');
}

enum ReviewDecisionKind { label, skip, symptom, keepGlass, removeGlass }

class ReviewDecision {
  const ReviewDecision._(this.kind,
      {this.choice, this.value, this.note, this.symptom});

  /// A quick answer. [value] only for a dose field; [note] only for Other.
  const ReviewDecision.label(MomentChoice c, {double? value, String? note})
      : this._(ReviewDecisionKind.label, choice: c, value: value, note: note);
  const ReviewDecision.skip() : this._(ReviewDecisionKind.skip);
  const ReviewDecision.symptom(SymptomDescription d)
      : this._(ReviewDecisionKind.symptom,
            choice: MomentChoice.symptom, symptom: d);
  const ReviewDecision.keepGlass() : this._(ReviewDecisionKind.keepGlass);
  const ReviewDecision.removeGlass() : this._(ReviewDecisionKind.removeGlass);

  final ReviewDecisionKind kind;
  final MomentChoice? choice;
  final double? value;
  final String? note;
  final SymptomDescription? symptom;

  /// Whether this decision belongs on a moment (true) or an assumed glass.
  bool get forMoment => throw UnimplementedError('RED stub');

  Map<String, Object?> toJson() => throw UnimplementedError('RED stub');

  /// Null when [j] is malformed (unknown kind, a label with no choice, ...).
  static ReviewDecision? fromJson(Object? j) =>
      throw UnimplementedError('RED stub');

  @override
  bool operator ==(Object other) => throw UnimplementedError('RED stub');

  @override
  int get hashCode => throw UnimplementedError('RED stub');
}

/// Two moments forming one time range. Keys are the moments' PLAIN keys
/// (`PendingMoment.key`). [startKey] is always the earlier minute.
class ReviewRange {
  const ReviewRange(
      {required this.choice, required this.startKey, required this.endKey});

  /// Nap or Workout.
  final MomentChoice choice;
  final String startKey, endKey;

  @override
  bool operator ==(Object other) => throw UnimplementedError('RED stub');

  @override
  int get hashCode => throw UnimplementedError('RED stub');
}

/// Choices that can pair two moments into a range.
bool isRangeChoice(MomentChoice c) => throw UnimplementedError('RED stub');

class MomentReviewQueue {
  const MomentReviewQueue(
      {this.decisions = const {}, this.ranges = const []});

  static const MomentReviewQueue empty = MomentReviewQueue();

  /// By review key. A moment inside a range has no entry here.
  final Map<String, ReviewDecision> decisions;
  final List<ReviewRange> ranges;

  bool get isEmpty => throw UnimplementedError('RED stub');

  /// Items to apply: one per decision plus one per range.
  int get length => throw UnimplementedError('RED stub');

  ReviewDecision? decisionFor(String reviewKey) =>
      throw UnimplementedError('RED stub');

  /// The range the moment with this PLAIN key is an end of, or null.
  ReviewRange? rangeOf(String momentKey) =>
      throw UnimplementedError('RED stub');

  /// Replaces any earlier decision for [reviewKey]. If that moment was in a
  /// range, the range is dissolved (its partner becomes undecided). Throws
  /// ArgumentError for a kind that does not fit the key (keep/remove on a
  /// moment, a label/skip/symptom on a glass).
  MomentReviewQueue withDecision(String reviewKey, ReviewDecision d) =>
      throw UnimplementedError('RED stub');

  /// Undo. Removing either end of a range dissolves the whole range. Unknown
  /// key: unchanged.
  MomentReviewQueue without(String reviewKey) =>
      throw UnimplementedError('RED stub');

  /// Pairs [a] and [b] (either order) as one [choice] range; the earlier is the
  /// start. Each end's own queued decision is dropped; an end already in another
  /// range dissolves that range. Throws ArgumentError for a non-range choice or
  /// the same moment twice.
  MomentReviewQueue withRange(
          PendingMoment a, PendingMoment b, MomentChoice choice) =>
      throw UnimplementedError('RED stub');

  /// Keeps only what is still pending. [pendingReviewKeys] holds the review
  /// keys of every moment and glass still waiting. A range goes if either end
  /// is no longer pending.
  MomentReviewQueue dropStale(Set<String> pendingReviewKeys) =>
      throw UnimplementedError('RED stub');

  Map<String, Object?> toJson() => throw UnimplementedError('RED stub');

  /// Tolerant: null, wrong types or garbage give [empty]; a malformed entry is
  /// dropped, the rest kept.
  static MomentReviewQueue fromJson(Object? j) =>
      throw UnimplementedError('RED stub');
}
