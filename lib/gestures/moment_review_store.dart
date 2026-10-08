// moment_review_store.dart — where the queued review decisions live between
// visits. RED stubs.
//
// Decision: a `Prefs` JSON blob (`moment_review.queue`), not a table. The queue
// is a handful of small drafts that are thrown away on Save, with no history to
// query, so a table would cost a schema bump and a migration for nothing. The
// blob is written on every queue change (not on dispose), so it survives a kill.

import 'moment_review_queue.dart';

class MomentReviewStore {
  const MomentReviewStore();

  static const String prefKey = 'moment_review.queue';

  /// Reads the stored queue; absent or corrupt gives an empty one. Never throws.
  MomentReviewQueue load() => throw UnimplementedError('RED stub');

  /// Writes [q]. An empty queue leaves no draft behind.
  Future<void> save(MomentReviewQueue q) => throw UnimplementedError('RED stub');
}
