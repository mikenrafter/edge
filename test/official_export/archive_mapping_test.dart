// WHY: CLAIM(official-export-accounted-identities), archive overlap may neither
// resurrect cleared beats nor let an arbitrary bucket win a conflicting claim.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'archive_fixture.dart';
import 'support.dart';

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 test('verified expansion, live-empty wins, conflicting claims, deletion and corruption', () async {
  await withFreshForkDb((db,path) async {
   // UTC epoch literals: 2026-10-22 noon, then complete subsequent days.
   const a=1792670400, b=1792756800, c=1792843200, d=1792929600, e=1793016000, f=1793102400, g=1793188800;
   await db.insert('decoded_onehz',parent(b,72));
   await db.insert('decoded_onehz',{...parent(f,60),'hr':'unsupported'}); // deliberately EMPTY live beats
   await bucket(db,0,[{...parent(a,70),'device_id':'ring-A'}],[],device:'ring-A');
   await bucket(db,1,[parent(a,55),parent(b,56),parent(c,57),parent(d,58),parent(f,59)],
       [beat(a,0),{...beat(a,1),'device_id':'ring-A'},beat(b,0),beat(c,0),beat(d,0),beat(e,0),beat(f,0)]);
   await bucket(db,2,[parent(c,99)],[beat(c,0)]); // contradictory exact claim
   await bucket(db,3,[parent(e,80)],[],corrupt:true);
   // A verified codec does not make a malformed parent admissible. Its beats
   // must be withheld with it, rather than becoming orphan target input.
   await bucket(db,4,[{...parent(g,60),'hr':'unsupported'}],[beat(g,0)]);
   await db.insert('sync_cursor',{'name':'decoded_pruned_before','value':'1793145600','updated_at':1});
   await db.insert('compute_freshness',{'key':'redrive_excluded_windows','payload_json':'[[1792929600,1792929601]]','updated_at':1});
   await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
   await LocalDb.close();
   final report=await mapOfficialSnapshot(snapshotPath:path,outputPath:'${File(path).parent.path}/mapped.db',factory:databaseFactoryFfi);
   expect(report.cursor.sec,1792713600); // first UTC midnight after a
   final out=await databaseFactoryFfi.openDatabase(report.path);
   try {
    expect((await out.query('decoded_onehz',where:"device_id=''",orderBy:'rec_ts')).map((r)=>[r['rec_ts'],r['hr']]).toList(),[[a,55],[b,72]]);
    expect((await out.query('decoded_onehz',where:"device_id='ring-A'")).single['hr'],70);
    expect(await out.query('decoded_rr',where:"device_id='ring-A'"),isEmpty,
      reason:'a foreign-device beat in another bucket cannot replace this parent\'s empty set');
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
