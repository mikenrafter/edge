// WHY: SQL snapshot boundary excludes later writes; strict extras remain
// independently accountable and large BLOBs never cross a cursor window.
// CLAIM(official-export-source-unchanged); catches: copy live path; omit files;
// read a whole BLOB; include transactions after capture.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/snapshot.dart';
import 'package:openstrap_edge/data/official_export/session.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support.dart';
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
   await db.insert('journal',{'day_id':'2026-10-01','note':'before'});
   final session=Directory('${root.path}/session')..createSync();
   final snapshot=await LocalDbExportSnapshot().capture(session,ExportSpaceBudget(source:Plenty()),ExportCancellation());
   await db.insert('journal',{'day_id':'2026-10-02','note':'after'});
   final copy=await databaseFactoryFfi.openDatabase(snapshot.path);
   try{
    expect((await copy.query('journal')).map((r)=>r['day_id']),['2026-10-01']);
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
    await writeBackupExtras(path,audit:audit);
    expect((await db.rawQuery('SELECT length(bytes) n FROM backup_files')).single['n'],file.lengthSync());
  });
 });
}
