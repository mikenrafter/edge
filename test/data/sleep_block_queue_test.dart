// WHY: nap edits must never invalidate an in-flight night or release its pin.
// CLAIM(sleep-block-one-queue); catches routing naps through the night counter.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';

void main() {
  late Database db;
  final start = DateTime(2026, 10, 12, 14).millisecondsSinceEpoch ~/ 1000;
  const day = '2026-10-12';
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'sleep_block_queue_test.db';
    await databaseFactory.deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
    db = await LocalDb.instance;
  });
  tearDown(() async { await LocalDb.close(); });
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
  test('C24 Naps repository owns a crossing nap on its local start day', () async {
    final at = DateTime(2026, 10, 11, 23, 30).millisecondsSinceEpoch ~/ 1000;
    await LocalRepositoryImpl(getProfileMap: () => {}).putNap(dayId: day, startTs: at, endTs: at + 3600, source: 'manual');
    expect((await db.query('sleep_nap')).single['day_id'], '2026-10-11');
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
    final baselines=await db.query('baselines');
    await LocalDb.recomposeNaps(day,1);
    expect((await db.query('sleep_edit_job')).single['nap_applied_revision'],1);
    expect((await db.query('metric_series',where:"key = 'nap_min'")).single['value'],40);
    expect((await db.query('activity_review_meta')).single['revision'],meta+1);
    expect(await db.query('baselines'),baselines);
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
    final fence=await SleepEditStore.generationOn(db,upTo:'2026-10-14');
    await LocalRepositoryImpl(getProfileMap:()=>{}).putNap(dayId:day,startTs:start,endTs:start+2400,source:'manual');
    expect(await LocalDb.putDayResult(dayId:'2026-10-14',algoVersion:kAlgoVersion,payloadJson:'{}',windowJson:'{}',source:'band',finalized:false,sleepEditGeneration:fence),true);
  });
  test('Q14 nap recompose handles absent skipped and partial days without a measured-night shortcut', () async {
    for(final shape in ['absent','skipped','partial']) {
      await db.delete('day_result'); await db.delete('sleep_block'); await db.delete('sleep_edit_job');
      if(shape!='absent') await LocalDb.putDayResult(dayId:day,algoVersion:kAlgoVersion,
        payloadJson:shape=='skipped'?' {"skipped":true}':'{}',windowJson:'{}',source:'band',
        finalized:false,partial:true,skipped:shape=='skipped');
      await block(); await db.transaction((tx)=>SleepEditStore.enqueue(tx,day,main:false));
      await LocalDb.recomposeNaps(day,1);
      final row=await LocalDb.dayResult(day);
      expect(row,isNotNull,reason:shape);
      expect(row!['skipped'],0,reason:shape);
      expect(row['partial'],1,reason:shape);
      expect((jsonDecode(row['payload_json'] as String)['scalars'] as Map)['nap_min'],40,reason:shape);
    }
  });

}
