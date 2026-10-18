// Round 2, P1-3 and P2-6: ONE owner of the queue. A Save that outlives its
// screen merges into the CURRENT queue (never blind-replaces the stored blob),
// Saves run one at a time, and a storage write the platform did not confirm is
// reported instead of assumed.

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

/// A nap writer whose re-analysis waits for the test to let it finish.
class _SlowFinish extends FakeRangeWriter {
  _SlowFinish();
  final gate = Completer<void>();
  final started = Completer<void>();

  @override
  Future<void> finishNaps() async {
    started.complete();
    await gate.future;
  }
}

MomentReviewApplier _applier(FakeAnswerWriter w, FakeRangeWriter r) =>
    MomentReviewApplier(
        writer: w,
        assumedWriter: FakeGlassWriter(),
        ranges: r,
        exporter: TaskerMomentExport(connectionOn: () => false));

class _FailingStore extends MomentReviewStore {
  const _FailingStore();
  @override
  Future<bool> save(MomentReviewQueue q) async => false;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setString(MomentReviewStore.prefKey, '');
  });

  group('editing', () {
    test('edit changes the current queue, bumps the revision, notifies, stores',
        () async {
      final s = MomentReviewService();
      var notified = 0;
      s.addListener(() => notified++);
      final r0 = s.revision;
      final ok = await s.edit((q) => q.withDecision(kA, const ReviewDecision.skip()));
      expect(ok, isTrue);
      expect(s.revision, greaterThan(r0));
      expect(notified, greaterThan(0));
      expect(s.queue.decisionFor(kA), isNotNull);
      expect(const MomentReviewStore().load().decisionFor(kA), isNotNull);
    });

    test('a second service (a new screen\'s) reloads what the first stored', () async {
      final a = MomentReviewService();
      await a.edit((q) => q.withDecision(kA, const ReviewDecision.skip()));
      final b = MomentReviewService();
      b.reload();
      expect(b.queue.decisionFor(kA), isNotNull);
    });

    test('adopt drops drafts for items no longer pending, and stores that',
        () async {
      final s = MomentReviewService();
      await s.edit((q) => q
          .withDecision(kA, const ReviewDecision.skip())
          .withDecision(kC, const ReviewDecision.skip()));
      await s.adopt({kA});
      expect(s.queue.decisions.keys, [kA]);
      expect(const MomentReviewStore().load().decisions.keys, [kA]);
    });
  });

  group('persistence is confirmed, not assumed (P2)', () {
    test('a write the platform refuses is reported', () async {
      final s = MomentReviewService(store: const _FailingStore());
      expect(s.persistFailed, isFalse);
      final ok = await s.edit((q) => q.withDecision(kA, const ReviewDecision.skip()));
      expect(ok, isFalse);
      expect(s.persistFailed, isTrue);
      expect(s.queue.decisionFor(kA), isNotNull,
          reason: 'the choice is kept in memory for this session');
    });

    test('the next confirmed write clears the warning', () async {
      var fail = true;
      final s = MomentReviewService(store: _Flaky(() => fail));
      await s.edit((q) => q.withDecision(kA, const ReviewDecision.skip()));
      expect(s.persistFailed, isTrue);
      fail = false;
      await s.edit((q) => q.withDecision(kB, const ReviewDecision.skip()));
      expect(s.persistFailed, isFalse);
    });

    test('the real store reports the platform\'s answer (true when loaded)',
        () async {
      expect(await const MomentReviewStore().save(MomentReviewQueue.empty
          .withDecision(kA, const ReviewDecision.skip())), isTrue);
      expect(await Prefs.setStringAcked('x.y', 'v'), isTrue);
      expect(Prefs.getString('x.y', ''), 'v');
    });
  });

  group('Save through the owner', () {
    test('applies the queue and removes what landed', () async {
      final s = MomentReviewService();
      await s.edit((q) => q
          .withDecision(kA, const ReviewDecision.skip())
          .withDecision(kB, const ReviewDecision.skip()));
      final w = FakeAnswerWriter();
      final rep = await s.save(_applier(w, FakeRangeWriter()),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      expect(rep.applied, hasLength(2));
      expect(s.queue.isEmpty, isTrue);
      expect(const MomentReviewStore().load().isEmpty, isTrue);
    });

    test('a failed item stays queued', () async {
      final s = MomentReviewService();
      await s.edit((q) => q
          .withDecision(kA, const ReviewDecision.skip())
          .withDecision(kB, const ReviewDecision.skip()));
      final rep = await s.save(
          _applier(FakeAnswerWriter(failOn: {mB.key}), FakeRangeWriter()),
          moments: const [mA, mB],
          glasses: const [],
          now: reviewNow);
      expect(rep.failed.keys, [kB]);
      expect(s.queue.decisions.keys, [kB]);
    });

    test('a draft queued WHILE a Save runs survives it (the departed screen '
        'case)', () async {
      final s = MomentReviewService();
      final slow = _SlowFinish();
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      final run = s.save(_applier(FakeAnswerWriter(), slow),
          moments: const [mA, mB, mC], glasses: const [], now: reviewNow);
      await slow.started.future; // the nap is written, re-analysis is waiting
      // A newer screen queues an answer for another moment.
      await s.edit((q) => q.withDecision(kC, const ReviewDecision.skip()));
      slow.gate.complete();
      await run;
      expect(s.queue.decisionFor(kC), isNotNull,
          reason: 'the old Save must not erase the newer draft');
      expect(s.queue.ranges, isEmpty, reason: 'the range itself is done');
      expect(const MomentReviewStore().load().decisionFor(kC), isNotNull,
          reason: 'and the stored blob agrees');
    });

    test('a second service reading the blob mid-Save sees the newer draft '
        'after the Save ends', () async {
      final s = MomentReviewService();
      final slow = _SlowFinish();
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      final run = s.save(_applier(FakeAnswerWriter(), slow),
          moments: const [mA, mB, mC], glasses: const [], now: reviewNow);
      await slow.started.future;
      await s.edit((q) => q.withDecision(kC, const ReviewDecision.skip()));
      slow.gate.complete();
      await run;
      final fresh = MomentReviewService()..reload();
      expect(fresh.queue.decisionFor(kC), isNotNull);
    });

    test('a failed item the user undid meanwhile is not resurrected', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withDecision(kA, const ReviewDecision.skip()));
      final gate = Completer<void>();
      final started = Completer<void>();
      final w = _GatedWriter(gate, started, failOn: {mA.key});
      final run = s.save(_applier(w, FakeRangeWriter()),
          moments: const [mA], glasses: const [], now: reviewNow);
      await started.future;
      await s.edit((q) => q.without(kA)); // undo while the write is in flight
      gate.complete();
      await run;
      expect(s.queue.isEmpty, isTrue);
    });

    test('Saves run one at a time, in order', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withDecision(kA, const ReviewDecision.skip()));
      final gate = Completer<void>();
      final started = Completer<void>();
      final w1 = _GatedWriter(gate, started);
      final first = s.save(_applier(w1, FakeRangeWriter()),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      await started.future;
      expect(s.saving, isTrue);
      await s.edit((q) => q.withDecision(kB, const ReviewDecision.skip()));
      final w2 = FakeAnswerWriter(log: w1.log);
      final second = s.save(_applier(w2, FakeRangeWriter()),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      await Future<void>.delayed(Duration.zero);
      expect(w2.skips, isEmpty, reason: 'the second waits for the first');
      gate.complete();
      await first;
      await second;
      expect(w1.skips, [mA.key]);
      expect(w2.skips, [mB.key], reason: 'and sees the queue as it is then');
      expect(s.saving, isFalse);
    });

    test('progress made by a Save is merged even if its screen is gone',
        () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      await s.save(
          _applier(FakeAnswerWriter(failOn: {mB.key}), FakeRangeWriter()),
          moments: const [mA, mB],
          glasses: const [],
          now: reviewNow);
      final r = s.queue.ranges.single;
      expect((r.windowWritten, r.startLabelled), (true, true));
      final fresh = MomentReviewService()..reload();
      expect(fresh.queue.ranges.single.windowWritten, isTrue,
          reason: 'stored, so a restart resumes it');
    });
  });
}

class _Flaky extends MomentReviewStore {
  const _Flaky(this.fail);
  final bool Function() fail;
  @override
  Future<bool> save(MomentReviewQueue q) async => !fail();
}

class _GatedWriter extends FakeAnswerWriter {
  _GatedWriter(this.gate, this.started, {super.failOn});
  final Completer<void> gate, started;

  @override
  Future<MomentAnswerResult> skip(PendingMoment m, {DateTime? now}) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    return super.skip(m, now: now);
  }
}
