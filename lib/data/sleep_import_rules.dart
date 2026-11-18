// Owner: SleepBlockStore decides import rows; this module owns only the
// durable report codec and storage. CLAIM(sleep-editor-transport), spec §2.2.
import 'dart:convert';

import 'db.dart' show LocalDb;
import 'json_payload_lane.dart';

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

  /// Absorb diagnostics: refused, imported, close pairs, and legacy-shape warnings.
  final String kind;
  final String table, day;
  final int startTs, endTs;

  /// Conflicting block/reason or close neighbor identity, when present.
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
