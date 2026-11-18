// WHY: nap edits must never invalidate an in-flight night or release its pin.
// CLAIM(sleep-block-one-queue); catches routing naps through the night counter.
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_nap_export.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/app_state.dart';
import '../support/test_callable.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';

// Same independent moving/still fixture as nap_attribution_test: a ramp
// survives the detector's rolling median; the still block has a real HR dip.
Substrate napDay(int napStart) {
  const length=6*3600;
  final hr=<int>[],ax=<double>[],ay=<double>[],az=<double>[];
  for(var i=0;i<length;i++) {
    final nap=i>=7200 && i<9600;
    hr.add(nap?56:78);
    final angle=(i%9)*10*math.pi/180;
    ax.add(nap?0:math.cos(angle));ay.add(0);az.add(nap?1:math.sin(angle));
  }
  return Substrate(tsSec:[for(var i=0;i<length;i++) napStart-7200+i],hr:hr,
    rrTsMs:const [],rrMs:const [],ax:ax,ay:ay,az:az,
    spo2Red:List.filled(length,0),spo2Ir:List.filled(length,0),
    skinTemp:List.filled(length,0),skinContact:List.filled(length,0),deviceFamily:'gen4');
}

class _HealthNapWriter implements HealthKitNapWriter {
  int replaces=0;
  @override
  Future<bool> replaceNap({required DateTime start,required DateTime end}) async { replaces++;return true; }
  @override
  Future<bool> deleteRange({required DateTime start,required DateTime end,List<Map<String,int>> protectWindows=const []}) async => true;
}

void main() {
  late Database db;
  final start = DateTime(2026, 10, 12, 14).millisecondsSinceEpoch ~/ 1000;
  const day = '2026-10-12';
  setUpAll(() { TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'sleep_block_queue_test.db';
    await databaseFactory.deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
    db = await LocalDb.instance;
    SharedPreferences.setMockInitialValues({});await Prefs.ensureLoaded();
  });
  tearDown(() async { DerivationEngine.debugSecondHalfHook=null;await LocalDb.close(); });
  test('Q1 nap receipt has only nap work and preserves the frozen headline', () async {
    await db.insert('sync_cursor', {'name': LocalDb.kFrozenHeadlineCursor, 'updated_at': 1, 'value': jsonEncode({'day': day, 'readiness': 71})});
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    expect(await repo.putNap(dayId: day, startTs: start, endTs: start + 2400, source: 'manual'), isA<SleepSaved>());
    final jobs = await db.query('sleep_edit_job');
    expect(jobs, hasLength(1));
    expect(jobs.single['revision'], 0);
    expect(jobs.single['nap_revision'], 1);
    expect(jobs.single['nap_applied_revision'], 0);
    expect(await db.query('activity_review_days'), isEmpty);
    expect(await db.query('sync_cursor', where: 'name = ?', whereArgs: [LocalDb.kFrozenHeadlineCursor]), hasLength(1));
  });
  test('Q4 nap receipt leaves the night fence and withholding unchanged', () async {
    final before = await SleepEditStore.generationOn(db, upTo: '2026-10-14');
    await LocalRepositoryImpl(getProfileMap: () => {}).putNap(dayId: day, startTs: start, endTs: start + 2400, source: 'manual');
    expect(await SleepEditStore.generationOn(db, upTo: '2026-10-14'), before);
    expect((await SleepEditStore.viewOn(db, day)).withholdNight, false);
    expect((await SleepEditStore.viewOn(db, day)).recalculating, true);
  });
  // WHY: main and nap counters fence different work; counters are not booleans.
  test('Q2 main edit queues night work and releases its headline', () async {
    await db.insert('sync_cursor', {'name':LocalDb.kFrozenHeadlineCursor,'value':jsonEncode({'day':day}),'updated_at':1});
    final read=await SleepBlockStore.read(db,day);
    final plan=SleepEditorPlan(dayId:day,commands:[AddMain(day,start-3600,start)],expectedRevisions:{day:null},draftGeneration:read.draftGeneration);
    expect(await db.transaction((tx)=>SleepBlockStore.apply(plan,tx:tx)),isA<SleepSaved>());
    final r=(await db.query('sleep_edit_job')).single;
    expect([r['revision'],r['nap_revision']],[1,0]);
    expect((await SleepEditStore.viewOn(db,day)).withholdNight,true);
    expect(await db.query('sync_cursor',where:'name = ?',whereArgs:[LocalDb.kFrozenHeadlineCursor]),isEmpty);
  });
  Future<void> block({String owner=day}) async {
    await db.insert('sleep_block',SleepBlockStore.encodeBlock(
      SleepBlock(id:'n',kind:SleepBlockKind.nap,day:owner,startTs:start,endTs:start+2400),
      source:SleepBlockSource.manual,state:SleepBlockState.live,createdAt:1,history:const DetectedAbsent()));
  }
  test('Q3 recompose applies nap intent advances rollup revision and leaves baselines intact', () async {
    await block(); await db.transaction((tx)=>SleepEditStore.enqueue(tx,day,main:false));
    final meta=(await db.query('activity_review_meta')).single['revision'] as int;
    await LocalDb.putBaseline('crossday_input',jsonEncode({'algo_version':kAlgoVersion,
      'built_for_day':LocalDb.localDayLabelNow(),'review_revision':meta,
      'zone':DerivationEngine.crossDayZoneStamp(),'days':[{'date':day,'nap_min':999}]}));
    final baselines=await db.query('baselines');
    await LocalDb.recomposeNaps(day,1);
    expect((await db.query('sleep_edit_job')).single['nap_applied_revision'],1);
    expect((await db.query('metric_series',where:"key = 'nap_min'")).single['value'],40);
    expect((await db.query('activity_review_meta')).single['revision'],meta+1);
    expect(await db.query('baselines'),baselines);
    await DerivationEngine(log:(_){}).runCrossDayForTest(const Profile());
    final input=jsonDecode((await LocalDb.baseline('crossday_input'))!['payload_json'] as String) as Map;
    expect(input['review_revision'],meta+1,reason:'cached rollup input must be rebuilt after recompose');
    expect((input['days'] as List).whereType<Map>().any((d)=>d['nap_min']==999),false);

    expect(await db.query('activity_review_days'),isEmpty);
  });
  test('Q5 only an earlier main edit changes the later-night fence', () async {
    final before=await SleepEditStore.generationOn(db,upTo:'2026-10-14');
    await db.transaction((tx)=>SleepEditStore.enqueue(tx,day,main:false));
    expect(await SleepEditStore.generationOn(db,upTo:'2026-10-14'),before);
    await db.transaction((tx)=>SleepEditStore.enqueue(tx,day,main:true));
    expect(await SleepEditStore.generationOn(db,upTo:'2026-10-14'),before+1);
  });
  test('Q6 merge queues absorbed nap deletes and survivor export atomically', () async {
    final repo=LocalRepositoryImpl(getProfileMap:()=>{});
    await repo.putNap(dayId:day,startTs:start,endTs:start+2400,source:'manual');
    final proposal=await repo.proposeNapKeep(start+3000,start+5400);
    expect(proposal,isNotNull);
    final out=await repo.putNap(dayId:day,startTs:start+3000,endTs:start+5400,source:'manual',merge:proposal!.authorization);
    expect(out,isA<SleepSaved>());
    final deletes=(await db.query('sync_cursor',where:"name = 'health_nap_pending_deletes'")).single;
    final exports=(await db.query('sync_cursor',where:"name = 'health_nap_pending_exports'")).single;
    expect(jsonDecode(deletes['value'] as String),contains(containsPair('startTs',start)));
    expect(jsonDecode(exports['value'] as String),contains(containsPair('endTs',start+5400)));
    // WHY: a retry names the assertion that created it, not a later block at
    // the same legacy key. A removed id must never export that replacement.
    final survivor=(await db.query('sleep_block',where: "state = 'live'")).single;
    final id=survivor['id'] as String;
    await db.update('sleep_block',{'state':'removed'},where:'id = ?',whereArgs:[id]);
    await db.insert('sleep_block',{...survivor,'id':'replacement'});
    await db.delete('sync_cursor');
    Future<void> receipt() => LocalDb.setCursor('health_nap_pending_exports',jsonEncode([
      {'blockId':id,'dayId':day,'startTs':start,'endTs':start+5400}]));
    await receipt();
    final writer=_HealthNapWriter();var naturalReads=0;
    final exporter=HealthNapExporter(writer:writer,isApple:true,healthSyncEnabled:() async => true,
      dayNapRows:(_) async => [],overlapsMainSleep:(_,_) async => false,
      napRow:(_,_) async { naturalReads++;return {'source':'manual','end_ts':start+5400}; });
    expect(await exporter.exportDayNaps(day),true);
    expect(writer.replaces,0,reason:'the retry id was removed, despite a live replacement at its key');
    expect(naturalReads,0);
    await db.update('sleep_block',{'state':'live'},where:'id = ?',whereArgs:[id]);
    await receipt();
    expect(await exporter.exportDayNaps(day),true);expect(writer.replaces,1);
    expect(naturalReads,0,reason:'positive control uses the same stored id');
  });
  test('Q8 putDayResult composes block truth without a nap projection and applies nap counter', () async {
    await block(); await db.transaction((tx)=>SleepEditStore.enqueue(tx,day,main:false));
    expect(await db.query('sleep_nap'),isEmpty);
    await LocalDb.putDayResult(dayId:day,algoVersion:kAlgoVersion,payloadJson:'{}',windowJson:'{}',source:'band',finalized:false);
    final bundle=jsonDecode((await LocalDb.dayResult(day))!['payload_json'] as String) as Map;
    expect((bundle['scalars'] as Map)['nap_min'],40);
    expect((await db.query('sleep_edit_job')).single['nap_applied_revision'],1);
  });
  test('Q11 lossy projection still signals a new nap input revision', () async {
    await block(); await SleepBlockStore.projectForTest(db,{day});
    final before=(await db.rawQuery("SELECT rev FROM input_revision WHERE source='sleep_nap' AND scope=?",[day])).single['rev'] as int;
    final read=await SleepBlockStore.read(db,day);
    final out=await db.transaction((tx)=>SleepBlockStore.apply(SleepEditorPlan(dayId:day,
      commands:[RemoveBlock(const StoredBlockRef('n',0))],expectedRevisions:{},draftGeneration:read.draftGeneration),tx:tx));
    expect(out,isA<SleepSaved>());
    expect((await db.rawQuery("SELECT rev FROM input_revision WHERE source='sleep_nap' AND scope=?",[day])).single['rev'],greaterThan(before));
  });
  test('Q12 auto-log nap counter does not refuse same-day or later-night writes', () async {
    final fence=await SleepEditStore.generationOn(db,upTo:'2026-10-14');
    await db.transaction((tx)=>SleepEditStore.enqueue(tx,day,main:false));
    for(final d in [day,'2026-10-14']) {
      expect(await LocalDb.putDayResult(dayId:d,algoVersion:kAlgoVersion,payloadJson:'{}',windowJson:'{}',source:'band',finalized:false,sleepEditGeneration:fence),true);
    }
  });
  test('Q13 a user nap receipt leaves an in-flight later-night write admissible', () async {
    await db.insert('sleep_block',SleepBlockStore.encodeBlock(
      SleepBlock(id:'m',kind:SleepBlockKind.main,day:day,startTs:start-28800,endTs:start-7200),
      source:SleepBlockSource.manual,state:SleepBlockState.live,createdAt:1));
    await SleepBlockStore.projectForTest(db,{day});
    final stamp=(await db.rawQuery("SELECT rev FROM input_revision WHERE source='sleep_override' AND scope=?",[day])).single['rev'] as int;
    final fence=await SleepEditStore.generationOn(db,upTo:'2026-10-14');
    await LocalRepositoryImpl(getProfileMap:()=>{}).putNap(dayId:day,startTs:start,endTs:start+2400,source:'manual');
    expect(await LocalDb.putDayResult(dayId:day,algoVersion:kAlgoVersion,payloadJson:'{}',windowJson:'{}',source:'band',finalized:false,sleepEditGeneration:fence,inputStamp:{'sleep_override':{day:stamp}}),true);
    expect(await LocalDb.putDayResult(dayId:'2026-10-14',algoVersion:kAlgoVersion,payloadJson:'{}',windowJson:'{}',source:'band',finalized:false,sleepEditGeneration:fence),true);
  });
  test('Q14 nap recompose handles absent skipped and partial days without a measured-night shortcut', () async {
    for(final shape in ['absent','skipped','partial']) {
      await db.delete('day_result'); await db.delete('sleep_block'); await db.delete('sleep_edit_job');
      if(shape!='absent') { await LocalDb.putDayResult(dayId:day,algoVersion:kAlgoVersion,
        payloadJson:shape=='skipped'?' {"skipped":true}':'{}',windowJson:'{}',source:'band',
        finalized:false,partial:true,skipped:shape=='skipped'); }
      await block(); await db.transaction((tx)=>SleepEditStore.enqueue(tx,day,main:false));
      var nightDerives=0;
      DerivationEngine.debugSecondHalfHook=TestCall1((_) async { nightDerives++; });
      final app=AppState.forTesting();
      try { await app.sleepEditRunner.start(); } finally { app.dispose(); }
      expect(nightDerives,0,reason:'nap-only jobs never invoke night derivation');
      expect((await db.query('sleep_edit_job')).single['phase'],'done');
      final row=await LocalDb.dayResult(day);
      expect(row,isNotNull,reason:shape);
      expect(row!['skipped'],0,reason:shape);
      expect(row['partial'],1,reason:shape);
      expect((jsonDecode(row['payload_json'] as String)['scalars'] as Map)['nap_min'],40,reason:shape);
    }
  });

  // WHY Q7: the post-day step alone creates block intent, in its own receipt.
  test('Q7 post-day auto-log writes one block and projection in the same transaction',() async {
    await db.update('activity_review_meta',{'activated_at':start-1});
    SharedPreferences.setMockInitialValues({Prefs.napAutoLogSinceSec:start-1});
    await db.execute('CREATE TABLE sleep_write_spy(kind TEXT, blocks INTEGER, naps INTEGER)');
    await db.execute("CREATE TRIGGER sleep_write_spy_ai AFTER INSERT ON sleep_nap BEGIN INSERT INTO sleep_write_spy VALUES('nap',(SELECT COUNT(*) FROM sleep_block),(SELECT COUNT(*) FROM sleep_nap)); SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM day_result) THEN RAISE(ABORT,'auto-log preceded the day commit') END; END");
    final sub=napDay(start);
    final prepared=PreparedDerivationDay(date:day,endSec:sub.tsSec.last+1,confidence:0.9,flags:const [],
      sleepJson:const {},hypnoStages:const [],sleepOnsetSec:0,sleepOffsetSec:0,
      daySub:sub,sleepSub:Substrate.empty);
    final logs=<String>[];
    await DerivationEngine(log:logs.add).debugDerivePreparedDay(prepared,const Profile(),sub.tsSec.last+1);
    expect(await db.query('day_result'),hasLength(1),reason:logs.join('\n'));
    final writes=await db.query('sleep_write_spy');
    expect(writes,hasLength(1),reason:logs.join('\n')); expect([writes.single['blocks'],writes.single['naps']],[1,1]);
    final job=(await db.query('sleep_edit_job')).single;
    expect([job['revision'],job['nap_revision'],job['nap_applied_revision']],[0,1,0],reason:'headless post-day step leaves nap work queued for foreground');
    expect(await db.query('activity_review_days'),isEmpty);
  });
  // WHY Q9: the prompt loop must re-read pending after the same-pass auto-log.
  test('Q9 auto-logged same-pass nap emits no prompt with an opt-out positive control',() async {
    await db.update('activity_review_meta',{'activated_at':start-1});
    final engine=DerivationEngine(log:(_){});
    var prompts=0;
    for(final enabled in [true,false]) {
      for(final t in ['sleep_block','sleep_nap','sleep_edit_job','activity_suggestions']) { await db.delete(t); }
      SharedPreferences.setMockInitialValues({if(enabled) Prefs.napAutoLogSinceSec:start-1});
      await engine.debugPublishSleepReview(day,[{'start':start,'end':start+2400,'confidence':0.9}],start+3600,onPrompt:(_) async { prompts++; });
      final suggestions=await db.query('activity_suggestions');expect(suggestions,hasLength(1));
      expect(suggestions.single['status'],enabled?'confirmed':'pending');
      expect(prompts,enabled?0:1);
    }
  });
  // WHY Q10: stale proposals and import/reference passes never auto-log.
  test('Q10 only current candidates in an ordinary pass can auto-log',() async {
    await db.update('activity_review_meta',{'activated_at':start-1});
    SharedPreferences.setMockInitialValues({Prefs.napAutoLogSinceSec:start-1});
    final engine=DerivationEngine(log:(_){});
    final candidate=<String,dynamic>{'start':start,'end':start+2400,'confidence':0.9};
    await ActivityStore(db).reconcile(ActivityKind.nap,[candidate]);
    await engine.debugPublishSleepReview(day,[],start+3600);
    expect(await db.query('sleep_block'),isEmpty);
    await engine.debugPublishSleepReview(day,[candidate],start+3600,forceFinalize:true);
    expect(await db.query('sleep_block'),isEmpty);
    await engine.debugPublishSleepReview(day,[candidate],start+3600,batchReference:true);
    expect(await db.query('sleep_block'),isEmpty);
    await engine.debugPublishSleepReview(day,[candidate],start+3600);
    expect(await db.query('sleep_block'),hasLength(1));
  });

}
