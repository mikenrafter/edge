import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('old and same-version databases add nullable doses without backfilling totals', () async {
    final env = await BackupEnv.create('typical_dose_migration.db');
    addTearDown(env.dispose);
    await LocalDb.putMomentLabel(const MomentLabel(date: '2026-10-01',
      hhmm: '09:00', label: 'caffeine', answeredAtMs: 1));
    await LocalDb.putJournalMetrics('2026-10-01', {
      'caffeine_mg': const JournalMetricValue(200, atMinuteOfDay: 540),
    });
    final path = p.join(env.dbDir, LocalDb.dbName);
    for (final upgrade in [true, false]) {
      await LocalDb.close();
      final legacy = await databaseFactory.openDatabase(path);
      // Reconstruct the old schema before removing the dose column. The
      // newer Tracks view depends on that column and did not exist then.
      await legacy.execute('DROP VIEW IF EXISTS track_event_feed');
      await legacy.execute('ALTER TABLE moment_label DROP COLUMN caffeine_mg');
      if (upgrade) await legacy.execute('PRAGMA user_version = 80');
      await legacy.close();
      final migrated = await LocalDb.instance;
      final columns = await migrated.rawQuery('PRAGMA table_info(moment_label)');
      expect(columns.where((c) => c['name'] == 'caffeine_mg'), hasLength(1));
      expect((await LocalDb.momentLabels(date: '2026-10-01')).single.caffeineMg, isNull);
      expect((await migrated.query('journal_metric')).single['value'], 200);
    }
    // Reopening again leaves the one column and historical null unchanged.
    await LocalDb.close();
    expect((await LocalDb.momentLabels(date: '2026-10-01')).single.caffeineMg, isNull);
  });
}
