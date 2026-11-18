// WHY: CLAIM(official-export-day-inventory) [P2 review F4; spec §6.2 "Compare by
// day and device"]. The per-day/device inventory is what P3's missing-data
// wording reads. Its day labels and windows follow the calendar the caller
// passes, the same one the prune cursor uses, never the process zone.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/prune_cursor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'archive_fixture.dart';
import 'process_zone.dart';
import 'support.dart';

const _fields=['day','device_id','source_live_parents','source_live_beats','mapped_live_parents','mapped_live_beats',
  'exact_archive_additions','exact_archive_beat_additions','target_parents','target_beats','coverage'];
List<List<Object?>> _view(List<Map<String,Object?>> days)=>[for(final d in days) [for(final f in _fields) d[f]]];

Future<(OfficialMapReport,String)> _map(Database db,String path,LocalCalendar calendar) async {
  await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
  await LocalDb.close();
  final report=await mapOfficialSnapshot(snapshotPath:path,outputPath:'${File(path).parent.path}/mapped.db',
    factory:databaseFactoryFfi,calendar:calendar);
  final o=await databaseFactoryFfi.openDatabase(report.path,options:OpenDatabaseOptions(readOnly:true));
  try {return (report,(await o.query('fork_transition_manifest')).single['payload_json'] as String);} finally {await o.close();}
}

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 final originalZone=Platform.environment['TZ'];
 setUp(() => setProcessZone(denverPosixZone)); // hostile: the calendar argument must win
 tearDown(() => setProcessZone(originalZone));
 // UTC epochs: Oct 22 12:00Z = 1792670400; each following day adds 86400.
 const a=1792670400,b=a+86400,c=a+2*86400,d=a+3*86400;
 test('inventory counts live, archive-added and refused input per UTC day and device',() async {
  await withFreshForkDb((db,path) async {
   await db.insert('decoded_onehz',parent(b,72));
   await db.insert('decoded_onehz',{...parent(c,60),'hr':'unsupported'}); // refused: no exact input survives
   await db.insert('decoded_onehz',parent(d,60));
   await db.insert('decoded_onehz',{...parent(d+1,61),'hr':'unsupported'}); // one of two refused: partial
   await bucket(db,1,[parent(a,55),parent(b,56)],[beat(a,0)]);
   final (report,manifest)=await _map(db,path,const FixedOffsetCalendar(0));
   final want=[
    ['2026-10-22','',0,0,0,0,1,1,1,1,'Exact input retained'],
    ['2026-10-23','',1,0,1,0,0,0,1,0,'Exact input retained'],
    ['2026-10-24','',1,0,0,0,0,0,0,0,'No exact input retained'],
    ['2026-10-25','',2,0,1,0,0,0,1,0,'Partial input retained'],
   ];
   expect(_view(report.days),want);
   expect(_view((jsonDecode(manifest)['days'] as List).cast<Map<String,Object?>>()),want,reason:'the manifest carries the same table');
  });
 },timeout:const Timeout(Duration(minutes:8)));
 test('day labels and windows follow the passed calendar, not the process zone',() async {
  await withFreshForkDb((db,path) async {
   // 2026-10-22 20:00Z is 01:30 on Oct 23 at +05:30 (and 14:00 on Oct 22 in the process zone).
   await db.insert('decoded_onehz',parent(a+8*3600,70));
   final (report,_)=await _map(db,path,const FixedOffsetCalendar(19800));
   expect(_view(report.days),[
    ['2026-10-23','',1,0,1,0,0,0,1,0,'Exact input retained'],
   ]);
  });
 },timeout:const Timeout(Duration(minutes:8)));
}
