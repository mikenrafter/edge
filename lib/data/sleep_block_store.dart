// Owner: SleepBlockStore owns sleep assertions and their legacy projections.
// Callers supply the executor and transaction. Storage errors propagate, so a
// failed write never leaves a half-written projection. Commands land in slice B.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import '../compute/nap_edits.dart';
import 'db.dart';
import 'db/input_read_tracker.dart';
import 'day_label.dart';
import 'json_payload_lane.dart';
import 'sleep_draft_fence.dart';
import 'sleep_editor.dart';
import 'sleep_import_rules.dart';
import 'sleep_ownership.dart';

enum AbsorbMode { backfill, importFile }
enum SleepBlockState { live, removed, merged }
enum SleepBlockSource { manual, confirmed, legacy, detected }

class _StoredBlock {
  _StoredBlock(this.row) {
    final kind = SleepBlockKind.values.where((v) => v.name == row['kind']).firstOrNull;
    final source = SleepBlockSource.values.where((v) => v.name == row['source']).firstOrNull;
    final rawState = SleepBlockState.values.where((v) => v.name == row['state']).firstOrNull;
    state = kind == null || source == null || rawState == null
        ? SleepBlockState.removed : rawState;
    block = SleepBlock(
      id: row['id'] as String, kind: kind ?? SleepBlockKind.nap,
      day: row['owner_day'] as String, ownerRule: row['owner_rule'] as int, startTs: row['start_ts'] as int,
      endTs: row['end_ts'] as int, revision: row['revision'] as int,
      provenance: switch (source) {
        SleepBlockSource.manual => SleepEntryProvenance.manual,
        SleepBlockSource.confirmed => SleepEntryProvenance.confirmed,
        SleepBlockSource.legacy => SleepEntryProvenance.legacy,
        _ => SleepEntryProvenance.automatic,
      },
    );
    final a = row['detected_start'], b = row['detected_end'], day = row['detected_day'];
    history = kind == null || source == null || rawState == null
        ? const DetectedUnavailable('unknown stored block shape')
        : switch (row['history']) {
      'absent' => const DetectedAbsent(),
      'known' when a is int && b is int && b > a && day is String =>
        DetectedKnown(startTs: a, endTs: b, sourceDay: day),
      _ => const DetectedUnavailable('stored history unavailable'),
    };
  }
  final Map<String, Object?> row;
  late final SleepBlock block;
  late final SleepBlockState state;
  late final DetectedHistory history;
}

abstract final class SleepBlockStore {
  /// Shared row codec for absorption and new assertions. Callers choose the
  /// owner day through SleepOwnership; an existing block retains its rule.
  /// CLAIM(sleep-block-owner-rule): new assertions use rule 1; absorption
  /// preserves legacy rule 0 [owner decision 2026-11-18; B17].
  static Map<String, Object?> encodeBlock(SleepBlock block, {
    required SleepBlockSource source,
    required SleepBlockState state,
    required int createdAt,
    int? updatedAt,
    DetectedHistory history = const DetectedUnavailable('no retained detection'),
    String? mergedInto,
    String? payload,
  }) {
    if (block.id == null) throw ArgumentError('a stored block needs an id');
    return {
      'id': block.id, 'kind': block.kind.name, 'owner_day': block.day,
      'owner_rule': block.ownerRule ?? SleepOwnership.currentRule,
      'start_ts': block.startTs, 'end_ts': block.endTs,
      'source': source.name, 'state': state.name, 'merged_into': mergedInto,
      'history': switch (history) {
        DetectedKnown() => 'known', DetectedAbsent() => 'absent',
        DetectedUnavailable() => 'unavailable',
      },
      'detected_start': history is DetectedKnown ? history.startTs : null,
      'detected_end': history is DetectedKnown ? history.endTs : null,
      'detected_day': history is DetectedKnown ? history.sourceDay : null,
      'payload_json': payload, 'revision': block.revision,
      'created_at': createdAt, 'updated_at': updatedAt ?? createdAt,
    };
  }

  static Future<Map<String, dynamic>?> _payload(Object? value) async {
    if (value is! String || value.trim().isEmpty) return null;
    try {
      final decoded = await JsonPayloadLane.shared.decodeUncached(value);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// Absorbs release/upstream shapes only. It never interprets pilot envelopes.
  /// Backfill writes blocks, plus missing pre-review legacy-nap projections;
  /// it never enqueues or rewrites existing projections [spec §2.2; B5/B6/B15].
  static Future<List<SleepImportEntry>> absorb(DatabaseExecutor tx, {
    required List<Map<String, Object?>> overrides,
    required List<Map<String, Object?>> naps,
    Iterable<Map<String, Object?>> servedDayResults = const [],
    List<Map<String, Object?>> blocks = const [],
    required AbsorbMode mode,
  }) async {
    if (mode != AbsorbMode.backfill) {
      throw UnsupportedError('Import absorption requires the slice-C transport stage');
    }
    final report = <SleepImportEntry>[];
    void note(String kind, String table, String day, int start, int end) {
      report.add(SleepImportEntry(kind: kind, table: table, day: day,
        startTs: start, endTs: end));
    }
    Map<String, Object?> row(String id, String kind, String day, int start,
        int end, String source, String state, int created, {
        String history = 'unavailable', int? detectedStart, int? detectedEnd,
        String? payload}) => encodeBlock(SleepBlock(id: id,
          kind: SleepBlockKind.values.byName(kind), day: day,
          ownerRule: SleepOwnership.legacyRule, startTs: start, endTs: end),
        source: SleepBlockSource.values.byName(source),
        state: SleepBlockState.values.byName(state), createdAt: created,
        history: history == 'known'
          ? DetectedKnown(startTs: detectedStart!, endTs: detectedEnd!, sourceDay: day)
          : const DetectedUnavailable('legacy detection unavailable'),
        payload: payload);
    Future<bool> insertBlock(Map<String, Object?> block) async {
      if ((await tx.query('sleep_block', columns: ['id'], where: 'id = ?',
          whereArgs: [block['id']])).isNotEmpty) {
        return false;
      }
      // An explicit pre-check reports uniqueness refusal; OR IGNORE would hide it.
      if (block['kind'] == 'main' && block['state'] == 'live' &&
          (await tx.query('sleep_block', columns: ['id'],
            where: "kind = 'main' AND state = 'live' AND owner_day = ?",
            whereArgs: [block['owner_day']])).isNotEmpty) {
        note('refused', 'sleep_block', block['owner_day'] as String,
          block['start_ts'] as int, block['end_ts'] as int);
        return false;
      }
      await tx.insert('sleep_block', block);
      return true;
    }
    for (final legacy in overrides) {
      final day = legacy['day_id'] as String, start = legacy['onset_ts'] as int;
      final end = legacy['offset_ts'] as int, source = legacy['source'];
      final known = source == 'manual' || source == 'confirmed';
      if (!known && source != 'rejected') note('unknown_source', 'sleep_override', day, start, end);
      if (source == 'rejected' && end - start == 1) note('placeholder_bounds', 'sleep_override', day, start, end);
      await insertBlock(row('legacy:main:$day', 'main', day, start, end,
        known ? source as String : 'detected', known ? 'live' : 'removed', legacy['created_at'] as int));
    }
    for (final legacy in naps) {
      final day = legacy['day_id'] as String, start = legacy['start_ts'] as int;
      final end = legacy['end_ts'] as int, source = legacy['source'];
      final raw = legacy['payload_json'] as String?;
      final payload = await _payload(raw);
      if (raw != null && raw.trim().isNotEmpty && payload == null) note('malformed_payload', 'sleep_nap', day, start, end);
      final a = payload?['start'], b = payload?['end'];
      final snapshot = a is num && b is num && b > a;
      final knownSource = const {'manual', 'confirmed', 'legacy', 'rejected'}.contains(source);
      if (!knownSource) note('unknown_source', 'sleep_nap', day, start, end);
      final known = source == 'legacy' || (source == 'confirmed' || source == 'rejected') && snapshot;
      await insertBlock(row('legacy:nap:$day:$start', 'nap', day, start, end,
        knownSource && source != 'rejected' ? source as String : 'detected',
        knownSource && source != 'rejected' ? 'live' : 'removed', legacy['created_at'] as int,
        history: known ? 'known' : 'unavailable',
        detectedStart: known ? source == 'legacy' ? start : (a as num).toInt() : null,
        detectedEnd: known ? source == 'legacy' ? end : (b as num).toInt() : null,
        payload: raw));
    }
    final meta = await tx.query('activity_review_meta', columns: ['activated_at']);
    final cutoff = meta.firstOrNull?['activated_at'];
    if (cutoff is! int) return report;
    for (final served in servedDayResults) {
      final day = served['day_id'] as String;
      Object? values;
      try { values = await JsonPayloadLane.shared.decodeUncached(served['naps_json']); }
      catch (_) { continue; }
      if (values is! List) continue;
      for (final nap in values.whereType<Map>()) {
        final a = nap['start'], b = nap['end'];
        if (a is! num || b is! num || b <= a || a >= cutoff ||
            nap['source'] == 'manual' || nap['source'] == 'confirmed') {
          continue;
        }
        final start = a.toInt(), end = b.toInt();
        if ((await tx.query('sleep_block', columns: ['id'],
            where: 'start_ts < ? AND end_ts > ?', whereArgs: [end, start])).isNotEmpty) {
          continue;
        }
        final payload = await JsonPayloadLane.shared.encode({...nap, 'source': 'legacy'});
        if (payload == null) throw StateError('legacy nap payload could not be encoded');
        if (await insertBlock(row('legacy:nap:$day:$start', 'nap', day, start, end,
            'legacy', 'live', cutoff, history: 'known', detectedStart: start,
            detectedEnd: end, payload: payload))) {
          // The sole projection write in backfill. Existing source rows are kept.
          await tx.rawInsert('INSERT INTO sleep_nap(day_id,start_ts,end_ts,source,created_at,payload_json) '
            "SELECT ?,?,?,'legacy',?,? WHERE NOT EXISTS (SELECT 1 FROM sleep_nap WHERE day_id = ? AND start_ts = ?)",
            [day, start, end, cutoff, payload, day, start]);
        }
      }
    }
    return report;
  }

  /// The SQL projection reads only naps.value, never the whole day bundle.
  static Future<void> backfill(DatabaseExecutor tx) async {
    await absorb(tx, overrides: await tx.query('sleep_override'),
      naps: await tx.query('sleep_nap'), mode: AbsorbMode.backfill,
      servedDayResults: await tx.rawQuery('''SELECT r.day_id,
        CASE WHEN json_valid(r.payload_json) THEN json_extract(r.payload_json, '\$.naps.value') END AS naps_json
        FROM day_result r ${LocalDb.servedDayJoinSql} WHERE r.skipped = 0'''));
  }

  /// Both stored window shapes, through the screens' served-version rule.
  static Future<List<Map<String, Object?>>> detectedMainWindows(
      DatabaseExecutor tx, String first, String last) => tx.rawQuery('''SELECT r.day_id AS day_id,
      CASE WHEN json_valid(r.window_json) THEN COALESCE(
        json_extract(r.window_json, '\$.value.onset_ms'), json_extract(r.window_json, '\$.onset_ms')) END AS on_ms,
      CASE WHEN json_valid(r.window_json) THEN COALESCE(
        json_extract(r.window_json, '\$.value.offset_ms'), json_extract(r.window_json, '\$.offset_ms')) END AS off_ms
      FROM day_result r ${LocalDb.servedDayJoinSql}
      WHERE r.skipped = 0 AND r.day_id BETWEEN ? AND ?''', [first, last]);

  // CLAIM(sleep-block-live-read): a main assertion in ANY state replaces the
  // automatic window [spec §3.3; sleep_block_store_test S1-S7].
  static Future<List<SleepBlock>> live(DatabaseExecutor tx, int fromSec, int toSec) async {
    if (toSec < fromSec) return [];
    final stored = (await tx.query('sleep_block', where:
      "state = 'live' AND start_ts <= ? AND end_ts >= ?", whereArgs: [toSec, fromSec]))
        .map(_StoredBlock.new);
    final out = [for (final r in stored) if (r.state == SleepBlockState.live) r.block];
    final days = SleepOwnership.daysOf(fromSec, toSec).toList();
    final first = dayLabelBefore(days.first, 1)!, last = dayLabelBefore(days.last, -1)!;
    final asserted = {for (final r in await tx.query('sleep_block', columns: ['owner_day'],
      where: "kind = 'main' AND owner_day BETWEEN ? AND ?", whereArgs: [first,last])) r['owner_day']};
    for (final r in await detectedMainWindows(tx, first, last)) {
      if (asserted.contains(r['day_id'])) continue;
      final on = r['on_ms'], off = r['off_ms'];
      if (on is! num || off is! num || off <= on) continue;
      final start = on.toInt() ~/ 1000, end = off.toInt() ~/ 1000;
      if (start > toSec || end < fromSec) continue;
      out.add(SleepBlock(kind: SleepBlockKind.main, day: r['day_id'] as String,
        startTs: start, endTs: end));
    }
    out.sort((a,b) => a.startTs != b.startTs ? a.startTs.compareTo(b.startTs) : (a.id ?? '').compareTo(b.id ?? ''));
    return out;
  }

  static Future<SleepEditorRead> read(DatabaseExecutor tx, String day) async {
    final rows = (await tx.query('sleep_block', where: 'owner_day = ?',
      whereArgs: [day], orderBy: 'start_ts, id')).map(_StoredBlock.new).toList();
    final entries = <SleepEditorEntry>[];
    for (final r in rows) {
      final b = r.block;
      final survivor = r.row['merged_into'];
      final attached = survivor is String && survivor.isNotEmpty &&
        (await tx.query('sleep_block', columns: ['id'], where: 'id = ?', whereArgs: [survivor])).isNotEmpty;
      entries.add(SleepEditorEntry(id: b.id, revision: b.revision, ownerRule: b.ownerRule,
        mergedInto: attached ? survivor : null,
        ref: SleepEntryRef(kind: b.kind, day: day, startTs: b.kind == SleepBlockKind.nap ? b.startTs : null,
          expectedEndTs: b.endTs, expectedSource: r.row['source'] as String),
        startTs: b.startTs, endTs: b.endTs, provenance: b.provenance,
        history: r.history, removed: r.state != SleepBlockState.live));
    }
    if (!rows.any((r) => r.block.kind == SleepBlockKind.main)) {
      for (final r in await detectedMainWindows(tx, day, day)) {
        final on = r['on_ms'], off = r['off_ms'];
        if (on is! num || off is! num || off <= on) continue;
        final start = on.toInt() ~/ 1000, end = off.toInt() ~/ 1000;
        entries.add(SleepEditorEntry(ref: SleepEntryRef(kind: SleepBlockKind.main, day: day,
          expectedEndTs: end, expectedSource: 'automatic'), startTs: start, endTs: end,
          provenance: SleepEntryProvenance.automatic,
          history: DetectedKnown(startTs: start,endTs: end,sourceDay: day),removed: false));
      }
    }
    entries.sort((a,b) => a.startTs.compareTo(b.startTs));
    final main = entries.where((e) => e.ref.kind == SleepBlockKind.main).firstOrNull;
    final span = SleepOwnership.framingSpan(day,main: main == null ? null : (start:main.startTs,end:main.endTs),
      entries:[for (final e in entries) (start:e.startTs,end:e.endTs)]);
    final jobs = await tx.query('sleep_edit_job', columns:['revision'],where:'day_id = ?',whereArgs:[day]);
    return SleepEditorRead(dayId: day, entries: entries,
      revision: jobs.firstOrNull?['revision'] as int?, draftGeneration: SleepDraftFence.shared.generationOf(day),
      neighbors: [for (final b in await live(tx,span.start,span.end)) if (b.day != day) b]);
  }

  static Future<List<NapEdit>> napEdits(DatabaseExecutor tx, String day) async {
    InputReads.note('sleep_nap', day);
    final rows = await tx.query('sleep_block',where: "kind = 'nap' AND (owner_day = ? OR history = 'known' AND detected_day = ? AND owner_day <> ?)",
      whereArgs:[day,day,day],orderBy:'start_ts, id');
    final out = <NapEdit>[];
    for (final row in rows) {
      final r = _StoredBlock(row), b = r.block;
      if (b.day == day) {
        out.add(NapEdit(kind: r.state == SleepBlockState.live ? NapEditKind.added : NapEditKind.rejected,
          startSec:b.startTs,endSec:b.endTs,snapshot:await _payload(row['payload_json'])));
      } else if (r.history case DetectedKnown(:final startTs,:final endTs)) {
        out.add(NapEdit(kind:NapEditKind.rejected,startSec:startTs,endSec:endTs));
      }
    }
    return out;
  }

  // CLAIM(sleep-block-projection): stable total order handles the one lossy
  // natural-key collision [spec §1.3; B5/S9/S10]. Payload bytes are copied.
  static Future<void> _project(DatabaseExecutor tx, Set<String> ownerDays) async {
    const priority = {'live':0,'removed':1,'merged':2};
    for (final day in ownerDays) {
      final rows = List<Map<String, Object?>>.of(await tx.query(
        'sleep_block', where: 'owner_day = ?', whereArgs: [day]));
      rows.sort((a,b) {
        final state = (priority[a['state']] ?? 1).compareTo(priority[b['state']] ?? 1);
        if (state != 0) return state;
        final updated = (b['updated_at'] as int).compareTo(a['updated_at'] as int);
        return updated != 0 ? updated : (a['id'] as String).compareTo(b['id'] as String);
      });
      await tx.delete('sleep_nap',where:'day_id = ?',whereArgs:[day]);
      await tx.delete('sleep_override',where:'day_id = ?',whereArgs:[day]);
      final naps = <int>{};
      var main = false;
      for (final row in rows) {
        final r = _StoredBlock(row), b = r.block;
        final source = r.state != SleepBlockState.live ? 'rejected'
            : row['source'] == 'detected' ? 'confirmed' : row['source'];
        if (b.kind == SleepBlockKind.nap && naps.add(b.startTs)) {
          await tx.insert('sleep_nap',{'day_id':day,'start_ts':b.startTs,'end_ts':b.endTs,
            'source':source,'created_at':row['created_at'],'payload_json':row['payload_json']});
        } else if (b.kind == SleepBlockKind.main && !main) {
          main = true;
          await tx.insert('sleep_override',{'day_id':day,'onset_ts':b.startTs,'offset_ts':b.endTs,
            'source':source,'created_at':row['created_at'],'payload_json':null});
        }
      }
    }
  }

  @visibleForTesting
  static Future<void> projectForTest(DatabaseExecutor tx, Set<String> ownerDays) => _project(tx,ownerDays);
}
