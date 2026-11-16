import 'dart:convert';
import 'dart:math' as math;

import '../gestures/moment_follow_ups.dart';

import 'package:sqflite/sqflite.dart';

import '../compute/manual_session.dart';
import '../compute/derivation_engine.dart' show kAlgoVersion;
import '../compute/nap_edits.dart';
import '../models/activity_suggestion.dart';
import 'day_label.dart';
import 'db.dart' show LocalDb;
import 'nap_resolution.dart';
import 'sleep_edit_store.dart';
import 'json_payload_lane.dart';
import 'track_activity.dart';
import 'db/input_read_tracker.dart';

/// The single persistence seam for proposals and review decisions. Computing a
/// proposal never writes a session or credits sleep. All actions are atomic.
/// In a discarded track question's details: its Discard wrote the day's
/// `track_absence` row (pilot day-timeline's Restore takes back only that).
const String kDiscardAbsence = '_discard_wrote_absence';

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

  static Future<bool> _overlapsSleep(DatabaseExecutor tx, int s, int e) async {
    final naps = await tx.query(
      'sleep_nap',
      where: "source != 'rejected' AND start_ts < ? AND end_ts > ?",
      whereArgs: [e, s],
    );
    if (naps.isNotEmpty) return true;
    final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(s * 1000));
    final end = DateTime.fromMillisecondsSinceEpoch(e * 1000);
    // An evening interval can overlap the main sleep owned by tomorrow's
    // wake date. Walk calendar dates rather than adding a fixed 24 hours.
    final next = dayLabelOf(DateTime(end.year, end.month, end.day + 1));
    // Only the two parts of the bundle that are read, never the whole row.
    final nights = await tx.rawQuery(
      '''SELECT CASE WHEN json_type(d.payload_json, '\$.naps.value') = 'array'
          THEN json_extract(d.payload_json, '\$.naps.value') END AS naps,
        json_extract(d.payload_json, '\$.sleep.window.value.onset_ms') AS on_ms,
        json_extract(d.payload_json, '\$.sleep.window.value.offset_ms') AS off_ms
      FROM day_result d
      WHERE d.day_id BETWEEN ? AND ? AND d.algo_version =
        (SELECT MAX(r.algo_version) FROM day_result r WHERE r.day_id = d.day_id AND r.algo_version <= ?)''',
      [day, next, kAlgoVersion],
    );
    for (final r in nights) {
      // Before its first recompute, a pre-upgrade nap still lives only in the
      // day bundle. It is already logged and takes precedence just as a nap
      // that has been copied into the accepted-record table does.
      final napsJson = r['naps'] as String?;
      final legacy = napsJson == null ? null : jsonDecode(napsJson);
      if (legacy is List) {
        for (final nap in legacy.whereType<Map>()) {
          final ns = nap['start'] as num?, ne = nap['end'] as num?;
          if (ns != null && ne != null && s < ne && e > ns) return true;
        }
      }
      // Absent metric envelopes store '—', which has no onset_ms: NULL here.
      final ns = r['on_ms'] as num?, ne = r['off_ms'] as num?;
      if (ns != null && ne != null && s * 1000 < ne && e * 1000 > ns) {
        return true;
      }
    }
    return (await _overlappingSessions(tx, s, e)).isNotEmpty;
  }

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
        final row = await _check(tx, expected, 'discarded');
        if (row == null) return;
        await tx.update(
          'activity_suggestions',
          {
            'status': 'discarded',
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [expected.id],
        );
        await _changed(tx, row['day_id'] as String);
        if (expected.kind == ActivityKind.track && expected.isPrompt) {
          final wrote = await TrackActivity.answerNo(tx, expected, row['day_id'] as String);
          // Pilot day-timeline: the row records that THIS Discard wrote the
          // day's absence (other flows write absences too), so Restore takes
          // back only that. Kept in the row's details, no schema change.
          if (wrote) {
            await tx.update('activity_suggestions', {
              'details_json': jsonEncode({...expected.details, kDiscardAbsence: true}),
            }, where: 'id = ?', whereArgs: [expected.id]);
          }
        }
      }
    return transaction == null ? db.transaction(write) : write(transaction);
  }

  /// Restore (pilot day-timeline): a DISCARDED suggestion goes back to
  /// pending, so it is offered for review again. Nothing else is touched
  /// except what its own Discard wrote: a track question's absence row,
  /// when [kDiscardAbsence] in its details says that Discard wrote it. The revision moves
  /// on, so a decision staged against the discarded row can never apply to
  /// the restored one. False, writing nothing, when the row is not
  /// discarded (already restored, or decided some other way since).
  static Future<bool> restore(Transaction tx, String id) async {
    final rows = await tx.query('activity_suggestions',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty || rows.single['status'] != 'discarded') return false;
    final row = rows.single;
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = ActivitySuggestion.fromRow(row);
    final wroteAbsence = s.details[kDiscardAbsence] == true;
    if (wroteAbsence && s.trackId != null) {
      await tx.delete('track_absence',
          where: 'track_id = ? AND date = ?',
          whereArgs: [s.trackId, row['day_id']]);
    }
    await tx.update(
      'activity_suggestions',
      {
        'status': 'pending',
        if (wroteAbsence)
          'details_json': jsonEncode({...s.details}..remove(kDiscardAbsence)),
        'revision': (row['revision'] as int) + 1,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _changed(tx, row['day_id'] as String);
    return true;
  }

  /// The day's discarded suggestions (pilot day-timeline's "Only discarded").
  static Future<List<ActivitySuggestion>> discardedOn(
      DatabaseExecutor db, String day) async => [
        for (final r in await db.query('activity_suggestions',
            where: "status = 'discarded' AND day_id = ?",
            whereArgs: [day], orderBy: 'start_ts ASC, id ASC'))
          ActivitySuggestion.fromRow(r),
      ];

  /// Null when the row is already [done] (a repeated tap). Any other decided
  /// status means it changed underneath the caller, which must not report
  /// success for a write it never made.
  static Future<Map<String, dynamic>?> _check(
    DatabaseExecutor tx,
    ActivitySuggestion expected,
    String done,
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
    if (row['status'] != 'pending') {
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
    NapResolution? expectedNap,
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
    final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(startTs * 1000));
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
          'A nap must last between 5 minutes and 6 hours.',
        );
      }
      final ext = await applyNapExtension(tx, startTs, endTs,
          expected: expectedNap);
      resolution = ext.res;
      if (ext.handled) {
        linked = '${ext.day}:${ext.res.startTs}';
      } else {
        linked = '$day:$startTs';
        await tx.insert('sleep_nap', {
          'day_id': day,
          'start_ts': startTs,
          'end_ts': endTs,
          'source': edited ? 'manual' : 'confirmed',
          'created_at': now ~/ 1000,
          'payload_json': edited
              ? null
              : jsonEncode({
                  ...expected.details,
                  'start': startTs,
                  'end': endTs,
                  'source': 'confirmed',
                }),
        });
      }
      await _changed(tx, day);
    }
    await tx.update(
      'activity_suggestions',
      {'status': 'confirmed', 'linked_id': linked, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [expected.id],
    );
    await _changed(tx, row['day_id'] as String);
    return resolution;
    }
    final res = transaction == null
        ? await db.transaction<NapResolution?>(write) : await write(transaction);
    final main = res?.extended.where((b) => b.kind == 'main_sleep').lastOrNull;
    if (main != null && transaction == null) await LocalDb.releaseFrozenHeadline(main.day);
    return res;
  }

  /// Keeps a nap at [s]..[e] inside [tx]: re-resolves, throws
  /// [NapResolutionChanged] (writing nothing) when [expected] no longer
  /// matches, then writes the union. A main sleep it reaches is rewritten as
  /// the union through the sleep-override row (the caller releases the frozen
  /// headline after commit and re-derives); absorbed naps are deleted and no
  /// nap row is added, so the hours are not credited twice. Otherwise ONE
  /// manual nap row carries the union; a union equal to one existing nap
  /// changes nothing. [handled] is false when nothing was reached: the caller
  /// writes its own plain row. [day] is the day that owns the result.
  static Future<({NapResolution res, bool handled, String day})>
  applyNapExtension(
    DatabaseExecutor tx,
    int s,
    int e, {
    NapResolution? expected,
  }) async {
    final res = await NapResolver.grow(tx, s, e);
    if (expected != null && !NapResolver.same(expected, res)) {
      throw NapResolutionChanged(res);
    }
    final unionDay = dayLabelOf(
      DateTime.fromMillisecondsSinceEpoch(res.startTs * 1000),
    );
    if (res.extended.isEmpty) return (res: res, handled: false, day: unionDay);
    final mains = res.extended.where((b) => b.kind == 'main_sleep').toList();
    final naps = res.extended.where((b) => b.kind == 'nap').toList();
    if (mains.isEmpty &&
        naps.length == 1 &&
        naps.single.startTs == res.startTs &&
        naps.single.endTs == res.endTs) {
      return (res: res, handled: true, day: naps.single.day);
    }
    for (final n in naps) {
      await tx.delete(
        'sleep_nap',
        where: 'day_id = ? AND start_ts = ?',
        whereArgs: [n.day, n.startTs],
      );
      await _changed(tx, n.day);
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (mains.isNotEmpty) {
      final main = mains.last;
      await tx.insert('sleep_override', {
        'day_id': main.day,
        'onset_ts': res.startTs,
        'offset_ts': res.endTs,
        'source': 'manual',
        'created_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // A window edit reopens the night, as putSleepOverride does, and owes
      // it a recalculation: the job commits with the assertion or not at all
      // (a crash between the two once left new times under old numbers).
      await tx.delete(
        'wake_confirmation',
        where: 'day_id = ?',
        whereArgs: [main.day],
      );
      await SleepEditStore.enqueue(tx, main.day);
      await _changed(tx, main.day);
      return (res: res, handled: true, day: main.day);
    }
    await tx.insert('sleep_nap', {
      'day_id': unionDay,
      'start_ts': res.startTs,
      'end_ts': res.endTs,
      'source': 'manual',
      'created_at': now,
      'payload_json': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _changed(tx, unionDay);
    return (res: res, handled: true, day: unionDay);
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

  /// Capture only previously LOGGED pre-upgrade naps, never newly detected old
  /// history. Called before replacing a day's result, outside the migration.
  static Future<void> preserveLegacyNaps(
    DatabaseExecutor tx,
    String day,
    Map<String, dynamic> bundle,
  ) async {
    await _ensureMeta(tx);
    final cutoff =
        (await tx.query('activity_review_meta')).single['activated_at'] as int;
    final naps = (bundle['naps'] as Map?)?['value'];
    if (naps is! List) return;
    for (final n in naps.whereType<Map>()) {
      final s = (n['start'] as num?)?.toInt(), e = (n['end'] as num?)?.toInt();
      if (s == null ||
          e == null ||
          s >= cutoff ||
          e <= s ||
          n['source'] == 'manual' ||
          n['source'] == 'confirmed') {
        continue;
      }
      if ((await tx.query(
        'sleep_nap',
        where: 'start_ts < ? AND end_ts > ?',
        whereArgs: [e, s],
      )).isNotEmpty) {
        continue;
      }
      await tx.insert('sleep_nap', {
        'day_id': day,
        'start_ts': s,
        'end_ts': e,
        'source': 'legacy',
        'created_at': cutoff,
        'payload_json': jsonEncode({...n, 'source': 'legacy'}),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<List<NapEdit>> napEdits(
    DatabaseExecutor tx,
    String day,
  ) async {
    InputReads.note('sleep_nap', day);
    final rows=await tx.query('sleep_nap',where:'day_id = ?',whereArgs:[day]);
    if(rows.isEmpty)return [];
    final decoded=await const IsolateJsonPayloadLane().run(JsonPayloadsInput(
      values:[for(final row in rows)row['payload_json']],encode:false));
    return [for(final (i,row) in rows.indexed)
      NapEdit(kind:row['source']=='rejected'?NapEditKind.rejected:NapEditKind.added,
        startSec:row['start_ts'] as int,endSec:row['end_ts'] as int,
        snapshot:decoded.values[i] is Map&&(row['source']!='manual'||
          (decoded.values[i] as Map)['_stage_only']==true)
            ?Map<String,dynamic>.from(decoded.values[i] as Map):null)];

  }
}
