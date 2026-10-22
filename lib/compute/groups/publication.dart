// publication.dart — validate and publish a day's manifest (design 06 1e).
//
// A publication selects one revision per group, checks that the whole
// dependency closure is still current, and records it as the day's next
// manifest. It is compare-and-set on the prior manifest_seq, so an assembly
// that started before a newer one published cannot overwrite it.
//
// SHADOW ONLY: `publish` marks `group_row.published` and adds a `day_manifest`
// row; nothing reads either to serve. `publishInTxn` is the same work for a
// caller that already owns a transaction (the post-commit shadow write, which
// puts rows and manifest in one).
//
// Closure rules (design 06 section 12.2), per selected (group, revision):
//  * the row exists;
//  * it was stamped from a pinned capture (not `"_unpinned":true`);
//  * its counter and its ancestors' counters equal the current registry's;
//  * its input stamp equals the stamp the current input revisions give for
//    the same inputs. That covers a stamped input that moved AND an input
//    scope the stamp never held: a bump after the capture is a pending
//    invalidation. A queued compute_jobs row is not (it names no day).
// Comparing canonical text keeps this free of payload reads and JSON decodes.

import 'dart:convert' show utf8;

import 'package:sqflite/sqflite.dart';

import '../../data/db/group_row_store.dart';
import '../../data/db/manifest_store.dart';
import 'group_registry.dart';
import 'manifest_codec.dart';
import 'slice_bundle.dart';

enum ClosureReason { unpinned, inputMoved, counterMoved, missingRevision }

class ClosureProblem {
  const ClosureProblem(this.group, this.reason);
  final String group;
  final ClosureReason reason;

  @override
  String toString() => '$group: ${reason.name}';
}

class ClosureVerdict {
  const ClosureVerdict(this.problems);
  final List<ClosureProblem> problems;
  bool get ok => problems.isEmpty;
}

/// Does every selected revision of [dayId] still match the current registry
/// counters and input revisions? Reads group_row metadata and the input
/// revisions only.
Future<ClosureVerdict> validateClosure(DatabaseExecutor db,
    {required String dayId, required Map<String, int> selected}) async {
  final reg = groupRegistryForTest ?? kMergedRegistry;
  final byId = {for (final g in reg.groups) g.id: g};
  final stored = {
    for (final r in await db.query('group_row',
        columns: ['group_id', 'revision', 'counter', 'ancestors_json', 'input_stamp_json'],
        where: 'day_id = ?',
        whereArgs: [dayId]))
      '${r['group_id']}#${r['revision']}': r,
  };
  final problems = <ClosureProblem>[];
  InputStamp? now;
  for (final id in selected.keys.toList()..sort()) {
    final row = stored['$id#${selected[id]}'];
    if (row == null) {
      problems.add(ClosureProblem(id, ClosureReason.missingRevision));
      continue;
    }
    final stampJson = row['input_stamp_json'] as String? ?? '';
    if (stampJson.contains('"_unpinned":true')) {
      problems.add(ClosureProblem(id, ClosureReason.unpinned));
      continue;
    }
    final g = byId[id];
    final ancestors = {
      for (final a in transitiveDeps(reg, id))
        if (byId[a] != null) a: byId[a]!.counter,
    };
    if (g == null ||
        (row['counter'] as num?)?.toInt() != g.counter ||
        row['ancestors_json'] != canonCounters(ancestors)) {
      problems.add(ClosureProblem(id, ClosureReason.counterMoved));
      continue;
    }
    now ??= await captureInputStamp(dayId, db: db);
    if (stampJson != canonStamp(stampWindow(now, closureInputs(reg, id), dayId))) {
      problems.add(ClosureProblem(id, ClosureReason.inputMoved));
    }
  }
  return ClosureVerdict(problems);
}

sealed class PublishResult {
  const PublishResult();
}

class Published extends PublishResult {
  const Published(this.seq);
  final int seq;
}

enum PublishRefusal { priorMoved, closure }

class PublishRefused extends PublishResult {
  const PublishRefused(this.reason, this.problems);
  final PublishRefusal reason;
  final List<ClosureProblem> problems;
}

class PublishFailed extends PublishResult {
  const PublishFailed(this.error);
  final Object error;
}

/// The publication work inside a transaction the caller owns. A refusal
/// changes nothing; a database error propagates (the caller's transaction
/// rolls back).
Future<PublishResult> publishInTxn(
  DatabaseExecutor txn, {
  required String dayId,
  required int? expectedPriorSeq,
  required Map<String, int> selected,
  required List<String> keyOrder,
  required String bundleSha,
  required String seriesSha,
  required Map<String, Object?> freshness,
  int? nowMs,
}) async {
  final prior = await latestManifestSeq(txn, dayId);
  if (prior != expectedPriorSeq) {
    return const PublishRefused(PublishRefusal.priorMoved, []);
  }
  final verdict = await validateClosure(txn, dayId: dayId, selected: selected);
  if (!verdict.ok) {
    return PublishRefused(PublishRefusal.closure, verdict.problems);
  }
  final seq = (prior ?? 0) + 1;
  await txn.insert(
      'day_manifest',
      manifestToRow(Manifest(
        dayId: dayId,
        manifestSeq: seq,
        compat: kManifestCompat,
        registryVersion:
            (groupRegistryForTest ?? kMergedRegistry).registryVersion,
        selected: selected,
        keyOrder: keyOrder,
        bundleSha: bundleSha,
        seriesSha: seriesSha,
        freshness: freshness,
        publishedAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      )));
  // Exactly the selected revisions are published: the previous publication's
  // marks go, so published = 1 always spells out the latest manifest.
  await txn.update('group_row', {'published': 0},
      where: 'day_id = ? AND published = 1', whereArgs: [dayId]);
  for (final e in selected.entries) {
    await txn.update('group_row', {'published': 1},
        where: 'day_id = ? AND group_id = ? AND revision = ?',
        whereArgs: [dayId, e.key, e.value]);
  }
  // Provisional revisions this publication superseded are scratch (a
  // provisional row is replaced, never kept); finished ones are history.
  // Without this every re-derive of a published day would leave a copy.
  for (final e in selected.entries) {
    await txn.delete('group_row',
        where: 'day_id = ? AND group_id = ? AND revision < ? '
            'AND published = 0 AND finalized = 0',
        whereArgs: [dayId, e.key, e.value]);
  }
  return Published(seq);
}

/// [publishInTxn] in a transaction of its own. NEVER throws: a database error
/// is a [PublishFailed] and its marks are rolled back with it.
Future<PublishResult> publish(
  Database db, {
  required String dayId,
  required int? expectedPriorSeq,
  required Map<String, int> selected,
  required List<String> keyOrder,
  required String bundleSha,
  required String seriesSha,
  required Map<String, Object?> freshness,
  int? nowMs,
}) async {
  try {
    return await db.transaction((txn) => publishInTxn(txn,
        dayId: dayId,
        expectedPriorSeq: expectedPriorSeq,
        selected: selected,
        keyOrder: keyOrder,
        bundleSha: bundleSha,
        seriesSha: seriesSha,
        freshness: freshness,
        nowMs: nowMs));
  } catch (e) {
    return PublishFailed(e);
  }
}

/// The bundle text a manifest names: its selected rows assembled in
/// `keyOrder`, each value its stored substring, so it equals the stored
/// `payload_json` the manifest was published for. Throws StateError when a
/// selected row is missing or the paths do not fit (a half set).
Future<String> assembleManifestPayload(DatabaseExecutor db, Manifest m) async {
  final payloads = <String>[];
  for (final e in m.selected.entries) {
    final rows = await db.query('group_row',
        columns: ['payload'],
        where: 'day_id = ? AND group_id = ? AND revision = ?',
        whereArgs: [m.dayId, e.key, e.value],
        limit: 1);
    if (rows.isEmpty) {
      throw StateError('manifest ${m.manifestSeq}: ${e.key} r${e.value} is gone');
    }
    payloads.add(utf8.decode(rows.single['payload'] as List<int>));
  }
  return assembleBundleJson(payloads, m.keyOrder);
}
