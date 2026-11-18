// WHY: CLAIM(official-export-accounted-identities), archive overlap may neither
// resurrect cleared beats nor let an arbitrary bucket win a conflicting claim.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support.dart';

ArchiveTable table(List<Map<String,Object?>> rows) {
  final b = ArchiveTableBuilder()..addRows(rows); return b.build();
}
Future<void> bucket(Database db, int day, List<Map<String,Object?>> parents,
    List<Map<String,Object?>> beats, {bool corrupt = false}) async {
  final w = SubstrateArchiveCodec.encodeMergeVerify(ArchiveBucket(table(parents),table(beats)));
  await db.insert('substrate_archive', {'device_id':'', 'utc_day':day,
    'codec':1, 'from_ts':w.fromTs ?? 1, 'to_ts':w.toTs ?? 1, 'onehz_rows':parents.length,
    'rr_rows':beats.length,'raw_bytes':w.rawBytes,'fingerprint':corrupt ? 1 : w.fingerprint,
    'blob':w.blob,'created_at':1,'updated_at':1});
}
Map<String,Object?> parent(int sec, int hr) => {'device_id':'','ts_ms':sec*1000,'rec_ts':sec,'counter':sec,'hr':hr};
Map<String,Object?> beat(int sec, int n) => {'device_id':'','ts_ms':sec*1000,'rec_ts':sec,'beat_index':n,'rr_ms':800.0,'rr_ts_ms':sec*1000+n*800};
void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 test('verified expansion, live-empty wins, conflicting claims, deletion and corruption', () async {
  await withFreshForkDb((db,path) async {
   // UTC epoch literals: 2026-10-22 noon, then complete subsequent days.
   const a=1792670400, b=1792756800, c=1792843200, d=1792929600, e=1793016000;
   await db.insert('decoded_onehz',parent(b,72)); // deliberately EMPTY live beats
   await bucket(db,1,[parent(a,55),parent(b,56),parent(c,57),parent(d,58)],
       [beat(a,0),beat(b,0),beat(c,0),beat(d,0),beat(e,0)]);
   await bucket(db,2,[parent(c,99)],[beat(c,0)]); // contradictory exact claim
   await bucket(db,3,[parent(e,80)],[],corrupt:true);
   await db.insert('sync_cursor',{'name':'decoded_pruned_before','value':'1793145600','updated_at':1});
   await db.insert('compute_freshness',{'key':'redrive_excluded_windows','payload_json':'[[1792929600,1792929601]]','updated_at':1});
   await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
   await LocalDb.close();
   final report=await mapOfficialSnapshot(snapshotPath:path,outputPath:'${File(path).parent.path}/mapped.db',factory:databaseFactoryFfi);
   expect(report.cursor.sec,1792713600); // first UTC midnight after a
   final out=await databaseFactoryFfi.openDatabase(report.path);
   try {
    expect((await out.query('decoded_onehz',orderBy:'rec_ts')).map((r)=>[r['rec_ts'],r['hr']]).toList(),[[a,55],[b,72]]);
    expect((await out.query('decoded_rr')).map((r)=>r['rec_ts']).toList(),[a]);
    expect(await out.query('day_result'),isEmpty);
    expect(await out.query('substrate_archive'),isEmpty);
    final manifest=(await out.query('fork_transition_manifest')).single['payload_json'] as String;
    for(final reason in ['live parent owns complete beat set','conflicting archive claims','deleted input window','archive orphan beat','fingerprint mismatch']) {
      expect(manifest,contains(reason));
    }
   } finally {await out.close();}
  });
 }, timeout:const Timeout(Duration(minutes:8)));
}
