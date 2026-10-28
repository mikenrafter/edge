part of '../db.dart';

Future<bool> _ldbClaimNotifFired(String key, {required int? firedAtMs}) async {
    final now = firedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    final won = await LocalDb._guardedWrite<bool>((db) async {
      return db.transaction<bool>((txn) async {
        await txn.rawInsert(
          'INSERT OR IGNORE INTO notif_fired(key, fired_at) VALUES(?, ?)',
          [key, now],
        );
        // changes() reports rows touched by the statement just executed on this
        // connection; inside the transaction that is unambiguously our INSERT.
        final n = Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()'));
        return n == 1;
      });
    });
    if (won == null) throw StateError('notif_fired: claim undecided');
    return won;
  }

Future<int> _ldbClaimNotifSlot(String category, String dedupeKey, {required int startAt, required int bandSize, required int maxProbes}) async {
    if (bandSize <= 0) throw ArgumentError('bandSize must be > 0');
    // maxProbes beyond bandSize can only re-probe candidates already tried
    // (the modulo wraps), so cap it — this also bounds the DB round-trips a
    // single transaction can make.
    final probes = maxProbes < bandSize ? maxProbes : bandSize;
    final start = startAt % bandSize;
    final slot = await LocalDb._guardedWrite<int>((db) async {
      return db.transaction<int>((txn) async {
        final existing = await txn.query(
          'notif_slots',
          columns: ['slot'],
          where: 'category = ? AND dedupe_key = ?',
          whereArgs: [category, dedupeKey],
          limit: 1,
        );
        if (existing.isNotEmpty) return existing.first['slot'] as int;

        for (var i = 0; i < probes; i++) {
          final candidate = (start + i) % bandSize;
          await txn.rawInsert(
            'INSERT OR IGNORE INTO notif_slots(category, dedupe_key, slot) '
            'VALUES(?, ?, ?)',
            [category, dedupeKey, candidate],
          );
          final n =
              Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()'));
          if (n == 1) return candidate;
        }
        throw StateError('notif_slots: no free slot within $probes probes');
      });
    });
    if (slot == null) throw StateError('notif_slots: claim undecided');
    return slot;
  }

Future<void> _ldbSeedNotifFired(Iterable<String> keys, {required int? firedAtMs}) async {
    if (keys.isEmpty) return;
    final now = firedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    await LocalDb._guardedWrite<void>((db) async {
      final batch = db.batch();
      for (final k in keys) {
        batch.rawInsert(
          'INSERT OR IGNORE INTO notif_fired(key, fired_at) VALUES(?, ?)',
          [k, now],
        );
      }
      await batch.commit(noResult: true);
    }, bestEffort: true);
  }

Future<void> _ldbPruneNotifFired(String cutoffDate, {required int? nowMs}) async {
    final gestureCutoff = (nowMs ?? DateTime.now().millisecondsSinceEpoch) -
        LocalDb.gestureClaimRetention.inMilliseconds;
    await LocalDb._guardedWrite<int>(
      (handle) => handle.transaction((db) async {
        final dated = await db.rawDelete(
          "DELETE FROM notif_fired "
          "WHERE substr(key, 1, 10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "
          "AND substr(key, 1, 10) < ?",
          [cutoffDate],
        );
        final gestures = await db.rawDelete(
          "DELETE FROM notif_fired WHERE key LIKE 'gesture:%' AND fired_at < ?",
          [gestureCutoff],
        );
        return dated + gestures;
      }),
      bestEffort: true,
    );
  }

Future<void> _ldbAppendWakeTrace({required int wakeEpochSec, required int atMs, required String kind, required String dataJson}) async {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      await txn.insert('wake_trace', {
        'wake_epoch': wakeEpochSec,
        'at_ms': atMs,
        'kind': kind,
        'data_json': dataJson,
      });
      await txn.delete('wake_trace',
          where: 'wake_epoch < ? AND kind NOT IN '
              '(${List.filled(LocalDb.wakeJournalKinds.length, '?').join(',')})',
          whereArgs: [wakeEpochSec - 14 * 86400, ...LocalDb.wakeJournalKinds]);
    });
  }

Future<List<Map<String, Object?>>> _ldbWakeTraceRows(int wakeEpochSec, {required int? limit}) async {
    final db = await LocalDb.instance;
    if (limit == null) {
      return db.query('wake_trace',
          where: 'wake_epoch = ?',
          whereArgs: [wakeEpochSec],
          orderBy: 'id ASC');
    }
    final newest = await db.query('wake_trace',
        where: 'wake_epoch = ?',
        whereArgs: [wakeEpochSec],
        orderBy: 'id DESC',
        limit: limit);
    return newest.reversed.toList();
  }

Future<List<(int, int)>> _ldbPrivGestureBands(DatabaseExecutor db, String deviceId) async {
    final rows = await db.rawQuery(
      'SELECT strap_start, strap_end FROM ecg_gesture_session '
      'WHERE device_id = ? AND strap_start IS NOT NULL '
      'AND strap_end IS NOT NULL',
      [deviceId],
    );
    return [
      for (final r in rows)
        (
          (r['strap_start'] as num).toInt() - LocalDb.gestureTagToleranceSec,
          (r['strap_end'] as num).toInt() + LocalDb.gestureTagToleranceSec,
        ),
    ];
  }

Future<int> _ldbRecordEcgGestureSession({required String deviceId, required int? strapStart, required int? strapEnd, required int? finalCount, required String? reason, required int createdAtMs}) async {
    final db = await LocalDb.instance;
    return db.transaction((txn) async {
      await txn.insert('ecg_gesture_session', {
        'device_id': deviceId,
        'created_at': createdAtMs,
        'strap_start': strapStart,
        'strap_end': strapEnd,
        'final_count': finalCount,
        'outcome': finalCount == null ? 'abandoned' : 'counted',
        'reason': reason,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (strapStart == null || strapEnd == null) return 0;
      return txn.rawUpdate(
        'UPDATE ecg_raw_packet SET origin = ? '
        'WHERE device_id = ? AND reading_id IS NULL '
        'AND strap_seconds BETWEEN ? AND ? '
        "AND COALESCE(origin, '') != 'gesture'",
        [
          'gesture',
          deviceId,
          strapStart - LocalDb.gestureTagToleranceSec,
          strapEnd + LocalDb.gestureTagToleranceSec,
        ],
      );
    });
  }

Future<void> _ldbPrivRetagAllGesturePackets(Database db) async {
    final rows = await db.rawQuery(
      'SELECT DISTINCT device_id FROM ecg_gesture_session '
      'WHERE strap_start IS NOT NULL AND strap_end IS NOT NULL',
    );
    for (final r in rows) {
      final dev = r['device_id'] as String;
      for (final (lo, hi) in await LocalDb._gestureBands(db, dev)) {
        await db.rawUpdate(
          'UPDATE ecg_raw_packet SET origin = ? '
          'WHERE device_id = ? AND reading_id IS NULL '
          'AND strap_seconds BETWEEN ? AND ? '
          "AND COALESCE(origin, '') != 'gesture'",
          ['gesture', dev, lo, hi],
        );
      }
    }
  }

Future<void> _ldbPutStepCalibrationDay({required String day, required String deviceFamily, required int wearing, required int? referenceSteps, required int? counterTicks}) async {
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

Future<int> _ldbSetDeviceWearing(int wearing, String id) async {
    final db = await LocalDb.instance;
    return db.rawUpdate(
      'UPDATE device SET wearing = ?, wearing_set_ts = '
      'CASE WHEN wearing = ? THEN wearing_set_ts ELSE ? END '
      'WHERE id = ?',
      [
        wearing,
        wearing,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        id,
      ],
    );
  }

Future<StepCalibrationProfile?> _ldbStepCalibrationProfile(String deviceFamily, int wearing) async {
    InputReads.note('step_calibration', '');
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

Future<void> _ldbInsertEcgReading(Map<String, Object?> reading, List<Map<String, Object?>> packets) async {
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

Future<String?> _ldbSaveEcgResult(Map<String, Object?> reading, List<Map<String, Object?>> packets) async {
    final db = await LocalDb.instance;
    return db.transaction((txn) async {
      final incoming = EcgReading.fromRow(reading);
      Map<String, Object?>? target;
      if (incoming != null) {
        final rows = await txn.query(
          'ecg_reading',
          where: 'superseded_by IS NULL',
          orderBy: 'end_ts DESC, created_at DESC',
          limit: 1,
        );
        final latest = rows.isEmpty ? null : EcgReading.fromRow(rows.first);
        if (ecgJoinTargetId(latest: latest, incoming: incoming) != null) {
          target = rows.first;
        }
      }
      final id = reading['id'] as String?;
      final String? group;
      final int attempt;
      if (target != null) {
        // A legacy target has no group: it becomes attempt 1 of its own.
        group = (target['attempt_group'] as String?) ?? target['id'] as String;
        attempt = ((target['attempt'] as num?)?.toInt() ?? 1) + 1;
      } else {
        group = id;
        attempt = 1;
      }
      await txn.insert(
        'ecg_reading',
        {
          ...reading,
          'attempt_group': group,
          'attempt': attempt,
          'superseded_by': null,
        },
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
      if (target == null) return null;
      await txn.update(
        'ecg_reading',
        {
          'superseded_by': id,
          'attempt_group': group,
          'attempt': (target['attempt'] as num?)?.toInt() ?? 1,
        },
        where: 'id = ?',
        whereArgs: [target['id']],
      );
      return target['id'] as String;
    });
  }

Future<List<Map<String, Object?>>> _ldbEcgReadingsForExport({required int limit, required int? afterStartTs, required String? afterId}) async {
    final db = await LocalDb.instance;
    return db.query(
      'ecg_reading',
      where: afterStartTs == null
          ? null
          : afterId == null
          ? 'start_ts > ?'
          : '(start_ts > ? OR (start_ts = ? AND id > ?))',
      whereArgs: afterStartTs == null
          ? null
          : afterId == null
          ? [afterStartTs]
          : [afterStartTs, afterStartTs, afterId],
      orderBy: 'start_ts ASC, id ASC',
      limit: limit,
    );
  }

Future<void> _ldbDeleteEcgReading(String id) async {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      final me = await txn.query(
        'ecg_reading',
        columns: ['attempt_group'],
        where: 'id = ?',
        whereArgs: [id],
      );
      final group = me.isEmpty ? null : me.first['attempt_group'] as String?;
      final rows = group == null
          ? const <Map<String, Object?>>[]
          : await txn.query(
              'ecg_reading',
              columns: ['id'],
              where: 'attempt_group = ?',
              whereArgs: [group],
            );
      final ids = <String>{id, for (final r in rows) r['id']! as String};
      for (final one in ids) {
        await txn.delete(
          'ecg_reading_packet',
          where: 'reading_id = ?',
          whereArgs: [one],
        );
        await txn.update(
          'ecg_raw_packet',
          {'reading_id': null},
          where: 'reading_id = ?',
          whereArgs: [one],
        );
        await txn.delete('ecg_reading', where: 'id = ?', whereArgs: [one]);
      }
    });
  }

Future<void> _ldbSetAlarmScheduleDay({required int weekday, required int hour, required int minute, required bool enabled, required int smartWindowMinutes, required int naturalWindowMinutes, required int gradualWindowMinutes, required String gradualPattern, required int gradualCadenceSec}) async {
    final db = await LocalDb.instance;
    await db.insert(
      'alarm_schedule',
      {
        'weekday': weekday,
        'hour': hour,
        'minute': minute,
        'enabled': enabled ? 1 : 0,
        'smart_window_minutes': smartWindowMinutes,
        'natural_window_minutes': naturalWindowMinutes,
        'gradual_window_minutes': gradualWindowMinutes,
        'gradual_pattern': gradualPattern,
        'gradual_cadence_sec': gradualCadenceSec,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

Future<void> _ldbPutVendorSleepEpochs(List<VendorEpoch> epochs, {required String deviceId, required String source, required bool wholeNights}) async {
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

Future<List<VendorNight>> _ldbVendorSleepNights(int fromSec, int toSec) async {
    InputReads.note('vendor_sleep_epoch', '');
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

Future<void> _ldbPutSleepOverride({required String dayId, required int onsetTs, required int offsetTs, required String source}) async {
    final db = await LocalDb.instance;
    // One transaction: a user window edit reopens the night, so the confirmation
    // goes with it (otherwise a crash between the two leaves an edit the next
    // pass would still truncate).
    await db.transaction((txn) async {
      await txn.insert('sleep_override', {
        'day_id': dayId,
        'onset_ts': onsetTs,
        'offset_ts': offsetTs,
        'source': source,
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('wake_confirmation',
          where: 'day_id = ?', whereArgs: [dayId]);
    });
    await LocalDb.releaseFrozenHeadline(dayId);
  }

Future<List<MomentLabel>> _ldbMomentLabels({required String? date, required String? sinceDate}) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'moment_label',
      where: date != null
          ? 'date = ?'
          : sinceDate != null
              ? 'date >= ?'
              : null,
      whereArgs: date != null
          ? [date]
          : sinceDate != null
              ? [sinceDate]
              : null,
      orderBy: 'date ASC, hhmm ASC',
    );
    return [
      for (final r in rows)
        MomentLabel(
          date: r['date'] as String,
          hhmm: r['hhmm'] as String,
          label: r['label'] as String?,
          note: r['note'] as String?,
          caffeineMg: (r['caffeine_mg'] as num?)?.toDouble(),
          answeredAtMs: (r['answered_at'] as num).toInt(),
        ),
    ];
  }

Future<bool> _ldbAnswerMoment(MomentLabel l, {required String? metricField, required double? metricValue, required double? metricMax, Transaction? transaction}) async {
    // One transaction: the label check, the read of the day's total and the
    // write back are serialized by sqflite, so two overlapping answers on one
    // day cannot read the same total and lose one.
    Future<bool> write(Transaction txn) async {
      final have = await txn.query('moment_label',
          columns: ['date'],
          where: 'date = ? AND hhmm = ?',
          whereArgs: [l.date, l.hhmm],
          limit: 1);
      if (have.isNotEmpty) return false;
      await txn.insert('moment_label', {
        ...LocalDb._momentLabelRow(l),
        if (l.label == 'caffeine' && metricField == 'caffeine_mg')
          'caffeine_mg': metricValue,
      });
      if (metricField != null && metricValue != null) {
        final atMin = int.parse(l.hhmm.substring(0, 2)) * 60 +
            int.parse(l.hhmm.substring(3, 5));
        final old = await txn.query('journal_metric',
            where: 'date = ? AND field = ?',
            whereArgs: [l.date, metricField],
            limit: 1);
        final oldVal = old.isEmpty ? 0.0 : (old.first['value'] as num).toDouble();
        final oldAt = old.isEmpty ? null : (old.first['at_min'] as num?)?.toInt();
        await txn.insert(
            'journal_metric',
            {
              'date': l.date,
              'field': metricField,
              'value': metricMax == null
                  ? oldVal + metricValue
                  : (oldVal + metricValue).clamp(0.0, metricMax).toDouble(),
              'at_min': oldAt != null && oldAt > atMin ? oldAt : atMin,
              'updated_at': l.answeredAtMs,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      return true;
    }
    return transaction == null
        ? (await LocalDb.instance).transaction(write) : write(transaction);
  }

Future<void> _ldbPutWakeEvidence({required int onsetSec, required String kind, required int atSec}) async {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      await txn.insert(
        'wake_evidence',
        {
          'onset_sec': onsetSec,
          'kind': kind,
          'at_sec': atSec,
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await txn.delete('wake_evidence',
          where: 'onset_sec < ?',
          whereArgs: [onsetSec - LocalDb._wakeEvidenceKeepDays * 86400]);
    });
  }

Future<void> _ldbPutWakeConfirmation({required String dayId, required int atSec, required String basis}) async {
    final db = await LocalDb.instance;
    await db.insert(
      'wake_confirmation',
      {
        'day_id': dayId,
        'at_sec': atSec,
        'basis': basis,
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

Future<void> _ldbUpsertDevice({required String id, required String? adapterId, required String? remoteId, required String? label, required String? tier, required bool clearAdapterId}) async {
    final db = await LocalDb.instance;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.insert('device', {
      'id': id,
      'adapter_id': adapterId,
      'remote_id': remoteId,
      'label': label,
      'tier': tier,
      'first_seen': now,
      'last_seen': now,
      // NAMED, not left to the column DEFAULT. `id == ''` IS the primary band
      // permanently, and the v51 rung stamps that row `'primary'` on every
      // UPGRADED database — so taking the `'paired'` default here would give a
      // FRESH install a different role for the same row than an upgraded one,
      // and the first reader of this column would be wrong on exactly the
      // installs that never migrated. Insert-only (the conflict algorithm is
      // IGNORE), so it can never demote a row that already exists.
      'role': id == LocalDb.kPrimaryDeviceId ? 'primary' : 'paired',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    // ONE flag decides both the placeholder and its argument. It is a local
    // and not the expression twice because the two must never disagree: a
    // statement whose `?` count differs from the argument list binds every
    // value one column to the left, which SQLite accepts silently.
    final blankAdapter = adapterId == null && clearAdapterId;
    await db.rawUpdate(
      'UPDATE device SET '
      '${blankAdapter ? 'adapter_id = NULL, ' : 'adapter_id = COALESCE(?, adapter_id), '}'
      'remote_id = COALESCE(?, remote_id), label = COALESCE(?, label), '
      'tier = COALESCE(?, tier), last_seen = ? WHERE id = ?',
      [
        if (!blankAdapter) adapterId,
        remoteId,
        label,
        tier,
        now,
        id,
      ],
    );
  }

Future<int> _ldbPutObservations(List<Observation> rows, {required String deviceId, required Map<String, String> cursors}) async {
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

Future<List<Map<String, Object?>>> _ldbObservationsForDay(String date) async {
    final db = await LocalDb.instance;
    return db.query(
      'observation',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'attribution ASC, COALESCE(vendor_key, key) ASC',
    );
  }

Future<Map<int, num>> _ldbDeviceObservationValues(String deviceId, String key, {required int fromMs}) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'observation',
      columns: ['ts_ms', 'value'],
      where: 'device_id = ? AND key = ? AND ts_ms >= ?',
      whereArgs: [deviceId, key, fromMs],
    );
    return {
      for (final r in rows)
        if (r['value'] != null) r['ts_ms'] as int: r['value'] as num,
    };
  }

Future<void> _ldbSupersedeImportedWorkout(String uuid, String sessionId) async {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      // A session that already has its own route keeps it whole: moving only
      // the non-colliding points would splice two routes into one.
      await txn.rawUpdate(
          'UPDATE workout_route SET session_id = ? WHERE session_id = ? '
          'AND NOT EXISTS (SELECT 1 FROM workout_route WHERE session_id = ?)',
          [sessionId, uuid, sessionId]);
      await txn.delete('workout_route',
          where: 'session_id = ?', whereArgs: [uuid]);
      await txn.delete('imported_workout',
          where: 'uuid = ?', whereArgs: [uuid]);
    });
  }

Future<void> _ldbDeleteImportedWorkoutsFrom(Set<String> sources) async {
    if (sources.isEmpty) return;
    final db = await LocalDb.instance;
    final marks = List.filled(sources.length, '?').join(',');
    await db.transaction((txn) async {
      await txn.delete(
        'workout_route',
        where: 'session_id IN (SELECT uuid FROM imported_workout '
            'WHERE source IN ($marks))',
        whereArgs: [...sources],
      );
      await txn.delete(
        'imported_workout',
        where: 'source IN ($marks)',
        whereArgs: [...sources],
      );
    });
  }

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

Future<bool> _ldbLogAssumedWater({required String date, required int atMin, required double ml, required int loggedAtMs}) async {
    final db = await LocalDb.instance;
    final max = kJournalFieldsByKey[LocalDb._waterField]!.max;
    return db.transaction((txn) async {
      final have = await txn.query('assumed_water',
          columns: ['date'],
          where: 'date = ? AND at_min = ?',
          whereArgs: [date, atMin],
          limit: 1);
      if (have.isNotEmpty) return false;
      final old = await txn.query('journal_metric',
          where: 'date = ? AND field = ?',
          whereArgs: [date, LocalDb._waterField],
          limit: 1);
      final oldVal = old.isEmpty ? 0.0 : (old.first['value'] as num).toDouble();
      final oldAt = old.isEmpty ? null : (old.first['at_min'] as num?)?.toInt();
      final newVal = (oldVal + ml).clamp(0.0, max).toDouble();
      final added = newVal - oldVal;
      if (added > 0) {
        await txn.insert(
            'journal_metric',
            {
              'date': date,
              'field': LocalDb._waterField,
              'value': newVal,
              'at_min': oldAt != null && oldAt > atMin ? oldAt : atMin,
              'updated_at': loggedAtMs,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.insert('assumed_water', {
        'date': date,
        'at_min': atMin,
        'ml': added > 0 ? added : 0.0,
        // A glass that added nothing (the day was at its ceiling) has nothing
        // to review: it is recorded as a tombstone so the slot is not retried.
        'state': added > 0
            ? AssumedState.assumed.name
            : AssumedState.removed.name,
        'logged_at': loggedAtMs,
      });
      return true;
    });
  }

Future<List<AssumedGlass>> _ldbAssumedWater({required String? date, required String? sinceDate, required bool includeRemoved}) async {
    final db = await LocalDb.instance;
    final where = <String>[];
    final args = <Object?>[];
    if (date != null) {
      where.add('date = ?');
      args.add(date);
    } else if (sinceDate != null) {
      where.add('date >= ?');
      args.add(sinceDate);
    }
    if (!includeRemoved) {
      where.add('state <> ?');
      args.add(AssumedState.removed.name);
    }
    final rows = await db.query('assumed_water',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'date ASC, at_min ASC');
    return [
      for (final r in rows)
        AssumedGlass(
          date: r['date'] as String,
          atMin: (r['at_min'] as num).toInt(),
          ml: (r['ml'] as num).toDouble(),
          // A state from a newer build reads as assumed (kept in the total,
          // offered for review) rather than crashing the list.
          state: AssumedState.values.firstWhere(
              (s) => s.name == r['state'],
              orElse: () => AssumedState.assumed),
          loggedAtMs: (r['logged_at'] as num).toInt(),
        ),
    ];
  }

Future<bool> _ldbRemoveAssumedWater(AssumedGlass g, {Transaction? transaction, bool onlyUnreviewed = false}) async {
    Future<bool> write(Transaction txn) async {
      final rows = await txn.query('assumed_water',
          where: 'date = ? AND at_min = ?', whereArgs: [g.date, g.atMin], limit: 1);
      if (rows.isEmpty ||
          rows.first['state'] == AssumedState.removed.name ||
          (onlyUnreviewed && rows.first['state'] != AssumedState.assumed.name)) {
        return false;
      }
      final ml = (rows.first['ml'] as num).toDouble();
      final cur = await txn.query('journal_metric',
          where: 'date = ? AND field = ?',
          whereArgs: [g.date, LocalDb._waterField],
          limit: 1);
      if (cur.isNotEmpty) {
        final left = (cur.first['value'] as num).toDouble() - ml;
        if (left <= 0) {
          await txn.delete('journal_metric',
              where: 'date = ? AND field = ?', whereArgs: [g.date, LocalDb._waterField]);
        } else {
          await txn.update('journal_metric', {'value': left},
              where: 'date = ? AND field = ?', whereArgs: [g.date, LocalDb._waterField]);
        }
      }
      await txn.update('assumed_water', {'state': AssumedState.removed.name},
          where: 'date = ? AND at_min = ?', whereArgs: [g.date, g.atMin]);
      return true;
    }
    return transaction == null ? (await LocalDb.instance).transaction(write) : write(transaction);
  }

Map<String, Object?> _ldbPrivSymptomRow(StoredSymptom s) {
    final d = s.description;
    String? text(String? v) {
      final t = v?.trim();
      return t == null || t.isEmpty ? null : t;
    }

    return {
      'date': s.date,
      'hhmm': s.hhmm,
      'severity': d.severity.id,
      'side': d.side?.id,
      'kind': d.kind.id,
      'kind_other': d.kind == SymptomKind.other ? text(d.kindOther) : null,
      'area': d.area.id,
      'area_other': d.area == SymptomArea.other ? text(d.areaOther) : null,
      'note': text(d.note),
      'created_at': s.createdAtMs,
    };
  }

Future<List<StoredSymptom>> _ldbSymptomEntries({required String? date, required String? sinceDate}) async {
    final db = await LocalDb.instance;
    final rows = await db.query('symptom_entry',
        where: date != null
            ? 'date = ?'
            : sinceDate != null
                ? 'date >= ?'
                : null,
        whereArgs: date != null
            ? [date]
            : sinceDate != null
                ? [sinceDate]
                : null,
        orderBy: 'date ASC, hhmm ASC');
    T? byId<T>(List<T> values, String Function(T) id, Object? v) {
      for (final e in values) {
        if (id(e) == v) return e;
      }
      return null;
    }

    final out = <StoredSymptom>[];
    for (final r in rows) {
      final severity =
          byId(SymptomSeverity.values, (e) => e.id, r['severity']);
      final kind = byId(SymptomKind.values, (e) => e.id, r['kind']);
      final area = byId(SymptomArea.values, (e) => e.id, r['area']);
      if (severity == null || kind == null || area == null) continue;
      out.add(StoredSymptom(
        date: r['date'] as String,
        hhmm: r['hhmm'] as String,
        description: SymptomDescription(
          severity: severity,
          side: byId(SymptomSide.values, (e) => e.id, r['side']),
          kind: kind,
          kindOther: r['kind_other'] as String?,
          area: area,
          areaOther: r['area_other'] as String?,
          note: r['note'] as String?,
        ),
        createdAtMs: (r['created_at'] as num).toInt(),
      ));
    }
    return out;
  }

Future<void> _ldbPutJournalMetrics(String date, Map<String, JournalMetricValue> fields) async {
    final db = await LocalDb.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await WaterMomentStore.recordTotalChange(txn, date, fields['water_ml']);
      final previous = {
        for (final r in await txn.query(
          'journal_metric',
          where: "date = ? AND field IN ('caffeine_mg', 'alcohol_units')",
          whereArgs: [date],
        ))
          r['field'] as String: r,
      };
      await txn.delete('journal_metric', where: 'date = ?', whereArgs: [date]);
      // ↳ CLAIM(remainder-time-fresh): only a substance field whose value or
      // time actually changed loses its stored remainder time; saving an
      // unrelated field keeps it [R3-2, R4-2].
      for (final e in const {
        'caffeine_mg': 'caffeine',
        'alcohol_units': 'alcohol',
      }.entries) {
        final old = previous[e.key], next = fields[e.key];
        final unchanged = old == null
            ? next == null
            : next != null &&
                  (old['value'] as num).toDouble() == next.value &&
                  (old['at_min'] as num?)?.toInt() == next.atMinuteOfDay;
        if (!unchanged) await LocalDb._clearRemainderMinute(txn, date, e.value);
      }
      for (final e in fields.entries) {
        await txn.insert('journal_metric', {
          'date': date,
          'field': e.key,
          'value': e.value.value,
          'at_min': e.value.atMinuteOfDay,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

Future<Map<String, Map<String, JournalMetricValue>>> _ldbJournalMetricsByDay({required String? sinceDaysEpoch}) async {
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

Future<NapResolution?> _ldbPutNapEdit({required String dayId, required int startTs, required int endTs, required String source, NapResolution? expected, Transaction? transaction}) async {
    Future<NapResolution?> write(Transaction tx) async {
      String? snapshot;
      if (source != 'rejected') {
        // A nap that reaches sleep extends it to the union (one transaction
        // with the write); a stale preview throws and nothing is written.
        final ext = await ActivityStore.applyNapExtension(tx, startTs, endTs, expected: expected);
        if (ext.handled) {
          await ActivityStore.supersede(tx, ActivityKind.nap, ext.res.startTs, ext.res.endTs);
          await ActivityStore.markDayChanged(tx, dayId);
          return ext.res;
        }
      }
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
      return null;
    }
    final res = transaction == null ? await (await LocalDb.instance).transaction(write) : await write(transaction);
    final main = res?.extended.where((b) => b.kind == 'main_sleep').lastOrNull;
    if (main != null && transaction == null) await LocalDb.releaseFrozenHeadline(main.day);
    return res;
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
        await tx.update('sleep_nap', {
          'source': restoreSource,
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'payload_json': ?restorePayload,
        }, where: 'day_id = ? AND start_ts = ?', whereArgs: [dayId, startTs]);
      } else {
        await tx.delete('sleep_nap', where: 'day_id = ? AND start_ts = ?', whereArgs: [dayId, startTs]);
      }
    });
  }

Future<void> _ldbUpdateBreathingWindows({required int startedAt, required double? preRmssd, required double? postRmssd}) async {
    final db = await LocalDb.instance;
    await db.update(
      'breathing_session',
      {'pre_rmssd': preRmssd, 'post_rmssd': postRmssd},
      where: 'started_at = ?',
      whereArgs: [startedAt],
    );
  }

Future<int> _ldbSetSessionScores(String id, {required double? strain, required double? calories, required int? maxHr, required String zoneMinJson, required int? avgHr, required String? traceJson, required int? traceSamples}) async {
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

Future<({double bpm, String date})?> _ldbObservedHrCeiling() async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      "SELECT date, value FROM metric_series "
      "WHERE key = 'hr_ceiling_bpm' AND value IS NOT NULL "
      'ORDER BY value DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    final d = rows.first['date'], v = rows.first['value'];
    if (d is! String || v is! num) return null;
    return (bpm: v.toDouble(), date: d);
  }

Future<bool> _ldbPrivFlagOffOnly(Map<String, dynamic> r) async {
    final s = (r['start_ts'] as num?)?.toInt();
    final e = (r['end_ts'] as num?)?.toInt();
    if (s == null || e == null || r['status'] != 'done') return false;
    // Scored by a workout sensor whose flag is now off: its score is that
    // sensor's whatever else the window holds (a band's partial minutes, the
    // wearable's) and once its raw is pruned.
    // ponytail: a stamped window the band also measured serves empty too,
    // not band-only; rescore it from the band's rows if that matters.
    if ((await LocalDb.sessionSensorsOf(r['id']))
        .any((s) => !LocalDb.sessionSensorSources.contains(s))) {
      return true;
    }
    final on = {...LocalDb.sessionSensorSources, ?LocalDb.sessionWearableSource};
    final sources = [
      for (final x in await (await LocalDb.instance).rawQuery(
          'SELECT DISTINCT source FROM decoded_onehz '
          'WHERE rec_ts >= ? AND rec_ts <= ? AND hr > 0',
          [s, e]))
        x['source'],
    ];
    return sources.isNotEmpty &&
        sources.every((x) =>
            x != null && !kDerivableSources.contains(x) && !on.contains(x));
  }

Future<void> _ldbRefreshSessionScoreMask() async {
    final db = await LocalDb.instance;
    final ids = [
      for (final r in await db.query('sessions',
          columns: ['id', 'start_ts', 'end_ts', 'status'],
          where: "status = 'done'"))
        if (await LocalDb._flagOffOnly(r)) r['id'],
    ];
    await db.transaction((txn) async {
      await txn.delete('session_score_mask');
      for (final id in ids) {
        await txn.insert('session_score_mask', {'session_id': id});
      }
    });
  }

Future<void> _ldbPutWorkoutSplits(String sessionId, List<Map<String, Object?>> rows) async {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      await txn.delete(
        'workout_split',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      for (final r in rows) {
        await txn.insert('workout_split', {
          'session_id': sessionId,
          ...r,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

