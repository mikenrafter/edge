// WHY: optional recovery must use the existing journaled fork importer, carry
// original results/unsupported facts, and restore a large attachment byte-exact.
// CLAIM(official-export-saved-bytes); catches: encrypt mapped SQL twice; second
// passphrase prompt; omit attachment; bypass normal importer/reload notices.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/official_export/session.dart';
import 'package:openstrap_edge/data/official_export/snapshot.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'package:openstrap_edge/import/backup_crypto.dart';
import '../backup/backup_support.dart';
import 'session_fixture.dart';
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 test('one-passphrase recovery restores through the actual fork importer twice',()async{
  final env=await BackupEnv.create('p3_recovery.db');
  try{
   await env.seedData();
   final db=await LocalDb.instance;
   await db.insert('track_event',{'id':'event-1','track_id':'caffeine','date':'2026-10-24','source_kind':'manual','source_id':'user'});
   final bytes=List<int>.generate(3*1024*1024+7,(i)=>i%251);
   await env.writeImu('saved.jsonl',bytes);
   final prefs=await SharedPreferences.getInstance();await prefs.setBool('coach_api_key_present',true);
   final free=Space();final dest=Destination(Directory('${env.root.path}/saved')..createSync(),free);
   var prompts=0;
   final coordinator=OfficialExportCoordinator();
   final result=await coordinator.export(snapshot:LocalDbExportSnapshot(),privateRoot:Directory('${env.root.path}/private'),destination:dest,
    space:ExportSpaceBudget(source:free),prompts:Prompts(()async{prompts++;return 'pw';},(_)async=>true)) as OfficialExportSaved;
   expect(prompts,1);expect(result.recoveryStatus,RecoveryStatus.saved);
   final recovery=File('${env.root.path}/recovery.db');
   await decryptBackupFile(File(result.recovery!.file.path),recovery,'pw');
   await env.wipe();
   final summary=await LocalDb.importFromDbFile(recovery.path);
   expect(summary.needsReentry,contains('coach_api_key'));
   final restored=await LocalDb.instance;
   expect((await restored.query('track_event',where:"id='event-1'")).single['source_id'],'user');
   expect((await restored.query('day_result',where:"algo_version=100")).single['finalized'],1);
   expect(env.imuFile('saved.jsonl').readAsBytesSync(),bytes);
   await LocalDb.importFromDbFile(recovery.path);
   expect((await restored.query('track_event',where:"id='event-1'")).length,1);
   expect(env.imuFile('saved.jsonl').readAsBytesSync(),bytes);
  }finally{await env.dispose();}
 },timeout:const Timeout(Duration(minutes:5)));
}
