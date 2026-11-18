// WHY B4: rung 94 runs before the raw-free cleanup; it must not make a
// pre-v106 next-night phantom durable. CLAIM(sleep-block-backfill).
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/compute/nap_overlap_cleanup.dart';
import 'support/sleep_block_fixture.dart';

void main() {
  test('B4 v0.12.1 shape upgrade cannot capture a next-night phantom',() async {
    sqfliteFfiInit(); databaseFactory=databaseFactoryFfi;
    final temp=await Directory.systemTemp.createTemp('sleep-B4-');
    await LocalDb.close(); LocalDb.dbName=p.join(temp.path,'old.db');
    try {
      var db=await LocalDb.instance;
      await db.update('activity_review_meta',{'activated_at':20000});
      await seedDay(db,fixtureDay,naps:[{'start':5000,'end':5600,'duration_min':10}],version:105);
      await seedDay(db,'2026-11-02',version:105,window:{'onset_ms':4500000,'offset_ms':6500000});
      await db.update('day_result',{'payload_json':jsonEncode({'sleep':{'window':{'value':
        {'onset_ms':4500000,'offset_ms':6500000}}},'naps':{'value':[]}})},
        where:"day_id = '2026-11-02'");
      final path=db.path; await LocalDb.close();
      final raw=await databaseFactory.openDatabase(path);
      await raw.execute('DROP TABLE sleep_block');
      await raw.execute('ALTER TABLE sleep_override DROP COLUMN payload_json');
      await raw.execute('PRAGMA user_version = 92'); await raw.close();
      db=await LocalDb.instance;
      await cleanNextNightNapsOnce();
      expect((await SleepBlockStore.live(db,4500,6500)).where((b)=>b.kind==SleepBlockKind.nap),isEmpty,
        reason:'the old phantom must not become a Merge neighbor');
      expect(await db.query('sleep_nap'),isEmpty);
      await db.transaction((tx)=>SleepEditStore.enqueue(tx,fixtureDay,main:false));
      await LocalDb.recomposeNaps(fixtureDay,(await SleepEditStore.status(fixtureDay))!['nap_revision'] as int);
      final bundle=jsonDecode((await LocalDb.dayResult(fixtureDay))!['payload_json'] as String);
      expect(bundle['naps']['value'],isEmpty,reason:'later composition cannot resurrect the phantom');
    } finally { await LocalDb.close(); await temp.delete(recursive:true); }
  });
}
