// WHY: backups must preserve wearer decisions and stable identities without
// resurrecting removed sleep. CLAIM(sleep-editor-transport), spec §2.2/§6.1.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/data/sleep_import_rules.dart';
import '../data/support/sleep_block_fixture.dart' show blockRow, seedDay;

const day = '2026-10-12', otherDay = '2026-10-13';
final start = DateTime(2026,10,12,14).millisecondsSinceEpoch ~/ 1000;
Map<String,Object?> block(String id, {String owner = day, int? s, int? e,
    String kind = 'nap', String state = 'live', String? survivor, int rule = 1}) =>
  {...blockRow(id,day:owner,start:s ?? start,end:e ?? start+2400,
    kind:kind,state:state,mergedInto:survivor), 'owner_rule':rule};

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override Future<String?> getApplicationSupportPath() async => root;
  @override Future<String?> getApplicationDocumentsPath() async => root;
}

// A real nap compose between the sleep stage and bundle copy pins the
// pre-import boundary: this imported block was never a local assertion.
class _NapBeforeResultCopy implements ImportTableProbe {
  _NapBeforeResultCopy(this.day);
  final String day;
  bool ran=false;
  @override
  Future<void> beforeTable(String table) async {
    if(table!='day_result') return;
    final db=await LocalDb.instance;
    final jobs=await db.query('sleep_edit_job',where:'day_id = ?',whereArgs:[day]);
    if(jobs.isEmpty) return;
    await LocalDb.recomposeNaps(day,jobs.single['nap_revision'] as int);
    ran=true;
  }
}

void main() {
  late Database db;
  late Directory temp;
  var serial = 0;
  Future<void> clear() async {
    for(final t in ['sleep_block','sleep_nap','sleep_override','sleep_edit_job',
      'activity_suggestions','day_result','compute_freshness']) { await db.delete(t); }
  }
  Future<String> backup(List<Map<String,Object?>> rows) async {
    await clear();
    for(final r in rows) { await db.insert('sleep_block',r); }
    await SleepBlockStore.projectForTest(db,rows.map((r)=>r['owner_day'] as String).toSet());
    final path=p.join(temp.path,'source-${serial++}.db');
    await db.execute("VACUUM INTO '$path'");
    await clear();
    return path;
  }
  Future<void> restoreBackup(String path) async { await LocalDb.importFromDbFile(path); }
  Future<List<Map<String,Object?>>> rows() => db.query('sleep_block',orderBy:'id');
  Future<List<SleepImportEntry>> notes() => SleepImportReport.load();
  setUpAll(() { TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit(); databaseFactory=databaseFactoryFfi; });
  setUp(() async {
    SharedPreferences.setMockInitialValues({}); await Prefs.ensureLoaded();
    temp=await Directory.systemTemp.createTemp('sleep-C-');
    PathProviderPlatform.instance=_Paths(temp.path);
    await LocalDb.close(); LocalDb.dbName=p.join(temp.path,'local.db');
    db=await LocalDb.instance;
  });
  tearDown(() async { ImportHooks.reset(); await LocalDb.close(); await temp.delete(recursive:true); });

  // catches: restore leaves the already-upgraded destination block table empty.
  test('T1 old backup without blocks is absorbed immediately', () async {
    final path=await backup([]);
    final src=await databaseFactory.openDatabase(path);
    await src.execute('DROP TABLE sleep_block');
    await src.insert('sleep_nap',{'day_id':day,'start_ts':start,'end_ts':start+2400,
      'source':'manual','created_at':5});
    await src.close(); await restoreBackup(path);
    expect((await rows()).single['id'],'legacy:nap:$day:$start');
    expect((await rows()).single['owner_rule'],0);
    expect((await rows()).single['history'],'unavailable');
  });
  // catches: projections override block truth, or an empty block table hides old rows.
  test('T2 blocks win over projections and empty table falls back', () async {
    final path=await backup([{...block('stable'),'revision':17,'merged_into':''}]);
    final src=await databaseFactory.openDatabase(path);
    await src.update('sleep_nap',{'end_ts':start+9000}); await src.close();
    final counts=await LocalDb.importFromDbFile(path);
    expect((await rows()).single['id'],'stable');
    expect((await rows()).single['revision'],0,reason:'foreign counters do not become local receipts');
    expect((await rows()).single['merged_into'],isNull);
    expect((await rows()).single['owner_rule'],1);
    final projected=await db.query('sleep_nap');
    expect(projected,hasLength(1),reason:'the imported block must regenerate its nap projection');
    expect(projected.single['end_ts'],start+2400);
    expect(counts['sleep_nap'],1,reason:'report the one nap projection regenerated from block truth');
    await clear();
    final raw=await databaseFactory.openDatabase(path);
    await raw.delete('sleep_block'); await raw.close(); await restoreBackup(path);
    expect((await rows()).single['id'],'legacy:nap:$day:$start');
    expect((await rows()).single['end_ts'],start+9000);
  });
  // catches: salvage only copies projections, leaving blocks permanently empty.
  test('T3 salvage absorbs legacy and preserves block identities', () async {
    for(final legacy in [true,false]) {
      await clear(); await db.insert('sleep_block',block('salvaged',rule:0));
      await SleepBlockStore.projectForTest(db,{day});
      final localPath=db.path; await LocalDb.close();
      final raw=await databaseFactory.openDatabase(localPath);
      if(legacy) { await raw.execute('DROP TABLE sleep_block'); }
      await raw.execute('CREATE TABLE _raw_old(hex TEXT)');
      await raw.execute('PRAGMA user_version = 2'); await raw.close();
      db=await LocalDb.instance;
      expect(LocalDb.lastRebuild,isNotNull);
      expect((await rows()).single['id'],legacy?'legacy:nap:$day:$start':'salvaged');
      expect((await rows()).single['owner_rule'],0);
    }
  });
  // catches: comparison ignores history, origin, merge target, or ownership rule.
  test('T4 identical is silent but every retained column participates', () async {
    final original=block('same'); final path=await backup([original]);
    await db.insert('sleep_block',original); await restoreBackup(path);
    expect(await notes(),isEmpty);
    for(final change in [<String,Object?>{'history':'absent'},
      {'detected_start':123}, {'detected_end':456}, {'detected_day':otherDay},
      {'merged_into':'missing'}, {'owner_rule':0}]) {
      await db.update('sleep_block',{...original,...change});
      await restoreBackup(path);
      expect((await notes()).where((e)=>e.refused),hasLength(1),reason:'$change');
      expect((await rows()).single,{...original,...change});
    }
  });
  // catches: generic REPLACE overwrites a stable local identity.
  test('T5 differing same id keeps the entire local row', () async {
    final path=await backup([block('same')]);
    final local=block('same',e:start+1200,rule:0);
    await db.insert('sleep_block',local); await restoreBackup(path);
    expect(await rows(),[local]);
    expect((await notes()).single.kind,'refused');
  });
  // catches: unchanged imports rewrite projection rows and enqueue new work.
  test('T6 reimport projects and enqueues nothing', () async {
    final path=await backup([block('same')]); await restoreBackup(path);
    final before=<String,Object?>{for(final t in ['sleep_block','sleep_nap','sleep_edit_job','input_revision'])
      t:await db.query(t)};
    await db.execute('CREATE TEMP TABLE probe(n INTEGER)');
    await db.execute('CREATE TEMP TRIGGER nap_probe AFTER INSERT ON main.sleep_nap BEGIN INSERT INTO probe VALUES(1); END');
    await restoreBackup(path);
    expect({for(final t in before.keys) t:await db.query(t)},before);
    expect(await db.query('probe'),isEmpty);
    await db.insert('sleep_nap',{'day_id':otherDay,'start_ts':1,'end_ts':2,'source':'manual','created_at':1});
    expect(await db.query('probe'),hasLength(1),reason:'positive control proves the write probe works');
  });
  // catches: partial block/projection/job writes survive interruption.
  test('T7 sleep stage rolls back then resume converges', () async {
    final path=await backup([block('a'),block('b',s:start+7200,e:start+9600)]);
    ImportHooks.chunk=(tx,c) async { if(c.table=='sleep_block') { throw StateError('C sleep kill'); } };
    await expectLater(restoreBackup(path),throwsA(isA<StateError>()));
    expect(await rows(),isEmpty); expect(await db.query('sleep_nap'),isEmpty);
    expect(await db.query('sleep_edit_job'),isEmpty);
    ImportHooks.reset();
    final resumed=await ImportJournal.resumeIfUnfinished(force:true);
    expect(resumed.error,isNull); expect(resumed.resumed,isTrue);
    expect((await rows()).map((r)=>r['id']),['a','b']);
    expect(await db.query('sleep_nap'),hasLength(2));
    expect(await db.query('sleep_edit_job'),hasLength(1));
  });
  // catches: selected export misses overlaps/merge dependencies or leaks other measurements.
  test('T8 selected export includes overlap and survivor dependency only', () async {
    for(final r in [block('owned',state:'merged',survivor:'survivor'),
      block('overlap',owner:otherDay,s:start+7200,e:start+9600),
      block('survivor',owner:otherDay,s:start+86400,e:start+90000),
      block('excluded',owner:'2026-10-14',s:start+172800,e:start+175200)]) {
      await db.insert('sleep_block',r);
    }
    await seedDay(db,day);
    await seedDay(db,otherDay);
    final path=await LocalDb.exportDaysDb({day});
    final src=await databaseFactory.openDatabase(path);
    expect((await src.query('sleep_block',orderBy:'id')).map((r)=>r['id']),['overlap','owned','survivor']);
    expect(await src.query('day_result',where:'day_id = ?',whereArgs:[otherDay]),isEmpty);
    expect(await src.query('day_result',where:'day_id = ?',whereArgs:[day]),hasLength(1));
    await src.close(); await clear(); await restoreBackup(path);
    expect((await rows()).map((r)=>r['id']),['overlap','owned','survivor']);
    expect((await notes()).where((e)=>e.day==otherDay && e.kind=='imported'),hasLength(2));
  });
  // catches: deletion resurrects assertions, or cascades into another owner's block.
  test('T9 Delete day removes owner rows and keeps dangling participant history', () async {
    await db.insert('sleep_block',block('survivor'));
    await db.insert('sleep_block',block('participant',owner:otherDay,state:'merged',survivor:'survivor'));
    await SleepBlockStore.projectForTest(db,{day,otherDay});
    final service=MomentReviewService.shared;
    service.stageSleepEditorDraft(day,await SleepBlockStore.plan(db,day,[AddNap(start+10000,start+12400)]));
    service.stageSleepEditorDraft(otherDay,await SleepBlockStore.plan(db,otherDay,[]));
    final app=AppState.forTesting();
    try { await app.deleteDays({day}); } finally { app.dispose(); }
    expect(service.readSleepEditorDraft(day).plan,isNull);
    expect(service.readSleepEditorDraft(otherDay).plan,isNotNull);
    expect((await rows()).map((r)=>r['id']),['participant']);
    final entry=(await SleepBlockStore.read(db,otherDay)).entries.single;
    expect(entry.removed,isTrue); expect(entry.mergedInto,isNull);
    expect(await db.query('sleep_nap',where:'day_id = ?',whereArgs:[day]),isEmpty);
    expect((await db.query('track_unknown_day')).map((r)=>r['date']),contains(day));
  });
  // catches: recent support slices silently omit durable assertion history.
  test('T10 recent slice contains blocks', () async {
    await db.insert('sleep_block',block('slice',rule:0));
    final path=await exportRecentSlice(now:DateTime(2026,10,15));
    final src=await databaseFactory.openDatabase(path);
    expect((await src.query('sleep_block')).single['owner_rule'],0); await src.close();
  });
  // catches: an edits-only install is misclassified fresh and settings overwritten.
  test('T11 blocks alone establish an install', () async {
    expect(await LocalDb.backupPrefsFreshInstall(),isTrue);
    await db.insert('sleep_block',block('only'));
    expect(await LocalDb.backupPrefsFreshInstall(),isFalse);
  });
  // catches: one malformed payload crashes the entire restore or fabricates history.
  test('T12 malformed legacy rows are retained and reported', () async {
    final report=await db.transaction((tx)=>SleepBlockStore.absorb(tx,
      overrides:[{'day_id':day,'onset_ts':100,'offset_ts':101,'source':'rejected','created_at':5}],
      naps:[{'day_id':day,'start_ts':200,'end_ts':300,'source':'future','created_at':5,'payload_json':'{bad'},
        {'day_id':day,'start_ts':2000,'end_ts':2600,'source':'confirmed','created_at':5,
          'payload_json':'{"start":1900,"end":2700,"duration_min":10}'}],
      mode:AbsorbMode.importFile));
    expect(report.map((e)=>e.kind),containsAll(['placeholder_bounds','unknown_source','malformed_payload']));
    expect((await rows()).map((r)=>(r['state'],r['history'])),
      [('removed','unavailable'),('removed','unavailable'),('live','known')]);
  });
  // catches: interactive spacing incorrectly refuses historical source pairs.
  test('T13 source internal twenty minute pair imports whole', () async {
    final path=await backup([block('a'),block('b',s:start+3600,e:start+6000)]);
    await restoreBackup(path); expect(await rows(),hasLength(2));
    expect((await notes()).where((e)=>e.kind=='close-in-source'),hasLength(1));
    expect((await LocalDb.importFromDbFile(path)).sleepCloseReview,isEmpty,
      reason:'identical re-import has no newly imported historical pair');
  });
  // catches: close imported neighbors merge automatically or disappear.
  test('T14 close local pair remains live historical sleep', () async {
    final path=await backup([block('incoming',s:start+3600,e:start+6000)]);
    await db.insert('sleep_block',block('local')); await restoreBackup(path);
    expect((await rows()).map((r)=>r['state']),['live','live']);
    expect((await notes()).where((e)=>e.kind=='close-with-local'),hasLength(1));
  });
  // catches: report lives only in route memory.
  test('T15 report survives closing and reopening the database', () async {
    final path=await backup([block('same')]);
    await db.insert('sleep_block',block('same',e:start+1200)); await restoreBackup(path);
    final before=(await notes()).map((e)=>e.toJson()).toList();
    await LocalDb.close(); db=await LocalDb.instance;
    expect((await notes()).map((e)=>e.toJson()).toList(),before);
  });
  // catches: a newer imported main replaces local onset 100.
  test('T16 restore keeps local onset 100 and reports refusal', () async {
    final path=await backup([block('foreign-main',kind:'main',s:500,e:600)]);
    await db.insert('sleep_block',block('local-main',kind:'main',s:100,e:200));
    await SleepBlockStore.projectForTest(db,{day}); await restoreBackup(path);
    expect((await db.query('sleep_override')).single['onset_ts'],100);
    expect((await notes()).single.other,'main_exists');
  });
  // catches: overlap predicate filters out removed local blocks (required mutation).
  test('T17 removed local blocks beat foreign overlaps and leave dangling merges', () async {
    final path=await backup([block('incoming'),block('participant',owner:otherDay,
      s:start+10000,e:start+11000,state:'merged',survivor:'incoming')]);
    await db.insert('sleep_block',block('local',s:start+600,e:start+1800,state:'removed'));
    await restoreBackup(path);
    expect((await rows()).map((r)=>r['id']),['local','participant']);
    expect((await notes()).where((e)=>e.refused).single.other,'overlap');
    final entry=(await SleepBlockStore.read(db,otherDay)).entries.single;
    expect(entry.removed,isTrue); expect(entry.mergedInto,isNull);
  });
  // catches: imported accepted activity overrides a locally decided suggestion.
  test('T18 locally decided linked suggestion prevents capture', () async {
    final path=await backup([block('incoming')]);
    await db.insert('activity_suggestions',{'id':'decided','kind':'nap','day_id':day,
      'start_ts':start,'end_ts':start+2400,'details_json':'{}',
      'detection_start':start,'detection_end':start+2400,'status':'discarded',
      'linked_id':'incoming','created_at':5,'updated_at':5});
    await restoreBackup(path); expect(await rows(),isEmpty);
    expect((await notes()).single.other,'decided_locally');
  });
  // catches: main uniqueness index silently ignores conflicts with non-live mains.
  test('T19 any local main state prevents a foreign main', () async {
    final path=await backup([block('foreign',kind:'main')]);
    for(final state in ['live','removed','merged']) {
      await clear(); await db.insert('sleep_block',block('local',kind:'main',state:state));
      await restoreBackup(path);
      expect((await rows()).map((r)=>r['id']),['local']);
      expect((await notes()).single.other,'main_exists');
    }
  });
  // WHY C1: replacing a bundle does not replace local block truth, including
  // edits without activity suggestions. Raw presence excludes the no-raw edge.
  // CLAIM(sleep-editor-transport).
  for(final removed in [true,false]) {
    test('C1 import recomposes a local ${removed ? 'removed' : 'typed'} nap with raw still present',() async {
      final path=await backup([block('foreign')]);
      final src=await databaseFactory.openDatabase(path);
      await seedDay(src,day,naps:[{'start':start,'end':start+2400,'duration_min':40}]);
      await src.update('day_result',{'payload_json':jsonEncode({'date':day,
        'naps':{'value':[{'start':start,'end':start+2400,'duration_min':40}]},
        'scalars':{'nap_min':40}})},where:'day_id = ?',whereArgs:[day]);
      await src.close();
      await db.insert('sleep_block',block('local',s:start+600,e:start+1800,
        state:removed?'removed':'live'));
      await SleepBlockStore.projectForTest(db,{day});
      await seedDay(db,day,naps:removed?[]:[{'start':start+600,'end':start+1800,'duration_min':20}]);
      await db.update('day_result',{'finalized':0},where:'day_id = ?',whereArgs:[day]);
      await db.insert('decoded_onehz',{'device_id':'','ts_ms':start*1000,
        'rec_ts':start,'counter':1,'hr':60});
      expect(await db.query('activity_suggestions'),isEmpty);
      await restoreBackup(path);
      expect(await db.query('decoded_onehz',where:'rec_ts = ?',whereArgs:[start]),hasLength(1));
      final jobs=await db.query('sleep_edit_job',where:'day_id = ?',whereArgs:[day]);
      expect(jobs,hasLength(1),reason:'a replaced bundle needs local nap work even when absorb inserted nothing');
      expect(jobs.single['revision'],0,reason:'this is nap-only work');
      expect(jobs.single['nap_revision'],greaterThan(jobs.single['nap_applied_revision'] as int));
      final app=AppState.forTesting();
      try { await app.sleepEditRunner.start(); } finally { app.dispose(); }
      final value=jsonDecode((await LocalDb.dayResult(day))!['payload_json'] as String);
      expect(value['naps']['value'],hasLength(removed?0:1));
      expect(value['scalars']['nap_min'],removed?0:20);
      if(!removed) { expect(value['naps']['value'].single['start'],start+600); }
      expect((await db.query('sleep_edit_job')).single['phase'],'done');
    });
  }
  test('C1 fresh restore queues only the absorb receipt',() async {
    final path=await backup([block('fresh')]);
    final src=await databaseFactory.openDatabase(path);
    await seedDay(src,day,naps:[{'start':start,'end':start+2400,'duration_min':40}]);
      await src.update('day_result',{'payload_json':jsonEncode({'date':day,
        'naps':{'value':[{'start':start,'end':start+2400,'duration_min':40}]},
        'scalars':{'nap_min':40}})},where:'day_id = ?',whereArgs:[day]);
    await src.close();
    expect(await rows(),isEmpty);
    final probe=_NapBeforeResultCopy(day);
    ImportHooks.table=probe;
    await restoreBackup(path);
    expect(probe.ran,isTrue,reason:'the absorb receipt was acknowledged before the bundle copy');
    final jobs=await db.query('sleep_edit_job');
    expect(jobs,hasLength(1));
    expect([jobs.single['revision'],jobs.single['nap_revision'],jobs.single['nap_applied_revision']],[0,1,1],
      reason:'blocks from this import do not need a second nap receipt, even after the first was applied');
  });
  test('C1 import queues beyond one hundred local nap days without a cap',() async {
    final dates=[for(var i=0;i<101;i++) DateTime(2026,1,1+i,14)];
    final days=dates.map(dayLabelOf).toList();
    final starts=[for(final date in dates) date.millisecondsSinceEpoch~/1000];
    final foreign=[for(var i=0;i<days.length;i++) block('foreign-$i',owner:days[i],
      s:starts[i],e:starts[i]+2400)];
    final protectedStart=DateTime(2025,12,30,14).millisecondsSinceEpoch~/1000;
    final path=await backup([...foreign,block('protected-foreign',owner:'2025-12-30',
      s:protectedStart,e:protectedStart+2400)]);
    final src=await databaseFactory.openDatabase(path);
    for(final d in days) { await seedDay(src,d); }
    await seedDay(src,'2025-12-30');
    await src.close();
    for(var i=0;i<days.length;i++) {
      await db.insert('sleep_block',block('local-$i',owner:days[i],state:'removed',
        s:starts[i],e:starts[i]+2400));
      await seedDay(db,days[i]);
    }
    await db.update('day_result',{'finalized':0});
    for(final d in ['2025-12-30','2025-12-31']) {
      final s=DateTime.parse(d).add(const Duration(hours:14)).millisecondsSinceEpoch~/1000;
      await db.insert('sleep_block',block('untouched-$d',owner:d,state:'removed',s:s,e:s+2400));
      await seedDay(db,d);
    }
    await restoreBackup(path);
    final jobs=await db.query('sleep_edit_job');
    expect(jobs,hasLength(101),reason:'the hundred-day transaction boundary is not a work limit');
    expect(jobs.map((r)=>r['day_id']).toSet(),days.toSet());
    expect(jobs.every((r)=>r['revision']==0 && (r['nap_revision'] as int)>(r['nap_applied_revision'] as int)),isTrue);
  });
  // WHY C2: Delete everything removes the destination activation marker.
  // A pre-94 file still contains real detector naps that composition must keep.
  // CLAIM(sleep-editor-transport).
  for(final mode in ['source-cutoff','missing-source-meta','next-night-phantom']) {
    test('C2 wiped restore preserves pre-review naps: $mode',() async {
      final phantom=mode=='next-night-phantom';
      final path=await backup([]);
      final src=await databaseFactory.openDatabase(path);
      await src.execute('DROP TABLE sleep_block');
      await src.execute('PRAGMA user_version = 92');
      if(mode=='source-cutoff') {
        await src.update('activity_review_meta',{'activated_at':start+3000});
      } else { await src.execute('DROP TABLE activity_review_meta'); }
      final tooLate=mode=='source-cutoff'?start+7200:
        DateTime.now().millisecondsSinceEpoch~/1000+3600;
      await seedDay(src,day,naps:[
        {'start':start,'end':start+1200,'duration_min':20},
        {'start':tooLate,'end':tooLate+1200,'duration_min':20},
        if(phantom) {'start':start+4000,'end':start+4600,'duration_min':10},
      ]);
      if(phantom) { await seedDay(src,otherDay,
        window:{'onset_ms':(start+3600)*1000,'offset_ms':(start+6000)*1000}); }
      await src.close();
      await LocalDb.wipeAll();
      expect(await db.query('activity_review_meta'),isEmpty);
      await restoreBackup(path);
      final blocks=await rows();
      expect(blocks,hasLength(1),reason:'source activation, else import start, preserves exactly the eligible real nap');
      expect([blocks.single['id'],blocks.single['source'],blocks.single['state'],blocks.single['history']],
        ['legacy:nap:$day:$start','legacy','live','known']);
      expect((await db.query('sleep_nap')).map((r)=>r['start_ts']),[start],
        reason:'post-cutoff naps and next-night phantoms never become projections');
      await db.transaction((tx)=>SleepEditStore.enqueue(tx,day,main:false));
      final job=(await db.query('sleep_edit_job',where:'day_id = ?',whereArgs:[day])).single;
      await LocalDb.recomposeNaps(day,job['nap_revision'] as int);
      final value=jsonDecode((await LocalDb.dayResult(day))!['payload_json'] as String);
      expect(value['naps']['value'].map((n)=>n['start']),[start]);
      expect(value['scalars']['nap_min'],20);
    });
  }
  // WHY G1: old exports can lack optional result columns. Reading their naps
  // must neither abort the entire import nor lose the source's recorded night.
  // CLAIM(sleep-editor-transport); discovered by the full db_integrity gate.
  test('G1 sparse legacy results import safely and retain the next-night exclusion',() async {
    const protectedDay='2026-10-11';
    await seedDay(db,protectedDay);
    final protected=(await db.query('day_result')).single;
    final path=p.join(temp.path,'sparse-source.db');
    final src=await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE day_result(day_id TEXT NOT NULL, algo_version INTEGER NOT NULL, '
      'payload_json TEXT NOT NULL, computed_at INTEGER NOT NULL, finalized INTEGER NOT NULL, '
      'PRIMARY KEY(day_id,algo_version))');
    final phantom=start+8*3600+600;
    for(final value in [
      {'day':day,'payload':{'naps':{'value':[
        {'start':start,'end':start+1200,'duration_min':20},
        {'start':phantom,'end':phantom+600,'duration_min':10},
      ]},'scalars':{'nap_min':30}}},
      {'day':otherDay,'payload':{'sleep':{'window':{'value':{
        'onset_ms':(start+8*3600)*1000,'offset_ms':(start+17*3600)*1000}}},'naps':{'value':[]}}},
      {'day':protectedDay,'payload':{'src':'foreign'}},
    ]) {
      await src.insert('day_result',{'day_id':value['day'],
        'algo_version':protected['algo_version'],'payload_json':jsonEncode(value['payload']),
        'computed_at':1,'finalized':1});
    }
    await src.close();
    Object? importError;
    try { await restoreBackup(path); } catch(error) { importError=error; }
    expect(importError,isNull,
      reason:'missing skipped/window columns are a legacy shape, not a reason to abort all tables');
    expect((await db.query('day_result',where:'day_id = ?',whereArgs:[protectedDay])).single['payload_json'],
      protected['payload_json'],reason:'source compatibility must retain the finalized-row guard');
    final naps=await rows();
    expect(naps,hasLength(1),reason:'retain the real nap, exclude the recorded next night');
    expect([naps.single['start_ts'],naps.single['source'],naps.single['history']],[start,'legacy','known']);
    final jobs=await db.query('sleep_edit_job',where:'day_id = ?',whereArgs:[day]);
    expect(jobs,hasLength(1));
    await LocalDb.recomposeNaps(day,jobs.single['nap_revision'] as int);
    final value=jsonDecode((await LocalDb.dayResult(day))!['payload_json'] as String);
    expect(value['naps']['value'].map((n)=>n['start']),[start]);
    expect(value['scalars']['nap_min'],20);
  });
  // WHY G2: journal progress is not an input replacement. Empty sleep stages
  // must preserve cached-input identity; a real accepted block must change it.
  // CLAIM(sleep-editor-transport); full E16/input-revision gate regression.
  test('G2 empty sleep stage preserves identity but a real import rotates it',() async {
    final path=p.join(temp.path,'empty-sleep-stage.db');
    final ddl=(await db.query('sqlite_master',columns:['sql'],
      where:"type = 'table' AND name = 'sleep_block'")).single['sql'] as String;
    var src=await databaseFactory.openDatabase(path);
    await src.execute(ddl);await src.close();
    final identity=await LocalDb.storeIdentity();
    final generation=LocalDb.cacheGeneration;
    await restoreBackup(path);
    expect(await LocalDb.storeIdentity(),identity,reason:'an empty stage committed no input history');
    expect(LocalDb.cacheGeneration,generation,reason:'journal-only progress must not invalidate computed inputs');
    expect(await rows(),isEmpty);
    src=await databaseFactory.openDatabase(path);
    await src.insert('sleep_block',block('real-input-change'));await src.close();
    await restoreBackup(path);
    expect((await rows()).single['id'],'real-input-change');
    expect(await LocalDb.storeIdentity(),isNot(identity),reason:'accepted block and new identity commit atomically');
    expect(LocalDb.cacheGeneration,greaterThan(generation));
  });
}
