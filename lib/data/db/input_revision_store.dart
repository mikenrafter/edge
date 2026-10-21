// input_revision_store.dart — per-input revisions (design 06 phase 1c).
//
// RED-PHASE STUBS: every function is a no-op. Green creates the
// `input_revision(source, scope, rev)` table, the per-table triggers from
// `kInputCatalogue`, and the bump/snapshot behaviour.

import 'package:sqflite/sqflite.dart';

/// source -> scope -> revision. Absent means revision 0.
typedef InputRevSnapshot = Map<String, Map<String, int>>;

/// Creates `input_revision` and the AFTER INSERT/UPDATE/DELETE triggers for
/// every catalogued table. Idempotent (CREATE ... IF NOT EXISTS).
Future<void> createInputRevision(DatabaseExecutor db) async {}

/// Adds 1 to the revision of ([source], [scope]); [scope] is a day label or ''.
/// For non-table setters (profile, policies).
Future<void> bumpInputRev(String source, String scope,
    {DatabaseExecutor? db}) async {}

/// Revisions of [sources] for the global scope '' and every day label in
/// [fromDay]..[toDay] inclusive. `decoded` is summed from `input_rev` buckets
/// per day.
Future<InputRevSnapshot> inputRevSnapshot(
  Iterable<String> sources, {
  required String fromDay,
  required String toDay,
  DatabaseExecutor? db,
}) async => <String, Map<String, int>>{};
