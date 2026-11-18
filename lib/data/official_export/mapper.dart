// Owns private output-file lifetime and SQL conversion. Native SQLite does the
// paging and inserts; payload decoding/projection runs in mapping_worker.dart.
// The caller supplies a CLOSED immutable snapshot, never a live database path.
// CLAIM(official-export-source-unchanged) [mapper_test; owner proof].
import 'dart:io';
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
  const OfficialMapReport(this.path, this.cursor, this.tables, this.targetCounts, this.days);
  final String path;
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
}) async {
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
    final profileHash = (await runMappingWorker(const MappingInput('profileHash','',[]))).text!;
    final catalog = await SchemaCatalog.read(src);
    final archiveBytes = catalog.tables.containsKey('substrate_archive')
        ? Sqflite.firstIntValue(await src.rawQuery('SELECT SUM(raw_bytes) FROM substrate_archive')) ?? 0 : 0;
    await space?.requireAvailable(ExportSpaceBudget.mappedPeakBytes(File(snapshotPath).lengthSync(), archiveBytes));
    targetFile = await PrivateExportFile.create(outputPath,factory:dbFactory);
    dst = targetFile.read;
    for (final o in officialTargetObjects.where((o) => o.type == 'table')) {
      await targetFile.applySql(o.sql);
    }
    await targetFile.applySql('CREATE TABLE backup_prefs(key TEXT PRIMARY KEY,type TEXT NOT NULL,value TEXT NOT NULL)');
    await targetFile.applySql('CREATE TABLE backup_secrets(key TEXT PRIMARY KEY)');
    final target = await SchemaCatalog.read(dst);
    final builder = _Mapper(src, targetFile, catalog, target, space, calendar);
    await builder.readExclusions();
    await builder.prepareLiveOwnership();
    // Parents precede dependent rows. No source ID allocation or generic remap.
    final names = catalog.tables.keys.toList()..sort();
    for (final name in const ['device', 'journal_field_def', 'lab_marker_def', 'sessions',
        'imported_workout', 'hyrox_session', 'triathlon_session', 'ecg_reading']) {
      if (names.remove(name)) { await builder.copyTable(name); }
    }
    for (final name in names.where((n) => n != 'substrate_archive' && n != 'sync_cursor' && n != 'decoded_rr')) {
      await builder.copyTable(name);
    }
    if (catalog.tables.containsKey('decoded_rr')) { await builder.copyTable('decoded_rr'); }
    await builder.captureLiveDays();
    if (catalog.tables.containsKey('substrate_archive')) { await builder.expandArchives(); }
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
    final days = await builder.dayInventory();
    final manifest = await runMappingWorker(MappingInput('json', '', const [], json: {
      'format': 1, 'snapshot_sha256': sourceHash, 'profile_sha256': profileHash, 'target_tag': officialTargetTag, 'target_sha': officialTargetSha,
      'source_schema': await src.getVersion(), 'target_schema': officialTargetSchema,
      'cursor': {'value': choice.sec, 'reason': choice.reason.name},
      'tables': builder.reports, 'target_counts': inventory.rowCounts,
      'omitted_source_objects': [for (final o in catalog.objects)
        {'type':o.type,'name':o.name,'table':o.table,'reason':'source SQL objects never travel'}],
      'archive_accounting': builder.archiveAccounting, 'days': days,
      'snapshot_receipt': 'caller supplies snapshot boundary/content receipt in P3',
    }));
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
    verified = true;
    return OfficialMapReport(outputPath, choice, builder.reports, inventory.rowCounts, days);
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

class _Mapper {
  _Mapper(this.src, this.file, this.source, this.target, this.space, this.calendar);
  final LocalCalendar calendar;
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
    await file.applySql('CREATE TEMP TABLE live_parent(device_id TEXT NOT NULL,ts_ms INTEGER NOT NULL,PRIMARY KEY(device_id,ts_ms))');
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
    final shape = source.tables[name]!;
    final policy = officialProfile.tables[name];
    final count = Sqflite.firstIntValue(await src.rawQuery('SELECT count(*) FROM ${_q(name)}'))!;
    final ledger = _RowLedger(count);
    if (policy == null || !policy.policy.carriesRows || shape.rowidAlias == null || shape.nonPlainColumns.isNotEmpty ||
        (shape.columnNames.difference(policy.columns.keys.toSet()).isNotEmpty ||
        policy.columns.keys.toSet().difference(shape.columnNames).isNotEmpty)) {
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
    int? after;
    while (true) {
      // backup_files is D and never reaches SELECT *, so an oversized attached
      // recording cannot overflow Android's CursorWindow.
      final projection=[for (final c in shape.columns)
        if (policy.clear.contains(c.name) || (policy.omit.contains(c.name) && name!='alarm_schedule'))
          'CASE WHEN ${_q(c.name)} IS NULL THEN NULL ELSE 1 END AS ${_q(c.name)}'
        else _q(c.name)].join(',');
      final page = await src.rawQuery('SELECT ${_q(shape.rowidAlias!)} AS __export_rowid,$projection FROM ${_q(name)} '
          '${after == null ? '' : 'WHERE ${_q(shape.rowidAlias!)} > ?'} ORDER BY ${_q(shape.rowidAlias!)} LIMIT 256',
          [?after]);
      if (page.isEmpty) { break; }
      after = page.last['__export_rowid'] as int;
      Set<(Object?,Object?)>? liveBeatParents;
      if(name=='decoded_rr') {
        final matches=await LocalDb.exportMatchingParents(dst,[
          for(final row in page)
            if(row['device_id'] is String && row['ts_ms'] is int) (row['device_id'] as String,row['ts_ms'] as int),
        ]);
        final metadata=await runMappingWorker(MappingInput('keys','',const [],batch:matches));
        liveBeatParents={for(final row in metadata.rows) (row['device_id'],row['ts_ms'])};
      }
      final projected = await runMappingWorker(MappingInput('page', name, page, legacySmartWakeActive: legacyWake));
      final originals = {for (final row in page) row['__export_rowid']: row};
      final notes = {for (final n in projected.notes) n['rowid'] as int: n};
      final batch = file.beginBatch();
      final decisions = <int, (String, List, Object?)>{};
      final queuedFrames=<(Object?,String),Map<String,Object?>>{};
      var written = 0;
      for (final row in projected.rows) {
        final id = row.remove('__export_rowid') as int;
        final original = originals[id]!;
        final reason = excluded(name, original) ?? (name == 'decoded_rr'
            ? liveBeatParents!.contains((original['device_id'],original['ts_ms'])) ? null : 'orphan live beat'
            : await dependency(name, original));
        if (reason != null) { decisions[id] = (reason, const [], null); continue; }
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
          final existing = queued==null ? await dst.query('raw_archive_frames', where: 'device_id=? AND hash=?',
              whereArgs: [row['device_id'], row['hash']]) : [queued];
          if (existing.isNotEmpty) {
            decisions[id] = (sameRawFrame(existing.single, row) ? 'exact frame overlap' : 'frame hash collision; withheld incoming frame', const [], null);
            continue;
          }
          queuedFrames[identity]=row;
        }
        final lostLink = (name == 'hyrox_segment' || name == 'triathlon_segment') &&
            row['workout_id'] != null && !await parentExists('sessions','id',row['workout_id']);
        if (lostLink) { row['workout_id'] = null; }
        final columns = target.tables[policy.dest]?.columnNames ?? row.keys.toSet();
        final defaulted = {for (final c in target.tables[policy.dest]?.columns ?? <ColumnShape>[])
          if (c.notNull && c.defaultValue != null) c.name};
        row.removeWhere((key, value) => !columns.contains(key) || (value == null && defaulted.contains(key) && policy.clear.contains(key)));
        final invalid = invalidTargetRow(row, target.tables[policy.dest!]);
        if (invalid != null) { decisions[id] = (invalid,const [],null); continue; }
        batch.writeRow(policy.dest!, row);
        written++;
        decisions[id] = ('mapped', [...(notes[id]?['columns'] as List? ?? const []), if (lostLink) 'workout_id'], notes[id]?['key_map']);
      }
      for (final note in projected.notes.where((n) => n['omitted'] == true)) {
        decisions[note['rowid'] as int] = (note['reason'] as String, const [], null);
      }
      for (final row in page) {
        final id = row['__export_rowid'] as int;
        final decision = decisions[id]!;
        ledger.add(id, decision.$1, columns: decision.$2, keyMap: decision.$3);
      }
      await space?.requireAvailable(256 * 32768);
      await batch.flush();
      expectedCounts[policy.dest!] = (expectedCounts[policy.dest!] ?? 0) + written;
    }
    ledger.verify();
    reports[name] = ledger.toJson();
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
        'bucket_id INTEGER NOT NULL,row_index INTEGER NOT NULL,beats INTEGER NOT NULL,digest TEXT NOT NULL)');
    await file.applySql('CREATE INDEX archive_claim_identity ON archive_claims(device_id,ts_ms)');
    final count = Sqflite.firstIntValue(await src.rawQuery('SELECT count(*) FROM substrate_archive'))!;
    final ledger = _RowLedger(count);
    final outcomes = <int, String>{};
    final metas = await src.rawQuery('SELECT rowid AS __export_rowid,${SubstrateArchive.metaColumns.map(_q).join(',')} FROM substrate_archive '
        'ORDER BY device_id,from_ts,to_ts,rowid');
    final group = _ArchiveGroup();
    final flushed = <String, List<(int, int)>>{};
    for (final meta in metas) {
      final id = meta['__export_rowid'] as int;
      final device = meta['device_id'] as String;
      final blob = await SubstrateArchive.readBlob(src, device, meta['utc_day'] as int);
      if (blob == null) { outcomes[id] = 'missing archive bytes'; continue; }
      final decoded = await runMappingWorker(MappingInput('archive', '', const [], blob: blob,
          codec: meta['codec'] as int, fingerprint: meta['fingerprint'] as int));
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
      if (usable.isEmpty) { continue; }
      var lo = usable.first['ts_ms'] as int, hi = lo;
      for (final c in usable) { final t = c['ts_ms'] as int; if (t < lo) { lo = t; } if (t > hi) { hi = t; } }
      // Buckets arrive in metadata order. A bucket whose CONTENT reaches back
      // into a group already settled cannot be compared with it, so it is
      // withheld by name rather than risking an unseen conflict.
      if ((flushed[device] ?? const <(int, int)>[]).any((r) => lo <= r.$2 && hi >= r.$1)) {
        for (final c in usable) {
          archiveLedgers.putIfAbsent(id,()=>_RowLedger(-1)).add(c['row_index'] as int,'bucket content overlaps a settled group; withheld');
        }
        continue;
      }
      if (group.isEmpty || group.device != device || lo > group.hi! || hi < group.lo!) {
        await _settleGroup(group, flushed);
        group.start(device);
      }
      group.add(id, meta, lo, hi);
      for (var offset = 0; offset < usable.length; offset += 256) {
        final batch = file.beginBatch();
        for (final c in usable.skip(offset).take(256)) {
          batch.writeRow('archive_claims', {...c, 'bucket_id': id});
        }
        await space?.requireAvailable(256 * 512 + 65536);
        await batch.flush();
      }
    }
    await _settleGroup(group, flushed);
    for (final id in outcomes.keys.toList()..sort()) { ledger.add(id, outcomes[id]!); }
    archiveAccounting.addAll([for (final e in archiveLedgers.entries)
      {'bucket': e.key, ...e.value.toJson()}]);
    await file.applySql('DROP TABLE archive_claims');
    await file.applySql('DROP TABLE temp.live_parent');
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
  Future<void> _settleGroup(_ArchiveGroup group, Map<String, List<(int, int)>> flushed) async {
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
    // conflicting archive claim is withheld; no bucket order decides a winner.
    int? lastClaim;
    while (true) {
      final claims = await dst.rawQuery(
          'SELECT a.rowid AS claim_id,a.bucket_id,a.row_index,CASE '
          'WHEN EXISTS(SELECT 1 FROM live_parent l WHERE l.device_id=a.device_id AND l.ts_ms=a.ts_ms) THEN 1 '
          'WHEN EXISTS(SELECT 1 FROM archive_claims b WHERE b.device_id=a.device_id AND b.ts_ms=a.ts_ms AND b.digest != a.digest) THEN 2 '
          'WHEN EXISTS(SELECT 1 FROM archive_claims b WHERE b.device_id=a.device_id AND b.ts_ms=a.ts_ms AND b.rowid<a.rowid) THEN 3 '
          'ELSE 0 END AS verdict FROM archive_claims a '
          '${lastClaim == null ? '' : 'WHERE a.rowid > ?'} ORDER BY a.rowid LIMIT 4096',
          [?lastClaim]);
      if (claims.isEmpty) { break; }
      final kept = <int, List<int>>{};
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
        if (claim['verdict'] == 0) { (kept[bucket] ??= []).add(claim['row_index'] as int); }
      }
      final expanded = await runMappingWorker(MappingInput('unpack', '', await _bucketBlobs(group, kept.keys, kept)));
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
          if(table=='decoded_onehz') {acceptedParents.add((row['device_id'],row['ts_ms']));}
          batch.writeRow(table, row);
          expectedCounts[table] = (expectedCounts[table] ?? 0) + 1;
        }
        await space?.requireAvailable(slice.length * 4096 + 65536);
        await batch.flush();
      }
      lastClaim = claims.last['claim_id'] as int;
    }
    await file.applySql('DELETE FROM archive_claims');
    (flushed[group.device!] ??= []).add((group.lo!, group.hi!));
    group.clear();
  }
}

/// One device's buckets whose archived second ranges overlap. Identity
/// conflicts can only arise inside a group.
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
