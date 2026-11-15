// Owner: SleepEditStore owns durable sleep-edit revisions and remaining work.
// Assertion writers enqueue INSIDE their transaction. Job completion uses a
// compare-and-update, so a worker for A cannot clear edit B. Errors propagate.
import 'package:sqflite/sqflite.dart';
import 'db.dart';

enum SleepEditPhase { queued, dependents, failed, done }

/// A lost revision is an obsolete job, not a storage failure. Storage failures
/// throw and leave the durable intent available for retry.
enum SleepEditAdvance { applied, superseded }

class SleepEditJob {
  const SleepEditJob(this.day, this.revision);
  final String day;
  final int revision;
}

class SleepEditStore {
  static Future<void> create(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS sleep_edit_job (
      day_id TEXT PRIMARY KEY, revision INTEGER NOT NULL,
      phase TEXT NOT NULL DEFAULT 'queued', error TEXT,
      applied_revision INTEGER NOT NULL DEFAULT 0)
  ''');

  static Future<void> enqueue(DatabaseExecutor tx, String day) async {
    await tx.rawInsert(
      'INSERT INTO sleep_edit_job(day_id, revision) SELECT ?, 0 '
      'WHERE NOT EXISTS (SELECT 1 FROM sleep_edit_job WHERE day_id = ?)',
      [day, day],
    );
    await tx.rawUpdate(
      "UPDATE sleep_edit_job SET revision = revision + 1, phase = 'queued', error = NULL WHERE day_id = ?",
      [day],
    );
    // Pin release belongs to the receipt too. No post-commit writer round trip.
    await tx.rawDelete(
      'DELETE FROM sync_cursor WHERE name = ? AND CASE WHEN json_valid(value) THEN json_extract(value, \'\$.day\') END = ?',
      [LocalDb.kFrozenHeadlineCursor, day],
    );
  }

  static Future<bool> hasOutstandingOn(DatabaseExecutor db) async =>
      (await db.rawQuery(
        "SELECT 1 FROM sleep_edit_job WHERE phase != 'done' LIMIT 1",
      )).isNotEmpty;

  static Future<void> cancel(DatabaseExecutor tx, String day) async {
    await tx.rawUpdate(
      "UPDATE sleep_edit_job SET revision = revision + 1, "
      "applied_revision = revision + 1, phase = 'done', error = NULL WHERE day_id = ?",
      [day],
    );
  }

  static Future<int> generationOn(DatabaseExecutor db) async =>
      Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COALESCE(SUM(revision), 0) FROM sleep_edit_job',
        ),
      ) ??
      0;
  static Future<int> generation() =>
      LocalDb.readerRun(generationOn, name: 'sleep edit revision');

  static Future<bool> dirtyOn(
    DatabaseExecutor db,
    String day,
  ) async => (await db.rawQuery(
    "SELECT 1 FROM sleep_edit_job WHERE ((phase != 'done' AND day_id < ?) OR (day_id = ? AND applied_revision < revision)) "
    "LIMIT 1",
    [day, day],
  )).isNotEmpty;
  static Future<Map<String, Object?>?> status(String day) =>
      LocalDb.readerRun((db) async {
        final rows = await db.query(
          'sleep_edit_job',
          where: 'day_id = ?',
          whereArgs: [day],
          limit: 1,
        );
        return rows.firstOrNull;
      }, name: 'sleep edit status');
  static Future<bool> dirty(String day) =>
      LocalDb.readerRun((db) => dirtyOn(db, day), name: 'sleep edit pending');

  static Future<List<SleepEditJob>> pending({bool retryFailed = false}) =>
      LocalDb.readerRun(
        (db) async => [
          for (final r in await db.query(
            'sleep_edit_job',
            where: retryFailed
                ? "phase != 'done'"
                : "phase NOT IN ('done', 'failed')",
            orderBy: 'day_id ASC',
          ))
            SleepEditJob(r['day_id'] as String, r['revision'] as int),
        ],
        name: 'sleep edit jobs',
      );

  static Future<List<Map<String, dynamic>>> visibleRows(
    List<Map<String, dynamic>> rows,
  ) => LocalDb.readerRun((db) async {
    final jobs = await db.query(
      'sleep_edit_job',
      where: "phase != 'done' OR applied_revision < revision",
    );
    return [
      for (final row in rows)
        if (!jobs.any(
          (j) =>
              (j['day_id'] as String).compareTo(row['date'] as String) < 0 &&
                  j['phase'] != 'done' ||
              j['day_id'] == row['date'] &&
                  j['applied_revision'] != j['revision'],
        ))
          row,
    ];
  }, name: 'sleep edit chart visibility');

  static Future<SleepEditAdvance> advance(
    SleepEditJob job,
    SleepEditPhase phase, {
    String? error,
  }) async =>
      await (await LocalDb.instance).update(
            'sleep_edit_job',
            {'phase': phase.name, 'error': error},
            where: 'day_id = ? AND revision = ?',
            whereArgs: [job.day, job.revision],
          ) ==
          1
      ? SleepEditAdvance.applied
      : SleepEditAdvance.superseded;

  static Future<void> recalculate(String day) async => LocalDb.timedTransaction(
    await LocalDb.instance,
    'sleep edit receipt',
    (tx) => enqueue(tx, day),
  );
}
