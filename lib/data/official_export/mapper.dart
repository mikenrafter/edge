// Owns private output-file lifetime and SQL conversion. Native SQLite does the
// paging and inserts; payload decoding/projection runs in mapping_worker.dart.
// The caller supplies a CLOSED immutable snapshot, never a live database path.
// CLAIM(official-export-source-unchanged) [mapper_test; owner proof].
import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'mapping_worker.dart';
import 'payload_requirements.dart';
import 'profile.dart';
import 'profile_tables.dart';
import 'profile_target.dart';
import 'prune_cursor.dart';
import 'schema_catalog.dart';
import 'space_budget.dart';
import '../../compute/derivation_engine.dart' show kAlgoVersion;
import '../json_payload_lane.dart';
import '../attach_copy.dart';
import '../db.dart' show LocalDb;
import '../substrate_archive.dart';

const pilotPulseOmissions = {
  'pulse_episode', 'pulse_episode_alias', 'pulse_episode_outbox',
  'pulse_episode_revision', 'pulse_evidence_chunk', 'pulse_input_arrival',
  'pulse_source_complete', 'pulse_upgrade', 'pulse_upgrade_record',
};

String _q(String name) => '"${name.replaceAll('"', '""')}"';

class OfficialMapReport {
  const OfficialMapReport(this.path, this.cursor, this.tables, this.targetCounts, this.days, {this.manifest=const {}});
  final String path;
  final Map<String,Object?> manifest;
  final PrunedBeforeChoice cursor;
  final Map<String, Object?> tables;
  final Map<String, int> targetCounts;
  final List<Map<String,Object?>> days;
}

/// Throws on I/O, failed integrity/accounting or an unverifiable target file.
/// Unsafe source rows/tables become named omissions while other data exports.
/// On failure only this call's newly created output is deleted. Existing paths
/// and the snapshot are never overwritten. No receipt exists before verification.
Future<OfficialMapReport> mapOfficialSnapshot({
  required String snapshotPath,
  required String outputPath,
  DatabaseFactory? factory,
  LocalCalendar calendar = const DayLabelCalendar(),
  ExportSpaceBudget? space,
  void Function(String phase, int milliseconds)? onPhase,
  void Function(String family, int records)? onProgress,
  Map<String,Object?>? snapshotReceipt,
  String? exportId,
}) async {
  final timer = Stopwatch()..start();
  void lap(String phase) { onPhase?.call(phase, timer.elapsedMilliseconds); timer.reset(); }
  final dbFactory = factory ?? databaseFactory;
  if (File(outputPath).existsSync() || snapshotPath == outputPath) {
    throw ArgumentError('output must be a new private path');
  }
  final src = await dbFactory.openDatabase(snapshotPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
  Database? dst;
  PrivateExportFile? targetFile;
  var verified = false;
  try {
    final sourceHash = (await runMappingWorker(MappingInput('fileHash','',const [],json:snapshotPath))).text!;
    if(snapshotReceipt!=null && snapshotReceipt['sha256']!=sourceHash)throw StateError('Snapshot differs from capture receipt');
    final profileHash = (await runMappingWorker(const MappingInput('profileHash','',[]))).text!;
    final catalog = await SchemaCatalog.read(src);
    final archiveBytes = catalog.tables.containsKey('substrate_archive')
        ? Sqflite.firstIntValue(await src.rawQuery('SELECT SUM(raw_bytes) FROM substrate_archive')) ?? 0 : 0;
    await space?.requireAvailable(ExportSpaceBudget.mappedPeakBytes(File(snapshotPath).lengthSync(), archiveBytes));
    lap('source_inventory_hash');
    targetFile = await PrivateExportFile.create(outputPath,factory:dbFactory);
    dst = targetFile.read;
    // This unpublished scratch file is discarded on every failure. Sync once
    // before verification instead of fsyncing thousands of page batches.
    await targetFile.setScratchSync(ScratchSync.off);
    for (final o in officialTargetObjects.where((o) => o.type == 'table')) {
      await targetFile.applySql(o.sql);
    }
    await targetFile.applySql('CREATE TABLE backup_prefs(key TEXT PRIMARY KEY,type TEXT NOT NULL,value TEXT NOT NULL)');
    await targetFile.applySql('CREATE TABLE backup_secrets(key TEXT PRIMARY KEY)');
    final target = await SchemaCatalog.read(dst);
    final builder = _Mapper(src, targetFile, catalog, target, space, calendar, onProgress);
    await builder.readExclusions();
    await builder.prepareLiveOwnership();
    lap('layout_and_live_ownership');
    // Parents precede dependent rows. No source ID allocation or generic remap.
    final names = catalog.tables.keys.toList()..sort();
    for (final name in const ['device', 'journal_field_def', 'lab_marker_def', 'sessions',
        'imported_workout', 'hyrox_session', 'triathlon_session', 'ecg_reading', 'sleep_nap']) {
      if (names.remove(name)) { await builder.copyTable(name); }
    }
    for (final name in names.where((n) => n != 'substrate_archive' && n != 'sync_cursor' && n != 'decoded_rr')) {
      await builder.copyTable(name);
    }
    if (catalog.tables.containsKey('decoded_rr')) { await builder.copyTable('decoded_rr'); }
    await builder.captureLiveDays();
    lap('live_tables');
    if (catalog.tables.containsKey('substrate_archive')) { await builder.expandArchives(); }
    for (final e in builder.archiveTimings.entries) { if (e.value >= 500) { onPhase?.call(e.key.startsWith('live.') ? e.key : 'archive.${e.key}', e.value); } }
    lap('archive_expansion');
    await targetFile.applySql('DROP TABLE live_parent');
    final forkRow = catalog.tables.containsKey('sync_cursor')
        ? await src.query('sync_cursor', where: "name='decoded_pruned_before'") : <Map<String, Object?>>[];
    final forkCursor = forkRow.isEmpty ? null : int.tryParse('${forkRow.single['value']}');
    final choice = chooseDecodedPrunedBefore(forkCursorSec: forkCursor != null && forkCursor > 0 ? forkCursor : null,
        oldestExactSec: await oldestMappedExactSec(dst), calendar: calendar);
    if (catalog.tables.containsKey('sync_cursor')) { await builder.copyCursor(choice); }
    // Target SQL is replayed verbatim, after all rows. Insertion must never fire
    // revision or session-counter triggers in this transport file. [target_layout_test]
    for (final type in const ['index', 'view', 'trigger']) {
      for (final o in officialTargetObjects.where((o) => o.type == type)) {
        await space?.requireAvailable(1024 * 1024);
        await targetFile.applySql(o.sql);
      }
    }
    await targetFile.applySql('PRAGMA user_version = $officialTargetSchema');
    await targetFile.syncForVerification();
    final inventory = await PayloadInventory.read(dst);
    final violations = checkPayload(inventory, officialProfile,
        target: SchemaCatalog(target.tables, objects: [
          for (final o in officialTargetObjects.where((o) => o.type != 'table'))
            (type: o.type, name: o.name, table: o.table, sql: o.sql),
        ]), expectedPrunedBefore: choice.sec);
    if (violations.isNotEmpty) { throw StateError('unverified payload: $violations'); }
    if ((await dst.rawQuery('PRAGMA integrity_check')).single.values.single != 'ok' ||
        (await dst.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
      throw StateError('target integrity or foreign keys failed');
    }
    for (final e in builder.expectedCounts.entries) {
      if (inventory.rowCounts[e.key] != e.value) {
        throw StateError('target count ${e.key}: ${inventory.rowCounts[e.key]} != ${e.value}');
      }
    }
    lap('target_objects_verification');
    final days = await builder.dayInventory();
    final manifestPayload=<String,Object?>{
      'format': 1, 'export_id':exportId??sourceHash, 'snapshot_sha256': sourceHash, 'profile_sha256': profileHash, 'target_tag': officialTargetTag, 'target_sha': officialTargetSha,
      'source_schema': await src.getVersion(), 'source_algorithm':kAlgoVersion,
      'source_sha':const String.fromEnvironment('OPENSTRAP_SOURCE_SHA',defaultValue:'unknown'),
      'source_tag':const String.fromEnvironment('OPENSTRAP_SOURCE_TAG',defaultValue:'unknown'),
      'target_schema': officialTargetSchema, 'target_algorithm':officialTargetAlgorithm,
      'cursor': {'value': choice.sec, 'reason': choice.reason.name},
      'tables': builder.reports, 'target_counts': inventory.rowCounts,
      'omitted_source_objects': [for (final o in catalog.objects)
        {'type':o.type,'name':o.name,'table':o.table,'reason':'source SQL objects never travel'}],
      'archive_accounting': builder.archiveAccounting, 'days': days,
      'snapshot_receipt': snapshotReceipt ?? {'sha256':sourceHash},
    };
    final manifest = await runMappingWorker(MappingInput('json', '', const [], json:manifestPayload));
    await space?.requireAvailable((manifest.text!.length * 4) + 65536);
    await targetFile.applySql('CREATE TABLE fork_transition_manifest(version INTEGER NOT NULL,payload_json TEXT NOT NULL)');
    await targetFile.writeRow('fork_transition_manifest', {'version': 1, 'payload_json': manifest.text});
    // Check the final file, including the manifest, not an earlier candidate.
    final finalInventory = await PayloadInventory.read(dst);
    if (checkPayload(finalInventory, officialProfile,
        target: SchemaCatalog(target.tables, objects: [
          for (final o in officialTargetObjects.where((o) => o.type != 'table'))
            (type: o.type, name: o.name, table: o.table, sql: o.sql),
        ]), expectedPrunedBefore: choice.sec).isNotEmpty) { throw StateError('final payload failed'); }
    final afterHash = (await runMappingWorker(MappingInput('fileHash','',const [],json:snapshotPath))).text;
    if (afterHash != sourceHash) { throw StateError('snapshot changed during mapping'); }
    lap('manifest_and_final_verification');
    verified = true;
    return OfficialMapReport(outputPath, choice, builder.reports, inventory.rowCounts, days,manifest:manifestPayload);
  } finally {
    try {
      await targetFile?.close();
    } finally {
      try { await src.close(); } finally {
        if (!verified && targetFile != null) { await targetFile.discard(); }
      }
    }
  }
}

Future<int?> oldestMappedExactSec(DatabaseExecutor db) async =>
    Sqflite.firstIntValue(await db.rawQuery(
      'SELECT MIN(rec_ts) FROM ('
      'SELECT rec_ts FROM decoded_onehz WHERE rec_ts > 0 UNION ALL '
      'SELECT rec_ts FROM decoded_rr WHERE rec_ts > 0)',
    ));

/// Tables read [_fetchRows] rows per query (narrow rows, far below Android's
/// 2 MB CursorWindow); every other table keeps 256.
const _wideFetch = {'decoded_onehz', 'decoded_rr', 'samples', 'raw_archive_frames', 'raw_archive_legacy'};
const _fetchRows = 2048;
/// Archive buckets decoded ahead of the one being written (each ~85k seconds).
const _archiveLookahead = 2;

class _Mapper {
  _Mapper(this.src, this.file, this.source, this.target, this.space, this.calendar, this.onProgress);
  final Set<(Object?,String)> _writtenFrames = {};
  /// Milliseconds per archive step, reported through onPhase for profiling.
  final Map<String,int> archiveTimings = {};
  void _spent(String step, Stopwatch clock) { archiveTimings[step] = (archiveTimings[step] ?? 0) + clock.elapsedMilliseconds; }
  final LocalCalendar calendar;
  final void Function(String,int)? onProgress;
  final Database src;
  final PrivateExportFile file;
  Database get dst => file.read;
  final SchemaCatalog source, target;
  final ExportSpaceBudget? space;
  final reports = <String, Object?>{};
  final expectedCounts = <String, int>{};
  final archiveLedgers = <int, _RowLedger>{};
  final archiveAccounting = <Map<String, Object?>>[];
  final liveDays = <(String,String),(int,int)>{};
  final keyMaps = <String, Map<String, String>>{};
  List<(int, int)> windows = [];
  bool unknownExclusions = false;
  bool unknownLiveOwnership = false;

  Future<void> readExclusions() async {
    if (!source.tables.containsKey('compute_freshness')) { return; }
    if (!source.tables['compute_freshness']!.columnNames.containsAll(['key','payload_json'])) { unknownExclusions=true;return; }
    final rows = await src.query('compute_freshness', where: "key='redrive_excluded_windows'");
    if (rows.isEmpty) { return; }
    final decoded = await JsonPayloadLane.shared.decodeUncached(rows.single['payload_json'] as String);
    if (decoded is! List) { unknownExclusions = true; return; }
    for (final w in decoded) {
      if (w is! List || w.length != 2 || w[0] is! int || w[1] is! int || (w[0] as int) >= (w[1] as int)) {
        unknownExclusions = true; return;
      }
      windows.add((w[0] as int, w[1] as int));
    }
  }

  String? excluded(String table, Map<String, Object?> row) {
    if (!{'decoded_onehz', 'decoded_rr', 'samples', 'raw_archive', 'raw_archive_legacy', 'raw_archive_frames'}.contains(table)) { return null; }
    if (unknownExclusions) { return 'unreadable deletion windows'; }
    final sec = row[table == 'samples' ? 'ts' : 'rec_ts'];
    if (windows.isNotEmpty && (sec is! num || sec <= 0)) { return 'unknown instant under deletion windows'; }
    if (sec is num && windows.any((w) => sec >= w.$1 && sec < w.$2)) { return 'deleted input window'; }
    return null;
  }

  // Preferences are read from the immutable snapshot, never this install.
  // Unreadable or mistyped flags cannot authorize an earlier receiver alarm.
  // CLAIM(official-export-active-smart-wake) [alarm_mapping_test; review N1].
  Future<bool> legacySmartWakeActive() async {
    if (!(source.tables['backup_prefs']?.columnNames.containsAll(['key','type','value']) ?? false)) { return false; }
    try {
      final flags = await src.query('backup_prefs', columns: ['type','value'], where: "key='ff.natural_wake'");
      if (flags.length > 1 || (flags.isNotEmpty &&
          (flags.single['type'] != 'bool' || !{'true','false'}.contains(flags.single['value'])))) { return false; }
      if (flags.isNotEmpty && flags.single['value'] == 'false') { return true; }
      if (!(source.tables['wake_meta']?.columnNames.containsAll(['key','value']) ?? false)) { return false; }
      final upgrade = await src.query('wake_meta', columns: ['value'], where: "key='upgrade_explanation'");
      return upgrade.length == 1 && upgrade.single['value'] == 'pending';
    } catch (_) { return false; }
  }

  Future<void> prepareLiveOwnership() async {
    await file.applySql('CREATE TABLE live_parent(device_id TEXT NOT NULL,ts_ms INTEGER NOT NULL,PRIMARY KEY(device_id,ts_ms))');
    final shape=source.tables['decoded_onehz'];
    if (shape==null) {return;}
    if (shape.rowidAlias==null || !shape.columnNames.containsAll(['device_id','ts_ms'])) {
      unknownLiveOwnership=true;return;
    }
    int? after;
    while (true) {
      final rawPage=await LocalDb.exportParentKeys(src,shape.rowidAlias!,after);
      final page=(await runMappingWorker(MappingInput('keys','',const [],batch:rawPage))).rows;
      if (page.isEmpty) {break;}
      final batch=file.beginBatch();
      for (final row in page) {
        if (row['device_id'] is! String || row['ts_ms'] is! int) {unknownLiveOwnership=true;continue;}
        batch.writeRow('live_parent',{'device_id':row['device_id'],'ts_ms':row['ts_ms']});
      }
      await space?.requireAvailable(page.length*1024+65536);
      await batch.flush();after=page.last['cursor'] as int;
    }
  }

  Future<bool> parentExists(String table, String key, Object? id) async =>
      (await dst.query(table, columns: [key], where: '${_q(key)} = ?', whereArgs: [id], limit: 1)).isNotEmpty;

  // Sleep keeps block ids, while v0.12.2 activity_store.keep uses day:start.
  // Follow merges to the current projection, never the suggestion's old span.
  // CLAIM(official-export-nap-link) [nap_links_test; v0.12.2 activity_store.keep].
  Future<String?> officialNapLink(Object? linked) async {
    if (linked is! String) return null;
    if (source.tables['sleep_block']?.columnNames.containsAll(
        ['id','merged_into','state','kind','owner_day','start_ts']) ?? false) {
      final blocks=await src.rawQuery('''WITH RECURSIVE links(id) AS (
        SELECT ? UNION SELECT b.merged_into FROM sleep_block b
        JOIN links l ON b.id=l.id WHERE b.state='merged' AND b.merged_into IS NOT NULL
      ) SELECT b.owner_day,b.start_ts FROM sleep_block b JOIN links l ON b.id=l.id
        WHERE b.kind='nap' AND b.state='live' LIMIT 2''',[linked]);
      if(blocks.length==1) {
        final block=blocks.single;
        final nap=await dst.rawQuery("SELECT 1 FROM sleep_nap WHERE day_id=? AND start_ts=? AND source!='rejected' LIMIT 1",
          [block['owner_day'],block['start_ts']]);
        if(nap.isNotEmpty)return '${block['owner_day']}:${block['start_ts']}';
      }
    }
    final legacy=await dst.rawQuery("SELECT 1 FROM sleep_nap WHERE day_id || ':' || start_ts = ? AND source!='rejected' LIMIT 1",[linked]);
    return legacy.isEmpty?null:linked;
  }

  Future<String?> dependency(String table, Map<String, Object?> row) async {
    final parent = switch (table) {
      'strength_set' || 'workout_split' => ('sessions', 'id', row['session_id']),
      'hyrox_segment' => ('hyrox_session', 'id', row['session_id']),
      'triathlon_segment' => ('triathlon_session', 'id', row['session_id']),
      'ecg_reading_packet' => ('ecg_reading', 'id', row['reading_id']),
      'decoded_rr' => null,
      _ => null,
    };
    if (parent != null && !await parentExists(parent.$1, parent.$2, parent.$3)) { return 'omitted or missing parent'; }
    if (table == 'workout_route' || table == 'session_sensor') {
      if (!await parentExists('sessions', 'id', row['session_id']) &&
          !await parentExists('imported_workout', 'uuid', row['session_id'])) { return 'omitted or missing workout parent'; }
    }
    if (table == 'decoded_rr' && (await dst.rawQuery(
        'SELECT 1 FROM decoded_onehz WHERE device_id=? AND ts_ms=?', [row['device_id'], row['ts_ms']])).isEmpty) { return 'orphan live beat'; }
    return null;
  }

  Future<void> copyTable(String name) async {
    onProgress?.call(name,0);
    final shape = source.tables[name]!;
    final policy = officialProfile.tables[name];
    final count = Sqflite.firstIntValue(await src.rawQuery('SELECT count(*) FROM ${_q(name)}'))!;
    final ledger = _RowLedger(count);
    if (policy == null || !policy.policy.carriesRows || shape.rowidAlias == null || shape.nonPlainColumns.isNotEmpty ||
        (shape.columnNames.difference(policy.columns.keys.toSet()).isNotEmpty ||
        policy.requiredColumns.difference(shape.columnNames).isNotEmpty)) {
      reports[name] = {'source_count': count, 'omitted_all': true,
        'reason': policy == null ? pilotPulseOmissions.contains(name) ? 'pilot Pulse table; recovery only' : 'unsupported table; retained in snapshot' : policy.policy.carriesRows ? 'unsupported source shape' : policy.meaning,
        'columns': shape.columnNames.toList()};
      return;
    }
    final legacyWake = name == 'alarm_schedule' && await legacySmartWakeActive();
    final collidingDefinitions = <String>{};
    if (name == 'journal_field_def' || name == 'lab_marker_def') {
      final seenKeys = <String>{};
      int? last;
      while (true) {
        final page = await src.rawQuery('SELECT rowid AS __export_rowid,* FROM ${_q(name)} ${last == null ? '' : 'WHERE rowid > ?'} ORDER BY rowid LIMIT 256', [?last]);
        if (page.isEmpty) { break; }
        final keys = await runMappingWorker(MappingInput('page', name, page, legacySmartWakeActive: legacyWake));
        for (final row in keys.rows) {
          if (!seenKeys.add(row['key'] as String)) { collidingDefinitions.add(row['key'] as String); }
        }
        last = page.last['__export_rowid'] as int;
      }
    }
    // backup_files is D and never reaches SELECT *, so an oversized attached
    // recording cannot overflow Android's CursorWindow.
    final projection=[for (final c in shape.columns)
      if (policy.clear.contains(c.name) || (policy.omit.contains(c.name) && name!='alarm_schedule'))
        'CASE WHEN ${_q(c.name)} IS NULL THEN NULL ELSE 1 END AS ${_q(c.name)}'
      else _q(c.name)].join(',');
    // Narrow, long tables are read and projected [_fetchRows] at a time
    // (one query, one worker hop) but still written, accounted and
    // committed in the same 256-row pages, so the file bytes are unchanged:
    // per-page query and isolate hops made decoded_rr take 131 s on the
    // emulator. The next read and projection of the closed snapshot run while
    // this one is written. [xe fixture parity]
    final fetchRows = _wideFetch.contains(name) ? _fetchRows : 256;
    Future<(List<Map<String, Object?>>, MappingOutput?)> read(int? from) async {
      final rows = await src.rawQuery('SELECT ${_q(shape.rowidAlias!)} AS __export_rowid,$projection FROM ${_q(name)} '
          '${from == null ? '' : 'WHERE ${_q(shape.rowidAlias!)} > ?'} ORDER BY ${_q(shape.rowidAlias!)} LIMIT $fetchRows',
          [?from]);
      if (rows.isEmpty) { return (rows, null); }
      return (rows, await runMappingWorker(MappingInput('page', name, rows, legacySmartWakeActive: legacyWake)));
    }
    // Per table, not per row: the target's columns and NOT NULL defaults.
    final targetColumns = target.tables[policy.dest]?.columnNames;
    final defaulted = {for (final c in target.tables[policy.dest]?.columns ?? <ColumnShape>[])
      if (c.notNull && c.defaultValue != null) c.name};
    int? after;
    var ahead = read(null);
    while (true) {
      final readWait = Stopwatch()..start();
      final (fetched, projectedRead) = await ahead;
      _spent('live.$name.read_wait', readWait);
      if (fetched.isEmpty) { break; }
      after = fetched.last['__export_rowid'] as int;
      ahead = read(after);
      unawaited(ahead.then((_) {}, onError: (Object _, StackTrace _) {})); // awaited next iteration
      Set<(Object?,Object?)>? liveBeatParents;
      if(name=='decoded_rr') {
        // decoded_onehz is complete in the target before decoded_rr starts.
        liveBeatParents={};
        for (var at = 0; at < fetched.length; at += 256) {
          final matches=await LocalDb.exportMatchingParents(dst,[
            for(final row in fetched.sublist(at, min(at + 256, fetched.length)))
              if(row['device_id'] is String && row['ts_ms'] is int) (row['device_id'] as String,row['ts_ms'] as int),
          ]);
          final metadata=await runMappingWorker(MappingInput('keys','',const [],batch:matches));
          liveBeatParents.addAll([for(final row in metadata.rows) (row['device_id'],row['ts_ms'])]);
        }
      }
      final projectedAll = projectedRead!;
      final notes = {for (final n in projectedAll.notes) n['rowid'] as int: n};
      final sliceOf = <Object?, int>{for (var i = 0; i < fetched.length; i++) fetched[i]['__export_rowid']: i ~/ 256};
      final projectedSlices = [for (var i = 0; i < fetched.length; i += 256) <Map<String,Object?>>[]];
      for (final row in projectedAll.rows) { projectedSlices[sliceOf[row['__export_rowid']]!].add(row); }
      for (var slice = 0; slice < projectedSlices.length; slice++) {
      final page = fetched.sublist(slice * 256, min(slice * 256 + 256, fetched.length));
      final pageIds = {for (final row in page) row['__export_rowid']};
      final originals = {for (final row in page) row['__export_rowid']: row};
      final batch = file.beginBatch();
      final decisions = <int, (String, List, Object?)>{};
      final queuedFrames=<(Object?,String),Map<String,Object?>>{};
      var written = 0;
      final accounting = Stopwatch()..start();
      for (final row in projectedSlices[slice]) {
        final id = row.remove('__export_rowid') as int;
        final original = originals[id]!;
        final reason = excluded(name, original) ?? (name == 'decoded_rr'
            ? liveBeatParents!.contains((original['device_id'],original['ts_ms'])) ? null : 'orphan live beat'
            : await dependency(name, original));
        if (reason != null) { decisions[id] = (reason, const [], null); continue; }
        final napLink=name=='activity_suggestions' && row['kind']=='nap' && row['status']=='confirmed';
        if(napLink)row['linked_id']=await officialNapLink(row['linked_id']);
        if (collidingDefinitions.contains(row['key'])) {
          decisions[id] = ('unit-qualified key collision', const [], null); continue;
        }
        if (name == 'journal_field_def' || name == 'lab_marker_def') {
          (keyMaps[name] ??= {})[original['key'] as String] = row['key'] as String;
        }
        if (name == 'journal_metric' || name == 'lab_result') {
          final field = name == 'journal_metric' ? 'field' : 'marker';
          final definitions = name == 'journal_metric' ? 'journal_field_def' : 'lab_marker_def';
          if (row[field] is! String) {
            decisions[id] = ('unsupported reference storage type', const [], null); continue;
          }
          row[field] = keyMaps[definitions]?[row[field]] ?? row[field];
          if ((row[field] as String).startsWith('custom_') && !await parentExists(definitions, 'key', row[field])) {
            decisions[id] = ('unsupported or missing custom definition', const [], null); continue;
          }
        }
        if (name.startsWith('raw_archive')) {
          final identity=(row['device_id'],'${row['hash']}');
          final queued=queuedFrames[identity];
          // Only this loop writes the target frame table, so an identity it
          // never wrote cannot be there: skip the lookup (86k queries, 39 s).
          final existing = queued!=null ? [queued] : !_writtenFrames.contains(identity) ? const <Map<String,Object?>>[]
              : await dst.query('raw_archive_frames', where: 'device_id=? AND hash=?',
              whereArgs: [row['device_id'], row['hash']]);
          if (existing.isNotEmpty) {
            decisions[id] = (sameRawFrame(existing.single, row) ? 'exact frame overlap' : 'frame hash collision; withheld incoming frame', const [], null);
            continue;
          }
          queuedFrames[identity]=row;
        }
        final lostLink = (name == 'hyrox_segment' || name == 'triathlon_segment') &&
            row['workout_id'] != null && !await parentExists('sessions','id',row['workout_id']);
        if (lostLink) { row['workout_id'] = null; }
        final columns = targetColumns ?? row.keys.toSet();
        row.removeWhere((key, value) => !columns.contains(key) || (value == null && defaulted.contains(key) && policy.clear.contains(key)));
        final invalid = invalidTargetRow(row, target.tables[policy.dest!]);
        if (invalid != null) { decisions[id] = (invalid,const [],null); continue; }
        batch.writeRow(policy.dest!, row);
        written++;
        decisions[id] = ('mapped', [...(notes[id]?['columns'] as List? ?? const []), if (lostLink) 'workout_id',
          if(napLink && row['linked_id']!=original['linked_id']) 'linked_id'], notes[id]?['key_map']);
      }
      for (final note in projectedAll.notes.where((n) => n['omitted'] == true && pageIds.contains(n['rowid']))) {
        decisions[note['rowid'] as int] = (note['reason'] as String, const [], null);
      }
      for (final row in page) {
        final id = row['__export_rowid'] as int;
        final decision = decisions[id]!;
        ledger.add(id, decision.$1, columns: decision.$2, keyMap: decision.$3);
      }
      onProgress?.call(name,ledger.accounted);
      await space?.requireAvailable(256 * 32768);
      _spent('live.$name.account', accounting);
      final wrote = Stopwatch()..start();
      await batch.flush();
      _spent('live.$name.write', wrote);
      if (name.startsWith('raw_archive')) { _writtenFrames.addAll(queuedFrames.keys); }
      expectedCounts[policy.dest!] = (expectedCounts[policy.dest!] ?? 0) + written;
      }
    }
    ledger.verify();
    reports[name] = {
      ...ledger.toJson(),
      // Schema omissions remain explicit even when the table has no rows or
      // every omitted value is NULL; row ranges still describe actual values.
      'omitted_columns':[for(final column in policy.omit) if(shape.columnNames.contains(column))column],
    };
  }

  Future<Set<String>> observedDays(Database db) async {
    if (identical(db,src) && !(source.tables['decoded_onehz']?.columnNames.contains('rec_ts') ?? false)) { return {}; }
    final labels=<String>{};
    final rawBounds=await LocalDb.exportDayBounds(db);
    final metadata=await runMappingWorker(MappingInput('bounds','',const [],batch:rawBounds));
    labels.addAll([for(final row in metadata.rows) calendar.dayLabel(row['sec'] as int)]);
    return labels;
  }

  Future<Map<String,(int,int)>> dayCounts(Database db,String day) async {
    if (identical(db,src) && (!(source.tables['decoded_onehz']?.columnNames.containsAll(['rec_ts','device_id']) ?? false) ||
        !(source.tables['decoded_rr']?.columnNames.containsAll(['rec_ts','device_id']) ?? false))) { return {}; }
    final lo=calendar.dayStartSec(day)!,hi=calendar.dayEndSec(day)!;
    final p=await LocalDb.exportInputCounts(db,beats:false,fromSec:lo,toSec:hi);
    final b=await LocalDb.exportInputCounts(db,beats:true,fromSec:lo,toSec:hi);
    return {for(final device in {...p.keys,...b.keys}) device:(p[device]??0,b[device]??0)};
  }

  Future<void> captureLiveDays() async {
    for(final day in await observedDays(dst)) {
      for(final e in (await dayCounts(dst,day)).entries) {liveDays[(day,e.key)]=e.value;}
    }
  }

  Future<List<Map<String,Object?>>> dayInventory() async {
    final labels={...await observedDays(src),...await observedDays(dst)};
    if (source.tables.containsKey('day_result')) {
      labels.addAll([for (final row in await src.rawQuery('SELECT DISTINCT day_id FROM day_result')) row['day_id'] as String]);
    }
    if (source.tables.containsKey('spectral_archive')) {
      labels.addAll([for (final row in await src.rawQuery('SELECT DISTINCT day_id FROM spectral_archive')) row['day_id'] as String]);
    }
    final days=labels.where((day)=>calendar.dayStartSec(day)!=null).toList()..sort();
    final out=<Map<String,Object?>>[];
    for(final day in days) {
      final original=await dayCounts(src,day),mapped=await dayCounts(dst,day);
      final devices=<String?>{...original.keys,...mapped.keys};
      if (devices.isEmpty) { devices.add(null); }
      for(final device in devices) {
        final live=liveDays[(day,device)]??(0,0), total=mapped[device]??(0,0), before=original[device]??(0,0);
        out.add({'day':day,'device_id':device,'source_live_parents':before.$1,'source_live_beats':before.$2,
          'mapped_live_parents':live.$1,'mapped_live_beats':live.$2,
          'exact_archive_additions':total.$1-live.$1,'exact_archive_beat_additions':total.$2-live.$2,
          'target_parents':total.$1,'target_beats':total.$2,'not_rebuildable_from_exact_input':total.$1==0,
          'coverage':total.$1==0 ? 'No exact input retained' : before.$1>live.$1 || before.$2>live.$2 ? 'Partial input retained' : 'Exact input retained',
          'boundary_note':'Observed retained inputs do not establish a complete night or promise a metric'});
      }
    }
    return out;
  }

  Future<void> copyCursor(PrunedBeforeChoice choice) async {
    final rows = await src.rawQuery('SELECT rowid AS __export_rowid,* FROM sync_cursor ORDER BY rowid');
    final ledger = _RowLedger(rows.length);
    for (final row in rows) {
      if (row['name'] != 'decoded_pruned_before' || choice.sec == null) {
        ledger.add(row['__export_rowid'] as int, 'nonportable or malformed cursor');
      } else {
        await file.writeRow('sync_cursor', {'name': row['name'], 'value': '${choice.sec}', 'updated_at': row['updated_at']});
        expectedCounts['sync_cursor'] = 1;
        ledger.add(row['__export_rowid'] as int, 'recomputed from final exact input');
      }
    }
    ledger.verify(); reports['sync_cursor'] = ledger.toJson();
  }

  // Archive claims. One record per archived parent (identity, bucket, row index,
  // beat count, typed content hash) in the OUTPUT file, where ExportSpaceBudget
  // sees it (TEMP is RAM on Android). Only one overlapping bucket group of one
  // device is held at a time. Content is re-read from the snapshot to expand.
  // CLAIM(official-export-archive-claims) [archive_claims_test; P2 review F1].
  Future<void> expandArchives() async {
    final shape=source.tables['substrate_archive']!;
    if (!shape.columnNames.containsAll([...SubstrateArchive.metaColumns,'blob']) || shape.rowidAlias==null || unknownLiveOwnership) {
      reports['substrate_archive']={'source_count':Sqflite.firstIntValue(await src.rawQuery('SELECT count(*) FROM substrate_archive')),
        'omitted_all':true,'reason':unknownLiveOwnership ? 'unverifiable live parent ownership':'unsupported archive shape','columns':shape.columnNames.toList()};
      return;
    }
    await file.applySql('CREATE TABLE archive_claims(device_id TEXT NOT NULL,ts_ms INTEGER NOT NULL,rec_ts INTEGER,'
        'bucket_id INTEGER NOT NULL,row_index INTEGER NOT NULL,beats INTEGER NOT NULL,digest TEXT NOT NULL,verdict INTEGER)');
    await file.applySql('CREATE INDEX archive_claim_identity ON archive_claims(device_id,ts_ms)');
    await file.applySql('CREATE INDEX archive_claim_selection ON archive_claims(bucket_id,verdict,row_index)');
    final count = Sqflite.firstIntValue(await src.rawQuery('SELECT count(*) FROM substrate_archive'))!;
    final ledger = _RowLedger(count);
    final outcomes = <int, String>{};
    final metas = await src.rawQuery('SELECT rowid AS __export_rowid,${SubstrateArchive.metaColumns.map(_q).join(',')} FROM substrate_archive '
        'ORDER BY device_id,from_ts,to_ts,rowid');
    final group = _ArchiveGroup();
    final flushed = <String, List<(int, int)>>{};
    // Reading and decoding a bucket touch only the closed snapshot, so the
    // next buckets are fetched and decoded in their own isolates while this
    // one is written; results are consumed in metadata order, unchanged.
    Future<(Uint8List?, MappingOutput?)> load(Map<String, Object?> meta) async {
      final blob = await SubstrateArchive.readBlob(src, meta['device_id'] as String, meta['utc_day'] as int);
      if (blob == null) { return (null, null); }
      return (blob, await runMappingWorker(MappingInput('archive', '', const [], blob: blob,
          codec: meta['codec'] as int, fingerprint: meta['fingerprint'] as int)));
    }
    final loads = <int, Future<(Uint8List?, MappingOutput?)>>{};
    Future<(Uint8List?, MappingOutput?)> loadAt(int index) => loads.putIfAbsent(index, () {
      final f = load(metas[index]);
      unawaited(f.then((_) {}, onError: (Object _, StackTrace _) {})); // awaited in order below
      return f;
    });
    for (var index = 0; index < metas.length; index++) {
      final meta = metas[index];
      final id = meta['__export_rowid'] as int;
      onProgress?.call('substrate_archive',outcomes.length);
      final device = meta['device_id'] as String;
      for (var ahead = index + 1; ahead < metas.length && ahead <= index + _archiveLookahead; ahead++) { loadAt(ahead); }
      final waited = Stopwatch()..start();
      final (blob, loaded) = await loadAt(index);
      _spent('load_wait', waited);
      loads.remove(index);
      if (blob == null) { outcomes[id] = 'missing archive bytes'; continue; }
      final decoded = loaded!;
      if (decoded.rows.isEmpty && decoded.notes.any((n) => n['reason'] == 'unreadable codec or fingerprint mismatch')) {
        outcomes[id] = 'unreadable codec or fingerprint mismatch'; continue;
      }
      final usable = <Map<String, Object?>>[];
      for (final claim in decoded.rows) {
        if (claim['device_id'] != device || claim['ts_ms'] is! int) {
          archiveLedgers.putIfAbsent(id,()=>_RowLedger(-1)).add(claim['row_index'] as int,'invalid archive identity'); continue;
        }
        final reason = excluded('decoded_onehz', claim);
        if (reason != null) {
          archiveLedgers.putIfAbsent(id,()=>_RowLedger(-1)).add(claim['row_index'] as int,reason); continue;
        }
        usable.add(claim);
      }
      archiveAccounting.add({'bucket': id, 'fingerprint': meta['fingerprint'], 'parents': decoded.rows.length, 'beats': meta['rr_rows'],
        'orphan_beats': decoded.notes});
      outcomes[id] = 'verified exact expansion; archive storage represented by decoded rows';
      if (usable.isEmpty) { outcomes[id] = 'no admissible archive parents; fully withheld'; continue; }
      var lo = usable.first['ts_ms'] as int, hi = lo;
      for (final c in usable) { final t = c['ts_ms'] as int; if (t < lo) { lo = t; } if (t > hi) { hi = t; } }
      // Buckets arrive in metadata order. A bucket whose CONTENT reaches back
      // into a group already settled cannot be compared with it, so it is
      // withheld by name. Earlier output stays kept, so corrupt metadata can
      // still make bucket order select the earlier claim. [P2 review N4]
      if ((flushed[device] ?? const <(int, int)>[]).any((r) => lo <= r.$2 && hi >= r.$1)) {
        outcomes[id] = 'bucket content overlaps a settled group; fully withheld';
        for (final c in usable) {
          archiveLedgers.putIfAbsent(id,()=>_RowLedger(-1)).add(c['row_index'] as int,'bucket content overlaps a settled group; withheld');
        }
        continue;
      }
      if (group.isEmpty || group.device != device || lo > group.hi! || hi < group.lo!) {
        final settled = Stopwatch()..start();
        await _settleGroup(group, flushed, outcomes);
        _spent('settle', settled);
        group.start(device);
      }
      group.add(id, meta, lo, hi);
      // One durable commit per decoded bucket avoids hundreds of fsyncs on
      // scratch claims. Failure discards the entire unpublished file; all
      // counts and integrity checks still run before publishing. [P3 brief]
      final batch = file.beginBatch();
      for (final c in usable) {
        batch.writeRow('archive_claims', {...c, 'bucket_id': id});
      }
      await space?.requireAvailable(usable.length * 512 + 65536);
      final wrote = Stopwatch()..start();
      await batch.flush();
      _spent('claim_write', wrote);
    }
    final settled = Stopwatch()..start();
    await _settleGroup(group, flushed, outcomes);
    _spent('settle', settled);
    for (final id in outcomes.keys.toList()..sort()) { ledger.add(id, outcomes[id]!); }
    archiveAccounting.addAll([for (final e in archiveLedgers.entries)
      {'bucket': e.key, ...e.value.toJson()}]);
    await file.applySql('DROP TABLE archive_claims');
    ledger.verify(); reports['substrate_archive'] = ledger.toJson();
  }

  Future<List<Map<String, Object?>>> _bucketBlobs(_ArchiveGroup group, Iterable<int> ids, [Map<int, List<int>>? select]) async => [
    for (final id in ids)
      {'bucket_id': id, 'codec': group.metas[id]!['codec'], 'fingerprint': group.metas[id]!['fingerprint'],
       'blob': (await SubstrateArchive.readBlob(src, group.metas[id]!['device_id'] as String, group.metas[id]!['utc_day'] as int))!,
       if (select != null) 'select': select[id]},
  ];

  /// Decides every claim of one overlapping group, expands the kept ones, then
  /// empties the claim table so the next group reuses its pages.
  Future<void> _settleGroup(_ArchiveGroup group, Map<String, List<(int, int)>> flushed, Map<int, String> outcomes) async {
    if (group.isEmpty) { return; }
    // Equal hashes deduplicate only after an exact re-read compare.
    int? lastIdentity;
    while (true) {
      final identities = await dst.rawQuery(
          'SELECT a.device_id,a.ts_ms,group_concat(a.bucket_id||\':\'||a.row_index,\',\') AS claims,min(a.rowid) AS first_claim '
          'FROM archive_claims a WHERE NOT EXISTS(SELECT 1 FROM live_parent l WHERE l.device_id=a.device_id AND l.ts_ms=a.ts_ms) '
          'GROUP BY a.device_id,a.ts_ms HAVING count(*)>1 AND count(DISTINCT a.digest)=1 '
          '${lastIdentity == null ? '' : 'AND min(a.rowid)>?'} ORDER BY min(a.rowid) LIMIT 2048', [?lastIdentity]);
      if (identities.isEmpty) { break; }
      final lists = [for (final row in identities)
        [for (final c in (row['claims'] as String).split(',')) [for (final part in c.split(':')) int.parse(part)]]];
      final ids = {for (final l in lists) for (final c in l) c[0]};
      final differing = await runMappingWorker(MappingInput('claimsEqual', '', await _bucketBlobs(group, ids), json: lists));
      for (final d in differing.rows) {
        final row = identities[d['identity'] as int];
        await file.applySql("UPDATE archive_claims SET digest=digest||'#'||rowid WHERE device_id=? AND ts_ms=?",
            [row['device_id'], row['ts_ms']]);
      }
      lastIdentity = identities.last['first_claim'] as int;
    }
    // Live parents own the WHOLE beat set, even when it is empty. Every
    // conflicting archive claim in this group is withheld before expansion.
    await file.applySql('UPDATE archive_claims AS a SET verdict=CASE '
        'WHEN EXISTS(SELECT 1 FROM live_parent l WHERE l.device_id=a.device_id AND l.ts_ms=a.ts_ms) THEN 1 '
        'WHEN EXISTS(SELECT 1 FROM archive_claims b WHERE b.device_id=a.device_id AND b.ts_ms=a.ts_ms AND b.digest != a.digest) THEN 2 '
        'WHEN EXISTS(SELECT 1 FROM archive_claims b WHERE b.device_id=a.device_id AND b.ts_ms=a.ts_ms AND b.rowid<a.rowid) THEN 3 '
        'ELSE 0 END');
    int? lastClaim;
    while (true) {
      final claims = await dst.rawQuery('SELECT rowid AS claim_id,bucket_id,row_index,verdict FROM archive_claims '
          '${lastClaim == null ? '' : 'WHERE rowid > ?'} ORDER BY rowid LIMIT 4096', [?lastClaim]);
      if (claims.isEmpty) { break; }
      for (final claim in claims) {
        final reason = switch (claim['verdict']) {
          1 => 'live parent owns complete beat set',
          2 => 'conflicting archive claims',
          3 => 'identical archive overlap',
          _ => 'expanded',
        };
        // Bucket index ranges identify every exact occurrence without a
        // multi-million-entry in-memory manifest.
        final bucket = claim['bucket_id'] as int;
        archiveLedgers.putIfAbsent(bucket, () => _RowLedger(-1)).add(claim['row_index'] as int, reason);
      }
      lastClaim = claims.last['claim_id'] as int;
    }
    // All group verdicts are durable before unpacking. Each worker decodes one
    // bucket, selecting at most 20k parents; writes remain 1024-row slices.
    // CLAIM(official-export-bounded-unpack) [archive_claims_test; review N2].
    for (final bucket in group.metas.keys) {
      var expandedParents = 0;
      // Verdicts are final here and expansion writes never touch
      // archive_claims, so the next page is selected and unpacked in its
      // worker while this page is written. Same pages, same write order.
      Future<List<Map<String, Object?>>> select(int? after) => dst.rawQuery(
          'SELECT row_index FROM archive_claims WHERE bucket_id=? AND verdict=0 '
          '${after == null ? '' : 'AND row_index>?'} ORDER BY row_index LIMIT 20000', [bucket, ?after]);
      Future<MappingOutput> unpack(List<Map<String, Object?>> rows) async {
        final kept = {bucket: [for (final row in rows) row['row_index'] as int]};
        return runMappingWorker(MappingInput('unpack', '', await _bucketBlobs(group, kept.keys, kept)));
      }
      var selected = await select(null);
      Future<MappingOutput>? pending = selected.isEmpty ? null : unpack(selected);
      while (pending != null) {
        final unpacked = Stopwatch()..start();
        final expanded = await pending;
        _spent('unpack_worker', unpacked);
        final next = await select(selected.last['row_index'] as int);
        pending = next.isEmpty ? null : unpack(next);
        if (pending != null) { unawaited(pending.then((_) {}, onError: (Object _, StackTrace _) {})); }
        final acceptedParents=<(Object?,Object?)>{};
        for (var offset = 0; offset < expanded.rows.length; offset += 1024) {
          final batch = file.beginBatch();
          final slice = expanded.rows.skip(offset).take(1024).toList();
          for (final entry in slice) {
            final table = entry['table'] as String;
            final row = (entry['row'] as Map).cast<String, Object?>();
            final invalid = excluded(table,row) ?? invalidTargetRow(row,target.tables[table]) ??
                (table=='decoded_rr' && !acceptedParents.contains((row['device_id'],row['ts_ms']))
                  ? 'orphan archive beat after withheld parent':null);
            if (invalid != null) {
              archiveAccounting.add({'bucket':entry['bucket'],'parent_index':entry['parent_index'],
                'table':table,'beat_index':row['beat_index'],'reason':invalid});
              continue;
            }
            if(table=='decoded_onehz') {acceptedParents.add((row['device_id'],row['ts_ms']));expandedParents++;}
            batch.writeRow(table, row);
            expectedCounts[table] = (expectedCounts[table] ?? 0) + 1;
          }
          await space?.requireAvailable(slice.length * 4096 + 65536);
          final wrote = Stopwatch()..start();
          await batch.flush();
          _spent('expand_write', wrote);
        }
        selected = next;
      }
      if (expandedParents == 0) { outcomes[bucket] = 'no admissible archive parents; fully withheld'; }
    }
    await file.applySql('DELETE FROM archive_claims');
    (flushed[group.device!] ??= []).add((group.lo!, group.hi!));
    group.clear();
  }
}

/// One device's buckets whose archived second ranges overlap. Honest UTC-day
/// metadata confines conflicts to a group; late overlap is withheld separately.
class _ArchiveGroup {
  String? device;
  int? lo, hi;
  final metas = <int, Map<String, Object?>>{};
  bool get isEmpty => metas.isEmpty;
  void start(String d) { device = d; lo = null; hi = null; metas.clear(); }
  void add(int id, Map<String, Object?> meta, int from, int to) {
    metas[id] = meta;
    lo = lo == null || from < lo! ? from : lo;
    hi = hi == null || to > hi! ? to : hi;
  }
  void clear() { device = null; lo = null; hi = null; metas.clear(); }
}

String? invalidTargetRow(Map<String,Object?> row,TableShape? shape) {
  if (shape == null) { return null; }
  for (final c in shape.columns) {
    final value=row[c.name];
    if (value == null) {
      if (c.notNull && (row.containsKey(c.name) || c.defaultValue == null)) { return 'missing required ${c.name}'; }
      continue;
    }
    final supported=switch(c.type.toUpperCase()) {
      'TEXT' => value is String,
      'INTEGER' => value is int,
      'REAL' => value is num,
      'BLOB' => value is Uint8List,
      _ => false,
    };
    if (!supported) { return 'unsupported stored type for ${c.name}'; }
  }
  return null;
}

// Exact content comparison supplements the target SHA key. Never dedupe on
// counter or hash alone. Exposed for the otherwise infeasible collision test.
bool sameRawFrame(Map<String, Object?> a, Map<String, Object?> b) {
  if (a['hex'] != b['hex']) { return false; }
  final x = a['frame'], y = b['frame'];
  if (x == null || y == null) { return x == y; }
  if (x is! Uint8List || y is! Uint8List || x.length != y.length) { return false; }
  for (var i = 0; i < x.length; i++) { if (x[i] != y[i]) return false; }
  return true;
}

class _RowLedger {
  _RowLedger(this.sourceCount);
  final int sourceCount;
  final groups = <String, List<List<int>>>{};
  final keyMaps = <Object?>[];
  int accounted = 0;
  int? lastId;
  void add(int id, String reason, {List columns = const [], Object? keyMap}) {
    if (sourceCount >= 0 && lastId != null && id <= lastId!) { throw StateError('source row order/duplicate: $id'); }
    lastId = id;
    accounted++;
    final group = groups.putIfAbsent('$reason; columns=${columns.join(',')}', () => []);
    if (group.isNotEmpty && group.last[1] + 1 == id) { group.last[1] = id; }
    else { group.add([id, id]); }
    if (keyMap != null) { keyMaps.add(keyMap); }
  }
  void verify() { if (accounted != sourceCount) throw StateError('row accounting $accounted != $sourceCount'); }
  Map<String, Object?> toJson() => {'source_count': sourceCount, 'accounted': accounted,
    'rowid_ranges': groups, if (keyMaps.isNotEmpty) 'key_maps': keyMaps};
}
