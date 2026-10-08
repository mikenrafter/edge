// moment_review_store.dart — where the queued review decisions live between
// visits.
//
// Decision: a `Prefs` JSON blob (`moment_review.queue`), not a table. The queue
// is a handful of small drafts that are thrown away on Save, with no history to
// query, so a table would cost a schema bump and a migration for nothing. The
// blob is written on every queue change (not on dispose), so it survives a kill.

import 'dart:convert';

import '../state/prefs.dart';
import 'moment_review_queue.dart';

class MomentReviewStore {
  const MomentReviewStore();

  static const String prefKey = 'moment_review.queue';

  /// Reads the stored queue; absent or corrupt gives an empty one. Never throws.
  MomentReviewQueue load() {
    try {
      final raw = Prefs.getString(prefKey, '');
      if (raw.isEmpty) return MomentReviewQueue.empty;
      return MomentReviewQueue.fromJson(jsonDecode(raw));
    } catch (_) {
      return MomentReviewQueue.empty;
    }
  }

  /// Writes [q] and returns the platform's own answer: false when there is no
  /// storage, the write was refused, or it threw. An empty queue leaves no draft
  /// behind. The write reaches the preference cache before the first await, so
  /// a read right after sees it even before the platform confirms.
  Future<bool> save(MomentReviewQueue q) =>
      Prefs.setStringAcked(prefKey, q.isEmpty ? '' : jsonEncode(q.toJson()));
}
