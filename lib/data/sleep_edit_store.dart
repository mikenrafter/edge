// Owner: SleepEditStore owns durable sleep-edit revisions and remaining work.
// Assertion writers enqueue INSIDE their transaction. Job completion uses a
// compare-and-update, so a worker for A cannot clear edit B. Errors propagate.
import 'package:sqflite/sqflite.dart';
import '../compute/sleep_blank.dart' show kSleepDerivedMetricKeys;
import 'db.dart';

enum SleepEditPhase { queued, dependents, failed, done }

/// A lost revision is an obsolete job, not a storage failure. Storage failures
/// throw and leave the durable intent available for retry.
enum SleepEditAdvance { applied, superseded }

/// What reading one day must do while sleep edits are outstanding.
class SleepEditView {
  const SleepEditView({this.ownPhase, this.dependsOn, this.dependsPhase});
  static const none = SleepEditView();

  /// Phase of THIS night's own unapplied edit; null when it has none.
  final String? ownPhase;

  /// The earliest earlier night whose edit is still outstanding, and its
  /// phase. This day is scored against it: its values stay, flagged.
  final String? dependsOn, dependsPhase;

  /// This night's sleep numbers belong to times the user has since changed.
  bool get withholdNight => ownPhase != null;
  bool get isNone => ownPhase == null && dependsOn == null;

  /// 'queued' / 'dependents' while work runs, 'failed' once it gave up.
  String? get phase => ownPhase ?? dependsPhase;
  bool get failed => phase == 'failed';
  bool get recalculating => phase != null && !failed;
}

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

  /// The edit fence of one night: the revisions of that night and of every
  /// EARLIER one, because a night is scored against the nights before it. An
  /// edit to a later night cannot change this night's numbers, so it must not
  /// refuse this night's write. With no [upTo], every night.
  /// CLAIM(sleep-edit-fence) [responsiveness_sleep_retry_test].
  static Future<int> generationOn(DatabaseExecutor db, {String? upTo}) async =>
      Sqflite.firstIntValue(
        await db.rawQuery(
          upTo == null
              ? 'SELECT COALESCE(SUM(revision), 0) FROM sleep_edit_job'
              : 'SELECT COALESCE(SUM(revision), 0) FROM sleep_edit_job WHERE day_id <= ?',
          upTo == null ? const [] : [upTo],
        ),
      ) ??
      0;
  static Future<int> generation({String? upTo}) => LocalDb.readerRun(
    (db) => generationOn(db, upTo: upTo),
    name: 'sleep edit revision',
  );

  /// Every night's revision at this moment, so a pass that reads many nights
  /// can fence each of them later without another query ([generationIn]).
  static Future<Map<String, int>> revisionsOn(DatabaseExecutor db) async => {
    for (final r in await db.query('sleep_edit_job', columns: ['day_id', 'revision']))
      r['day_id'] as String: r['revision'] as int,
  };

  /// [generationOn] over a snapshot taken by [revisionsOn].
  static int generationIn(Map<String, int> revisions, String upTo) => [
    for (final e in revisions.entries)
      if (e.key.compareTo(upTo) <= 0) e.value,
  ].fold(0, (a, b) => a + b);

  /// This night's own numbers are stale: an assertion landed that no result
  /// has applied yet. Only the night's own sleep numbers are withheld for it
  /// ([SleepEditView.withholdNight]); a later day is never "dirty".
  static Future<bool> dirtyOn(DatabaseExecutor db, String day) async =>
      (await db.rawQuery(
        'SELECT 1 FROM sleep_edit_job WHERE day_id = ? AND applied_revision < revision LIMIT 1',
        [day],
      )).isNotEmpty;

  /// Nights whose own edit is not applied yet, for a walk over many days.
  static Future<Set<String>> staleNights() => LocalDb.readerRun(
    (db) async => {
      for (final r in await db.rawQuery(
        'SELECT day_id FROM sleep_edit_job WHERE applied_revision < revision',
      ))
        r['day_id'] as String,
    },
    name: 'sleep edit stale nights',
  );

  /// What a read of [day] has to do while edits are outstanding.
  /// CLAIM(sleep-edit-masking) [responsiveness_sleep_fix_test].
  static Future<SleepEditView> viewOn(DatabaseExecutor db, String day) async {
    final rows = await db.rawQuery(
      'SELECT day_id, phase FROM sleep_edit_job '
      "WHERE day_id = ? AND applied_revision < revision "
      "OR day_id < ? AND phase != 'done' ORDER BY day_id",
      [day, day],
    );
    if (rows.isEmpty) return SleepEditView.none;
    String? own, dependsOn, dependsPhase;
    for (final r in rows) {
      if (r['day_id'] == day) {
        own = r['phase'] as String;
      } else if (dependsOn == null) {
        dependsOn = r['day_id'] as String;
        dependsPhase = r['phase'] as String;
      }
    }
    return SleepEditView(ownPhase: own, dependsOn: dependsOn, dependsPhase: dependsPhase);
  }

  static Future<SleepEditView> view(String day) =>
      LocalDb.readerRun((db) => viewOn(db, day), name: 'sleep edit view');

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

  /// [rows] of the series [key] as a chart may draw them. A night with an
  /// unapplied edit loses only its sleep-derived points; its other series, and
  /// every later day, keep theirs. Points of later days that were scored
  /// against the edited night carry `sleep_edit`: 'recalculating', or 'failed'
  /// when the edit gave up, so the value reads as older than the edit.
  static Future<List<Map<String, dynamic>>> visibleRows(
    List<Map<String, dynamic>> rows, {
    required String key,
  }) async {
    if (!kSleepDerivedMetricKeys.contains(key)) return rows;
    return LocalDb.readerRun((db) async {
      final jobs = await db.query(
        'sleep_edit_job',
        where: "phase != 'done' OR applied_revision < revision",
      );
      if (jobs.isEmpty) return rows;
      final out = <Map<String, dynamic>>[];
      for (final row in rows) {
        final date = row['date'] as String;
        if (jobs.any((j) => j['day_id'] == date && j['applied_revision'] != j['revision'])) continue;
        final earlier = [
          for (final j in jobs)
            if ((j['day_id'] as String).compareTo(date) < 0 && j['phase'] != 'done') j,
        ];
        out.add(earlier.isEmpty
            ? row
            : {...row, 'sleep_edit': earlier.every((j) => j['phase'] == 'failed') ? 'failed' : 'recalculating'});
      }
      return out;
    }, name: 'sleep edit chart visibility');
  }

  /// [markApplied] for the engine, fenced like its other writes: only while
  /// nothing at or before [day] has been edited since [generation].
  static Future<void> markAppliedIfCurrent(String day, int generation) async {
    final db = await LocalDb.instance;
    await LocalDb.timedTransaction(db, 'sleep edit applied', (tx) async {
      if (await generationOn(tx, upTo: day) != generation) return;
      await tx.rawUpdate(
        'UPDATE sleep_edit_job SET applied_revision = revision WHERE day_id = ?',
        [day],
      );
    });
  }

  /// The edit's recalculation finished with nothing newer to store for the
  /// night (no live inputs, a skipped or blanked night, a partial result). The
  /// applied marker still has to advance, or the night stays withheld forever.
  /// Compare-and-update on the revision, like [advance].
  static Future<bool> markApplied(SleepEditJob job) async =>
      await (await LocalDb.instance).rawUpdate(
        'UPDATE sleep_edit_job SET applied_revision = revision WHERE day_id = ? AND revision = ?',
        [job.day, job.revision],
      ) ==
      1;

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
