part of '../db.dart';

Future<ResolvedDaySteps> _ldbResolvedStepsForDay(String day) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'live_coverage',
      columns: ['start_ts', 'end_ts', 'steps', 'source', 'device_id'],
      where: 'day = ?',
      whereArgs: [day],
    );
    return resolveDaySteps([
      for (final r in rows)
        CoverageSpan(
          startTs: (r['start_ts'] as num).toInt(),
          endTs: (r['end_ts'] as num).toInt(),
          steps: (r['steps'] as num).toInt(),
          // Anything not explicitly 'phone' is band — pre-v27 rows default to
          // it, and relabelling them would suppress a real band count.
          fromBand: r['source'] != LocalDb.kStepSourcePhone,
          // WHICH sensor, so two equal-ranked spans from two different straps
          // compete instead of both being credited in full (see
          // [_ensureLiveCoverageDeviceId]). Pre-v49 rows take the column
          // default — the primary band — so a single-device install resolves
          // exactly as it did before the column existed.
          deviceId: (r['device_id'] as String?) ?? LocalDb.kPrimaryDeviceId,
        ),
    ]);
  }

Future<List<Sample>> _ldbSamplesInRange(int fromTs, int toTs) async {
    final db = await LocalDb.instance;
    final decodedRows = await db.query(
      'decoded_onehz',
      columns: LocalDb._decodedSampleColumns,
      where: 'rec_ts >= ? AND rec_ts <= ? AND $kPrimaryBandSourceSql',
      whereArgs: [fromTs, toTs],
      orderBy: 'rec_ts ASC, counter ASC',
    );
    if (decodedRows.isNotEmpty) {
      return decodedRows.map(Sample.fromDecodedRow).toList();
    }
    final rows = await db.query(
      'samples',
      where: 'ts >= ? AND ts <= ?',
      whereArgs: [fromTs, toTs],
      orderBy: 'ts ASC',
    );
    return rows.map(Sample.fromDbMap).toList();
  }

Future<Map<String, int>> _ldbDecodedRecTsMaxByDay() async {
    final (lo, hi) = await LocalDb.firstAndLastRecordTs();
    if (lo == null || hi == null) return {};
    final db = await LocalDb.instance;
    final out = <String, int>{};
    var day = dayLabelOf(
      DateTime.fromMillisecondsSinceEpoch(lo * 1000, isUtc: true).toLocal(),
    );
    // Bounded by the number of days actually present. `localDayEndSec` returns
    // null only for a malformed label, which `dayLabelOf` cannot produce — the
    // guard is there so a future change can never spin here.
    for (var guard = 0; guard < 4000; guard++) {
      final end = localDayEndSec(day);
      if (end == null) break;
      final rows = await db.rawQuery(
        'SELECT MAX(rec_ts) AS mx FROM decoded_onehz '
        'WHERE rec_ts > 0 AND ${derivableSourceSql()} '
        'AND rec_ts >= ? AND rec_ts < ?',
        [localDayStartSec(day) ?? 0, end],
      );
      final mx = rows.isEmpty ? null : (rows.first['mx'] as num?)?.toInt();
      if (mx != null) out[day] = mx;
      if (end > hi) break;
      day = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch(end * 1000, isUtc: true).toLocal(),
      );
    }
    return out;
  }

Future<List<Map<String, dynamic>>> _ldbDecodedOneHzBatchByRecTsRange({
    required int limit,
    required int fromRecTs,
    required int toRecTs,
    int? afterRecTs,
    int? afterCounter,
  }) async {
    final db = await LocalDb.instance;
    if (afterRecTs == null || afterCounter == null) {
      return db.rawQuery(
        'SELECT counter, rec_ts, hr, ax, ay, az, '
        'spo2_red_raw, spo2_ir_raw, skin_temp_raw, '
        'step_count, step_cadence, activity_class, skin_temp_c, '
        'on_wrist, hr_valid, hr_alt, device_family, device_id, band_sleep_state '
        'FROM decoded_onehz '
        'WHERE rec_ts >= ? AND rec_ts <= ? AND ${derivableSourceSql()} '
        'ORDER BY rec_ts ASC, counter ASC LIMIT ?',
        [fromRecTs, toRecTs, limit],
      );
    }
    return db.rawQuery(
      'SELECT counter, rec_ts, hr, ax, ay, az, '
      'spo2_red_raw, spo2_ir_raw, skin_temp_raw, '
      'step_count, step_cadence, activity_class, skin_temp_c, '
      'on_wrist, hr_valid, hr_alt, device_family, device_id, band_sleep_state '
      'FROM decoded_onehz '
      'WHERE rec_ts >= ? AND rec_ts <= ? AND ${derivableSourceSql()} '
      'AND (rec_ts > ? OR (rec_ts = ? AND counter > ?)) '
      'ORDER BY rec_ts ASC, counter ASC LIMIT ?',
      [fromRecTs, toRecTs, afterRecTs, afterRecTs, afterCounter, limit],
    );
  }

Future<List<Map<String, dynamic>>> _ldbDecodedRrByRecTsRange({
    required int fromRecTs,
    required int toRecTs,
  }) async {
    final db = await LocalDb.instance;
    final lo = fromRecTs <= toRecTs ? fromRecTs : toRecTs;
    final hi = fromRecTs <= toRecTs ? toRecTs : fromRecTs;
    return db.rawQuery(
      // `beat_ts_ms` is the MEASURED beat instant (`beatTimesMs`); `rr_ts_ms` is
      // `rec_ts * 1000`, a whole-second staircase that says every beat inside
      // one record happened at the same millisecond. Both are returned because
      // `beat_ts_ms` is NULL on every row banked before the column existed and
      // on every source that carries no sub-second — the reader coalesces.
      'SELECT rec_ts, beat_index, rr_ts_ms, rr_ms, beat_ts_ms, device_id '
      'FROM decoded_rr '
      'WHERE rec_ts >= ? AND rec_ts <= ? AND ${derivableSourceSql()} '
      'ORDER BY rec_ts ASC, beat_index ASC',
      [lo, hi],
    );
  }

Future<List<CoverageInterval>> _ldbCoverageIntervals(
    InputSignal signal,
    int from,
    int to,
  ) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'device_coverage',
      where: 'signal = ? AND end_ts > ? AND start_ts < ?',
      whereArgs: [signal.name, from, to], // rides idx_coverage_window
    );
    return [
      for (final r in rows)
        (
          deviceId: r['device_id'] as String,
          start: (r['start_ts'] as num).toInt(),
          end: (r['end_ts'] as num).toInt(),
        ),
    ];
  }

Future<Map<String, List<String>>> _ldbCoverageDevicesByDay({
    required List<String> signals,
    required int fromSec,
    required int toSec,
    DatabaseExecutor? executor,
  }) async {
    if (signals.isEmpty || toSec <= fromSec) return const {};
    final db = executor ?? await LocalDb.instance;
    final marks = List.filled(signals.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT DISTINCT device_id, start_ts, end_ts FROM device_coverage '
      'WHERE signal IN ($marks) AND end_ts > ? AND start_ts < ?',
      [...signals, fromSec, toSec],
    );
    // Interval -> LOCAL day labels. A night's span crosses midnight, so one
    // row lands on two days; `dayLabelOf` is the only helper that gets the 23 h
    // and 25 h days right, and walking with `DateTime(y, m, d + 1)` walks the
    // calendar rather than adding 86400 s.
    final out = <String, Set<String>>{};
    for (final r in rows) {
      final id = r['device_id'] as String? ?? LocalDb.kPrimaryDeviceId;
      final a = ((r['start_ts'] as num).toInt()).clamp(fromSec, toSec);
      // `end_ts` is EXCLUSIVE (see the table's doc), so the last second this
      // row actually covers is one before it. Converted BEFORE the clamp: an
      // interval ending exactly at local midnight otherwise walks into the
      // next day and hands it a contributor it had no coverage in.
      final b = ((r['end_ts'] as num).toInt() - 1).clamp(fromSec, toSec);
      var d = DateTime.fromMillisecondsSinceEpoch(a * 1000);
      final last = DateTime.fromMillisecondsSinceEpoch(b * 1000);
      // Bounded by the clamp above: at most one iteration per day in the
      // window, whatever the row claims.
      while (!d.isAfter(last)) {
        (out[dayLabelOf(d)] ??= <String>{}).add(id);
        d = DateTime(d.year, d.month, d.day + 1);
      }
    }
    return {for (final e in out.entries) e.key: e.value.toList()..sort()};
  }

Future<void> _ldbPutDayResult({
    required String dayId,
    required int algoVersion,
    required String payloadJson,
    required String windowJson,
    bool finalized = false,
    bool skipped = false,
    // A day whose offloaded second-half compute (naps/workouts/HRR/wear/
    // curves/wake-features) failed or timed out AFTER the headline scalars
    // already succeeded — the row is real (not a skip marker) so headline
    // scalars still display, but it must never count as "derived" for the
    // raw-pruning guard (see dayResultIds). Callers should also avoid passing
    // `finalized: true` alongside `partial: true` unless there genuinely is
    // no raw substrate to ever retry from (e.g. the force-finalized import
    // path), since a finalized row is never revisited on a version bump.
    bool partial = false,
    double? rhr,
    double? rmssd,
    double? readiness,
    Map<String, double?> series = const {},
    // WHO produced these scalars — 'band' for a day this app derived from 1 Hz
    // records, a vendor tag for an importer. NULL is the default and means
    // UNKNOWN; it is never filled in with a guess, because the whole point of
    // the column is that a guessed provenance is worse than none. See
    // [_createMetricSeriesVersion].
    String? source,
    // Per series key: the method, method family and class behind the stored
    // value (`metric_method`). Null writes nothing.
    ({String method, String family, String cls}) Function(String key)?
        seriesMethod,
    // WHICH BAND'S UNITS these scalars are in — the substrate's own
    // `device_family` stamp, which is already null when the window spans two
    // straps or carries no stamp at all. Same rule as [source]: never guessed.
    // See [_createMetricSeriesVersion] and [foreignFamilyDates].
    String? deviceFamily,
    // M5: the day's contributor set (`daySub.deviceIds`, comma-joined,
    // sorted for determinism) — '' alone for every single-device install
    // today. Null, never guessed, same discipline as [deviceFamily].
    String? coverageDevices,
    // M5: the priority order in force when this day derived — the STRING a
    // change-point search can refuse across (`coverage_resolver.dart
    // .priorityKey`), not a hash. Column is named `priority_hash` (already
    // migrated in by M3); this stores the readable string under that name
    // rather than renaming a shipped column.
    String? priorityHash,
  }) async {
    final db = await LocalDb.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    // THE write seam for the compact curve format. All four callers
    // (DerivationEngine x2, cloud_import, whoop_import) funnel through here, so
    // no producer needs to know the wire format exists — upstream code keeps
    // merging and patching plain [{t,v}] lists in memory. Lossless or no-op:
    // SeriesCodec leaves anything it cannot encode exactly as it found it.
    await db.transaction((txn) async {
      var reviewedPayload = payloadJson;
      var reviewedSeries = series;
      if (source == 'band') {
        final previous = await txn.query('day_result', where: 'day_id = ? AND algo_version <= ?',
          whereArgs: [dayId, kAlgoVersion], orderBy: 'algo_version DESC', limit: 1);
        if (previous.isNotEmpty) {
          await ActivityStore.preserveLegacyNaps(txn, dayId,
            Map<String, dynamic>.from(jsonDecode(previous.single['payload_json'] as String) as Map));
        }
        final bundle = Map<String, dynamic>.from(jsonDecode(payloadJson) as Map);
        composeAcceptedNaps(bundle, await ActivityStore.napEdits(txn, dayId));
        reviewedPayload = jsonEncode(bundle);
        reviewedSeries = {...series, 'nap_min': ((bundle['scalars'] as Map?)?['nap_min'] as num?)?.toDouble()};
      }
      final encodedPayload = SeriesCodec.encodePayloadJson(reviewedPayload);
      await txn.insert('day_result', {
        'day_id': dayId,
        'algo_version': algoVersion,
        'payload_json': encodedPayload,
        'window_json': windowJson,
        'computed_at': now,
        'finalized': finalized ? 1 : 0,
        'skipped': skipped ? 1 : 0,
        'partial': partial ? 1 : 0,
        'rhr': rhr,
        'rmssd': rmssd,
        'readiness': readiness,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // A `partial` row already doesn't count as "derived" for the raw-pruning
      // guard (see above) — extend the same caution to the rolling baselines:
      // don't let a day whose second-half compute failed/timed out overwrite
      // (or seed, for a brand-new day) the value tomorrow's readiness/illness
      // baseline reads via metric_series. The next successful (non-partial)
      // pass writes the real value once it lands.
      if (!partial) {
        for (final e in reviewedSeries.entries) {
          await txn.insert('metric_series', {
            'date': dayId,
            'key': e.key,
            'value': e.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        // Whose maths wrote those scalars (see _createMetricSeriesVersion).
        // REPLACE, not IGNORE: the last pass to write the series is the one
        // that owns the stamp, including a ROLLED-BACK build writing a lower
        // version over a higher one — that is the case a MAX() over day_result
        // gets wrong, and the reason this is a stamp and not a query.
        //
        // Inside the same transaction as the values, so the stamp and what it
        // describes can never disagree. Skipped when the series map is empty:
        // an empty map wrote nothing, so there is nothing to attribute.
        if (seriesMethod != null) {
          for (final key in reviewedSeries.keys) {
            final m = seriesMethod(key);
            await txn.insert('metric_method', {
              'date': dayId,
              'key': key,
              'method': m.method,
              'family': m.family,
              'class': m.cls,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        } else if (reviewedSeries.isNotEmpty) {
          // No method for these values (a window spanning two straps, or an
          // unstamped one): the previous writer's class no longer describes
          // them, and an 'estimated' left behind would hide a real value.
          await txn.delete('metric_method',
              where: 'date = ? AND key IN '
                  '(${List.filled(reviewedSeries.length, '?').join(',')})',
              whereArgs: [dayId, ...reviewedSeries.keys]);
        }
        if (reviewedSeries.isNotEmpty) {
          await txn.insert('metric_series_version', {
            'date': dayId,
            'algo_version': algoVersion,
            // The last pass to write the series owns the stamp — provenance
            // included, so a caller that does not know its own writes NULL
            // here rather than inheriting the previous writer's claim.
            'source': source,
            'device_family': deviceFamily,
            'coverage_devices': coverageDevices,
            'priority_hash': priorityHash,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

Future<List<(int, double, double)>> _ldbSkinTempAmbientMinutes(
    int fromSec,
    int toSec,
  ) async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      'SELECT rec_ts / 60 AS m, AVG(skin_temp_raw) AS t, AVG(ambient_raw) AS a '
      'FROM decoded_onehz WHERE rec_ts >= ? AND rec_ts < ? '
      'AND skin_temp_raw > 0 AND ambient_raw > 0 '
      // The primary band's own rows only: the same sensor the night's
      // skin_temp_z comes from, never a second band or a wearable's mix.
      'AND $kPrimaryBandSourceSql AND device_id = ? GROUP BY m ORDER BY m',
      [fromSec, toSec, LocalDb.kPrimaryDeviceId],
    );
    return [
      for (final r in rows)
        if (r['m'] is num && r['t'] is num && r['a'] is num)
          (
            (r['m'] as num).toInt(),
            (r['t'] as num).toDouble(),
            (r['a'] as num).toDouble(),
          ),
    ];
  }

Future<void> _ldbUpdateFreshnessJson(
    String key,
    Map<String, dynamic> Function(Map<String, dynamic> current) update,
  ) async {
    try {
      final db = await LocalDb.instance;
      await db.transaction((txn) async {
        final rows = await txn.query('compute_freshness',
            where: 'key = ?', whereArgs: [key], limit: 1);
        Map<String, dynamic> m = {};
        if (rows.isNotEmpty && rows.first['payload_json'] is String) {
          final v = jsonDecode(rows.first['payload_json'] as String);
          if (v is Map) m = v.cast<String, dynamic>();
        }
        await txn.insert('compute_freshness', {
          'key': key,
          'payload_json': jsonEncode(update(m)),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }, exclusive: true);
    } catch (_) {}
  }

Future<({num? onsetMs, num? onsetClockSec})?> _ldbStoredNightClock(
      String dayId) async {
    final db = await LocalDb.instance;
    // Nested CASE: json_extract raises on a malformed document and only CASE
    // branches are evaluated lazily.
    final rows = await db.rawQuery(
      'SELECT '
      "CASE WHEN json_valid(payload_json) THEN CASE WHEN "
      "json_type(payload_json, '\$.skipped') = 'true' THEN 1 ELSE 0 END "
      'ELSE 1 END AS bad, '
      "CASE WHEN json_valid(payload_json) THEN "
      "json_extract(payload_json, '\$.sleep.window.value.onset_ms') END "
      'AS onset_ms, '
      "CASE WHEN json_valid(payload_json) THEN "
      "json_extract(payload_json, '\$.scalars.sleep_onset_sec') END "
      'AS onset_clock, skipped '
      'FROM day_result WHERE day_id = ? AND algo_version <= ? '
      'ORDER BY algo_version DESC LIMIT 1',
      [dayId, LocalDb._servedAlgoCeiling],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    if (r['bad'] == 1 || (r['skipped'] as num?)?.toInt() == 1) return null;
    final onset = r['onset_ms'], clock = r['onset_clock'];
    return (
      onsetMs: onset is num ? onset : null,
      onsetClockSec: clock is num ? clock : null,
    );
  }

Future<List<Map<String, dynamic>>> _ldbRecentDayScalars(
    int limit,
    List<String> keys,
  ) async {
    // The names are spliced into the SQL as JSON paths and column aliases.
    final plain = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    for (final k in keys) {
      if (!plain.hasMatch(k)) {
        throw ArgumentError.value(k, 'keys', 'not a plain scalar name');
      }
    }
    final db = await LocalDb.instance;
    // Nested CASE rather than AND: json_type/json_extract RAISE on a malformed
    // document, and SQLite only promises lazy evaluation for CASE branches —
    // one corrupt bundle must null its own day, not fail the whole read.
    final cols = [
      for (final k in keys)
        'CASE WHEN json_valid(r.payload_json) THEN '
            "CASE WHEN json_type(r.payload_json, '\$.scalars.$k') "
            "IN ('integer', 'real') "
            "THEN json_extract(r.payload_json, '\$.scalars.$k') END "
            'END AS "$k"',
    ];
    final rows = await db.rawQuery(
      'SELECT r.day_id${cols.isEmpty ? '' : ', ${cols.join(', ')}'} '
      'FROM day_result r '
      '${LocalDb._servedNewestDaysJoin} '
      'ORDER BY r.day_id DESC',
      [limit],
    );
    return [for (final r in rows) LocalDb._withDate(r)];
  }

Future<String?> _ldbDayInputSignature({
    required String dayId,
    required String prevDayId,
    required String nextDayId,
    required int fromSec,
    required int toSec,
    required String? wearableDeviceId,
  }) async {
    final db = await LocalDb.instance;
    final out = StringBuffer();
    String rows(List<Map<String, Object?>> rs, {Set<String> drop = const {}}) {
      final keys = rs.isEmpty
          ? const <String>[]
          : (rs.first.keys.where((k) => !drop.contains(k)).toList()..sort());
      return jsonEncode([
        for (final r in rs) [for (final k in keys) r[k]],
      ]);
    }

    Future<void> add(String label, String sql,
        [List<Object?> args = const [], Set<String> drop = const {}]) async {
      out
        ..write(label)
        ..write('=')
        ..write(rows(await db.rawQuery(sql, args), drop: drop))
        ..write(';');
    }

    Future<bool> has(String table) async =>
        (await LocalDb._objectType(db, table)) != null;

    final days = [prevDayId, dayId, nextDayId];
    const stamps = {'computed_at', 'updated_at', 'updated_ts'};
    final openSession = await db.rawQuery(
      'SELECT 1 FROM sessions WHERE end_ts IS NULL AND start_ts <= ? LIMIT 1',
      [toSec + 86400],
    );
    if (openSession.isNotEmpty) return null;

    final oneHzCols = {
      for (final c in await db.rawQuery('PRAGMA table_info(decoded_onehz)'))
        c['name'] as String,
    }..removeAll(const {'device_id', 'device_family', 'source'});
    await add(
      'onehz',
      'SELECT COUNT(*), TOTAL(rowid), MAX(rowid), '
          '${[for (final c in oneHzCols.toList()..sort()) 'TOTAL($c)'].join(', ')}, '
          'TOTAL(LENGTH(device_id)), TOTAL(LENGTH(device_family)), '
          'TOTAL(LENGTH(source)) '
          'FROM decoded_onehz WHERE rec_ts BETWEEN ? AND ?',
      [fromSec, toSec],
    );
    await add(
      'rr',
      'SELECT COUNT(*), TOTAL(rowid), MAX(rowid), TOTAL(rr_ms), '
          'TOTAL(rr_ts_ms), TOTAL(LENGTH(device_id)) '
          'FROM decoded_rr WHERE rec_ts BETWEEN ? AND ?',
      [fromSec, toSec],
    );
    // The wear and charge transitions are read back past the window (the
    // state already open at its start), so all of them count.
    await add(
      'band_events',
      'SELECT COUNT(*), TOTAL(rowid), MAX(rowid) FROM band_events '
          'WHERE (ts BETWEEN ? AND ?) OR event_id IN (?, ?, ?, ?)',
      [
        fromSec,
        toSec,
        proto.EventId.chargingOn,
        proto.EventId.chargingOff,
        proto.EventId.wristOn,
        proto.EventId.wristOff,
      ],
    );
    await add('live_coverage',
        'SELECT * FROM live_coverage WHERE day = ? ORDER BY rowid', [dayId]);
    await add(
      'sessions',
      'SELECT * FROM sessions WHERE start_ts BETWEEN ? AND ? ORDER BY id',
      [fromSec - 2 * 86400, toSec + 86400],
    );
    for (final t in const [
      'session_sensor',
      'session_score_mask',
      'signal_priority',
      'step_calibration',
      'activity_review_meta',
      'activity_review_days',
    ]) {
      if (await has(t)) {
        await add(t, 'SELECT * FROM $t ORDER BY rowid', const [], stamps);
      }
    }
    final marks = List.filled(days.length, '?').join(',');
    await add('sleep_override',
        'SELECT * FROM sleep_override WHERE day_id IN ($marks) ORDER BY day_id',
        days, stamps);
    if (await has('sleep_nap')) {
      await add(
        'sleep_nap',
        'SELECT * FROM sleep_nap WHERE day_id IN ($marks) '
            'OR (start_ts < ? AND end_ts > ?) ORDER BY rowid',
        [...days, toSec, fromSec],
        stamps,
      );
    }
    if (await has('activity_suggestions')) {
      await add(
        'activity_suggestions',
        'SELECT * FROM activity_suggestions WHERE day_id IN ($marks) '
            'OR (detection_start < ? AND detection_end > ?) ORDER BY id',
        [...days, toSec + 86400, fromSec - 86400],
        stamps,
      );
    }
    await add(
      'device',
      'SELECT * FROM device ORDER BY id',
      const [],
      {...stamps, 'last_seen', 'battery_pct', 'battery_ts', 'name'},
    );
    await add(
      'cursor',
      "SELECT name, value FROM sync_cursor WHERE name IN (?, ?) "
          "OR name LIKE 'wearable_enabled:%' ORDER BY name",
      ['active_wearable', LocalDb.kDecodedPrunedBeforeCursor],
    );
    await add(
      'device_coverage',
      'SELECT * FROM device_coverage WHERE end_ts > ? AND start_ts < ? '
          'ORDER BY rowid',
      [fromSec, toSec],
    );
    if (await has('vendor_sleep_epoch')) {
      await add(
        'vendor_sleep',
        'SELECT COUNT(*), TOTAL(rowid), MAX(rowid) FROM vendor_sleep_epoch '
            'WHERE night_onset_ts BETWEEN ? AND ?',
        [fromSec - 86400, toSec + 86400],
      );
    }
    if (wearableDeviceId != null) {
      // A wearable's substrate is read without a window (its whole HR
      // history sets its edge) and from the archive (rings bank replies
      // there), so all of that device's rows count.
      await add(
        'wearable_rows',
        'SELECT COUNT(*), TOTAL(rowid), MAX(rowid), TOTAL(hr) '
            'FROM decoded_onehz WHERE device_id = ?',
        [wearableDeviceId],
      );
      // Read off the tables, not the view: the view's hex is built from each
      // frame's bytes, which was text per frame per day for a length. A
      // stored blob's hex is exactly twice its bytes, and the columns keep the
      // view query's names (the signature orders values by them), so the
      // value — and every stored fingerprint — is the same as before.
      final legacyArchive = await has(LocalDb._rawArchiveLegacy);
      await add(
        'wearable_archive',
        'SELECT COUNT(*) AS "COUNT(*)", '
            'MAX(captured_at) AS "MAX(captured_at)", '
            'TOTAL(captured_at) AS "TOTAL(captured_at)", '
            'TOTAL(n) AS "TOTAL(LENGTH(hex))" FROM ('
            'SELECT captured_at, CASE WHEN hex IS NOT NULL THEN LENGTH(hex) '
            'ELSE LENGTH(frame) * 2 END AS n FROM ${LocalDb.rawArchiveTable} '
            'WHERE device_id = ?'
            '${legacyArchive ? ' UNION ALL SELECT captured_at, LENGTH(hex) '
                'FROM ${LocalDb._rawArchiveLegacy} WHERE device_id = ?' : ''})',
        [wearableDeviceId, if (legacyArchive) wearableDeviceId],
      );
    }
    await add(
      'baselines',
      "SELECT key, payload_json FROM baselines "
          "WHERE key IN ('sleep_user_profile', 'movement_floor') ORDER BY key",
    );
    await add(
      'freshness',
      'SELECT key, payload_json FROM compute_freshness WHERE key = ?',
      ['quiet_repass:$dayId'],
    );
    // The day's own rows and its neighbours' — read back by the carry-forward
    // guards, tonight's sleep and activity review. Hashed, not inlined.
    final results = await db.rawQuery(
      'SELECT day_id, algo_version, finalized, partial, skipped, rhr, rmssd, '
      'readiness, window_json, payload_json FROM day_result '
      'WHERE day_id IN ($marks) ORDER BY day_id, algo_version',
      days,
    );
    out.write('day_result=');
    for (final r in results) {
      final payload = r['payload_json'];
      out
        ..write([
          for (final k in const [
            'day_id', 'algo_version', 'finalized', 'partial', 'skipped',
            'rhr', 'rmssd', 'readiness', 'window_json',
          ])
            r[k],
        ].join(','))
        ..write(',')
        ..write(payload is String
            ? sha1.convert(utf8.encode(payload)).toString()
            : 'null')
        ..write('|');
    }
    out.write(';');
    await add(
      'candidates',
      'SELECT day_id, algo_version, payload_json FROM sleep_session_candidates '
          'WHERE day_id = ? ORDER BY algo_version',
      [dayId],
    );
    out
      ..write('windows=')
      ..write(rows(await LocalDb.sleepWindowRows(60)))
      ..write(';');
    return out.toString();
  }

Future<void> _ldbClearDerivedDays(Set<String> dayIds) async {
    final sorted = dayIds.toList()..sort();
    if (sorted.isEmpty) return;
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      for (final (table, column) in const [
        ('day_result', 'day_id'),
        ('metric_series', 'date'),
        ('metric_series_version', 'date'),
        ('metric_method', 'date'),
        ('sleep_session_candidates', 'day_id'),
        ('wake_day_features', 'day_id'),
      ]) {
        for (final chunk in LocalDb._sqlVarChunks(sorted)) {
          await txn.rawDelete(
            'DELETE FROM $table WHERE $column IN '
            '(${List.filled(chunk.length, '?').join(',')})',
            chunk,
          );
        }
      }
    });
  }

Future<int> _ldbDeleteDays(Set<String> dayIds) async {
    final sorted = dayIds.toList()..sort();
    if (sorted.isEmpty) return 0;
    final db = await LocalDb.instance;
    int deleted = 0;
    Future<void> deleteByIn(
      Transaction txn,
      String table,
      String column,
      List<String> values,
    ) async {
      // Chunked: "select all" on a multi-year history binds one day label per
      // parameter, which would blow SQLITE_MAX_VARIABLE_NUMBER.
      for (final chunk in LocalDb._sqlVarChunks(values)) {
        final placeholders = List.filled(chunk.length, '?').join(',');
        deleted += await txn.rawDelete(
          'DELETE FROM $table WHERE $column IN ($placeholders)',
          chunk,
        );
      }
    }

    await db.transaction((txn) async {
      // `raw_archive` frames are kept, but a later archive re-drive must not
      // decode them back into a day the user deleted: record the windows.
      final prevRow = await txn.query('compute_freshness',
          where: 'key = ?', whereArgs: [LocalDb.kRedriveExcludedKey], limit: 1);
      // An unreadable earlier list is replaced, not fatal: the deletion
      // itself must still go through.
      final excluded = LocalDb._mergeWindows([
        ...?(prevRow.isEmpty
            ? null
            : LocalDb._parseWindows(prevRow.first['payload_json'])),
        for (final dayId in sorted) LocalDb._localDayWindow(dayId),
      ]);
      await txn.insert('compute_freshness', {
        'key': LocalDb.kRedriveExcludedKey,
        'payload_json': jsonEncode([
          for (final w in excluded) [w.$1, w.$2],
        ]),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // The archived copy of these seconds goes too — "delete this day" is a
      // privacy action, and the archive holds the same data, compressed.
      deleted += await SubstrateArchive.deleteRanges(txn, [
        for (final dayId in sorted) LocalDb._localDayWindow(dayId),
      ]);
      for (final dayId in sorted) {
        final (startSec, endSec) = LocalDb._localDayWindow(dayId);
        deleted += await txn.delete(
          'decoded_rr',
          where: 'rec_ts >= ? AND rec_ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'decoded_onehz',
          where: 'rec_ts >= ? AND rec_ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'samples',
          where: 'ts >= ? AND ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'events',
          where: 'ts >= ? AND ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'band_events',
          where: 'ts >= ? AND ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'band_battery',
          where: 'ts >= ? AND ts < ?',
          whereArgs: [startSec, endSec],
        );
        // CASCADE the GPS route and the typed sets BEFORE their session row
        // disappears — otherwise the join key is gone and every lat/lng point
        // of a deleted run (and every logged set) stays on disk forever. Must
        // run first: once `sessions` is deleted the subquery is empty and the
        // children are unreachable.
        for (final child in const [
          'workout_route',
          'workout_split',
          'strength_set',
          'session_sensor',
        ]) {
          deleted += await txn.rawDelete(
            'DELETE FROM $child WHERE session_id IN '
            '(SELECT id FROM sessions WHERE start_ts >= ? AND start_ts < ?)',
            [startSec, endSec],
          );
        }
        deleted += await txn.delete(
          'sessions',
          where: 'start_ts >= ? AND start_ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'live_coverage',
          where: 'end_ts > ? AND start_ts < ?',
          whereArgs: [startSec, endSec],
        );
      }
      await deleteByIn(txn, 'day_result', 'day_id', sorted);
      await deleteByIn(txn, 'metric_series', 'date', sorted);
      await deleteByIn(txn, 'metric_series_version', 'date', sorted);
      await deleteByIn(txn, 'metric_method', 'date', sorted);
      await deleteByIn(txn, 'journal', 'date', sorted);
      await deleteByIn(txn, 'journal_metric', 'date', sorted);
      await deleteByIn(txn, 'cycle_log', 'date', sorted);
      await deleteByIn(txn, 'notifications', 'date', sorted);
      await deleteByIn(txn, 'sleep_session_candidates', 'day_id', sorted);
      await deleteByIn(txn, 'wake_day_features', 'day_id', sorted);
      // Day-keyed USER rows. Same class of leak as workout_route: "delete this
      // day" must not leave the user's own logged health data behind.
      await deleteByIn(txn, 'cycle_symptom', 'date', sorted);
      await deleteByIn(txn, 'workout_suggestions', 'date', sorted);
      await deleteByIn(txn, 'sleep_override', 'day_id', sorted);
      await deleteByIn(txn, 'sleep_nap', 'day_id', sorted);
      await deleteByIn(txn, 'activity_suggestions', 'day_id', sorted);
      await deleteByIn(txn, 'activity_review_days', 'day_id', sorted);
      // The frozen readiness headline is a cursor, not a day row, so nothing
      // above reaches it. A pin that outlives its day is that day's readiness
      // still on disk, and it would come back on the chart, in the log and
      // in a push.
      final pinRows = await txn.query(
        'sync_cursor',
        columns: ['value'],
        where: 'name = ?',
        whereArgs: [LocalDb.kFrozenHeadlineCursor],
        limit: 1,
      );
      if (pinRows.isNotEmpty) {
        final pinDay = LocalDb._parseFrozenHeadline(pinRows.first['value'])?.day;
        if (pinDay != null && dayIds.contains(pinDay)) {
          deleted += await txn.delete(
            'sync_cursor',
            where: 'name = ?',
            whereArgs: [LocalDb.kFrozenHeadlineCursor],
          );
        }
      }
    });
    return deleted;
  }

Future<void> _ldbUpdateBaseline(
    String key,
    String? Function(String? current) transform,
  ) async {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'baselines',
        columns: ['payload_json'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      final current = rows.isEmpty
          ? null
          : rows.first['payload_json'] as String?;
      final next = transform(current);
      if (next == null) return;
      await txn.insert('baselines', {
        'key': key,
        'payload_json': next,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }, exclusive: true);
  }

Future<int> _ldbReencodeLegacyDayResults({int limit = 40}) async {
    final db = await LocalDb.instance;

    String? cursorDay;
    int? cursorVersion;
    final prev = await LocalDb.computeFreshness(LocalDb.kReencodeCursorKey);
    final prevJson = prev?['payload_json'];
    if (prevJson is String && prevJson.isNotEmpty) {
      try {
        final d = jsonDecode(prevJson);
        if (d is Map) {
          if (d['done'] == true) return 0; // whole history already walked
          final c = d['cursor'];
          if (c is String && c.isNotEmpty) cursorDay = c;
          final v = d['cursor_version'];
          if (v is int) cursorVersion = v;
        }
      } catch (_) {
        /* unreadable bookkeeping ⇒ start over; the walk is idempotent */
      }
    }

    // The cursor is the COMPOSITE key, not just the day. `day_result` is keyed
    // (day_id, algo_version) and one day can hold several generations, so a
    // day-only cursor stepped straight past a day's older rows and left them
    // legacy forever.
    //
    // Spelled out rather than as the row-value form `(day_id, algo_version) <
    // (?, ?)`: row values need SQLite 3.15, and on Android sqflite uses the
    // OS's SQLite, which is older than that on the devices this app still
    // supports.
    final String? where;
    final List<Object?>? whereArgs;
    if (cursorDay == null) {
      where = null;
      whereArgs = null;
    } else if (cursorVersion == null) {
      where = 'day_id < ?';
      whereArgs = [cursorDay];
    } else {
      where = 'day_id < ? OR (day_id = ? AND algo_version < ?)';
      whereArgs = [cursorDay, cursorDay, cursorVersion];
    }

    final rows = await db.query(
      'day_result',
      columns: ['day_id', 'algo_version', 'payload_json'],
      where: where,
      whereArgs: whereArgs,
      orderBy: 'day_id DESC, algo_version DESC',
      limit: limit,
    );
    if (rows.isEmpty) {
      await LocalDb.putComputeFreshness(LocalDb.kReencodeCursorKey, jsonEncode({'done': true}));
      return 0;
    }

    // PREPARE ON A WORKER ISOLATE, outside the transaction.
    //
    // Outside the transaction because each eligible bundle costs several JSON
    // parse/serialize passes (needsReencode, then verifyLossless, which encodes
    // and decodes to prove the round trip, then the real encode), and doing
    // that inside db.transaction held the write lock open across ~40 x ~88 KB
    // of pure CPU while the rest of the app waited to write.
    //
    // Off THIS isolate because that CPU is otherwise synchronous on whichever
    // isolate called the derive, and the derive is called from the UI one:
    // measured at 0.1-0.4 s per batch on a desktop, which is several times that
    // on a mid-tier phone, with no await in the loop for the frame scheduler to
    // get a word in. This app has shipped a derive-correlated main-isolate
    // freeze before. `SeriesCodec` is pure — no I/O, no plugins, no Flutter —
    // so it is safe anywhere, and the batch is bounded by `limit`.
    final payloads = [
      for (final row in rows)
        (row['payload_json'] is String) ? row['payload_json'] as String : '',
    ];
    final prepared = await Isolate.run(() => _reencodeBatch(payloads));
    // The window the compare-and-set below exists to close: the rows were read,
    // the encode took real time, and nothing has been locked yet. A test drives
    // a competing write through here rather than racing a sleep against it —
    // the interleave is the whole property, so it has to be placed rather than
    // hoped for.
    final afterPrepare = LocalDb.debugAfterReencodePrepare;
    if (afterPrepare != null) await afterPrepare();

    final updates =
        <
          ({
            int rowIndex,
            String dayId,
            int algoVersion,
            String from,
            String to,
          })
        >[];
    for (var i = 0; i < rows.length; i++) {
      final encoded = prepared[i];
      if (encoded == null) continue;
      updates.add((
        rowIndex: i,
        dayId: rows[i]['day_id'] as String,
        algoVersion: (rows[i]['algo_version'] as num).toInt(),
        from: payloads[i],
        to: encoded,
      ));
    }

    var rewritten = 0;
    // Index of the OLDEST-ranked row (first in this newest-first batch) whose
    // compare-and-set found something other than what we read.
    int? missedIndex;
    if (updates.isNotEmpty) {
      await db.transaction((txn) async {
        for (final u in updates) {
          // COMPARE-AND-SET on the payload we actually read.
          //
          // The prepare above deliberately runs outside any transaction and
          // takes hundreds of milliseconds, and derivation runs in more than
          // one isolate (see updateBaseline's exclusive transaction for the
          // same hazard). A blind `WHERE day_id = ? AND algo_version = ?` will
          // happily write a stale bundle over a row that a concurrent derive
          // rewrote in the meantime — and because this walk starts at the
          // NEWEST day with kAlgoVersion unbumped, its first targets are
          // exactly the rows a light derive is rewriting. The row would end up
          // holding the new scalar columns beside the old payload.
          //
          // A row that has moved is left alone. It is not lost: the cursor is
          // held back below so a later pass looks at it again.
          final n = await txn.update(
            'day_result',
            {'payload_json': u.to},
            where: 'day_id = ? AND algo_version = ? AND payload_json = ?',
            whereArgs: [u.dayId, u.algoVersion, u.from],
          );
          if (n > 0) {
            rewritten++;
          } else {
            missedIndex ??= u.rowIndex;
          }
        }
      });
    }

    // The cursor advances past every row we LOOKED at, not just the ones we
    // rewrote — a row we skipped (already encoded, or not provably lossless)
    // would otherwise be re-examined on every future pass and the walk would
    // never terminate.
    //
    // A row that lost the compare-and-set is the one exception: it is parked
    // just BEHIND the cursor so the next pass reads it again, and `done` is
    // withheld so the walk cannot latch shut over it. A missed FIRST row leaves
    // the cursor exactly where it was, which costs one repeated batch and
    // converges — the second look either re-encodes the row or finds it already
    // encoded and steps past.
    final Map<String, Object?> mark;
    final missed = missedIndex;
    if (missed == null) {
      mark = {
        'cursor': rows.last['day_id'],
        'cursor_version': rows.last['algo_version'],
        'done': rows.length < limit,
      };
    } else if (missed > 0) {
      mark = {
        'cursor': rows[missed - 1]['day_id'],
        'cursor_version': rows[missed - 1]['algo_version'],
        'done': false,
      };
    } else if (cursorDay == null) {
      mark = const {};
    } else {
      mark = {
        'cursor': cursorDay,
        'cursor_version': cursorVersion,
        'done': false,
      };
    }
    await LocalDb.putComputeFreshness(
      LocalDb.kReencodeCursorKey,
      jsonEncode({...mark, 'rewritten_last': rewritten}),
    );
    return rewritten;
  }

Future<Map<String, dynamic>> _ldbFreshnessRawStats() async {
    final db = await LocalDb.instance;
    final hi = (await db.rawQuery(
      'SELECT MAX(rec_ts) AS hi FROM decoded_onehz WHERE rec_ts > 0',
    )).first['hi'];
    final oneHz =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_onehz'),
        ) ??
        0;
    final rr =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_rr'),
        ) ??
        0;
    return {
      'max_rec_ts': (hi as num?)?.toInt(),
      'decoded_onehz': oneHz,
      'decoded_rr': rr,
    };
  }

Future<void> _ldbRefreshComputeFreshness() async {
    final raw = await LocalDb._freshnessRawStats();
    // Payload-free: this runs at the end of every derive pass, including the
    // light one after each BLE drain, on the UI isolate. The loop usually
    // stops after a row or two, so each bundle is fetched only when visited.
    final recent = await LocalDb.recentDayResultsMeta(30);
    final rolling = await LocalDb.baseline('rolling');
    final cross = await LocalDb.baseline('crossday');
    final today = LocalDb.localDayLabelNow();
    final latestRawTs = (raw['max_rec_ts'] as num?)?.toInt();
    final todayWake = await LocalDb.wakeDayFeatures(today);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // The band's edge: a peripheral streaming this morning says nothing about
    // how far the band's night has drained. Only for legacy rows without a
    // stored `data_edge_sec`.
    final bandEdgeSec = await LocalDb.lastDecodedRecTs() ?? 0;
    String? latestOvernightDay;
    int? latestOvernightComputedAt;
    String? latestRecoveryDay;
    int? latestRecoveryComputedAt;
    Map<String, dynamic>? todayRow;
    int? overnightRecheckAt;
    String? recoveryState;
    for (final row in recent) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      if (dayId == today && todayRow == null) todayRow = row;
      final decoded =
          SeriesCodec.decodePayloadJson(
            await LocalDb._servedPayloadJson(dayId, row['algo_version']),
          ) ??
          const <String, dynamic>{};
      if (decoded['skipped'] == true) continue;
      // #448: today's night is not today's overnight until the drain has
      // passed its wake. Mid-drain the window closes at the newest record, so
      // serving it showed a partial night and its readiness as this morning's.
      // A row with no window is held too: mid-drain the edge can still sit
      // before sleep onset, and that read as a settled 'no sleep' night.
      // A no-sleep window's `value` is the string '—', not a Map.
      final sleepMap = decoded['sleep'];
      final windowMap = sleepMap is Map ? sleepMap['window'] : null;
      final windowVal = windowMap is Map ? windowMap['value'] : null;
      final offsetMs = windowVal is Map ? windowVal['offset_ms'] : null;
      final wakeSec = offsetMs is num ? offsetMs ~/ 1000 : null;
      // A night is judged on the edge its row was derived against
      // (`data_edge_sec`), so wake and edge share one substrate: a later band
      // sync must not settle a row still holding the partial night, and an
      // unworn band's edge says nothing about a wearable's night. Legacy rows
      // without the stamp fall back to the band's edge.
      final edgeSec =
          (decoded['data_edge_sec'] as num?)?.toInt() ?? bandEdgeSec;
      if (dayId == today) {
        recoveryState = recoveryStateOf(
          wakeSec: wakeSec,
          dataEdgeSec: edgeSec,
          nowSec: nowSec,
        )?.wire;
      }
      final flags = decoded['flags'];
      // 'Not sleep' is the user's own verdict on the night, so it needs no
      // settling and is as final an overnight as a detected absence. Without
      // this a rejected today was never the overnight day: Home held the
      // previous night over as "still being worked out" for the rest of it.
      final rejected = flags is List && flags.contains('SLEEP_REJECTED');
      if (dayId == today &&
          !rejected &&
          !overnightSettled(
            sleepOffsetSec: wakeSec,
            dataEdgeSec: edgeSec,
            nowSec: nowSec,
          )) {
        // When the give-up lands; getToday re-checks then, since a quiet
        // strap triggers no derive to do it.
        overnightRecheckAt = (wakeSec ?? edgeSec) + kOvernightGiveUpSec;
        continue;
      }
      final scalars = ((decoded['scalars'] as Map?) ?? const {})
          .cast<String, dynamic>();
      if (latestOvernightDay == null) {
        final sleep =
            ((decoded['sleep'] as Map?)?['accounting'] as Map?)?['value'];
        final hasSleep = sleep is Map && sleep['tst_sec'] != null;
        final noSleep = rejected ||
            (flags is List && flags.contains('NO_SLEEP_DETECTED'));
        if (hasSleep || noSleep) {
          latestOvernightDay = dayId;
          latestOvernightComputedAt = (row['computed_at'] as num?)?.toInt();
        }
      }
      if (latestRecoveryDay == null &&
          ((row['readiness'] as num?) != null || scalars['readiness'] is num)) {
        latestRecoveryDay = dayId;
        latestRecoveryComputedAt = (row['computed_at'] as num?)?.toInt();
      }
      // Rows run newest day first, so once one is older than today, today has
      // no row and cannot turn up further down. Waiting for it walked and
      // decoded all 30 bundles on every pass whenever today was not derived
      // yet (just after midnight, a held day, a drain that only moved last
      // night's tail).
      if (latestOvernightDay != null &&
          latestRecoveryDay != null &&
          (todayRow != null || dayId.compareTo(today) < 0)) {
        break;
      }
    }
    final todayComputedAt = (todayRow?['computed_at'] as num?)?.toInt();
    final wakeComputedAt = (todayWake?['computed_at'] as num?)?.toInt();
    final activityReady = todayRow != null || todayWake != null;
    final overnightReady = latestOvernightDay == today;
    final rawReachedToday =
        latestRawTs != null && LocalDb._localDayLabelFromEpoch(latestRawTs) == today;
    final activityState = activityReady
        ? 'ready'
        : (rawReachedToday ? 'building' : 'missing');
    final overnightState = overnightReady
        ? 'ready'
        : (rawReachedToday ? 'building' : 'missing');
    await LocalDb.putComputeFreshness(
      'capture',
      jsonEncode({
        'latest_raw_rec_ts': latestRawTs,
        'latest_raw_day': latestRawTs == null
            ? null
            : LocalDb._localDayLabelFromEpoch(latestRawTs),
        'decoded_onehz': raw['decoded_onehz'],
        'decoded_rr': raw['decoded_rr'],
      }),
    );
    await LocalDb.putComputeFreshness(
      'today',
      jsonEncode({
        'today_day': today,
        'activity_day': activityReady ? today : null,
        'activity_state': activityState,
        'activity_computed_at': todayComputedAt ?? wakeComputedAt,
        'overnight_day': latestOvernightDay,
        'overnight_state': overnightState,
        'overnight_computed_at': latestOvernightComputedAt,
        'overnight_recheck_at': overnightRecheckAt,
        // Today's own night: night_in_progress / provisional / final, or null
        // when today has no derived row yet. See [recoveryStateOf].
        'recovery_state': recoveryState,
        'recovery_day': latestRecoveryDay,
        'recovery_computed_at': latestRecoveryComputedAt,
        'showing_prior_overnight':
            latestOvernightDay != null && latestOvernightDay != today,
      }),
    );
    await LocalDb.putComputeFreshness(
      'crossday',
      jsonEncode({
        'present': cross != null,
        'updated_at': rolling?['updated_at'],
      }),
    );
  }

Future<void> _ldbEnqueueDeriveJob({
    required String type,
    required String reason,
  }) async {
    final db = await LocalDb.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      // Only a QUEUED job covers a new request. A running pass may have
      // loaded its substrate before the batch behind this request landed, so
      // it queues behind it and drains when the pass finishes.
      final active = await txn.query(
        'compute_jobs',
        columns: ['id', 'type', 'state'],
        where: 'scope = ? AND state = ?',
        whereArgs: ['derive', 'queued'],
      );
      bool hasType(String t) =>
          active.any((row) => row['type']?.toString() == t);
      if (type == 'derive_light') {
        if (hasType('derive_light') || hasType('derive_heavy')) return;
      } else if (type == 'derive_heavy') {
        if (hasType('derive_heavy')) return;
        await txn.delete(
          'compute_jobs',
          where: 'scope = ? AND state = ? AND type = ?',
          whereArgs: ['derive', 'queued', 'derive_light'],
        );
      }
      await txn.insert('compute_jobs', {
        // Microseconds: the running job this one may queue behind can share
        // its millisecond, and a PK collision would throw.
        'id': 'derive_${type}_${DateTime.now().microsecondsSinceEpoch}',
        'type': type,
        'scope': 'derive',
        'priority': type == 'derive_heavy' ? 200 : 100,
        'state': 'queued',
        'reason': reason,
        'depends_on': null,
        'input_from_ts': null,
        'input_to_ts': null,
        'algo_version': null,
        'attempts': 0,
        'next_run_at': null,
        'created_at': now,
        'updated_at': now,
      });
    });
  }

Future<Map<String, dynamic>?> _ldbTakeNextComputeJob() async {
    final db = await LocalDb.instance;
    return db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await txn.rawQuery(
        'SELECT * FROM compute_jobs '
        'WHERE state = ? AND (next_run_at IS NULL OR next_run_at <= ?) '
        'ORDER BY priority DESC, updated_at ASC, created_at ASC '
        'LIMIT 1',
        ['queued', now],
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      await txn.update(
        'compute_jobs',
        {
          'state': 'running',
          'attempts': ((row['attempts'] as num?)?.toInt() ?? 0) + 1,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      return {...row, 'state': 'running', 'updated_at': now};
    });
  }

Future<List<Map<String, dynamic>>> _ldbHrSamplesInRange(
    int fromTs,
    int toTs,
  ) async {
    final db = await LocalDb.instance;
    if (LocalDb.sessionSensorSources.isEmpty) {
      return db.query(
        'decoded_onehz',
        columns: ['rec_ts', 'hr'],
        where: 'rec_ts >= ? AND rec_ts <= ? AND hr > 0 AND '
            '${derivableSourceSql()}',
        whereArgs: [fromTs, toTs],
        orderBy: 'rec_ts ASC',
      );
    }
    final rows = await db.query(
      'decoded_onehz',
      columns: ['rec_ts', 'hr', 'source'],
      where: 'rec_ts >= ? AND rec_ts <= ?',
      whereArgs: [fromTs, toTs],
      orderBy: 'rec_ts ASC',
    );
    return [
      for (final r in sessionWindowRows(rows))
        if (((r['hr'] as num?) ?? 0) > 0)
        {'rec_ts': r['rec_ts'], 'hr': r['hr'], 'source': r['source']},
    ];
  }

Future<int?> _ldbLastDecodedRecTs() async {
    final db = await LocalDb.instance;
    return Sqflite.firstIntValue(
      await db.rawQuery(
        // [kPrimaryBandSourceSql], NOT [derivableSourceSql]: the data edge is
        // the BAND's edge. A peripheral sensor's second is not evidence the
        // strap synced, and letting it move this would tell the sync engine it
        // made progress it did not make.
        //
        // ponytail: the derive engine reads this as "now, in data time" (its
        // finalization anchor, and `dataNowSec <= 0` short-circuits the whole
        // pass), which is a DIFFERENT question — an install with a verified
        // strap and no band would derive nothing. The upgrade is a sibling
        // `lastAdmittedRecTs()` on [derivableSourceSql] for the derive callers,
        // added when a second admitted source actually exists; splitting it now
        // would be two names for one query.
        'SELECT MAX(rec_ts) FROM decoded_onehz '
        'WHERE rec_ts > 0 AND $kPrimaryBandSourceSql',
      ),
    );
  }
