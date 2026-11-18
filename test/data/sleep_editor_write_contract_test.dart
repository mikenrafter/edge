// WHY: every mutation must preserve identity, history, projections and intent.
// CLAIM(sleep-block-owner), CLAIM(sleep-block-projection),
// CLAIM(sleep-block-explicit-merge), CLAIM(sleep-editor-draft-generation).
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/compute/nap_edits.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/data/sleep_draft_fence.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'support/sleep_projection.dart';

const day = '2026-10-12';
final a = DateTime(2026, 10, 12, 14).millisecondsSinceEpoch ~/ 1000;
void main() {
  late Database db;
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  setUp(() async {
    await LocalDb.close(); LocalDb.dbName = 'sleep_editor_write_contract_test.db';
    await databaseFactory.deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
    db = await LocalDb.instance;
  });
  tearDown(() async { await LocalDb.close(); });
  Future<String> snapshot() async => jsonEncode({for (final t in [
    'sleep_block','sleep_nap','sleep_override','sleep_edit_job','activity_review_days',
    'activity_review_meta','wake_confirmation','activity_suggestions','input_revision','sync_cursor'])
      t: await db.query(t)});
  Future<List<Map<String,Object?>>> rows() => db.query('sleep_block',orderBy:'start_ts,id');
  Future<void> seed(String id, int s, int e, {String owner = day,
      SleepBlockKind kind = SleepBlockKind.nap, SleepBlockState state = SleepBlockState.live,
      SleepBlockSource source = SleepBlockSource.confirmed, int rule = 1,
      DetectedHistory? history, String? payload}) async {
    await db.insert('sleep_block',SleepBlockStore.encodeBlock(
      SleepBlock(id:id,kind:kind,day:owner,ownerRule:rule,startTs:s,endTs:e),
      source:source,state:state,createdAt:1,
      history:history ?? DetectedKnown(startTs:s,endTs:e,sourceDay:owner),payload:payload));
    await SleepBlockStore.projectForTest(db,{owner});
  }
  Future<void> detection({bool nap=false}) async {
    await LocalDb.putDayResult(dayId:day,algoVersion:kAlgoVersion,
      payloadJson:jsonEncode({'naps':{'value':nap?[{'start':a,'end':a+3600,'duration_min':47}]:[]}}),
      windowJson:jsonEncode(nap?{}:{'onset_ms':a*1000,'offset_ms':(a+3600)*1000}),
      finalized:false,source:'band');
  }
  SleepEditorPlan plan(List<SleepEditorCommand> commands,{Map<String,int?> revisions=const {}}) =>
    SleepEditorPlan(dayId:day,commands:commands,expectedRevisions:revisions,
      draftGeneration:SleepDraftFence.shared.generationOf(day));
  Future<SleepEditorOutcome> save(List<SleepEditorCommand> commands,{SleepMergeAuthorization? merge}) =>
    db.transaction((tx)=>SleepBlockStore.apply(plan(commands),tx:tx,merge:merge));
  Future<void> parity() async {
    for (final d in {for(final r in await rows()) r['owner_day'] as String}) { await projectionMatches(db,d); }
  }
  test('W1 unchanged Save writes nothing',() async {
    await seed('n',a,a+2400); final before=await snapshot();
    expect(await save([SetIntervals(const StoredBlockRef('n',0),a,a+2400)]),isA<SleepNoChange>());
    expect(await snapshot(),before);
  });
  test('W2 add then remove in one Save has no durable effect',() async {
    final before=await snapshot();
    expect(await save([AddNap(a,a+2400),RemoveBlock(DetectedNapRef(day,a,a+2400))]),isA<SleepNoChange>());
    expect(await snapshot(),before);
  });
  test('W3 first automatic main edit snapshots the served detection',() async {
    await detection();
    expect(await save([SetIntervals(DetectedMainRef(day,a,a+3600),a-600,a+3600)]),isA<SleepSaved>());
    final r=(await rows()).single;
    expect([r['kind'],r['source'],r['history'],r['detected_start'],r['detected_end'],r['detected_day'],r['owner_rule']],
      ['main','detected','known',a,a+3600,day,1]); await parity();
  });
  test('W4 a second edit preserves the first snapshot and stable id',() async {
    await seed('n',a,a+2400);
    expect(await save([SetIntervals(const StoredBlockRef('n',0),a+60,a+2400)]),isA<SleepSaved>());
    expect(await save([SetIntervals(const StoredBlockRef('n',1),a+120,a+2460)]),isA<SleepSaved>());
    final r=(await rows()).single;
    expect([r['id'],r['revision'],r['detected_start'],r['detected_end']],['n',2,a,a+2400]); await parity();
  });
  test('W5 Remove and Restore use the id; repeated Remove is a no-op',() async {
    await seed('n',a,a+2400);
    expect(await save([const RemoveBlock(StoredBlockRef('n',0))]),isA<SleepSaved>());
    final before=await snapshot();
    expect(await save([const RemoveBlock(StoredBlockRef('n',1))]),isA<SleepNoChange>());
    expect(await snapshot(),before);
    expect(await save([const RestoreRemoved(StoredBlockRef('n',1))]),isA<SleepSaved>());
    expect((await rows()).single['state'],'live'); await parity();
  });
  test('W6 same-start replacement keeps both blocks and exact suppression',() async {
    await seed('d',a,a+3600);
    await save([const RemoveBlock(StoredBlockRef('d',0))]);
    expect(await save([AddNap(a,a+2400)]),isA<SleepSaved>());
    expect(await rows(),hasLength(2));
    expect((await db.query('sleep_nap')).single['end_ts'],a+2400);
    final manual=(await rows()).singleWhere((r)=>r['id']!='d');
    await save([RemoveBlock(StoredBlockRef(manual['id'] as String,manual['revision'] as int))]);
    final edits=await SleepBlockStore.napEdits(db,day);
    expect(applyNapEdits([{'start':a+2700,'end':a+3300}],edits),isEmpty); await parity();
  });
  test('W7 midnight move re-owns even a misdated absorbed nap and suppresses stored origin',() async {
    final old=DateTime(2026,10,11,23,30).millisecondsSinceEpoch~/1000;
    await seed('n',old,old+2400,rule:0);
    final moved=DateTime(2026,10,13,0,10).millisecondsSinceEpoch~/1000;
    final out=await save([SetIntervals(const StoredBlockRef('n',0),moved,moved+2400)]);
    expect((out as SleepSaved).days,{day,'2026-10-13'});
    final r=(await rows()).single;
    expect([r['owner_day'],r['owner_rule'],r['detected_day']],['2026-10-13',1,day]);
    expect(applyNapEdits([{'start':old,'end':old+2400}],await SleepBlockStore.napEdits(db,day)),isEmpty);
    expect(await SleepBlockStore.napEdits(db,'2026-10-11'),isEmpty);
    expect(await db.query('sleep_edit_job'),hasLength(2)); await parity();
  });
  test('W8 29:59 touching and overlap all refuse with every table unchanged',() async {
    await seed('n',a,a+2400);
    for(final offset in [4199,2400,1200]) {
      final before=await snapshot();
      final out=await save([AddNap(a+offset,a+offset+2400)]);
      expect(out,isA<SleepRefused>());
      expect((out as SleepRefused).reason,SleepRefusalReason.mergeRequired);
      expect(await snapshot(),before);
    }
  });
  test('W9 exactly 30 minutes is accepted separately',() async {
    await seed('n',a,a+2400);
    expect(await save([AddNap(a+4200,a+6600)]),isA<SleepSaved>());
    expect((await rows()).where((r)=>r['state']=='live'),hasLength(2)); await parity();
  });
  test('W10 authorized transitive merge keeps one live survivor and links participants',() async {
    for(final allKnown in [true,false]) {
    for(final t in ['sleep_block','sleep_nap','sleep_edit_job','sync_cursor']) { await db.delete(t); }
    for(final (id,s,e) in [('a',a,a+1200),('b',a+3000,a+4200),('c',a+5400,a+6600)]) {
      await seed(id,s,e,history:!allKnown && id=='b'?const DetectedUnavailable('lost snapshot'):null);
    }
    final commands=[SetIntervals(const StoredBlockRef('a',0),a,a+1801)];
    final pre=await SleepBlockStore.preflight(db,plan(commands));
    expect(pre,isA<SleepProposalMergeRequired>());
    final proposal=(pre as SleepProposalMergeRequired).proposal;
    expect(proposal.participants.map((b)=>b.id).toSet(),{'a','b','c'});
    expect(await save(commands,merge:proposal.authorization),isA<SleepSaved>());
    final all=await rows();
    expect(all.where((r)=>r['state']=='live'),hasLength(1));
    expect(all.where((r)=>r['state']=='merged').map((r)=>r['merged_into']).toSet(),{'a'});
    final survivor=all.singleWhere((r)=>r['id']=='a');
    expect([survivor['start_ts'],survivor['end_ts'],survivor['history'],survivor['detected_start'],survivor['detected_end']],
      [a,a+6600,allKnown?'known':'unavailable',allKnown?a:null,allKnown?a+6600:null]); await parity();
    }
  });
  test('W11 stale row revision day revision and draft generation refuse atomically',() async {
    await seed('n',a,a+2400); final before=await snapshot();
    final stale=await save([SetIntervals(const StoredBlockRef('n',7),a,a+2500)]);
    expect(stale,isA<SleepRefused>());
    expect((stale as SleepRefused).reason,SleepRefusalReason.staleEntry);
    expect((await db.transaction((tx)=>SleepBlockStore.apply(plan([AddNap(a+7200,a+9600)],revisions:{day:9}),tx:tx)) as SleepRefused).reason,SleepRefusalReason.staleEntry);
    final stale=plan([AddNap(a+7200,a+9600)]); SleepDraftFence.shared.advanceDays({day});
    expect((await db.transaction((tx)=>SleepBlockStore.apply(stale,tx:tx)) as SleepRefused).reason,SleepRefusalReason.staleDraft);
    expect(await snapshot(),before);
  });
  test('W12 transaction abort rolls back blocks projections and jobs; commit keeps intent',() async {
    final before=await snapshot();
    await expectLater(db.transaction((tx) async {
      expect(await SleepBlockStore.apply(plan([AddNap(a,a+2400)]),tx:tx),isA<SleepSaved>());
      throw StateError('crash before commit');
    }),throwsStateError);
    expect(await snapshot(),before);
    expect(await save([AddNap(a,a+2400)]),isA<SleepSaved>());
    expect(await db.query('sleep_edit_job'),hasLength(1)); await parity();
  });
  test('W13 disjoint measured participants sum; overlapping measured participants abstain',() async {
    for(final overlap in [false,true]) {
      await db.delete('sleep_block'); await db.delete('sleep_nap'); await db.delete('sleep_edit_job');
      await seed('a',a,a+2400,payload:jsonEncode({'duration_min':30,'in_bed_min':40}));
      await seed('b',a+(overlap?1200:3600),a+6000,payload:jsonEncode({'duration_min':35,'in_bed_min':40}));
      final commands=[SetIntervals(const StoredBlockRef('a',0),a,a+3000)];
      final pre=await SleepBlockStore.preflight(db,plan(commands));
      expect(pre,isA<SleepProposalMergeRequired>());
      final proposal=(pre as SleepProposalMergeRequired).proposal;
      expect(await save(commands,merge:proposal.authorization),isA<SleepSaved>());
      final payload=jsonDecode((await rows()).singleWhere((r)=>r['state']=='live')['payload_json'] as String) as Map;
      expect(payload['duration_min'],overlap?null:65); await parity();
    }
  });
  test('W14 ClearMain reveals detection; dangling merged participants become restorable',() async {
    await detection(); await seed('m',a,a+3600,kind:SleepBlockKind.main);
    await seed('n',a+6000,a+7200,state:SleepBlockState.merged);
    await db.update('sleep_block',{'merged_into':'m'},where:"id='n'");
    expect(await save([const ClearMain(day)]),isA<SleepSaved>());
    final read=await SleepBlockStore.read(db,day);
    expect(read.entries.where((e)=>e.id==null),hasLength(1));
    expect(read.entries.singleWhere((e)=>e.id=='n').mergedInto,isNull);
    expect(await save([const RestoreRemoved(StoredBlockRef('n',0))]),isA<SleepSaved>()); await parity();
  });
  test('W15 AddMain on an empty night is manual with explicitly absent history',() async {
    expect(await save([AddMain(day,a,a+3600)]),isA<SleepSaved>());
    final r=(await rows()).single;
    expect([r['kind'],r['source'],r['history'],r['owner_rule']],['main','manual','absent',1]); await parity();
  });
  test('W16 Not sleep on an empty night writes the legacy one-second placeholder',() async {
    expect(await save([const RemoveBlock(NoDetectionMainRef(day))]),isA<SleepSaved>());
    final midnight=DateTime(2026,10,12).millisecondsSinceEpoch~/1000;
    final r=(await rows()).single;
    expect([r['state'],r['history'],r['start_ts'],r['end_ts']],['removed','absent',midnight,midnight+1]); await parity();
  });
  test('W17 removing a bundle-only nap snapshots it before tombstoning',() async {
    await detection(nap:true);
    // A served detector proposal exists before an assertion is made.
    await db.update('day_result',{'payload_json':jsonEncode({'naps':{'value':[{'start':a,'end':a+3600,'duration_min':47}]}})});
    expect(await save([RemoveBlock(DetectedNapRef(day,a,a+3600))]),isA<SleepSaved>());
    final r=(await rows()).single;
    expect([r['kind'],r['source'],r['state'],r['history'],r['detected_day']],['nap','detected','removed','known',day]); await parity();
  });
  test('W18 a second main refuses without an index exception or any writes',() async {
    await seed('m',a,a+3600,kind:SleepBlockKind.main); final before=await snapshot();
    final out=await save([AddMain(day,a+7200,a+10800)]);
    expect(out,isA<SleepRefused>()); expect((out as SleepRefused).reason,SleepRefusalReason.mainExists);
    expect(await snapshot(),before);
  });
  test('W19 time wheels revive a rejected main; ConfirmMain keeps its id and history',() async {
    await seed('m',a,a+3600,kind:SleepBlockKind.main,state:SleepBlockState.removed);
    expect(await save([SetIntervals(const StoredBlockRef('m',0),a+60,a+3600)]),isA<SleepSaved>());
    expect((await rows()).single['source'],'manual');
    expect(await save([ConfirmMain(day,a+120,a+3660)]),isA<SleepSaved>());
    final r=(await rows()).single;
    expect([r['id'],r['source'],r['history'],r['detected_start']],['m','confirmed','known',a]); await parity();
  });
}
