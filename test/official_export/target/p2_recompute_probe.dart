// Unchanged release code runs the ordered handoff on real mapped archive rows.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
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
void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 final report=<String,Object?>{};
 tearDownAll(() {File('${Platform.environment['OFFICIAL_PROBE_OUT']}/p2-recompute.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));});
 test('process zone is UTC (the epoch literals and day labels are UTC)',() {
  expect(DateTime.utc(2026,7,1).toLocal().timeZoneOffset,Duration.zero);
 });
 for(final mode in ['fresh receiver limitation','populated boundary guard','intervening light pass']) {
 final lightFirst=mode=='intervening light pass';
 final populated=mode=='populated boundary guard';
 test('archive-restored history: $mode',() async {
  sqfliteFfiInit();databaseFactory=databaseFactoryFfi;SharedPreferences.setMockInitialValues({});
  final root=await Directory.systemTemp.createTemp('p2_recompute_');
  PathProviderPlatform.instance=_Paths(root.path);LocalDb.dbName='${root.path}/official.db';
  final r=<String,Object?>{};report[mode]=r;
  try {
   var db=await LocalDb.instance;
   if(populated) {
    await LocalDb.putDayResult(dayId:'2026-10-23',algoVersion:124,
      payloadJson:'{"target_owned":true}',windowJson:'{}',rhr:54.0);
   }
   await LocalDb.importFromDbFile('${Platform.environment['CANDIDATES_DIR']}/archive_complete.db');
   expect((await db.query('day_result')).length,populated ? 1 : 0,
     reason:'the transport transfers zero day_result rows');
   if(populated) {expect((await LocalDb.dayResult('2026-10-23'))!['rhr'],54.0);}
   expect(await db.query('day_checkpoint'),isEmpty);
   expect((await db.query('compute_freshness',where:"key='substrate_archive_policy'")).single['payload_json'],'{"keep_days":-1}');
   expect(await LocalDb.decodedPrunedFor('2026-10-22'),isTrue);
   final edge=await LocalDb.getCursorInt(LocalDb.kDecodedPrunedBeforeCursor);
   expect(edge,1792713600);
   expect(DerivationEngine.windowTruncatedByPrune('2026-10-23',edge),isTrue);
   expect(DerivationEngine.windowTruncatedByPrune('2026-10-24',edge),isFalse);
   Future<int> parents() async=>Sqflite.firstIntValue(await db.rawQuery('SELECT count(*) FROM decoded_onehz WHERE rec_ts>=1792713600 AND rec_ts<1792886400'))!;
   expect(await parents(),172800);
   if(lightFirst) {
    final engine=DerivationEngine(log:(_){ });
    try {await engine.run(const Profile(ageYears:40,weightKg:75,heightCm:175,sex:'m'));}
    finally {engine.dispose();}
    r['after_light']={'parents':await parents(),'archive_buckets':(await db.query('substrate_archive',columns:['utc_day'])).length,
      'results':(await db.query('day_result',columns:['day_id','rhr','partial']))};
    expect(await parents(),0,reason:'bounded seven-day hold can prune imported but underived old days');
    expect(await db.query('substrate_archive',columns:['utc_day']),isNotEmpty,reason:'archive bytes survive but this release cannot rederive them');
   }
   final state=AppState.forTesting()..user={'age':40,'weight_kg':75.0,'height_cm':175.0,'sex':'m'};
   try {
    final outcome=await state.reanalyzeAll();
    r['outcome']={'days':outcome.days,'failed_days':outcome.failedDays,'error':outcome.error};
    expect(outcome.error,isNull);expect(outcome.failedDays,0);
    final day=await LocalDb.dayResult('2026-10-24');
    r['complete_day']=day;
    if(!lightFirst) {
     expect(day,isNotNull,reason:'fully restored day before fork live cursor must be derived');
     expect(day!['algo_version'],124);
     expect(day['rhr'],60.0,reason:'target-owned nocturnal result, not a copied algorithm stamp');
    } else {
     expect(day,isNull,reason:'intervening light prune loses derivability until the original file is reimported');
    }
    final boundary=await LocalDb.dayResult('2026-10-23');
    r['boundary_day']=boundary;
    if(populated) {
     expect(boundary?['rhr'],54.0,reason:'the receiver protects an existing real night on a truncated window');
     expect(boundary?['payload_json'],'{"target_owned":true}');
    } else if(!lightFirst) {
     // Documented receiver limitation, NOT an abstention certification test.
     // v0.12.2 derivation_engine.dart:7177-7188 returns only if an existing
     // night has a scalar. No cursor value can make that true on a fresh DB.
     expect(boundary?['rhr'],60.0,reason:'pin actual v0.12.2 fresh-boundary behavior');
     r['receiver_limitation']={
       'guard':'lib/compute/derivation_engine.dart:7177-7188',
       'tag':'v0.12.2','actual':'fresh truncated boundary derives RHR 60; guard protects existing nights only',
     };
    } else {
     expect(boundary,isNull);
    }
   } finally {state.dispose();}
   await LocalDb.close();db=await LocalDb.instance;
   expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single,'ok');
  } finally {await LocalDb.close();await root.delete(recursive:true);}
 },timeout:const Timeout(Duration(minutes:40)));
 }
}
