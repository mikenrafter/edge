// WHY: a realistic release-shape sample proves the same real ladder and
// projection parity without ever editing the owner's export in place.
// CLAIM(sleep-block-backfill). Intentionally opt-in; no pilot-shape migration.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'support/sleep_projection.dart';
import 'support/sleep_block_fixture.dart' show snapshot;

void main() {
  final source = Platform.environment['SLEEP_BLOCK_PROOF_DB'];
  test('B12 real sample survives rung 94 and repeated open', () async {
    sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;
    final root = await Directory.systemTemp.createTemp('sleep-block-proof-');
    final priorName = LocalDb.dbName;
    try {
      final copy = p.join(root.path,'proof.db');
      await File(source!).copy(copy);
      final beforeDb = await databaseFactory.openDatabase(copy);
      final oldMains = [for (final r in await beforeDb.query('sleep_override')) {...r,'payload_json':null}];
      final oldNaps = await beforeDb.query('sleep_nap');
      final windows = await LocalDb.servedMainWindows(beforeDb,'0001-01-01','9999-12-31');
      await beforeDb.close();
      await LocalDb.close(); LocalDb.dbName=copy;
      final db = await LocalDb.instance;
      expect(await db.query('sleep_override'),oldMains);
      for (final nap in oldNaps) {
        expect((await db.query('sleep_nap',where:'day_id = ? AND start_ts = ?',
          whereArgs:[nap['day_id'],nap['start_ts']])).single,nap);
      }
      expect(await LocalDb.servedMainWindows(db,'0001-01-01','9999-12-31'),windows);
      final projectedNaps = await db.query('sleep_nap');
      expect((await db.query('sleep_block')).length,oldMains.length+projectedNaps.length);
      // Counts are proof evidence only; the source file is never overwritten.
      // ignore: avoid_print
      print('sleep proof mains=${oldMains.length}, naps=${oldNaps.length}, legacy captured=${projectedNaps.length-oldNaps.length}');
      final days = (await db.query('sleep_block',columns:['owner_day'],distinct:true)).map((r)=>r['owner_day'] as String);
      for (final day in days) { await projectionMatches(db,day); }
      final before = await snapshot(db);
      await SleepBlockStore.backfill(db);
      expect(await snapshot(db),before);
      await LocalDb.close();
      expect(await snapshot(await LocalDb.instance),before);
    } finally {
      await LocalDb.close(); LocalDb.dbName=priorName; await root.delete(recursive:true);
    }
  },skip:source == null ? 'Owner must manually fix a COPY before setting SLEEP_BLOCK_PROOF_DB' : false);
}
