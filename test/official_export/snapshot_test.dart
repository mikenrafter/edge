// WHY: SQL snapshot boundary excludes later writes; strict extras remain
// independently accountable and large BLOBs never cross a cursor window.
// CLAIM(official-export-source-unchanged); catches: copy live path; omit files;
// read a whole BLOB; include transactions after capture.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/official_export/snapshot.dart';
import 'package:openstrap_edge/data/official_export/session.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Sqflite, DatabaseExecutor;
import 'support.dart';
import 'session_fixture.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
class UnreadablePreferences extends Fake implements SharedPreferences {
 @override Future<void> reload()async{throw StateError('unavailable');}
}
class HookSpace implements ExportFreeSpace {
 HookSpace(this.hook);
 final Future<void> Function(int call) hook;
 int calls=0;
 @override Future<int> readAvailableBytes()async{await hook(++calls);return 1<<40;}
}
class Plenty implements ExportFreeSpace {@override Future<int> readAvailableBytes()async=>1<<40;}
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 test('real snapshot freezes SQL and includes a 3 MiB finalized attachment',()async{
  await withFreshForkDb((db,path)async{
   final root=File(path).parent;
   final recordings=Directory('${root.path}/device_lab/imu')..createSync(recursive:true);
   final bytes=List<int>.generate(3*1024*1024+7,(i)=>i%251);
   File('${recordings.path}/saved.jsonl').writeAsBytesSync(bytes);
   File('${recordings.path}/unfinished.part').writeAsStringSync('unfinished');
   await db.insert('journal',{'date':'2026-10-01','tags_json':'[]','note':'before','updated_at':1});
   final session=Directory('${root.path}/session')..createSync();
   final snapshot=await LocalDbExportSnapshot().capture(session,ExportSpaceBudget(source:Plenty()),ExportCancellation());
   await db.insert('journal',{'date':'2026-10-02','tags_json':'[]','note':'after','updated_at':2});
   final copy=await databaseFactoryFfi.openDatabase(snapshot.path);
   try{
    expect((await copy.query('journal')).map((r)=>r['date']),['2026-10-01']);
    expect((await db.query('journal')).length,2);
    final chunk=(await copy.rawQuery('SELECT length(bytes) n, substr(bytes,3145729,7) tail FROM backup_files')).single;
    expect(chunk['n'],3145735);expect(chunk['tail'],bytes.sublist(3145728));
    expect(snapshot.omissions.single['reason'],'recording is unfinished');
    expect(await copy.getVersion(),snapshot.schema);
   }finally{await copy.close();}
  });
 });
 test('unreadable preference store does not silently discard saved files',()async{
  await withFreshForkDb((db,path)async{
    // Positive fixture and strict audit through existing owner.
    final file=File('${File(path).parent.path}/coach_s_fixture.json')..writeAsStringSync('{"note":"saved"}');
    final audit=BackupExtrasAudit(beforeWrite:(_)async{},checkCancelled:(){});
    await writeBackupExtras(path,audit:audit,prefs:UnreadablePreferences());
    expect(audit.omissions.single,{'family':'settings','identity':'portable preferences','reason':'preference store unavailable'});
    expect((await db.rawQuery('SELECT length(bytes) n FROM backup_files')).single['n'],file.lengthSync());
  });
 });
 test('low space omits finalized files by identity and saves the safe SQL remainder',()async {
  await withFreshForkDb((db,path)async {
    final root=File(path).parent;
    final recordings=Directory('${root.path}/device_lab/imu')..createSync(recursive:true);
    File('${recordings.path}/large.jsonl').writeAsBytesSync(List.filled(3*1024*1024,7));
    final source=LocalDbExportSnapshot();final estimate=await source.estimate();
    final free=Space()..available=64*1024*1024+estimate.peakBytes-4*estimate.extrasBytes+1024*1024;
    final destination=Destination(Directory('${root.path}/saved')..createSync(),free);
    final coordinator=OfficialExportCoordinator();
    final result=await coordinator.export(snapshot:source,privateRoot:Directory('${root.path}/private'),destination:destination,
      space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>false));
    expect(result,isA<OfficialExportSavedWithOmissions>(),reason:result is OfficialExportFailed?'${result.reason}':result.toString());
    expect(coordinator.extrasOmissions,[{'family':'saved files','identity':'device_lab/imu/large.jsonl','reason':'omitted to preserve space for new recordings'}]);
    expect(destination.creates,1);
    expect(File('${recordings.path}/large.jsonl').lengthSync(),3*1024*1024);
  });
 });
 // WHY: spec 6.2 / review F10. The capture holds one DEFERRED read transaction
 // for its whole copy; a band commit while it is open must neither block nor
 // leak into the snapshot. catches: BEGIN IMMEDIATE; a rollback-journal source.
 // Harness limit: sqflite_common_ffi serves every connection from one isolate, so
 // this proves the write commits between statements of the open read transaction,
 // not during one long INSERT...SELECT (that stays device-trial evidence).
 test('a band commit during capture is not blocked and stays out of the snapshot',()async{
  await withFreshForkDb((db,path)async{
   expect((await db.rawQuery('PRAGMA journal_mode')).single.values.single,'wal');
   RawRecord rec(int n)=>RawRecord(counter:n,packetType:0x2F,hex:'2f18aabbccdd',capturedAt:1750000000000+n,recTs:1750000000+n);
   Future<void> commit(int n)=>LocalDb.commitSyncBatch([rec(n)],<Sample?>[Sample(tsEpoch:1750000000+n,counter:n,hr:60)]);
   Future<int> count(DatabaseExecutor d)async=>Sqflite.firstIntValue(await d.rawQuery('SELECT count(*) FROM decoded_onehz'))!;
   await commit(1);
   final order=[for(final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY rowid"))r['name'] as String];
   final target=order.indexOf('decoded_onehz');
   // The Nth hook call precedes the copy of table N-1: at least one table is
   // already copied, and the written table is copied only after the write.
   expect(target,greaterThan(0));
   final before=await count(db);
   expect(before,greaterThan(0));
   var wrote=false;
   final free=HookSpace((call)async{
    if(call!=target+1)return;
    await commit(2).timeout(const Duration(seconds:5));
    wrote=true;
   });
   final session=Directory('${File(path).parent.path}/session')..createSync();
   final snapshot=await LocalDbExportSnapshot().capture(session,ExportSpaceBudget(source:free),ExportCancellation());
   expect(wrote,isTrue);
   expect(await count(db),greaterThan(before),reason:'the write committed on the live store');
   final copy=await databaseFactoryFfi.openDatabase(snapshot.path);
   try{
    expect(await count(copy),before,reason:'the snapshot keeps its read point');
    expect((await copy.rawQuery('PRAGMA integrity_check')).single.values.single,'ok');
   }finally{await copy.close();}
   await commit(3);
   expect(await count(db),greaterThan(before+1));
  });
 },timeout:const Timeout(Duration(minutes:2)));

}
