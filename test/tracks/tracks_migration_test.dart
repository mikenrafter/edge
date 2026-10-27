import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';

import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async => env = await BackupEnv.create('tracks_migration_t1.db'));
  tearDown(() async => env.dispose());

  test('v81 migration retains doses, imports only residual total, and is idempotent', () async {
    await LocalDb.putJournalMetrics('2026-10-01', {
      'caffeine_mg': const JournalMetricValue(250),
      'alcohol_units': const JournalMetricValue(2),
    });
    await LocalDb.putJournalMetrics('2026-10-02', {
      'caffeine_mg': const JournalMetricValue(50),
    });
    await LocalDb.putMomentLabel(const MomentLabel(date: '2026-10-01',
      hhmm: '09:00', label: 'caffeine', caffeineMg: 100, answeredAtMs: 1));
    await LocalDb.putMomentLabel(const MomentLabel(date: '2026-10-01',
      hhmm: '13:00', label: 'caffeine', caffeineMg: 80, answeredAtMs: 2));
    await LocalDb.putMomentLabel(const MomentLabel(date: '2026-10-02',
      hhmm: '09:00', label: 'caffeine', caffeineMg: 100, answeredAtMs: 3));
    await LocalDb.close();
    final legacy = await databaseFactory.openDatabase(p.join(env.dbDir, LocalDb.dbName));
    // Reconstruct the previous head: journal and moments exist, Tracks does not.
    await legacy.execute('DROP VIEW IF EXISTS track_event_feed');
    for (final table in ['track_event', 'track_setup_history', 'track_definition']) {
      await legacy.execute('DROP TABLE IF EXISTS $table');
    }
    await legacy.execute('PRAGMA user_version = 81');
    await legacy.close();

    final migrated = await LocalDb.instance;
    expect(LocalDb.schemaVersion, greaterThan(81));
    final caffeine = await migrated.query('track_event_feed',
      where: 'track_id = ? AND date = ?', whereArgs: ['caffeine', '2026-10-01'],
      orderBy: 'at_ms');
    // 250 mg daily total = 100 + 80 timed mg + 70 untimed residual; never 430.
    expect(caffeine.map((e) => e['amount']).toList(), [70, 100, 80]);
    expect(caffeine.map((e) => e['at_ms']).toList(),
      [null, 1790845200000, 1790859600000]);
    final alcohol = (await migrated.query('track_event_feed', where: 'track_id = ?',
      whereArgs: ['alcohol'])).single;
    expect(alcohol['amount'], 2);
    expect(alcohol['at_ms'], isNull, reason: 'a daily total has no recorded instant');
    final lowerTotal = await migrated.query('track_event_feed',
      where: 'track_id = ? AND date = ?', whereArgs: ['caffeine', '2026-10-02']);
    expect(lowerTotal, hasLength(1));
    expect(lowerTotal.single['amount'], 100,
      reason: 'explicit timed doses survive an inconsistent lower daily total');
    expect((await LocalDb.journalMetricsForDay('2026-10-01'))['caffeine_mg']!.value, 250);
    final before = await migrated.query('track_event_feed', orderBy: 'id');
    await LocalDb.close();
    expect(await (await LocalDb.instance).query('track_event_feed', orderBy: 'id'), before);
  });

  test('workout and food owners mirror edits and deletion without copied records', () async {
    final db = await LocalDb.instance;
    const start = 1790863200;
    Future<void> workout(int end) => LocalDb.putSession({
      'id': 'w1', 'start_ts': start, 'end_ts': end, 'type': 'running',
      'status': 'done', 'source': 'manual', 'created_at': start * 1000,
    });
    await workout(start + 1800);
    await NutritionDb.put(db, const FoodEntry(id: 'food1', date: '2026-10-01',
      atTs: start, meal: 'dinner', label: 'Soup'));
    final feed = await db.query('track_event_feed');
    expect(feed.where((e) => e['track_id'] == 'late_workout'), hasLength(1));
    final meal = feed.singleWhere((e) => e['track_id'] == 'late_meal');
    expect(meal['at_ms'], start * 1000);
    expect(meal['amount'], isNull);
    await workout(start + 3600);
    expect((await db.query('track_event_feed')).where((e) => e['track_id'] == 'late_workout'), hasLength(1));
    expect(await db.query('track_event'), isEmpty,
      reason: 'the existing owner stays the only persisted record');
    await LocalDb.deleteSession('w1');
    await NutritionDb.delete(db, 'food1');
    expect(await db.query('track_event_feed'), isEmpty);
  });

  test('only taken medication slots appear, and undo removes their mirror', () async {
    final db = await LocalDb.instance;
    await MedDb.putDef(db, const MedDef(key: 'vitamin_d', label: 'Vitamin D',
      doseValue: 1000, doseUnit: 'IU'));
    await MedDb.mark(db, medKey: 'vitamin_d', date: '2026-10-01', slotMin: 480,
      taken: false, skipped: true);
    expect(await db.query('track_event_feed'), isEmpty);
    await MedDb.mark(db, medKey: 'vitamin_d', date: '2026-10-01', slotMin: 480, taken: true);
    final taken = (await db.query('track_event_feed')).single;
    expect(taken['track_id'], 'med:vitamin_d');
    expect(taken['amount'], isNull, reason: 'a definition default is not a recorded dose amount');
    await MedDb.mark(db, medKey: 'vitamin_d', date: '2026-10-01', slotMin: 480, taken: false);
    expect(await db.query('track_event_feed'), isEmpty);
    expect(await db.query('track_event'), isEmpty);
  });
}
