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

  /// Runs one Save after any Save already running, on the queue as it is when
  /// this one starts, and merges the outcome into the CURRENT queue.
  Future<ReviewSaveReport> save(
    MomentReviewApplier applier, {
    required List<PendingMoment> moments,
    required List<AssumedGlass> glasses,
    required DateTime now,
  }) async {
    _running++;
    notifyListeners();
    try {
      // One at a time, in the order asked.
      if (_active) {
        final turn = Completer<void>();
        _waiting.add(turn);
        await turn.future;
      }
      _active = true;
      try {
        final snapshot = _queue;
        final report = await applier.apply(
          snapshot,
          moments: moments,
          glasses: glasses,
          now: now,
          // Progress is merged and stored as it happens, so a cut-off range
          // resumes.
          onProgress: (r) async {
            // A range undone while Save was still checking it stays undone:
            // the attempt (recorded before the write) is refused.
            final held = _queue.ranges
                .any((x) => x.startKey == r.startKey && x.endKey == r.endKey);
            if (!held && r.attempting && !r.windowWritten) {
              throw const RangeWithdrawnException();
            }
            _set(_queue.withRangeProgress(r));
            await _persist();
          },
        );
        _set(_merge(_queue, snapshot, report));
        await _persist();
        return report;
      } finally {
        _active = false;
        if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
      }
    } finally {
      _running--;
      notifyListeners();
    }
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
        q = MomentReviewQueue(
          decisions: q.decisions,
          ranges: [for (final r in q.ranges) if (ReviewKey.range(r) != key) r],
        );
      } else if (q.decisions.containsKey(key)) {
        q = MomentReviewQueue(
          decisions: {...q.decisions}..remove(key),
          ranges: q.ranges,
        );
      }
    }
    // A failed range keeps what the Save got done (even if it was re-added).
    for (final r in report.remaining.ranges) {
      final held = q.ranges
          .any((x) => x.startKey == r.startKey && x.endKey == r.endKey);
      // Progress is kept even if the range was dropped meanwhile (the window is
      // already written); a range that never started is not brought back.
      if (held || r.inProgress) q = q.withRangeProgress(r);
    }
    return q;
  }
}
