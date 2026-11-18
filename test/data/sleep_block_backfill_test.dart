import 'dart:convert';
// WHY: rung 94 must preserve sleep assertions on every supported open path.
// CLAIM(sleep-block-backfill). catches: creator or upgrade hook omitted.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/compute/nap_edits.dart';
import 'package:openstrap_edge/compute/accepted_naps.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'support/sleep_block_fixture.dart';
import 'support/sleep_projection.dart';
Future<Map<String,Object?>> readerSnapshot(LocalRepositoryImpl repo) async => {
  'sleep':await repo.getDaySleep(fixtureDay), 'naps':await repo.getDayNaps(fixtureDay),
  'windows':await repo.sleepWindows(days:5,before:'2026-11-02'),
  'reminders':await LocalDb.reminderNapWindows('2026-10-01'),
};

const name = 'sleep_block_backfill_test.db';
Future<String> dbPath() async => p.join(await databaseFactory.getDatabasesPath(), name);
Future<Database> reopen() async {
  await LocalDb.close();
  LocalDb.dbName = name;
  return LocalDb.instance;
}
Future<void> rewind(int version) async {
  await LocalDb.close();
  final db = await databaseFactory.openDatabase(await dbPath());
  await db.execute('DROP TABLE IF EXISTS sleep_block');
  if (version == 92) {
    await db.execute('ALTER TABLE sleep_override DROP COLUMN payload_json');
  }
  await db.execute('PRAGMA user_version = $version');
  await db.close();
}
Future<void> expectBlockTable(Database db) async {
  expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='sleep_block'"),
      [{'name': 'sleep_block'}]);
}
// Frozen release reader, independent of the new ActivityStore adapter.
Future<List<NapEdit>> releaseNapEdits(DatabaseExecutor db,String day) async => [
  for(final row in await db.query('sleep_nap',where:'day_id = ?',whereArgs:[day]))
    NapEdit(kind:row['source']=='rejected'?NapEditKind.rejected:NapEditKind.added,
      startSec:row['start_ts'] as int,endSec:row['end_ts'] as int,
      snapshot:await releaseSnapshot(row['payload_json'])),
];
Future<Map<String,dynamic>?> releaseSnapshot(Object? raw) async {
  if(raw is! String) return null;
  final map=Map<String,dynamic>.from(jsonDecode(raw) as Map)..remove('sleep_edit');
  return map.isEmpty?null:map;
}
void main() {
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  setUp(() async { await LocalDb.close(); await databaseFactory.deleteDatabase(await dbPath()); });
  tearDown(() async { await LocalDb.close(); await databaseFactory.deleteDatabase(await dbPath()); });
  // WHY F1: today's capture checks naps only; a partial main overlap still counts.
  test('F1 step-3 capture preserves a nap partially overlapping a manual main', () async {
    var db = await reopen();
    await db.update('activity_review_meta', {'activated_at':20000});
    await SleepBlockStore.absorb(db,
      overrides:[mainRow(fixtureDay,'manual',1000,3000)], naps:[],
      servedDayResults:[{'day_id':fixtureDay,'naps_json':'[{"start":700,"end":1300,"duration_min":10}]'}],
      mode:AbsorbMode.backfill);
    expect(await db.query('sleep_block',where:"kind = 'nap'"),hasLength(1));
    expect((await db.query('sleep_nap')).single['source'],'legacy');
    final edits=await SleepBlockStore.napEdits(db,fixtureDay);
    expect(edits.single.snapshot?['duration_min'],10);
  });
  // WHY F1 owner clarification: store fully contained naps, while a rejected
  // night blocks legacy capture. B10's second named delta is that exclusion.
  test('F1 contained live-main nap is retained; rejected-main nap is not captured', () async {
    final db=await reopen(); await db.update('activity_review_meta',{'activated_at':20000});
    for(final (owner,source,start) in [('2026-10-30','manual',1000),('2026-10-31','rejected',5000)]) {
      await SleepBlockStore.absorb(db,overrides:[mainRow(owner,source,start,start+3000)],naps:[],
        servedDayResults:[{'day_id':owner,'naps_json':'[{"start":${start+600},"end":${start+1200},"duration_min":10}]'}],
        mode:AbsorbMode.backfill);
    }
    final naps=await db.query('sleep_block',where:"kind = 'nap'");
    expect(naps,hasLength(1)); expect(naps.single['owner_day'],'2026-10-30');
    expect(await db.query('sleep_nap',where:"day_id = '2026-10-31'"),isEmpty,
      reason:'B10 named delta 2: a non-live main prevents legacy capture');
    final bundle=<String,dynamic>{'sleep':{'window':{'value':{'onset_ms':1000000,'offset_ms':4000000}}},
      'naps':{'value':[]},'scalars':<String,dynamic>{}};
    composeAcceptedNaps(bundle,await SleepBlockStore.napEdits(db,'2026-10-30'));
    expect((bundle['naps'] as Map)['value'],isEmpty,reason:'stored for a later correction, hidden from current totals');
  });
  // WHY F2: composition must use the same snapshots as the release reader,
  // including a NULL snapshot for an empty payload so manual minutes survive.
  test('F2 B10 store napEdits equals legacy on the full upgraded fixture including empty payload', () async {
    var db=await reopen(); await seedLegacy(db);
    await db.insert('sleep_nap',napRow(12000,12600,'manual',payload:'{}'));
    await rewind(92); db=await reopen();
    List<Object?> tuples(List<NapEdit> edits) => [for(final e in edits)
      [e.kind.name,e.startSec,e.endSec,e.snapshot]];
    for(final d in ['2026-10-30','2026-10-31',fixtureDay]) {
      expect(tuples(await SleepBlockStore.napEdits(db,d)),
        tuples(await releaseNapEdits(db,d)),reason:d);
    }
    expect((await SleepBlockStore.napEdits(db,fixtureDay)).singleWhere((e)=>e.startSec==12000).snapshot,isNull);
  });
  test('B1 fresh open creates sleep_block and the one-live-main index', () async {
    final db = await reopen();
    await expectBlockTable(db);
    expect((await db.rawQuery('PRAGMA index_list(sleep_block)')).map((r) => r['name']),
        contains('idx_sleep_block_live_main'));
    await db.insert('sleep_block',blockRow('first',kind:'main'));
    await expectLater(db.insert('sleep_block',blockRow('second',kind:'main')),throwsA(isA<DatabaseException>()));
    await db.insert('sleep_block',blockRow('removed',kind:'main',state:'removed'));
    expect(await db.query('sleep_block'),hasLength(2));
  });
  for (final version in [92, 93]) {
    test('B${version == 92 ? 2 : 3} upgrade from $version absorbs a stored main', () async {
      var db = await reopen();
      await seedLegacy(db);
      await rewind(version);
      if (version == 93) {
        final raw = await databaseFactory.openDatabase(await dbPath());
        await raw.execute('DROP TABLE sleep_edit_job');
        await raw.close();
      }
      db = await reopen();
      await expectBlockTable(db);
      final expected = <Map<String,Object?>>[
        for (final (day,source,state,a,b) in [
          ('2026-10-30','manual','live',100,200),
          ('2026-10-31','confirmed','live',300,400),
          (fixtureDay,'detected','removed',500,501),
        ]) {...blockRow('legacy:main:$day',kind:'main',day:day,start:a,end:b,
          source:source,state:state), 'created_at':11,'updated_at':11},
        blockRow('legacy:nap:$fixtureDay:1100',start:1100,end:1700,source:'confirmed',
          history:'known',detectedStart:1000,detectedEnd:1600,detectedDay:fixtureDay,payload:napPayload),
        blockRow('legacy:nap:$fixtureDay:1800',start:1800,end:1900,source:'confirmed'),
        blockRow('legacy:nap:$fixtureDay:2000',start:2000,end:2100),
        blockRow('legacy:nap:$fixtureDay:3000',start:3000,end:3600,source:'legacy',
          history:'known',detectedStart:3000,detectedEnd:3600,detectedDay:fixtureDay,payload:'{"duration_min":10}'),
        blockRow('legacy:nap:$fixtureDay:2200',start:2200,end:2800,source:'detected',state:'removed',
          history:'known',detectedStart:2000,detectedEnd:2900,detectedDay:fixtureDay,payload:rejectedPayload),
        blockRow('legacy:nap:$fixtureDay:4000',start:4000,end:4600,source:'detected',state:'removed'),
        {...blockRow('legacy:nap:$fixtureDay:5000',start:5000,end:5600,source:'legacy',
          history:'known',detectedStart:5000,detectedEnd:5600,detectedDay:fixtureDay,
          payload:'{"start":5000,"end":5600,"duration_min":10,"source":"legacy"}'),
          'created_at':20000,'updated_at':20000},
      ]..sort((a,b)=>(a['id'] as String).compareTo(b['id'] as String));
      expect(await db.query('sleep_block',orderBy:'id'),expected);
    });
  }
  test('B4 same-version repair recreates a missing table', () async {
    await reopen();
    await rewind(LocalDb.schemaVersion);
    await expectBlockTable(await reopen());
  });
  // catches: migration rewrites the source projections or changes payload bytes;
  // two non-live collisions chosen by query order instead of the total order.
  test('B5 projection is exact for legacy rows and deterministic on collisions', () async {
    var db = await reopen(); await seedLegacy(db);
    final oldNaps = await db.query('sleep_nap',orderBy:'start_ts');
    final oldMains = await db.query('sleep_override',orderBy:'day_id');
    await rewind(92); db = await reopen();
    expect((await db.query('sleep_nap',orderBy:'start_ts')).where((n)=>n['start_ts']!=5000),oldNaps);
    expect(await db.query('sleep_override',orderBy:'day_id'),oldMains);
    for (final d in ['2026-10-30','2026-10-31',fixtureDay]) { await projectionMatches(db,d); }
    for (final order in [false,true]) {
      await db.delete('sleep_block');
      final pair = [blockRow('z',state:'removed',payload:'z'),blockRow('a',state:'removed',payload:'a')];
      for (final r in order ? pair.reversed : pair) { await db.insert('sleep_block',r); }
      await SleepBlockStore.projectForTest(db,{fixtureDay});
      expect((await db.query('sleep_nap',where:'day_id = ?',whereArgs:[fixtureDay])).single['payload_json'],'a');
      await projectionMatches(db,fixtureDay);
      await db.insert('sleep_block',blockRow('merged',state:'merged',updatedAt:200,payload:'merged'));
      await db.insert('sleep_block',blockRow('newer',state:'removed',updatedAt:18,payload:'newer'));
      await SleepBlockStore.projectForTest(db,{fixtureDay});
      expect((await db.query('sleep_nap',where:'day_id = ?',whereArgs:[fixtureDay])).single['payload_json'],'newer');
      await db.insert('sleep_block',blockRow('live',state:'live',updatedAt:1,payload:'live'));
      await SleepBlockStore.projectForTest(db,{fixtureDay});
      expect((await db.query('sleep_nap',where:'day_id = ?',whereArgs:[fixtureDay])).single['payload_json'],'live');
      await projectionMatches(db,fixtureDay);
    }
  });
  // catches: upsert bumps revisions/jobs or rewrites projections on repeat.
  test('B6 repeated backfill is byte and revision identical', () async {
    var db = await reopen(); await seedLegacy(db); await rewind(93); db = await reopen();
    await db.update('sleep_block',{'revision':3});
    await db.insert('sleep_edit_job',{'day_id':fixtureDay,'revision':4,'applied_revision':2,
      'nap_revision':9,'nap_applied_revision':8,'phase':'failed','error':'kept'});
    final before = await snapshot(db);
    await SleepBlockStore.backfill(db);
    expect(await snapshot(db),before);
    await reopen(); expect(await snapshot(await LocalDb.instance),before);
  });
  // catches: rejecting or recomputing a legacy placeholder's stored owner day.
  test('B7 placeholder rejection survives and is reported', () async {
    final db = await reopen();
    final report = await SleepBlockStore.absorb(db, overrides:[mainRow(fixtureDay,'rejected',500,501)], naps:[], mode:AbsorbMode.backfill);
    expect(report.map((e)=>e.kind),['placeholder_bounds']);
    final r = (await db.query('sleep_block')).single;
    expect((r['owner_day'],r['start_ts'],r['end_ts'],r['state'],r['history']),
      (fixtureDay,500,501,'removed','unavailable'));
  });
  // catches: missing step-3 projection insert, full bundle capture, overlap loss,
  // capturing user-authored or post-review detections, and repeat capture.
  test('B8 pre-review bundle detection is captured exactly once', () async {
    var db = await reopen(); await seedLegacy(db); await rewind(92); db = await reopen();
    final captured = await db.query('sleep_block',where:'start_ts = 5000');
    expect(captured,hasLength(1)); final r = captured.single;
    expect((r['id'],r['owner_day'],r['source'],r['history'],r['detected_start'],r['detected_end'],r['detected_day']),
      ('legacy:nap:2026-11-01:5000',fixtureDay,'legacy','known',5000,5600,fixtureDay));
    expect((await db.query('sleep_nap',where:'start_ts = 5000')).single['payload_json'],
      '{"start":5000,"end":5600,"duration_min":10,"source":"legacy"}');
    expect(await db.query('sleep_block'),hasLength(10));
    await SleepBlockStore.backfill(db); expect(await db.query('sleep_block'),hasLength(10));
  });
  // catches: malformed JSON crashes absorb/read, or fabricates original bounds.
  test('B9 malformed payload preserves scalar bounds and drops read measures', () async {
    final db = await reopen();
    final report = await SleepBlockStore.absorb(db, overrides:[], naps:[napRow(1000,1600,'confirmed',payload:'{bad')], mode:AbsorbMode.backfill);
    expect(report.map((e)=>e.kind),['malformed_payload']);
    final row = (await db.query('sleep_block')).single;
    expect((row['start_ts'],row['end_ts'],row['payload_json'],row['history']), (1000,1600,'{bad','unavailable'));
    final entry = (await SleepBlockStore.read(db,fixtureDay)).entries.single;
    expect(entry.history,isA<DetectedUnavailable>());
    expect((await SleepBlockStore.napEdits(db,fixtureDay)).single.snapshot,isNull);
  });
  // catches: a ladder changes served measurement output. Named delta 1 is
  // newly captured legacy projections. Delta 2 is the owner-approved exclusion
  // of a pre-review nap inside a non-live main (no new assertion or projection).
  test('B10 existing readers preserve output with the two named capture deltas', () async {
    var db = await reopen(); await seedLegacy(db);
    await db.update('sleep_override',{'offset_ts':400},where:"day_id = '2026-10-30'");
    await db.update('sleep_override',{'offset_ts':800},where:'day_id = ?',whereArgs:[fixtureDay]);
    await db.update('day_result',{'payload_json':jsonEncode({'naps':{'value':[
      {'start':70,'end':130,'duration_min':1}, // partly overlaps a live main
      {'start':250,'end':310,'duration_min':1}, // contained in a live main
    ]},'scalars':{}})},where:"day_id = '2026-10-30'");
    final bundle=jsonDecode((await db.query('day_result',where:'day_id = ?',whereArgs:[fixtureDay])).single['payload_json'] as String) as Map;
    (bundle['naps']['value'] as List).add({'start':600,'end':660,'duration_min':1});
    await db.update('day_result',{'payload_json':jsonEncode(bundle)},where:'day_id = ?',whereArgs:[fixtureDay]);
    final repo = LocalRepositoryImpl(getProfileMap:()=>{});
    final before = await readerSnapshot(repo);
    final edits = await LocalDb.napEdits(fixtureDay);
    final editDays = await LocalDb.napEditDays();
    final feed = await db.rawQuery("SELECT * FROM track_event_feed WHERE source_kind = 'nap'");
    await rewind(92); db = await reopen();
    final after = await readerSnapshot(LocalRepositoryImpl(getProfileMap:()=>{}));
    expect(after,before,reason:'backfill does not rewrite day_result or served metrics');
    final afterEdits = await LocalDb.napEdits(fixtureDay);
    expect(afterEdits.length,edits.length+1);
    expect(afterEdits.where((n)=>n['start_ts']==5000).single['source'],'legacy');
    expect(await LocalDb.napEditDays(),{...editDays,'2026-10-30'});
    expect((await db.rawQuery("SELECT * FROM track_event_feed WHERE source_kind = 'nap'")).length,feed.length+3);
    expect((await db.query('sleep_block',where:"kind = 'nap' AND owner_day = '2026-10-30'",orderBy:'start_ts')).map((r)=>r['start_ts']),[70,250]);
    expect(await db.query('sleep_block',where:"kind = 'nap' AND start_ts = 600"),isEmpty,
      reason:'named delta 2: do not preserve a nap inside a rejected main');
    expect(await db.query('sleep_nap',where:'start_ts = 600'),isEmpty);
  });
  // catches: a future/unknown source starts counting as sleep.
  test('B11 unknown source is retained as removed and reported', () async {
    final db = await reopen();
    final report = await SleepBlockStore.absorb(db, overrides:[],naps:[napRow(1000,1600,'future')],mode:AbsorbMode.backfill);
    final rows = await db.query('sleep_block'); expect(rows,hasLength(1));
    final row = rows.single;
    expect((row['state'],row['source'],row['history']),('removed','detected','unavailable'));
    expect(report.map((e)=>e.kind),['unknown_source']);
    expect(await SleepBlockStore.live(db,0,2000),isEmpty);
  });
  for (final zone in ['America/Denver','Asia/Kolkata']) {
    // catches: recomputing historical owner_day from bounds under this zone.
    test('B${zone == 'America/Denver' ? 13 : 14} stored labels stay literal ($zone matrix)', () async {
      var db = await reopen(); await seedLegacy(db); await rewind(92); db = await reopen();
      expect((await db.query('sleep_block',orderBy:'id')).map((r)=>r['owner_day']).toSet(),
        {'2026-10-30','2026-10-31',fixtureDay});
      expect((await db.query('sleep_block',where:'id = ?',whereArgs:['legacy:main:2026-11-01'])).single['start_ts'],500);
    });
  }
  // catches: backfill enqueues, releases frozen headline, withholds a night,
  // rewrites any existing projection, or moves unrelated input revisions.
  test('B15 upgrade changes only step-3 nap input revision, no jobs/headline', () async {
    var db = await reopen(); await seedLegacy(db);
    await db.insert('sleep_edit_job',{'day_id':fixtureDay,'revision':4,'applied_revision':4,'nap_revision':7,'nap_applied_revision':6,'phase':'done'});
    await db.insert('sync_cursor',{'name':LocalDb.kFrozenHeadlineCursor,'value':'{"day":"2026-11-01","score":72}','updated_at':1});
    final jobs = await db.query('sleep_edit_job'), cursor = await db.query('sync_cursor');
    final revisions = await db.query('input_revision');
    final results = await db.query('day_result');
    await rewind(92); db = await reopen();
    expect(await db.query('sleep_edit_job'),jobs); expect(await db.query('sync_cursor'),cursor);
    expect(await db.query('day_result'),results);
    expect((await SleepEditStore.viewOn(db,fixtureDay)).withholdNight,isFalse);
    final changed = await db.query('input_revision');
    // Independently compare all rows; the only allowed change is sleep_nap on D.
    expect(changed.where((r)=>!(r['source']=='sleep_nap' && r['scope']==fixtureDay)),
      revisions.where((r)=>!(r['source']=='sleep_nap' && r['scope']==fixtureDay)));
    final oldNapRev = revisions.where((r)=>r['source']=='sleep_nap' && r['scope']==fixtureDay).single['rev'] as int;
    expect(changed.where((r)=>r['source']=='sleep_nap' && r['scope']==fixtureDay).single['rev'],oldNapRev+1);
  });
  // catches: same-version repair creates an empty owner and silently unpins it.
  test('B16 missing table reabsorbs, present empty table never reabsorbs', () async {
    var db = await reopen(); await seedLegacy(db); await rewind(93); db = await reopen();
    final rows = await db.query('sleep_block',orderBy:'id');
    expect(rows,hasLength(10));
    await rewind(LocalDb.schemaVersion); db = await reopen();
    expect(await db.query('sleep_block',orderBy:'id'),rows);
    await db.delete('sleep_block'); db = await reopen();
    expect(await db.query('sleep_block'),isEmpty);
  });
  // WHY: ownership-rule changes must remain visible without relabeling history.
  // catches: absorbed rows inherit the current rule or rule metadata is absent.
  test('B17 stored ownership distinguishes legacy and current rules', () async {
    var db = await reopen(); await seedLegacy(db); await rewind(93); db = await reopen();
    expect((await db.rawQuery('PRAGMA table_info(sleep_block)')).map((r)=>r['name']),
      contains('owner_rule'));
    expect((await db.query('sleep_block')).map((r)=>r['owner_rule']).toSet(),{0});
    await db.insert('sleep_block',SleepBlockStore.encodeBlock(
      const SleepBlock(id:'new-rule',kind:SleepBlockKind.nap,day:fixtureDay,startTs:8000,endTs:8600),
      source:SleepBlockSource.manual,state:SleepBlockState.live,createdAt:19));
    db = await reopen();
    expect((await db.query('sleep_block',where:'id = ?',whereArgs:['new-rule'])).single['owner_rule'],1);
    expect((await db.query('sleep_block',where:'id = ?',whereArgs:['legacy:nap:$fixtureDay:1100'])).single['owner_rule'],0);
    final read = await SleepBlockStore.read(db,fixtureDay);
    expect(read.entries.where((e)=>e.id=='new-rule').single.ownerRule,1);
    expect(read.entries.where((e)=>e.id=='legacy:nap:$fixtureDay:1100').single.ownerRule,0);
    final legacy = (await SleepBlockStore.live(db,1100,1200)).single;
    expect(SleepBlockStore.encodeBlock(legacy,source:SleepBlockSource.confirmed,
      state:SleepBlockState.live,createdAt:17)['owner_rule'],0);
    // A same-version creator repairs the additive column without relabeling.
    await db.execute('ALTER TABLE sleep_block DROP COLUMN owner_rule');
    db = await reopen();
    expect((await db.query('sleep_block')).map((r)=>r['owner_rule']).toSet(),{0});
  });

  // WHY: sparse merged/legacy schemas must heal without quarantining user rows.
  // catches: rung 94 reads a missing legacy nap, review-meta or result table.
  test('B18 sparse upgrades and current-version repair preserve existing rows', () async {
    for (final version in [LocalDb.schemaVersion,93,77]) {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(await dbPath());
      final raw = await databaseFactory.openDatabase(await dbPath(), options:OpenDatabaseOptions(
        version:version,onCreate:(db,_) async {
          await db.execute('CREATE TABLE last_result (key TEXT PRIMARY KEY, computed_at INTEGER NOT NULL, payload_json TEXT NOT NULL, input_sig TEXT)');
          await db.insert('last_result',{'key':'kept','computed_at':7,'payload_json':'{}'});
          await db.execute('CREATE TABLE sleep_override (day_id TEXT PRIMARY KEY, onset_ts INTEGER NOT NULL, offset_ts INTEGER NOT NULL, source TEXT NOT NULL, created_at INTEGER NOT NULL)');
          await db.insert('sleep_override',{'day_id':fixtureDay,'onset_ts':100,'offset_ts':200,'source':'manual','created_at':11});
        }));
      await raw.close();
      LocalDb.lastRebuild = null;
      final db = await reopen();
      expect(LocalDb.lastRebuild,isNull,reason:'schema $version must not quarantine missing source tables');
      expect(await db.query('last_result',columns:['key','computed_at','payload_json'],where:'key = ?',whereArgs:['kept']),
        [{'key':'kept','computed_at':7,'payload_json':'{}'}]);
      expect(await db.query('sleep_block',columns:['id','owner_day','owner_rule','start_ts','end_ts','source']),
        [{'id':'legacy:main:$fixtureDay','owner_day':fixtureDay,'owner_rule':0,'start_ts':100,'end_ts':200,'source':'manual'}]);
    }
  });
  // WHY: recreating a nap projection must still invalidate that day's inputs.
  // catches: repair installs the nap input-revision triggers after absorption.
  test('B19 repair installs revision triggers before a missing nap projection is captured', () async {
    var db = await reopen();
    await db.update('activity_review_meta',{'activated_at':20000});
    await seedDay(db,fixtureDay,naps:[{'start':5000,'end':5600,'duration_min':10}]);
    await db.execute('DROP TABLE sleep_nap');
    await db.execute('DROP TABLE sleep_block');
    LocalDb.lastRebuild = null;
    db = await reopen();
    expect(LocalDb.lastRebuild,isNull);
    expect(await db.query('sleep_nap',columns:['day_id','start_ts','end_ts','source']),
      [{'day_id':fixtureDay,'start_ts':5000,'end_ts':5600,'source':'legacy'}]);
    expect(await db.query('input_revision',columns:['rev'],where:'source = ? AND scope = ?',whereArgs:['sleep_nap',fixtureDay]),
      [{'rev':1}]);
    expect(await db.query('sleep_edit_job'),isEmpty);
  });

}
