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
import '../../compute/groups/slice_bundle.dart';
import 'input_revision_store.dart';

/// Test seam: the registry the writer reads counters and ancestors from.
/// null means [kMergedRegistry].
GroupRegistry? groupRegistryForTest;

/// Shadow-write diagnostics: bundles that could not be sliced.
class GroupRowDiagnostics {
  int unsliceable = 0;
  String? lastProblem;
}

final GroupRowDiagnostics groupRowDiagnostics = GroupRowDiagnostics();

/// `CREATE TABLE IF NOT EXISTS group_row`. A literal at the call, not a
/// constant: the p21 write-seam guard reads the SQL text.
Future<void> createGroupRow(DatabaseExecutor db) =>
    db.execute('CREATE TABLE IF NOT EXISTS group_row ('
        'day_id TEXT NOT NULL, group_id TEXT NOT NULL, '
        'revision INTEGER NOT NULL, counter INTEGER, ancestors_json TEXT, '
        'input_stamp_json TEXT, payload BLOB, computed_at INTEGER, '
        'finalized INTEGER, partial INTEGER, published INTEGER DEFAULT 0, '
        'PRIMARY KEY (day_id, group_id, revision))');

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

/// Canonical JSON of `{key: int}` (keys sorted: equal content, equal text).
/// Keys are group, input and scope ids (no characters needing escapes).
String _canon(Map<String, int> m) =>
    '{${[for (final k in (m.keys.toList()..sort())) '"$k":${m[k]}'].join(',')}}';

String _canon2(Map<String, Map<String, int>> m) =>
    '{${[for (final k in (m.keys.toList()..sort())) '"$k":${_canon(m[k]!)}'].join(',')}}';

/// Writes the group rows of one accepted day_result write. [encodedPayload] is
/// exactly the string stored in `day_result.payload_json`. NEVER throws and
/// never disturbs the surrounding transaction: any failure rolls back only the
/// group rows (savepoint), is counted in [groupRowDiagnostics] and logged.
Future<void> writeGroupRowsShadow(
  DatabaseExecutor txn, {
  required String dayId,
  required String encodedPayload,
  required bool finalized,
  required bool partial,
  required bool skipped,
  required bool userOverride,
  required int nowMs,
}) async {
  // Shadow only: nothing here may fail or roll back the day_result write. A
  // savepoint confines a part-way failure to the group rows (no half set).
  try {
    await txn.execute('SAVEPOINT group_row_sp');
  } catch (e) {
    _shadowFailed(dayId, e);
    return;
  }
  try {
    await writeGroupRows(txn,
        dayId: dayId,
        encodedPayload: encodedPayload,
        finalized: finalized,
        partial: partial,
        skipped: skipped,
        userOverride: userOverride,
        nowMs: nowMs);
    await txn.execute('RELEASE group_row_sp');
  } catch (e) {
    _shadowFailed(dayId, e);
    try {
      await txn.execute('ROLLBACK TO group_row_sp');
      await txn.execute('RELEASE group_row_sp');
    } catch (e2) {
      dev.log('$dayId savepoint rollback failed: $e2', name: 'group_row');
    }
  }
}

void _shadowFailed(String dayId, Object e) {
  groupRowDiagnostics.unsliceable++;
  groupRowDiagnostics.lastProblem = '$e';
  dev.log('$dayId group rows failed: $e', name: 'group_row');
}

/// The rows themselves; use [writeGroupRowsShadow] from the write seam. An
/// unsliceable bundle returns quietly; database errors propagate.
Future<void> writeGroupRows(
  DatabaseExecutor txn, {
  required String dayId,
  required String encodedPayload,
  required bool finalized,
  required bool partial,
  required bool skipped,
  required bool userOverride,
  required int nowMs,
}) async {
  if (skipped) return;
  final ({Map<String, List<(String, String)>> slices, List<String> keyOrder})
      sliced;
  try {
    sliced = sliceBundleJson(encodedPayload);
  } on StateError catch (e) {
    groupRowDiagnostics.unsliceable++;
    groupRowDiagnostics.lastProblem = e.message;
    dev.log('$dayId not sliced: ${e.message}', name: 'group_row');
    return;
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
  if (decls.isEmpty) return;

  // Every source's rows in the window, filtered in Dart: naming the sources in
  // the SQL (or its arguments) would make the read-tracking SQL log count this
  // stamp as a derive read of each of them. `decoded` is not in
  // input_revision; it comes from its 15-minute buckets.
  final from = _addDays(dayId, -_rangeDays), to = _addDays(dayId, 1);
  final snap = <String, Map<String, int>>{};
  for (final r in await txn.rawQuery(
      'SELECT source, scope, rev FROM input_revision '
      "WHERE scope = '' OR (scope >= ? AND scope <= ?)",
      [from, to])) {
    final src = r['source'] as String;
    if (sources.contains(src)) {
      (snap[src] ??= <String, int>{})[r['scope'] as String] =
          (r['rev'] as num).toInt();
    }
  }
  if (sources.contains('decoded')) {
    snap.addAll(await inputRevSnapshot(const ['decoded'],
        fromDay: from, toDay: to, db: txn));
  }

  final latest = <String, Map<String, Object?>>{};
  for (final r in await txn.query('group_row',
      where: 'day_id = ?', whereArgs: [dayId], orderBy: 'revision')) {
    latest[r['group_id'] as String] = r; // ascending: the last one wins
  }

  for (final e in decls.entries) {
    final id = e.key;
    final g = e.value;
    final ancestors = {
      for (final a in anc[id]!)
        if (byId[a] != null) a: byId[a]!.counter,
    };
    final stamp = <String, Map<String, int>>{};
    for (final i in inputs[id]!) {
      final scopes = snap[i.id];
      if (scopes == null) continue;
      final keep = {
        for (final s in scopes.entries)
          if (_inScope(i.id, i.scope, s.key, dayId)) s.key: s.value,
      };
      if (keep.isEmpty) continue;
      (stamp[i.id] ??= <String, int>{}).addAll(keep);
    }
    final ancestorsJson = _canon(ancestors);
    final stampJson = _canon2(stamp);
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
      continue;
    }
    final rev = (cur['revision'] as num).toInt();
    final isFinished = (cur['finalized'] as num?)?.toInt() == 1;
    if (!isFinished || userOverride) {
      await txn.update('group_row', values,
          where: 'day_id = ? AND group_id = ? AND revision = ?',
          whereArgs: [dayId, id, rev]);
      continue;
    }
    final moved = (cur['counter'] as num?)?.toInt() != g.counter ||
        cur['ancestors_json'] != ancestorsJson ||
        cur['input_stamp_json'] != stampJson;
    if (moved) {
      await txn.insert('group_row',
          {'day_id': dayId, 'group_id': id, 'revision': rev + 1, ...values});
    }
  }
}
