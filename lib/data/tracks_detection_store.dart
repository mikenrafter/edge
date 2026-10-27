part of 'tracks_store.dart';

// Detection candidates go through ActivityStore (the review seam). TracksStore
// adds the per-track daily bounds, the evidence gates and the minimum-count
// questions. Only the wearer's confirmation ever writes a track event.
extension TracksDetectionStore on TracksStore {
  static const _detectors = TrackDetectors();

  Future<int> _countCandidates(String trackId, String date) async =>
      Sqflite.firstIntValue(
        await db.rawQuery(
          "SELECT COUNT(*) FROM activity_suggestions WHERE kind = 'track' "
          "AND day_id = ? AND status IN ('pending', 'confirmed', 'discarded') "
          "AND json_extract(details_json, '\$.track_id') = ? "
          "AND COALESCE(json_extract(details_json, '\$.prompt'), 0) = 0",
          [date, trackId],
        ),
      ) ??
      0;

  /// The stable T2 effects for the track's selected systems, or none.
  Future<List<LearnedSignature>> _learnedSignatures(
    TrackDefinition track,
    int nowMs,
  ) async {
    final rows = await db.rawQuery(
      "SELECT l.started_ms AS started, "
      "json_extract(e.value, '\$.system') AS system, "
      "json_extract(e.value, '\$.effect') AS effect, "
      "json_extract(e.value, '\$.reason') AS reason, "
      "json_extract(e.value, '\$.matched_pairs') AS pairs, "
      "json_extract(e.value, '\$.adjusted_p') AS adjusted, "
      "json_extract(e.value, '\$.shuffle_p') AS shuffle "
      "FROM track_learning l, json_each(l.state_json, '\$.effects') e "
      "WHERE l.track_id = ?",
      [track.id],
    );
    return [
      for (final row in rows)
        if (track.systems.contains(row['system']) &&
            TrackDetectors.pastGlobalPeriod(row['started'] as int, nowMs) &&
            TrackDetectors.stable(
              reason: row['reason'] as String?,
              effect: row['effect'] as num?,
              pairs: row['pairs'] as num?,
              adjustedP: row['adjusted'] as num?,
              shuffleP: row['shuffle'] as num?,
            ))
          LearnedSignature(
            row['system'] as String,
            (row['effect'] as num).toDouble(),
          ),
    ];
  }

  static String? _reasonFor(
    String trackId,
    DetectionWindow window,
    Set<String> systems,
    List<LearnedSignature> learned,
  ) => switch (trackId) {
    'alcohol' => _detectors.alcohol(window, systems),
    'cannabis' => _detectors.cannabis(window, systems),
    'caffeine' => null,
    _ => _detectors.learned(window, learned),
  };

  Future<Map<String, Object?>> _refreshDetections({
    required String date,
    required List<Map<String, Object?>> windows,
    DateTime? asOf,
  }) async {
    if (!TracksStore._validDay(date)) throw ArgumentError('date');
    final nowMs = (asOf ?? DateTime.now()).millisecondsSinceEpoch;
    final observed = [
      for (final map in windows) ?DetectionWindow.fromMap(map),
    ]..sort((a, b) => a.startTs.compareTo(b.startTs));
    final today = [
      for (final w in observed)
        if (dayLabelOf(DateTime.fromMillisecondsSinceEpoch(w.startTs * 1000)) ==
            date)
          w,
    ];
    final store = ActivityStore(db);
    final tracks = [
      for (final t in await definitions(enabledOnly: true))
        if (t.roles.contains('detectable')) t,
    ];
    final candidates = <ActivitySuggestion>[];
    final promptTracks = <String>{};
    final day = DateTime.parse(date);
    final dayStart = DateTime(day.year, day.month, day.day);
    for (final track in tracks) {
      var count = await _countCandidates(track.id, date);
      final learned = TrackDetectors.hasPreset(track.id) ||
              track.id == 'caffeine'
          ? const <LearnedSignature>[]
          : await _learnedSignatures(track, nowMs);
      final systems = track.systems.toSet();
      for (final window in today) {
        if (count >= track.detectionMax) break;
        final reason = _reasonFor(track.id, window, systems, learned);
        if (reason == null) continue;
        final made = await store.reconcile(ActivityKind.track, [
          {
            'id': 'track:${track.id}:${window.startTs}',
            'track_id': track.id,
            'track_name': track.name,
            'start_ts': window.startTs,
            'end_ts': window.endTs,
            'evidence_kind': reason,
            'signals': window.evidence(),
          },
        ]);
        candidates.addAll(made);
        count = await _countCandidates(track.id, date);
      }
      if (track.detectionMin <= 0) continue;
      final logged = Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM track_event_feed '
              'WHERE track_id = ? AND date = ?',
              [track.id, date],
            ),
          ) ??
          0;
      final answered = (await db.query(
        'track_absence',
        where: 'track_id = ? AND date = ?',
        whereArgs: [track.id, date],
        limit: 1,
      )).isNotEmpty;
      // Pending candidates are evidence the day is not empty; the question is
      // only for a day with fewer occurrences than the wearer's minimum.
      final pendingCandidates = Sqflite.firstIntValue(
            await db.rawQuery(
              "SELECT COUNT(*) FROM activity_suggestions WHERE kind = 'track' "
              "AND day_id = ? AND status = 'pending' "
              "AND json_extract(details_json, '\$.track_id') = ? "
              "AND COALESCE(json_extract(details_json, '\$.prompt'), 0) = 0",
              [date, track.id],
            ),
          ) ??
          0;
      if (answered || logged + pendingCandidates >= track.detectionMin) continue;
      promptTracks.add(track.id);
      await store.reconcile(ActivityKind.track, [
        {
          'id': 'track-prompt:${track.id}:$date',
          'track_id': track.id,
          'track_name': track.name,
          'prompt': true,
          'date': date,
          'start_ts': dayStart.millisecondsSinceEpoch ~/ 1000,
          'end_ts':
              DateTime(day.year, day.month, day.day + 1)
                  .millisecondsSinceEpoch ~/
              1000,
        },
      ]);
    }
    // A question the wearer answered (or the data now settles) leaves review.
    final pending = await db.query(
      'activity_suggestions',
      where:
          "kind = 'track' AND status = 'pending' AND day_id = ? "
          "AND COALESCE(json_extract(details_json, '\$.prompt'), 0) = 1",
      whereArgs: [date],
    );
    final prompts = <Map<String, Object?>>[];
    final stale = <String>[];
    for (final row in pending) {
      final suggestion = ActivitySuggestion.fromRow(row);
      if (promptTracks.contains(suggestion.trackId)) {
        prompts.add({
          'track_id': suggestion.trackId,
          'track_name': suggestion.details['track_name'],
          'date': date,
          'suggestion_id': suggestion.id,
        });
      } else {
        stale.add(suggestion.id);
      }
    }
    if (stale.isNotEmpty) {
      await db.transaction((tx) async {
        for (final id in stale) {
          await tx.update(
            'activity_suggestions',
            {'status': 'superseded'},
            where: "id = ? AND status = 'pending'",
            whereArgs: [id],
          );
        }
        await ActivityStore.markDayChanged(tx, date);
      });
    }
    return {'candidates': candidates, 'prompts': prompts};
  }
}
