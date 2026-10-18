// Round 2: a half-applied range RESUMES, a stale range does not write, and a
// retry never overwrites somebody else's workout.
//
// P1-2  Save wrote the window and labelled the start; labelling the end failed.
//       Reopening lists only the unanswered END, and `dropStale` used to delete
//       the whole range: the end stayed unanswered and Tasker never heard.
//       Progress is persisted with the range and survives that.
// P1-4  A range is only written while BOTH marks are still unanswered; an
//       answer that arrives from elsewhere wins and nothing is announced.
// P1-5  The retry exemption used to be "a session with id manual:<startSec>".
//       It is now only the exact window THIS operation recorded as attempted.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_apply.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';

import '../../../support/moment_review_fakes.dart';

final kA = ReviewKey.moment(mA);
final kB = ReviewKey.moment(mB);

class _Rig {
  _Rig({this.range, Set<String> failMoments = const {}, Set<String> already = const {}}) {
    writer = FakeAnswerWriter(log: log, failOn: failMoments, already: already);
    ranges = range ?? FakeRangeWriter(log: log);
    applier = MomentReviewApplier(
        writer: writer,
        assumedWriter: FakeGlassWriter(log: log),
        ranges: ranges,
        exporter: TaskerMomentExport(
            connectionOn: () => true,
            emit: (e, x) async {
              log.entries.add('tasker:${x['type']}');
              sent.add(x);
              return true;
            }));
  }
  final FakeRangeWriter? range;
  final log = WriteLog();
  late final FakeAnswerWriter writer;
  late final FakeRangeWriter ranges;
  late final MomentReviewApplier applier;
  final sent = <Map<String, Object>>[];
  final progress = <ReviewRange>[];

  Future<ReviewSaveReport> save(MomentReviewQueue q,
          {List<PendingMoment> moments = const [mA, mB]}) =>
      applier.apply(q,
          moments: moments,
          glasses: const [],
          now: reviewNow,
          onProgress: (r) async => progress.add(r));
}

MomentReviewQueue _nap() =>
    MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap);

void main() {
  group('range progress (pure)', () {
    test('a fresh range is not in progress and not finished', () {
      final r = _nap().ranges.single;
      expect(r.inProgress, isFalse);
      expect(r.finished, isFalse);
    });

    test('attempting or window written means in progress', () {
      final r = _nap().ranges.single;
      expect(r.copyWith(attempting: true).inProgress, isTrue);
      expect(r.copyWith(windowWritten: true).inProgress, isTrue);
    });

    test('finished needs the window, both labels AND the announcement', () {
      var r = _nap().ranges.single.copyWith(windowWritten: true);
      expect(r.finished, isFalse);
      r = r.copyWith(startLabelled: true, endLabelled: true);
      expect(r.finished, isFalse, reason: 'Tasker has not been told yet');
      expect(r.copyWith(announced: true).finished, isTrue);
    });

    test('the absolute seconds of both marks are fixed at pairing', () {
      final r = _nap().ranges.single;
      expect(r.startSec, sec(2026, 10, 6, 9, 15));
      expect(r.endSec, sec(2026, 10, 6, 10, 5));
    });

    test('progress survives JSON', () {
      final q = _nap().withRangeProgress(_nap().ranges.single.copyWith(
          attempting: true,
          windowWritten: true,
          startLabelled: true,
          announced: false));
      final back =
          MomentReviewQueue.fromJson(jsonDecode(jsonEncode(q.toJson())));
      final r = back.ranges.single;
      expect((r.attempting, r.windowWritten, r.startLabelled, r.endLabelled,
              r.announced),
          (true, true, true, false, false));
      expect(r.startSec, sec(2026, 10, 6, 9, 15));
    });

    test('withRangeProgress replaces the same range, or adds it back', () {
      final q = _nap();
      final done = q.ranges.single.copyWith(windowWritten: true);
      expect(q.withRangeProgress(done).ranges.single.windowWritten, isTrue);
      expect(q.withRangeProgress(done).ranges, hasLength(1));
      expect(MomentReviewQueue.empty.withRangeProgress(done).ranges, hasLength(1));
    });
  });

  group('dropStale keeps a half-done range', () {
    test('start already answered (so no longer pending), window written: kept',
        () {
      final q = _nap().withRangeProgress(_nap()
          .ranges
          .single
          .copyWith(windowWritten: true, startLabelled: true));
      final out = q.dropStale({kB}); // only the end is still pending
      expect(out.ranges, hasLength(1));
    });

    test('an UNSTARTED range with one end gone is still dropped', () {
      expect(_nap().dropStale({kB}).ranges, isEmpty);
    });

    test('a finished range is dropped', () {
      final r = _nap().ranges.single.copyWith(
          windowWritten: true,
          startLabelled: true,
          endLabelled: true,
          announced: true);
      final q = MomentReviewQueue.empty.withRangeProgress(r);
      expect(q.dropStale(const {}).ranges, isEmpty);
    });

    test('written and labelled but not yet announced is kept (Tasker is owed)',
        () {
      final r = _nap().ranges.single.copyWith(
          windowWritten: true, startLabelled: true, endLabelled: true);
      final q = MomentReviewQueue.empty.withRangeProgress(r);
      expect(q.dropStale(const {}).ranges, hasLength(1));
    });
  });

  group('resume after reopening', () {
    test('first Save: window written, start labelled, end fails; progress is '
        'reported as it happens', () async {
      final r = _Rig(failMoments: {mB.key});
      final rep = await r.save(_nap());
      expect(rep.failed, hasLength(1));
      final left = rep.remaining.ranges.single;
      expect((left.windowWritten, left.startLabelled, left.endLabelled,
              left.announced),
          (true, true, false, false));
      expect(r.ranges.loggedNaps, hasLength(1));
      expect(r.sent, isEmpty, reason: 'a label failed: nothing announced');
      expect(r.progress.any((p) => p.windowWritten), isTrue);
      expect(r.progress.any((p) => p.attempting), isTrue,
          reason: 'the attempt is recorded BEFORE the write');
    });

    test('reopened with only the END pending: label it, announce ONCE, '
        'never write the window again', () async {
      final r = _Rig(failMoments: {mB.key});
      final first = await r.save(_nap());
      r.writer.failOn = {};
      // The start is answered now, so the list holds the end alone.
      final second = await r.save(first.remaining, moments: [mB]);
      expect(second.failed, isEmpty);
      expect(second.remaining.isEmpty, isTrue);
      expect(r.ranges.loggedNaps, hasLength(1), reason: 'window written once');
      expect(r.writer.answers.map((a) => (a.key, a.choice)),
          [(mA.key, MomentChoice.nap), (mB.key, MomentChoice.nap)]);
      expect(r.sent, hasLength(1));
      expect(r.sent.single['kind'], 'range');
    });

    test('a third Save finds nothing left to announce', () async {
      final r = _Rig(failMoments: {mB.key});
      final first = await r.save(_nap());
      r.writer.failOn = {};
      final second = await r.save(first.remaining, moments: [mB]);
      await r.save(second.remaining, moments: const []);
      expect(r.sent, hasLength(1));
    });

    test('the range survives a restart (JSON) and still resumes', () async {
      final r = _Rig(failMoments: {mB.key});
      final first = await r.save(_nap());
      final reloaded = MomentReviewQueue.fromJson(
          jsonDecode(jsonEncode(first.remaining.toJson())));
      r.writer.failOn = {};
      final second = await r.save(reloaded.dropStale({kB}), moments: [mB]);
      expect(second.failed, isEmpty);
      expect(r.sent, hasLength(1));
      expect(r.ranges.loggedNaps, hasLength(1));
    });

    test('everything labelled but the announcement was lost: it is sent once',
        () async {
      final r = _Rig();
      final owed = MomentReviewQueue.empty.withRangeProgress(_nap()
          .ranges
          .single
          .copyWith(
              windowWritten: true, startLabelled: true, endLabelled: true));
      final rep = await r.save(owed, moments: const []);
      expect(r.sent, hasLength(1));
      expect(r.ranges.loggedNaps, isEmpty);
      expect(r.writer.answers, isEmpty);
      expect(rep.remaining.isEmpty, isTrue);
    });
  });

  group('a range is written only while both marks are unanswered', () {
    test('one end already answered: nothing written, nothing announced, the '
        'range leaves the queue as already answered', () async {
      final r = _Rig(already: {mB.key});
      final rep = await r.save(_nap());
      expect(r.ranges.loggedNaps, isEmpty);
      expect(r.writer.answers, isEmpty, reason: 'the other end is not labelled');
      expect(r.sent, isEmpty);
      expect(rep.alreadyAnswered, hasLength(1));
      expect(rep.failed, isEmpty);
      expect(rep.remaining.isEmpty, isTrue);
    });

    test('an end answered between the check and the label: the answer wins, '
        'no success is announced', () async {
      // The check passes (not answered), then the write reports "already".
      final r = _Rig();
      r.writer.already = {};
      final racing = _RacingWriter(r.log, raceOn: mB.key);
      final applier = MomentReviewApplier(
          writer: racing,
          assumedWriter: FakeGlassWriter(log: r.log),
          ranges: r.ranges,
          exporter: TaskerMomentExport(
              connectionOn: () => true,
              emit: (e, x) async {
                r.sent.add(x);
                return true;
              }));
      final rep = await applier.apply(_nap(),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      expect(r.sent, isEmpty);
      expect(rep.alreadyAnswered, hasLength(1));
      expect(rep.failed, isEmpty);
    });

    test('a label that fails is never announced as success', () async {
      final r = _Rig(failMoments: {mA.key});
      final rep = await r.save(_nap());
      expect(rep.failed, hasLength(1));
      expect(r.sent, isEmpty);
    });
  });

  group('a retry never overwrites somebody else\'s workout', () {
    final own = sec(2026, 10, 6, 9, 15);

    test('an existing manual workout with the same START but another end is '
        'an overlap, not "my own retry"', () async {
      final r = _Rig(
          range: FakeRangeWriter(spans: [
        SessionSpan(manualSessionId(own), own, sec(2026, 10, 6, 10, 30))
      ]));
      final rep = await r.save(
          MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.workout,
              workoutType: 'running'));
      expect(r.ranges.loggedWorkouts, isEmpty);
      expect(rep.failed, hasLength(1));
      expect(
          (rep.failed.values.single as ManualWindowException).error,
          ManualWindowError.overlapsExisting);
    });

    test('the same window with no recorded attempt is also refused', () async {
      final r = _Rig(
          range: FakeRangeWriter(spans: [
        SessionSpan(manualSessionId(own), own, sec(2026, 10, 6, 10, 5))
      ]));
      final rep = await r.save(
          MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.workout));
      expect(r.ranges.loggedWorkouts, isEmpty);
      expect(rep.failed, hasLength(1));
    });

    test('after a recorded attempt, exactly that window is exempt', () async {
      final r = _Rig(
          range: FakeRangeWriter(spans: [
        SessionSpan(manualSessionId(own), own, sec(2026, 10, 6, 10, 5))
      ]));
      final attempted = MomentReviewQueue.empty.withRangeProgress(
          MomentReviewQueue.empty
              .withRange(mA, mB, MomentChoice.workout)
              .ranges
              .single
              .copyWith(attempting: true));
      final rep = await r.save(attempted);
      expect(rep.failed, isEmpty);
      expect(r.ranges.loggedWorkouts, hasLength(1));
    });

    test('after a recorded attempt, a DIFFERENT window at that start is not '
        'exempt', () async {
      final r = _Rig(
          range: FakeRangeWriter(spans: [
        SessionSpan(manualSessionId(own), own, sec(2026, 10, 6, 10, 30))
      ]));
      final attempted = MomentReviewQueue.empty.withRangeProgress(
          MomentReviewQueue.empty
              .withRange(mA, mB, MomentChoice.workout)
              .ranges
              .single
              .copyWith(attempting: true));
      final rep = await r.save(attempted);
      expect(r.ranges.loggedWorkouts, isEmpty);
      expect(rep.failed, hasLength(1));
    });

    test('a written workout is never validated or written again on resume',
        () async {
      final r = _Rig(failMoments: {mB.key});
      final q = MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.workout);
      final first = await r.save(q);
      expect(r.ranges.loggedWorkouts, hasLength(1));
      // The written workout now exists as a saved session.
      r.ranges.spans = [
        SessionSpan(manualSessionId(own), own, sec(2026, 10, 6, 10, 5))
      ];
      r.writer.failOn = {};
      final second = await r.save(first.remaining, moments: [mB]);
      expect(second.failed, isEmpty);
      expect(r.ranges.loggedWorkouts, hasLength(1));
    });
  });
}

/// Answers every moment normally except [raceOn], which "was answered
/// elsewhere" only once the write is attempted.
class _RacingWriter extends FakeAnswerWriter {
  _RacingWriter(WriteLog log, {required this.raceOn}) : super(log: log);
  final String raceOn;

  @override
  Future<MomentAnswerResult> answer(PendingMoment m, MomentChoice choice,
      {double? value, String? note, DateTime? now}) async {
    if (m.key == raceOn) return MomentAnswerResult.alreadyAnswered;
    return super.answer(m, choice, value: value, note: note, now: now);
  }
}
