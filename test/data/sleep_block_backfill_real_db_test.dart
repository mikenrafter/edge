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
      await LocalDb.close(); LocalDb.dbName=copy;
      final db = await LocalDb.instance;
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
