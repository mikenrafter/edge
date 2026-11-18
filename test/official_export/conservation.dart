// Independent value oracle. It reads source values directly and compares typed
// SQL projections; it never calls a projection or archive-expansion worker.
// CLAIM(official-export-independent-oracle) [P2 review F2]. It does NOT trust the
// mapper's own classification: every omitted row must satisfy an independent SQL
// predicate (or be a literal the caller names), every mapped row must satisfy
// none, a carried table may not be omitted entirely, and the target holds
// nothing beyond mapped source rows and verified archive expansions.
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
import 'package:openstrap_edge/data/substrate_archive.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
String q(String s)=>'"${s.replaceAll('"','""')}"';
Object typed(Object? v)=>v==null ? ['null']:v is Uint8List ? ['blob',base64Encode(v)]:
 v is int ? ['int','$v']:v is double ? ['real',v.toString()]:['text',v];
String canonical(Map<String,Object?> row,List<String> columns)=>jsonEncode([for(final c in columns) typed(row[c])]);
// Source-local reasons an independent reader can check in SQL. `{s}` is the
// source row alias. Reasons absent here must be named by the caller as literal
// omitted rowids (e.g. an unparsable race plan).
const _portablePrefs={'clock_format':'string','theme_choice':'string','locale_override':'string','units_system':'string',
 'local_profile_json':'string','cycle_tracking_enabled':'bool','sleep_hmm_stages':'bool','rough_night.ask':'string',
 'rough_night.dismissed':'string','ui.wearable_show_estimates':'bool','ui.wearable_side_by_side':'bool'};
String _portablePrefSql(String s)=>"(${[for(final e in _portablePrefs.entries) "($s.key='${e.key}' AND $s.type='${e.value}')"].join(' OR ')}) "
 "AND typeof($s.value)='text' AND ($s.type<>'bool' OR $s.value IN ('true','false')) "
 "AND ($s.key<>'local_profile_json' OR CASE WHEN json_valid($s.value) THEN json_type($s.value)='object' ELSE 0 END)";
Map<String,Map<String,String>> _localPredicates()=>{
 'sessions':{'unfinished or fabricated session end':"{s}.status IS NULL OR {s}.status NOT IN ('done','completed') OR typeof({s}.start_ts) NOT IN ('integer','real') OR typeof({s}.end_ts) NOT IN ('integer','real') OR {s}.end_ts<={s}.start_ts OR {s}.end_ts_fabricated=1"},
 'hyrox_session':{'unfinished race':"{s}.status IS NULL OR {s}.status NOT IN ('finished','finalized','abandoned','discarded')"},
 'triathlon_session':{'unfinished race':"{s}.status IS NULL OR {s}.status NOT IN ('finished','finalized','abandoned','discarded')"},
 'activity_suggestions':{'pending inference':"{s}.status='pending'"},
 'workout_suggestions':{'pending workout inference':"{s}.dismissed IS NULL OR {s}.dismissed NOT IN (1,2)"},
 'sleep_nap':{'unconfirmed nap inference':"{s}.source IS NULL OR {s}.source NOT IN ('manual','confirmed','rejected','auto_confirmed')"},
 'sleep_override':{'unsupported sleep boundaries':"typeof({s}.onset_ts) NOT IN ('integer','real') OR typeof({s}.offset_ts) NOT IN ('integer','real') OR {s}.offset_ts<={s}.onset_ts"},
 'live_step_calibration_run':{'unsupported calibration counter/category/reference':"{s}.counter_version IS NOT 2 OR {s}.category IS NULL OR {s}.category NOT IN ('slow','brisk','jog','everyday') OR {s}.reference IS NULL OR {s}.reference NOT IN ('wearerCount','phonePedometer')"},
 'backup_prefs':{'unsupported or nonportable preference':'NOT COALESCE(${_portablePrefSql("{s}")},0)'},
 'backup_secrets':{'unknown presence marker':"{s}.key IS NULL OR {s}.key NOT IN ('coach_api_key','coach_chatgpt','coach_base_url')"},
 'compute_freshness':{'fork freshness or deletion metadata':"{s}.key IS NOT 'substrate_archive_policy'"},
 'observation':{'unsupported observation provenance or identity':"{s}.source_kind IS NULL OR {s}.source_kind NOT IN ('vendor','entered','imported') OR ({s}.key IS NULL AND {s}.vendor_key IS NULL)"},
};
// Parent links checked against the TARGET file: a child is omitted exactly when
// its parent is not in the output.
const _parentLinks={
 'strength_set':('sessions','id','session_id'),'workout_split':('sessions','id','session_id'),
 'hyrox_segment':('hyrox_session','id','session_id'),'triathlon_segment':('triathlon_session','id','session_id'),
 'ecg_reading_packet':('ecg_reading','id','reading_id'),
};
// Columns the mapper rewrites on purpose; they have their own literal proofs.
const _rewritten={'journal_field_def':{'key'},'lab_marker_def':{'key'},'journal_metric':{'field'},'lab_result':{'marker'},
 'hyrox_segment':{'workout_id'},'triathlon_segment':{'workout_id'}};

/// [allowOmittedAll]: carried tables the caller expects to be omitted entirely.
/// [literalOmitted]: source rowids per table whose omission only the fixture
/// (not a SQL predicate) can justify. Anything else unexplained fails.
Future<void> verifyConservation(String sourcePath,OfficialMapReport report,
    {Set<String> allowOmittedAll=const {},Map<String,Set<int>> literalOmitted=const {}}) async {
 final out=await databaseFactoryFfi.openDatabase(report.path,options:OpenDatabaseOptions(readOnly:true));
 final src=await databaseFactoryFfi.openDatabase(sourcePath,options:OpenDatabaseOptions(readOnly:true));
 try {
  await out.execute('ATTACH DATABASE ? AS original',[sourcePath]);
  final windowRows=await src.query('compute_freshness',where:"key='redrive_excluded_windows'");
  final windowList=windowRows.isEmpty ? <List>[]:(jsonDecode(windowRows.single['payload_json'] as String) as List).cast<List>();
  final sourceTables={for(final r in await src.rawQuery("SELECT name FROM sqlite_master WHERE type='table'")) r['name'] as String};
  final mappedCount=<String,int>{};
  final dests={for(final t in officialProfile.tables.values) if(t.policy.carriesRows && t.dest!=null) t.dest!:<String>[]};
  for(final e in officialProfile.tables.entries) {if(e.value.policy.carriesRows && e.value.dest!=null) {dests[e.value.dest!]!.add(e.key);}}
  for(final e in officialProfile.tables.entries) {
   if(!e.value.policy.carriesRows || e.key.startsWith('raw_archive') || e.key=='substrate_archive'||e.key=='sync_cursor') {continue;}
   if(!sourceTables.contains(e.key)) {continue;}
   final stats=report.tables[e.key];
   expect(stats,isA<Map>(),reason:'${e.key}: a carried source table must appear in the report');
   if((stats as Map)['omitted_all']==true) {
    expect(allowOmittedAll,contains(e.key),reason:'${e.key} is carried by policy but the mapper omitted it entirely: ${stats['reason']}');
    continue;
   }
   expect(stats['rowid_ranges'],isA<Map>(),reason:'${e.key} report shape');
   final groups=stats['rowid_ranges'] as Map;
   var accounted=0;
   for(final group in groups.values) {
    for(final r in group as List) {
     accounted+=Sqflite.firstIntValue(await src.rawQuery('SELECT count(*) FROM ${q(e.key)} WHERE rowid BETWEEN ? AND ?',[(r as List)[0],r[1]]))!;
    }
   }
   expect(accounted,stats['source_count'],reason:'exact source-row identity accounting ${e.key}');
   // Independent classification. Every omitted row must satisfy a predicate
   // written here from the spec rules, never the mapper's own group label.
   final dateCol=e.key=='samples' ? 'ts':'rec_ts';
   String? predicate(String reason) {
    final local=_localPredicates()[e.key]?[reason];
    if(local!=null) {return local;}
    for(final rule in officialProfile.enums.where((r)=>r.table==e.key)) {
     if(reason.startsWith('unsupported ${rule.column}: ')) {
      return "{s}.${rule.column} IS NOT NULL AND {s}.${rule.column} NOT IN (${[for(final v in rule.targetValues) "'$v'"].join(',')})";
     }
    }
    final link=_parentLinks[e.key];
    if(reason=='omitted or missing parent' && link!=null) {
     return 'NOT EXISTS(SELECT 1 FROM main.${q(link.$1)} p WHERE p.${q(link.$2)}={s}.${q(link.$3)})';
    }
    if(reason=='omitted or missing workout parent') {
     return 'NOT EXISTS(SELECT 1 FROM main.sessions p WHERE p.id={s}.session_id) AND NOT EXISTS(SELECT 1 FROM main.imported_workout p WHERE p.uuid={s}.session_id)';
    }
    if(reason=='orphan live beat') {
     return 'NOT EXISTS(SELECT 1 FROM main.decoded_onehz p WHERE p.device_id={s}.device_id AND p.ts_ms={s}.ts_ms)';
    }
    if(reason=='deleted input window' && windowList.isNotEmpty) {
     return windowList.map((w)=>'({s}.$dateCol>=${w[0]} AND {s}.$dateCol<${w[1]})').join(' OR ');
    }
    if(reason=='unknown instant under deletion windows' && windowList.isNotEmpty) {
     return "typeof({s}.$dateCol) NOT IN ('integer','real') OR {s}.$dateCol<=0";
    }
    return null;
   }
   // Rows of one range set, as an alias-s relation.
   Future<void> withRanges(List ranges,Future<void> Function(String from) body) async {
    await out.execute('CREATE TEMP TABLE p2_ranges(__p2lo INTEGER,__p2hi INTEGER)');
    final batch=out.batch();
    for(final r in ranges) {batch.insert('p2_ranges',{'__p2lo':(r as List)[0],'__p2hi':r[1]});}
    await batch.commit(noResult:true);
    try {await body('temp.p2_ranges CROSS JOIN original.${q(e.key)} AS s ON s.rowid BETWEEN __p2lo AND __p2hi');}
    finally {await out.execute('DROP TABLE temp.p2_ranges');}
   }
   final literal=literalOmitted[e.key] ?? const <int>{};
   final literalSql=literal.isEmpty ? '0':'s.rowid IN (${literal.join(',')})';
   var mapped=0;
   final omissionPredicates=[for(final p in (_localPredicates()[e.key] ?? const <String,String>{}).values) '(${p.replaceAll('{s}','s')})',
     for(final rule in officialProfile.enums.where((r)=>r.table==e.key))
       "(s.${rule.column} IS NOT NULL AND s.${rule.column} NOT IN (${[for(final v in rule.targetValues) "'$v'"].join(',')}))",
     for(final reason in [
       if(_parentLinks.containsKey(e.key)) 'omitted or missing parent',
       if({'workout_route','session_sensor'}.contains(e.key)) 'omitted or missing workout parent',
       if(e.key=='decoded_rr') 'orphan live beat',
       if({'decoded_onehz','decoded_rr','samples'}.contains(e.key))
         ...['deleted input window','unknown instant under deletion windows'],
     ])
       if(predicate(reason) case final p?) '(${p.replaceAll('{s}','s')})'];
   for(final g in groups.entries) {
    final reason=(g.key as String).split(';').first;
    final isMapped=reason=='mapped';
    await withRanges(g.value as List,(from) async {
     final rows=Sqflite.firstIntValue(await out.rawQuery('SELECT count(*) FROM $from'))!;
     if(isMapped) {
      mapped+=rows;
      if(omissionPredicates.isNotEmpty) {
       expect(Sqflite.firstIntValue(await out.rawQuery('SELECT count(*) FROM $from WHERE ${omissionPredicates.join(' OR ')}'))!,0,
        reason:'${e.key}: rows the mapper kept that an independent rule says must be omitted');
      }
     } else {
      final pred=predicate(reason);
      final unexplained=await out.rawQuery(pred==null
        ? 'SELECT s.rowid AS id FROM $from WHERE NOT ($literalSql) LIMIT 5'
        : 'SELECT s.rowid AS id FROM $from WHERE NOT COALESCE((${pred.replaceAll('{s}','s')}),0) AND NOT ($literalSql) LIMIT 5');
      expect(unexplained,isEmpty,reason:'${e.key}: rows omitted as "$reason" that no independent rule or named literal explains');
     }
    });
   }
   mappedCount[e.key]=mapped;
   final ranges=[for(final g in groups.entries) if((g.key as String).startsWith('mapped;')) ...g.value as List];
   if(ranges.isEmpty) {continue;}
   final columns=e.value.keep;
   // Rewritten fields have separate literal unit-key/reference proofs. Every
   // unmodified source field still participates in this typed-value comparison.
   final projection=[for(final c in columns) '${q(c)},typeof(${q(c)})'].join(',');
   // Source rowids can be very sparse after INSERT OR REPLACE. A complete
   // target EXCEPT per range rescans millions of expanded rows repeatedly.
   // CROSS JOIN fixes ranges as the outer loop, then compares the union once.
   await out.execute('CREATE TEMP TABLE p2_ranges(__p2lo INTEGER,__p2hi INTEGER)');
   final batch=out.batch();
   for(final r in ranges) {batch.insert('p2_ranges',{'__p2lo':(r as List)[0],'__p2hi':r[1]});}
   await batch.commit(noResult:true);
   final missing=await out.rawQuery('SELECT $projection FROM temp.p2_ranges CROSS JOIN original.${q(e.key)} AS source_rows '
      'WHERE source_rows.rowid BETWEEN __p2lo AND __p2hi EXCEPT SELECT $projection FROM main.${q(e.value.dest!)} LIMIT 1');
   expect(missing,isEmpty,reason:'${e.key} exact mapped source identities and kept fields');
   await out.execute('DROP TABLE temp.p2_ranges');
  }
  // Target to source: nothing in the target that no mapped source row explains.
  // decoded_* also carry verified archive expansions and are counted below.
  for(final dest in dests.entries) {
   if(dest.key=='decoded_onehz'||dest.key=='decoded_rr'||dest.value.length!=1) {continue;}
   final table=dest.value.single, policy=officialProfile.tables[table]!;
   if(!mappedCount.containsKey(table)) {continue;}
   final columns=[for(final c in policy.keep) if(!(_rewritten[table]??const <String>{}).contains(c)) c];
   expect(Sqflite.firstIntValue(await out.rawQuery('SELECT count(*) FROM main.${q(dest.key)}')),mappedCount[table],
     reason:'${dest.key}: target row count must equal the mapped source rows (no invented or duplicated rows)');
   if(columns.isEmpty) {continue;}
   final cols=columns.map(q).join(',');
   final invented=await out.rawQuery('SELECT $cols FROM main.${q(dest.key)} EXCEPT SELECT $cols FROM original.${q(table)} LIMIT 1');
   expect(invented,isEmpty,reason:'${dest.key}: a target row has no source row behind it');
  }
  await out.execute('DETACH DATABASE original');
  // Frame hashes are transport identities, not a value oracle. Independently
  // reconstruct exact bytes/text and compare both content and mapped metadata.
  for(final table in ['raw_archive','raw_archive_legacy','raw_archive_frames']) {
   final stats=report.tables[table];
   if(stats is! Map || stats['rowid_ranges'] is! Map) {continue;}
   for(final group in (stats['rowid_ranges'] as Map).entries) {
    final mapped=(group.key as String).startsWith('mapped;');
    final overlap=(group.key as String).startsWith('exact frame overlap;');
    if(!mapped && !overlap) {continue;}
    for(final range in group.value as List) {
     int? after;
     while(true) {
      final page=await src.rawQuery('SELECT rowid AS source_id,* FROM ${q(table)} WHERE rowid BETWEEN ? AND ? ${after==null ? '' : 'AND rowid>?'} ORDER BY rowid LIMIT 256',
       [(range as List)[0],range[1],?after]);
      if(page.isEmpty) {break;}
      for(final row in page) {
       final text=row['hex'] as String?;
       final bytes=text==null ? row['frame'] as Uint8List :
         RegExp(r'^(?:[0-9a-f]{2})+$').hasMatch(text)
           ? Uint8List.fromList([for(var i=0;i<text.length;i+=2) int.parse(text.substring(i,i+2),radix:16)]) : null;
       final hash=Uint8List.fromList(sha1.convert(bytes ?? utf8.encode('text:$text')).bytes);
       final actual=(await out.query('raw_archive_frames',where:'device_id=? AND hash=?',whereArgs:[row['device_id'],hash])).single;
       expect(actual['frame'],bytes,reason:'$table exact bytes at source ${row['source_id']}');
       expect(actual['hex'],bytes==null ? text:null,reason:'$table exact noncanonical text');
       if(mapped) {
        for(final c in ['device_id','counter','packet_type','rec_ts','captured_at','reason']) {
         expect(actual[c],row[c],reason:'$table mapped frame metadata $c');
        }
       }
      }
      after=page.last['source_id'] as int;
     }
    }
   }
  }
  final exclusions=await src.query('compute_freshness',where:"key='redrive_excluded_windows'");
  final windows=exclusions.isEmpty ? <List>[]:(jsonDecode(exclusions.single['payload_json'] as String) as List).cast<List>();
  bool deleted(Object? sec)=>sec is num && windows.any((w)=>sec>=(w[0] as num)&&sec<(w[1] as num));
  final metas=await src.query('substrate_archive',columns:SubstrateArchive.metaColumns);
  var expectedParents=0,expectedBeatsTotal=0;
  for(final meta in metas) {
   final blob=await SubstrateArchive.readBlob(src,meta['device_id'] as String,meta['utc_day'] as int);
   final bucket=blob==null ? null:SubstrateArchiveCodec.decode(blob,codec:meta['codec'] as int);
   if(bucket==null || SubstrateArchiveCodec.fingerprint(bucket)!=meta['fingerprint']) {continue;}
   final columns=officialProfile.tables['decoded_onehz']!.keep;
   final beatColumns=officialProfile.tables['decoded_rr']!.keep;
   // The owner proof's buckets are disjoint UTC partitions. The synthetic
   // conflict fixture separately proves multi-claim withholding with literals.
   final live={for(final r in await src.rawQuery('SELECT ts_ms FROM decoded_onehz WHERE device_id=? AND rec_ts>=? AND rec_ts<=?',
      [meta['device_id'],meta['from_ts'],meta['to_ts']])) r['ts_ms']};
   final expected=<Object?,Map<String,Object?>>{};
   for(var i=0;i<bucket.onehz.rowCount;i++) {
    final row=bucket.onehz.rowAt(i), ts=bucket.onehz.valueAt('ts_ms',i);
    expect((row['rec_ts'] as int)~/86400,meta['utc_day'],reason:'owner bucket partition assumption');
    if(!live.contains(ts) && !deleted(row['rec_ts'])) {expected[ts]=row;}
   }
   expectedParents+=expected.length;
   if(expected.isEmpty) {continue;}
   final actual=await out.rawQuery('SELECT * FROM decoded_onehz WHERE device_id=? AND rec_ts>=? AND rec_ts<=?',
      [meta['device_id'],meta['from_ts'],meta['to_ts']]);
   final byTs={for(final r in actual) r['ts_ms']:r};
   for(final e in expected.entries) {
    expect(byTs.containsKey(e.key),isTrue,reason:'archive exact parent ${e.key}');
    expect(canonical(byTs[e.key]!,columns),canonical(e.value,columns));
   }
   final expectedBeats=<String>[],actualBeats=<String>[];
   for(var i=0;i<bucket.rr.rowCount;i++) {
    if(expected.containsKey(bucket.rr.valueAt('ts_ms',i)) && !deleted(bucket.rr.valueAt('rec_ts',i))) {
     expectedBeats.add(canonical(bucket.rr.rowAt(i),beatColumns));
    }
   }
   for(final r in await out.rawQuery('SELECT * FROM decoded_rr WHERE device_id=? AND rec_ts>=? AND rec_ts<=?',
      [meta['device_id'],meta['from_ts'],meta['to_ts']])) {
    if(expected.containsKey(r['ts_ms'])) {actualBeats.add(canonical(r,beatColumns));}
   }
   expectedBeatsTotal+=expectedBeats.length;
   expectedBeats.sort();actualBeats.sort();
   expect(actualBeats,expectedBeats,reason:'exact archive beat-set conservation ${meta['utc_day']}');
  }
 // Nothing beyond live mapped rows and verified archive expansions. Forward
  // checks above prove each expected row is present; equal counts prove no extra.
  for(final e in {'decoded_onehz':expectedParents,'decoded_rr':expectedBeatsTotal}.entries) {
   if(!mappedCount.containsKey(e.key)) {continue;}
   expect(Sqflite.firstIntValue(await out.rawQuery('SELECT count(*) FROM main.${e.key}')),mappedCount[e.key]!+e.value,
     reason:'${e.key}: target rows must be exactly live mapped rows plus verified archive expansions');
  }
 } finally {await out.close();await src.close();}
}
