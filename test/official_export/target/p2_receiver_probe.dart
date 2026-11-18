// Copied into the verified, unmodified tag. Only host paths/preferences are
// substituted. All import, reanalysis, retention and model code is the release.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/step_calibration_fit.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform {
 _Paths(this.root); final String root;
 @override Future<String?> getTemporaryPath() async=>root;
 @override Future<String?> getApplicationDocumentsPath() async=>root;
 @override Future<String?> getApplicationSupportPath() async=>root;
}
String q(String name)=>'"${name.replaceAll('"','""')}"';
Future<int> count(DatabaseExecutor db,String table) async=>Sqflite.firstIntValue(await db.rawQuery('SELECT count(*) FROM ${q(table)}'))!;

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 final report=<String,Object?>{'fork_head':Platform.environment['OFFICIAL_FORK_HEAD'],
  'fork_status_porcelain':Platform.environment['OFFICIAL_FORK_STATUS']};
 tearDownAll(() {
  final out=Directory(Platform.environment['OFFICIAL_PROBE_OUT']!)..createSync(recursive:true);
  File('${out.path}/p2-receiver.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
 });
 test('target file open, repair and reopen accept a disposable copy',() async {
  sqfliteFfiInit();databaseFactory=databaseFactoryFfi;SharedPreferences.setMockInitialValues({});
  final work=Platform.environment['OWNER_WORK']!;
  final dir=await Directory('$work/target-open').create(recursive:true);
  final copy=await File('$work/policy.db').copy('${dir.path}/official.db');
  PathProviderPlatform.instance=_Paths(dir.path);LocalDb.dbName=copy.path;
  try {
   for(var pass=0;pass<2;pass++) {
    final db=await LocalDb.instance;
    expect(await db.getVersion(),62);expect(LocalDb.lastRebuild,isNull);
    expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single,'ok');
    expect(await count(db,'day_result'),0);expect(await count(db,'day_checkpoint'),0);
    final imported=(await db.rawQuery('PRAGMA table_info(day_result)')).singleWhere((r)=>r['name']=='imported');
    expect(imported['notnull'],1);expect(imported['dflt_value'],'0');
    await LocalDb.close();
   }
   report['file_open_reopen']='passed';
  } finally {await LocalDb.close();await dir.delete(recursive:true);}
 },timeout:const Timeout(Duration(minutes:10)));
 for(final populated in [false,true]) {
  test('production owner file, ${populated ? 'populated' : 'fresh'} receiver',() async {
   sqfliteFfiInit();databaseFactory=databaseFactoryFfi;
   SharedPreferences.setMockInitialValues({'notif_health':false,'notif_recovery':false,'notif_auto_detect':false,
    'notif_movement':false,'notif_water':false,'notif_stepgoal':false,'notif_checkin':false});
   final root=await Directory('${Platform.environment['OWNER_WORK']}/receiver-${populated ? 'populated':'fresh'}').create(recursive:true);
   PathProviderPlatform.instance=_Paths(root.path);LocalDb.dbName='${root.path}/official.db';
   final r=<String,Object?>{};report[populated ? 'populated':'fresh']=r;
   try {
    var db=await LocalDb.instance;
    expect(kLiveStepCounterVersion,2);
    final path='${Platform.environment['OWNER_WORK']}/policy.db';
    if(populated) {
     await LocalDb.upsertDevice(adapterId:'whoop',remoteId:'target-handle');
     await db.update('device',{'wearing':1,'wearing_set_ts':99},where:"id=''");
     await db.insert('journal',{'date':'2001-01-01','tags_json':'[]','note':'target-only','updated_at':999});
     await db.insert('day_result',{'day_id':'2001-01-01','algo_version':124,'payload_json':'{"target":true}',
      'computed_at':1,'finalized':1,'rhr':66.0});
     await db.insert('compute_freshness',{'key':'substrate_archive_policy','payload_json':'{"keep_days":365}','updated_at':1});
     await db.insert('sync_cursor',{'name':'decoded_pruned_before','value':'1794294000','updated_at':1});
    }
    final watch=Stopwatch()..start();
    if(populated) {
      final incoming=await databaseFactoryFfi.openDatabase(path,options:OpenDatabaseOptions(readOnly:true));
      final stop=(await incoming.rawQuery('SELECT device_id,ts_ms FROM decoded_onehz ORDER BY rowid LIMIT 1 OFFSET 10000')).single;
      await incoming.close();
      final stopDevice=(stop['device_id'] as String).replaceAll("'","''");
      await db.execute("CREATE TRIGGER p2_interrupt BEFORE INSERT ON decoded_onehz WHEN new.device_id='$stopDevice' AND new.ts_ms=${stop['ts_ms']} BEGIN SELECT RAISE(ABORT,'p2 deliberate interruption'); END");
      Object? interrupted;
      // Exercise the release's existing paged fallback. Normal ATTACH bulk
      // import is table-atomic; the retry below uses that normal path again.
      LocalDb.debugRowByRowMerge=true;
      try {await LocalDb.importFromDbFile(path);} catch(e) {interrupted=e;}
      finally {LocalDb.debugRowByRowMerge=false;}
      expect(interrupted,isNotNull);
      final partial=await count(db,'decoded_onehz');
      expect(partial,greaterThan(0));
      r['interrupted_committed_parents']=partial;
      await db.execute('DROP TRIGGER p2_interrupt');
    }
    await LocalDb.importFromDbFile(path);r['import_ms']=watch.elapsedMilliseconds;
    expect(await db.getVersion(),62);expect(LocalDb.lastRebuild,isNull);
    expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single,'ok');
    expect(await db.rawQuery('PRAGMA foreign_key_check'),isEmpty);
    expect(await count(db,'day_result'),populated ? 1:0);
    expect(await count(db,'day_checkpoint'),0);
    await db.execute('ATTACH DATABASE ? AS payload',[path]);
    // Independent typed-value oracle for every decoded column, including the
    // release's three intentional normalizations (db.dart importer).
    for(final table in ['decoded_onehz','decoded_rr','samples','band_events','band_battery','events',
      'device_coverage','external_hr','imported_measurement','imported_workout','ecg_reading','ecg_reading_packet',
      'ecg_raw_packet','workout_route','workout_split','session_sensor','strength_set','food_entry','food_def',
      'raw_archive_frames','med_dose','med_def','journal_metric','lab_result','journal_field_def','lab_marker_def']) {
     final columns=[for(final c in await db.rawQuery('PRAGMA table_info(${q(table)})')) c['name'] as String];
     String expected(String c) {
      if(table=='decoded_onehz' && {'on_wrist','hr_valid'}.contains(c)) return 'NULL';
      if(table=='decoded_onehz' && c=='skin_temp_c') return 'CASE WHEN skin_temp_c<=-49.995 THEN NULL ELSE skin_temp_c END';
      return q(c);
     }
     final incoming=await db.rawQuery('SELECT ${[for(final c in columns) '${expected(c)},typeof(${expected(c)})'].join(',')} FROM payload.${q(table)} '
       'EXCEPT SELECT ${[for(final c in columns) '${q(c)},typeof(${q(c)})'].join(',')} FROM main.${q(table)} LIMIT 1');
     expect(incoming,isEmpty,reason:'$table typed source value conservation');
     expect(await count(db,table),Sqflite.firstIntValue(await db.rawQuery('SELECT count(*) FROM payload.${q(table)}')),reason:'$table exact row count');
    }
    r['per_day_device_before']=await db.rawQuery('SELECT device_id,rec_ts/86400 AS utc_day,count(*) AS parents FROM decoded_onehz GROUP BY device_id,rec_ts/86400 ORDER BY device_id,utc_day');
    r['beats_before']=await count(db,'decoded_rr');
    r['cursor']=await LocalDb.getCursorInt(LocalDb.kDecodedPrunedBeforeCursor);
    final incomingCursor=await db.rawQuery("SELECT value FROM payload.sync_cursor WHERE name='decoded_pruned_before'");
    final expectedCursor=incomingCursor.isEmpty ? null:int.parse(incomingCursor.single['value'] as String);
    expect(r['cursor'],populated ? 1794294000:expectedCursor);
    r['policy']=await db.query('compute_freshness',where:"key='substrate_archive_policy'");
    await db.execute('DETACH DATABASE payload');
    final before=await count(db,'decoded_onehz');
    // Repeat import proves receiver idempotence after a committed-page retry.
    await LocalDb.importFromDbFile(path);
    expect(await count(db,'decoded_onehz'),before);
    final oldSessions=await db.rawQuery('SELECT id,start_ts,end_ts FROM sessions WHERE end_ts IS NOT NULL ORDER BY start_ts LIMIT 1');
    final repository=LocalRepositoryImpl(getProfileMap:()=>{'age':40,'weight_kg':75.0,'height_cm':175.0,'sex':'m'});
    Future<void> readOldWorkout(String stage) async {
      if(oldSessions.isEmpty) {r['workout/$stage']='no supported completed source workout';return;}
      final stored=oldSessions.single;
      final detail=await repository.getWorkout(stored['id'] as String);
      expect(detail,isNotEmpty);expect(detail['id'],stored['id']);
      expect(detail['start_ts'],stored['start_ts']);expect(detail['end_ts'],stored['end_ts']);
      r['workout/$stage']={for(final key in ['id','start_ts','end_ts','calories','strain','avg_hr','hrr_bpm']) key:detail[key]};
    }
    await readOldWorkout('before_reanalysis');
    if(populated) {
      expect((await db.query('device',where:"id=''")).single['remote_id'],'target-handle');
      expect((await db.query('device',where:"id=''")).single['wearing'],1);
      expect((await db.query('journal',where:"date='2001-01-01'")).single['note'],'target-only');
      expect((await db.query('day_result',where:"day_id='2001-01-01'")).single['rhr'],66.0);
      expect((await db.query('compute_freshness',where:"key='substrate_archive_policy'")).single['payload_json'],'{"keep_days":365}');
    } else {
      // Host-only constructor bypasses platform startup; reanalyzeAll itself is
      // unchanged and uses the real engine. Explicit proof profile, not owner identity.
      final state=AppState.forTesting();
      final restoredProfile=(await SharedPreferences.getInstance()).getString('local_profile_json');
      state.user=restoredProfile==null ? {'age':40,'weight_kg':75.0,'height_cm':175.0,'sex':'m'}
          : (jsonDecode(restoredProfile) as Map).cast<String,dynamic>();
      r['profile_source']=restoredProfile==null ? 'explicit proof profile; owner profile absent from SQL artifact':'restored profile from owner artifact';
      watch.reset();
      try {
       final outcome=await state.reanalyzeAll();
       r['reanalysis']={'days':outcome.days,'failed_days':outcome.failedDays,'error':outcome.error,
        'elapsed_ms':watch.elapsedMilliseconds,'proof_profile':state.user};
       expect(outcome.error,isNull);expect(outcome.failedDays,0);
       expect(outcome.days,greaterThan(0));
       final rows=await db.query('day_result');
       expect(rows,isNotEmpty);expect(rows.every((r)=>r['algo_version']==124),isTrue);
       r['target_results']=[for(final row in rows) {'day':row['day_id'],'partial':row['partial'],'rhr':row['rhr'],'computed_at':row['computed_at']}];
      } finally {state.dispose();}
      // Normal post-handoff light pass/maintenance runs only after completion.
      final engine=DerivationEngine(log:(_){ });
      try {await engine.run(const Profile(ageYears:40,weightKg:75,heightCm:175,sex:'m'));}
      finally {engine.dispose();}
      r['per_day_device_after_maintenance']=await db.rawQuery('SELECT device_id,rec_ts/86400 AS utc_day,count(*) AS parents FROM decoded_onehz GROUP BY device_id,rec_ts/86400 ORDER BY device_id,utc_day');
      await readOldWorkout('after_maintenance');
    }
    await LocalDb.close();db=await LocalDb.instance;
    expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single,'ok');
    expect(LocalDb.lastRebuild,isNull);
    r['reopened_results']=await count(db,'day_result');
   } finally {await LocalDb.close();await root.delete(recursive:true);}
  },timeout:const Timeout(Duration(minutes:60)));
 }
}
