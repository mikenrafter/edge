// WHY: v3 button promises cannot be implemented by redetecting a window.
// CLAIM(sleep-editor-v3-write): exact bounds, durable jobs, recoverable history.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../backup/backup_support.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  const day='2026-11-14';
  final a=DateTime(2026,11,13,23).millisecondsSinceEpoch~/1000;
  final b=DateTime(2026,11,14,7).millisecondsSinceEpoch~/1000;
  setUp(()async{
    env=await BackupEnv.create('editor-v3.db');db=await LocalDb.instance;
    await db.insert('day_result',{'day_id':day,'algo_version':123,'computed_at':1,'finalized':0,
      'window_json':jsonEncode({'onset_ms':a*1000,'offset_ms':b*1000}),
      'payload_json':jsonEncode({'date':day,'sleep_source':'auto','sleep':{'window':{'value':{'onset_ms':a*1000,'offset_ms':b*1000}}}})});
  });
  tearDown(()async=>env.dispose());
  test('moving main retains readable detected boundaries and exact reset survives reopen',()async{
    await writeSleepEdit(db,SleepEditPlan(day:day,window:(a+1200,b+600)));
    final repo=LocalRepositoryImpl(getProfileMap:()=>const{});
    final night=await (repo as dynamic).getSleepEditorMain(day);
    expect((night['detected_start'],night['detected_end']),(a,b));
    await writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:a+1200,end:b+600,
      main:true,source:'manual',action:SleepEntryAction.values.byName('resetDetected'))));
    final row=(await db.query('sleep_override')).single;
    expect((row['onset_ts'],row['offset_ts']),(a,b));
    expect((await db.query('sleep_edit_job')).single['revision'],2);
  });
  test('stages contract pins both selected bounds and preserves an unrelated nap',()async{
    final n=b+4*3600;
    await db.insert('sleep_nap',{'day_id':day,'start_ts':n,'end_ts':n+1800,'source':'manual','created_at':42});
    final before=await db.query('sleep_nap');
    await writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:a,end:b,
      main:true,source:'auto',action:SleepEntryAction.values.byName('stages'))));
    final row=(await db.query('sleep_override')).single;
    expect((row['onset_ts'],row['offset_ts']),(a,b));
    expect(await db.query('sleep_nap'),before);
    expect((await db.query('sleep_edit_job')).single['phase'],'queued');
  });
}
