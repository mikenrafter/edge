// Independent value oracle. It reads source values directly and compares typed
// SQL projections; it never calls a projection or archive-expansion worker.
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
Future<void> verifyConservation(String sourcePath,OfficialMapReport report) async {
 final out=await databaseFactoryFfi.openDatabase(report.path,options:OpenDatabaseOptions(readOnly:true));
 final src=await databaseFactoryFfi.openDatabase(sourcePath,options:OpenDatabaseOptions(readOnly:true));
 try {
  await out.execute('ATTACH DATABASE ? AS original',[sourcePath]);
  for(final e in officialProfile.tables.entries) {
   if(!e.value.policy.carriesRows || e.key.startsWith('raw_archive') || e.key=='substrate_archive'||e.key=='sync_cursor') {continue;}
   final stats=report.tables[e.key];
   if(stats is! Map || stats['rowid_ranges'] is! Map) {continue;}
   final groups=stats['rowid_ranges'] as Map;
   var accounted=0;
   for(final group in groups.values) {
    for(final r in group as List) {
     accounted+=Sqflite.firstIntValue(await src.rawQuery('SELECT count(*) FROM ${q(e.key)} WHERE rowid BETWEEN ? AND ?',[(r as List)[0],r[1]]))!;
    }
   }
   expect(accounted,stats['source_count'],reason:'exact source-row identity accounting ${e.key}');
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
   expectedBeats.sort();actualBeats.sort();
   expect(actualBeats,expectedBeats,reason:'exact archive beat-set conservation ${meta['utc_day']}');
  }
 } finally {await out.close();await src.close();}
}
