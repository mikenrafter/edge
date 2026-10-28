part of 'tracks_store.dart';

// Experiments live beside the track they test. Assignments are persisted once;
// adherence comes only from explicit logs and absence confirmations; outcomes
// are the night each assigned date starts (read as stored, never recomputed).
extension TracksExperimentStore on TracksStore {
  static String endDate(String startDate, int weeks) {
    final d = DateTime.parse(startDate);
    return dayLabelOf(DateTime(d.year, d.month, d.day + 7 * weeks - 1));
  }

  Future<Map<String, Object?>> _startExperiment({
    required String trackId,
    required String startDate,
    required int weeks,
    int? seed,
  }) async {
    if (!experimentWeeks.contains(weeks)) throw ArgumentError('weeks');
    if (!TracksStore._validDay(startDate)) throw ArgumentError('date');
    final track = (await definitions()).where((d) => d.id == trackId);
    if (track.isEmpty || !track.single.enabled) throw ArgumentError('track');
    // ↳ CLAIM(never-ask-skip-prescribed)
    if (ExperimentableTrack.from(track.single) == null) {
      throw const ExperimentRefused(ExperimentRefusal.prescribed);
    }
    // ↳ CLAIM(washout-vs-block)
    if (experimentWashoutExceedsBlock(track.single)) {
      throw const ExperimentRefused(ExperimentRefusal.washout);
    }
    final end = endDate(startDate, weeks);
    final chosen = seed ?? math.Random().nextInt(0x7fffffff);
    final assignments = assignExperimentDays(weeks * 7, chosen);
    // Route-safe: the id travels in a notification deep link.
    final id = 'xp-${trackId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}-$startDate-$chosen';
    await db.transaction((tx) async {
      final overlapping = await tx.query(
        'track_experiment',
        columns: ['id'],
        where: 'track_id = ? AND start_date <= ? AND end_date >= ?',
        whereArgs: [trackId, end, startDate],
        limit: 1,
      );
      if (overlapping.isNotEmpty) throw StateError('experiment_running');
      await tx.insert('track_experiment', {
        'id': id,
        'track_id': trackId,
        'start_date': startDate,
        'end_date': end,
        'weeks': weeks,
        'seed': chosen,
        'created_ms': clock.now().millisecondsSinceEpoch,
      });
      final first = DateTime.parse(startDate);
      for (var i = 0; i < assignments.length; i++) {
        await tx.insert('track_experiment_day', {
          'experiment_id': id,
          'date': dayLabelOf(DateTime(first.year, first.month, first.day + i)),
          'do_it': assignments[i] ? 1 : 0,
        });
      }
    });
    return (await _experiments(trackId: trackId)).firstWhere(
      (e) => e['id'] == id,
    );
  }

  /// A stopped experiment keeps its rows, with `end_date` moved to yesterday
  /// and later assignments deleted, so it is recognisable as stopped by
  /// `end_date != endDate(start_date, weeks)`. One that has not yet had a full
  /// day is removed. No schema change.
  // CLAIM(stop-ends-reminders): after a stop no assignment is left on or after
  // today, so no reminder is produced; the range is free [tracks_experiments_t3_test].
  Future<void> _stopExperiment(String id) async {
    final rows = await db.query('track_experiment', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) throw ArgumentError('experiment');
    final today = dayLabelOf(clock.now());
    final start = rows.single['start_date'] as String;
    final end = rows.single['end_date'] as String;
    if (end.compareTo(today) < 0) throw StateError('experiment_finished');
    final now = clock.now();
    final yesterday = dayLabelOf(DateTime(now.year, now.month, now.day - 1));
    await db.transaction((tx) async {
      if (start.compareTo(yesterday) > 0) {
        await tx.delete('track_experiment_day', where: 'experiment_id = ?', whereArgs: [id]);
        await tx.delete('track_experiment', where: 'id = ?', whereArgs: [id]);
        return;
      }
      await tx.delete(
        'track_experiment_day',
        where: 'experiment_id = ? AND date > ?',
        whereArgs: [id, yesterday],
      );
      await tx.update(
        'track_experiment',
        {'end_date': yesterday},
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  Future<List<Map<String, Object?>>> _experiments({String? trackId}) async {
    final rows = await db.query(
      'track_experiment',
      where: trackId == null ? null : 'track_id = ?',
      whereArgs: [?trackId],
      orderBy: 'start_date, id',
    );
    final out = <Map<String, Object?>>[];
    for (final row in rows) {
      final days = await db.query(
        'track_experiment_day',
        where: 'experiment_id = ?',
        whereArgs: [row['id']],
        orderBy: 'date',
      );
      out.add({
        'id': row['id'],
        'track_id': row['track_id'],
        'start_date': row['start_date'],
        'end_date': row['end_date'],
        'weeks': row['weeks'],
        'seed': row['seed'],
        'assignments': [
          for (final d in days) {'date': d['date'], 'do': d['do_it'] == 1},
        ],
      });
    }
    return out;
  }

  Future<Map<String, Object?>> _experimentReport(
    String id, {
    DateTime? asOf,
  }) async {
    final experiment = (await _experiments()).where((e) => e['id'] == id);
    if (experiment.isEmpty) throw ArgumentError('experiment');
    final e = experiment.single;
    final trackId = e['track_id'] as String;
    final start = e['start_date'] as String, end = e['end_date'] as String;
    final now = asOf ?? clock.now();
    final report = <String, Object?>{
      'id': id,
      'track_id': trackId,
      'start_date': start,
      'end_date': end,
      'effects': <String, Object?>{},
    };
    if (end != endDate(start, e['weeks'] as int)) {
      return {...report, 'status': 'stopped'};
    }
    // The final night is part of the experiment; nothing is concluded early.
    if (dayLabelOf(now).compareTo(end) <= 0) {
      return {...report, 'status': 'running'};
    }
    // CLAIM(last-night-before-complete): the last assigned night is day_id
    // end+1; on that morning wait for it to be finalized, and conclude anyway
    // once a grace day has passed [review T14; tracks_experiments_t3_test.dart].
    final lastNightDay = dayLabelBefore(end, -1)!;
    if (dayLabelOf(now) == lastNightDay &&
        (await db.query(
          'day_result',
          columns: ['day_id'],
          where: 'day_id = ? AND finalized = 1 AND partial = 0 AND skipped = 0',
          whereArgs: [lastNightDay],
          limit: 1,
        )).isEmpty) {
      return {...report, 'status': 'running'};
    }
    final assigned = (e['assignments'] as List).cast<Map>();
    final logged = {
      for (final r in await db.rawQuery(
        'SELECT DISTINCT date FROM track_event_feed '
        'WHERE track_id = ? AND date BETWEEN ? AND ?',
        [trackId, start, end],
      ))
        r['date'] as String,
    };
    final absent = {
      for (final r in await db.query(
        'track_absence',
        where: 'track_id = ? AND date BETWEEN ? AND ?',
        whereArgs: [trackId, start, end],
      ))
        r['date'] as String,
    };
    final followed = <String, bool>{
      for (final day in assigned)
        if (day['do'] == true
            ? logged.contains(day['date'])
            : absent.contains(day['date']) && !logged.contains(day['date']))
          day['date'] as String: day['do'] as bool,
    };
    final done = {...report, 'status': 'completed'};
    done['adherence'] = {'assigned': assigned.length, 'followed': followed.length};
    if (followed.length < assigned.length * minExperimentAdherence) {
      return {...done, 'reason': 'insufficient_adherence'};
    }
    final systems = [
      for (final s in (await definitions()).firstWhere((d) => d.id == trackId).systems)
        if (experimentSystems.contains(s)) s,
    ];
    final first = DateTime.parse(start);
    final nights = await db.rawQuery(
      'SELECT d.day_id AS day_id, '
      'COALESCE(json_extract(d.window_json, \'\$.value.onset_ms\'), '
      'json_extract(d.window_json, \'\$.onset_ms\')) AS onset, '
      'COALESCE(json_extract(d.window_json, \'\$.value.offset_ms\'), '
      'json_extract(d.window_json, \'\$.offset_ms\')) AS offset, '
      'json_extract(d.payload_json, \'\$.scalars.rhr\') AS hr, '
      'json_extract(d.payload_json, \'\$.scalars.rmssd\') AS hrv, '
      'json_extract(d.payload_json, \'\$.scalars.stress\') AS stress, '
      'json_extract(d.payload_json, \'\$.scalars.skin_temp_dev_c\') AS skin_temp, '
      'json_extract(d.payload_json, \'\$.scalars.strain\') AS workout_intensity, '
      'json_extract(d.payload_json, \'\$.scalars.readiness\') AS recovery, '
      'json_extract(d.payload_json, \'\$.scalars.resp_rate\') AS respiration, '
      'json_extract(d.payload_json, \'\$.sleep.accounting.value.tst_sec\') AS tst '
      'FROM day_result d WHERE d.finalized = 1 AND d.partial = 0 '
      'AND d.skipped = 0 AND d.day_id BETWEEN ? AND ? '
      'AND d.algo_version = (SELECT MAX(n.algo_version) FROM day_result n '
      'WHERE n.day_id = d.day_id)',
      // The night after assigned date D is filed under D+1, so the range is
      // [start+1, end+1].
      [
        dayLabelOf(DateTime(first.year, first.month, first.day + 1)),
        dayLabelOf(DateTime(first.year, first.month, first.day + 7 * (e['weeks'] as int))),
      ],
    );
    final doValues = <String, List<double>>{}, skipValues = <String, List<double>>{};
    for (final night in nights) {
      final onset = night['onset'] as num?, offset = night['offset'] as num?;
      if (onset == null || offset == null || offset > now.millisecondsSinceEpoch) {
        continue;
      }
      // CLAIM(night-by-wake-day): the derive files a sleep under the local date
      // it ENDS on [substrate.dart "The main sleep that ENDS in this calendar
      // day"], so the night after assigned date D is day_id D+1 and a date owns
      // at most one night (day_id is unique per algo_version) [tracks_experiments_t3_test].
      // ↳ CLAIM(night-by-wake-day)
      final date = dayLabelBefore(night['day_id'] as String, 1);
      final arm = followed[date];
      if (arm == null) continue;
      for (final system in systems) {
        final raw = system == 'sleep' && night['tst'] is num
            ? (night['tst'] as num) / 60
            : night[system];
        if (raw is num && raw.isFinite) {
          (arm ? doValues : skipValues)
              .putIfAbsent(system, () => [])
              .add(raw.toDouble());
        }
      }
    }
    final effects = <String, Object?>{};
    for (final system in systems) {
      final effect = experimentEffect(
        doValues[system] ?? const [],
        skipValues[system] ?? const [],
      );
      if (effect != null) effects[system] = effect;
    }
    done['effects'] = effects;
    if (effects.isEmpty) done['reason'] = 'insufficient_data';
    return done;
  }

  /// One descriptor per experiment with an assignment on [date]. The caller
  /// emits them through NotificationCenter, whose gates own preference and
  /// fire-once behaviour; nothing here logs adherence.
  Future<List<Map<String, Object?>>> _experimentReminders({
    required String date,
  }) async {
    // Names come straight from SQL: this runs inside the background derive,
    // where only registered worker entries may dispatch.
    final rows = await db.rawQuery(
      'SELECT x.id, x.track_id, d.do_it, '
      "json_extract(t.payload_json, '\$.name') AS name "
      'FROM track_experiment x '
      'JOIN track_experiment_day d ON d.experiment_id = x.id '
      'JOIN track_definition t ON t.id = x.track_id '
      // ↳ CLAIM(never-ask-skip-prescribed): read the LIVE definition, so a
      // medication, a restored experiment and a track marked prescribed after
      // the start all stay silent.
      "WHERE d.date = ? AND x.track_id NOT LIKE 'med:%' "
      "AND COALESCE(json_extract(t.payload_json, '\$.prescribed'), 0) = 0 "
      // ↳ CLAIM(stop-ends-reminders): "deleting" a track only disables it.
      "AND COALESCE(json_extract(t.payload_json, '\$.enabled'), 1) != 0",
      [date],
    );
    return [
      for (final row in rows)
        {
          'date': date,
          'experiment_id': row['id'],
          'track_id': row['track_id'],
          'track_name': row['name'] ?? row['track_id'],
          'do': row['do_it'] == 1,
          'category': 'reminders',
          'dedupe_key': '$date:experiment:${row['id']}',
          'route': Uri(
            path: '/tracks/experiment',
            queryParameters: {'id': row['id'] as String},
          ).toString(),
        },
    ];
  }
}
