// sleep_import_rules.dart — what an import does with sleep assertions.
//
// Owner decision 2026-11-17 (S7): LOCAL WINS, with a report. For
// `sleep_override` rows match by `day_id`; for `sleep_nap` check the exact
// `(day_id, start_ts)` key AND overlapping local windows, tombstones included.
// A differing row never replaces the local row (whichever `created_at` is
// newer), an identical row skips silently, and only keys that are missing with
// no conflicting local window import. The frozen PRE-import local set is the
// only thing incoming rows are compared with, so a historical close pair that
// travels together in one source restores whole; pairs under 30 minutes are
// LISTED for review, never merged, never refused here (spec §5.5).
// CLAIM(sleep-editor-transport).

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'db.dart' show LocalDb;
import 'json_payload_lane.dart';
import 'sleep_editor.dart' show kMinSleepGapSec;

enum SleepImportVerdict { copy, skipIdentical, refuseConflict, refuseOverlap }

/// One line of the import report: a refused entry or a close pair to review.
class SleepImportEntry {
  const SleepImportEntry({
    required this.kind,
    required this.table,
    required this.day,
    required this.startTs,
    required this.endTs,
    this.other,
  });

  /// `refused-conflict`, `refused-overlap`, `close-in-source`, `close-with-local`.
  final String kind;
  final String table, day;
  final int startTs, endTs;

  /// The block it is close to (`<day>:<start>`), when there is one.
  final String? other;

  bool get refused => kind.startsWith('refused');

  Map<String, Object?> toJson() => {
        'kind': kind,
        'table': table,
        'day': day,
        'start': startTs,
        'end': endTs,
        if (other != null) 'other': other,
      };

  static SleepImportEntry? fromJson(Object? j) {
    if (j is! Map ||
        j['kind'] is! String ||
        j['table'] is! String ||
        j['day'] is! String ||
        j['start'] is! int ||
        j['end'] is! int) {
      return null;
    }
    return SleepImportEntry(
      kind: j['kind'] as String,
      table: j['table'] as String,
      day: j['day'] as String,
      startTs: j['start'] as int,
      endTs: j['end'] as int,
      other: j['other'] as String?,
    );
  }

  String get key => '$kind|$table|$day|$startTs|$endTs|${other ?? ''}';
}

/// The local sleep rows as they were BEFORE the import started copying.
class SleepImportPre {
  const SleepImportPre(this.naps, this.overrides);
  final List<Map<String, Object?>> naps, overrides;
}

typedef _Blk = ({String table, String day, int s, int e});

class SleepImportRules {
  const SleepImportRules._();

  static Future<SleepImportPre> freeze(DatabaseExecutor db) async =>
      SleepImportPre(await db.query('sleep_nap'), await db.query('sleep_override'));

  static bool _same(Map<String, Object?> row, Map<String, Object?> local) {
    for (final e in row.entries) {
      if (!local.containsKey(e.key)) continue;
      if (local[e.key] != e.value) return false;
    }
    return true;
  }

  static SleepImportVerdict judge(
      String table, Map<String, Object?> row, SleepImportPre pre) {
    if (table == 'sleep_override') {
      for (final l in pre.overrides) {
        if (l['day_id'] == row['day_id']) {
          return _same(row, l)
              ? SleepImportVerdict.skipIdentical
              : SleepImportVerdict.refuseConflict;
        }
      }
      return SleepImportVerdict.copy;
    }
    final s = row['start_ts'], e = row['end_ts'];
    for (final l in pre.naps) {
      if (l['day_id'] == row['day_id'] && l['start_ts'] == s) {
        return _same(row, l)
            ? SleepImportVerdict.skipIdentical
            : SleepImportVerdict.refuseConflict;
      }
    }
    if (s is int && e is int) {
      for (final l in pre.naps) {
        if ((l['start_ts'] as int) < e && (l['end_ts'] as int) > s) {
          return SleepImportVerdict.refuseOverlap;
        }
      }
    }
    return SleepImportVerdict.copy;
  }

  static SleepImportEntry refusal(
      String table, Map<String, Object?> row, SleepImportVerdict v) {
    final overrides = table == 'sleep_override';
    return SleepImportEntry(
      kind: v == SleepImportVerdict.refuseOverlap
          ? 'refused-overlap'
          : 'refused-conflict',
      table: table,
      day: '${row['day_id']}',
      startTs: (overrides ? row['onset_ts'] : row['start_ts']) as int? ?? 0,
      endTs: (overrides ? row['offset_ts'] : row['end_ts']) as int? ?? 0,
    );
  }

  static int _gap(int s1, int e1, int s2, int e2) =>
      (s1 > s2 ? s1 : s2) - (e1 < e2 ? e1 : e2);

  /// Close pairs worth a second look: inside the source, and between a source
  /// block that was imported and a block this install already had.
  static List<SleepImportEntry> closePairs({
    required List<Map<String, Object?>> srcNaps,
    required List<Map<String, Object?>> srcOverrides,
    required SleepImportPre pre,
    required Set<String> refused,
  }) {
    List<_Blk> blocks(List<Map<String, Object?>> naps,
            List<Map<String, Object?>> overs) =>
        [
          for (final n in naps)
            if (n['source'] != 'rejected')
              (
                table: 'sleep_nap',
                day: '${n['day_id']}',
                s: n['start_ts'] as int,
                e: n['end_ts'] as int,
              ),
          for (final o in overs)
            if (o['source'] != 'rejected')
              (
                table: 'sleep_override',
                day: '${o['day_id']}',
                s: o['onset_ts'] as int,
                e: o['offset_ts'] as int,
              ),
        ];
    final src = blocks(srcNaps, srcOverrides);
    final local = blocks(pre.naps, pre.overrides);
    String id(_Blk b) => '${b.table}|${b.day}|${b.s}';
    final out = <SleepImportEntry>[];
    for (var i = 0; i < src.length; i++) {
      for (var j = i + 1; j < src.length; j++) {
        if (_gap(src[i].s, src[i].e, src[j].s, src[j].e) < kMinSleepGapSec) {
          out.add(SleepImportEntry(
              kind: 'close-in-source',
              table: src[j].table,
              day: src[j].day,
              startTs: src[j].s,
              endTs: src[j].e,
              other: '${src[i].day}:${src[i].s}'));
        }
      }
      if (refused.contains(id(src[i]))) continue;
      for (final l in local) {
        if (l.table == src[i].table && l.day == src[i].day && l.s == src[i].s) {
          continue; // the same row, not a neighbour
        }
        final g = _gap(src[i].s, src[i].e, l.s, l.e);
        if (g >= 0 && g < kMinSleepGapSec) {
          out.add(SleepImportEntry(
              kind: 'close-with-local',
              table: src[i].table,
              day: src[i].day,
              startTs: src[i].s,
              endTs: src[i].e,
              other: '${l.day}:${l.s}'));
        }
      }
    }
    return out;
  }

  static String refusedId(SleepImportEntry e) => '${e.table}|${e.day}|${e.startTs}';
}

/// The report, kept beside the import summary (`compute_freshness`) so it
/// outlives the import screen.
class SleepImportReport {
  const SleepImportReport._();

  static const String key = 'import_sleep_report_v1';

  static Future<void> save(List<SleepImportEntry> entries,
      {bool unionWithStored = false}) async {
    final all = <String, SleepImportEntry>{};
    if (unionWithStored) {
      for (final e in await load()) {
        all[e.key] = e;
      }
    }
    for (final e in entries) {
      all[e.key] = e;
    }
    await LocalDb.putComputeFreshness(
        key, jsonEncode([for (final e in all.values) e.toJson()]));
  }

  static Future<List<SleepImportEntry>> load() async {
    final row = await LocalDb.computeFreshness(key);
    if (row == null) return const [];
    try {
      final raw = await JsonPayloadLane.shared.decodeUncached('${row['payload_json']}');
      if (raw is! List) return const [];
      return [
        for (final j in raw)
          if (SleepImportEntry.fromJson(j) case final e?) e,
      ];
    } catch (_) {
      return const [];
    }
  }
}
