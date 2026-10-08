// moment_review_queue.dart — the QUEUED decisions of the marked-moment review.
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
import '../data/moment_label.dart' show momentLocalTime;
import 'moment_follow_ups.dart';
import 'symptom_description.dart';

class ReviewKey {
  const ReviewKey._();

  static const String _momentPrefix = 'moment:';
  static const String _glassPrefix = 'glass:';

  /// `moment:2026-10-06 09:15`.
  static String moment(PendingMoment m) => '$_momentPrefix${m.key}';

  /// `glass:2026-10-06 08:00`.
  static String glass(AssumedGlass g) => '$_glassPrefix${g.key}';

  /// `range:<startKey>|<endKey>` over the moments' plain keys.
  static String range(ReviewRange r) => 'range:${r.startKey}|${r.endKey}';

  static bool isMoment(String reviewKey) => reviewKey.startsWith(_momentPrefix);
  static bool isGlass(String reviewKey) => reviewKey.startsWith(_glassPrefix);

  /// The plain `PendingMoment.key` of a `moment:` review key.
  static String plainOf(String reviewKey) =>
      reviewKey.substring(_momentPrefix.length);
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
  bool get forMoment =>
      kind != ReviewDecisionKind.keepGlass &&
      kind != ReviewDecisionKind.removeGlass;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'choice': ?choice?.id,
        'value': ?value,
        'note': ?note,
        'symptom': ?symptom?.toJson(),
      };

  /// Null when [j] is malformed (unknown kind, a label with no choice, ...).
  static ReviewDecision? fromJson(Object? j) {
    if (j is! Map) return null;
    final kindName = j['kind'];
    ReviewDecisionKind? kind;
    for (final k in ReviewDecisionKind.values) {
      if (k.name == kindName) kind = k;
    }
    if (kind == null) return null;
    switch (kind) {
      case ReviewDecisionKind.skip:
        return const ReviewDecision.skip();
      case ReviewDecisionKind.keepGlass:
        return const ReviewDecision.keepGlass();
      case ReviewDecisionKind.removeGlass:
        return const ReviewDecision.removeGlass();
      case ReviewDecisionKind.symptom:
        final d = SymptomDescription.fromJson(j['symptom']);
        return d == null ? null : ReviewDecision.symptom(d);
      case ReviewDecisionKind.label:
        final cid = j['choice'];
        final c = MomentChoice.fromId(cid is String ? cid : null);
        if (c == null || c == MomentChoice.symptom) return null;
        final v = j['value'];
        if (v != null && (v is! num || !v.isFinite)) return null;
        final n = j['note'];
        if (n != null && n is! String) return null;
        return ReviewDecision.label(c,
            value: (v as num?)?.toDouble(), note: n as String?);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ReviewDecision &&
      other.kind == kind &&
      other.choice == choice &&
      other.value == value &&
      other.note == note &&
      other.symptom == symptom;

  @override
  int get hashCode => Object.hash(kind, choice, value, note, symptom);
}

/// Two moments forming one time range. Keys are the moments' PLAIN keys
/// (`PendingMoment.key`). [startKey] is always the earlier minute.
class ReviewRange {
  const ReviewRange(
      {required this.choice,
      required this.startKey,
      required this.endKey,
      this.workoutType});

  /// Nap or Workout.
  final MomentChoice choice;
  final String startKey, endKey;

  /// A workout range's `sessions.type` key (the activity picker's `typeKey`);
  /// null means the default, `other`: a marked moment does not say which sport.
  final String? workoutType;

  @override
  bool operator ==(Object other) =>
      other is ReviewRange &&
      other.choice == choice &&
      other.startKey == startKey &&
      other.endKey == endKey &&
      other.workoutType == workoutType;

  @override
  int get hashCode => Object.hash(choice, startKey, endKey, workoutType);
}

/// Choices that can pair two moments into a range.
bool isRangeChoice(MomentChoice c) =>
    c == MomentChoice.nap || c == MomentChoice.workout;

class MomentReviewQueue {
  const MomentReviewQueue(
      {this.decisions = const {}, this.ranges = const []});

  static const MomentReviewQueue empty = MomentReviewQueue();

  /// By review key. A moment inside a range has no entry here.
  final Map<String, ReviewDecision> decisions;
  final List<ReviewRange> ranges;

  bool get isEmpty => decisions.isEmpty && ranges.isEmpty;

  /// Items to apply: one per decision plus one per range.
  int get length => decisions.length + ranges.length;

  ReviewDecision? decisionFor(String reviewKey) => decisions[reviewKey];

  /// The range the moment with this PLAIN key is an end of, or null.
  ReviewRange? rangeOf(String momentKey) {
    for (final r in ranges) {
      if (r.startKey == momentKey || r.endKey == momentKey) return r;
    }
    return null;
  }

  List<ReviewRange> _without(String momentKey) =>
      [for (final r in ranges) if (r.startKey != momentKey && r.endKey != momentKey) r];

  /// Replaces any earlier decision for [reviewKey]. If that moment was in a
  /// range, the range is dissolved (its partner becomes undecided). Throws
  /// ArgumentError for a kind that does not fit the key (keep/remove on a
  /// moment, a label/skip/symptom on a glass).
  MomentReviewQueue withDecision(String reviewKey, ReviewDecision d) {
    final moment = ReviewKey.isMoment(reviewKey);
    if (!moment && !ReviewKey.isGlass(reviewKey)) {
      throw ArgumentError.value(reviewKey, 'reviewKey', 'not a review key');
    }
    if (d.forMoment != moment) {
      throw ArgumentError.value(
          d.kind, 'd', 'does not fit ${moment ? 'a moment' : 'an assumed glass'}');
    }
    return MomentReviewQueue(
      decisions: {...decisions, reviewKey: d},
      ranges: moment ? _without(ReviewKey.plainOf(reviewKey)) : ranges,
    );
  }

  /// Undo. Removing either end of a range dissolves the whole range. Unknown
  /// key: unchanged.
  MomentReviewQueue without(String reviewKey) {
    if (decisions.containsKey(reviewKey)) {
      return MomentReviewQueue(
          decisions: {...decisions}..remove(reviewKey), ranges: ranges);
    }
    if (ReviewKey.isMoment(reviewKey)) {
      final plain = ReviewKey.plainOf(reviewKey);
      if (rangeOf(plain) != null) {
        return MomentReviewQueue(decisions: decisions, ranges: _without(plain));
      }
    }
    return this;
  }

  /// Pairs [a] and [b] (either order) as one [choice] range; the earlier is the
  /// start. Each end's own queued decision is dropped; an end already in another
  /// range dissolves that range. Throws ArgumentError for a non-range choice or
  /// the same moment twice. [workoutType] is kept for a workout range only.
  MomentReviewQueue withRange(PendingMoment a, PendingMoment b, MomentChoice choice,
      {String? workoutType}) {
    if (!isRangeChoice(choice)) {
      throw ArgumentError.value(choice, 'choice', 'cannot form a range');
    }
    if (a.key == b.key) {
      throw ArgumentError.value(b.key, 'b', 'a moment cannot pair with itself');
    }
    final first = a.local.isAfter(b.local) ? b : a;
    final second = identical(first, a) ? b : a;
    final kept = [
      for (final r in ranges)
        if (r.startKey != a.key &&
            r.endKey != a.key &&
            r.startKey != b.key &&
            r.endKey != b.key)
          r
    ];
    return MomentReviewQueue(
      decisions: {...decisions}
        ..remove(ReviewKey.moment(a))
        ..remove(ReviewKey.moment(b)),
      ranges: [
        ...kept,
        ReviewRange(
            choice: choice,
            startKey: first.key,
            endKey: second.key,
            workoutType: choice == MomentChoice.workout ? workoutType : null),
      ],
    );
  }

  /// Keeps only what is still pending. [pendingReviewKeys] holds the review
  /// keys of every moment and glass still waiting. A range goes if either end
  /// is no longer pending.
  MomentReviewQueue dropStale(Set<String> pendingReviewKeys) =>
      MomentReviewQueue(
        decisions: {
          for (final e in decisions.entries)
            if (pendingReviewKeys.contains(e.key)) e.key: e.value,
        },
        ranges: [
          for (final r in ranges)
            if (pendingReviewKeys.contains('moment:${r.startKey}') &&
                pendingReviewKeys.contains('moment:${r.endKey}'))
              r,
        ],
      );

  Map<String, Object?> toJson() => {
        'decisions': {
          for (final e in decisions.entries) e.key: e.value.toJson(),
        },
        'ranges': [
          for (final r in ranges)
            {
              'choice': r.choice.id,
              'start': r.startKey,
              'end': r.endKey,
              'type': ?r.workoutType,
            },
        ],
      };

  /// Tolerant: null, wrong types or garbage give [empty]; a malformed entry is
  /// dropped, the rest kept.
  static MomentReviewQueue fromJson(Object? j) {
    if (j is! Map) return empty;
    final ranges = <ReviewRange>[];
    final used = <String>{};
    final rawRanges = j['ranges'];
    if (rawRanges is List) {
      for (final r in rawRanges) {
        if (r is! Map) continue;
        final cid = r['choice'];
        final c = MomentChoice.fromId(cid is String ? cid : null);
        final s = r['start'], e = r['end'], t = r['type'];
        if (c == null || !isRangeChoice(c) || s is! String || e is! String) {
          continue;
        }
        final sl = _plainTime(s), el = _plainTime(e);
        if (sl == null || el == null || !sl.isBefore(el)) continue;
        if (used.contains(s) || used.contains(e)) continue;
        used..add(s)..add(e);
        ranges.add(ReviewRange(
            choice: c,
            startKey: s,
            endKey: e,
            workoutType:
                c == MomentChoice.workout && t is String ? t : null));
      }
    }
    final decisions = <String, ReviewDecision>{};
    final raw = j['decisions'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final k = e.key;
        if (k is! String) continue;
        final moment = ReviewKey.isMoment(k);
        if (!moment && !ReviewKey.isGlass(k)) continue;
        final d = ReviewDecision.fromJson(e.value);
        if (d == null || d.forMoment != moment) continue;
        if (moment && used.contains(ReviewKey.plainOf(k))) continue;
        decisions[k] = d;
      }
    }
    return MomentReviewQueue(decisions: decisions, ranges: ranges);
  }

  static DateTime? _plainTime(String key) {
    final parts = key.split(' ');
    return parts.length == 2 ? momentLocalTime(parts[0], parts[1]) : null;
  }
}
