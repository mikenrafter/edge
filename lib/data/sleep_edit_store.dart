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
  const SleepEditView({
    this.ownPhase,
    this.ownUnapplied = false,
    this.dependsOn,
    this.dependsPhase,
  });
  static const none = SleepEditView();

  /// Phase of this night's outstanding work, including dependent work after
  /// its own measurements have been applied.
  final String? ownPhase;
  final bool ownUnapplied;

  /// An earlier outstanding night and its phase, prioritizing the earliest
  /// failure so every projection exposes it. This day is scored against it: its values stay, flagged.
  final String? dependsOn, dependsPhase;

  Map<String, Object?> toJson() => {
    'own_phase': ownPhase,
    'own_unapplied': ownUnapplied,
    'depends_on': dependsOn,
    'depends_phase': dependsPhase,
  };
  static SleepEditView? of(Object? value) {
    if (value is SleepEditView) return value;
    if (value is! Map) return null;
    return SleepEditView(
      ownPhase: value['own_phase'] as String?,
      ownUnapplied: value['own_unapplied'] == true,
      dependsOn: value['depends_on'] as String?,
      dependsPhase: value['depends_phase'] as String?,
    );
  }

  /// This night's sleep numbers belong to times the user has since changed.
  bool get withholdNight => ownUnapplied;
  bool get isNone => ownPhase == null && dependsOn == null;

  /// 'queued' / 'dependents' while work runs, 'failed' once it gave up.
  String? get phase => ownPhase ?? dependsPhase;
  bool get failed => phase == 'failed';
  bool get recalculating => phase != null && !failed;
}

class SleepEditJob {
  const SleepEditJob(this.day, this.revision, {this.napRevision=0, this.mainPending=true});
  final String day;
  final int revision;
  final int napRevision;
  final bool mainPending;
}

/// Publication of an applied night must complete before dependent work starts.
abstract interface class SleepEditPublication {
  Future<bool> publish();
}

class SleepEditStore {
  static Future<void> create(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS sleep_edit_job (
      day_id TEXT PRIMARY KEY, revision INTEGER NOT NULL,
      phase TEXT NOT NULL DEFAULT 'queued', error TEXT,
      applied_revision INTEGER NOT NULL DEFAULT 0)
  ''');

  static Future<void> enqueue(DatabaseExecutor tx, String day, {bool main = true}) async {
    await tx.rawInsert(
      'INSERT INTO sleep_edit_job(day_id, revision) SELECT ?, 0 '
      'WHERE NOT EXISTS (SELECT 1 FROM sleep_edit_job WHERE day_id = ?)',
      [day, day],
    );
    if (main) {
      await tx.rawUpdate(
        "UPDATE sleep_edit_job SET revision = revision + 1, phase = 'queued', error = NULL WHERE day_id = ?",[day]);
      await tx.rawDelete(
        'DELETE FROM sync_cursor WHERE name = ? AND CASE WHEN json_valid(value) THEN json_extract(value, \'\$.day\') END = ?',
        [LocalDb.kFrozenHeadlineCursor,day]);
    } else {
      await tx.rawUpdate("UPDATE sleep_edit_job SET nap_revision = nap_revision + 1, "
        "phase = CASE WHEN phase = 'done' THEN 'queued' ELSE phase END WHERE day_id = ?",[day]);
    }
  }

  static Future<bool> hasOutstandingOn(DatabaseExecutor db) async =>
      (await db.rawQuery(
        "SELECT 1 FROM sleep_edit_job WHERE phase != 'done' LIMIT 1",
      )).isNotEmpty;

  static Future<void> cancel(DatabaseExecutor tx, String day) async {
    await tx.rawUpdate(
      "UPDATE sleep_edit_job SET revision = revision + 1, "
      "applied_revision = revision + 1, nap_applied_revision = nap_revision, phase = 'done', error = NULL WHERE day_id = ?",
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
    for (final r in await db.query(
      'sleep_edit_job',
      columns: ['day_id', 'revision'],
    ))
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
  static Future<bool> dirtyOn(
    DatabaseExecutor db,
    String day,
  ) async => (await db.rawQuery(
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
      'SELECT day_id, phase, applied_revision, revision, nap_revision, nap_applied_revision FROM sleep_edit_job '
      "WHERE day_id = ? AND (applied_revision < revision OR phase != 'done') "
      "OR day_id < ? AND (applied_revision < revision OR phase = 'dependents') AND phase != 'done' ORDER BY day_id",
      [day, day],
    );
    return _viewFor(rows, day);
  }

  // CLAIM(sleep-edit-r3): cards and chart points choose the same dependency
  // from date-ordered jobs [responsiveness_sleep_r3_test: R3-3].
  static SleepEditView _viewFor(List<Map<String, Object?>> jobs, String day) {
    final own = jobs.where((j) => j['day_id'] == day &&
        (j['applied_revision'] != j['revision'] || j['phase'] != 'done')).firstOrNull;
    final earlier = jobs.where((j) =>
        (j['day_id'] as String).compareTo(day) < 0 && j['phase'] != 'done' &&
        (j['applied_revision'] != j['revision'] || j['phase'] == 'dependents'));
    final dependency = earlier.where((j) => j['phase'] == 'failed').firstOrNull ??
        earlier.firstOrNull;
    return SleepEditView(
      ownPhase: own?['phase'] as String?,
      ownUnapplied: own != null && own['applied_revision'] != own['revision'],
      dependsOn: dependency?['day_id'] as String?,
      dependsPhase: dependency?['phase'] as String?,
    );
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
            SleepEditJob(r['day_id'] as String, r['revision'] as int,
              napRevision:r['nap_revision'] as int,mainPending:(r['applied_revision'] as int)<(r['revision'] as int)),
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
        orderBy: 'day_id ASC',
      );
      if (jobs.isEmpty) return rows;
      final out = <Map<String, dynamic>>[];
      for (final row in rows) {
        final date = row['date'] as String;
        final view = _viewFor(jobs, date);
        if (view.withholdNight) continue;
        out.add(view.isNone ? row : {...row, 'sleep_edit': view});
      }
      return out;
    }, name: 'sleep edit chart visibility');
  }

  /// Reuse a complete measured night only when its persisted bounds exactly
  /// match the current assertion. With no override, recalculation retains the
  /// stored assertion itself. The proof and applied marker share a writer
  /// transaction; a source label alone is never proof. CLAIM(sleep-edit-r2)
  /// [responsiveness_sleep_r2_test: identical measured confirmed window].
  static Future<bool> reuseMeasuredNightIfCurrent(
    String day,
    int generation, {
    required int algoVersion,
  }) async => LocalDb.timedTransaction(
    await LocalDb.instance,
    'sleep edit measured window',
    InlineTransactionWork((tx) async {
      if (await generationOn(tx, upTo: day) != generation) return false;
      final measured = await tx.rawQuery(
        r'''
            SELECT 1 FROM day_result AS r
            LEFT JOIN sleep_override AS o ON o.day_id = r.day_id
            WHERE r.day_id = ? AND r.algo_version =
              (SELECT MAX(algo_version) FROM day_result WHERE day_id = ? AND algo_version <= ?)
              AND r.partial = 0 AND r.skipped = 0
              AND (o.day_id IS NULL OR (o.source != 'rejected'
              AND CASE WHEN json_valid(r.window_json) THEN
                COALESCE(json_extract(r.window_json, '$.value.onset_ms'),
                         json_extract(r.window_json, '$.onset_ms')) END = o.onset_ts * 1000
              AND CASE WHEN json_valid(r.window_json) THEN
                COALESCE(json_extract(r.window_json, '$.value.offset_ms'),
                         json_extract(r.window_json, '$.offset_ms')) END = o.offset_ts * 1000))
              AND (r.rhr > 0 OR r.rmssd > 0 OR
                CASE WHEN json_valid(r.payload_json) THEN CAST(
                  COALESCE(json_extract(r.payload_json, '$.scalars.tst_min.value'),
                           json_extract(r.payload_json, '$.scalars.tst_min')) AS REAL) END > 0)
            LIMIT 1
          ''',
        [day, day, algoVersion],
      );
      if (measured.isEmpty) return false;
      await tx.rawUpdate(
        'UPDATE sleep_edit_job SET applied_revision = revision WHERE day_id = ?',
        [day],
      );
      return true;
    }),
  );

  /// [markApplied] for the engine, fenced like its other writes: only while
  /// nothing at or before [day] has been edited since [generation].
  static Future<void> markAppliedIfCurrent(String day, int generation) async {
    final db = await LocalDb.instance;
    await LocalDb.timedTransaction(
      db,
      'sleep edit applied',
      InlineTransactionWork((tx) async {
        if (await generationOn(tx, upTo: day) != generation) return;
        await tx.rawUpdate(
          'UPDATE sleep_edit_job SET applied_revision = revision WHERE day_id = ?',
          [day],
        );
      }),
    );
  }

  static Future<SleepEditAdvance> advance(
    SleepEditJob job,
    SleepEditPhase phase, {
    String? error,
  }) async =>
      await (await LocalDb.instance).update(
            'sleep_edit_job',
            {'phase': phase.name, 'error': error},
            where: 'day_id = ? AND revision = ? AND nap_revision = ?',
            whereArgs: [job.day, job.revision, job.napRevision],
          ) ==
          1
      ? SleepEditAdvance.applied
      : SleepEditAdvance.superseded;

  static Future<void> recalculate(String day) async => LocalDb.timedTransaction(
    await LocalDb.instance,
    'sleep edit receipt',
    InlineTransactionWork((tx) => enqueue(tx, day, main:true)),
  );
}
