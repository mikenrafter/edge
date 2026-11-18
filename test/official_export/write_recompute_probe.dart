// Synthetic physiological support and exact archived history, made through the
// real fork creators. This is test data, independent of the owner proof sample.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support.dart';

ArchiveTable rows(List<Map<String,Object?>> rows) => (ArchiveTableBuilder()..addRows(rows)).build();
void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 test('write exact archive-restored physiological fixture', () async {
  await withFreshForkDb((db,path) async {
   const from=1792670400,end=1792886400; // Oct22 noon through Oct25 midnight UTC
   for(var day=from~/86400;day<(end+86399)~/86400;day++) {
    final lo=day*86400<from ? from:day*86400;
    final hi=(day+1)*86400>end ? end:(day+1)*86400;
    final p=<Map<String,Object?>>[],b=<Map<String,Object?>>[];
    for(var sec=lo;sec<hi;sec++) {
     final hour=(sec%86400)~/3600;
     p.add({'device_id':'','ts_ms':sec*1000,'rec_ts':sec,'counter':sec-from,
      'hr':hour<8||hour>=23 ? 60:80,'ax':0.0,'ay':0.0,'az':1.0,
      'skin_temp_raw':3300,'device_family':'gen4'});
     b.add({'device_id':'','ts_ms':sec*1000,'rec_ts':sec,'beat_index':0,
      'rr_ts_ms':sec*1000,'beat_ts_ms':sec*1000,'rr_ms':1000+(sec%3-1)*20,
      'device_family':'gen4'});
    }
    final w=SubstrateArchiveCodec.encodeMergeVerify(ArchiveBucket(rows(p),rows(b)));
    await db.insert('substrate_archive',{'device_id':'','utc_day':day,'codec':1,
      'from_ts':lo,'to_ts':hi-1,'onehz_rows':p.length,'rr_rows':b.length,
      'raw_bytes':w.rawBytes,'fingerprint':w.fingerprint,'blob':w.blob,'created_at':1,'updated_at':1});
   }
   await db.insert('decoded_onehz',{'device_id':'','ts_ms':1794096000000,'rec_ts':1794096000,'counter':999999,'hr':80,'device_family':'gen4'});
   await db.insert('sync_cursor',{'name':'decoded_pruned_before','value':'1794096000','updated_at':1});
   await db.insert('compute_freshness',{'key':'substrate_archive_policy','payload_json':'{"keep_days":-1}','updated_at':1});
   await db.insert('sleep_override',{'day_id':'2026-10-24','onset_ts':1792796400,'offset_ts':1792825200,'source':'manual','created_at':1});
   await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)'); await LocalDb.close();
   final out=Directory(Platform.environment['CANDIDATES_DIR']!)..createSync(recursive:true);
   final report=await mapOfficialSnapshot(snapshotPath:path,outputPath:'${out.path}/archive_complete.db',factory:databaseFactoryFfi);
   expect(report.cursor.sec,1792713600);
   expect(report.targetCounts['decoded_onehz'],216001);
   expect(report.targetCounts['decoded_rr'],216000);
  });
 },timeout:const Timeout(Duration(minutes:30)));
}
