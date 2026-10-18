// Round 3 (service, queue, applier, zone arithmetic). See the screen file for
// the UI half.
//
// 1  recording a range's progress that is not acknowledged stops the range
//    BEFORE its next write
// 2  a newer draft for the SAME key survives an older Save
// 3  every answer path runs inside the owner's one critical section, and answers
//    are re-checked right before the window write
// 4  a repeated wall-clock minute is found from the zone's real offsets (a
//    30-minute rollback included), not from a fixed hour
// 5  a started range cannot be dissolved through its remaining end
// 7  a range awaiting only its announcement is counted

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_apply.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/gestures/moment_review_store.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/moment_review_fakes.dart';

final kA = ReviewKey.moment(mA);
final kB = ReviewKey.moment(mB);
final kC = ReviewKey.moment(mC);

MomentReviewApplier _applier(FakeAnswerWriter w, FakeRangeWriter r,
        {List<Map<String, Object>>? sent}) =>
    MomentReviewApplier(
        writer: w,
        assumedWriter: FakeGlassWriter(),
        ranges: r,
        exporter: TaskerMomentExport(
            connectionOn: () => true,
            emit: (e, x) async {
              sent?.add(x);
              return true;
            }));

/// Confirms the first [okWrites] saves, refuses every one after.
class _CountingStore extends MomentReviewStore {
  _CountingStore(this.okWrites);
  int okWrites;
  @override
  Future<bool> save(MomentReviewQueue q) async {
    if (okWrites <= 0) return false;
    okWrites--;
    return true;
  }
}

ReviewRange _started() => MomentReviewQueue.empty
    .withRange(mA, mB, MomentChoice.nap)
    .ranges
    .single
    .copyWith(windowWritten: true, startLabelled: true);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setString(MomentReviewStore.prefKey, '');
  });

  group('1  unacknowledged progress stops the range', () {
    test('the attempt cannot be recorded: NOTHING is written', () async {
      // The edit that queued the range is the one confirmed write.
      final s = MomentReviewService(store: _CountingStore(1));
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      final ranges = FakeRangeWriter();
      final w = FakeAnswerWriter();
      final rep = await s.save(_applier(w, ranges),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      expect(ranges.loggedNaps, isEmpty);
      expect(w.answers, isEmpty);
      expect(rep.failed.values.single, isA<ProgressNotPersistedException>());
      expect(s.queue.ranges, hasLength(1), reason: 'kept, to try again');
      expect(s.persistFailed, isTrue);
    });

    test('the written window cannot be recorded: no label follows it',
        () async {
      // queue edit + the attempt are confirmed; the "window written" is not.
      final s = MomentReviewService(store: _CountingStore(2));
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      final ranges = FakeRangeWriter();
      final w = FakeAnswerWriter();
      final sent = <Map<String, Object>>[];
      final rep = await s.save(_applier(w, ranges, sent: sent),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      expect(ranges.loggedNaps, hasLength(1));
      expect(w.answers, isEmpty);
      expect(sent, isEmpty);
      expect(rep.failed.values.single, isA<ProgressNotPersistedException>());
      expect(s.queue.ranges.single.windowWritten, isTrue,
          reason: 'what happened is still known in memory');
    });

    test('a label that cannot be recorded stops before the next label',
        () async {
      final s = MomentReviewService(store: _CountingStore(3));
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      final w = FakeAnswerWriter();
      final rep = await s.save(_applier(w, FakeRangeWriter()),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      expect(w.answers.map((a) => a.key), [mA.key],
          reason: 'the end is not labelled on unrecorded progress');
      expect(rep.failed, hasLength(1));
    });

    test('a label that WAS written but not recorded is recognised as ours on '
        'resume (not a conflict): the range finishes and announces', () async {
      final s = MomentReviewService(store: _CountingStore(3));
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      final w = FakeAnswerWriter();
      final ranges = FakeRangeWriter();
      await s.save(_applier(w, ranges),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      // Storage works again; the start is answered (so no longer listed) but
      // the stored progress never heard of it.
      final s2 = MomentReviewService();
      await s2.edit((q) => q.withRangeProgress(
          s.queue.ranges.single.copyWith(startLabelled: false)));
      final sent = <Map<String, Object>>[];
      final rep = await s2.save(_applier(w, ranges, sent: sent),
          moments: const [mB], glasses: const [], now: reviewNow);
      expect(rep.failed, isEmpty);
      expect(rep.alreadyAnswered, isEmpty);
      expect(sent, hasLength(1));
      expect(w.answers.map((a) => a.key), [mA.key, mB.key]);
    });

    test('a start answered as something ELSE is a conflict: nothing announced',
        () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRangeProgress(
          MomentReviewQueue.empty
              .withRange(mA, mB, MomentChoice.nap)
              .ranges
              .single
              .copyWith(windowWritten: true)));
      final w = FakeAnswerWriter()..labels[mA.key] = 'meal';
      final sent = <Map<String, Object>>[];
      final rep = await s.save(_applier(w, FakeRangeWriter(), sent: sent),
          moments: const [mB], glasses: const [], now: reviewNow);
      expect(sent, isEmpty);
      expect(rep.alreadyAnswered, hasLength(1));
    });

    test('with working storage nothing changes', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      final rep = await s.save(_applier(FakeAnswerWriter(), FakeRangeWriter()),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      expect(rep.failed, isEmpty);
    });
  });

  group('2  a newer draft for the same key survives an older Save', () {
    test('80 mg is saved; the 160 mg queued meanwhile stays', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withDecision(kA,
          const ReviewDecision.label(MomentChoice.caffeine, value: 80)));
      final gate = Completer<void>();
      final started = Completer<void>();
      final w = _Gated(gate, started);
      final run = s.save(_applier(w, FakeRangeWriter()),
          moments: const [mA], glasses: const [], now: reviewNow);
      await started.future;
      await s.edit((q) => q.withDecision(kA,
          const ReviewDecision.label(MomentChoice.caffeine, value: 160)));
      gate.complete();
      await run;
      expect(w.answers.single.value, 80);
      expect(s.queue.decisionFor(kA)!.value, 160);
      expect(const MomentReviewStore().load().decisionFor(kA)!.value, 160);
    });

    test('an unchanged draft still leaves when it lands', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withDecision(kA, const ReviewDecision.skip()));
      await s.save(_applier(FakeAnswerWriter(), FakeRangeWriter()),
          moments: const [mA], glasses: const [], now: reviewNow);
      expect(s.queue.isEmpty, isTrue);
    });
  });

  group('3  one critical section', () {
    test('a direct answer waits for a running Save, then labels and drops the '
        'mark\'s draft', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withDecision(kA, const ReviewDecision.label(MomentChoice.meal)));
      final gate = Completer<void>();
      final started = Completer<void>();
      final w = _Gated(gate, started);
      final save = s.save(_applier(w, FakeRangeWriter()),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      await started.future;
      var wrote = false;
      final direct = s.answerDirect(mB, () async {
        wrote = true;
        return MomentAnswerResult.saved;
      });
      await Future<void>.delayed(Duration.zero);
      expect(wrote, isFalse, reason: 'not while the Save is mid-flight');
      gate.complete();
      await save;
      expect(await direct, MomentAnswerResult.saved);
      expect(wrote, isTrue);
    });

    test('and a Save waits for a running direct answer', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withDecision(kA, const ReviewDecision.skip()));
      final gate = Completer<void>();
      final started = Completer<void>();
      final direct = s.answerDirect(mB, () async {
        started.complete();
        await gate.future;
        return MomentAnswerResult.saved;
      });
      await started.future;
      final w = FakeAnswerWriter();
      final save = s.save(_applier(w, FakeRangeWriter()),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      await Future<void>.delayed(Duration.zero);
      expect(w.skips, isEmpty);
      gate.complete();
      await direct;
      await save;
      expect(w.skips, [mA.key]);
    });

    test('a direct answer to a mark of an unstarted range dissolves that range',
        () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      await s.answerDirect(mA, () async => MomentAnswerResult.saved);
      expect(s.queue.ranges, isEmpty);
    });

    test('a mark of a STARTED range cannot be answered directly: refused, '
        'nothing written', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRangeProgress(_started()));
      var wrote = false;
      await expectLater(
          s.answerDirect(mB, () async {
            wrote = true;
            return MomentAnswerResult.saved;
          }),
          throwsStateError);
      expect(wrote, isFalse);
      expect(s.queue.ranges, hasLength(1));
    });

    test('a failing direct write releases the section', () async {
      final s = MomentReviewService();
      await expectLater(
          s.answerDirect(mA, () async => throw StateError('disk')),
          throwsStateError);
      final w = FakeAnswerWriter();
      await s.edit((q) => q.withDecision(kB, const ReviewDecision.skip()));
      await s.save(_applier(w, FakeRangeWriter()),
          moments: const [mB], glasses: const [], now: reviewNow);
      expect(w.skips, [mB.key]);
    });

    test('answers are checked AGAIN right before the window write', () async {
      // Calls 1 and 2 are the first look at both marks; the third is the check
      // made after validation and before the write.
      final w = _AnsweredOnCall(3);
      final ranges = FakeRangeWriter();
      final rep = await _applier(w, ranges).apply(
          MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap),
          moments: const [mA, mB],
          glasses: const [],
          now: reviewNow);
      expect(ranges.loggedNaps, isEmpty);
      expect(w.answers, isEmpty);
      expect(rep.alreadyAnswered, hasLength(1));
      expect(rep.failed, isEmpty);
    });
  });

  group('4  a repeated wall-clock minute, from the zone\'s real offsets', () {
    // Lord Howe: clocks go back 30 minutes at 02:00 LHDT (+11:00) on
    // 2026-04-05 = 2026-04-04T15:00Z, to +10:30. 01:30..02:00 happens twice.
    final lhRollback = DateTime.utc(2026, 4, 4, 15);
    Duration lordHowe(DateTime utc) => utc.isBefore(lhRollback)
        ? const Duration(hours: 11)
        : const Duration(hours: 10, minutes: 30);

    // Denver: back one hour at 08:00Z on 2026-11-01.
    final denverBack = DateTime.utc(2026, 11, 1, 8);
    Duration denver(DateTime utc) => utc.isBefore(denverBack)
        ? const Duration(hours: -6)
        : const Duration(hours: -7);

    // New York spring forward (02:00 does not exist), 07:00Z on 2026-03-08.
    final nySpring = DateTime.utc(2026, 3, 8, 7);
    Duration newYork(DateTime utc) => utc.isBefore(nySpring)
        ? const Duration(hours: -5)
        : const Duration(hours: -4);

    test('Lord Howe: 01:40 is ambiguous (an hour-either-side check misses it)',
        () {
      expect(
          wallMinuteIsAmbiguous(DateTime(2026, 4, 5, 1, 40), offsetAt: lordHowe),
          isTrue);
      expect(
          wallMinuteIsAmbiguous(DateTime(2026, 4, 5, 1, 59), offsetAt: lordHowe),
          isTrue);
    });

    test('Lord Howe: minutes outside the repeated half hour are not', () {
      for (final hm in [(1, 10), (1, 29), (2, 0), (2, 10), (0, 40)]) {
        expect(
            wallMinuteIsAmbiguous(DateTime(2026, 4, 5, hm.$1, hm.$2),
                offsetAt: lordHowe),
            isFalse,
            reason: '${hm.$1}:${hm.$2}');
      }
    });

    test('Denver: the repeated hour', () {
      expect(
          wallMinuteIsAmbiguous(DateTime(2026, 11, 1, 1, 30), offsetAt: denver),
          isTrue);
      expect(
          wallMinuteIsAmbiguous(DateTime(2026, 11, 1, 0, 59), offsetAt: denver),
          isFalse);
      expect(
          wallMinuteIsAmbiguous(DateTime(2026, 11, 1, 2, 0), offsetAt: denver),
          isFalse);
    });

    test('a spring-forward day has no repeated minute', () {
      for (var h = 0; h < 5; h++) {
        expect(
            wallMinuteIsAmbiguous(DateTime(2026, 3, 8, h, 30), offsetAt: newYork),
            isFalse,
            reason: 'hour $h');
      }
    });

    test('a zone without changes never says ambiguous', () {
      expect(
          wallMinuteIsAmbiguous(DateTime(2026, 4, 5, 1, 40),
              offsetAt: (_) => const Duration(hours: 5, minutes: 30)),
          isFalse);
    });

    test('marks read with the Lord Howe zone: unknown time is flagged, a '
        'recorded epoch is not', () {
      final f = MomentFollowUps(
        enabledSince: DateTime(2026, 4, 1),
        marked: const [
          (date: '2026-04-05', hhmm: '01:40'),
          (date: '2026-04-05', hhmm: '01:45'),
          (date: '2026-04-05', hhmm: '01:10'),
        ],
        absolute: {'2026-04-05 01:45': 1775315100},
        isAmbiguous: (w) => wallMinuteIsAmbiguous(w, offsetAt: lordHowe),
      );
      final by = {for (final m in f.pending(DateTime(2026, 4, 6, 12))) m.hhmm: m};
      expect(by['01:40']!.ambiguous, isTrue);
      expect(by['01:45']!.ambiguous, isFalse);
      expect(by['01:10']!.ambiguous, isFalse);
    });

    test('a flagged Lord Howe mark is never paired', () {
      const m = PendingMoment(date: '2026-04-05', hhmm: '01:40', ambiguous: true);
      expect(
          () => MomentReviewQueue.empty
              .withRange(m, const PendingMoment(date: '2026-04-05', hhmm: '03:00'),
                  MomentChoice.nap),
          throwsArgumentError);
    });
  });

  group('5  a started range is finished as a range, never dissolved', () {
    MomentReviewQueue started() =>
        MomentReviewQueue.empty.withRangeProgress(_started());

    test('a decision for the remaining end changes nothing', () {
      final q = started();
      final out = q.withDecision(kB, const ReviewDecision.skip());
      expect(out, same(q));
      expect(out.ranges, hasLength(1));
      expect(out.decisionFor(kB), isNull);
    });

    test('so does a label', () {
      final q = started();
      expect(
          q.withDecision(kB, const ReviewDecision.label(MomentChoice.meal)),
          same(q));
    });

    test('undo (without) changes nothing', () {
      final q = started();
      expect(q.without(kB), same(q));
      expect(q.without(kA), same(q));
    });

    test('pairing a started range\'s end with another mark changes nothing',
        () {
      final q = started();
      expect(q.withRange(mB, mC, MomentChoice.nap), same(q));
    });

    test('a range that is only ATTEMPTING is protected too', () {
      final q = MomentReviewQueue.empty.withRangeProgress(MomentReviewQueue
          .empty
          .withRange(mA, mB, MomentChoice.nap)
          .ranges
          .single
          .copyWith(attempting: true));
      expect(q.without(kA), same(q));
    });

    test('an unstarted range is still free to change', () {
      final q = MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap);
      expect(q.without(kB).ranges, isEmpty);
      expect(q.withDecision(kB, const ReviewDecision.skip()).ranges, isEmpty);
    });

    test('the owner enforces it for a screen too', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRangeProgress(_started()));
      await s.edit((q) => q.withDecision(kB, const ReviewDecision.skip()));
      await s.edit((q) => q.without(kB));
      expect(s.queue.ranges, hasLength(1));
      expect(s.queue.decisionFor(kB), isNull);
    });
  });

  group('7  a range awaiting only its announcement is counted', () {
    ReviewRange owed() => MomentReviewQueue.empty
        .withRange(mA, mB, MomentChoice.nap)
        .ranges
        .single
        .copyWith(windowWritten: true, startLabelled: true, endLabelled: true);

    test('orphanRanges: started, unfinished, no mark pending', () {
      final q = MomentReviewQueue.empty.withRangeProgress(owed());
      expect(q.orphanRanges(const {}), hasLength(1));
      expect(q.orphanRanges({mA.key}), isEmpty,
          reason: 'a pending mark shows it already');
      expect(q.orphanRanges({mB.key}), isEmpty);
    });

    test('an unstarted or a finished range is not an orphan', () {
      expect(
          MomentReviewQueue.empty
              .withRange(mA, mB, MomentChoice.nap)
              .orphanRanges(const {}),
          isEmpty);
      expect(
          MomentReviewQueue.empty
              .withRangeProgress(owed().copyWith(announced: true))
              .orphanRanges(const {}),
          isEmpty);
    });

    test('the Home count includes it, and only while the setting is on', () {
      final q = MomentReviewQueue.empty.withRangeProgress(owed());
      final on = MomentFollowUps(
          enabledSince: DateTime(2026, 10, 1),
          marked: const [(date: '2026-10-07', hhmm: '07:05')]);
      expect(on.pendingCount(reviewNow), 1);
      expect(on.reviewCount(reviewNow, q), 2);
      final off = MomentFollowUps(enabledSince: null);
      expect(off.reviewCount(reviewNow, q), 0);
    });

    test('a range with a pending mark is counted once (by the mark)', () {
      final half = MomentReviewQueue.empty.withRangeProgress(_started());
      final f = MomentFollowUps(
          enabledSince: DateTime(2026, 10, 1),
          marked: const [(date: '2026-10-06', hhmm: '10:05')]);
      expect(f.reviewCount(reviewNow, half), 1);
    });
  });
}

class _Gated extends FakeAnswerWriter {
  _Gated(this.gate, this.started);
  final Completer<void> gate, started;
  @override
  Future<MomentAnswerResult> answer(PendingMoment m, MomentChoice choice,
      {double? value, String? note, DateTime? now}) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    return super.answer(m, choice, value: value, note: note, now: now);
  }
}

class _AnsweredOnCall extends FakeAnswerWriter {
  _AnsweredOnCall(this.onCall);
  final int onCall;
  int calls = 0;
  @override
  Future<bool> isAnswered(PendingMoment m) async => ++calls >= onCall;
}
