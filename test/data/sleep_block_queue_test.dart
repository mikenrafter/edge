// WHY: nap edits must never invalidate an in-flight night or release its pin.
// CLAIM(sleep-block-one-queue); catches routing naps through the night counter.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
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
    await db.insert('sync_cursor', {'name': LocalDb.kFrozenHeadlineCursor, 'value': jsonEncode({'day': day, 'readiness': 71})});
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
}
