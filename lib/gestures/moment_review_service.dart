// moment_review_service.dart — the ONE owner of the review queue.
//
// Every screen edits and saves through this object. Without that, a Save that
// outlives its screen finished by writing its own copy of the queue over
// whatever a newer screen had queued, and two Saves could run at once. Here
// every edit applies to the CURRENT queue, Saves run one at a time, and a
// Save's outcome is MERGED into the current queue (items that landed leave, a
// range's progress is kept) instead of replacing it.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/assumed_water.dart';
import 'moment_follow_ups.dart';
import 'moment_review_apply.dart';
import 'moment_review_queue.dart';
import 'moment_review_store.dart';

class MomentReviewService extends ChangeNotifier {
  MomentReviewService({this.store = const MomentReviewStore()}) {
    _queue = store.load();
  }

  /// The app-wide instance.
  static final MomentReviewService shared = MomentReviewService();

  final MomentReviewStore store;

  late MomentReviewQueue _queue;
  int _revision = 0;
  int _running = 0;
  bool _persistFailed = false;
  bool _active = false;
  final List<Completer<void>> _waiting = [];

  MomentReviewQueue get queue => _queue;

  /// Bumped by every change to the queue.
  int get revision => _revision;

  /// A Save is running or waiting.
  bool get saving => _running > 0;

  /// True after a queue write the platform did not confirm: the choices are
  /// kept for this session but may be lost if the app closes.
  bool get persistFailed => _persistFailed;

  /// Re-reads the stored queue (unless a Save is running, whose in-memory
  /// queue is the newer truth). Quiet: it does not notify.
  void reload() {
    if (saving) return;
    _queue = store.load();
    _revision++;
  }

  Future<bool> _persist() async {
    var ok = false;
    try {
      ok = await store.save(_queue);
    } catch (_) {
      ok = false;
    }
    if (_persistFailed == ok) {
      _persistFailed = !ok;
      notifyListeners();
    }
    return ok;
  }

  void _set(MomentReviewQueue q) {
    _queue = q;
    _revision++;
    notifyListeners();
  }

  /// Applies [f] to the CURRENT queue, bumps the revision, notifies, persists.
  /// Returns whether the platform confirmed the write.
  Future<bool> edit(MomentReviewQueue Function(MomentReviewQueue q) f) {
    _set(f(_queue));
    return _persist();
  }

  /// Drops drafts for items no longer pending (`MomentReviewQueue.dropStale`).
  Future<bool> adopt(Set<String> pendingReviewKeys) {
    final kept = _queue.dropStale(pendingReviewKeys);
    if (kept.length == _queue.length && kept.ranges.length == _queue.ranges.length) {
      return Future.value(true);
    }
    return edit((q) => q.dropStale(pendingReviewKeys));
  }

  /// Runs [job] when no other critical section is running, in the order asked.
  /// Every write that answers a mark (a Save's decisions, a range's window and
  /// both labels, a direct answer) runs in one of these, so no answer can land
  /// between another's checks and its writes.
  Future<T> _exclusive<T>(Future<T> Function() job) async {
    _running++;
    notifyListeners();
    try {
      if (_active) {
        final turn = Completer<void>();
        _waiting.add(turn);
        await turn.future;
      }
      _active = true;
      try {
        return await job();
      } finally {
        _active = false;
        if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
      }
    } finally {
      _running--;
      notifyListeners();
    }
  }

  /// One direct answer ("Log a workout at this time" labels its mark at once),
  /// in the same critical section as Saves. Returns [write]'s result; the mark's
  /// queued draft goes with it (an unstarted range it belonged to dissolves).
  /// Refused (StateError, nothing written) for a mark of a range Save has
  /// started.
  Future<MomentAnswerResult> answerDirect(
      PendingMoment m, Future<MomentAnswerResult> Function() write) {
    return _exclusive(() async {
      if (_queue.rangeOf(m.key)?.inProgress == true) {
        throw StateError('${m.key} belongs to a range that is being saved');
      }
      final result = await write();
      _set(_queue.without(ReviewKey.moment(m)));
      await _persist();
      return result;
    });
  }

  /// Runs one Save after any critical section already running, on the queue as
  /// it is when this one starts, and merges the outcome into the CURRENT queue.
  Future<ReviewSaveReport> save(
    MomentReviewApplier applier, {
    required List<PendingMoment> moments,
    required List<AssumedGlass> glasses,
    required DateTime now,
  }) {
    return _exclusive(() async {
      final snapshot = _queue;
      final report = await applier.apply(
        snapshot,
        moments: moments,
        glasses: glasses,
        now: now,
        // Progress is merged and STORED as it happens, so a cut-off range
        // resumes. If the store does not confirm it, the range stops here,
        // before its next write: carrying on would leave work that a restart
        // cannot see.
        onProgress: (r) async {
          // A range undone while Save was still checking it stays undone: the
          // attempt (recorded before the write) is refused.
          // Identity, not just the two marks: another screen may have replaced
          // the pair (same marks, other choice) while this Save was checking,
          // and that newer decision must not be overwritten.
          final held = _queue.ranges.any((x) => x.sameDecision(r));
          if (!held && r.attempting && !r.windowWritten) {
            throw const RangeWithdrawnException();
          }
          _set(_queue.withRangeProgress(r));
          if (!await _persist()) throw const ProgressNotPersistedException();
        },
      );
      _set(_merge(_queue, snapshot, report));
      await _persist();
      return report;
    });
  }

  /// [current] (what the queue is now) with the outcome of a Save that ran on
  /// [snapshot]: every item that landed (or was answered elsewhere) leaves,
  /// whatever was queued or changed meanwhile is untouched, and a range keeps
  /// the progress the Save made on it.
  MomentReviewQueue _merge(MomentReviewQueue current, MomentReviewQueue snapshot,
      ReviewSaveReport report) {
    var q = current;
    for (final key in [...report.applied, ...report.alreadyAnswered]) {
      if (key.startsWith('range:')) {
        final was = snapshot.ranges
            .where((r) => ReviewKey.range(r) == key)
            .firstOrNull;
        // Only the range this Save worked on: a different decision queued under
        // the same marks since stays.
        q = MomentReviewQueue(
          decisions: q.decisions,
          ranges: [
            for (final r in q.ranges)
              if (ReviewKey.range(r) != key ||
                  (was != null && !r.sameDecision(was)))
                r,
          ],
        );
      } else if (q.decisions.containsKey(key) &&
          q.decisions[key] == snapshot.decisions[key]) {
        // Only the decision this Save applied: a newer, different one for the
        // same mark stays queued.
        q = MomentReviewQueue(
          decisions: {...q.decisions}..remove(key),
          ranges: q.ranges,
        );
      }
    }
    // A failed range keeps what the Save got done (even if it was re-added).
    for (final r in report.remaining.ranges) {
      final held = q.ranges.where(
          (x) => x.startKey == r.startKey && x.endKey == r.endKey);
      // A different decision under the same marks is newer: leave it. Progress
      // of THIS range is kept even if it was dropped meanwhile (the window is
      // already written); a range that never started is not brought back.
      if (held.isNotEmpty) {
        if (held.first.sameDecision(r)) q = q.withRangeProgress(r);
      } else if (r.inProgress) {
        q = q.withRangeProgress(r);
      }
    }
    return q;
  }
}
