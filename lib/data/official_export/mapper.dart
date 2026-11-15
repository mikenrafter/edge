// SQL orchestration only. Native SQLite performs I/O; hashes, archive decoding
// and crypto run in registered workers. This module never opens a live LocalDb.
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import '../../util/worker_init.dart';
import 'profile.dart';
import 'worker.dart';
import '../json_payload_lane.dart';

const exportWorkerInputs = WorkerInputs(
  nowEpochMs: 0,
  zoneId: 'UTC',
  localeTag: 'en',
);
String quoteSql(String name) => '"${name.replaceAll('"', '""')}"';

Future<String> exportFileHash(String path) =>
    Isolate.run(() => officialFileHashHeavy(exportWorkerInputs, path));

// Keyset pages keep scans bounded as history grows. The snapshot is immutable.
// CLAIM(export-linear-pages): indexed pages avoid OFFSET rescans for supported
// tables [paging_test; pilot timings]. A foreign table shadowing all three
// SQLite rowid aliases uses the compatibility fallback to preserve duplicates.
class _ExportPages {
  _ExportPages(
    this.db,
    this.table,
    this.order,
    this.rowId,
    this.cursorColumn,
    this.fallback,
  );
  final Database db;
  final String table;
  final List<String> order;
  final String? rowId;
  final String cursorColumn;
  final bool fallback;
  List<Object?>? _last;
  int _read = 0;

  static Future<_ExportPages> open(Database db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info(${quoteSql(table)})');
    final keys = [...info.where((c) => (c['pk'] as int) > 0)]
      ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
    final sql =
        (await db.rawQuery('SELECT sql FROM sqlite_master WHERE name=?', [
              table,
            ])).single['sql']
            as String;
    final withoutRowId = RegExp(
      r'WITHOUT\s+ROWID',
      caseSensitive: false,
    ).hasMatch(sql);
    final columns = {for (final c in info) c['name'] as String};
    final lowerColumns = {for (final c in columns) c.toLowerCase()};
    final aliases = [
      'rowid',
      '_rowid_',
      'oid',
    ].where((c) => !lowerColumns.contains(c)).toList();
    final rowId = withoutRowId || aliases.isEmpty ? null : aliases.first;
    var cursorColumn = '__export_cursor';
    while (lowerColumns.contains(cursorColumn)) {
      cursorColumn += '_';
    }
    return _ExportPages(
      db,
      table,
      [
        for (final c in keys) c['name'] as String,
        // Heap tables have no indexed logical key. Their stable snapshot rowid
        // avoids repeatedly sorting every column, and distinguishes duplicates.
        ?rowId,
        if (rowId == null && !withoutRowId) ...columns,
      ],
      rowId,
      cursorColumn,
      !withoutRowId && rowId == null,
    );
  }

  Future<List<Map<String, Object?>>> next({int limit = 1024}) async {
    final last = _last;
    final args = <Object?>[];
    String? where;
    if (last != null && !fallback) {
      if (last.every((v) => v != null)) {
        where = order.length == 1
            ? '${quoteSql(order.single)} > ?'
            : '(${order.map(quoteSql).join(',')}) > (${List.filled(order.length, '?').join(',')})';
        args.addAll(last);
      } else {
        // SQLite tuples containing NULL compare as unknown. Spell out the
        // NULL-first lexicographic successor only for that uncommon boundary.
        final alternatives = <String>[];
        for (var i = 0; i < order.length; i++) {
          final terms = <String>[];
          for (var j = 0; j < i; j++) {
            terms.add('${quoteSql(order[j])} IS ?');
            args.add(last[j]);
          }
          terms.add(
            last[i] == null
                ? '${quoteSql(order[i])} IS NOT NULL'
                : '${quoteSql(order[i])} > ?',
          );
          if (last[i] != null) args.add(last[i]);
          alternatives.add('(${terms.join(' AND ')})');
        }
        where = alternatives.join(' OR ');
      }
    }
    final page = await db.rawQuery(
      'SELECT *${rowId == null ? '' : ', ${quoteSql(rowId!)} AS ${quoteSql(cursorColumn)}'} '
      'FROM ${quoteSql(table)} ${where == null ? '' : 'WHERE $where'} '
      'ORDER BY ${order.map(quoteSql).join(',')} LIMIT $limit ${fallback ? 'OFFSET $_read' : ''}',
      args,
    );
    if (page.isEmpty) return [];
    _read += page.length;
    _last = [
      for (final c in order)
        c == rowId ? page.last[cursorColumn] : page.last[c],
    ];
    return [
      for (final row in page)
        {
          for (final e in row.entries)
            if (e.key != cursorColumn) e.key: e.value,
        },
    ];
  }
}

Future<Map<String, Object?>> inventoryDatabase(
  Database db, {
  OfficialExportCancellation? cancellation,
}) async {
  final out = <String, Object?>{};
  for (final entry in await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*' AND name!='fork_transition_manifest' ORDER BY name",
  )) {
    cancellation?.check();
    final table = entry['name'] as String;
    final info = await db.rawQuery('PRAGMA table_info(${quoteSql(table)})');
    final columns = [for (final c in info) c['name'] as String];
    final pages = await _ExportPages.open(db, table);
    var digest = OfficialProfile.hash(jsonEncode([table, columns]));
    var count = 0;
    while (true) {
      cancellation?.check();
      final page = await pages.next();
      if (page.isEmpty) break;
      final previous = digest;
      final input = OfficialRows(page);
      digest = await Isolate.run(
        () =>
            hashOfficialRowsHeavy(exportWorkerInputs, input, columns, previous),
      );
      count += page.length;
    }
    out[table] = {'rows': count, 'sha256': digest, 'columns': columns};
  }
  return out;
}

Future<void> verifyDatabaseInventory(
  String path,
  Map<String, Object?> expected,
) async {
  final db = await openDatabase(path, readOnly: true, singleInstance: false);
  try {
    if ((await db.rawQuery('PRAGMA integrity_check')).single.values.single !=
        'ok') {
      throw const FormatException('Export database integrity check failed');
    }
    final actual = await inventoryDatabase(db);
    if (jsonEncode(actual) != jsonEncode(expected)) {
      throw const FormatException('Export table counts or checksums changed');
    }
  } finally {
    await db.close();
  }
}

Future<OfficialExportReport> mapOfficialSnapshot(
  String sourcePath,
  String destinationPath,
  String profileText, {
  OfficialExportCancellation? cancellation,
  OfficialExportProgress? progress,
}) async {
  if (await File(destinationPath).exists()) {
    throw const FileSystemException(
      'Official export destination already exists',
    );
  }
  final profile = OfficialProfile.parse(profileText);
  final before = await exportFileHash(sourcePath);
  final source = await openDatabase(
    sourcePath,
    readOnly: true,
    singleInstance: false,
  );
  Database? target;
  final skipped = <ExportSkip>[];
  late final Map<String, Object?> sourceInventory;
  final targetTables = (profile.target['tables'] as Map)
      .cast<String, dynamic>();
  final exportedSessions = <String>{};
  final confirmedNaps = <String>{};
  List<List<int>>? deletionWindows = [];
  var unsafeDeletionPolicy = false;
  final days = <String, String>{};
  try {
    sourceInventory = await inventoryDatabase(
      source,
      cancellation: cancellation,
    );
    cancellation?.check();
    target = await openDatabase(destinationPath, singleInstance: false);
    final out = target;
    // The snapshot is never reopened as a lower-version live database.
    for (final object in profile.target['objects'] as List) {
      if (object['type'] == 'table') await out.execute(object['sql'] as String);
    }
    await out.setVersion(58);
    if (sourceInventory.containsKey('compute_freshness')) {
      for (final row in await source.query('compute_freshness')) {
        final key = row['key'] as String;
        if (key == 'redrive_excluded_windows') {
          final text = row['payload_json'];
          if (text is String) {
            final String payload = text;
            deletionWindows = await Isolate.run(
              () => decodeOfficialWindowsHeavy(exportWorkerInputs, payload),
            );
          } else {
            deletionWindows = null;
          }
          if (deletionWindows == null) unsafeDeletionPolicy = true;
        } else if (!profile.sourceColumns('compute_freshness').contains(key) &&
            RegExp(
              'delet|exclud|retention|prun',
              caseSensitive: false,
            ).hasMatch(key) &&
            !{
              'substrate_archive_policy',
              'substrate_archive_retention_days',
              'decoded_pruned_before',
            }.contains(key)) {
          unsafeDeletionPolicy = true;
          skipped.add(
            ExportSkip(
              'compute_freshness',
              1,
              'Unrecognized deletion/retention policy; measured inputs withheld',
              identity: key,
            ),
          );
        }
      }
    }
    if (unsafeDeletionPolicy) deletionWindows = null;
    if (sourceInventory.containsKey('activity_suggestions')) {
      for (final row in await source.query(
        'activity_suggestions',
        columns: ['linked_id'],
        where: "kind='nap' AND status='confirmed'",
      )) {
        if (row['linked_id'] case final String id) confirmedNaps.add(id);
      }
    }
    final tableOrder = [
      ...profile.policies.keys.where(
        (t) =>
            t != 'substrate_archive' &&
            !{'session_sensor', 'workout_route', 'workout_split'}.contains(t),
      ),
      'session_sensor',
      'workout_route',
      'workout_split',
    ];
    for (final table in {...tableOrder, ...sourceInventory.keys}) {
      cancellation?.check();
      final inv = sourceInventory[table] as Map?;
      if (inv == null) continue;
      final count = inv['rows'] as int;
      if (table == 'substrate_archive') continue;
      final policy = profile.policies[table];
      if (policy != 'keep' || !targetTables.containsKey(table)) {
        {
          skipped.add(
            ExportSkip(
              table,
              count,
              policy == 'empty'
                  ? 'Fork computed or operational state is cleared'
                  : policy == null
                  ? 'Unreviewed source table; official release has no safe mapping'
                  : 'Official importer does not support this table',
            ),
          );
        }
        continue;
      }
      final info = (targetTables[table] as List).cast<Map>();
      final columns = {for (final c in info) c['name'] as String};
      final sourceColumns = (inv['columns'] as List).cast<String>().toSet();
      final omitted = sourceColumns.difference(columns).toList()..sort();
      if (omitted.isNotEmpty) {
        skipped.add(
          ExportSkip(
            table,
            count,
            'Columns are unsupported by official $officialTargetTag',
            columns: omitted,
          ),
        );
      }
      final unknown = sourceColumns.difference(profile.sourceColumns(table));
      if (unknown.isNotEmpty) {
        skipped.add(
          ExportSkip(
            table,
            count,
            'Unreviewed source columns retained only in recovery',
            columns: unknown.toList(),
          ),
        );
      }
      final pages = await _ExportPages.open(source, table);
      var offset = 0;
      while (true) {
        cancellation?.check();
        progress?.update('Mapping $table', offset);
        final rows = await pages.next();
        if (rows.isEmpty) break;
        offset += rows.length;
        final activityTexts = table == 'activity_suggestions'
            ? [
                for (final row in rows)
                  row['details_json'] is String
                      ? row['details_json'] as String
                      : '',
              ]
            : <String>[];
        final activityDetails = activityTexts.isEmpty
            ? null
            : await Isolate.run(
                () => sanitizeOfficialActivitiesHeavy(
                  exportWorkerInputs,
                  activityTexts,
                ),
              );
        await out.transaction((txn) async {
          final batch = txn.batch();
          final pending = <({Map<String, Object?> row, String identity})>[];
          var rowIndex = -1;
          for (final original in rows) {
            rowIndex++;
            final row = <String, Object?>{
              for (final c in columns)
                if (original.containsKey(c) && !unknown.contains(c))
                  c: original[c],
            };
            final identity = officialRowIdentity(original, [
              for (final c in info.where((c) => (c['pk'] as int) > 0))
                c['name'] as String,
            ]);
            void skip(String reason) {
              skipped.add(ExportSkip(table, 1, reason, identity: identity));
            }

            if (table == 'device' &&
                row['adapter_id'] != null &&
                !(profile.enums['device_family'] as List).contains(
                  row['adapter_id'],
                )) {
              skip('Unsupported device adapter: ${row['adapter_id']}');
              continue;
            }
            if ({'signal_priority', 'device_coverage'}.contains(table) &&
                !(profile.enums['signal'] as List).contains(row['signal'])) {
              skip('Unsupported source signal: ${row['signal']}');
              continue;
            }
            final family = row['device_family'];
            if (family != null &&
                !(profile.enums['device_family'] as List).contains(family)) {
              skip('Unsupported device family: $family');
              continue;
            }
            if (_measuredTables.contains(table)) {
              if (deletionWindows == null) {
                skip('Deletion windows cannot be read safely');
                continue;
              }
              final instant =
                  original['rec_ts'] ??
                  original['ts'] ??
                  original['start_ts'] ??
                  (original['ts_ms'] is num
                      ? (original['ts_ms'] as num) / 1000
                      : null);
              final intervalEnd = original['end_ts'];
              if (deletionWindows.isNotEmpty &&
                  (instant is! num ||
                      deletionWindows.any(
                        (w) => intervalEnd is num
                            ? instant < w[1] && intervalEnd > w[0]
                            : instant >= w[0] && instant < w[1],
                      ))) {
                skip(
                  'Excluded by source deletion policy, or timestamp unavailable for safe filtering',
                );
                continue;
              }
            }
            if (table == 'ecg_reading') {
              if (!(profile.enums['ecg_wrist'] as List).contains(
                    row['wrist'],
                  ) ||
                  !(profile.enums['ecg_category'] as List).contains(
                    row['category'],
                  ) ||
                  !(profile.enums['ecg_status'] as List).contains(
                    row['status'],
                  )) {
                skip(
                  'ECG reading uses a wrist, category or status unsupported by the official model',
                );
                continue;
              }
            }
            if (table == 'sessions') {
              if (row['status'] != 'done' ||
                  row['end_ts'] is! num ||
                  original['end_ts_fabricated'] == 1 ||
                  (row['end_ts'] as num) <= (row['start_ts'] as num)) {
                skip('Session is live or has no verified actual end');
                continue;
              }
              final cleared = _sessionScores
                  .where((c) => row[c] != null)
                  .toList();
              for (final c in _sessionScores) {
                if (row.containsKey(c)) row[c] = null;
              }
              // A source label cannot prove whether these two values were
              // measured or estimated. Preserve them in recovery, never guess.
              for (final c in ['steps', 'cadence_spm']) {
                if (row[c] != null) {
                  skipped.add(
                    ExportSkip(
                      table,
                      1,
                      'Measured versus estimated provenance is unavailable',
                      identity: identity,
                      columns: [c],
                    ),
                  );
                  row[c] = null;
                }
              }
              if (cleared.isNotEmpty) {
                skipped.add(
                  ExportSkip(
                    table,
                    1,
                    'Fork session scores cleared for official recomputation',
                    identity: identity,
                    columns: cleared,
                  ),
                );
              }
            }
            if ({
                  'session_sensor',
                  'workout_route',
                  'workout_split',
                }.contains(table) &&
                !exportedSessions.contains(row['session_id'])) {
              skip('Parent session is not portable');
              continue;
            }
            if (table == 'workout_split' && row['avg_hr'] != null) {
              row['avg_hr'] = null;
              skipped.add(
                ExportSkip(
                  table,
                  1,
                  'Fork HR aggregate cleared',
                  identity: identity,
                  columns: ['avg_hr'],
                ),
              );
            }
            if (table == 'activity_suggestions') {
              if (!['nap', 'workout'].contains(row['kind']) ||
                  ![
                    'confirmed',
                    'discarded',
                    'superseded',
                  ].contains(row['status'])) {
                skip('Unsupported activity kind or undecided proposal');
                continue;
              }
              final details = activityDetails![rowIndex];
              if (details == null) {
                skip('Activity decision JSON is unreadable');
                continue;
              }
              row['details_json'] = details.json;
              if (details.omitted.isNotEmpty) {
                skipped.add(
                  ExportSkip(
                    table,
                    1,
                    'Computed or unreviewed activity details cleared',
                    identity: identity,
                    columns: details.omitted,
                  ),
                );
              }
            }
            if (table == 'sleep_nap') {
              if (row['source'] == 'auto' &&
                  !confirmedNaps.contains(
                    '${row['day_id']}:${row['start_ts']}',
                  )) {
                skip('Automatic nap has no preserved confirmation');
                continue;
              }
              if (row['payload_json'] != null) {
                skipped.add(
                  ExportSkip(
                    table,
                    1,
                    'Fork nap staging payload cleared; user bounds retained',
                    identity: identity,
                    columns: ['payload_json'],
                  ),
                );
              }
              row['payload_json'] = null;
            }
            if (table == 'workout_suggestions') {
              if (row['dismissed'] != 1) {
                skip('Pending computed workout proposal');
                continue;
              }
              final cleared = [
                'avg_bpm',
                'peak_bpm',
              ].where((c) => row[c] != null).toList();
              if (cleared.isNotEmpty) {
                skipped.add(
                  ExportSkip(
                    table,
                    1,
                    'Fork HR aggregates cleared from dismissed proposal',
                    identity: identity,
                    columns: cleared,
                  ),
                );
              }
              for (final c in ['avg_bpm', 'peak_bpm']) {
                if (row.containsKey(c)) row[c] = null;
              }
            }
            if (table == 'activity_review_meta' && row['revision'] != 0) {
              skipped.add(
                ExportSkip(
                  table,
                  1,
                  'Review revision reset for official ownership',
                  identity: identity,
                  columns: ['revision'],
                ),
              );
              row['revision'] = 0;
            }
            batch.insert(table, row);
            pending.add((row: row, identity: identity));
          }
          // One native round trip per page; keep individual constraint failures
          // accountable instead of aborting unrelated portable records.
          final results = await batch.commit(continueOnError: true);
          for (var i = 0; i < results.length; i++) {
            final result = results[i];
            final item = pending[i];
            if (result is DatabaseException) {
              skipped.add(
                ExportSkip(
                  table,
                  1,
                  'Target constraints rejected row: ${result.isUniqueConstraintError() ? 'duplicate identity' : 'incompatible value or required field'}',
                  identity: item.identity,
                ),
              );
            } else if (table == 'sessions') {
              exportedSessions.add(item.row['id'] as String);
            } else if (table == 'imported_workout') {
              exportedSessions.add(item.row['uuid'] as String);
            }
          }
        });
      }
    }
    await _expandArchives(
      source,
      out,
      profile,
      sourceInventory,
      skipped,
      deletionWindows,
      cancellation,
      progress,
    );
    // Validate children even when a parent was rejected by target constraints.
    for (final pair in const [
      ('decoded_rr', 'decoded_onehz', 'device_id', 'ts_ms'),
      ('ecg_reading_packet', 'ecg_reading', 'reading_id', 'id'),
    ]) {
      final child = pair.$1, parent = pair.$2;
      final predicate = child == 'decoded_rr'
          ? 'p.device_id=c.device_id AND p.ts_ms=c.ts_ms'
          : 'p.id=c.reading_id';
      final orphans = await out.rawQuery(
        'SELECT COUNT(*) AS n FROM $child c WHERE NOT EXISTS(SELECT 1 FROM $parent p WHERE $predicate)',
      );
      final n = orphans.single['n'] as int;
      if (n > 0) {
        await out.rawDelete(
          'DELETE FROM $child AS c WHERE NOT EXISTS(SELECT 1 FROM $parent p WHERE $predicate)',
        );
        skipped.add(
          ExportSkip(child, n, 'Parent evidence was unavailable or skipped'),
        );
      }
    }
    // Add indexes/views/triggers only after projection, so target bookkeeping
    // cannot manufacture computed payloads during the copy.
    for (final object in profile.target['objects'] as List) {
      if (object['type'] != 'table') await out.execute(object['sql'] as String);
    }
    if (sourceInventory.containsKey('day_result')) {
      for (final r in await source.query(
        'day_result',
        columns: ['day_id'],
        distinct: true,
      )) {
        days[r['day_id'] as String] = 'No exact input retained';
      }
    }
    final coveredPage = OfficialRows(
      await out.rawQuery(
        "SELECT MIN(rec_ts) AS rec_ts FROM decoded_onehz GROUP BY date(rec_ts,'unixepoch','localtime')",
      ),
    );
    final coveredDays = await Isolate.run(
      () => officialCoveredDaysHeavy(exportWorkerInputs, coveredPage),
    );
    for (final day in coveredDays) {
      days[day] = 'Partial input retained; completeness is not certified';
    }
    final outputInventory = await inventoryDatabase(
      out,
      cancellation: cancellation,
    );
    final report = OfficialExportReport(
      skipped: skipped,
      sourceInventory: sourceInventory,
      outputInventory: outputInventory,
      profileHash: OfficialProfile.hash(profileText),
      days: days,
      sourceIdentity: {
        ...profile.identity,
        'schema': await source.getVersion(),
        'build_sha': const String.fromEnvironment(
          'EDGE_BUILD_SHA',
          defaultValue: 'development-unrecorded',
        ),
      },
      snapshotHash: before,
    );
    await writeTransitionManifest(out, report);
    await out.close();
    target = null;
    await verifyDatabaseInventory(destinationPath, outputInventory);
    if (await exportFileHash(sourcePath) != before) {
      throw StateError('Source snapshot changed during export');
    }
    return report;
  } finally {
    await source.close();
    await target?.close();
  }
}

Future<void> writeTransitionManifest(
  Database db,
  OfficialExportReport report,
) async {
  await db.execute(
    'CREATE TABLE IF NOT EXISTS fork_transition_manifest(version INTEGER PRIMARY KEY,json TEXT NOT NULL)',
  );
  final encoded = await const IsolateJsonPayloadLane().run(
    JsonPayloadsInput(values: [report.toJson()], encode: true),
  );
  await db.insert('fork_transition_manifest', {
    'version': 1,
    'json': encoded.values.single as String,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

const _sessionScores = [
  'calories',
  'strain',
  'max_hr',
  'avg_hr',
  'hrr_bpm',
  'vo2max_estimate',
  'zone_min_json',
  'trace_json',
  'trace_samples',
];
const _measuredTables = {
  'decoded_onehz',
  'decoded_rr',
  'samples',
  'raw_archive',
  'events',
  'band_events',
  'band_battery',
  'external_hr',
  'live_coverage',
  'observation',
  'vendor_sleep_epoch',
  'imported_measurement',
  'imported_workout',
  'device_coverage',
};

Future<void> _expandArchives(
  Database source,
  Database target,
  OfficialProfile profile,
  Map<String, Object?> inventory,
  List<ExportSkip> skipped,
  List<List<int>>? deleted,
  OfficialExportCancellation? cancellation,
  OfficialExportProgress? progress,
) async {
  if (!inventory.containsKey('substrate_archive')) return;
  final count = (inventory['substrate_archive'] as Map)['rows'] as int;
  final archiveColumns = {
    for (final column in profile.target['tables']['substrate_archive'] as List)
      column['name'] as String,
  };
  final sourceColumns =
      ((inventory['substrate_archive'] as Map)['columns'] as List)
          .cast<String>()
          .toSet();
  final omitted = sourceColumns
      .difference(archiveColumns)
      .union(
        sourceColumns.difference(profile.sourceColumns('substrate_archive')),
      );
  if (omitted.isNotEmpty) {
    skipped.add(
      ExportSkip(
        'substrate_archive',
        count,
        'Archive metadata columns are unsupported by the certified target',
        columns: omitted.toList()..sort(),
      ),
    );
  }

  final ambiguousSeconds = <String>{};
  final conflictingDevices = <String>{};
  final pages = await _ExportPages.open(source, 'substrate_archive');
  var offset = 0;
  while (true) {
    cancellation?.check();
    progress?.update('Expanding lossless archive buckets', offset);
    final page = await pages.next(limit: 1);
    if (page.isEmpty) break;
    final row = page.single;
    offset++;
    final identity = '${row['device_id']}/${row['utc_day']}';
    if (deleted == null) {
      skipped.add(
        ExportSkip(
          'substrate_archive',
          1,
          'Deletion policy is unreadable',
          identity: identity,
        ),
      );
      continue;
    }
    final blob = row['blob'] as Uint8List,
        codec = row['codec'] as int,
        fp = row['fingerprint'] as int;
    final bucket = await Isolate.run(
      () => expandOfficialBucketHeavy(exportWorkerInputs, blob, codec, fp),
    );
    if (bucket == null) {
      skipped.add(
        ExportSkip(
          'substrate_archive',
          1,
          'Unknown codec or corrupt fingerprint',
          identity: identity,
        ),
      );
      continue;
    }
    var livePage = const OfficialRows([]);
    var archivedPage = const OfficialRows([]);
    final times = [
      for (final row in bucket.onehz)
        if (row['ts_ms'] is int) row['ts_ms'] as int,
    ];
    if (times.isNotEmpty) {
      final bounds = times.fold((
        times.first,
        times.first,
      ), (b, t) => (t < b.$1 ? t : b.$1, t > b.$2 ? t : b.$2));
      final args = [row['device_id'], bounds.$1, bounds.$2];
      livePage = OfficialRows(
        await source.rawQuery(
          'SELECT ts_ms FROM decoded_onehz WHERE device_id=? AND ts_ms BETWEEN ? AND ?',
          args,
        ),
      );
      archivedPage = OfficialRows(
        await target.rawQuery(
          'SELECT ts_ms FROM decoded_onehz WHERE device_id=? AND ts_ms BETWEEN ? AND ?',
          args,
        ),
      );
    }
    final keys = await Isolate.run(
      () =>
          officialArchiveKeysHeavy(exportWorkerInputs, livePage, archivedPage),
    );
    final liveSeconds = keys.live;
    final archivedSeconds = keys.archived;
    final cols = {
      for (final c in profile.target['tables']['decoded_onehz'] as List)
        c['name'] as String,
    };
    final allowed = profile.sourceColumns('decoded_onehz');
    final beatCols = {
      for (final c in profile.target['tables']['decoded_rr'] as List)
        c['name'] as String,
    };
    await target.transaction((txn) async {
      final batch = txn.batch();
      var excluded = false;
      for (final original in bucket.onehz) {
        cancellation?.check();
        final measured = {...original, 'device_id': row['device_id']};
        final secondKey = '${row['device_id']}/${original['ts_ms']}';
        if (ambiguousSeconds.contains(secondKey) ||
            (original['device_id'] != null &&
                original['device_id'] != row['device_id'])) {
          excluded = true;
          skipped.add(
            ExportSkip(
              'substrate_archive',
              1,
              'Conflicting archive identity withheld',
              identity: secondKey,
            ),
          );
          continue;
        }
        final family = measured['device_family'];
        if (family != null &&
            !(profile.enums['device_family'] as List).contains(family)) {
          skipped.add(
            ExportSkip(
              'substrate_archive',
              1,
              'Unsupported archived device family: $family',
              identity: '$identity/${measured['ts_ms']}',
            ),
          );
          excluded = true;
          continue;
        }
        final instant = measured['rec_ts'];
        if (instant is! num ||
            deleted.any((w) => instant >= w[0] && instant < w[1])) {
          excluded = true;
          continue;
        }
        if (liveSeconds.contains(measured['ts_ms'])) {
          skipped.add(
            ExportSkip(
              'substrate_archive',
              1,
              'Live second and its complete current beat set override archived data',
              identity: '$identity/${measured['ts_ms']}',
            ),
          );
          continue;
        } // Whole live second owns its current RR set.
        final parent = {
          for (final e in measured.entries)
            if (cols.contains(e.key) && allowed.contains(e.key)) e.key: e.value,
        };
        if (archivedSeconds.contains(parent['ts_ms'])) {
          ambiguousSeconds.add(secondKey);
          conflictingDevices.add(row['device_id'] as String);
          batch.delete(
            'decoded_rr',
            where: 'device_id=? AND ts_ms=?',
            whereArgs: [row['device_id'], parent['ts_ms']],
          );
          batch.delete(
            'decoded_onehz',
            where: 'device_id=? AND ts_ms=?',
            whereArgs: [row['device_id'], parent['ts_ms']],
          );
          batch.delete(
            'substrate_archive',
            where: 'device_id=?',
            whereArgs: [row['device_id']],
          );
          excluded = true;
          skipped.add(
            ExportSkip(
              'substrate_archive',
              1,
              'Conflicting archive parents and both beat sets withheld; originals stay in recovery',
              identity: '$identity/${parent['ts_ms']}',
            ),
          );
          continue;
        }
        batch.insert('decoded_onehz', parent);
        archivedSeconds.add(parent['ts_ms'] as int);
        for (final beat
            in bucket.beats[parent['ts_ms']] ??
                const <Map<String, Object?>>[]) {
          batch.insert('decoded_rr', {
            for (final e in beat.entries)
              if (beatCols.contains(e.key)) e.key: e.value,
            'device_id': row['device_id'],
          });
        }
      }
      // The unfiltered blob could resurrect deleted seconds in a later
      // target replay. Keep its exact bytes in recovery, not active storage.
      if (!excluded &&
          deleted.isEmpty &&
          !conflictingDevices.contains(row['device_id'])) {
        batch.insert('substrate_archive', {
          for (final entry in row.entries)
            if (archiveColumns.contains(entry.key) &&
                !omitted.contains(entry.key))
              entry.key: entry.value,
        });
      } else {
        skipped.add(
          ExportSkip(
            'substrate_archive',
            1,
            conflictingDevices.contains(row['device_id'])
                ? 'Original bucket withheld because conflicting archive inputs cannot be safely replayed; nonconflicting seconds expanded'
                : 'Original bucket withheld to prevent replay of deleted data or unsupported input; permitted seconds expanded',
            identity: identity,
          ),
        );
      }
      await batch.commit(noResult: true);
    });
  }
}
