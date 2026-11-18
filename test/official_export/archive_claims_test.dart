// WHY: CLAIM(official-export-archive-claims) [P2 review F1]. An archive claim
// is a (parent key, bucket, row index, beat count, typed content hash) record,
// never the claim's full content. The record lives in the output file, where
// ExportSpaceBudget sees it (Android keeps TEMP tables in RAM), one overlapping
// bucket group per device at a time. Equal hashes are deduplicated only after
// an exact re-read compare, the same rule sameRawFrame applies to raw frames.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/mapping_worker.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'archive_fixture.dart';
import 'support.dart';

({Uint8List blob,int fp}) _encode(List<Map<String,Object?>> parents,List<Map<String,Object?>> beats) {
  final w=SubstrateArchiveCodec.encodeMergeVerify(ArchiveBucket(archiveTable(parents),archiveTable(beats)));
  return (blob:w.blob,fp:w.fingerprint);
}

/// Reads the output file between writes, as the space budget does in production.
class ProbingSpace implements ExportFreeSpace {
  ProbingSpace(this.path);
  final String path;
  final samples=<({List<String> columns,int rows,int devices})>[];
  @override
  Future<int> readAvailableBytes() async {
    if (!File(path).existsSync()) {return 1<<40;}
    final db=await databaseFactoryFfi.openDatabase(path,options:OpenDatabaseOptions(readOnly:true,singleInstance:false));
    try {
      final info=await db.rawQuery("PRAGMA table_info('archive_claims')");
      if (info.isNotEmpty) {
        final r=(await db.rawQuery('SELECT count(*) AS n,count(DISTINCT device_id) AS d FROM archive_claims')).single;
        samples.add((columns:[for(final c in info) c['name'] as String],rows:r['n'] as int,devices:r['d'] as int));
      }
    } finally {await db.close();}
    return 1<<40;
  }
}

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 test('a claim record holds identity, bucket, row index, beat count and a typed hash, never its content',() async {
  final e=_encode([parent(100,70),parent(101,71)],[beat(100,0),beat(100,1)]);
  final out=await runMappingWorker(MappingInput('archive','',const [],blob:e.blob,fingerprint:e.fp));
  expect(out.rows,hasLength(2));
  final first=out.rows.first;
  expect(first.keys.toSet(),{'device_id','ts_ms','rec_ts','row_index','beats','digest'});
  expect(first['beats'],2);expect(out.rows.last['beats'],0);
  expect(first['digest'],matches(RegExp(r'^[0-9a-f]{64}$')));
  expect(out.rows.last['digest'],isNot(first['digest']));
 });
 test('the claim hash is typed: 72 and 72.0 are different content',() async {
  final asInt=_encode([parent(100,72)],const []),asReal=_encode([parent(100,72.0)],const []);
  Future<Object?> digest(({Uint8List blob,int fp}) e) async=>(await runMappingWorker(MappingInput('archive','',const [],blob:e.blob,fingerprint:e.fp))).rows.single['digest'];
  expect(await digest(asInt),isNot(await digest(asReal)));
  expect(await digest(asInt),await digest(_encode([parent(100,72)],const [])),reason:'equal content hashes equal');
 });
 test('equal hashes are deduplicated only after an exact re-read compare (the hash is never trusted)',() async {
  final same1=_encode([parent(100,70)],[beat(100,0)]),same2=_encode([parent(100,70)],[beat(100,0)]);
  final other=_encode([parent(100,70)],[beat(100,1)]);
  Future<List<Object?>> mismatched(({Uint8List blob,int fp}) x,({Uint8List blob,int fp}) y) async=>(await runMappingWorker(MappingInput('claimsEqual','',[
    {'bucket_id':1,'codec':1,'fingerprint':x.fp,'blob':x.blob},{'bucket_id':2,'codec':1,'fingerprint':y.fp,'blob':y.blob},
  ],json:[[[1,0],[2,0]]]))).rows.map((r)=>r['identity']).toList();
  expect(await mismatched(same1,same2),isEmpty);
  expect(await mismatched(same1,other),[0],reason:'different content is reported whatever the stored hash says');
 });
 test('claims live in the output file, one overlapping group at a time, and dedupe or withhold exactly',() async {
  await withFreshForkDb((db,path) async {
   const a=1792670400,day=86400;
   // Group A (device ''): three buckets overlap. p1 identical in 10 and 11;
   // p4 has the same parent but different beats; p3 is 72 in one bucket and
   // 72.0 in the other. Groups B (later day) and C (other device) are alone.
   await bucket(db,10,[parent(a,70),parent(a+10,72),parent(a+20,73),parent(a+30,71)],[beat(a,0),beat(a+20,0)]);
   await bucket(db,11,[parent(a,70),parent(a+20,73),parent(a+30,71)],[beat(a,0),beat(a+20,1)]);
   await bucket(db,12,[parent(a+10,72.0)],const []);
   await bucket(db,13,[parent(a+2*day,60)],const []);
   await bucket(db,14,[{...parent(a,65),'device_id':'ring-A'}],const [],device:'ring-A');
   await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
   await LocalDb.close();
   final outPath='${File(path).parent.path}/mapped.db';
   final space=ProbingSpace(outPath);
   final report=await mapOfficialSnapshot(snapshotPath:path,outputPath:outPath,factory:databaseFactoryFfi,
     space:ExportSpaceBudget(source:space,liveFloorBytes:0));
   expect(space.samples,isNotEmpty,reason:'the claim table must be visible in the output file, not TEMP');
   for(final s in space.samples) {
    expect(s.columns,containsAll(['device_id','ts_ms','bucket_id','row_index','beats','digest']));
    expect(s.columns,isNot(contains('claim')),reason:'no claim content is stored');
   }
   expect(space.samples.map((s)=>s.rows).reduce((x,y)=>x>y?x:y),lessThanOrEqualTo(8),reason:'only group A (8 claims) at once');
   expect(space.samples.map((s)=>s.devices).reduce((x,y)=>x>y?x:y),1,reason:'one device per group');
   final out=await databaseFactoryFfi.openDatabase(report.path,options:OpenDatabaseOptions(readOnly:true));
   try {
    expect((await out.rawQuery("SELECT name FROM sqlite_master WHERE name LIKE 'archive_claim%'")),isEmpty);
    expect((await out.query('decoded_onehz',where:"device_id=''",orderBy:'rec_ts')).map((r)=>[r['rec_ts'],r['hr']]).toList(),
      [[a,70],[a+30,71],[a+2*day,60]],reason:'identical overlap once; changed-beats and int/real claims withheld');
    expect((await out.query('decoded_rr')).map((r)=>[r['rec_ts'],r['beat_index']]).toList(),[[a,0]]);
    final manifest=(await out.query('fork_transition_manifest')).single['payload_json'] as String;
    expect(manifest,contains('identical archive overlap'));expect(manifest,contains('conflicting archive claims'));
   } finally {await out.close();}
  });
 },timeout:const Timeout(Duration(minutes:8)));
}
