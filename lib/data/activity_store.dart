import 'dart:convert';
import 'dart:math' as math;
import '../gestures/moment_follow_ups.dart';
import 'package:sqflite/sqflite.dart';
import '../compute/manual_session.dart';
import '../compute/nap_edits.dart';
import '../models/activity_suggestion.dart';
import 'day_label.dart';
import 'db.dart' show LocalDb;
import 'sleep_block_store.dart';
import 'sleep_ownership.dart';
import 'sleep_editor.dart';


import 'track_activity.dart';






typedef NapBlock = ({String kind, String day, int startTs, int endTs});

/// The bounds a kept nap ends up with (the union with every block it overlaps,
/// transitively; touching counts, a gap never does) and the blocks it extends.
typedef NapResolution = ({int startTs, int endTs, List<NapBlock> extended});

/// Told after a kept nap rewrote a main sleep (its override is committed), so
/// the owner of derivation can re-derive that night as a sleep edit does.
abstract class MainSleepExtendedListener {
  Future<void> mainSleepExtended(String day);
}

/// Told after an activity suggestion was answered, so the pending count and
/// queue are re-read.
abstract class ActivitiesChangedListener {
  Future<void> activitiesChanged();
}

/// The single persistence seam for proposals and review decisions. Computing a
/// proposal never writes a session or credits sleep. All actions are atomic.
class ActivityStore {
  ActivityStore(this.db);
  final Database db;

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS activity_suggestions (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, day_id TEXT NOT NULL,
      start_ts INTEGER NOT NULL, end_ts INTEGER NOT NULL,
      detection_start INTEGER NOT NULL, detection_end INTEGER NOT NULL,
      details_json TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
      revision INTEGER NOT NULL DEFAULT 0, linked_id TEXT,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS activity_pending '
      'ON activity_suggestions(status, start_ts)',
    );
    await db.execute('''CREATE TABLE IF NOT EXISTS activity_review_meta (
      id INTEGER PRIMARY KEY CHECK(id = 1), activated_at INTEGER NOT NULL,
      revision INTEGER NOT NULL DEFAULT 0, legacy_migrated INTEGER NOT NULL DEFAULT 0,
      alert_after_ts INTEGER NOT NULL DEFAULT 0
    )''');
    final metaCols = await db.rawQuery(
      'PRAGMA table_info(activity_review_meta)',
    );
    if (!metaCols.any((r) => r['name'] == 'alert_after_ts')) {
      await db.execute(
        'ALTER TABLE activity_review_meta ADD COLUMN alert_after_ts INTEGER NOT NULL DEFAULT 0',
      );
    }
    await _ensureMeta(db);
    await db.execute('''CREATE TABLE IF NOT EXISTS activity_review_days (
      day_id TEXT PRIMARY KEY, revision INTEGER NOT NULL
    )''');
    final cols = await db.rawQuery('PRAGMA table_info(sleep_nap)');
    if (cols.isNotEmpty && !cols.any((r) => r['name'] == 'payload_json')) {
      await db.execute('ALTER TABLE sleep_nap ADD COLUMN payload_json TEXT');
    }
  }

  static Future<void> _ensureMeta(DatabaseExecutor tx) async {
    await tx.insert('activity_review_meta', {
      'id': 1,
      'activated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Small, resumable legacy transfer outside the schema upgrade transaction.
  Future<void> migrateLegacy() async {
    await _ensureMeta(db);
    while (true) {
      final finished = await db.transaction((tx) async {
        final meta = (await tx.query('activity_review_meta')).single;
        if (meta['legacy_migrated'] == 1) return true;
        final rows = await tx.rawQuery('''SELECT w.* FROM workout_suggestions w
          WHERE NOT EXISTS (SELECT 1 FROM activity_suggestions a WHERE a.id=w.id)
          ORDER BY w.created_at, w.id LIMIT 100''');
        for (final row in rows) {
          final s = row['start_ts'] as int, e = row['end_ts'] as int;
          final saved = await _overlappingSessions(tx, s, e);
          await tx.insert('activity_suggestions', {
            'id': row['id'],
            'kind': 'workout',
            'day_id': row['date'],
            'start_ts': s,
            'end_ts': e,
            'detection_start': s,
            'detection_end': e,
            'details_json': jsonEncode(row),
            'status': e <= s || saved.isNotEmpty
                ? 'superseded'
                : row['dismissed'] == 1
                ? 'discarded'
                : 'pending',
            'created_at': row['created_at'],
            'updated_at': row['created_at'],
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        if (rows.length < 100) {
          await tx.update('activity_review_meta', {'legacy_migrated': 1});
          return true;
        }
        return false;
      });
      if (finished) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// How long an unanswered suggestion stays in the review list. Nearly half
  /// of all suggestions were never answered and piled up; past a week nobody
  /// remembers whether a bout was a workout. The rows stay, unchanged.
  static const int pendingShownForSec = 7 * 86400;

  static int _pendingFloorTs([int? nowTs]) =>
      (nowTs ?? DateTime.now().millisecondsSinceEpoch ~/ 1000) -
      pendingShownForSec;

  /// One committed SELECT, including legacy proposals until preparation has
  /// migrated them. A migration committing mid-read cannot duplicate a row.
  Future<List<ActivitySuggestion>> pending({int? nowTs}) async => [
    for (final row in await db.rawQuery('''
      SELECT id, kind, start_ts, end_ts, revision, status, details_json
      FROM activity_suggestions WHERE status = 'pending' AND end_ts >= ?
      UNION ALL
      SELECT w.id, 'workout', w.start_ts, w.end_ts, 0, 'pending',
        json_object('id',w.id,'date',w.date,'start_ts',w.start_ts,'end_ts',w.end_ts,
          'avg_bpm',w.avg_bpm,'peak_bpm',w.peak_bpm,'duration_min',w.duration_min,
          'sport',w.sport,'dismissed',w.dismissed,'created_at',w.created_at)
      FROM workout_suggestions w
      WHERE w.dismissed = 0 AND w.end_ts > w.start_ts AND w.end_ts >= ?
      AND NOT EXISTS (SELECT 1 FROM activity_suggestions a WHERE a.id = w.id)
      AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.start_ts < w.end_ts
        AND COALESCE(s.end_ts, ?) > w.start_ts)
      ORDER BY start_ts DESC, id ASC''',
      [_pendingFloorTs(nowTs), _pendingFloorTs(nowTs), nowTs ?? DateTime.now().millisecondsSinceEpoch ~/ 1000]))
      ActivitySuggestion.fromRow(row),
  ];

  Future<int> pendingCount({int? nowTs}) async => (await pending(nowTs: nowTs)).length;

  Future<ActivitySuggestion?> get(String id) async {
    final rows = await db.query(
      'activity_suggestions',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : ActivitySuggestion.fromRow(rows.single);
  }

  /// A later normal derive can encounter rows restored by an import. Those
  /// detections still belong in the list, but must not alert about the import.
  static Future<void> suppressImportedAlerts(DatabaseExecutor tx) async {
    await _ensureMeta(tx);
    await tx.update('activity_review_meta', {
      'alert_after_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  Future<bool> mayNotifyNew(ActivitySuggestion suggestion, {int? nowTs}) async {
    final age =
        (nowTs ?? DateTime.now().millisecondsSinceEpoch ~/ 1000) -
        suggestion.endTs;
    if (age < 0 || age >= 2 * 3600) return false;
    final meta = (await db.query('activity_review_meta')).single;
    if (suggestion.endTs <= (meta['alert_after_ts'] as int)) return false;
    return (await get(suggestion.id))?.status == ActivityReviewStatus.pending;
  }

  /// Returns only genuinely NEW pending proposals, for one-time notification.
  /// Without [moved], a track candidate whose window changed is also returned
  /// (older callers). With it, those go into [moved] and the result is new
  /// proposals only, so a caller that notifies on the result notifies once.
  Future<List<ActivitySuggestion>> reconcile(
    ActivityKind kind,
    List<Map<String, dynamic>> candidates, {
    List<ActivitySuggestion>? moved,
  }) async {
    await migrateLegacy();
    return db.transaction((tx) async {
      final cutoff =
          (await tx.query('activity_review_meta')).single['activated_at']
              as int;
      final created = <ActivitySuggestion>[];
      for (final c in candidates) {
        final start = ((c['start_ts'] ?? c['start']) as num).toInt();
        final end = ((c['end_ts'] ?? c['end']) as num).toInt();
        if (end <= start) continue;
        // Track candidates of different tracks never merge, and a minimum-count
        // question never merges with an observed candidate of the same track.
        final isTrack = kind == ActivityKind.track;
        final matches = await tx.query(
          'activity_suggestions',
          where:
              "kind = ? AND detection_start < ? AND detection_end > ? "
              "AND NOT (status = 'superseded' AND linked_id IS NOT NULL)"
              "${isTrack ? " AND json_extract(details_json, '\$.track_id') = ? "
                  "AND COALESCE(json_extract(details_json, '\$.prompt'), 0) = ?" : ''}",
          whereArgs: [
            kind.name,
            end,
            start,
            if (isTrack) ...[c['track_id'], c['prompt'] == true ? 1 : 0],
          ],
          orderBy: 'created_at ASC, id ASC',
        );
        // A decided interval wins over every re-detection, including a merger
        // that now covers both a decided and a still-pending fragment.
        final decided = matches.where((m) => m['status'] != 'pending').toList();
        // A track candidate is evidence from the sleep itself, so overlapping
        // recorded sleep must not suppress it.
        final saved = !isTrack && await _overlapsSleep(tx, start, end);
        if (decided.isNotEmpty || saved) {
          for (final m in matches) {
            await tx.update(
              'activity_suggestions',
              {
                'detection_start': math.min(m['detection_start'] as int, start),
                'detection_end': math.max(m['detection_end'] as int, end),
                if (m['status'] == 'pending') 'status': 'superseded',
              },
              where: 'id = ?',
              whereArgs: [m['id']],
            );
          }
          continue;
        }
        if (matches.isEmpty && start < cutoff) continue;
        final now = DateTime.now().millisecondsSinceEpoch;
        final id = matches.isEmpty
            ? (c['id'] as String? ??
                  (isTrack
                      ? 'track:${c['track_id']}:$start'
                      : '${kind.name}:$start'))
            : matches.first['id'] as String;
        final details = jsonEncode(c);
        if (matches.isEmpty) {
          final row = <String, dynamic>{
            'id': id,
            'kind': kind.name,
            'day_id': dayLabelOf(
              DateTime.fromMillisecondsSinceEpoch(start * 1000),
            ),
            'start_ts': start,
            'end_ts': end,
            'detection_start': start,
            'detection_end': end,
            'details_json': details,
            'status': 'pending',
            'revision': 0,
            'created_at': now,
            'updated_at': now,
          };
          await tx.insert('activity_suggestions', row);
          created.add(ActivitySuggestion.fromRow(row));
        } else {
          final first = matches.first;
          // A slower pass from another engine can land after a newer one; a
          // same-start bout only grows, so it never moves the end back.
          // Workouts only: a nap's end can legitimately move back once more
          // of the day is staged.
          if (kind == ActivityKind.workout &&
              first['start_ts'] == start &&
              (first['end_ts'] as int) > end) {
            continue;
          }
          final changed =
              first['start_ts'] != start ||
              first['end_ts'] != end ||
              first['details_json'] != details;
          await tx.update(
            'activity_suggestions',
            {
              'start_ts': start,
              'end_ts': end,
              'day_id': dayLabelOf(
                DateTime.fromMillisecondsSinceEpoch(start * 1000),
              ),
              'details_json': details,
              'detection_start': matches.fold<int>(
                start,
                (int a, m) => math.min(a, m['detection_start'] as int),
              ),
              'detection_end': matches.fold<int>(
                end,
                (int a, m) => math.max(a, m['detection_end'] as int),
              ),
              'revision': (first['revision'] as int) + (changed ? 1 : 0),
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          // A track candidate whose evidence window moved is reported again so
          // the caller can refresh what it shows; the revision already changed.
          if (isTrack && changed) {
            (moved ?? created).add(ActivitySuggestion.fromRow(
              (await tx.query('activity_suggestions', where: 'id = ?', whereArgs: [id])).single,
            ));
          }
          for (final duplicate in matches.skip(1)) {
            await tx.update(
              'activity_suggestions',
              {'status': 'superseded', 'linked_id': id},
              where: 'id = ?',
              whereArgs: [duplicate['id']],
            );
          }
        }
      }
      return created;
    });
  }

  static Future<List<Map<String, dynamic>>> _overlappingSessions(
    DatabaseExecutor tx,
    int s,
    int e,
  ) => tx.query(
    'sessions',
    where: 'start_ts < ? AND COALESCE(end_ts, ?) > ?',
    whereArgs: [e, DateTime.now().millisecondsSinceEpoch ~/ 1000, s],
  );

  static Future<bool> _overlapsSleep(DatabaseExecutor tx,int s,int e) async =>
    (await SleepBlockStore.live(tx,s,e)).any((b)=>b.startTs<e && b.endTs>s) ||
    (await _overlappingSessions(tx,s,e)).isNotEmpty;

  static Future<void> supersede(
    DatabaseExecutor tx,
    ActivityKind kind,
    int s,
    int e,
  ) async {
    await tx.rawUpdate(
      "UPDATE activity_suggestions SET status = 'superseded' "
      "WHERE kind = ? AND status = 'pending' AND start_ts < ? AND end_ts > ?",
      [kind.name, e, s],
    );
  }

  Future<void> discard(ActivitySuggestion expected, {Transaction? transaction}) {
    Future<void> write(Transaction tx) async {
        final row = await _check(tx, expected, 'discarded',allowConfirmed:expected.kind==ActivityKind.nap);
        if (row == null) return;
        if(row['status']=='confirmed' && expected.kind==ActivityKind.nap) {
          final blocks=await tx.query('sleep_block',where:'id = ?',whereArgs:[row['linked_id']]);
          if(blocks.isEmpty) throw const ActivityReviewException('This saved nap is no longer available.');
          final block=blocks.single;
          final participants=await tx.query('sleep_block',columns:['id'],
            where:'merged_into = ?',whereArgs:[block['id']],limit:1);
          // A Keep can link to an older survivor. Incoming proposals need not
          // have a stored participant row, so also prove this is this nap's
          // original detection, not a union snapshot [B1; callers test].
          if(block['kind']!='nap' || block['state']=='merged' || participants.isNotEmpty ||
              block['detected_start']!=row['detection_start'] ||
              block['detected_end']!=row['detection_end']) {
            throw const ActivityReviewException(
              'This nap is now part of another sleep; edit it there.');
          }
          final plan=await SleepBlockStore.plan(tx,block['owner_day'] as String,
            [RemoveBlock(StoredBlockRef(block['id'] as String,block['revision'] as int))]);
          requireSleepSaved(await SleepBlockStore.apply(plan,tx:tx));
        }
        await tx.update(
          'activity_suggestions',
          {
            'status': 'discarded',
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [expected.id],
        );
        if(expected.kind!=ActivityKind.nap) await _changed(tx, row['day_id'] as String);
        if (expected.kind == ActivityKind.track && expected.isPrompt) {
          await TrackActivity.answerNo(tx, expected, row['day_id'] as String);
        }
      }
    return transaction == null ? db.transaction(write) : write(transaction);
  }

  /// Null when the row is already [done] (a repeated tap). Any other decided
  /// status means it changed underneath the caller, which must not report
  /// success for a write it never made.
  static Future<Map<String, dynamic>?> _check(
    DatabaseExecutor tx,
    ActivitySuggestion expected,
    String done, {bool allowConfirmed=false}
  ) async {
    var rows = await tx.query(
      'activity_suggestions', where: 'id = ?', whereArgs: [expected.id]);
    if (rows.isEmpty) {
      final legacy = await tx.query('workout_suggestions', where: 'id = ?', whereArgs: [expected.id]);
      if (legacy.isNotEmpty) {
        final r = legacy.single;
        final start = r['start_ts'] as int, end = r['end_ts'] as int;
        await tx.insert('activity_suggestions', {
          'id': r['id'], 'kind': 'workout', 'day_id': r['date'],
          'start_ts': start, 'end_ts': end, 'detection_start': start, 'detection_end': end,
          'details_json': jsonEncode(r), 'revision': 0,
          'status': end <= start || (await _overlappingSessions(tx, start, end)).isNotEmpty
            ? 'superseded' : r['dismissed'] == 1 ? 'discarded' : 'pending',
          'created_at': r['created_at'], 'updated_at': r['created_at'],
        });
        rows = await tx.query('activity_suggestions', where: 'id = ?', whereArgs: [expected.id]);
      }
    }
    if (rows.isEmpty) {
      throw const ActivityReviewException(
        'This suggestion is no longer available.',
      );
    }
    final row = rows.single;
    if (row['status'] == done) return null;
    if (row['status'] != 'pending' && !(allowConfirmed && row['status']=='confirmed')) {
      throw const ActivityReviewException(
        'This suggestion is no longer available.',
      );
    }
    if (row['revision'] != expected.revision) {
      throw const ActivityReviewException(
        'This suggestion changed as more data arrived. Review its updated times and try again.',
      );
    }
    return row;
  }

  /// The nap resolution that was applied (null for a workout or a repeated
  /// tap). A main sleep it extended is released for re-derive after commit;
  /// the caller schedules that derive.
  Future<NapResolution?> confirm(
    ActivitySuggestion expected, {
    required int startTs,
    required int endTs,
    Map<String, dynamic>? session,
    bool edited = false,
    bool auto = false,
    SleepMergeAuthorization? merge,
    Transaction? transaction,
  }) async {
    Future<NapResolution?> write(Transaction tx) async {
    final row = await _check(tx, expected, 'confirmed');
    if (row == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (startTs <= 0 || endTs <= startTs) {
      throw const ActivityReviewException('Choose a positive time window.');
    }
    if (endTs > now ~/ 1000 && !expected.isPrompt) {
      throw const ActivityReviewException('The end time is in the future.');
    }
    final day = SleepOwnership.dayOf(SleepBlockKind.nap,startTs,endTs);
    String linked;
    NapResolution? resolution;
    if (expected.kind == ActivityKind.meal) {
      final local = DateTime.fromMillisecondsSinceEpoch(startTs * 1000);
      final hhmm = '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
      final writer = MomentAnswerWriter(transaction: tx);
      final label = await writer.labelOf(day, hhmm);
      final moment = PendingMoment(date: day, hhmm: hhmm, epochSec: startTs);
      if (await writer.isAnswered(moment) && label != 'meal') {
        throw const ActivityReviewException('That moment already has another answer.');
      }
      // Food entries are already timestamped independently. Keep their amounts
      // and identity intact; confirming a candidate adds no invented nutrition.
      await writer.answer(moment, MomentChoice.meal);
      linked = '$day $hhmm';
    } else if (expected.kind == ActivityKind.track) {
      linked = await TrackActivity.confirm(tx, expected,
          dayId: row['day_id'] as String, startTs: startTs, nowMs: now);
    } else if (expected.kind == ActivityKind.workout) {
      final overlap = await _overlappingSessions(tx, startTs, endTs);
      final invalid = validateManualWindow(
        startSec: startTs,
        endSec: endTs,
        nowSec: now ~/ 1000,
        existing: [
          for (final r in overlap)
            SessionSpan(
              r['id'] as String,
              r['start_ts'] as int,
              (r['end_ts'] as int?) ?? now ~/ 1000,
            ),
        ],
      );
      if (invalid != null) throw ManualWindowException(invalid);
      if (await _overlapsSleep(tx, startTs, endTs)) {
        throw const ActivityReviewException(
          'That overlaps sleep already in your history.',
        );
      }
      if (session == null) {
        throw StateError('Workout must be scored before commit');
      }
      linked = session['id'] as String;
      await tx.insert('sessions', session);
      await supersede(tx, ActivityKind.workout, startTs, endTs);
    } else {
      if (!manualNapWindowIsValid(startTs, endTs)) {
        throw const ActivityReviewException(
          'A nap must last between 5 minutes and 3 hours.',
        );
      }
      final command=auto
        ? AutoLogNap(expected.id,startTs,endTs,jsonEncode({...expected.details,
            'start':startTs,'end':endTs,'source':'confirmed','auto_logged':true}))
        : AddNap(startTs,endTs,source:edited?'manual':'confirmed',suggestionId:expected.id,
            payload:edited?null:jsonEncode({...expected.details,'start':startTs,'end':endTs,'source':'confirmed'}));
      final plan=await SleepBlockStore.plan(tx,day,[command]);
      final proposal=await SleepBlockStore.preflight(tx,plan);
      final outcome=await SleepBlockStore.apply(plan,tx:tx,merge:merge);
      requireSleepSaved(outcome);
      if(proposal is SleepProposalMergeRequired) {
        final p=proposal.proposal;
        resolution=(startTs:p.startTs,endTs:p.endTs,extended:[for(final b in p.participants)
          (kind:b.kind==SleepBlockKind.main?'main_sleep':'nap',day:b.day,startTs:b.startTs,endTs:b.endTs)]);
      }
      return resolution;
    }
    await tx.update('activity_suggestions',{'status':'confirmed','linked_id':linked,'updated_at':now},
      where:'id = ?',whereArgs:[expected.id]);
    await _changed(tx, row['day_id'] as String);
    return resolution;
    }
    final res = transaction == null
        ? await db.transaction<NapResolution?>(write) : await write(transaction);
    final main = res?.extended.where((b) => b.kind == 'main_sleep').lastOrNull;
    if (main != null && transaction == null) await LocalDb.releaseFrozenHeadline(main.day);
    return res;
  }

  /// Records WHY a pending nap was not logged (no revision bump: the detection
  /// itself is unchanged).
  Future<void> _markMergeRequired(
      ActivitySuggestion s, SleepMergeProposal proposal) async {
    final details = {
      ...s.details,
      'merge_required': {
        'start': proposal.startTs,
        'end': proposal.endTs,
        'days': proposal.affectedDays.toList()..sort(),
      },
    };
    await db.update(
      'activity_suggestions',
      {'details_json': jsonEncode(details)},
      where: "id = ? AND status = 'pending'",
      whereArgs: [s.id],
    );
  }

  static Future<void> _changed(DatabaseExecutor tx, String day) async {
    await _ensureMeta(tx);
    await tx.rawUpdate(
      'UPDATE activity_review_meta SET revision = revision + 1',
    );
    final rev = (await tx.query('activity_review_meta')).single['revision'];
    await tx.insert('activity_review_days', {
      'day_id': day,
      'revision': rev,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> markDayChanged(DatabaseExecutor tx, String day) =>
      _changed(tx, day);

  static Future<List<NapEdit>> napEdits(DatabaseExecutor tx,String day) => SleepBlockStore.napEdits(tx,day);

  /// The bar for logging a nap without asking (#625). The detector's
  /// confidence is a composite of HR coverage, HR dip, stillness and wear,
  /// in [0.2, 0.85]; it is not a probability and 0.8 is not a validated cut.
  /// ponytail: one fixed bar, the value the issue asked for. Make it a user
  /// choice if people want it looser or stricter.
  static const double napAutoLogMinConfidence = 0.8;

  /// Whether the opt-in setting would log [s] without asking. [sinceSec] is
  /// when the setting was turned on (null = off): a nap that ended before
  /// that is never logged behind the user's back.
  static bool napAutoLoggable(ActivitySuggestion s, int? sinceSec) {
    final c = s.details['confidence'];
    return sinceSec != null &&
        s.kind == ActivityKind.nap &&
        s.status == ActivityReviewStatus.pending &&
        c is num &&
        c >= napAutoLogMinConfidence &&
        // Strictly after: the switch is stored in whole seconds, and a nap
        // that ended in that same second ended before it was turned on.
        s.endTs > sinceSec;
  }

  /// Confirms every [napAutoLoggable] pending nap exactly as detected, once
  /// the data edge is [settleSec] past its end, so sleep that resumes after a
  /// short arousal can still be bridged into it first. A nap that cannot be
  /// confirmed (it overlaps saved sleep, or changed underneath) stays pending.
  /// Returns how many were logged.
  ///
  /// [current] is the nap candidates this pass detected. Only a pending row
  /// that overlaps one of them is a candidate: [reconcile] only retires rows
  /// that overlap a re-detection, so a nap a later pass no longer finds stays
  /// pending, and must not be confirmed behind the user's back.
  Future<int> autoLogNaps({
    required int? sinceSec,
    required int dataEdgeSec,
    required int settleSec,
    required List<Map<String, dynamic>> current,
  }) async {
    if (sinceSec == null) return 0;
    final spans = <(int, int)>[
      for (final c in current)
        (
          ((c['start_ts'] ?? c['start']) as num).toInt(),
          ((c['end_ts'] ?? c['end']) as num).toInt(),
        ),
    ];
    if (spans.isEmpty) return 0;
    await migrateLegacy();
    // Imported history is never logged for the user: the same line
    // [mayNotifyNew] draws for prompts.
    final importedThrough =
        (await db.query('activity_review_meta')).single['alert_after_ts']
            as int;
    // Not [pending]: its seven-day floor is for what the review list shows. A
    // band that syncs after a longer gap still has naps to log.
    final rows = await db.query(
      'activity_suggestions',
      where: "status = 'pending' AND kind = 'nap' AND end_ts > ?",
      whereArgs: [math.max(sinceSec, importedThrough)],
      orderBy: 'start_ts ASC, id ASC',
    );
    var logged = 0;
    for (final s in rows.map(ActivitySuggestion.fromRow)) {
      if (!napAutoLoggable(s, sinceSec) || s.endTs + settleSec > dataEdgeSec) {
        continue;
      }
      if (!spans.any((c) => s.startTs < c.$2 && s.endTs > c.$1)) continue;
      try {
        await confirm(s, startTs: s.startTs, endTs: s.endTs, auto: true);
        logged++;
      } on SleepMergeRequiredException catch (e) {
        // Left pending with the reason: a person decides Merge or Cancel.
        await _markMergeRequired(s, e.proposal);
      } on ActivityReviewException {
        // Left for the user to review.
      }
    }
    return logged;
  }
}

