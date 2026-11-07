part of '../db.dart';

Future<List<String>> _ldbToggleCycleSymptom(
    String date,
    String symptom,
  ) async {
    final db = await LocalDb.instance;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'cycle_symptom',
        columns: ['symptoms_json', 'note'],
        where: 'date = ?',
        whereArgs: [date],
        limit: 1,
      );
      final row = rows.isEmpty ? null : rows.first;
      final now = <String>[];
      final raw = row?['symptoms_json'];
      if (raw is String) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) now.addAll(decoded.whereType<String>());
        } catch (_) {
          // A corrupt list is treated as empty rather than blocking the tap.
        }
      }
      final note = row?['note'] as String?;
      now.contains(symptom) ? now.remove(symptom) : now.add(symptom);
      if (now.isEmpty && (note == null || note.isEmpty)) {
        await txn.delete('cycle_symptom', where: 'date = ?', whereArgs: [date]);
      } else {
        await txn.insert('cycle_symptom', {
          'date': date,
          'symptoms_json': jsonEncode(now),
          'note': note,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      return now;
    });
  }

Future<void> _ldbPutStepCalibrationDay({
    required String day,
    required String deviceFamily,
    required int wearing,
    int? referenceSteps,
    int? counterTicks,
  }) async {
    final db = await LocalDb.instance;
    await db.insert(
      'step_calibration_day',
      {
        'day': day,
        'device_family': deviceFamily,
        'wearing': wearing,
        'reference_steps': referenceSteps,
        'counter_ticks': counterTicks,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

Future<StepCalibrationProfile?> _ldbStepCalibrationProfile(
    String deviceFamily,
    int wearing,
  ) async {
    final db = await LocalDb.instance;
    final r = await db.query(
      'step_calibration',
      where: 'device_family = ? AND wearing = ?',
      whereArgs: [deviceFamily, wearing],
      limit: 1,
    );
    if (r.isEmpty) return null;
    final row = r.first;
    final version = (row['version'] as num?)?.toInt() ?? 0;
    if (version != kStepCalibrationVersion) return null;
    return StepCalibrationProfile(
      deviceFamily: deviceFamily,
      wearing: wearing,
      factor: (row['factor'] as num?)?.toDouble() ?? 1.0,
      nDays: (row['n_days'] as num?)?.toInt() ?? 0,
      version: version,
    );
  }

Future<List<StepCalibrationRun>> _ldbLiveStepCalibrationRuns({
    DatabaseExecutor? exec,
  }) async {
    final db = exec ?? await LocalDb.instance;
    // Only runs the CURRENT counter scored. The open-time clear removes the
    // rest, but a restore can merge untagged rows in after that ran, and a
    // refit in between must not read them. See [kLiveStepCounterVersion].
    final rows = await db.query(
      'live_step_calibration_run',
      where: 'counter_version = ?',
      whereArgs: [kLiveStepCounterVersion],
      orderBy: 'run_ts DESC',
    );
    final out = <StepCalibrationRun>[];
    for (final r in rows) {
      final category = StepCategory.parse(r['category']);
      // A row whose category or reference this build does not know is SKIPPED,
      // not guessed: attaching a run to the wrong family would corrupt that
      // family's fit with another one's evidence.
      if (category == null) continue;
      final reference = switch (r['reference']) {
        'wearerCount' => StepReference.wearerCount,
        'phonePedometer' => StepReference.phonePedometer,
        _ => null,
      };
      if (reference == null) continue;
      out.add(StepCalibrationRun(
        category: category,
        reference: reference,
        expectedSteps: (r['expected_steps'] as num?)?.toInt() ?? 0,
        rawSteps: (r['raw_steps'] as num?)?.toInt() ?? 0,
        cadenceSpm: (r['cadence_spm'] as num?)?.toDouble() ?? 0,
        // NULL PASSES THROUGH AS NULL. These two columns are nullable precisely
        // so a routine whose caller never measured them stores an ABSENCE — and
        // a `?? 0` here would turn that absence back into a real still reading at
        // the bottom of the scale, which is the fabrication the nullable column
        // exists to prevent. `cadence_spm` above keeps its `?? 0` because it is
        // NOT NULL and 0 there means "no cadence measurable", not a measurement.
        peakToPeakG: (r['p2p_g'] as num?)?.toDouble(),
        confidence: (r['confidence'] as num?)?.toDouble(),
      ));
    }
    return out;
  }

Future<void> _ldbPutLiveStepCalibrationRun(
    StepCalibrationRun r, {
    required int runTs,
    DatabaseExecutor? exec,
  }) async {
    final db = exec ?? await LocalDb.instance;
    await db.insert(
      'live_step_calibration_run',
      {
        'category': r.category.key,
        'run_ts': runTs,
        'reference': switch (r.reference) {
          StepReference.wearerCount => 'wearerCount',
          StepReference.phonePedometer => 'phonePedometer',
        },
        'expected_steps': r.expectedSteps,
        'raw_steps': r.rawSteps,
        'cadence_spm': r.cadenceSpm,
        'p2p_g': r.peakToPeakG,
        'confidence': r.confidence,
        'counter_version': kLiveStepCounterVersion,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

Future<LiveStepGainProfile> _ldbBankLiveStepCalibrationRun(
    StepCalibrationRun run, {
    required int runTs,
    DateTime? now,
  }) {
    // SERIALISED, because two routines for the same category banking at once can
    // each read a different history snapshot and write their profiles in the
    // opposite order — leaving the older result in place while the newer run is
    // already durable. One lock rather than one per category: a save is three
    // writes and the contention case is a user tapping two routines, so the
    // simpler invariant is worth more than the parallelism.
    // ONE transaction: a run that is durable without the profile it implies
    // (the refit read or the profile write failing after the insert) would be
    // reported to the wearer as a failed save while later fits quietly used it.
    final chained = LocalDb._liveStepGainLock.then((_) async {
      final db = await LocalDb.instance;
      return db.transaction((txn) async {
        await LocalDb.putLiveStepCalibrationRun(run, runTs: runTs, exec: txn);
        return LocalDb.refitLiveStepGain(run.category, now: now, exec: txn);
      });
    });
    // The chain must survive this save's own failure, or one bad routine would
    // block every later one.
    LocalDb._liveStepGainLock = chained.then((_) {}, onError: (_) {});
    return chained;
  }

Future<LiveStepGainProfile?> _ldbLiveStepGainProfile(
    StepCategory category,
  ) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'live_step_calibration',
      where: 'category = ?',
      whereArgs: [category.key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    if ((row['version'] as num?)?.toInt() != kLiveStepGainVersion) return null;
    final gain = (row['gain'] as num?)?.toDouble();
    // The row's own clamp is re-checked here: a hand-edited or restored row must
    // not be able to present a gain the fit would never have produced.
    if (gain == null || !gain.isFinite) return null;
    if (gain < gainFloor(category) || gain > gainCeiling(category)) return null;
    return LiveStepGainProfile(
      version: kLiveStepGainVersion,
      category: category,
      gain: gain,
      nRuns: (row['n_runs'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        ((row['updated_ts'] as num?)?.toInt() ?? 0) * 1000,
      ),
    );
  }

Future<void> _ldbInsertEcgReading(
    Map<String, Object?> reading,
    List<Map<String, Object?>> packets,
  ) async {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      await txn.insert(
        'ecg_reading',
        reading,
        conflictAlgorithm: ConflictAlgorithm.fail,
      );
      final batch = txn.batch();
      for (var i = 0; i < packets.length; i++) {
        batch.insert(
          'ecg_reading_packet',
          {...packets[i], 'reading_id': reading['id'], 'ordinal': i},
          conflictAlgorithm: ConflictAlgorithm.fail,
        );
      }
      await batch.commit(noResult: true);
    });
  }

Future<void> _ldbSetAlarmScheduleDay({
    required int weekday,
    required int hour,
    required int minute,
    required bool enabled,
    int smartWindowMinutes = 0,
  }) async {
    final db = await LocalDb.instance;
    await db.insert(
      'alarm_schedule',
      {
        'weekday': weekday,
        'hour': hour,
        'minute': minute,
        'enabled': enabled ? 1 : 0,
        'smart_window_minutes': smartWindowMinutes,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

Future<void> _ldbPutVendorSleepEpochs(
    List<VendorEpoch> epochs, {
    required String deviceId,
    required String source,
    required bool wholeNights,
  }) async {
    if (epochs.isEmpty) return;
    final sorted = [...epochs]..sort((a, b) => a.startSec.compareTo(b.startSec));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      for (final e in sorted) {
        // A re-reported whole night that starts later would otherwise keep
        // the old report's leading epochs, chained in by onset.
        if (wholeNights) {
          await txn.rawDelete(
              'DELETE FROM vendor_sleep_epoch WHERE device_id = ? AND '
              'night_onset_ts IN (SELECT night_onset_ts FROM '
              'vendor_sleep_epoch WHERE device_id = ? AND start_ts < ? '
              'AND end_ts > ?)',
              [deviceId, deviceId, e.endSec, e.startSec]);
        }
        await txn.delete('vendor_sleep_epoch',
            where: 'device_id = ? AND start_ts < ? AND end_ts > ?',
            whereArgs: [deviceId, e.endSec, e.startSec]);
      }
      int? onset;
      var prevEnd = 0;
      for (final e in sorted) {
        if (onset == null || e.startSec - prevEnd > LocalDb._kVendorNightChainSec) {
          final prior = await txn.rawQuery(
            'SELECT night_onset_ts FROM vendor_sleep_epoch '
            'WHERE device_id = ? AND end_ts >= ? AND start_ts < ? '
            'ORDER BY end_ts DESC LIMIT 1',
            [deviceId, e.startSec - LocalDb._kVendorNightChainSec, e.startSec],
          );
          onset = prior.isEmpty
              ? e.startSec
              : (prior.first['night_onset_ts'] as num).toInt();
        }
        await txn.insert('vendor_sleep_epoch', {
          'device_id': deviceId,
          'night_onset_ts': onset,
          'start_ts': e.startSec,
          'end_ts': e.endSec,
          'stage': e.stage,
          'source': source,
          'decoded_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        prevEnd = e.endSec;
      }
    });
  }

Future<List<VendorNight>> _ldbVendorSleepNights(
      int fromSec, int toSec) async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      'SELECT * FROM vendor_sleep_epoch '
      'WHERE night_onset_ts >= ? AND night_onset_ts < ? '
      'ORDER BY device_id, night_onset_ts, start_ts',
      [fromSec, toSec],
    );
    final out = <VendorNight>[];
    String? key;
    for (final r in rows) {
      final k = '${r['device_id']}|${r['night_onset_ts']}';
      final ep = VendorEpoch((r['start_ts'] as num).toInt(),
          (r['end_ts'] as num).toInt(), r['stage'] as String);
      final decodedAt = (r['decoded_at'] as num).toInt();
      if (k != key) {
        key = k;
        out.add(VendorNight(
          deviceId: r['device_id'] as String,
          source: r['source'] as String,
          decodedAtSec: decodedAt,
          epochs: [ep],
        ));
      } else {
        final n = out.removeLast();
        out.add(VendorNight(
          deviceId: n.deviceId,
          source: n.source,
          decodedAtSec:
              decodedAt > n.decodedAtSec ? decodedAt : n.decodedAtSec,
          epochs: n.epochs..add(ep),
        ));
      }
    }
    return out;
  }

Future<int> _ldbPutObservations(
    List<Observation> rows, {
    required String deviceId,
    required Map<String, String> cursors,
  }) async {
    if (rows.isEmpty && cursors.isEmpty) return 0;
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      for (final c in cursors.entries) {
        await LocalDb.setCursor(c.key, c.value, txn: txn);
      }
      final batch = txn.batch();
      for (final o in rows) {
        batch.insert('observation', {
          'device_id': deviceId,
          'ts_ms': o.at.millisecondsSinceEpoch,
          'date': o.date,
          'source_kind': o.sourceKind.name,
          'vendor_key': o.vendorKey,
          'key': o.key,
          'value': o.value.toDouble(),
          'unit': o.unit,
          'attribution': o.attribution,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    return rows.length;
  }

Future<int> _ldbDeleteImportedWorkoutsMissing(
    int startSec,
    int endSec,
    Set<String> present,
  ) async {
    final db = await LocalDb.instance;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'imported_workout',
        columns: ['uuid'],
        where: 'start_ts >= ? AND start_ts <= ?',
        whereArgs: [startSec, endSec],
      );
      final gone = [
        for (final r in rows)
          if (!present.contains(r['uuid'])) r['uuid'] as String,
      ];
      for (final u in gone) {
        await txn.delete('imported_workout',
            where: 'uuid = ?', whereArgs: [u]);
        await txn.delete('workout_route',
            where: 'session_id = ?', whereArgs: [u]);
      }
      return gone.length;
    });
  }

Future<List<List<int>>> _ldbToggleSpans(
    int loSec,
    int hiSec, {
    required int onId,
    required int offId,
    required String deviceId,
  }) async {
    if (hiSec <= loSec) return const [];
    final db = await LocalDb.instance;
    // One row before the window establishes the state we open in.
    final prior = await db.query(
      'band_events',
      columns: ['ts', 'event_id'],
      where: 'device_id = ? AND ts < ? AND event_id IN (?, ?)',
      whereArgs: [deviceId, loSec, onId, offId],
      orderBy: 'ts DESC',
      limit: 1,
    );
    final rows = await db.query(
      'band_events',
      columns: ['ts', 'event_id'],
      where: 'device_id = ? AND ts >= ? AND ts < ? AND event_id IN (?, ?)',
      whereArgs: [deviceId, loSec, hiSec, onId, offId],
      orderBy: 'ts ASC',
    );

    final spans = <List<int>>[];
    int? openAt =
        (prior.isNotEmpty && (prior.first['event_id'] as num).toInt() == offId)
        ? loSec
        : null;
    for (final r in rows) {
      final ts = (r['ts'] as num).toInt();
      final id = (r['event_id'] as num).toInt();
      if (id == offId) {
        openAt ??= ts;
      } else if (openAt != null) {
        if (ts > openAt) spans.add([openAt, ts]);
        openAt = null;
      }
    }
    if (openAt != null && hiSec > openAt) spans.add([openAt, hiSec]);
    return spans;
  }

Future<({String day, int value, int? wakeSec})?> _ldbFrozenHeadline() async {
    final raw = await LocalDb.getCursor(LocalDb.kFrozenHeadlineCursor);
    final pin = LocalDb._parseFrozenHeadline(raw);
    if (pin == null) return null;
    final db = await LocalDb.instance;
    final dayExists = (await db.rawQuery(
      'SELECT 1 FROM day_result WHERE day_id = ? LIMIT 1',
      [pin.day],
    )).isNotEmpty;
    if (dayExists) return pin;
    await LocalDb.debugBeforeOrphanPinClear?.call();
    // Compare-and-delete: only the orphan read above. A derive can pin a new
    // headline between that read and here, and that pin must survive.
    await db.delete(
      'sync_cursor',
      where: 'name = ? AND value = ?',
      whereArgs: [LocalDb.kFrozenHeadlineCursor, raw],
    );
    return null;
  }

Future<int?> _ldbHeadlinePinFor(String day) async {
    final pin = await LocalDb.frozenHeadline();
    final pinWake = pin?.wakeSec;
    if (pin == null || pin.day != day || pinWake == null) return null;
    int? wake, onset;
    try {
      final raw = jsonDecode(await LocalDb.sleepWindowJsonFor(day) ?? '{}');
      // Bare SleepWindow JSON today; older rows wrap it in a `value` envelope.
      final w = raw is Map && raw['value'] is Map ? raw['value'] : raw;
      final ms = w is Map ? w['offset_ms'] : null;
      final on = w is Map ? w['onset_ms'] : null;
      wake = ms is num ? ms ~/ 1000 : null;
      onset = on is num ? on ~/ 1000 : null;
    } catch (_) {/* malformed window → no wake → no pin */}
    if (wake == null ||
        (wake - pinWake).abs() >= kPinWakeToleranceSec ||
        !pinnableNight(wakeSec: wake, onsetSec: onset)) {
      return null;
    }
    return pin.value;
  }

Future<Map<String, int>?> _ldbNoteHeadlineShown(
          String day, int value) async =>
      // One transaction: overlapping getToday calls must not write back a
      // stale read and walk the "from" side of the note backwards.
      (await LocalDb.instance).transaction((txn) async {
    Map? cur;
    try {
      final d = jsonDecode(
          await LocalDb.getCursor(LocalDb.kHeadlineShownCursor, txn: txn) ?? 'null');
      if (d is Map && d['day'] == day && d['value'] is num) cur = d;
    } catch (_) {/* malformed → start over */}
    if (cur != null && (cur['value'] as num).round() == value) {
      final prev = cur['prev'], at = cur['at'];
      return prev is num && at is num
          ? {'from': prev.round(), 'to': value, 'at': at.toInt()}
          : null;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await LocalDb.setCursor(
      LocalDb.kHeadlineShownCursor,
      jsonEncode({
        'day': day,
        'value': value,
        if (cur != null) 'prev': (cur['value'] as num).round(),
        if (cur != null) 'at': now,
      }),
      txn: txn,
    );
    return cur == null
        ? null
        : {'from': (cur['value'] as num).round(), 'to': value, 'at': now};
  });

Future<({
    List<Map<String, Object?>> previous,
    List<Map<String, Object?>> best,
  })> _ldbStrengthHistoryCandidates() async {
    final db = await LocalDb.instance;
    final previous = await db.rawQuery('''
      SELECT s.*
      FROM strength_set s
      JOIN (
        SELECT exercise_key, MAX(COALESCE(at_ts, 0)) AS newest_at
        FROM strength_set
        GROUP BY exercise_key
      ) newest
        ON newest.exercise_key = s.exercise_key
       AND newest.newest_at = COALESCE(s.at_ts, 0)
      ORDER BY s.exercise_key ASC, COALESCE(s.at_ts, 0) DESC,
               s.session_id DESC, s.seq DESC
    ''');
    final best = await db.rawQuery('''
      SELECT s.*
      FROM strength_set s
      JOIN (
        SELECT exercise_key, MAX(load_kg) AS best_load
        FROM strength_set
        WHERE load_kg IS NOT NULL
        GROUP BY exercise_key
      ) heaviest
        ON heaviest.exercise_key = s.exercise_key
       AND heaviest.best_load = s.load_kg
      ORDER BY s.exercise_key ASC, COALESCE(s.reps, 0) DESC,
               COALESCE(s.at_ts, 0) DESC, s.session_id DESC, s.seq DESC
    ''');
    return (previous: previous, best: best);
  }

Future<Map<String, Map<String, JournalMetricValue>>>
  _ldbJournalMetricsByDay({String? sinceDaysEpoch}) async {
    final db = await LocalDb.instance;
    final rows = sinceDaysEpoch == null
        ? await db.query('journal_metric', orderBy: 'date ASC')
        : await db.query(
            'journal_metric',
            where: 'date >= ?',
            whereArgs: [sinceDaysEpoch],
            orderBy: 'date ASC',
          );
    final out = <String, Map<String, JournalMetricValue>>{};
    for (final r in rows) {
      (out[r['date'] as String] ??= {})[r['field']
          as String] = JournalMetricValue(
        (r['value'] as num).toDouble(),
        atMinuteOfDay: (r['at_min'] as num?)?.toInt(),
      );
    }
    return out;
  }

Future<List<JournalFieldSpec>> _ldbJournalFieldDefs() async {
    final db = await LocalDb.instance;
    final rows = await db.query('journal_field_def', orderBy: 'label ASC');
    return [
      for (final r in rows)
        JournalFieldSpec(
          key: r['key'] as String,
          label: r['label'] as String,
          kind: JournalFieldKind.values.firstWhere(
            (k) => k.name == r['kind'],
            // A row written by a newer build with a kind this one has never
            // heard of still renders as a dose rather than crashing the whole
            // journal screen.
            orElse: () => JournalFieldKind.dose,
          ),
          unit: r['unit'] as String,
          max: (r['max_value'] as num).toDouble(),
          step: (r['step'] as num).toDouble(),
          hasTime: ((r['has_time'] as num?)?.toInt() ?? 0) == 1,
          custom: true,
        ),
    ];
  }

Future<void> _ldbPutJournalFieldDef(JournalFieldSpec spec) async {
    final db = await LocalDb.instance;
    final exists = await db.query(
      'journal_field_def',
      where: 'key = ?',
      whereArgs: [spec.key],
      limit: 1,
    );
    if (exists.isNotEmpty) {
      throw StateError('journal field already exists: ${spec.key}');
    }
    await db.insert('journal_field_def', {
      'key': spec.key,
      'label': spec.label,
      'kind': spec.kind.name,
      'unit': spec.unit,
      'max_value': spec.max,
      'step': spec.step,
      'has_time': spec.hasTime ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

Future<Map<String, int>> _ldbApplyPendingActivityReviews() async {
    final db = await LocalDb.instance;
    return db.transaction((tx) async {
      final pending = await tx.query(
        'activity_review_days', orderBy: 'day_id', limit: 25,
      );
      final revisions = <String, int>{};
      for (final job in pending) {
        final day = job['day_id'] as String;
        revisions[day] = job['revision'] as int;
        final rows = await tx.query(
          'day_result',
          where: 'day_id = ? AND algo_version <= ?',
          whereArgs: [day, kAlgoVersion],
          orderBy: 'algo_version DESC',
          limit: 1,
        );
        final edits = await ActivityStore.napEdits(tx, day);
        if (rows.isEmpty && edits.every((e) => e.kind == NapEditKind.rejected)) {
          continue;
        }
        // An accepted snapshot remains useful even if no day bundle survived.
        // It does not make that day fully derived or invent other metrics.
        final row = rows.isEmpty
            ? <String, Object?>{
                'day_id': day,
                'algo_version': kAlgoVersion,
                'payload_json': '{}',
                'window_json': '{}',
                'partial': 1,
              }
            : Map<String, Object?>.from(rows.single);
        final bundle = Map<String, dynamic>.from(
          jsonDecode(row['payload_json'] as String) as Map,
        );
        await ActivityStore.preserveLegacyNaps(tx, day, bundle);
        final acceptedEdits = await ActivityStore.napEdits(tx, day);
        if ((row['skipped'] == 1 || bundle['skipped'] == true) &&
            acceptedEdits.any((e) => e.kind == NapEditKind.added)) {
          // This day now has accepted information for navigation and summaries,
          // but still needs derivation before it can be finalized or pruned.
          row['skipped'] = 0;
          row['partial'] = 1;
          row['finalized'] = 0;
          bundle.remove('skipped');
          bundle.remove('reason');
        }
        composeAcceptedNaps(bundle, acceptedEdits);
        // Editing naps does not recompute the retained metrics. Keep their
        // version so scheduling and pruning still require a current derivation.
        await tx.insert('day_result', {
          ...row,
          'payload_json': jsonEncode(bundle),
          'computed_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await tx.insert('metric_series', {
          'date': day,
          'key': 'nap_min',
          'value': (bundle['scalars'] as Map?)?['nap_min'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (revisions.isNotEmpty) {
        // Each batch changes the rollup's inputs, even without another review.
        // Advance in this transaction so cached or in-flight calculations from
        // before these day writes cannot be published as current.
        await tx.rawUpdate('UPDATE activity_review_meta SET revision = revision + 1');
      }
      return revisions;
    });
  }

Future<void> _ldbPutNapEdit({
    required String dayId,
    required int startTs,
    required int endTs,
    required String source,
  }) async {
    final db = await LocalDb.instance;
    await db.transaction((tx) async {
      // A logged nap is credited whole on top of the main night's TST (nap_min,
      // total asleep, sleep-need credit), so one typed over the end of the
      // night — the doze after the alarm — counts those minutes twice.
      if (source == 'manual' &&
          await ActivityStore.overlapsMainSleep(tx, startTs, endTs)) {
        throw const ActivityReviewException(
          'That overlaps your main sleep, which already counts that time.',
        );
      }
      String? snapshot;
      if (source == 'rejected') {
        // A pre-upgrade nap may still live only in its retained day result.
        // Capture it before replacing that result with the user's rejection.
        final days = await tx.query('day_result',
          where: 'day_id = ? AND algo_version <= ?',
          whereArgs: [dayId, kAlgoVersion], orderBy: 'algo_version DESC', limit: 1);
        if (days.isNotEmpty) {
          await ActivityStore.preserveLegacyNaps(tx, dayId,
            Map<String, dynamic>.from(jsonDecode(days.single['payload_json'] as String) as Map));
        }
        final existing = await tx.query('sleep_nap',
          where: 'day_id = ? AND start_ts = ?', whereArgs: [dayId, startTs]);
        if (existing.isNotEmpty) snapshot = existing.single['payload_json'] as String?;
      }
      await tx.insert('sleep_nap', {
        'day_id': dayId, 'start_ts': startTs, 'end_ts': endTs,
        'source': source, 'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'payload_json': snapshot,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // Derivation drops any detection under an edit, so a pending one here
      // would never be reconciled again and could only fail to confirm.
      await ActivityStore.supersede(tx, ActivityKind.nap, startTs, endTs);
      await ActivityStore.markDayChanged(tx, dayId);
    });
  }

Future<void> _ldbDeleteNapEdit(String dayId, int startTs) async {
    final db = await LocalDb.instance;
    await db.transaction((tx) async {
      final rows = await tx.query('sleep_nap',
        where: 'day_id = ? AND start_ts = ?', whereArgs: [dayId, startTs]);
      await ActivityStore.markDayChanged(tx, dayId);
      String? restoreSource, restorePayload;
      if (rows.isNotEmpty && rows.single['source'] == 'rejected') {
        final payload = rows.single['payload_json'];
        if (payload is String) {
          final source = (jsonDecode(payload) as Map)['source'];
          if (source == 'confirmed' || source == 'legacy') restoreSource = source as String;
        } else {
          // A rejection from before activity review has no snapshot, and a
          // detection that old is never offered for review again. Put the
          // window back as a legacy nap so it is not lost for good; with no
          // measured split, asleep and in-bed are the whole window.
          final cutoff = (await tx.query('activity_review_meta')).single['activated_at'] as int;
          if (startTs < cutoff) {
            final min = (((rows.single['end_ts'] as int) - startTs) / 60).round();
            restoreSource = 'legacy';
            restorePayload = jsonEncode({
              'duration_min': min, 'in_bed_min': min,
              'confidence': null, 'source': 'legacy',
            });
          }
        }
      }
      if (restoreSource != null) {
        // Removing a rejection means "Put it back". Keep its original asleep
        // minutes and confidence even after raw recordings have expired.
        // This is now an explicit decision, even for a legacy snapshot: a
        // later main-window correction must not suppress it as old detection.
        restoreSource = 'confirmed';
        final restored = Map<String, dynamic>.from(jsonDecode(
          restorePayload ?? rows.single['payload_json'] as String) as Map);
        restored['source'] = restoreSource;
        restorePayload = jsonEncode(restored);
        await tx.update('sleep_nap', {
          'source': restoreSource,
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'payload_json': restorePayload,
        }, where: 'day_id = ? AND start_ts = ?', whereArgs: [dayId, startTs]);
      } else {
        await tx.delete('sleep_nap', where: 'day_id = ? AND start_ts = ?', whereArgs: [dayId, startTs]);
      }
    });
  }

Future<int> _ldbSetSessionWindow(String id, int startTs, int? endTs) async {
    final db = await LocalDb.instance;
    return db.transaction((tx) async {
      final n = await tx.update(
        'sessions',
        {
          'start_ts': startTs,
          'end_ts': endTs,
          'trace_json': null,
          'trace_samples': null,
          'avg_hr': null,
          'zone_min_json': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      if (n > 0) {
        await ActivityStore.supersede(tx, ActivityKind.workout, startTs,
            endTs ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
      }
      return n;
    });
  }

Future<int> _ldbSetSessionScores(
    String id, {
    required double? strain,
    required double? calories,
    required int? maxHr,
    required String zoneMinJson,
    int? avgHr,
    String? traceJson,
    int? traceSamples,
  }) async {
    final db = await LocalDb.instance;
    return db.update(
      'sessions',
      {
        'strain': strain,
        'calories': calories,
        'max_hr': maxHr,
        'zone_min_json': zoneMinJson,
        // Only when the re-score actually measured one. Writing null over a
        // previously-banked average because THIS pass found no substrate would
        // delete a real measurement.
        'avg_hr': ?avgHr,
        // Same rule for the frozen trace: only ever written when this pass
        // actually read a window. A pass that found no substrate must not wipe
        // the trace banked by an earlier one — the substrate is gone for good.
        'trace_json': ?traceJson,
        'trace_samples': ?traceSamples,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

Future<bool> _ldbFlagOffOnly(Map<String, dynamic> r,
      {DatabaseExecutor? executor}) async {
    final s = (r['start_ts'] as num?)?.toInt();
    final e = (r['end_ts'] as num?)?.toInt();
    if (s == null || e == null || r['status'] != 'done') return false;
    // Scored by a workout sensor whose flag is now off: its score is that
    // sensor's whatever else the window holds (a band's partial minutes, the
    // wearable's) and once its raw is pruned.
    // ponytail: a stamped window the band also measured serves empty too,
    // not band-only; rescore it from the band's rows if that matters.
    if ((await LocalDb.sessionSensorsOf(r['id'], executor: executor))
        .any((s) => !LocalDb.sessionSensorSources.contains(s))) {
      return true;
    }
    final on = {...LocalDb.sessionSensorSources, ?LocalDb.sessionWearableSource};
    final sources = [
      for (final x in await (executor ?? await LocalDb.instance).rawQuery(
          'SELECT DISTINCT source FROM decoded_onehz '
          'WHERE rec_ts >= ? AND rec_ts <= ? AND hr > 0',
          [s, e]))
        x['source'],
    ];
    return sources.isNotEmpty &&
        sources.every((x) =>
            x != null && !kDerivableSources.contains(x) && !on.contains(x));
  }

Future<Map<String, List<Map<String, Object?>>>> _ldbSessionWindows(
    int fromTs,
    int toTs,
  ) async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      'SELECT s.id AS id, d.source AS source, d.rec_ts AS rec_ts, d.hr AS hr '
      'FROM sessions s '
      'JOIN decoded_onehz d ON d.rec_ts >= s.start_ts '
      '  AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) '
      'WHERE s.start_ts >= ? AND s.start_ts <= ? '
      'ORDER BY s.id, d.rec_ts ASC',
      [fromTs, toTs],
    );
    final by = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id != null) (by[id] ??= []).add(r);
    }
    return {
      for (final MapEntry(key: id, value: rs) in by.entries)
        if ([
          for (final r in sessionWindowRows(rs))
            if (((r['hr'] as num?) ?? 0) > 0) r,
        ]
            case final kept when kept.isNotEmpty)
          id: kept,
    };
  }

Future<Map<String, Map<String, num>>> _ldbSessionHrStats(
    int fromTs,
    int toTs, {
    int maxHrCeiling = 0,
    int minHrFloor = 0,
  }) async {
    if (LocalDb.sessionSensorSources.isNotEmpty) {
      return {
        for (final MapEntry(key: id, value: rs)
            in (await LocalDb._sessionWindows(fromTs, toTs)).entries)
          id: () {
            final hr = [for (final r in rs) (r['hr'] as num).toInt()];
            final low = [
              for (final h in hr)
                if (minHrFloor <= 0 || h >= minHrFloor) h,
            ];
            final high = [
              for (final h in hr)
                if (maxHrCeiling <= 0 || h <= maxHrCeiling) h,
            ];
            return <String, num>{
              'n': hr.length,
              'avg_hr': hr.fold<int>(0, (a, b) => a + b) / hr.length,
              'min_hr': low.isEmpty ? 0 : low.reduce((a, b) => a < b ? a : b),
              'max_hr': high.isEmpty ? 0 : high.reduce((a, b) => a > b ? a : b),
            };
          }(),
      };
    }
    final db = await LocalDb.instance;
    final ceilClause = maxHrCeiling > 0 ? 'AND d.hr <= $maxHrCeiling ' : '';
    final floorClause = minHrFloor > 0 ? 'AND d.hr >= $minHrFloor ' : '';
    final rows = await db.rawQuery(
      'SELECT s.id AS id, COUNT(d.rec_ts) AS n, AVG(d.hr) AS avg_hr, '
      '       MIN(CASE WHEN 1=1 $floorClause THEN d.hr END) AS min_hr, '
      '       MAX(CASE WHEN 1=1 $ceilClause THEN d.hr END) AS max_hr '
      'FROM sessions s '
      'JOIN decoded_onehz d ON d.rec_ts >= s.start_ts '
      '  AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) AND d.hr > 0 '
      // Admitted rows only. An unverified adapter writes its own seconds into
      // this table with `source` set; averaging the two together would report a
      // session HR that is neither sensor's.
      '  AND ${derivableSourceSql('d.source')} '
      'WHERE s.start_ts >= ? AND s.start_ts <= ? '
      'GROUP BY s.id',
      [fromTs, toTs],
    );
    return {
      for (final r in rows)
        if (r['id'] != null)
          r['id'] as String: {
            'n': (r['n'] as num?) ?? 0,
            'avg_hr': (r['avg_hr'] as num?) ?? 0,
            'min_hr': (r['min_hr'] as num?) ?? 0,
            'max_hr': (r['max_hr'] as num?) ?? 0,
          },
    };
  }

Future<Map<String, List<int>>> _ldbSessionHrSamplesBySession(
    int fromTs,
    int toTs,
  ) async {
    if (LocalDb.sessionSensorSources.isNotEmpty) {
      return {
        for (final MapEntry(key: id, value: rs)
            in (await LocalDb._sessionWindows(fromTs, toTs)).entries)
          id: [for (final r in rs) (r['hr'] as num).toInt()],
      };
    }
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      'SELECT s.id AS id, d.hr AS hr '
      'FROM sessions s '
      'JOIN decoded_onehz d ON d.rec_ts >= s.start_ts '
      '  AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) AND d.hr > 0 '
      // Admitted rows only. An unverified adapter writes its own seconds into
      // this table with `source` set; averaging the two together would report a
      // session HR that is neither sensor's.
      '  AND ${derivableSourceSql('d.source')} '
      'WHERE s.start_ts >= ? AND s.start_ts <= ? '
      'ORDER BY s.id, d.rec_ts ASC',
      [fromTs, toTs],
    );
    final out = <String, List<int>>{};
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id == null) continue;
      (out[id] ??= <int>[]).add((r['hr'] as num).toInt());
    }
    return out;
  }
