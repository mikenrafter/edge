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

/// A range holds a mark whose minute happened twice (the clocks went back) and
/// whose real time was never recorded: its order and length are unknowable, so
/// nothing is written.
class AmbiguousMarkException implements Exception {
  const AmbiguousMarkException(this.momentKey);
  final String momentKey;
  @override
  String toString() => 'AmbiguousMarkException: $momentKey happened twice';
}

/// Thrown by an `onProgress` callback to say the range was withdrawn (undone)
/// while Save was still checking it: nothing more is written for it, and it is
/// neither applied nor failed.
class RangeWithdrawnException implements Exception {
  const RangeWithdrawnException();
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
  /// applied, not failed — except a range Save already started, which resumes
  /// from its recorded progress whatever is still listed.
  ///
  /// A range is written only while both of its marks are still unanswered and
  /// its time is known (an answer from elsewhere wins; nothing is announced),
  /// validated first (`validateReviewRange`, against the writer's existing naps
  /// / sessions PLUS ranges applied earlier in this run). Its progress is handed
  /// to [onProgress] as it happens — the attempt BEFORE the write, then the
  /// written window, each label, the announcement — so a range cut short
  /// resumes instead of starting again or being forgotten. [onProgress] may
  /// throw `RangeWithdrawnException` to stop a range the user undid meanwhile. Its Tasker event is
  /// sent once, only after both labels landed.
  Future<ReviewSaveReport> apply(
    MomentReviewQueue queue, {
    required List<PendingMoment> moments,
    required List<AssumedGlass> glasses,
    required DateTime now,
    Future<void> Function(ReviewRange updated)? onProgress,
  }) async {
    final byMoment = {for (final m in moments) m.key: m};
    final byGlass = {for (final g in glasses) g.key: g};
    final export = exporter ?? TaskerMomentExport();

    // (when, key, action) — the action returns the item to announce, or null
    // when there is nothing to announce; it throws when the write failed.
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
    // The newest state of every range touched, kept even when it then fails.
    final latest = <String, ReviewRange>{};
    for (final r in queue.ranges) {
      final s = byMoment[r.startKey], e = byMoment[r.endKey];
      if (!r.inProgress && (s == null || e == null)) continue; // stale
      final key = ReviewKey.range(r);
      latest[key] = r;
      final at = r.startSec != null
          ? DateTime.fromMillisecondsSinceEpoch(r.startSec! * 1000)
          : (s?.local ?? e?.local ?? now);
      jobs.add((
        at: at,
        key: key,
        run: () => _range(r, s, e, now, doneNaps, doneSpans, export,
            (next) async {
              latest[key] = next;
              try {
                await onProgress?.call(next);
              } on RangeWithdrawnException {
                rethrow;
              } catch (_) {/* progress is best effort; the report has it too */}
            }),
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
      } on RangeWithdrawnException {
        latest.remove(j.key);
      } catch (e) {
        failed[j.key] = e;
      }
    }
    // Once for the whole batch, and also when a label failed after its nap
    // was stored.
    if (doneNaps.isNotEmpty) await ranges.finishNaps();

    return ReviewSaveReport(
      applied: applied,
      alreadyAnswered: already,
      failed: failed,
      remaining: MomentReviewQueue(
        decisions: {
          for (final e in queue.decisions.entries)
            if (failed.containsKey(e.key)) e.key: e.value,
        },
        ranges: [
          for (final r in queue.ranges)
            if (failed.containsKey(ReviewKey.range(r)))
              latest[ReviewKey.range(r)] ?? r,
        ],
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

  /// One range, resumable. [s] / [e] are the marks still listed as pending
  /// (null: answered). Returns done / already-answered; throws when a step
  /// failed, with the progress made so far already reported through [mark].
  Future<_Done> _range(
    ReviewRange r,
    PendingMoment? s,
    PendingMoment? e,
    DateTime now,
    List<NapMap> doneNaps,
    List<SessionSpan> doneSpans,
    TaskerMomentExport export,
    Future<void> Function(ReviewRange next) mark,
  ) async {
    var cur = r;
    Future<void> step(ReviewRange next) async {
      cur = next;
      await mark(next);
    }

    final startSec = r.startSec ?? s?.sec;
    final endSec = r.endSec ?? e?.sec;
    if (startSec == null || endSec == null) {
      throw StateError('a range without the time of both marks');
    }
    final start = DateTime.fromMillisecondsSinceEpoch(startSec * 1000);
    final end = DateTime.fromMillisecondsSinceEpoch(endSec * 1000);
    final nap = r.choice == MomentChoice.nap;

    if (!cur.windowWritten) {
      // A mark answered meanwhile (somewhere else) wins: write nothing.
      if (s == null || e == null) return const _Done.already();
      for (final m in [s, e]) {
        if (m.ambiguous) throw AmbiguousMarkException(m.key);
      }
      if (await writer.isAnswered(s) || await writer.isAnswered(e)) {
        return const _Done.already();
      }
      final err = await checkReviewRange(ranges,
          choice: r.choice,
          start: start,
          end: end,
          now: now,
          alsoNaps: doneNaps,
          alsoSpans: doneSpans,
          // Only the window THIS operation recorded as attempted may match an
          // existing row; any other match is somebody else's entry.
          ownAttempt: cur.attempting);
      if (err != null) throw ManualWindowException(err);

      // The attempt is recorded BEFORE the write, so a crash in between leaves
      // a trace the next Save can recognise as its own.
      await step(cur.copyWith(attempting: true));
      if (nap) {
        await ranges.logNap(
            dayId: dayLabelOf(start), startSec: startSec, endSec: endSec);
        doneNaps.add({'start': startSec, 'end': endSec});
      } else {
        await ranges.logWorkout(
            startSec: startSec,
            endSec: endSec,
            type: r.workoutType ?? 'other');
        doneSpans.add(SessionSpan(manualSessionId(startSec), startSec, endSec));
      }
      await step(cur.copyWith(windowWritten: true));
    }

    // Both marks leave the pending list only once the window is in. An answer
    // that is not ours (or a mark that is gone) is a conflict: no success is
    // announced.
    var conflict = false;
    Future<void> label(PendingMoment? m, bool done, bool isStart) async {
      if (done) return;
      if (m == null) {
        conflict = true;
        return;
      }
      final res = await writer.answer(m, r.choice, now: now);
      if (res == MomentAnswerResult.alreadyAnswered) conflict = true;
      await step(isStart
          ? cur.copyWith(startLabelled: true)
          : cur.copyWith(endLabelled: true));
    }

    await label(s, cur.startLabelled, true);
    await label(e, cur.endLabelled, false);
    if (conflict) return const _Done.already();

    if (!cur.announced) {
      await export.exportAll(
          [ReviewedItem(choice: r.choice, start: start, end: end)]);
      await step(cur.copyWith(announced: true));
    }
    return const _Done(null);
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
