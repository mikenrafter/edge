// Save: apply every queued decision in one go, each through its EXISTING writer.
// One failure never loses the others (it is reported and stays queued); a range
// is validated and written as one item (nap path / workout path), then labels
// both of its moments; Tasker hears about each applied item once, only after
// its write landed. RED: the applier is a throwing stub.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_apply.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';

import '../../../support/moment_review_fakes.dart';

final kA = ReviewKey.moment(mA);
final kB = ReviewKey.moment(mB);
final kC = ReviewKey.moment(mC);
final kG = ReviewKey.glass(gNoon);

class _Rig {
  _Rig({
    Set<String> failMoments = const {},
    Set<String> alreadyMoments = const {},
    Set<String> failGlasses = const {},
    FakeRangeWriter? range,
    bool taskerOn = true,
  })  : log = WriteLog() {
    writer = FakeAnswerWriter(log: log, failOn: failMoments, already: alreadyMoments);
    glasses = FakeGlassWriter(log: log, failOn: failGlasses);
    ranges = range ?? FakeRangeWriter(log: log);
    exporter = TaskerMomentExport(
        connectionOn: () => taskerOn,
        emit: (e, x) async {
          log.entries.add('tasker:${x['type']}');
          sent.add(x);
          return true;
        });
    applier = MomentReviewApplier(
        writer: writer,
        assumedWriter: glasses,
        ranges: ranges,
        exporter: exporter);
  }
  final WriteLog log;
  late final FakeAnswerWriter writer;
  late final FakeGlassWriter glasses;
  late final FakeRangeWriter ranges;
  late final TaskerMomentExport exporter;
  late final MomentReviewApplier applier;
  final sent = <Map<String, Object>>[];

  Future<ReviewSaveReport> save(
    MomentReviewQueue q, {
    List<PendingMoment> moments = const [mA, mB, mC],
    List<AssumedGlass>? glassList,
  }) =>
      applier.apply(q,
          moments: moments,
          glasses: glassList ?? [gNoon],
          now: reviewNow);
}

void main() {
  group('apply everything', () {
    test('every kind of decision reaches its writer with its payload', () async {
      final r = _Rig();
      final q = MomentReviewQueue.empty
          .withDecision(
              kA, const ReviewDecision.label(MomentChoice.caffeine, value: 80))
          .withDecision(kB, const ReviewDecision.symptom(symptomDesc))
          .withDecision(kC, const ReviewDecision.skip())
          .withDecision(kG, const ReviewDecision.removeGlass());
      final rep = await r.save(q);
      expect(r.writer.answers.single.key, mA.key);
      expect(r.writer.answers.single.choice, MomentChoice.caffeine);
      expect(r.writer.answers.single.value, 80);
      expect(r.writer.symptoms, [mB.key]);
      expect(r.writer.skips, [mC.key]);
      expect(r.glasses.removed, [gNoon.key]);
      expect(rep.applied, hasLength(4));
      expect(rep.failed, isEmpty);
      expect(rep.remaining.isEmpty, isTrue);
    });

    test('an Other note and a keep are passed through', () async {
      final r = _Rig();
      final rep = await r.save(MomentReviewQueue.empty
          .withDecision(kA,
              const ReviewDecision.label(MomentChoice.other, note: 'walk'))
          .withDecision(kG, const ReviewDecision.keepGlass()));
      expect(r.writer.answers.single.note, 'walk');
      expect(r.glasses.kept, [gNoon.key]);
      expect(rep.remaining.isEmpty, isTrue);
    });

    test('oldest first, whatever order they were queued in', () async {
      final r = _Rig();
      final q = MomentReviewQueue.empty
          .withDecision(kC, const ReviewDecision.skip())
          .withDecision(kA, const ReviewDecision.skip())
          .withDecision(kB, const ReviewDecision.skip());
      await r.save(q);
      expect(r.log.entries, [
        'skip:${mA.key}',
        'skip:${mB.key}',
        'skip:${mC.key}',
      ]);
    });

    test('an empty queue writes and sends nothing', () async {
      final r = _Rig();
      final rep = await r.save(MomentReviewQueue.empty);
      expect(r.log.entries, isEmpty);
      expect(rep.applied, isEmpty);
    });

    test('moments and glasses of the same minute are applied separately',
        () async {
      final r = _Rig();
      final q = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.skip())
          .withDecision(
              ReviewKey.glass(gSameMinuteAsA), const ReviewDecision.keepGlass());
      await r.save(q, glassList: [gSameMinuteAsA]);
      expect(r.writer.skips, [mA.key]);
      expect(r.glasses.kept, [gSameMinuteAsA.key]);
    });
  });

  group('partial failure', () {
    test('one failing write does not lose the others; it stays queued',
        () async {
      final r = _Rig(failMoments: {mB.key});
      final q = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.label(MomentChoice.meal))
          .withDecision(kB, const ReviewDecision.label(MomentChoice.meal))
          .withDecision(kC, const ReviewDecision.skip())
          .withDecision(kG, const ReviewDecision.keepGlass());
      final rep = await r.save(q);
      expect(rep.applied, containsAll([kA, kC, kG]));
      expect(rep.applied, isNot(contains(kB)));
      expect(rep.failed.keys, [kB]);
      expect(rep.failed[kB], isA<StateError>());
      expect(rep.remaining.decisions.keys, [kB]);
      expect(rep.remaining.decisionFor(kB)!.choice, MomentChoice.meal,
          reason: 'the failed draft is kept as it was');
      expect(r.glasses.kept, [gNoon.key], reason: 'later items still ran');
    });

    test('a failing glass write is reported and kept too', () async {
      final r = _Rig(failGlasses: {gNoon.key});
      final rep = await r.save(MomentReviewQueue.empty
          .withDecision(kG, const ReviewDecision.keepGlass())
          .withDecision(kA, const ReviewDecision.skip()));
      expect(rep.failed.keys, [kG]);
      expect(rep.remaining.decisions.keys, [kG]);
      expect(r.writer.skips, [mA.key]);
    });

    test('Save again after fixing the cause applies the rest', () async {
      final r = _Rig(failMoments: {mB.key});
      final q = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.skip())
          .withDecision(kB, const ReviewDecision.skip());
      final first = await r.save(q);
      r.writer.failOn = {};
      final second = await r.save(first.remaining);
      expect(second.failed, isEmpty);
      expect(second.remaining.isEmpty, isTrue);
      expect(r.writer.skips, [mA.key, mB.key],
          reason: 'A once (first save), B once (second)');
    });

    test('a moment answered elsewhere meanwhile leaves the queue, unreported '
        'as a failure, and is not sent to Tasker', () async {
      final r = _Rig(alreadyMoments: {mA.key});
      final rep = await r.save(MomentReviewQueue.empty.withDecision(
          kA, const ReviewDecision.label(MomentChoice.meal)));
      expect(rep.alreadyAnswered, [kA]);
      expect(rep.failed, isEmpty);
      expect(rep.applied, isEmpty);
      expect(rep.remaining.isEmpty, isTrue);
      expect(r.sent, isEmpty);
    });
  });

  group('stale drafts', () {
    test('an item no longer pending is dropped: not applied, not failed',
        () async {
      final r = _Rig();
      final q = MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.skip())
          .withDecision(kB, const ReviewDecision.skip())
          .withDecision(kG, const ReviewDecision.keepGlass());
      final rep = await r.save(q, moments: [mA], glassList: []);
      expect(r.log.entries, ['skip:${mA.key}']);
      expect(rep.failed, isEmpty);
      expect(rep.remaining.isEmpty, isTrue);
    });
  });

  group('nap range', () {
    final napSec = (
      s: sec(2026, 10, 6, 9, 15),
      e: sec(2026, 10, 6, 10, 5),
    );

    test('goes through the nap path: ONE edit of exactly the two minutes, on '
        'the start\'s local day', () async {
      final r = _Rig();
      final rep = await r
          .save(MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap));
      expect(r.ranges.loggedNaps, hasLength(1));
      final n = r.ranges.loggedNaps.single;
      expect(n.dayId, '2026-10-06');
      expect(n.startSec, napSec.s);
      expect(n.endSec, napSec.e);
      expect(r.ranges.loggedWorkouts, isEmpty);
      expect(rep.applied, hasLength(1), reason: 'a range is one item');
      expect(rep.remaining.isEmpty, isTrue);
    });

    test('both marked moments are then labelled Nap (they leave the pending list)',
        () async {
      final r = _Rig();
      await r.save(MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap));
      expect(r.writer.answers.map((a) => (a.key, a.choice)), [
        (mA.key, MomentChoice.nap),
        (mB.key, MomentChoice.nap),
      ]);
      expect(r.writer.answers.every((a) => a.value == null && a.note == null),
          isTrue);
      // the window is written before the labels
      expect(r.log.entries.first, startsWith('nap:'));
    });

    test('across local midnight: stored on the START day, end on the next',
        () async {
      final r = _Rig();
      await r.save(
          MomentReviewQueue.empty.withRange(mLate, mEarly, MomentChoice.nap),
          moments: [mLate, mEarly]);
      final n = r.ranges.loggedNaps.single;
      expect(n.dayId, '2026-10-05');
      expect(n.startSec, sec(2026, 10, 5, 23, 40));
      expect(n.endSec, sec(2026, 10, 6, 0, 20));
      expect(n.endSec - n.startSec, 40 * 60);
    });

    test('too long (over 6 h) is a failed item; nothing is written, it stays '
        'queued', () async {
      final r = _Rig();
      final q = MomentReviewQueue.empty.withRange(mA, mC, MomentChoice.nap);
      final rep = await r.save(q);
      expect(r.ranges.loggedNaps, isEmpty);
      expect(r.writer.answers, isEmpty);
      expect(rep.failed, hasLength(1));
      expect(rep.remaining.ranges, hasLength(1));
      expect(r.sent, isEmpty);
    });

    test('overlapping a nap already on the day is refused (no overlap '
        'fabrication)', () async {
      final r = _Rig(
          range: FakeRangeWriter(naps: {
        '2026-10-06': [
          {'start': sec(2026, 10, 6, 9, 30), 'end': sec(2026, 10, 6, 9, 50)}
        ]
      }));
      final rep = await r
          .save(MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap));
      expect(r.ranges.loggedNaps, isEmpty);
      expect(rep.failed, hasLength(1));
    });

    test('two ranges overlapping EACH OTHER: the first applies, the second '
        'is refused (even though the writer is stateless)', () async {
      const m1 = PendingMoment(date: '2026-10-06', hhmm: '13:00');
      const m2 = PendingMoment(date: '2026-10-06', hhmm: '14:00');
      const m3 = PendingMoment(date: '2026-10-06', hhmm: '13:30');
      const m4 = PendingMoment(date: '2026-10-06', hhmm: '14:30');
      final r = _Rig();
      final q = MomentReviewQueue.empty
          .withRange(m1, m2, MomentChoice.nap)
          .withRange(m3, m4, MomentChoice.nap);
      final rep = await r.save(q, moments: [m1, m2, m3, m4]);
      expect(r.ranges.loggedNaps, hasLength(1));
      expect(r.ranges.loggedNaps.single.startSec, sec(2026, 10, 6, 13, 0));
      expect(rep.applied, hasLength(1));
      expect(rep.failed, hasLength(1));
    });

    test('a range with an end that is no longer pending is dropped, not written',
        () async {
      final r = _Rig();
      final rep = await r.save(
          MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap),
          moments: [mA]);
      expect(r.ranges.loggedNaps, isEmpty);
      expect(rep.failed, isEmpty);
      expect(rep.remaining.isEmpty, isTrue);
    });

    test('if labelling an end fails the item stays queued; Save again is '
        'idempotent (same nap window, no second item)', () async {
      final r = _Rig(failMoments: {mB.key});
      final q = MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap);
      final first = await r.save(q);
      expect(first.failed, hasLength(1));
      expect(first.remaining.ranges, hasLength(1));
      expect(r.sent, isEmpty, reason: 'not announced until it fully landed');
      r.writer.failOn = {};
      final second = await r.save(first.remaining);
      expect(second.failed, isEmpty);
      expect(second.remaining.isEmpty, isTrue);
      for (final n in r.ranges.loggedNaps) {
        expect((n.dayId, n.startSec, n.endSec),
            ('2026-10-06', sec(2026, 10, 6, 9, 15), sec(2026, 10, 6, 10, 5)),
            reason: 'a retry writes the same keyed row, never a different one');
      }
      expect(r.sent, hasLength(1));
    });

    test('a failing nap write is a failed item and labels nothing', () async {
      final r = _Rig(range: FakeRangeWriter(failNap: true));
      final rep = await r
          .save(MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap));
      expect(rep.failed, hasLength(1));
      expect(r.writer.answers, isEmpty);
      expect(rep.remaining.ranges, hasLength(1));
    });
  });

  group('workout range', () {
    test('goes through the workout path with exactly the two minutes; no nap '
        'edit', () async {
      final r = _Rig();
      final rep = await r.save(
          MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.workout));
      expect(r.ranges.loggedWorkouts, hasLength(1));
      expect(r.ranges.loggedWorkouts.single.startSec, sec(2026, 10, 6, 9, 15));
      expect(r.ranges.loggedWorkouts.single.endSec, sec(2026, 10, 6, 10, 5));
      expect(r.ranges.loggedNaps, isEmpty);
      expect(r.writer.answers.map((a) => a.choice),
          [MomentChoice.workout, MomentChoice.workout]);
      expect(rep.remaining.isEmpty, isTrue);
    });

    test('across local midnight', () async {
      final r = _Rig();
      await r.save(
          MomentReviewQueue.empty.withRange(mLate, mEarly, MomentChoice.workout),
          moments: [mLate, mEarly]);
      expect(r.ranges.loggedWorkouts.single.startSec, sec(2026, 10, 5, 23, 40));
      expect(r.ranges.loggedWorkouts.single.endSec, sec(2026, 10, 6, 0, 20));
    });

    test('overlap with a saved session is refused; nothing is written', () async {
      final r = _Rig(
          range: FakeRangeWriter(spans: [
        SessionSpan('s1', sec(2026, 10, 6, 9, 0), sec(2026, 10, 6, 9, 30))
      ]));
      final rep = await r.save(
          MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.workout));
      expect(r.ranges.loggedWorkouts, isEmpty);
      expect(rep.failed, hasLength(1));
    });

    test('a failing workout write is a failed item and labels nothing',
        () async {
      final r = _Rig(range: FakeRangeWriter(failWorkout: true));
      final rep = await r.save(
          MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.workout));
      expect(rep.failed, hasLength(1));
      expect(r.writer.answers, isEmpty);
    });
  });

  group('Tasker, on Save only', () {
    test('each applied moment is sent once, AFTER its write', () async {
      final r = _Rig();
      await r.save(MomentReviewQueue.empty
          .withDecision(
              kA, const ReviewDecision.label(MomentChoice.caffeine, value: 80))
          .withDecision(kC, const ReviewDecision.label(MomentChoice.meal)));
      expect(r.sent, hasLength(2));
      expect(r.sent[0], {
        'kind': 'moment',
        'type': 'caffeine',
        'start': sec(2026, 10, 6, 9, 15),
        'day': '2026-10-06',
        'value': 80.0,
      });
      expect(r.sent[1]['type'], 'meal');
      expect(r.log.entries.indexOf('tasker:caffeine'),
          greaterThan(r.log.entries.indexOf('answer:${mA.key}:caffeine')));
    });

    test('a range is ONE broadcast with start and end (not two moments)',
        () async {
      final r = _Rig();
      await r.save(MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap));
      expect(r.sent, hasLength(1));
      expect(r.sent.single, {
        'kind': 'range',
        'type': 'nap',
        'start': sec(2026, 10, 6, 9, 15),
        'end': sec(2026, 10, 6, 10, 5),
        'day': '2026-10-06',
      });
    });

    test('a symptom is announced by type only: no description leaves the app',
        () async {
      final r = _Rig();
      await r.save(MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.symptom(symptomDesc)));
      expect(r.sent.single['type'], 'symptom');
      expect(r.sent.single.keys,
          unorderedEquals(['kind', 'type', 'start', 'day']));
    });

    test('an Other note never leaves the app', () async {
      final r = _Rig();
      await r.save(MomentReviewQueue.empty.withDecision(
          kA, const ReviewDecision.label(MomentChoice.other, note: 'private')));
      expect(r.sent.single.values.any((v) => '$v'.contains('private')), isFalse);
    });

    test('skips and assumed-glass decisions are not announced', () async {
      final r = _Rig();
      await r.save(MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.skip())
          .withDecision(kG, const ReviewDecision.keepGlass()));
      expect(r.sent, isEmpty);
    });

    test('a failed item is not announced; the others are', () async {
      final r = _Rig(failMoments: {mB.key});
      await r.save(MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.label(MomentChoice.meal))
          .withDecision(kB, const ReviewDecision.label(MomentChoice.meal)));
      expect(r.sent, hasLength(1));
      expect(r.sent.single['start'], sec(2026, 10, 6, 9, 15));
    });

    test('connection off: everything is saved, nothing is sent', () async {
      final r = _Rig(taskerOn: false);
      final rep = await r.save(MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.label(MomentChoice.meal))
          .withRange(mB, mC, MomentChoice.workout));
      expect(rep.applied, hasLength(2));
      expect(r.sent, isEmpty);
    });

    test('building and editing a queue sends nothing (drafts are silent)', () {
      final r = _Rig();
      MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.label(MomentChoice.meal))
          .withRange(mB, mC, MomentChoice.nap)
          .without(kA);
      expect(r.sent, isEmpty);
      expect(r.log.entries, isEmpty);
    });
  });
}
