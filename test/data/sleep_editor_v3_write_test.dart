// WHY: v3 button promises cannot be implemented by redetecting a window.
// CLAIM(sleep-editor-v3-write): exact bounds, durable jobs, recoverable history.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
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
  test('malformed retained snapshots degrade to unknown instead of breaking the read',()async{
    for(final raw in ['{broken','[]','null','42']){
      expect(await sleepEditorPayload(raw),isEmpty);
      expect(sleepEditorDetected(await sleepEditorPayload(raw)),isNull);
    }
  });
  test('moving main retains readable detected boundaries and exact reset survives reopen',()async{
    await writeSleepEdit(db,SleepEditPlan(day:day,window:(a+1200,b+600)));
    final repo=LocalRepositoryImpl(getProfileMap:()=>const{});
    final night=await (repo as dynamic).getSleepEditorMain(day);
    expect((night['detected_start'],night['detected_end']),(a,b));
    await writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:a+1200,end:b+600,
      main:true,source:'manual',action:SleepEntryAction.values.byName('resetDetected'))));
    await LocalDb.close();db=await LocalDb.instance;
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
  test('new actions and retained detection roll back with their queued job',()async{
    await expectLater(db.transaction((tx)async{
      await writeSleepEditInTransaction(tx,SleepEditPlan(day:day,entry:SleepEntryEdit(
        start:a,end:b,main:true,source:'auto',action:SleepEntryAction.remove)));
      expect((await tx.query('sleep_override')).single['source'],'rejected');
      expect((await tx.query('sleep_edit_job')).single['phase'],'queued');
      throw StateError('rollback');
    }),throwsStateError);
    expect(await db.query('sleep_override'),isEmpty);
    expect(await db.query('sleep_edit_job'),isEmpty);
  });
  test('empty Save preserves separate overlapping entries and creates no job',()async{
    await db.insert('sleep_nap',{'day_id':day,'start_ts':a+600,'end_ts':a+1800,'source':'legacy','created_at':42,
      'payload_json':jsonEncode({'source':'legacy','start':a+600,'end':a+1800,'duration_min':15})});
    final before=await db.query('sleep_nap');
    await writeSleepEdit(db,const SleepEditPlan(day:day));
    expect(await db.query('sleep_nap'),before);
    expect(await db.query('sleep_override'),isEmpty);
    expect(await db.query('sleep_edit_job'),isEmpty);
  });
  test('stale detected main action refuses the entire write',()async{
    await expectLater(writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(
      start:a+60,end:b,main:true,source:'auto',action:SleepEntryAction.stages))),throwsA(isA<SleepEditInvalid>()));
    expect(await db.query('sleep_override'),isEmpty);
    expect(await db.query('sleep_edit_job'),isEmpty);
  });

  for(final version in [88,LocalDb.schemaVersion]) {
    test('schema $version adds or heals detected snapshot column without changing old bounds',()async{
      await db.insert('sleep_override',{'day_id':day,'onset_ts':a,'offset_ts':b,'source':'manual','created_at':42});
      await db.execute('ALTER TABLE sleep_override DROP COLUMN payload_json');
      await db.setVersion(version);await LocalDb.close();db=await LocalDb.instance;
      final row=(await db.query('sleep_override')).single;
      expect((row['onset_ts'],row['offset_ts'],row['source']),(a,b,'manual'));
      expect(row.containsKey('payload_json'),true);
      expect(row['payload_json'],isNull,reason:'Unavailable detection stays unknown');
      await LocalDb.close();db=await LocalDb.instance;
      expect(await db.query('sleep_override'),[row],reason:'Repair must be idempotent');
    });
  }
  test('detected snapshots survive full export, restore and repeated import',()async{
    await writeSleepEdit(db,SleepEditPlan(day:day,window:(a+600,b+300)));
    final before=(await db.query('sleep_override')).single;
    final exported=await LocalDb.exportCopy();
    await db.delete('sleep_override');
    await LocalDb.importFromDbFile(exported);db=await LocalDb.instance;
    expect((await db.query('sleep_override')).single,before);
    await LocalDb.importFromDbFile(exported);db=await LocalDb.instance;
    expect(await db.query('sleep_override'),[before]);
  });

  test('removing and restoring a separately stored overlapping nap preserves both entries',()async{
    final start=a+600,end=a+2400;
    final snapshot={'source':'legacy','start':start,'end':end,'duration_min':20};
    await db.insert('sleep_nap',{'day_id':'2026-11-13','start_ts':start,'end_ts':end,
      'source':'legacy','created_at':42,'payload_json':jsonEncode(snapshot)});
    final night=await db.query('day_result');
    await writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:start,end:end,
      main:false,source:'legacy',action:SleepEntryAction.remove)));
    await LocalDb.close();db=await LocalDb.instance;
    await writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:start,end:end,
      main:false,source:'rejected',action:SleepEntryAction.resetDetected)));
    final restored=(await db.query('sleep_nap')).single;
    expect((restored['start_ts'],restored['end_ts'],restored['source']),(start,end,'legacy'));
    expect(sleepEditorDetected(await sleepEditorPayload(restored['payload_json'])),snapshot);
    expect(await db.query('day_result'),night);
  });

  test('restore refuses a neighbour changed since removal without changing the receipt',()async{
    final start=a+600,end=a+2400;
    await db.insert('sleep_nap',{'day_id':'2026-11-13','start_ts':start,'end_ts':end,
      'source':'legacy','created_at':42,'payload_json':jsonEncode({'source':'legacy','start':start,'end':end})});
    await writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:start,end:end,
      main:false,source:'legacy',action:SleepEntryAction.remove)));
    await db.update('day_result',{'window_json':jsonEncode({'onset_ms':(a+60)*1000,'offset_ms':b*1000})});
    final before=await db.query('sleep_nap'),jobs=await db.query('sleep_edit_job');
    await expectLater(writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:start,end:end,
      main:false,source:'rejected',action:SleepEntryAction.resetDetected))),throwsA(isA<SleepEditInvalid>()));
    expect(await db.query('sleep_nap'),before);
    expect(await db.query('sleep_edit_job'),jobs);
  });
  test('resetting a moved detected nap fixes both bounds and requests canonical stages',()async{
    final start=b+3600,end=start+1800;
    await writeSleepEdit(db,SleepEditPlan(day:day,naps:[NapWrite(start:start+600,end:end+300,
      fromStart:start,fromEnd:end)]));
    await writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:start+600,end:end+300,
      main:false,source:'manual',action:SleepEntryAction.resetDetected)));
    final row=(await db.query('sleep_nap',where:"source != 'rejected'")).single;
    expect((row['start_ts'],row['end_ts'],row['source']),(start,end,'confirmed'));
    expect((await sleepEditorPayload(row['payload_json']))['_stage_only'],true);
    expect((await db.query('sleep_edit_job')).single['revision'],2);
  });

  test('reopening while queued uses saved main bounds over a stale caller window and Save stays empty',()async{
    await writeSleepEdit(db,SleepEditPlan(day:day,window:(a+600,b+300)));
    final repo=LocalRepositoryImpl(getProfileMap:()=>const{});
    final loaded=await SleepEditorData.load(repo,day,window:(a,b));
    expect((loaded.main.start,loaded.main.end),(a+600,b+300));
    expect(planOf(loaded,[loaded.main,...loaded.naps]).isEmpty,true);
  });

  test('a moved nap owns its detected ghost; the suppression ledger row is not a second removed block',()async{
    final start=b+3600,end=start+1800;
    final snapshot={'start':start,'end':end,'source':'legacy','duration_min':20};
    await db.insert('sleep_nap',{'day_id':day,'start_ts':start,'end_ts':end,'source':'legacy',
      'created_at':42,'payload_json':jsonEncode(snapshot)});
    await writeSleepEdit(db,SleepEditPlan(day:day,naps:[NapWrite(start:start+600,end:end+300,
      fromStart:start,fromEnd:end,fromSource:'legacy')]));
    final repo=LocalRepositoryImpl(getProfileMap:()=>const{});
    final before=await db.query('sleep_nap');
    final read=await repo.getSleepEditorNaps(day);
    final entries=read['naps'] as List;
    expect(entries,hasLength(1));
    expect((entries.single['start'],entries.single['end']),(start+600,end+300));
    expect((entries.single['detected_start'],entries.single['detected_end']),(start,end));
    expect(await db.query('sleep_nap'),before,reason:'The read never merges or deletes persisted rows');
    await writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:start+600,end:end+300,
      main:false,source:'manual',action:SleepEntryAction.remove)));
    expect((await repo.getSleepEditorNaps(day))['naps'],hasLength(1));
    await writeSleepEdit(db,SleepEditPlan(day:day,entry:SleepEntryEdit(start:start+600,end:end+300,
      main:false,source:'rejected',action:SleepEntryAction.resetDetected)));
    final restored=(await db.query('sleep_nap')).single;
    expect((restored['start_ts'],restored['end_ts'],restored['source']),(start,end,'legacy'));
    expect(sleepEditorDetected(await sleepEditorPayload(restored['payload_json'])),snapshot);
  });

}
