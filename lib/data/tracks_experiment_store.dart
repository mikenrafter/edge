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
        'created_ms': DateTime.now().millisecondsSinceEpoch,
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
    final now = asOf ?? DateTime.now();
    final report = <String, Object?>{
      'id': id,
      'track_id': trackId,
      'start_date': start,
      'end_date': end,
      'effects': <String, Object?>{},
    };
    // The final night is part of the experiment; nothing is concluded early.
    if (dayLabelOf(now).compareTo(end) <= 0) {
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
      'SELECT COALESCE(json_extract(d.window_json, \'\$.value.onset_ms\'), '
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
      [
        start,
        dayLabelOf(DateTime(first.year, first.month, first.day + 7 * (e['weeks'] as int) + 1)),
      ],
    );
    final doValues = <String, List<double>>{}, skipValues = <String, List<double>>{};
    for (final night in nights) {
      final onset = night['onset'] as num?, offset = night['offset'] as num?;
      if (onset == null || offset == null || offset > now.millisecondsSinceEpoch) {
        continue;
      }
      final date = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch(onset.toInt()),
      );
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
      "COALESCE(m.label, json_extract(t.payload_json, '\$.name')) AS name "
      'FROM track_experiment x '
      'JOIN track_experiment_day d ON d.experiment_id = x.id '
      'LEFT JOIN track_definition t ON t.id = x.track_id '
      "LEFT JOIN med_def m ON 'med:' || m.key = x.track_id WHERE d.date = ?",
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
