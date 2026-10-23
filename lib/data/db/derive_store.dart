part of '../db.dart';

Future<DayCheckpoint?> _ldbDayCheckpoint(String dayId, int algoVersion) async {
    final db = await LocalDb.instance;
    return db.transaction((db) async {
    // Keep each platform-channel row below Android's CursorWindow limit.
    final rows = await db.rawQuery(
      'SELECT day_id, algo_version, fmt, ctx_sig, cp_rec_ts, night_ref, '
      'computed_at, length(state) AS state_len, length(rev_vec) AS rev_len '
      'FROM day_checkpoint WHERE day_id = ? AND algo_version = ? LIMIT 1',
      [dayId, algoVersion],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    Future<Uint8List> readBlob(String column, int length) async {
      const chunk = 512 * 1024;
      final bytes = Uint8List(length);
      for (var offset = 0; offset < length; offset += chunk) {
        final parts = await db.rawQuery(
          'SELECT substr($column, ?, ?) AS part FROM day_checkpoint '
          'WHERE day_id = ? AND algo_version = ?',
          [offset + 1, chunk, dayId, algoVersion],
        );
        final part = (parts.single['part'] as List).cast<int>();
        bytes.setRange(offset, offset + part.length, part);
      }
      return bytes;
    }
    final state = await readBlob('state', (r['state_len'] as num).toInt());
    final revVec = await readBlob('rev_vec', (r['rev_len'] as num).toInt());
    return DayCheckpoint(
      dayId: r['day_id'] as String,
      algoVersion: (r['algo_version'] as num).toInt(),
      fmt: (r['fmt'] as num).toInt(),
      ctxSig: r['ctx_sig'] as String,
      cpRecTs: (r['cp_rec_ts'] as num).toInt(),
      revVec: revVec,
      state: state,
      nightRef: r['night_ref'] as String?,
      computedAt: (r['computed_at'] as num).toInt(),
    );
    });
  }

Future<bool> _ldbPutLastResult(String key, int computedAt, String payload, int maxRows, {required String? sig, required ({int wipeEpoch, int openCount})? unlessReplacedSince}) async {
    final db = await LocalDb.instance;
    var written = false;
    await db.transaction((txn) async {
      // Fenced INSIDE the write transaction: a wipe that landed while the
      // caller was encoding must not be followed by the pre-wipe artifact.
      if (unlessReplacedSince != null && LocalDb.storeReplacedSince(unlessReplacedSince)) {
        return;
      }
      written = true;
      await txn.insert(
          'last_result',
          {
            'key': key,
            'computed_at': computedAt,
            'payload_json': payload,
            'input_sig': sig,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.rawDelete(
          'DELETE FROM last_result WHERE key NOT IN ('
          'SELECT key FROM last_result ORDER BY computed_at DESC, key DESC '
          'LIMIT ?)',
          [maxRows]);
    });
    return written;
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

({String day, int value, int? wakeSec})? _ldbPrivParseFrozenHeadline(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is Map && d['day'] is String && d['value'] is num) {
        final wake = d['wake_sec'];
        return (
          day: d['day'] as String,
          value: (d['value'] as num).round(),
          wakeSec: wake is num ? wake.toInt() : null,
        );
      }
    } catch (_) {
      /* malformed → treat as unset */
    }
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

Future<Map<String, int>?> _ldbNoteHeadlineShown(String day, int value) async =>
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

Future<bool> _ldbPutDayResult({required String dayId, required int algoVersion, required String payloadJson, required String windowJson, required bool finalized, required bool skipped, required bool partial, required double? rhr, required double? rmssd, required double? readiness, required Map<String, double?> series, required String? source, required ({String method, String family, String cls}) Function(String key)? seriesMethod, required String? deviceFamily, required String? coverageDevices, required String? priorityHash, required Set<String> blankKeys, required DayResultWrite reason, InputStamp? inputStamp}) async {
    final db = await LocalDb.instance;
    final now = LocalDb.nowMs();
    // THE write seam for the compact curve format. All four callers
    // (DerivationEngine x2, cloud_import, whoop_import) funnel through here, so
    // no producer needs to know the wire format exists — upstream code keeps
    // merging and patching plain [{t,v}] lists in memory. Lossless or no-op:
    // SeriesCodec leaves anything it cannot encode exactly as it found it.
    String? storedPayload;
    var storedSeries = const <String, double?>{};
    final accepted = await db.transaction((txn) async {
      if (reason != DayResultWrite.userOverride) {
        final cur = await txn.query(
          'day_result',
          columns: ['payload_json', 'skipped'],
          where: 'day_id = ? AND algo_version = ? AND finalized = 1',
          whereArgs: [dayId, algoVersion],
          limit: 1,
        );
        // A frozen row yields only to a newer IMPORT over a row that is itself
        // not measured on this device (a previous import or a skip marker) —
        // the replacement every importer already had; see [isMeasuredDayRow].
        if (cur.isNotEmpty &&
            !(LocalDb._isImportedPayload(payloadJson) &&
                !LocalDb.isMeasuredDayRow(cur.first))) {
          return false;
        }
      }
      // Upstream's nap review: a band day keeps the naps the user accepted or
      // edited (ActivityStore), composed into the payload before it is encoded.
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
      storedPayload = encodedPayload;
      storedSeries = reviewedSeries;
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
      //
      // The blanked keys are the exception, and are deleted whether or not the
      // row is partial. Withholding a value is what `partial` is for; a night
      // the user blanked has no value to wait for, and leaving its old rows
      // until a non-partial pass lands keeps feeding them to every baseline
      // for as long as that pass keeps failing.
      for (final k in blankKeys) {
        await txn.delete('metric_series',
            where: 'date = ? AND key = ?', whereArgs: [dayId, k]);
      }
      if (!partial) {
        for (final e in reviewedSeries.entries) {
          if (e.value == null && blankKeys.contains(e.key)) continue;
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
      // A written row ends a decline: the day was computable after all, so a
      // stale `settled:` marker must not keep a partial or unfinalized row
      // out of every later pass. Same transaction as the write.
      await txn.delete('compute_freshness',
          where: 'key = ?', whereArgs: ['${LocalDb._settledPrefix}$dayId']);
      return true;
    });
    // Shadow group rows: AFTER the commit, in their own small transaction.
    // Inside this one, SQLITE_FULL on the extra payload rolls back the whole
    // transaction and takes the day_result with it, and a savepoint rollback
    // confuses sqflite's transaction bookkeeping. A crash between the two
    // leaves the day with no or stale group rows; they are re-sliced from the
    // stored payload (1e/1f reconcile). Failures are counted, never thrown.
    if (accepted) {
      await writeGroupRowsAfterCommit(dayId: dayId, algoVersion: algoVersion, finalized: finalized, partial: partial, skipped: skipped, userOverride: reason == DayResultWrite.userOverride, expectedPayload: storedPayload!, expectedComputedAt: now, stamp: inputStamp, series: storedSeries);
    }
    return accepted;
  }

Future<List<(int, double, double)>> _ldbSkinTempAmbientMinutes(int fromSec, int toSec) async {
    InputReads.note('decoded', '');
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

Future<void> _ldbPrivUpdateFreshnessJson(String key, Map<String, dynamic> Function(Map<String, dynamic> current) update) async {
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

Future<bool> _ldbRewriteDayPayload(String dayId, int algoVersion, String payloadJson, {required String expectedPayloadJson}) async {
    final db = await LocalDb.instance;
    final n = await db.update(
      'day_result',
      {'payload_json': payloadJson},
      where: 'day_id = ? AND algo_version = ? AND payload_json = ?',
      whereArgs: [dayId, algoVersion, expectedPayloadJson],
    );
    return n > 0;
  }

Future<Map<String, dynamic>?> _ldbDayResultMeta(String dayId, {required bool onReader}) async {
    Future<Map<String, dynamic>?> read(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      'SELECT r.day_id, r.algo_version, r.computed_at, r.finalized, '
      'r.skipped, r.partial, r.rhr, r.rmssd, r.readiness, r.window_json, '
      'COALESCE(v.rev, 0) AS rev, r.day_id AS date '
      'FROM day_result r ${LocalDb._servedDayJoin} '
      "LEFT JOIN row_rev v ON v.kind = 'day_result' AND v.k1 = r.day_id "
      'AND v.k2 = r.algo_version WHERE r.day_id = ?',
      [dayId],
    );
    return rows.isEmpty ? null : rows.first;
    }
    return onReader ? LocalDb.readerRun(read) : read(await LocalDb.instance);
  }

Future<DayPayloadRead> _ldbDayPayload(String dayId, int algoVersion, {required int expectedRev, required bool onReader}) async {
    Future<DayPayloadRead> read(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      'SELECT r.payload_json, COALESCE(v.rev, 0) AS rev '
      'FROM day_result r LEFT JOIN row_rev v '
      "ON v.kind = 'day_result' AND v.k1 = r.day_id AND v.k2 = r.algo_version "
      'WHERE r.day_id = ? AND r.algo_version = ?',
      [dayId, algoVersion],
    );
    if (rows.isEmpty) return const DayPayloadAbsent();
    final rev = (rows.first['rev'] as num).toInt();
    if (rev != expectedRev) return DayPayloadStale(currentRev: rev);
    return DayPayloadOk(
      payloadJson: rows.first['payload_json'] as String,
      rev: rev,
    );
    }
    return onReader ? LocalDb.readerRun(read) : read(await LocalDb.instance);
  }

Future<Map<String, dynamic>?> _ldbReadinessAbsentDiag(String? day) async {
    if (day == null) return null;
    try {
      final payload = (await LocalDb.dayResult(day))?['payload_json'];
      if (payload is! String || !payload.contains('"readiness_absent_diag"')) {
        return null;
      }
      final b = jsonDecode(payload);
      final diag = b is Map ? b['readiness_absent_diag'] : null;
      return diag is Map ? diag.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

Future<List<Map<String, dynamic>>> _ldbDayResultsByIds(Iterable<String> dayIds) async {
    final ids = dayIds.toSet().toList();
    if (ids.isEmpty) return const [];
    final db = await LocalDb.instance;
    final out = <Map<String, dynamic>>[];
    // SQLite caps bound variables (999 on old builds); stay well under.
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
      final rows = await db.rawQuery(
        'SELECT r.* FROM day_result r ${LocalDb._servedDayJoin} '
        'WHERE r.day_id IN (${List.filled(chunk.length, '?').join(',')})',
        chunk,
      );
      out.addAll(rows.map(LocalDb._withDate));
    }
    return out;
  }

Future<List<Map<String, dynamic>>> _ldbRecentDayResultsMeta(int limit, {required DatabaseExecutor? within}) async {
    Future<List<Map<String, dynamic>>> read(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      'SELECT r.day_id, r.algo_version, r.computed_at, r.finalized, '
      'r.skipped, r.partial, r.rhr, r.rmssd, r.readiness '
      'FROM day_result r '
      '${LocalDb._servedDayJoin} '
      'ORDER BY r.day_id DESC LIMIT ?',
      [limit],
    );
    return [for (final r in rows) LocalDb._withDate(r)];
    }
    return within != null ? read(within) : LocalDb.readerRun(read);
  }

Future<List<String>> _ldbDayResultDayIdsDesc() async {
    return LocalDb.readerRun((db) async {
    final rows = await db.rawQuery(
      'SELECT day_id FROM day_result WHERE algo_version <= ? '
      'GROUP BY day_id ORDER BY day_id DESC',
      [LocalDb._servedAlgoCeiling],
    );
    return [
      for (final r in rows)
        if (r['day_id'] is String) r['day_id'] as String,
    ];
    });
  }

Future<Set<String>> _ldbDaysWithSleepTst() async {
    return LocalDb.readerRun((db) async {
    final rows = await db.rawQuery(
      'SELECT r.day_id FROM day_result r '
      '${LocalDb._servedDayJoin} '
      // json_valid() first: json_extract() ERRORS on a malformed payload, and a
      // corrupt bundle must degrade to "no sleep that day", never take out the
      // whole Records screen.
      'WHERE json_valid(r.payload_json) '
      "AND json_extract(r.payload_json, '\$.sleep.accounting.value.tst_sec') "
      'IS NOT NULL',
    );
    return {
      for (final r in rows)
        if (r['day_id'] is String) r['day_id'] as String,
    };
    });
  }

Future<List<String>> _ldbAvailableDayIds() async {
    return LocalDb.readerRun((db) async {
    // Latest version per day (matches [dayResult]), then drop skip-markers.
    final rows = await db.rawQuery(
      'SELECT r.day_id FROM day_result r '
      '${LocalDb._servedDayJoin} '
      'WHERE r.skipped = 0 '
      'ORDER BY r.day_id DESC',
    );
    return [
      for (final r in rows)
        if (r['day_id'] is String && (r['day_id'] as String).isNotEmpty)
          r['day_id'] as String,
    ];
    });
  }

Future<Set<String>> _ldbPartialDayIds(int algoVersion) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'day_result',
      columns: ['day_id'],
      where: 'algo_version = ? AND partial = 1',
      whereArgs: [algoVersion],
    );
    return {for (final r in rows) r['day_id'] as String};
  }

Future<Map<String, dynamic>> _ldbRawStats() async {
    final db = await LocalDb.instance;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_onehz'),
        ) ??
        0;
    final tsRow = (await db.rawQuery(
      'SELECT MIN(rec_ts) AS lo, MAX(rec_ts) AS hi FROM decoded_onehz WHERE rec_ts > 0',
    )).first;
    final decodedOneHz =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_onehz'),
        ) ??
        0;
    final decodedRr =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_rr'),
        ) ??
        0;
    final legacySamples =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM samples'),
        ) ??
        0;
    return {
      'count': count,
      'min_rec_ts': (tsRow['lo'] as num?)?.toInt(),
      'max_rec_ts': (tsRow['hi'] as num?)?.toInt(),
      'by_type': const <String, int>{},
      'min_captured_ms': null,
      'max_captured_ms': null,
      'decoded_onehz': decodedOneHz,
      'decoded_rr': decodedRr,
      'legacy_samples': legacySamples,
    };
  }

Future<List<Map<String, dynamic>>> _ldbTableStorageStats() async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' "
      "AND name != 'android_metadata' "
      "ORDER BY name ASC",
    );
    final out = <Map<String, dynamic>>[];
    final dbstatAvailable = await LocalDb._dbstatAvailable(db);
    for (final row in rows) {
      final name = row['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final tableRows =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $name'),
          ) ??
          0;
      final bytes = dbstatAvailable
          ? await LocalDb._tableBytesViaDbstat(db, name)
          : await LocalDb._tableBytesApprox(db, name);
      out.add({
        'table': name,
        'rows': tableRows,
        'bytes': bytes,
        'mb': bytes == null ? null : bytes / (1024 * 1024),
        'approximate': !dbstatAvailable,
      });
    }
    out.sort((a, b) {
      final aa = (a['bytes'] as num?)?.toInt() ?? -1;
      final bb = (b['bytes'] as num?)?.toInt() ?? -1;
      return bb.compareTo(aa);
    });
    return out;
  }

Future<Map<String, dynamic>> _ldbSchemaHealth() async {
    final db = await LocalDb.instance;
    Future<bool> hasTable(String name) async {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [name],
      );
      return rows.isNotEmpty;
    }

    Future<Set<String>> cols(String table) async {
      final info = await db.rawQuery('PRAGMA table_info($table)');
      return {
        for (final c in info)
          if (c['name'] is String) c['name'] as String,
      };
    }

    final requiredTables = <String>[
      'samples',
      'decoded_onehz',
      'decoded_rr',
      'events',
      'band_events',
      'band_battery',
      'day_result',
      'metric_series',
      'baselines',
      'sessions',
      'journal',
      'journal_metric',
      'journal_field_def',
      'lab_result',
      'lab_marker_def',
      'breathing_session',
      'food_entry',
      'food_def',
      'med_def',
      'med_dose',
      'cycle_log',
      'notifications',
      'sync_cursor',
      'sync_ledger',
      'sync_quarantine',
      'compute_freshness',
      'compute_jobs',
      'sleep_session_candidates',
      'wake_day_features',
      'live_coverage',
      'workout_route',
      'workout_split',
      'notif_fired',
      'metric_series_version',
      'metric_method',
      'band_backlog',
      'external_hr',
      'imported_measurement',
      'imported_workout',
      'observation',
      'device',
      'device_coverage',
      'signal_priority',
      'vendor_sleep_epoch',
      'substrate_archive',
    ];

    final missingTables = <String>[];
    for (final table in requiredTables) {
      if (!await hasTable(table)) missingTables.add(table);
    }

    final sessionCols = await hasTable('sessions')
        ? await cols('sessions')
        : <String>{};
    final syncLedgerCols = await hasTable('sync_ledger')
        ? await cols('sync_ledger')
        : <String>{};

    final missingColumns = <String, List<String>>{};
    void expect(String table, Set<String> present, List<String> required) {
      final miss = [
        for (final c in required)
          if (!present.contains(c)) c,
      ];
      if (miss.isNotEmpty) missingColumns[table] = miss;
    }

    expect('sessions', sessionCols, [
      'id',
      'start_ts',
      'status',
      'steps',
      // The frozen trace: a build that lost these columns silently blanks the
      // chart half of every session older than the substrate window.
      'trace_json',
      'trace_samples',
    ]);
    expect('sync_ledger', syncLedgerCols, [
      'chunk_id',
      'kind',
      'status',
      'updated_at',
      'meta_json',
    ]);

    final integrity = await db.rawQuery('PRAGMA integrity_check');
    final integrityOk =
        integrity.isNotEmpty && integrity.first.values.first == 'ok';

    return {
      'ok': missingTables.isEmpty && missingColumns.isEmpty && integrityOk,
      'missing_tables': missingTables,
      'missing_columns': missingColumns,
      'integrity_ok': integrityOk,
    };
  }

Future<Map<String, dynamic>?> _ldbSyncLedgerSummary(String chunkId) async {
    final row = await LocalDb.syncLedgerEntry(chunkId);
    if (row == null) return null;
    final meta = <String, dynamic>{};
    final rawMeta = row['meta_json'];
    if (rawMeta is String && rawMeta.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawMeta);
        if (decoded is Map) meta.addAll(decoded.cast<String, dynamic>());
      } catch (_) {
        /* ignore */
      }
    }
    return {
      'chunk_id': row['chunk_id'],
      'kind': row['kind'],
      'status': row['status'],
      'created_at': row['created_at'],
      'updated_at': row['updated_at'],
      'acked_at': row['acked_at'],
      'last_error': row['last_error'],
      ...meta,
    };
  }

Future<Map<String, dynamic>> _ldbDerivedStats() async {
    final db = await LocalDb.instance;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(DISTINCT day_id) FROM day_result'),
        ) ??
        0;
    final recent = await LocalDb.recentDayResults(14);
    var skipped = 0;
    for (final r in recent) {
      final pj = r['payload_json'];
      if (pj is String && pj.contains('"skipped":true')) skipped++;
    }
    final dates = [for (final r in recent) r['day_id'] as String];
    return {
      'count': count,
      'skipped': skipped,
      'latest_date': dates.isEmpty ? null : dates.first,
      'dates': dates,
    };
  }

Future<List<Map<String, dynamic>>> _ldbRecentDayDiagnostics(int limit) async {
    final rows = await LocalDb.recentDayResultMetas(limit);
    final rawByDay = await LocalDb.decodedRecTsMaxByDay();
    final out = <Map<String, dynamic>>[];
    for (var start = 0; start < rows.length; start += 8) {
      final chunk = rows.skip(start).take(8).toList();
      final reads = await BundleStore.shared.readAll([
        for (final row in chunk) BundleSource.day(row['date'] as String),
      ]);
      for (var i = 0; i < chunk.length; i++) {
        final row = chunk[i];
        final read = reads[i];
        final decoded = read is BundleOk ? read.view.debugFrozenRoot as Map : const <String, dynamic>{};
        final scalars = decoded['scalars'] is Map ? decoded['scalars'] as Map : const <String, dynamic>{};
        final dayId = row['date'] as String? ?? '';
        out.add({
          'day_id': dayId,
          'computed_at': row['computed_at'],
          'algo_version': row['algo_version'],
          'finalized': row['finalized'],
          'raw_max_rec_ts': rawByDay[dayId],
          'skipped': decoded['skipped'] == true,
          'skip_reason': decoded['reason'],
          'rhr': row['rhr'] ?? scalars['rhr'],
          'rmssd': row['rmssd'] ?? scalars['rmssd'],
          'readiness': row['readiness'] ?? scalars['readiness'],
          'strain': scalars['strain'],
          'tst_min': scalars['tst_min'],
          'resp_rate': scalars['resp_rate'],
        });
      }
    }
    return out;
  }

Future<({double floorG, String frozenOn, int days})?> _ldbGetMovementFloor() async {
    final row = await LocalDb.baseline('movement_floor');
    final raw = row?['payload_json'];
    if (raw is! String || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return null;
      final f = (d['floor_g'] as num?)?.toDouble();
      final on = d['frozen_on'] as String?;
      if (f == null || !f.isFinite || f <= 0 || on == null) return null;
      return (floorG: f, frozenOn: on, days: (d['days'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }

Future<List<Map<String, dynamic>>> _ldbMetricSeries(String key, {required int? limit, required bool measuredOnly, required bool ownOnly}) async {
    InputReads.note('metric_series', '');
    return LocalDb.readerRun((db) async {
    return db.query(
      'metric_series',
      where: 'key = ? AND value IS NOT NULL${LocalDb._validSql(key)}'
          '${measuredOnly ? ' AND date NOT IN (${LocalDb._importedDatesSql})' : ''}'
          '${ownOnly ? LocalDb._ownOnlySql : ''}',
      whereArgs: [key],
      orderBy: 'date ASC',
      limit: limit,
    );
    });
  }

Future<
    ({
      Map<String, List<Map<String, dynamic>>> rows,
      List<Map<String, dynamic>> versions,
      List<Map<String, dynamic>> meta,
    })
  > _ldbMetricSeriesBundle(List<String> keys, {required bool ownOnly}) async {
    return LocalDb.readerRun((db) async {
    // `transaction` opens with BEGIN IMMEDIATE, which a query-only connection
    // refuses. On the reader each statement still reads one committed snapshot;
    // only a commit landing BETWEEN the three can skew them (a series row with
    // no version row yet), which every consumer already treats as absent.
    // putDayResult writes all three in one transaction, so it cannot tear one.
    Future<R> snapshot<R>(Future<R> Function(DatabaseExecutor) body) =>
        identical(db, LocalDb._db) ? db.transaction(body) : body(db);
    return snapshot((txn) async {
      final byKey = {for (final k in keys) k: <Map<String, dynamic>>[]};
      if (keys.isNotEmpty) {
        final rows = await txn.query(
          'metric_series',
          where:
              'key IN (${List.filled(keys.length, '?').join(',')}) '
              'AND value IS NOT NULL${ownOnly ? LocalDb._ownOnlySql : ''}',
          whereArgs: keys,
          orderBy: 'date ASC',
        );
        for (final r in rows) {
          byKey[r['key'] as String]!.add(r);
        }
      }
      final versions = await txn.query(
        'metric_series_version',
        orderBy: 'date ASC',
      );
      final longest = byKey.values.fold<int>(
        0,
        (m, l) => l.length > m ? l.length : m,
      );
      final meta = longest == 0
          ? const <Map<String, dynamic>>[]
          : await LocalDb.recentDayResultsMeta(longest, within: txn);
      return (rows: byKey, versions: versions, meta: meta);
    });
    });
  }

Future<List<double>> _ldbTrailingSeriesValues(String key, int n, {required bool measuredOnly, required String? before}) async {
    InputReads.note('metric_series', '');
    return LocalDb.readerRun((db) async {
    final rows = await db.rawQuery(
      'SELECT value FROM metric_series '
      'WHERE key = ? AND value IS NOT NULL '
      '${before != null ? 'AND date < ? ' : ''}'
      '${measuredOnly ? 'AND date NOT IN (${LocalDb._importedDatesSql}) ' : ''}'
      'ORDER BY date DESC LIMIT ?',
      [key, ?before, n],
    );
    return [for (final r in rows.reversed) (r['value'] as num).toDouble()];
    });
  }

Future<void> _ldbUpdateBaseline(String key, String? Function(String? current) transform) async {
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
        'updated_at': LocalDb.nowMs(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }, exclusive: true);
  }

Future<Map<String, String>> _ldbDecodedDayFingerprints(Iterable<String> days) async {
    final db = await LocalDb.instance;
    final out = <String, String>{};
    for (final day in days.toSet()) {
      final lo = localDayStartSec(day), hi = localDayEndSec(day);
      if (lo == null || hi == null) continue;
      final rows = await db.rawQuery(
        'SELECT MAX(rec_ts) AS mx, COUNT(*) AS n FROM decoded_onehz '
        'WHERE rec_ts > 0 AND ${derivableSourceSql()} '
        'AND rec_ts >= ? AND rec_ts < ?',
        [lo, hi],
      );
      final mx = rows.isEmpty ? null : (rows.first['mx'] as num?)?.toInt();
      if (mx == null) continue;
      final rev = await db.rawQuery(
        'SELECT COALESCE(SUM(rev), 0) AS r FROM input_rev '
        'WHERE bucket >= ? AND bucket <= ?',
        [lo ~/ 900, (hi - 1) ~/ 900],
      );
      final r = rev.isEmpty ? 0 : (rev.first['r'] as num?)?.toInt() ?? 0;
      out[day] = '$mx:${(rows.first['n'] as num?)?.toInt() ?? 0}:$r';
    }
    return out;
  }

Future<String?> _ldbDecodedWindowFingerprint(int loSec, int hiSec) async {
    if (hiSec < loSec) return null;
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      'SELECT MAX(rec_ts) AS mx, COUNT(*) AS n FROM decoded_onehz '
      'WHERE rec_ts > 0 AND ${derivableSourceSql()} '
      'AND rec_ts >= ? AND rec_ts <= ?',
      [loSec, hiSec],
    );
    final mx = rows.isEmpty ? null : (rows.first['mx'] as num?)?.toInt();
    if (mx == null) return null;
    final rev = await db.rawQuery(
      'SELECT COALESCE(SUM(rev), 0) AS r FROM input_rev '
      'WHERE bucket >= ? AND bucket <= ?',
      [loSec ~/ 900, hiSec ~/ 900],
    );
    final r = rev.isEmpty ? 0 : (rev.first['r'] as num?)?.toInt() ?? 0;
    return '$mx:${(rows.first['n'] as num?)?.toInt() ?? 0}:$r';
  }

Future<({double? rhr, String? windowJson})?> _ldbDayCalorieInputs(String day) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'day_result',
      columns: ['rhr', 'window_json'],
      where: 'day_id = ? AND algo_version <= ?',
      whereArgs: [day, LocalDb._servedAlgoCeiling],
      orderBy: 'algo_version DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (
      rhr: (rows.first['rhr'] as num?)?.toDouble(),
      windowJson: rows.first['window_json'] as String?,
    );
  }

Future<({int? startTs, int? endTs, String rev})?> _ldbSessionRev(String id) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'sessions',
      columns: [
        'start_ts', 'end_ts', 'status', 'type', 'calories', 'strain', 'max_hr',
        'duration_min', 'steps', 'rpe', 'trace_samples', 'zone_min_json',
        'avg_hr', 'hrr_bpm', 'vo2max_estimate', 'private', 'device_family',
      ],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      startTs: (r['start_ts'] as num?)?.toInt(),
      endTs: (r['end_ts'] as num?)?.toInt(),
      rev: r.values.map((v) => v ?? '').join(','),
    );
  }

Future<Map<String, String>> _ldbDerivedFingerprints(int algoVersion) async {
    final db = await LocalDb.instance;
    final rows = await db.query(
      'compute_freshness',
      where: 'key LIKE ?',
      whereArgs: ['${LocalDb._derivedFpPrefix}%'],
    );
    final out = <String, String>{};
    for (final r in rows) {
      try {
        final m = jsonDecode(r['payload_json'] as String);
        if (m is Map && m['v'] == algoVersion && m['fp'] is String) {
          out[(r['key'] as String).substring(LocalDb._derivedFpPrefix.length)] =
              m['fp'] as String;
        }
      } catch (_) {
        // A row that does not parse is the same as no row: the day re-derives.
      }
    }
    return out;
  }

Future<Map<String, ({String own, String? prev, String edit})>> _ldbSettledFingerprints(int algoVersion) async {
    final db = await LocalDb.instance;
    // json_extract in SQL: four scalars of a bookkeeping row, no payload decode.
    final rows = await db.rawQuery(
      "SELECT key, json_extract(payload_json, '\$.own') AS own, "
      "json_extract(payload_json, '\$.prev') AS prev, "
      "json_extract(payload_json, '\$.edit') AS edit "
      'FROM compute_freshness WHERE substr(key, 1, ?) = ? '
      "AND json_extract(payload_json, '\$.v') = ?",
      [LocalDb._settledPrefix.length, LocalDb._settledPrefix, algoVersion],
    );
    return {
      for (final r in rows)
        if (r['own'] is String)
          (r['key'] as String).substring(LocalDb._settledPrefix.length): (
            own: r['own'] as String,
            prev: r['prev'] as String?,
            edit: (r['edit'] as String?) ?? '',
          ),
    };
  }

Future<Map<String, ({String reason, int? keptAlgoVersion, int decidedAtMs})>> _ldbDeclinedDays(int algoVersion) async {
    final db = await LocalDb.instance;
    // Scalars only: never day_result's payload (blob rows overflow the cursor window).
    final rows = await db.rawQuery(
      "SELECT f.key AS key, json_extract(f.payload_json, '\$.reason') AS reason, "
      "json_extract(f.payload_json, '\$.at') AS at, "
      '(SELECT MAX(r.algo_version) FROM day_result r '
      'WHERE r.day_id = substr(f.key, ? + 1) AND r.algo_version < ?) AS kept '
      'FROM compute_freshness f WHERE substr(f.key, 1, ?) = ? '
      "AND json_extract(f.payload_json, '\$.v') = ? "
      "AND json_extract(f.payload_json, '\$.reason') IS NOT NULL "
      'AND kept IS NOT NULL',
      [
        LocalDb._settledPrefix.length,
        algoVersion,
        LocalDb._settledPrefix.length,
        LocalDb._settledPrefix,
        algoVersion,
      ],
    );
    return {
      for (final r in rows)
        (r['key'] as String).substring(LocalDb._settledPrefix.length): (
          reason: r['reason'] as String,
          keptAlgoVersion: r['kept'] as int?,
          decidedAtMs: (r['at'] as int?) ?? 0,
        ),
    };
  }

Future<bool> _ldbDayIsFinal(String day, int algoVersion) async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      'SELECT 1 FROM day_result WHERE day_id = ? AND algo_version = ? '
      'AND finalized = 1 '
      "AND payload_json NOT LIKE '%\"imported\":true%' "
      'UNION ALL SELECT 1 FROM compute_freshness WHERE key = ? '
      "AND json_extract(payload_json, '\$.v') = ? LIMIT 1",
      [day, algoVersion, '${LocalDb._settledPrefix}$day', algoVersion],
    );
    return rows.isNotEmpty;
  }

Future<int> _ldbReencodeLegacyDayResults({required int limit}) async {
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
    final prepared = await Isolate.run(() => _reencodeBatchHeavy(payloads));
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

Future<void> _ldbRefreshComputeFreshness() {
    // The completers are the owner's too: a completer delivers through the zone
    // it was made in, so one made by a caller whose zone stopped would strand
    // every later caller that joins it. They carry the outcome as a VALUE (null
    // or a [_FreshnessFailed]): an error future does not cross into another
    // error zone, it would surface as uncaught in the root zone instead.
    if (LocalDb._freshnessRunning) {
      return LocalDb._joinFreshness(LocalDb._freshnessNext ??= Zone.root.run<Completer<Object?>>(Completer<Object?>.new));
    }
    final first = Zone.root.run<Completer<Object?>>(Completer<Object?>.new);
    // The loop is process-wide state, not the first caller's: it runs in the
    // root zone, so a caller's zone (a fake-async or guarded zone that stops
    // scheduling, or a zone torn down mid-run) can never strand the latch below
    // and with it every later caller. Callers still resume in their own zones.
    unawaited(Zone.root.runUnary(LocalDb._freshnessLoop, first));
    return LocalDb._joinFreshness(first);
  }

Future<void> _ldbPrivFreshnessLoop(Completer<Object?> first) async {
    LocalDb._freshnessRunning = true;
    var current = first;
    try {
      while (true) {
        try {
          LocalDb.debugFreshnessRuns++;
          await LocalDb._computeAndWriteFreshness();
          current.complete(null);
        } catch (e, st) {
          current.complete(_FreshnessFailed(e, st));
        }
        final next = LocalDb._freshnessNext;
        if (next == null) break;
        LocalDb._freshnessNext = null;
        current = next;
      }
    } finally {
      LocalDb._freshnessRunning = false;
    }
  }

Future<({Map<String, dynamic> row, BundleRead read})?> _ldbPrivFreshnessRead(String dayId, Map<String, dynamic> row) async {
    var current = row;
    for (var attempt = 0; attempt < 3; attempt++) {
      final read = await BundleStore.shared.project(
        BundleSource.day(dayId),
        ProjectionId.freshness,
      );
      if (read is BundleOk) {
        if (read.key.rev == (current['rev'] as num?)?.toInt() &&
            read.key.k2 == (current['algo_version'] as num?)?.toInt()) {
          return (row: current, read: read);
        }
      } else if (read is BundleAbsent && read.undecodable) {
        final fresh = await LocalDb.dayResultMeta(dayId);
        return fresh == null ? null : (row: fresh, read: read);
      }
      final fresh = await LocalDb.dayResultMeta(dayId);
      if (fresh == null) return null; // deleted since the scan began
      current = fresh;
    }
    throw BundleRetryable(BundleSource.day(dayId));
  }

Future<void> _ldbPrivComputeAndWriteFreshness() async {
    final raw = await LocalDb.rawStats();
    final recent = await LocalDb.recentDayResultMetas(30);
    final rolling = await LocalDb.baselineMeta('rolling');
    final cross = await LocalDb.baselineMeta('crossday');
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
    for (var row in recent) {
      final dayId = (row['day_id'] ?? row['date'])?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      final paired = await LocalDb._freshnessRead(dayId, row);
      if (paired == null) continue; // deleted while it was being read
      row = paired.row;
      final read = paired.read;
      if (dayId == today && todayRow == null) todayRow = row;
      if (read is BundleOk && read.view.owned('skipped') == true) continue;
      // #448: today's night is not today's overnight until the drain has
      // passed its wake. Mid-drain the window closes at the newest record, so
      // serving it showed a partial night and its readiness as this morning's.
      // A row with no window is held too: mid-drain the edge can still sit
      // before sleep onset, and that read as a settled 'no sleep' night.
      // A no-sleep window's `value` is the string '—', not a Map.
      final offsetMs = read is BundleOk
          ? read.view.owned('sleep.window.value.offset_ms')
          : null;
      final wakeSec = offsetMs is num ? offsetMs ~/ 1000 : null;
      // A night is judged on the edge its row was derived against
      // (`data_edge_sec`), so wake and edge share one substrate: a later band
      // sync must not settle a row still holding the partial night, and an
      // unworn band's edge says nothing about a wearable's night. Legacy rows
      // without the stamp fall back to the band's edge.
      final storedEdge =
          read is BundleOk ? read.view.owned('data_edge_sec') : null;
      final edgeSec = (storedEdge as num?)?.toInt() ?? bandEdgeSec;
      if (dayId == today) {
        recoveryState = recoveryStateOf(
          wakeSec: wakeSec,
          dataEdgeSec: edgeSec,
          nowSec: nowSec,
        )?.wire;
      }
      if (dayId == today &&
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
      final readiness = read is BundleOk
          ? read.view.owned('scalars.readiness')
          : null;
      if (latestOvernightDay == null) {
        final sleep = read is BundleOk
            ? read.view.owned('sleep.accounting.value')
            : null;
        final flags = read is BundleOk ? read.view.owned('flags') : null;
        final hasSleep = sleep is Map && sleep['tst_sec'] != null;
        final noSleep = flags is List && flags.contains('NO_SLEEP_DETECTED');
        if (hasSleep || noSleep) {
          latestOvernightDay = dayId;
          latestOvernightComputedAt = (row['computed_at'] as num?)?.toInt();
        }
      }
      if (latestRecoveryDay == null &&
          ((row['readiness'] as num?) != null || readiness is num)) {
        latestRecoveryDay = dayId;
        latestRecoveryComputedAt = (row['computed_at'] as num?)?.toInt();
      }
      if (latestOvernightDay != null &&
          latestRecoveryDay != null &&
          todayRow != null) {
        break;
      }
    }
    // The scan may have crossed a concurrent delete or replacement. Use the
    // current payload-free row for today's activity and timestamp fields.
    todayRow = await LocalDb.dayResultMeta(today);
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
    await LocalDb.debugBeforeFreshnessWrite?.beforeWrite();
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

Future<void> _ldbEnqueueDeriveJob({required String type, required String reason}) async {
    final db = await LocalDb.instance;
    final now = LocalDb.nowMs();
    await db.transaction((txn) async {
      // Dedupe against QUEUED jobs only. A running job already read its
      // inputs, so data that lands after that must queue a follow-up rather
      // than be absorbed into a pass that cannot see it.
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
        'id': 'derive_${type}_${now}_${++LocalDb._deriveJobSeq}',
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
      final now = LocalDb.nowMs();
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
      return {
        ...row,
        'state': 'running',
        'attempts': ((row['attempts'] as num?)?.toInt() ?? 0) + 1,
        'updated_at': now,
      };
    });
  }

Future<void> _ldbRetryComputeJob(String id, String error, Duration backoff) async {
    final db = await LocalDb.instance;
    final now = LocalDb.nowMs();
    await db.update(
      'compute_jobs',
      {
        'state': 'queued',
        'reason': error,
        'next_run_at': now + backoff.inMilliseconds,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

Future<void> _ldbPutDerivedSessionWrites({required List<(String, double)> hrr, required List<Map<String, dynamic>> suggestions}) async {
    if (hrr.isEmpty && suggestions.isEmpty) return;
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      for (final w in hrr) {
        await txn.update('sessions', {'hrr_bpm': w.$2},
            where: 'id = ?', whereArgs: [w.$1]);
      }
      for (final row in suggestions) {
        await txn.insert('workout_suggestions', row,
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

Future<int> _ldbPruneSupersededIntermediates({required int keepVersions}) async {
    if (keepVersions < 1) return 0;
    final db = await LocalDb.instance;
    var deleted = 0;
    for (final table in const [
      'sleep_session_candidates',
      'wake_day_features',
    ]) {
      final rows = await db.rawQuery(
        'SELECT DISTINCT day_id, algo_version FROM $table',
      );
      final versionsByDay = <String, List<int>>{};
      for (final r in rows) {
        final day = r['day_id'] as String;
        final v = r['algo_version'] as int;
        (versionsByDay[day] ??= <int>[]).add(v);
      }
      // One transaction per table instead of one round-trip per day_id —
      // right after a kAlgoVersion bump forces a bulk re-derive (or a user
      // runs "Re-analyze data"), many days can cross the keepVersions
      // threshold in the same pass, and un-batched deletes on iOS run under
      // the same CPU-watchdog constraint the rest of derivation is careful
      // about.
      await db.transaction((txn) async {
        for (final entry in versionsByDay.entries) {
          final versions = entry.value..sort((a, b) => b.compareTo(a));
          if (versions.length <= keepVersions) continue;
          final cutoff = versions[keepVersions - 1];
          deleted += await txn.delete(
            table,
            where: 'day_id = ? AND algo_version < ?',
            whereArgs: [entry.key, cutoff],
          );
        }
      });
    }
    return deleted;
  }

