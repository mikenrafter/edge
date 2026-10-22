// group_row_store.dart — revisioned per-group rows (design 06 phase 1d).
//
// `group_row(day_id, group_id, revision, ...)`: next to each accepted
// day_result write, the bundle's slice per calculation group, with the
// group's counter, its ancestors' counters and a stamp of the input revisions
// it (and its ancestors) read. SHADOW ONLY: nothing reads these rows in 1d
// (`published` stays 0), so a failure here must never break serving.
//
// Owner: [writeGroupRows], called from `_ldbPutDayResult` inside its
// transaction and only after that write was accepted. A refused frozen write
// reaches no code here.
//
// Rules per (day, group):
//  * no row yet: revision 1.
//  * the latest revision is provisional (finalized = 0): replaced in place on
//    any accepted write, counter moves included.
//  * the latest revision is finished: immutable. A write whose counter,
//    ancestor counters or input stamp differs adds revision + 1; one that
//    matches changes nothing. `DayResultWrite.userOverride` is the only way to
//    replace a finished revision in place.
//  * a descendant sees an ancestor's change on its own: ancestors_json holds
//    every transitive ancestor's counter, and input_stamp_json covers the
//    inputs of the group AND of its transitive ancestors (foundations own no
//    row, so a stamp-only change upstream could not be seen any other way).
//
// The payload is the slice of the map that is ENCODED into day_result
// (`payload_json`, after SeriesCodec), so assembling the slices reproduces the
// stored string byte for byte.
//
// An unowned bundle key means the day cannot be sliced completely: no group
// rows are written for it (a half-sliced day must not look complete), the
// day_result row is untouched, and [groupRowDiagnostics] counts it.

import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../compute/groups/group_registry.dart';
import '../../compute/groups/group_types.dart';
import '../../compute/groups/input_catalogue.dart';
import '../../compute/groups/input_stamp.dart';
import '../../compute/groups/manifest_codec.dart';
import '../../compute/groups/publication.dart';
import '../../compute/groups/slice_bundle.dart';
import '../db.dart' show LocalDb;
import 'input_revision_store.dart';
import 'manifest_store.dart';

export '../../compute/groups/input_stamp.dart';

/// Test seam: the registry the writer reads counters and ancestors from.
/// null means [kMergedRegistry].
GroupRegistry? groupRegistryForTest;

/// Shadow-write diagnostics: bundles that could not be sliced.
class GroupRowDiagnostics {
  int unsliceable = 0;

  /// Shadow writes abandoned because day_result moved on (replaced or deleted)
  /// between the accepted commit and the shadow transaction.
  int superseded = 0;

  /// Stamp reads that failed; the day stored an unpinned stamp instead.
  int stampReadFailures = 0;
  String? lastProblem;
}

final GroupRowDiagnostics groupRowDiagnostics = GroupRowDiagnostics();

/// `CREATE TABLE IF NOT EXISTS group_row`. A literal at the call, not a
/// constant: the p21 write-seam guard reads the SQL text.
Future<void> createGroupRow(DatabaseExecutor db) async {
  // Serves kStampQuerySql's scope predicate (the primary key leads with
  // source). Covering: the query reads nothing else.
  // A speed-up only, so best effort: an upgrade must never brick over it, and
  // the next open's repair pass retries (the table exists in every real v77).
  try {
    await db.execute('CREATE INDEX IF NOT EXISTS idx_input_revision_scope '
        'ON input_revision(scope, source, rev)');
  } catch (_) {}
  await db.execute('CREATE TABLE IF NOT EXISTS group_row ('
        'day_id TEXT NOT NULL, group_id TEXT NOT NULL, '
        'revision INTEGER NOT NULL, counter INTEGER, ancestors_json TEXT, '
        'input_stamp_json TEXT, payload BLOB, computed_at INTEGER, '
        'finalized INTEGER, partial INTEGER, published INTEGER DEFAULT 0, '
        'PRIMARY KEY (day_id, group_id, revision))');
}

const int _rangeDays = 28;

String _addDays(String day, int n) {
  final d = DateTime.parse(day);
  final x = DateTime(d.year, d.month, d.day + n);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${x.year.toString().padLeft(4, '0')}-${two(x.month)}-${two(x.day)}';
}

/// The scopes of [i] that matter to [day].
bool _inScope(String source, InputScope s, String scope, String day) {
  if (scope == '') return true;
  switch (s) {
    case InputScope.global:
      return false;
    case InputScope.day:
      return scope == day;
    case InputScope.dayAndNext:
      return scope == day || scope == _addDays(day, 1);
    case InputScope.range:
      // The day's own metric_series is this very write's output: counting it
      // would move the stamp on every accepted write (baselines read the
      // days BEFORE the day).
      return scope.compareTo(_addDays(day, -_rangeDays)) >= 0 &&
          (source == 'metric_series'
              ? scope.compareTo(day) < 0
              : scope.compareTo(day) <= 0);
  }
}

/// [snap] narrowed to what [inputs] read for [dayId]: per declared input, only
/// the scopes in its window. Shared by the writer (what a row stores) and the
/// closure check (what the row would store now), so the two compare as text.
InputStamp stampWindow(InputStamp snap, List<InputDecl> inputs, String dayId) {
  final stamp = <String, Map<String, int>>{};
  for (final i in inputs) {
    final scopes = snap[i.id];
    if (scopes == null) continue;
    final keep = {
      for (final s in scopes.entries)
        if (_inScope(i.id, i.scope, s.key, dayId)) s.key: s.value,
    };
    if (keep.isEmpty) continue;
    (stamp[i.id] ??= <String, int>{}).addAll(keep);
  }
  return stamp;
}

/// The inputs a group's row is stamped with: its own and its transitive
/// ancestors' (foundations own no row).
List<InputDecl> closureInputs(GroupRegistry reg, String id) {
  final byId = {for (final g in reg.groups) g.id: g};
  return [
    for (final gid in [id, ...transitiveDeps(reg, id)])
      if (byId[gid] != null) ...declaredInputs(byId[gid]!),
  ];
}

/// Canonical JSON of `{key: int}` (keys sorted: equal content, equal text).
/// Keys are group, input and scope ids (no characters needing escapes).
String canonCounters(Map<String, int> m) =>
    '{${[for (final k in (m.keys.toList()..sort())) '"$k":${m[k]}'].join(',')}}';

String canonStamp(Map<String, Map<String, int>> m, {bool unpinned = false}) =>
    '{${[
      if (unpinned) '"_unpinned":true',
      for (final k in (m.keys.toList()..sort())) '"$k":${canonCounters(m[k]!)}',
    ].join(',')}}';

/// The stamp window's `input_revision` rows. Names no source (the read
/// tracker's SQL log would count each as a derive read) and is served by
/// idx_input_revision_scope.
const String kStampQuerySql = 'SELECT source, scope, rev FROM input_revision '
    "WHERE scope = '' OR (scope >= ? AND scope <= ?)";

/// The latest revision's metadata per group of a day: no payload BLOBs.
const String kLatestRevisionSql =
    'SELECT g.group_id, g.revision, g.counter, g.ancestors_json, '
    'g.input_stamp_json, g.finalized, g.published FROM group_row g '
    'JOIN (SELECT group_id, MAX(revision) AS r FROM group_row '
    'WHERE day_id = ? GROUP BY group_id) m '
    'ON g.group_id = m.group_id AND g.revision = m.r WHERE g.day_id = ?';

/// The input revisions of [dayId]'s stamp window right now. The engine calls
/// this BEFORE it reads any input, so the stamp names what the result was
/// computed from even if the inputs move while it computes.
Future<InputStamp> captureInputStamp(String dayId,
    {DatabaseExecutor? db}) async {
  final ex = db ?? await LocalDb.instance;
  final from = _addDays(dayId, -_rangeDays), to = _addDays(dayId, 1);
  final out = <String, Map<String, int>>{};
  for (final r in await ex.rawQuery(kStampQuerySql, [from, to])) {
    (out[r['source'] as String] ??= <String, int>{})[r['scope'] as String] =
        (r['rev'] as num).toInt();
  }
  // `decoded` is not in input_revision; it comes from its 15-minute buckets.
  out.addAll(await inputRevSnapshot(const ['decoded'],
      fromDay: from, toDay: to, db: ex));
  return out;
}

/// Test seam: make every stamp read fail (a damaged input_revision).
bool stampReadFaultForTest = false;

/// [captureInputStamp] that never throws: on any error the day gets a null
/// stamp (stored unpinned), counted and logged. The real derive must not die
/// on a shadow read.
Future<InputStamp?> captureInputStampBestEffort(String dayId) async {
  try {
    if (stampReadFaultForTest) throw StateError('stamp read fault (test)');
    return await captureInputStamp(dayId);
  } catch (e) {
    groupRowDiagnostics.stampReadFailures++;
    dev.log('$dayId stamp read failed: $e', name: 'group_row');
    return null;
  }
}

/// Every `metric_series` revision right now (scope -> rev), or null when the
/// read fails. Taken BEFORE the shared baseline history is loaded and carried
/// with it: the history is frozen at that moment, whatever the rows do later.
Future<Map<String, int>?> captureMetricSeriesRevs() async {
  try {
    if (stampReadFaultForTest) throw StateError('stamp read fault (test)');
    final db = await LocalDb.instance;
    return {
      for (final r in await db.rawQuery(
          'SELECT scope, rev FROM input_revision WHERE source = ?',
          ['metric_series']))
        r['scope'] as String: (r['rev'] as num).toInt(),
    };
  } catch (e) {
    groupRowDiagnostics.stampReadFailures++;
    dev.log('metric_series revisions read failed: $e', name: 'group_row');
    return null;
  }
}

/// [day]'s stamp with each metric_series scope held to the revision the shared
/// history was loaded at, when that is EARLIER (revisions only go up, so the
/// earlier one is what the frozen history actually held; a scope the history
/// predates is dropped = revision 0). A null [day] or null [history] (its
/// capture failed) cannot be certified: null, stored unpinned.
InputStamp? stampNotLaterThan(InputStamp? day, Map<String, int>? history) {
  if (day == null || history == null) return null;
  final ms = day['metric_series'];
  if (ms == null) return day;
  final out = <String, Map<String, int>>{...day};
  final merged = <String, int>{};
  for (final e in ms.entries) {
    final h = history[e.key] ?? 0;
    final rev = h < e.value ? h : e.value;
    if (rev > 0) merged[e.key] = rev;
  }
  out['metric_series'] = merged;
  return out;
}

/// Writes the group rows of a day_result write that was just ACCEPTED and
/// committed, in a small transaction of their own, from the stored payload
/// (idempotent: a rerun re-slices the same string). NEVER throws; a failure is
/// counted in [groupRowDiagnostics] and logged, and leaves no half set.
///
/// [stamp] is the capture from before the inputs were read; null (imports,
/// backfills) stores the persist-time revisions marked `"_unpinned":true`,
/// which a reuse decision must refuse.
Future<void> writeGroupRowsAfterCommit({
  required String dayId,
  required int algoVersion,
  required bool finalized,
  required bool partial,
  required bool skipped,
  required bool userOverride,
  required String expectedPayload,
  required int expectedComputedAt,
  InputStamp? stamp,
  Map<String, double?> series = const {},
}) async {
  if (skipped) return;
  try {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      // The accepted write's identity, checked inside this transaction: if
      // another write replaced the day (or it was deleted) since, this
      // write's stamp and flags no longer describe what is stored.
      final rows = await txn.query('day_result',
          columns: ['payload_json', 'computed_at'],
          where: 'day_id = ? AND algo_version = ?',
          whereArgs: [dayId, algoVersion],
          limit: 1);
      if (rows.isEmpty ||
          (rows.single['computed_at'] as num?)?.toInt() !=
              expectedComputedAt ||
          rows.single['payload_json'] != expectedPayload) {
        groupRowDiagnostics.superseded++;
        dev.log('$dayId shadow write abandoned: day_result moved on',
            name: 'group_row');
        return;
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final written = await writeGroupRows(txn,
          dayId: dayId,
          encodedPayload: expectedPayload,
          finalized: finalized,
          partial: partial,
          skipped: false,
          userOverride: userOverride,
          nowMs: nowMs,
          stamp: stamp);
      // Unpinned (no stamp): its revisions are never reusable, so it
      // publishes nothing. Pinned: the manifest goes in THIS transaction, so
      // the rows and the manifest that names them commit or roll back as one.
      if (written == null || stamp == null) return;
      final PublishResult r;
      try {
        r = await publishInTxn(txn,
            dayId: dayId,
            expectedPriorSeq: await latestManifestSeq(txn, dayId),
            selected: written.selected,
            keyOrder: written.keyOrder,
            bundleSha: sha256Hex(expectedPayload),
            seriesSha: seriesSha(partial ? const {} : series),
            freshness: {
              'algo_version': algoVersion,
              'finalized': finalized,
              'partial': partial,
              'computed_at': expectedComputedAt,
            },
            nowMs: nowMs);
      } catch (e) {
        throw _ManifestFailure(e);
      }
      switch (r) {
        case Published():
          manifestDiagnostics.published++;
        case PublishRefused(:final reason, :final problems):
          manifestDiagnostics.refused++;
          manifestDiagnostics.lastProblem =
              '$dayId ${reason.name}: ${problems.map((p) => '${p.group} ${p.reason.name}').join(', ')}';
        case PublishFailed(:final error):
          throw _ManifestFailure(error);
      }
    });
  } on _ManifestFailure catch (e) {
    manifestDiagnostics.failed++;
    manifestDiagnostics.lastProblem = '${e.cause}';
    dev.log('$dayId manifest failed: ${e.cause}', name: 'group_row');
  } catch (e) {
    groupRowDiagnostics.unsliceable++;
    groupRowDiagnostics.lastProblem = '$e';
    dev.log('$dayId group rows failed: $e', name: 'group_row');
  }
}

/// A manifest publication that threw inside the shadow transaction; unwinds
/// the transaction (rows and manifest travel together) and is counted apart
/// from a row failure.
class _ManifestFailure implements Exception {
  _ManifestFailure(this.cause);
  final Object cause;
}

/// The rows themselves. An unsliceable bundle returns quietly; database errors
/// propagate to the caller's transaction.
///
/// Returns the latest revision of every group it wrote and the bundle's path
/// order (what a manifest names), or null when it wrote nothing, or when a
/// sliced key has an owner this registry does not know (the set would be
/// incomplete, so it is not publishable).
Future<({Map<String, int> selected, List<String> keyOrder})?> writeGroupRows(
  DatabaseExecutor txn, {
  required String dayId,
  required String encodedPayload,
  required bool finalized,
  required bool partial,
  required bool skipped,
  required bool userOverride,
  required int nowMs,
  InputStamp? stamp,
}) async {
  if (skipped) return null;
  final ({Map<String, List<(String, String)>> slices, List<String> keyOrder})
      sliced;
  try {
    sliced = sliceBundleJson(encodedPayload);
  } on StateError catch (e) {
    groupRowDiagnostics.unsliceable++;
    groupRowDiagnostics.lastProblem = e.message;
    dev.log('$dayId not sliced: ${e.message}', name: 'group_row');
    return null;
  }
  final reg = groupRegistryForTest ?? kMergedRegistry;
  final byId = {for (final g in reg.groups) g.id: g};

  final decls = <String, GroupDecl>{};
  final anc = <String, Set<String>>{};
  final inputs = <String, List<InputDecl>>{};
  final sources = <String>{};
  for (final id in sliced.slices.keys) {
    final g = byId[id];
    if (g == null) continue; // owner not in this registry: nothing to version
    decls[id] = g;
    anc[id] = transitiveDeps(reg, id);
    inputs[id] = [
      for (final gid in [id, ...anc[id]!])
        if (byId[gid] != null) ...declaredInputs(byId[gid]!),
    ];
    sources.addAll(inputs[id]!.map((i) => i.id));
  }
  if (decls.isEmpty) return null;
  final selected = <String, int>{};

  // Pinned: the capture from before the inputs were read. Unpinned: now.
  final stampIsNull = stamp == null;
  final snap = stamp ?? await captureInputStamp(dayId, db: txn);

  final latest = <String, Map<String, Object?>>{
    for (final r in await txn.rawQuery(kLatestRevisionSql, [dayId, dayId]))
      r['group_id'] as String: r,
  };

  for (final e in decls.entries) {
    final id = e.key;
    final g = e.value;
    final ancestors = {
      for (final a in anc[id]!)
        if (byId[a] != null) a: byId[a]!.counter,
    };
    final stamp = stampWindow(snap, inputs[id]!, dayId);
    final ancestorsJson = canonCounters(ancestors);
    final stampJson = canonStamp(stamp, unpinned: stampIsNull);
    final values = <String, Object?>{
      'counter': g.counter,
      'ancestors_json': ancestorsJson,
      'input_stamp_json': stampJson,
      'payload': Uint8List.fromList(utf8.encode(
          '{${[for (final (p, raw) in sliced.slices[id]!) '"$p":$raw'].join(',')}}')),
      'computed_at': nowMs,
      'finalized': finalized ? 1 : 0,
      'partial': partial ? 1 : 0,
    };
    final cur = latest[id];
    if (cur == null) {
      await txn.insert('group_row',
          {'day_id': dayId, 'group_id': id, 'revision': 1, ...values});
      selected[id] = 1;
      continue;
    }
    final rev = (cur['revision'] as num).toInt();
    selected[id] = rev;
    final isFinished = (cur['finalized'] as num?)?.toInt() == 1;
    // A revision a manifest names is what its bundle_sha vouches for: never
    // rewritten in place, provisional or not. A new revision takes over when
    // (and only when) a publication moves the manifest to it.
    final isPublished = (cur['published'] as num?)?.toInt() == 1;
    if (!isPublished && (!isFinished || userOverride)) {
      await txn.update('group_row', values,
          where: 'day_id = ? AND group_id = ? AND revision = ?',
          whereArgs: [dayId, id, rev]);
      continue;
    }
    final moved = (cur['counter'] as num?)?.toInt() != g.counter ||
        cur['ancestors_json'] != ancestorsJson ||
        cur['input_stamp_json'] != stampJson;
    if (moved || (isPublished && (!isFinished || userOverride))) {
      await txn.insert('group_row',
          {'day_id': dayId, 'group_id': id, 'revision': rev + 1, ...values});
      selected[id] = rev + 1;
    }
  }
  if (decls.length != sliced.slices.length) return null;
  return (selected: selected, keyOrder: sliced.keyOrder);
}
