part of 'tracks_store.dart';

// TracksStore owns learning, completeness confirmations and audit writes too.
// Snapshots are computed in the registered worker. A content stamp rejects
// concurrent edits before the atomic definition/state/audit switch.
extension TracksLearningStore on TracksStore {
  Future<void> _confirmNone(String trackId, String date) async {
    if (!TracksStore._validDay(date)) throw ArgumentError('date');
    final tracks = await db.rawQuery(
      "SELECT id FROM track_definition WHERE id = ? UNION ALL "
      "SELECT 'med:' || key AS id FROM med_def WHERE 'med:' || key = ? LIMIT 1",
      [trackId, trackId],
    );
    if (tracks.isEmpty) throw ArgumentError('track');
    await db.transaction((tx) async {
      final logged = await tx.query(
        'track_event_feed',
        columns: ['id'],
        where: 'track_id = ? AND date = ?',
        whereArgs: [trackId, date],
        limit: 1,
      );
      if (logged.isNotEmpty) throw StateError('already_logged');
      await tx.insert('track_absence', {
        'track_id': trackId,
        'date': date,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  Future<Map<String, Map<String, Object?>>> _refreshLearning({
    DateTime? asOf,
  }) async {
    final now = asOf ?? DateTime.now();
    final experimentResults = await _completedExperimentResults(now);
    final snapshot = await db.transaction(
      (tx) async => TrackLearningInput(
        definitions: await tx.query('track_definition', orderBy: 'id'),
        medications: await tx.query('med_def', orderBy: 'key'),
        events: await tx.query('track_event_feed', orderBy: 'date, at_ms'),
        history: await tx.query('track_setup_history'),
        absences: await tx.query('track_absence'),
        unknownDays: await tx.query('track_unknown_day'),
        experiments: await tx.query('track_experiment', orderBy: 'id'),
        states: await tx.query('track_learning'),
        experimentResults: experimentResults,
        days: await tx.rawQuery(
          'SELECT d.* FROM day_result d WHERE finalized = 1 AND partial = 0 AND skipped = 0 '
          'AND algo_version = (SELECT MAX(algo_version) FROM day_result n WHERE n.day_id = d.day_id) '
          'ORDER BY day_id DESC LIMIT 730',
        ),
        worker: WorkerInputs(
          nowEpochMs: now.millisecondsSinceEpoch,
          zoneId: 'UTC',
          localeTag: 'en',
        ),
      ),
    );
    final dispatchId = WorkerAudit.dispatched(Dispatcher.run, 'track learning');
    final auditPort = WorkerAudit.auditPort;
    final result = await Isolate.run(() {
      WorkerAudit.adopt(auditPort, dispatchId);
      return trackLearningHeavy(snapshot);
    });
    final applied = await db.transaction((tx) async {
      // Compare the snapshot's inputs, not only its definition. A second
      // concurrent learner must not count or apply the same nightly step twice.
      final fresh = await tx.query('track_definition', orderBy: 'id');
      final freshEvents = await tx.query(
        'track_event_feed',
        orderBy: 'date, at_ms',
      );
      final freshStates = await tx.query('track_learning');
      final freshDays = await tx.rawQuery(
        'SELECT d.* FROM day_result d WHERE finalized = 1 AND partial = 0 AND skipped = 0 '
        'AND algo_version = (SELECT MAX(algo_version) FROM day_result n WHERE n.day_id = d.day_id) '
        'ORDER BY day_id DESC LIMIT 730',
      );
      if (!_sameRows(
            await tx.query('med_def', orderBy: 'key'),
            snapshot.medications,
          ) ||
          !_sameRows(freshDays, snapshot.days) ||
          !_sameRows(fresh, snapshot.definitions) ||
          !_sameRows(freshEvents, snapshot.events) ||
          !_sameRows(freshStates, snapshot.states) ||
          !_sameRows(await tx.query('track_absence'), snapshot.absences) ||
          !_sameRows(await tx.query('track_unknown_day'), snapshot.unknownDays) ||
          !_sameRows(
            await tx.query('track_experiment', orderBy: 'id'),
            snapshot.experiments,
          ) ||
          !_sameRows(await tx.query('track_setup_history'), snapshot.history)) {
        return false;
      }
      for (final raw in result.updates) {
        final row = (raw as Map).cast<String, Object?>();
        if (row['definition_json'] is String) {
          await tx.update(
            'track_definition',
            {'payload_json': row['definition_json']},
            where: 'id = ?',
            whereArgs: [row['track_id']],
          );
        }
        await tx.insert('track_learning', {
          'track_id': row['track_id'],
          'started_ms': row['started_ms'],
          'state_json': row['state_json'],
          'last_step_date': row['last_step_date'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        for (final log in row['logs'] as List) {
          await tx.insert(
            'track_learning_log',
            (log as Map).cast<String, Object?>(),
          );
        }
      }
      return true;
    });
    return applied ? result.summaries : {};
  }

  /// The latest eligible COMPLETED result per track x system. Stopped, running
  /// and unreportable experiments give none.
  Future<List<Map<String, Object?>>> _completedExperimentResults(DateTime now) async {
    // Newest first, so the first ELIGIBLE (completed, reportable) result for a
    // track x system wins. A newer running, future, stopped or unreportable
    // experiment never hides an older completed result [review R3-1].
    final rows = await db.query('track_experiment', orderBy: 'end_date DESC, id DESC');
    final seen = <String>{};
    final out = <Map<String, Object?>>[];
    for (final row in rows) {
      final trackId = row['track_id'] as String;
      final report = await _experimentReport(row['id'] as String, asOf: now);
      if (report['status'] != 'completed') continue;
      for (final e in (report['effects'] as Map).entries) {
        if (!seen.add('$trackId|${e.key}')) continue;
        final effect = e.value as Map;
        out.add({
          'experiment_id': row['id'],
          'track_id': trackId,
          'system': e.key,
          'effect': effect['effect'],
          'lower': effect['lower'],
          'upper': effect['upper'],
          'n_do': effect['n_do'],
          'n_dont': effect['n_dont'],
        });
      }
    }
    return out;
  }

  /// The wearer's "use my day-to-day data instead": every system currently
  /// shown from an experiment returns to the observational estimate until a
  /// NEWER experiment completes. ArgumentError for a track with no learning
  /// state; a no-op when nothing is shown from an experiment.
  // CLAIM(experiment-precedence) [review T18]
  Future<void> _releaseExperimentPrecedence(String trackId) async {
    final rows = await db.query('track_learning', columns: ['track_id'], where: 'track_id = ?', whereArgs: [trackId]);
    if (rows.isEmpty) throw ArgumentError('track');
    await db.execute(
      'UPDATE track_learning SET state_json = json_set(state_json, '
      "'\$.experiment_released', json_patch("
      "COALESCE(json_extract(state_json, '\$.experiment_released'), '{}'), "
      '(SELECT json_group_object(json_extract(e.value, \'\$.system\'), '
      "json_extract(e.value, '\$.experiment_id')) FROM json_each(state_json, '\$.displayed_effects') e "
      "WHERE json_extract(e.value, '\$.reason') = 'from_experiment'))) "
      'WHERE track_id = ? AND EXISTS (SELECT 1 FROM json_each(state_json, '
      "'\$.displayed_effects') e WHERE json_extract(e.value, '\$.reason') = 'from_experiment')",
      [trackId],
    );
  }

  static bool _sameRows(
    List<Map<String, Object?>> a,
    List<Map<String, Object?>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (final e in a[i].entries) {
        if (b[i][e.key] != e.value) return false;
      }
    }
    return true;
  }
}
