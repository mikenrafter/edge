// WHY: transport uses supported release shapes, and the real ladder must
// preserve their readers. CLAIM(sleep-editor-transport), C P1/P2.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'support/sleep_block_fixture.dart';

Future<Map<String,Object?>> readers() async {
  final repo=LocalRepositoryImpl(getProfileMap:()=>{});
  return {'sleep':await repo.getDaySleep(fixtureDay),'naps':await repo.getDayNaps(fixtureDay),
    'windows':await repo.sleepWindows(days:5,before:'2026-11-02'),
    'reminders':await LocalDb.reminderNapWindows('2026-10-01')};
}
void main() {
  late Directory temp;
  setUpAll(() { sqfliteFfiInit(); databaseFactory=databaseFactoryFfi; });
  setUp(() async {
    temp=await Directory.systemTemp.createTemp('sleep-C-proof-');
    await LocalDb.close(); LocalDb.dbName=p.join(temp.path,'proof.db');
  });
  tearDown(() async { await LocalDb.close(); await temp.delete(recursive:true); });
  // catches: the migration changes served measurements or loses retained nap snapshots.
  test('P1 synthetic 92 full fixture retains reader output through the ladder', () async {
    var db=await LocalDb.instance; await seedLegacy(db);
    final before=await readers();
    final oldEdits=await ActivityStore(db).napEdits(fixtureDay);
    final path=db.path; await LocalDb.close();
    final raw=await databaseFactory.openDatabase(path);
    await raw.execute('DROP TABLE sleep_block');
    await raw.execute('ALTER TABLE sleep_override DROP COLUMN payload_json');
    await raw.execute('PRAGMA user_version = 92'); await raw.close();
    db=await LocalDb.instance;
    expect(await readers(),before);
    final actual=await SleepBlockStore.napEdits(db,fixtureDay);
    expect(actual.map((n)=>(n.startSec,n.endSec,n.source,n.snapshot)).toList(),
      oldEdits.map((n)=>(n.startSec,n.endSec,n.source,n.snapshot)).toList());
    expect(await db.query('sleep_block'),hasLength(10)); // 3 mains + 6 edits + pre-review legacy nap
    expect((await db.query('sleep_block')).map((r)=>r['owner_rule']),everyElement(0));
    final once=await snapshot(db); await LocalDb.close(); db=await LocalDb.instance;
    expect(await snapshot(db),once);
  });
  final sample=Platform.environment['SLEEP_BLOCK_PROOF_DB'];
  // catches: a real release DB loses assertions at the migration/transport seam.
  test('P2 owner release sample retains all existing assertions', () async {
    final copy=p.join(temp.path,'owner-copy.db'); await File(sample!).copy(copy);
    final raw=await databaseFactory.openDatabase(copy);
    final mains=await raw.query('sleep_override'); final naps=await raw.query('sleep_nap');
    await raw.close(); LocalDb.dbName=copy; final db=await LocalDb.instance;
    for(final r in mains) {
      expect(await db.query('sleep_block',where:'id = ?',whereArgs:['legacy:main:${r['day_id']}']),hasLength(1));
    }
    for(final r in naps) {
      expect(await db.query('sleep_block',where:'id = ?',whereArgs:['legacy:nap:${r['day_id']}:${r['start_ts']}']),hasLength(1));
    }
  },skip:sample==null?'Owner sample pending; P2 explicitly env-gated by the slice C brief':false);
}
