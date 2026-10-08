// moment_review_apply.dart — Save: applies every queued decision.
//
// Each decision goes through the EXISTING writer (MomentAnswerWriter.answer /
// skip / answerSymptom, AssumedWaterWriter.keep / remove, ReviewRangeWriter for
// ranges). One item failing does not lose the others: it stays queued and is
// reported. Applied items are handed to Tasker (one broadcast each) only after
// their write landed. Skips and assumed-glass decisions are not exported.

import '../compute/manual_session.dart';
import '../compute/nap_edits.dart';
import '../data/assumed_water.dart';
import '../data/day_label.dart' show dayLabelOf;
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
  }) async {
    final byMoment = {for (final m in moments) m.key: m};
    final byGlass = {for (final g in glasses) g.key: g};
    final export = exporter ?? TaskerMomentExport();

    // (when, key, action) — action returns the item to announce, or null when
    // there is nothing to announce; it throws when the write failed.
    final jobs = <({DateTime at, String key, Future<_Done> Function() run})>[];
    for (final e in queue.decisions.entries) {
      final key = e.key, d = e.value;
      if (ReviewKey.isMoment(key)) {
        final m = byMoment[ReviewKey.plainOf(key)];
        if (m == null) continue;
        jobs.add((at: m.local, key: key, run: () => _moment(m, d, now)));
      } else {
        final g = byGlass[key.substring('glass:'.length)];
        if (g == null) continue;
        jobs.add((at: g.local, key: key, run: () => _glass(g, d)));
      }
    }
    // Windows written in THIS run, so a later range cannot overlap them even
    // when the writer's own read does not show them yet.
    final doneNaps = <NapMap>[];
    final doneSpans = <SessionSpan>[];
    for (final r in queue.ranges) {
      final s = byMoment[r.startKey], e = byMoment[r.endKey];
      if (s == null || e == null) continue;
      jobs.add((
        at: s.local,
        key: ReviewKey.range(r),
        run: () => _range(r, s, e, now, doneNaps, doneSpans),
      ));
    }
    final order = {for (var i = 0; i < jobs.length; i++) jobs[i]: i};
    jobs.sort((a, b) {
      final c = a.at.compareTo(b.at);
      return c != 0 ? c : order[a]!.compareTo(order[b]!);
    });

    final applied = <String>[], already = <String>[];
    final failed = <String, Object>{};
    for (final j in jobs) {
      try {
        final done = await j.run();
        if (done.alreadyAnswered) {
          already.add(j.key);
          continue;
        }
        applied.add(j.key);
        final item = done.announce;
        if (item != null) await export.exportAll([item]);
      } catch (e) {
        failed[j.key] = e;
      }
    }
    // Once for the whole batch, and also when a label failed after its nap
    // was stored.
    if (doneNaps.isNotEmpty) await ranges.finishNaps();

    final failedRanges = [
      for (final r in queue.ranges)
        if (failed.containsKey(ReviewKey.range(r))) r,
    ];
    return ReviewSaveReport(
      applied: applied,
      alreadyAnswered: already,
      failed: failed,
      remaining: MomentReviewQueue(
        decisions: {
          for (final e in queue.decisions.entries)
            if (failed.containsKey(e.key)) e.key: e.value,
        },
        ranges: failedRanges,
      ),
    );
  }

  Future<_Done> _moment(PendingMoment m, ReviewDecision d, DateTime now) async {
    final MomentAnswerResult r;
    switch (d.kind) {
      case ReviewDecisionKind.label:
        r = await writer.answer(m, d.choice!,
            value: d.value, note: d.note, now: now);
      case ReviewDecisionKind.skip:
        r = await writer.skip(m, now: now);
      case ReviewDecisionKind.symptom:
        r = await writer.answerSymptom(m, d.symptom!, now: now);
      case ReviewDecisionKind.keepGlass:
      case ReviewDecisionKind.removeGlass:
        throw StateError('a glass decision on a moment');
    }
    if (r == MomentAnswerResult.alreadyAnswered) return const _Done.already();
    // A skip says nothing worth announcing; an answer does.
    if (d.kind == ReviewDecisionKind.skip) return const _Done(null);
    return _Done(ReviewedItem(
        choice: d.choice!, start: m.local, value: d.value));
  }

  Future<_Done> _glass(AssumedGlass g, ReviewDecision d) async {
    if (d.kind == ReviewDecisionKind.keepGlass) {
      await assumedWriter.keep(g);
    } else if (d.kind == ReviewDecisionKind.removeGlass) {
      await assumedWriter.remove(g);
    } else {
      throw StateError('a moment decision on a glass');
    }
    return const _Done(null);
  }

  Future<_Done> _range(ReviewRange r, PendingMoment s, PendingMoment e,
      DateTime now, List<NapMap> doneNaps, List<SessionSpan> doneSpans) async {
    final start = s.local, end = e.local;
    final startSec = start.millisecondsSinceEpoch ~/ 1000;
    final endSec = end.millisecondsSinceEpoch ~/ 1000;
    final dayId = dayLabelOf(start);
    final bool nap = r.choice == MomentChoice.nap;

    // Check before writing.
    final err = await checkReviewRange(ranges,
        choice: r.choice,
        start: start,
        end: end,
        now: now,
        alsoNaps: doneNaps,
        alsoSpans: doneSpans);
    if (err != null) throw ManualWindowException(err);

    if (nap) {
      await ranges.logNap(dayId: dayId, startSec: startSec, endSec: endSec);
      doneNaps.add({'start': startSec, 'end': endSec});
    } else {
      await ranges.logWorkout(
          startSec: startSec, endSec: endSec, type: r.workoutType ?? 'other');
      doneSpans.add(SessionSpan(manualSessionId(startSec), startSec, endSec));
    }
    // Both marks leave the pending list only once the window is in.
    await writer.answer(s, r.choice, now: now);
    await writer.answer(e, r.choice, now: now);
    return _Done(ReviewedItem(choice: r.choice, start: start, end: end));
  }
}

class _Done {
  const _Done(this.announce) : alreadyAnswered = false;
  const _Done.already()
      : announce = null,
        alreadyAnswered = true;
  final ReviewedItem? announce;
  final bool alreadyAnswered;
}
