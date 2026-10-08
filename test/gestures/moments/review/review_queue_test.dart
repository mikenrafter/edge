// The review queue (pure): decisions are queued, not applied. Editable,
// undoable, keyed by REVIEW KEY so a moment and an assumed glass of the same
// minute never collide; a range is ONE item; stale drafts fall away; JSON is
// tolerant. RED: every method is a throwing stub.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';

import '../../../support/moment_review_fakes.dart';

final kA = ReviewKey.moment(mA);
final kB = ReviewKey.moment(mB);
final kC = ReviewKey.moment(mC);

void main() {
  group('review keys', () {
    test('a moment and a glass of the same minute are different keys', () {
      expect(mA.key, gSameMinuteAsA.key, reason: 'precondition: same raw key');
      expect(ReviewKey.moment(mA), 'moment:2026-10-06 09:15');
      expect(ReviewKey.glass(gSameMinuteAsA), 'glass:2026-10-06 09:15');
      expect(ReviewKey.moment(mA), isNot(ReviewKey.glass(gSameMinuteAsA)));
    });

    test('a range key names both ends by their plain keys', () {
      const r = ReviewRange(
          choice: MomentChoice.nap, startKey: '2026-10-06 09:15', endKey: '2026-10-06 10:05');
      expect(ReviewKey.range(r), 'range:2026-10-06 09:15|2026-10-06 10:05');
    });
  });

  group('queueing', () {
    test('empty queue: isEmpty, length 0, nothing decided', () {
      const q = MomentReviewQueue.empty;
      expect(q.isEmpty, isTrue);
      expect(q.length, 0);
      expect(q.decisionFor(kA), isNull);
    });

    test('withDecision queues and does not mutate the original', () {
      const q0 = MomentReviewQueue.empty;
      final q1 = q0.withDecision(
          kA, const ReviewDecision.label(MomentChoice.caffeine, value: 80));
      expect(q0.isEmpty, isTrue, reason: 'immutable');
      expect(q1.length, 1);
      final d = q1.decisionFor(kA)!;
      expect(d.kind, ReviewDecisionKind.label);
      expect(d.choice, MomentChoice.caffeine);
      expect(d.value, 80);
    });

    test('editing replaces the earlier decision (still one item)', () {
      final q = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.label(MomentChoice.meal))
          .withDecision(kA, const ReviewDecision.skip());
      expect(q.length, 1);
      expect(q.decisionFor(kA)!.kind, ReviewDecisionKind.skip);
    });

    test('undo removes it; undoing an unknown key changes nothing', () {
      final q = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.label(MomentChoice.meal));
      expect(q.without(kA).isEmpty, isTrue);
      expect(q.without(kB).length, 1);
    });

    test('symptom, skip and other-with-note carry their payload', () {
      final q = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.symptom(symptomDesc))
          .withDecision(kB, const ReviewDecision.skip())
          .withDecision(kC,
              const ReviewDecision.label(MomentChoice.other, note: 'walk'));
      expect(q.decisionFor(kA)!.symptom, symptomDesc);
      expect(q.decisionFor(kB)!.kind, ReviewDecisionKind.skip);
      expect(q.decisionFor(kC)!.note, 'walk');
      expect(q.length, 3);
    });

    test('keep/remove only on a glass; label/skip/symptom only on a moment', () {
      final kg = ReviewKey.glass(gNoon);
      final q = MomentReviewQueue.empty;
      expect(() => q.withDecision(kA, const ReviewDecision.keepGlass()),
          throwsArgumentError);
      expect(() => q.withDecision(kg, const ReviewDecision.skip()),
          throwsArgumentError);
      expect(
          () => q.withDecision(
              kg, const ReviewDecision.label(MomentChoice.water)),
          throwsArgumentError);
      final ok = q
          .withDecision(kg, const ReviewDecision.removeGlass())
          .decisionFor(kg)!;
      expect(ok.kind, ReviewDecisionKind.removeGlass);
    });

    test('a moment and a glass of the same minute are two items', () {
      final q = MomentReviewQueue.empty
          .withDecision(ReviewKey.moment(mA), const ReviewDecision.skip())
          .withDecision(
              ReviewKey.glass(gSameMinuteAsA), const ReviewDecision.keepGlass());
      expect(q.length, 2);
    });
  });

  group('ranges', () {
    test('the earlier moment is the start, whichever order they are paired in',
        () {
      final q1 = MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap);
      final q2 = MomentReviewQueue.empty.withRange(mB, mA, MomentChoice.nap);
      for (final q in [q1, q2]) {
        expect(q.ranges.single.startKey, mA.key);
        expect(q.ranges.single.endKey, mB.key);
        expect(q.ranges.single.choice, MomentChoice.nap);
      }
    });

    test('a range is ONE item, and both ends point at it', () {
      final q = MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.workout);
      expect(q.length, 1);
      expect(q.rangeOf(mA.key), same(q.ranges.single));
      expect(q.rangeOf(mB.key), same(q.ranges.single));
      expect(q.rangeOf(mC.key), isNull);
    });

    test('only nap and workout can pair; a moment cannot pair with itself', () {
      for (final c in MomentChoice.values) {
        final capable = c == MomentChoice.nap || c == MomentChoice.workout;
        expect(isRangeChoice(c), capable, reason: c.id);
      }
      expect(() => MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.caffeine),
          throwsArgumentError);
      expect(() => MomentReviewQueue.empty.withRange(mA, mA, MomentChoice.nap),
          throwsArgumentError);
    });

    test('pairing drops the ends\' own decisions', () {
      final q = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.label(MomentChoice.nap))
          .withDecision(kB, const ReviewDecision.skip())
          .withRange(mA, mB, MomentChoice.nap);
      expect(q.decisionFor(kA), isNull);
      expect(q.decisionFor(kB), isNull);
      expect(q.length, 1);
    });

    test('undoing EITHER end dissolves the whole range', () {
      final q = MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap);
      expect(q.without(kA).isEmpty, isTrue);
      expect(q.without(kB).isEmpty, isTrue);
    });

    test('deciding something else for an end dissolves the range; the partner '
        'becomes undecided', () {
      final q = MomentReviewQueue.empty
          .withRange(mA, mB, MomentChoice.nap)
          .withDecision(kB, const ReviewDecision.skip());
      expect(q.ranges, isEmpty);
      expect(q.decisionFor(kB)!.kind, ReviewDecisionKind.skip);
      expect(q.decisionFor(kA), isNull);
      expect(q.rangeOf(mA.key), isNull);
    });

    test('pairing an end that is already in a range dissolves the old range',
        () {
      final q = MomentReviewQueue.empty
          .withRange(mA, mB, MomentChoice.nap)
          .withRange(mB, mC, MomentChoice.nap);
      expect(q.ranges, hasLength(1));
      expect(q.ranges.single.startKey, mB.key);
      expect(q.ranges.single.endKey, mC.key);
      expect(q.rangeOf(mA.key), isNull);
    });
  });

  group('stale drafts', () {
    test('dropStale keeps only what is still pending', () {
      final kg = ReviewKey.glass(gNoon);
      final q = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.skip())
          .withDecision(kB, const ReviewDecision.skip())
          .withDecision(kg, const ReviewDecision.keepGlass());
      final out = q.dropStale({kA, kg});
      expect(out.decisions.keys.toSet(), {kA, kg});
    });

    test('a range goes if EITHER end is no longer pending', () {
      final q = MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap);
      expect(q.dropStale({kA, kB}).length, 1);
      expect(q.dropStale({kA}).isEmpty, isTrue);
      expect(q.dropStale({kB}).isEmpty, isTrue);
    });

    test('a moment key does not keep a glass draft of the same minute alive',
        () {
      final q = MomentReviewQueue.empty.withDecision(
          ReviewKey.glass(gSameMinuteAsA), const ReviewDecision.keepGlass());
      expect(q.dropStale({ReviewKey.moment(mA)}).isEmpty, isTrue);
    });
  });

  group('JSON', () {
    test('round-trips every decision kind and a range, through real JSON text',
        () {
      final q = MomentReviewQueue.empty
          .withDecision(kA,
              const ReviewDecision.label(MomentChoice.alcohol, value: 1.5))
          .withDecision(kC, const ReviewDecision.symptom(symptomDesc))
          .withDecision(ReviewKey.moment(mLate),
              const ReviewDecision.label(MomentChoice.other, note: 'tea'))
          .withDecision(ReviewKey.moment(mEarly), const ReviewDecision.skip())
          .withDecision(
              ReviewKey.glass(gNoon), const ReviewDecision.removeGlass())
          .withRange(mB, const PendingMoment(date: '2026-10-06', hhmm: '11:00'),
              MomentChoice.workout);
      final back =
          MomentReviewQueue.fromJson(jsonDecode(jsonEncode(q.toJson())));
      expect(back.length, q.length);
      expect(back.decisionFor(kA)!.value, 1.5);
      expect(back.decisionFor(kC)!.symptom, symptomDesc);
      expect(back.decisionFor(ReviewKey.moment(mLate))!.note, 'tea');
      expect(back.decisionFor(ReviewKey.glass(gNoon))!.kind,
          ReviewDecisionKind.removeGlass);
      expect(back.ranges.single, q.ranges.single);
    });

    test('garbage gives an empty queue, never a throw', () {
      for (final bad in <Object?>[
        null,
        42,
        'x',
        <Object?>[],
        {'decisions': 'nope'},
        {'decisions': {kA: 7}},
      ]) {
        expect(MomentReviewQueue.fromJson(bad).isEmpty, isTrue, reason: '$bad');
      }
    });

    test('one malformed entry is dropped, the rest survive', () {
      final good = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.skip())
          .toJson();
      final json = jsonDecode(jsonEncode(good)) as Map<String, dynamic>;
      (json['decisions'] as Map<String, dynamic>)[kB] = {'kind': 'bogus'};
      (json['decisions'] as Map<String, dynamic>)[kC] = {
        'kind': 'label'
      }; // a label with no choice
      final back = MomentReviewQueue.fromJson(json);
      expect(back.decisions.keys, [kA]);
    });

    test('an unknown choice id is dropped, not defaulted', () {
      final json = {
        'decisions': {
          kA: {'kind': 'label', 'choice': 'teleport'}
        },
        'ranges': <Object?>[],
      };
      expect(MomentReviewQueue.fromJson(json).isEmpty, isTrue);
    });

    test('a decision JSON for an unknown choice returns null', () {
      expect(ReviewDecision.fromJson({'kind': 'label', 'choice': 'teleport'}),
          isNull);
      expect(ReviewDecision.fromJson('x'), isNull);
    });
  });
}
