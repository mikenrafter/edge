// Run explicitly: flutter test tool/bench_finalized_day_index.dart.
// Uses a real engine payload, repeated over three years and 12 algo siblings.
// This is a manual storage benchmark, outside the regular test discovery path.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common/sqflite_logger.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart' as native;

import '../test/support/synthetic_day.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('measure a three-year multi-version imported-index build', () async {
    sqfliteFfiInit();
    var measuring = false;
    var busyObserved = false;
    var journalStartedMs = -1;
    var journalSaveMs = -1;
    var indexSqlMs = -1;
    var indexFinishedMs = -1;
    var buildMs = -1;
    Timer? journalTimer;
    late Stopwatch watch;
    final journalDone = Completer<void>();
    void startJournalProbe(String path) {
      journalTimer = Timer(const Duration(milliseconds: 250), () async {
        try {
          final probe = native.sqlite3.open(path);
          try {
            probe.execute('PRAGMA busy_timeout=0');
            try {
              probe.execute('BEGIN IMMEDIATE');
              probe.execute('ROLLBACK');
            } on native.SqliteException catch (error) {
              if (error.resultCode != 5) rethrow;
              busyObserved = true;
            }
          } finally {
            probe.close();
          }
          if (!busyObserved) throw StateError('index WAL write lock was not observed');
          expect(LocalDb.finalizedDayIndexBuilding.value, isTrue,
              reason: 'queued save has a visible maintenance status');
          journalStartedMs = watch.elapsedMilliseconds;
          final save = Stopwatch()..start();
          await LocalDb.putJournal('2026-07-14', '["mid-build"]', 'saved during index');
          journalSaveMs = save.elapsedMilliseconds;
          journalDone.complete();
        } catch (error, stack) {
          journalDone.completeError(error, stack);
        }
      });
    }
    // The timer runs while native SQL is busy. An independent connection
    // must observe the real WAL lock before the production journal API starts.
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(databaseFactoryFfi,
      options: SqfliteLoggerOptions(log: (event) {
        if (!measuring) return;
        if (event is SqfliteLoggerSqlEvent &&
            event.sql.startsWith('CREATE INDEX IF NOT EXISTS idx_day_result_finalized_payload')) {
          indexSqlMs = event.sw!.elapsedMilliseconds;
          indexFinishedMs = watch.elapsedMilliseconds;
        }
      }));
    // This manually invoked Flutter test lives outside normal discovery.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('finalized_index_volume_');
    await databaseFactory.setDatabasesPath(dir.path);
    LocalDb.dbName = '${dir.path}/volume.db';
    await LocalDb.setForeground(true);
    try {
      final day = SyntheticDay(DateTime(2026, 7, 13));
      for (final (raws, samples) in day.primaryBatches()) {
        await LocalDb.commitSyncBatch(raws, samples, deviceFamily: 'gen4');
      }
      await DerivationEngine().runDays(
        const Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm'),
        {'2026-07-13'}, force: true,
      );
      final row = await LocalDb.dayResult('2026-07-13');
      expect(row, isNotNull);
      final payload = row!['payload_json'] as String;
      expect(payload.length, greaterThan(20000), reason: 'real curves, not padding');
      // Distinct JSON per sibling prevents JSON1's repeated-input parse cache
      // from turning years of independent day payloads into one cached parse.
      final payloadPrefix = payload.substring(0, payload.length - 1);
      final db = await LocalDb.instance;
      expect(db.path, '${dir.path}/volume.db', reason: 'each benchmark gets a fresh file');
      await db.delete('day_result');
      const days = 365 * 3;
      const versions = 12;
      for (var offset = 0; offset < days; offset += 30) {
        final batch = db.batch();
        for (var i = offset; i < offset + 30 && i < days; i++) {
          final date = dayLabelOf(DateTime(2023, 1, 1 + i));
          for (var version = 1; version <= versions; version++) {
            batch.insert('day_result', {
              'day_id': date, 'algo_version': version,
              'payload_json': '$payloadPrefix,"benchmark_revision":"$date:$version"}',
              'window_json': row['window_json'], 'computed_at': 1, 'finalized': 1,
            });
          }
        }
        await batch.commit(noResult: true);
      }
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      final bytes = await File(db.path).length();
      final busyTimeout = (await db.rawQuery('PRAGMA busy_timeout')).single.values.single as int;
      watch = Stopwatch()..start();
      measuring = true;
      final building = LocalDb.prepareFinalizedDayIndex().then((_) {
        buildMs = watch.elapsedMilliseconds;
      });
      startJournalProbe(db.path);
      await Future.wait([building, journalDone.future]);
      watch.stop();
      measuring = false;
      expect(LocalDb.finalizedDayIndexBuilding.value, isFalse);
      expect(busyObserved, isTrue, reason: 'native probe actually met SQLITE_BUSY');
      expect(journalStartedMs, greaterThan(0));
      expect(journalStartedMs, lessThan(indexFinishedMs), reason: 'save started before index SQL finished');
      final journal = await db.query('journal', where: 'date = ?', whereArgs: ['2026-07-14']);
      expect(journal.single['note'], 'saved during index');
      final probe = native.sqlite3.open(db.path);
      try {
        probe.execute('PRAGMA busy_timeout=0');
        probe.execute('BEGIN IMMEDIATE');
        probe.execute('ROLLBACK');
      } finally {
        probe.close();
      }
      expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name = 'idx_day_result_finalized_payload'"), hasLength(1));
      // ignore: avoid_print
      print('INDEX_PRODUCTION build_ms=$buildMs index_sql_ms=$indexSqlMs '
          'busy_timeout_ms=$busyTimeout journal_started_ms=$journalStartedMs '
          'journal_save_ms=$journalSaveMs index_finished_ms=$indexFinishedMs '
          'lock_observed=$busyObserved journal_persisted=true');
      // ignore: avoid_print
      print('INDEX_VOLUME rows=${days * versions} payload_bytes=${payload.length} '
          'database_bytes=$bytes distinct_payloads=${days * versions} '
          'build_ms=$buildMs index_sql_ms=$indexSqlMs busy_timeout_ms=$busyTimeout '
          'journal_started_ms=$journalStartedMs journal_save_ms=$journalSaveMs '
          'index_finished_ms=$indexFinishedMs lock_observed=$busyObserved journal_persisted=true');
    } finally {
      journalTimer?.cancel();
      await LocalDb.close();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
