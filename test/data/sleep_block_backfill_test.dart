// WHY: rung 94 must preserve sleep assertions on every supported open path.
// CLAIM(sleep-block-backfill). catches: creator or upgrade hook omitted.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

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
  await db.execute('PRAGMA user_version = $version');
  await db.close();
}
Future<void> expectBlockTable(Database db) async {
  expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='sleep_block'"),
      [{'name': 'sleep_block'}]);
}
void main() {
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  setUp(() async { await LocalDb.close(); await databaseFactory.deleteDatabase(await dbPath()); });
  tearDown(() async { await LocalDb.close(); await databaseFactory.deleteDatabase(await dbPath()); });
  test('B1 fresh open creates sleep_block and the one-live-main index', () async {
    final db = await reopen();
    await expectBlockTable(db);
    expect((await db.rawQuery('PRAGMA index_list(sleep_block)')).map((r) => r['name']),
        contains('idx_sleep_block_live_main'));
  });
  for (final version in [92, 93]) {
    test('B${version == 92 ? 2 : 3} upgrade from $version absorbs a stored main', () async {
      var db = await reopen();
      await db.insert('sleep_override', {'day_id':'2026-11-01', 'onset_ts':100,
        'offset_ts':200, 'source':'manual', 'created_at':7});
      await rewind(version);
      db = await reopen();
      await expectBlockTable(db);
      expect((await db.query('sleep_block')).single['id'], 'legacy:main:2026-11-01');
    });
  }
  test('B4 same-version repair recreates a missing table', () async {
    await reopen();
    await rewind(LocalDb.schemaVersion);
    await expectBlockTable(await reopen());
  });
}
