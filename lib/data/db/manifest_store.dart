// manifest_store.dart — `day_manifest` reads (design 06 phase 1e).
//
// SHADOW ONLY: nothing is served from a manifest in phase 1. The debug check
// [checkManifestAgainstStored] compares the latest manifest's bundle hash with
// the stored payload and counts; it never replaces anything.
//
// Writes belong to `publication.dart` (`publish`), reached from
// `writeGroupRowsAfterCommit`. This file creates the table and reads it.

import 'package:sqflite/sqflite.dart';

import '../../compute/groups/manifest_codec.dart';

/// Publication counters, for tests and the issue report.
class ManifestDiagnostics {
  int published = 0;

  /// Publications refused by the compare-and-set or the closure check.
  int refused = 0;

  /// Publications that threw; the shadow transaction (rows too) rolled back.
  int failed = 0;

  /// Debug comparisons made, and how many disagreed with the stored payload.
  int checked = 0;
  int mismatched = 0;
  String? lastProblem;
}

final ManifestDiagnostics manifestDiagnostics = ManifestDiagnostics();

/// `CREATE TABLE IF NOT EXISTS day_manifest`. A literal at the call, not a
/// constant: the p21 write-seam guard reads the SQL text.
Future<void> createDayManifest(DatabaseExecutor db) async {
  await db.execute('CREATE TABLE IF NOT EXISTS day_manifest ('
      'day_id TEXT NOT NULL, manifest_seq INTEGER NOT NULL, '
      'compat INTEGER NOT NULL, registry_version INTEGER, '
      'selected_json TEXT, key_order_json TEXT, bundle_sha TEXT, '
      'series_sha TEXT, freshness_json TEXT, published_at INTEGER, '
      'PRIMARY KEY (day_id, manifest_seq))');
}

/// The highest manifest_seq of [dayId] of ANY compat (a newer build's rows
/// still occupy their numbers), or null when the day has none.
Future<int?> latestManifestSeq(DatabaseExecutor db, String dayId) async {
  final r = await db.rawQuery(
      'SELECT MAX(manifest_seq) AS s FROM day_manifest WHERE day_id = ?',
      [dayId]);
  return (r.first['s'] as num?)?.toInt();
}

/// The latest manifest of [dayId] this build can read: highest seq whose
/// compat is at or below [maxCompat] and which decodes. A newer build's row,
/// or a damaged one, is skipped in favour of the next older.
Future<Manifest?> latestManifest(DatabaseExecutor db, String dayId,
    {int maxCompat = kManifestCompat}) async {
  final rows = await db.query('day_manifest',
      where: 'day_id = ? AND compat <= ?',
      whereArgs: [dayId, maxCompat],
      orderBy: 'manifest_seq DESC');
  for (final r in rows) {
    final m = tryDecodeManifest(r, maxCompat: maxCompat);
    if (m != null) return m;
  }
  return null;
}

/// Debug only: does the latest manifest describe the stored payload of
/// ([dayId], [algoVersion])? Counts in [manifestDiagnostics]; never serves.
/// False without counting a mismatch when either side does not exist (an
/// unpinned or unpublished day has no manifest by design).
Future<bool> checkManifestAgainstStored(DatabaseExecutor db, String dayId,
    {required int algoVersion}) async {
  final m = await latestManifest(db, dayId);
  final rows = await db.query('day_result',
      columns: ['payload_json'],
      where: 'day_id = ? AND algo_version = ?',
      whereArgs: [dayId, algoVersion],
      limit: 1);
  if (m == null || rows.isEmpty) return false;
  manifestDiagnostics.checked++;
  if (m.bundleSha == sha256Hex(rows.single['payload_json'] as String)) {
    return true;
  }
  manifestDiagnostics.mismatched++;
  manifestDiagnostics.lastProblem = '$dayId manifest ${m.manifestSeq} differs '
      'from the stored payload';
  return false;
}
