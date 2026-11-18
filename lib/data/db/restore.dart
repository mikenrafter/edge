part of '../db.dart';

Future<void> _ldbPurgeDemoRows() async {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      final dayRows = await txn.query(
        'metric_series_version',
        columns: ['date', 'algo_version'],
        where: 'source = ?',
        whereArgs: ['demo'],
      );
      for (final row in dayRows) {
        final date = row['date'] as String;
        await txn.delete(
          'day_result',
          where: 'day_id = ? AND algo_version = ?',
          whereArgs: [date, row['algo_version']],
        );
        await txn.delete('metric_series', where: 'date = ?', whereArgs: [date]);
        await txn.delete(
          'metric_series_version',
          where: 'date = ?',
          whereArgs: [date],
        );
      }
      final sessionRows = await txn.query(
        'sessions',
        columns: ['id'],
        where: 'source = ?',
        whereArgs: ['demo'],
      );
      for (final row in sessionRows) {
        final id = row['id'] as String;
        await txn.delete('sessions', where: 'id = ?', whereArgs: [id]);
        await txn.delete(
          'workout_route',
          where: 'session_id = ?',
          whereArgs: [id],
        );
        await txn.delete(
          'workout_split',
          where: 'session_id = ?',
          whereArgs: [id],
        );
      }
    });
  }

Future<String> _ldbExportCopy({required bool includeSubstrateArchive, required BackupExtras extras, Directory? into, AttachedCopy? attached}) async {
    // File-to-file SQL has one owner. The destination is opened here, never
    // obtained from LocalDb.instance, so dynamic schema copying cannot write
    // derived rows in the live store.
    Future<void> copyAttached(String srcPath, String dest, AttachCopyWhere whereFor) async {
  await deleteDatabase(dest);
  final out = await openDatabase(dest, singleInstance: false);
  try {
    await out.execute('ATTACH DATABASE ? AS src', [srcPath]);
    final schema = await out.rawQuery(
        "SELECT type, name, sql FROM src.sqlite_master WHERE sql IS NOT NULL "
        "AND name NOT LIKE 'sqlite_%' ORDER BY rowid");
    final have = {
      for (final r in await out.rawQuery(
          "SELECT name FROM main.sqlite_master WHERE type = 'table'"))
        r['name'] as String
    };
    // One DEFERRED transaction = one consistent read of the source, and
    // only a read lock on it. sqflite's transaction() is BEGIN IMMEDIATE,
    // which would take the source's write lock too and stall syncing.
    await out.execute('BEGIN');
    for (final r in schema) {
      if (r['type'] != 'table' || have.contains(r['name'])) continue;
      final name = r['name'] as String;
      await out.execute(r['sql'] as String);
      final where = await whereFor(out, name);
      if (where == null) continue;
      await out.execute(
          'INSERT INTO main."$name" SELECT * FROM src."$name"$where');
    }
    final seq = await out.rawQuery(
        "SELECT 1 FROM src.sqlite_master WHERE name = 'sqlite_sequence'");
    if (seq.isNotEmpty) {
      await out.execute('DELETE FROM main.sqlite_sequence');
      await out.execute(
          'INSERT INTO main.sqlite_sequence SELECT * FROM src.sqlite_sequence');
    }
    // Indexes, views and triggers after the rows (a trigger must not fire
    // on the copy).
    for (final type in const ['index', 'view', 'trigger']) {
      for (final r in schema) {
        if (r['type'] == type) await out.execute(r['sql'] as String);
      }
    }
    final v = await out.rawQuery('PRAGMA src.user_version');
    await out.execute('PRAGMA user_version = ${v.first.values.first}');
    await out.execute('COMMIT');
    await out.execute('DETACH DATABASE src');
    await out.close();
  } catch (_) {
    try {
      await out.close();
    } catch (_) {}
    try {
      await deleteDatabase(dest);
    } catch (_) {}
    rethrow;
  }
    }
    if (attached != null) {
      await copyAttached(attached.srcPath, attached.dest, attached.whereFor);
      return attached.dest;
    }

    final db = await LocalDb.instance;
    final tmp = into ?? await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = p.join(tmp.path, 'openstrap_export_$stamp.db');
    final f = File(dest);
    if (await f.exists()) await f.delete(); // VACUUM INTO requires a fresh path
    Database? copy;
    try {
      var archiveCopied = true;
      if (!LocalDb.debugForceAttachExport && await LocalDb._vacuumIntoSupported(db)) {
        await db.execute('VACUUM INTO ?', [dest]);
      } else {
        await copyAttached(db.path, dest, (_, table) async =>
          !includeSubstrateArchive && table == SubstrateArchive.table ? null : '');
        archiveCopied = includeSubstrateArchive;
      }
      if (!includeSubstrateArchive && archiveCopied) {
        copy = await openDatabase(dest, singleInstance: false);
        if (LocalDb.debugFailExportStrip) throw StateError('test: strip failed');
        await copy.delete(SubstrateArchive.table);
        await copy.execute('VACUUM');
        await copy.close();
        copy = null;
      }
      // After the strip (its VACUUM would drop nothing, but order keeps the
      // extras the last thing written) and on the COPY only: the live schema
      // never gains backup_* tables.
      await writeBackupExtras(dest, extras: extras);
    } catch (_) {
      // The caller never learns the path of a failed copy, so nobody else
      // could ever delete it: a full copy of the database left in temp.
      try {
        await copy?.close();
      } catch (_) {}
      try {
        await deleteDatabase(dest);
      } catch (_) {}
      rethrow;
    }
    return dest;
  }

Future<List<Map<String, dynamic>>> _ldbDataHistoryDays() async {
    final db = await LocalDb.instance;
    final rawRows = await db.rawQuery(
      "SELECT strftime('%Y-%m-%d', rec_ts, 'unixepoch', 'localtime') AS day_id, "
      'COUNT(*) AS raw_count, '
      'MIN(rec_ts) AS min_rec_ts, '
      'MAX(rec_ts) AS max_rec_ts '
      'FROM decoded_onehz WHERE rec_ts > 0 AND ${derivableSourceSql()} '
      'GROUP BY day_id ORDER BY day_id DESC',
    );
    final derivedRows = await db.rawQuery(
      'SELECT r.day_id, r.algo_version, r.computed_at, r.finalized '
      'FROM day_result r '
      '${LocalDb._servedDayJoin} '
      'ORDER BY r.day_id DESC',
    );
    final metricRows = await db.rawQuery(
      'SELECT date AS day_id, COUNT(*) AS metric_count '
      'FROM metric_series GROUP BY date',
    );
    final sessionRows = await db.rawQuery(
      "SELECT strftime('%Y-%m-%d', start_ts, 'unixepoch', 'localtime') AS day_id, "
      'COUNT(*) AS session_count '
      'FROM sessions GROUP BY day_id',
    );
    final byDay = <String, Map<String, dynamic>>{};
    Map<String, dynamic> ensure(String dayId) => byDay.putIfAbsent(
      dayId,
      () => {
        'day_id': dayId,
        'raw_count': 0,
        'min_rec_ts': null,
        'max_rec_ts': null,
        'has_derived': false,
        'algo_version': null,
        'computed_at': null,
        'finalized': 0,
        'metric_count': 0,
        'session_count': 0,
      },
    );
    for (final row in rawRows) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      final m = ensure(dayId);
      m['raw_count'] = (row['raw_count'] as num?)?.toInt() ?? 0;
      m['min_rec_ts'] = (row['min_rec_ts'] as num?)?.toInt();
      m['max_rec_ts'] = (row['max_rec_ts'] as num?)?.toInt();
    }
    for (final row in derivedRows) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      final m = ensure(dayId);
      m['has_derived'] = true;
      m['algo_version'] = (row['algo_version'] as num?)?.toInt();
      m['computed_at'] = (row['computed_at'] as num?)?.toInt();
      m['finalized'] = (row['finalized'] as num?)?.toInt() ?? 0;
    }
    for (final row in metricRows) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      ensure(dayId)['metric_count'] =
          (row['metric_count'] as num?)?.toInt() ?? 0;
    }
    for (final row in sessionRows) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      ensure(dayId)['session_count'] =
          (row['session_count'] as num?)?.toInt() ?? 0;
    }
    final out = byDay.values.toList()
      ..sort(
        (a, b) => (b['day_id'] as String).compareTo(a['day_id'] as String),
      );
    return out;
  }

Future<String> _ldbExportDaysDb(Set<String> dayIds) async {
    final sorted = dayIds.toList()..sort();
    if (sorted.isEmpty) {
      throw ArgumentError('No days selected');
    }
    final src = await LocalDb.instance;
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = p.join(tmp.path, 'openstrap_days_$stamp.db');
    await deleteDatabase(dest);
    final out = await openDatabase(
      dest,
      // `version:` is MANDATORY here. Without it sqflite throws
      // ArgumentError('onCreate must be null if no version is specified')
      // before opening anything — so this whole export path (Profile → Data
      // history → Export) had never once produced a file.
      version: LocalDb.schemaVersion,
      onCreate: (db, _) async {
        await LocalDb._createSamples(db);
        await LocalDb._createDecodedStore(db);
        await LocalDb._createSubstrateArchive(db);
        await db.execute('CREATE INDEX idx_samples_ts ON samples(ts)');
        await LocalDb._createEvents(db);
        await LocalDb._createBandSignals(db);
        await LocalDb._createDerived(db);
        await LocalDb._createDayResult(db);
        await LocalDb._createUserTables(db);
        await LocalDb._createSyncState(db);
        await LocalDb._createSyncCursor(db);
        await LocalDb._createComputeState(db);
        await LocalDb._createPrimitiveArtifacts(db);
        await LocalDb._createLiveCoverage(db);
        await LocalDb._createSleepNap(db);
        await ActivityStore.create(db);
        await LocalDb._createSampleArchive(db);
        await LocalDb._createSampleStatus(db);
      },
      // Same additive repair the live DB runs on every open, so the export's
      // tables carry every column the source rows do (sessions.avg_hr etc.).
      onOpen: LocalDb._repairOpenSchema,
    );

    // Every source read on the export path is PAGED on rowid. A day-ranged
    // `SELECT *` over `decoded_onehz` is 86,400 rows, and sqflite materialises
    // a whole result set as Java objects before any of it reaches Dart — the
    // same platform-heap exhaustion that OOMed the import path. Keyset, not
    // OFFSET, so paging stays linear.
    const exportPageSize = 2000;
    const rowidKey = '_rowid';

    /// Streams `table` (optionally filtered) into [out] one page at a time.
    /// The `$rowidKey` cursor column is read off the raw page here and
    /// stripped before the rows are written.
    ///
    /// PAGING COLUMN: rowid, not the filtered column, so one helper serves
    /// every table regardless of what it is filtered on. That means a filtered
    /// page walks the rowid chain and tests the predicate per row rather than
    /// driving off the `rec_ts`/`ts` index. It stays cheap because both factors
    /// are small: `decoded_onehz` is bounded by `rawRetentionDays` (days, not
    /// years — it is pruned behind the data edge), and the never-pruned tables
    /// paged per day here are hundreds to thousands of rows. Measured on a real
    /// 435k-row ledger the worst case — the exhaustion page that scans to the
    /// end of the table — is ~10 ms. Revisit only if retention grows a lot;
    /// per-table cursors would need a composite `(ts, rowid)` key for the
    /// non-unique columns, which is not worth the complexity today.
    Future<void> copyPaged(
      String table, {
      String? where,
      List<Object?> whereArgs = const [],
    }) async {
      var lastRowid = 0;
      while (true) {
        final clause = where == null ? '' : 'AND ($where) ';
        final page = await src.rawQuery(
          'SELECT rowid AS $rowidKey, * FROM $table '
          'WHERE rowid > ? $clause'
          'ORDER BY rowid ASC LIMIT ?',
          [lastRowid, ...whereArgs, exportPageSize],
        );
        if (page.isEmpty) return;
        final clean = [
          for (final row in page)
            <String, Object?>{
              for (final e in row.entries)
                if (e.key != rowidKey) e.key: e.value,
            },
        ];
        await out.transaction((txn) async {
          final batch = txn.batch();
          for (final row in clean) {
            batch.insert(
              table,
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await batch.commit(noResult: true);
        });
        lastRowid = (page.last[rowidKey] as num).toInt();
        if (page.length < exportPageSize) return;
      }
    }

    Future<void> copyRows(
      String table, {
      String? where,
      List<Object?> whereArgs = const [],
    }) => copyPaged(table, where: where, whereArgs: whereArgs);

    Future<void> copyRawRange(int startSec, int endSec) async {
      // Both decoded tables are copied on their own ranges. R-R is NOT pulled
      // through its 1 Hz parents: gen4 R10-lite history banks beats with no
      // parent row, and those seconds would never be exported.
      await copyRows(
        'decoded_onehz',
        where: 'rec_ts >= ? AND rec_ts < ?',
        whereArgs: [startSec, endSec],
      );
      // By hour, on decoded_rr's rec_ts index: a rowid walk filtered on
      // rec_ts would scan the whole table once per exported day, and an hour
      // is a few thousand beats at most — a bounded page without a cursor.
      for (var from = startSec; from < endSec; from += 3600) {
        final to = from + 3600 < endSec ? from + 3600 : endSec;
        final rr = await src.rawQuery(
          'SELECT * FROM decoded_rr WHERE rec_ts >= ? AND rec_ts < ?',
          [from, to],
        );
        if (rr.isEmpty) continue;
        await out.transaction((txn) async {
          final batch = txn.batch();
          for (final row in rr) {
            batch.insert(
              'decoded_rr',
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await batch.commit(noResult: true);
        });
      }
      await copyRows(
        'samples',
        where: 'ts >= ? AND ts < ?',
        whereArgs: [startSec, endSec],
      );
      await copyRows(
        'events',
        where: 'ts >= ? AND ts < ?',
        whereArgs: [startSec, endSec],
      );
      await copyRows(
        'band_events',
        where: 'ts >= ? AND ts < ?',
        whereArgs: [startSec, endSec],
      );
      await copyRows(
        'band_battery',
        where: 'ts >= ? AND ts < ?',
        whereArgs: [startSec, endSec],
      );
      await copyRows(
        'sessions',
        where: 'start_ts >= ? AND start_ts < ?',
        whereArgs: [startSec, endSec],
      );
      // Same midnight rule as deleteDays (shared predicate _hyroxInWindowSql):
      // a race is exported for a day when it starts that day OR one of its
      // segments starts that day or overlaps it, and always whole.
      await copyRows(
        'hyrox_session',
        where: 'id IN ${LocalDb._hyroxInWindowSql}',
        whereArgs: [startSec, endSec, endSec, startSec, startSec, endSec, startSec],
      );
      await copyRows(
        'hyrox_segment',
        where: 'session_id IN ${LocalDb._hyroxInWindowSql}',
        whereArgs: [startSec, endSec, endSec, startSec, startSec, endSec, startSec],
      );
      // Same midnight rule as deleteDays: a race is exported for a day when
      // it starts that day OR one of its segments does, and always whole.
      // An open segment only overlaps later days while the session is still
      // live; a FINALIZED race (incl. an abandoned DNF with an open cut
      // segment) is bounded by COALESCE(session.end_ts, session.start_ts),
      // so it does not match every later day.
      const triInWindow = '(SELECT id FROM triathlon_session '
          'WHERE start_ts >= ? AND start_ts < ? '
          'UNION SELECT session_id FROM triathlon_segment '
          'WHERE start_ts IS NOT NULL AND start_ts < ? '
          'AND ( (end_ts IS NOT NULL AND end_ts > ?) '
          '   OR (end_ts IS NULL AND start_ts < ? '
          '   AND EXISTS (SELECT 1 FROM triathlon_session s '
          '        WHERE s.id = triathlon_segment.session_id '
          '        AND (s.status <> \'finalized\' '
          '             OR COALESCE(s.end_ts, s.start_ts, 0) > ?)))) )';
      await copyRows(
        'triathlon_session',
        where: 'id IN $triInWindow',
        whereArgs: [startSec, endSec, endSec, startSec, endSec, endSec],
      );
      await copyRows(
        'triathlon_segment',
        where: 'session_id IN $triInWindow',
        whereArgs: [startSec, endSec, endSec, startSec, endSec, endSec],
      );
      await copyRows(
        'live_coverage',
        where: 'end_ts > ? AND start_ts < ?',
        whereArgs: [startSec, endSec],
      );
    }

    // A half-written export is never handed back, and never left open.
    try {
      for (final dayId in sorted) {
        final (startSec, endSec) = LocalDb._localDayWindow(dayId);
        await copyRawRange(startSec, endSec);
        await copyRows('day_result', where: 'day_id = ?', whereArgs: [dayId]);
        for (final table in ['sleep_nap', 'activity_suggestions', 'activity_review_days']) {
          await copyRows(table, where: 'day_id = ?', whereArgs: [dayId]);
        }
        await copyRows('metric_series', where: 'date = ?', whereArgs: [dayId]);
        await copyRows(
          'metric_series_version',
          where: 'date = ?',
          whereArgs: [dayId],
        );
        await copyRows('metric_method', where: 'date = ?', whereArgs: [dayId]);
        // What became of each flagged day's alert travels with the day.
        await copyRows('pulse_alert', where: 'day = ?', whereArgs: [dayId]);
        await copyRows('journal', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('journal_metric', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('cycle_log', where: 'date = ?', whereArgs: [dayId]);
        // Track rows ride with their day (the journal totals above already do,
        // and without the timed doses they would restore as untimed remainders).
        await copyRows('track_event', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('track_absence', where: 'date = ?', whereArgs: [dayId]);
        // CLAIM(deleted-day-unknown) [review R3-2]: a selected day's unknown marker
        // travels with it, or a restored pre-delete period would make the
        // deleted day nominal again.
        await copyRows('track_unknown_day', where: 'date = ?', whereArgs: [dayId]);
        // The canonical owners behind track_event_feed rows: medication doses,
        // caffeine moments and meals.
        // The journal remainder's own time (see writeTrackSubstance) travels with
        // its day. ↳ CLAIM(remainder-time)
        await copyRows(
          'wake_meta',
          where: 'key IN (?, ?)',
          whereArgs: [
            'substance_remainder_min:$dayId:caffeine',
            'substance_remainder_min:$dayId:alcohol',
          ],
        );
        await copyRows('med_dose', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('moment_label', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('food_entry', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('notifications', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('sleep_override', where: 'day_id = ?', whereArgs: [dayId]);
        await copyRows('sleep_edit_job', where: 'day_id = ?', whereArgs: [dayId]);
        await copyRows(
          'sleep_session_candidates',
          where: 'day_id = ?',
          whereArgs: [dayId],
        );
        await copyRows(
          'wake_day_features',
          where: 'day_id = ?',
          whereArgs: [dayId],
        );
        // The day's lossy archive (it outlives the raw it was built from) and
        // its outcome ledger.
        await copyRows('spectral_archive', where: 'day_id = ?', whereArgs: [dayId]);
        await copyRows(
          'spectral_archive_status',
          where: 'day_id = ?',
          whereArgs: [dayId],
        );
      }
      // Custom journal field definitions are not day-scoped, so they ride along
      // whole. Without them an exported day carries numbers under keys like
      // `custom_magnesium` with no label, no unit and no idea what scale they
      // are on — the values survive the export and their meaning does not.
      await copyRows('journal_field_def');
      // CLAIM(range-cut): setup periods ride clipped to the selected days (the
      // overrides of the other days stay behind), see track_range_cut.dart.
      final spanning = await src.query(
        'track_setup_history',
        where: 'start_date <= ? AND end_date >= ?',
        whereArgs: [sorted.last, sorted.first],
      );
      await out.transaction((txn) async {
        for (final piece in rangesOnDays([
          for (final row in spanning) TrackSetupRange.fromJson(row),
        ], sorted.toSet(), newId: const RandomRangeIds())) {
          await txn.insert('track_setup_history', piece.toJson());
        }
      });
      // Track definitions are not day-scoped either; events and setup history
      // above refer to them by id.
      await copyRows('track_definition');
      // CLAIM(export-completeness): a selected-day export carries only some
      // days' events, so it cannot vouch for "everything logged since X"; the
      // copied definitions are written as not-confirmed-complete, and an
      // omitted dose reads as unknown rather than as confirmed absence [R2-8;
      // tracks_storage_test].
      // Text rewrite, not a decode: the payload is machine-written JSON and
      // this path must not decode stored payloads.
      final completeFlag = RegExp(r'"logging_complete"\s*:\s*true');
      final completeSince = RegExp(r'"logging_complete_since_ms"\s*:\s*-?\d+');
      for (final row in await out.query('track_definition')) {
        final text = row['payload_json'] as String;
        if (!completeFlag.hasMatch(text)) continue;
        await out.update(
          'track_definition',
          {
            // ↳ CLAIM(export-completeness)
            'payload_json': text
                .replaceAll(completeFlag, '"logging_complete":false')
                .replaceAll(completeSince, '"logging_complete_since_ms":null'),
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
      await copyRows('med_def');
      await copyRows('food_def');
      await copyRows('activity_review_meta');
      // An old day's substrate lives in the archive, not the live tables:
      // exported as archive buckets cut to exactly these days, still
      // compressed, and merged by the ordinary restore on import.
      await SubstrateArchive.copyArchiveInto(src, out, [
        for (final dayId in sorted) LocalDb._localDayWindow(dayId),
      ]);
    } catch (_) {
      await out.close();
      await deleteDatabase(dest);
      rethrow;
    }
    await out.close();
    return dest;
  }

Future<void> _ldbClearDerivedDays(Set<String> dayIds, {int? computedSince}) async {
    final sorted = dayIds.toList()..sort();
    if (sorted.isEmpty) return;
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      // [computedSince]: only the day_result rows this build computed at or
      // after that instant (an import's partial-range derives); rows an import
      // carried in keep their source computed_at, and the other derived tables
      // are left alone.
      for (final (table, column) in computedSince != null
          ? const [('day_result', 'day_id')]
          : const [
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
            '(${List.filled(chunk.length, '?').join(',')})'
            '${computedSince != null ? ' AND computed_at >= ?' : ''}',
            [...chunk, ?computedSince],
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
      // Scratch prefixes can include an evening owned by another day label.
      // Clear every copy atomically with deletion so deleted raw stays deleted.
      await LocalDb._rotateStoreIdentity(txn);
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
        deleted += await txn.delete(
          'wake_evidence',
          where: 'at_sec >= ? AND at_sec < ?',
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
        // HYROX rows are NOT children of `sessions`: their key is the hyrox
        // session id, and a segment's `workout_id` merely points at one.
        // Treating them as session children matched nothing (a privacy leak
        // on delete) and could delete a race segment whose string id collided
        // with a workout id.
        //
        // A race belongs to a day when it STARTS that day, or when one of its
        // segments OVERLAPS it. Overlap is not "starts inside": a segment that
        // began yesterday and is still open, or ends today, was recorded on
        // this day too. An open segment has no end, so it overlaps every later
        // window. Deleting either day takes the WHOLE race — half a race is a
        // record nobody can read.
        //
        // The ids are read first and deleted second: deleting the segments
        // before the parent statement would empty the very subquery the parent
        // delete is built from, which is how a cross-midnight race used to
        // survive its own deletion.
        // An open segment only overlaps later days while the session is still
        // live; a FINALIZED race (incl. an abandoned DNF with an open cut
        // segment) is bounded by COALESCE(session.end_ts, session.start_ts).
        // The predicate is the shared _hyroxInWindowSql so export and delete
        // cannot drift apart.
        final hyroxIds = <String>[
          for (final r in await txn.query(
            'hyrox_session',
            columns: ['id'],
            where: 'id IN ${LocalDb._hyroxInWindowSql}',
            whereArgs: [startSec, endSec, endSec, startSec, startSec, endSec, startSec],
          ))
            r['id'] as String,
        ];
        for (final chunk in LocalDb._sqlVarChunks(hyroxIds)) {
          final marks = List.filled(chunk.length, '?').join(',');
          // Collect the linked workouts BEFORE the segment rows go: a segment
          // deleted with its `sessions` row left behind would orphan the
          // workout's route and splits on a day the user asked to delete.
          final linked = await txn.query(
            'hyrox_segment',
            columns: ['workout_id'],
            where: 'session_id IN ($marks) AND workout_id IS NOT NULL',
            whereArgs: chunk,
          );
          for (final w in linked) {
            final wid = w['workout_id'] as String;
            await txn.delete('workout_route',
                where: 'session_id = ?', whereArgs: [wid]);
            await txn.delete('workout_split',
                where: 'session_id = ?', whereArgs: [wid]);
            await txn.delete('session_sensor',
                where: 'session_id = ?', whereArgs: [wid]);
            await txn.delete('strength_set',
                where: 'session_id = ?', whereArgs: [wid]);
            deleted += await txn.delete('sessions',
                where: 'id = ?', whereArgs: [wid]);
          }
          deleted += await txn.rawDelete(
            'DELETE FROM hyrox_segment WHERE session_id IN ($marks)',
            chunk,
          );
          deleted += await txn.rawDelete(
            'DELETE FROM hyrox_session WHERE id IN ($marks)',
            chunk,
          );
        }
        // Triathlon rows are NOT children of `sessions`: their key is the
        // triathlon session id, and a segment's `workout_id` merely points at
        // one. Treating them as session children matched nothing (a privacy
        // leak on delete) and could delete a race segment whose string id
        // collided with a workout id.
        //
        // A race belongs to a day when it STARTS that day, or when one of its
        // segments OVERLAPS it. Overlap is not "starts inside": a segment that
        // began yesterday and is still open, or ends today, was recorded on
        // this day too. An open segment has no end, so it overlaps every later
        // window. Deleting either day takes the WHOLE race — half a race is a
        // record nobody can read.
        //
        // The ids are read first and deleted second: deleting the segments
        // before the parent statement would empty the very subquery the parent
        // delete is built from, which is how a cross-midnight race used to
        // survive its own deletion.
        // An open segment only overlaps later days while the session is still
        // live; a FINALIZED race (incl. an abandoned DNF with an open cut
        // segment) is bounded by COALESCE(session.end_ts, session.start_ts).
        const triInWindow = '(SELECT id FROM triathlon_session '
            'WHERE start_ts >= ? AND start_ts < ? '
            'UNION SELECT session_id FROM triathlon_segment '
            'WHERE start_ts IS NOT NULL AND start_ts < ? '
            'AND ( (end_ts IS NOT NULL AND end_ts > ?) '
            '   OR (end_ts IS NULL AND start_ts < ? '
            '   AND EXISTS (SELECT 1 FROM triathlon_session s '
            '        WHERE s.id = triathlon_segment.session_id '
            '        AND (s.status <> \'finalized\' '
            '             OR COALESCE(s.end_ts, s.start_ts, 0) > ?)))) )';
        final triIds = <String>[
          for (final r in await txn.query(
            'triathlon_session',
            columns: ['id'],
            where: 'id IN $triInWindow',
            whereArgs: [startSec, endSec, endSec, startSec, endSec, endSec],
          ))
            r['id'] as String,
        ];
        for (final chunk in LocalDb._sqlVarChunks(triIds)) {
          final marks = List.filled(chunk.length, '?').join(',');
          // Collect the linked workouts BEFORE the segment rows go: a segment
          // deleted with its `sessions` row left behind would orphan the
          // workout's route and splits on a day the user asked to delete.
          final linked = await txn.query(
            'triathlon_segment',
            columns: ['workout_id'],
            where: 'session_id IN ($marks) AND workout_id IS NOT NULL',
            whereArgs: chunk,
          );
          for (final w in linked) {
            final wid = w['workout_id'] as String;
            await txn.delete('workout_route',
                where: 'session_id = ?', whereArgs: [wid]);
            await txn.delete('workout_split',
                where: 'session_id = ?', whereArgs: [wid]);
            await txn.delete('session_sensor',
                where: 'session_id = ?', whereArgs: [wid]);
            await txn.delete('strength_set',
                where: 'session_id = ?', whereArgs: [wid]);
            deleted += await txn.delete('sessions',
                where: 'id = ?', whereArgs: [wid]);
          }
          deleted += await txn.rawDelete(
            'DELETE FROM triathlon_segment WHERE session_id IN ($marks)',
            chunk,
          );
          deleted += await txn.rawDelete(
            'DELETE FROM triathlon_session WHERE id IN ($marks)',
            chunk,
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
      // ↳ CLAIM(remainder-time-fresh)
      await deleteByIn(txn, 'wake_meta', 'key', [
        for (final d in sorted) ...[
          'substance_remainder_min:$d:caffeine',
          'substance_remainder_min:$d:alcohol',
        ],
      ]);
      await deleteByIn(txn, 'track_event', 'date', sorted);
      await deleteByIn(txn, 'track_absence', 'date', sorted);
      // CLAIM(deleted-day-unknown) [review R2-2]: with the logs gone, a pledge
      // ("I log every time") or a setup period would read these days as dose 0
      // or nominal. The dates are remembered so learning treats them as unknown.
      for (final day in sorted) {
        await txn.insert(
          'track_unknown_day',
          {'date': day},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      // ↳ CLAIM(range-cut): the deleted days' overrides are gone, so the days
      // leave the setup periods too (unknown, not the nominal dose).
      final cutRows = await txn.query(
        'track_setup_history',
        where: 'start_date <= ? AND end_date >= ?',
        whereArgs: [sorted.last, sorted.first],
      );
      final cutFrom = [for (final row in cutRows) TrackSetupRange.fromJson(row)];
      final cutTo = rangesWithoutDays(cutFrom, sorted.toSet(), newId: const RandomRangeIds());
      // Fresh ids cannot collide, so the pieces go in first with a plain insert
      // (never replace or ignore), then the cut originals go, in this one
      // transaction [review R4-2].
      for (final piece in cutTo) {
        if (cutFrom.contains(piece)) continue;
        await txn.insert('track_setup_history', piece.toJson());
      }
      for (final range in cutFrom) {
        if (cutTo.contains(range)) continue;
        await txn.delete(
          'track_setup_history',
          where: 'id = ?',
          whereArgs: [range.id],
        );
      }
      await deleteByIn(txn, 'track_experiment_day', 'date', sorted);
      // An experiment with no days left would still block its range and hold
      // learning in abstention (review T15).
      await txn.execute(
        'DELETE FROM track_experiment WHERE NOT EXISTS '
        '(SELECT 1 FROM track_experiment_day d WHERE d.experiment_id = track_experiment.id)',
      );
      await deleteByIn(txn, 'track_learning_log', 'date', sorted);
      // CLAIM(learning-keep): rebuildable aggregates (statistics, effects,
      // periods) are dropped with the evidence, but state that cannot be
      // reconstructed once its nights leave the read window survives: the
      // established baseline reference and the wearer's experiment release
      // [R4-4, T3 R3-6; tracks_learning_storage_test]. json_patch drops the
      // null (absent) keys.
      await txn.execute(
        'UPDATE track_learning SET last_step_date = NULL, '
        "state_json = json_patch('{}', json_object("
        "'reference_dose', json_extract(state_json, '\$.reference_dose'), "
        "'experiment_released', json(json_extract(state_json, '\$.experiment_released'))))",
      );
      await txn.execute("DELETE FROM track_learning WHERE state_json = '{}'");
      await deleteByIn(txn, 'cycle_log', 'date', sorted);
      await deleteByIn(txn, 'notifications', 'date', sorted);
      await deleteByIn(txn, 'sleep_session_candidates', 'day_id', sorted);
      await deleteByIn(txn, 'wake_day_features', 'day_id', sorted);
      // Day-keyed USER rows. Same class of leak as workout_route: "delete this
      // day" must not leave the user's own logged health data behind.
      await deleteByIn(txn, 'cycle_symptom', 'date', sorted);
      await deleteByIn(txn, 'workout_suggestions', 'date', sorted);
      await deleteByIn(txn, 'sleep_override', 'day_id', sorted);
      for (final day in sorted) { await SleepEditStore.cancel(txn, day); }
      await deleteByIn(txn, 'wake_confirmation', 'day_id', sorted);
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
      // The lossy archive of the day's 1 Hz health signals (every device, part
      // and codec version) and its outcome ledger: "delete this day" must not
      // leave a readable reconstruction behind.
      await deleteByIn(txn, 'spectral_archive', 'day_id', sorted);
      await deleteByIn(txn, 'spectral_archive_status', 'day_id', sorted);
      // Shadow group payloads of the deleted day (a reimport starts at revision 1).
      await deleteByIn(txn, 'group_row', 'day_id', sorted);
      await deleteByIn(txn, 'day_manifest', 'day_id', sorted);
    });
    // Fence pending Home reads and queued snapshot writes only after commit.
    // The bounded presentation cache is rebuildable, so clear it as a unit.
    // CLAIM(home-cache-reset) [home_cache_day_deletion_test].
    await HomeSnapshotStore.invalidate();
    return deleted;
  }

Future<int> _ldbWipeAll() async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata' "
      "AND name NOT IN ('input_revision', 'input_rev', 'session_ceiling_rev')",
    );
    var deleted = 0;
    await db.transaction((txn) async {
      for (final r in rows) {
        final t = r['name'];
        if (t is String) deleted += await txn.delete(t);
      }
      // Last: the deletes above bump it through the triggers, and its rows
      // name every day the wearer had data, so "Delete everything" empties it
      // too. Every stamp went with the wipe, so restarting at revision 0
      // cannot collide; a pass still in flight is fenced by the wipe epoch
      // ([storeGeneration]), not by these numbers.
      deleted += await txn.delete('input_revision');
      deleted += await txn.delete('input_rev');
      deleted += await txn.delete('session_ceiling_rev');
      await LocalDb._rotateStoreIdentity(txn);
    });
    await LocalDb._markStoreReplaced();
    return deleted;
  }

Future<Set<String>> _ldbForeignFamilyDates({required Iterable<String> ignore}) async {
    final db = await LocalDb.instance;
    final skip = ignore.toList();
    final notIn = skip.isEmpty
        ? ''
        : 'AND device_family NOT IN '
            '(${List.filled(skip.length, '?').join(', ')}) ';
    final rows = await db.rawQuery(
      'SELECT date FROM metric_series_version '
      'WHERE date IS NOT NULL AND device_family IS NOT NULL $notIn'
      'AND device_family <> ('
      '  SELECT device_family FROM metric_series_version '
      '  WHERE device_family IS NOT NULL $notIn'
      'ORDER BY date DESC LIMIT 1'
      ')',
      [...skip, ...skip],
    );
    return {for (final r in rows) r['date'] as String};
  }

Future<ImportSummary> _ldbImportFromDbFile(String path, {required void Function(ImportProgress p)? onProgress}) async {
    if (!await File(path).exists()) {
      throw const FileSystemException('Backup file not found');
    }
    if (await sniffFile(path) != ImportContainer.gzip) {
      return LocalDb._importPlain(path, onProgress);
    }
    onProgress?.call(const ImportPreparing(ImportPrepStep.inflating));
    final work = await Directory.systemTemp.createTemp('openstrap_restore_');
    try {
      final inflated = await inflateGzip(path, work);
      if (inflated == null ||
          await sniffFile(inflated) != ImportContainer.sqlite) {
        throw const ImportFormatException(
          'That file is not an OpenStrap database.',
        );
      }
      return await LocalDb._importPlain(inflated, onProgress);
    } finally {
      // The inflated copy is a full second copy of the database, so it goes
      // whether the import worked or not.
      try {
        if (work.existsSync()) await work.delete(recursive: true);
      } catch (_) {
        /* the OS reclaims the temp dir eventually */
      }
    }
  }

ImportStage _ldbPrivImportStageOf(String table) => switch (table) {
        'journal' ||
        'journal_metric' ||
        'journal_field_def' ||
        'lab_result' ||
        'lab_marker_def' ||
        'strength_set' ||
        'exercise_def' ||
        'food_entry' ||
        'food_def' ||
        'med_def' ||
        'med_dose' ||
        'cycle_log' ||
        'cycle_symptom' ||
        'breathing_session' ||
        'observation' =>
          ImportStage.journal,
        'workout_route' ||
        'workout_split' ||
        'workout_suggestions' ||
        'sessions' ||
        'session_sensor' ||
        'activity_suggestions' ||
        'activity_review_meta' ||
        'activity_review_days' ||
        'external_hr' ||
        'imported_workout' ||
        'imported_measurement' =>
          ImportStage.workouts,
        'sleep_override' || 'sleep_edit_job' || 'sleep_nap' || 'vendor_sleep_epoch' =>
          ImportStage.sleep,
        'samples' ||
        'decoded_onehz' ||
        'spectral_archive' ||
        'spectral_archive_status' =>
          ImportStage.heartRate,
        'decoded_rr' => ImportStage.beats,
        'events' || 'band_events' || 'band_battery' || 'notifications' =>
          ImportStage.events,
        'day_result' ||
        'metric_series' ||
        'metric_series_version' ||
        'metric_method' ||
        'baselines' ||
        'live_coverage' ||
        'step_calibration' ||
        'step_calibration_day' =>
          ImportStage.results,
        'raw_archive' ||
        'substrate_archive' ||
        'ecg_reading' ||
        'ecg_reading_packet' ||
        'ecg_raw_packet' ||
        'ecg_gesture_session' =>
          ImportStage.archive,
        _ => ImportStage.other,
      };

Future<Map<String, int>> _ldbPrivMergeFromDbFile(String path, {required List<String>? only, required bool tolerant, required void Function(ImportProgress p)? onProgress, ImportRun? run}) =>
    LocalDb._withReaderInvalidated(() => _ldbPrivMergeFromDbFileWithReaderHeld(
        path, only: only, tolerant: tolerant, onProgress: onProgress, run: run));

Future<Map<String, int>> _ldbPrivMergeFromDbFileWithReaderHeld(String path, {required List<String>? only, required bool tolerant, required void Function(ImportProgress p)? onProgress, ImportRun? run}) async {
    final committedBefore = LocalDb._mergePagesCommitted;
    try {
      return await LocalDb._mergeFromDbFileBody(path,
          only: only, tolerant: tolerant, onProgress: onProgress, run: run);
    } finally {
      if (LocalDb._mergePagesCommitted != committedBefore) {
        await LocalDb._markStoreReplaced();
      }
    }
  }

Future<Map<String, int>> _ldbPrivMergeFromDbFileBody(String path, {required List<String>? only, required bool tolerant, required void Function(ImportProgress p)? onProgress, ImportRun? run}) async {
    final resetGen = ResetGate.generation;
    var identityCommitted = false;
    Future<void> beforePageCommit(Transaction txn) async {
      if (ResetGate.changedSince(resetGen)) {
        throw StateError('import cancelled by reset');
      }
      if (!identityCommitted) await LocalDb._rotateStoreIdentity(txn);
    }
    void pageCommitted() {
      identityCommitted = true;
      LocalDb._mergePagesCommitted++;
    }

    final perfId = run == null ? 'salvage' : '${run.startedAt}-${run.id}';
    final prepWatch = Stopwatch()..start();
    // One place that reports a preparing step (opening, checking, counting).
    void prep(ImportPrepStep step, [int? done, int? total]) =>
        onProgress?.call(ImportPreparing(step, done, total));
    prep(ImportPrepStep.opening);
    final src = ImportSourceGuard(await openDatabase(path, readOnly: true));
    final db = await LocalDb.instance;
    const tables = LocalDb._restoreTables;
    // D38: where a resumed import starts (table index, rowid inside it).
    final order = only ?? tables;
    final startIdx = run?.startIndex(order) ?? 0;
    final resumed = run?.resumed ?? false;
    const bulkTables = {
      'decoded_onehz',
      'decoded_rr',
      'samples',
      'raw_archive',
      'events',
      'band_events',
      'band_battery',
      'day_result',
      'metric_series',
      'metric_series_version',
      'metric_method',
    };
    // Columns this app's schema actually has, per table — so a row from a NEWER
    // export carrying extra columns this build doesn't know about is filtered
    // down (dropped) instead of throwing "no such column". A column the source
    // LACKS simply isn't in the map → the dest default applies. Forward- and
    // backward-compatible across schema versions.
    Future<Set<String>> destCols(String t) async {
      final info = await db.rawQuery('PRAGMA table_info($t)');
      return {for (final c in info) (c['name'] as String)};
    }

    // The cursor as it stood BEFORE the import: the file's sync_cursor may
    // REPLACE it later. A journaled import records it before any table copies
    // and a resume uses the recorded value; reading the live one then would
    // see the file's cursor and forget the local prune holes.
    int? cursorBeforeImport;
    final recorded = run?.cursorBefore;
    if (recorded != null) {
      cursorBeforeImport = recorded == 'none' ? null : int.tryParse(recorded);
    } else {
      cursorBeforeImport =
          await LocalDb.getCursorInt(LocalDb.kDecodedPrunedBeforeCursor);
      if (run != null) {
        run.cursorBefore = cursorBeforeImport?.toString() ?? 'none';
        await ImportJournal.putMeta({'cursorBefore': run.cursorBefore});
      }
    }
    final counts = <String, int>{};
    // The local sleep assertions as they stand BEFORE any table copies: local
    // wins, and spacing is judged against this frozen set only (never against
    // rows this same import already wrote).
    final sleepPre = order.contains('sleep_nap') || order.contains('sleep_override')
        ? await SleepImportRules.freeze(db)
        : null;
    final sleepNotes = <SleepImportEntry>[];
    // DISTINCT DAYS ACTUALLY WRITTEN — the number the caller reports as
    // "N days imported".
    //
    // `day_result`'s primary key is (day_id, algo_version), so a row count is
    // not a day count: a history that has lived through two algo bumps has two
    // rows for the same day. This used to be a COUNT(DISTINCT day_id) asked of
    // the SOURCE before anything was copied, which over-reported the other way
    // — a re-import where every local row is finalized (all skipped by the
    // protectedKeys guard below) still claimed the full source day count. Stays
    // null when day_result could not be read at all, so the caller can tell
    // "nothing imported" from "we don't know".
    Set<String>? importedDays;
    List<String>? restoredWornOn;
    final localCursors = <String, Object?>{
      for (final r in await db.query('sync_cursor', columns: ['name', 'value']))
        '${r['name']}': r['value'],
    };
    // Days this device already finalized itself, read BEFORE anything merges.
    // The day_result guard below protects their bundle; their series scalars,
    // version stamp and this device's baselines are the same day's history and
    // get the same protection, or trends and the rolling baselines would be
    // rebuilt from the other export's numbers while day detail serves ours.
    prep(ImportPrepStep.checking);
    var finalizedDays = {
      for (final r in await db.query(
        'day_result',
        columns: ['day_id'],
        where: 'finalized = 1',
        distinct: true,
      ))
        '${r['day_id']}',
    };
    if (run != null) {
      // A resume must protect the days that were final BEFORE the import, not
      // the finalized rows this import has landed since (they would make the
      // series scalars of every imported day look locally owned and skip them).
      final saved = run.preFinal;
      if (saved != null) {
        finalizedDays = saved.toSet();
      } else {
        run.preFinal = finalizedDays.toList();
        await ImportJournal.putMeta({'preFinal': run.preFinal!.join(',')});
      }
    }
    // A LOCAL race wins over an OLDER snapshot, but a NEWER backup must be
    // able to advance it (e.g. the final boundaries recorded on another
    // phone). `discarded` is an explicit local decision and always wins.
    // Segments follow their parent's verdict, because they arrive as separate
    // rows and would otherwise rewrite the boundaries of a skipped race.
    final protectedHyrox = <String>{};
    final hyroxLastEdit = <String, int>{};
    // Session ids whose imported hyrox_session row the merge skipped (locally
    // discarded or newer). Their segment rows must be skipped too: segments
    // follow their parent's verdict, and hyrox_session is merged before
    // hyrox_segment in _restoreTables, so the set is complete before the
    // segment pass starts.
    final skippedHyrox = <String>{};
    try {
      // A race arrives as a parent row plus its segment rows, and a replaced
      // parent has its local segments cleared first. A restore cut off between
      // the two leaves a parent with none or only some of its segments; if that
      // parent counted as "local and current" the next restore would skip the
      // segments for good. So a parent only earns the newer-than-snapshot
      // protection once every segment its plan calls for is on disk.
      final haveHyroxSegments = <String, int>{
        for (final r in await db.rawQuery(
          'SELECT session_id, COUNT(*) AS n FROM hyrox_segment '
          'GROUP BY session_id',
        ))
          '${r['session_id']}': (r['n'] as num?)?.toInt() ?? 0,
      };
      Future<int?> plannedHyroxSegments(Object? planJson) async {
        try {
          final j = await JsonPayloadLane.shared.decodeUncached('$planJson');
          final segs = j is Map ? j['segments'] : null;
          return segs is List ? segs.length : null;
        } catch (_) {
          return null;
        }
      }

      for (final r in await db.query(
        'hyrox_session',
        columns: ['id', 'status', 'updated_at', 'finalized_at', 'plan_json'],
        distinct: true,
      )) {
        final id = '${r['id']}';
        // Finalization is one-way: a finalized local race is a record and is
        // never replaced by an import, not even a newer backup's unfinalized
        // copy. Discarded is an explicit local decision and always wins too.
        if (r['status'] == 'discarded' || r['finalized_at'] != null) {
          protectedHyrox.add(id);
        }
        final planned = await plannedHyroxSegments(r['plan_json']);
        if (planned == null || (haveHyroxSegments[id] ?? 0) < planned) {
          continue; // an interrupted import: let the next one finish it
        }
        hyroxLastEdit[id] = (r['updated_at'] as num?)?.toInt() ?? 0;
      }
    } on DatabaseException {
      /* table absent in an older build of this file — nothing to protect */
    }
    // A local race is protected from an import when the athlete explicitly
    // discarded it, or when the local row was edited no earlier than the
    // imported snapshot (a newer backup may still advance the race). [row] is
    // the imported hyrox_session row, null for segment rows.
    bool isHyroxProtected(String id, Map<String, Object?>? row) {
      if (protectedHyrox.contains(id)) return true;
      if (row == null) return false;
      final local = hyroxLastEdit[id];
      if (local == null) return false;
      final theirs = (row['updated_at'] as num?)?.toInt() ?? 0;
      return local >= theirs;
    }
    // A LOCAL race wins over an OLDER snapshot, but a NEWER backup must be
    // able to advance it (e.g. the final boundaries recorded on another
    // phone). `discarded` is an explicit local decision and always wins.
    // Segments follow their parent's verdict, because they arrive as separate
    // rows and would otherwise rewrite the boundaries of a skipped race.
    final protectedTriathlons = <String>{};
    final triLastEdit = <String, int>{};
    final skippedTriathlons = <String>{};
    // A local race is protected from an import when the athlete explicitly
    // discarded it, or when the local row was edited no earlier than the
    // imported snapshot (a newer backup may still advance the race). [row] is
    // the imported triathlon_session row, null for segment rows.
    bool triProtected(String id, Map<String, Object?>? row) {
      if (protectedTriathlons.contains(id)) return true;
      if (row == null) return false;
      final local = triLastEdit[id];
      if (local == null) return false;
      final theirs = (row['updated_at'] as num?)?.toInt() ?? 0;
      return local >= theirs;
    }

    try {
      // A race arrives as a parent row and its segment rows, in separate
      // statements. A restore cut off between the two leaves a parent with
      // none or only some of its segments; if that parent counted as "local
      // and current" the next restore would skip its segments for good. So a
      // parent only earns the newer-than-snapshot protection once every
      // segment its plan calls for is on disk.
      final haveSegments = <String, int>{
        for (final r in await db.rawQuery(
          'SELECT session_id, COUNT(*) AS n FROM triathlon_segment '
          'GROUP BY session_id',
        ))
          '${r['session_id']}': (r['n'] as num?)?.toInt() ?? 0,
      };
      Future<int?> plannedSegments(Object? planJson) async {
        try {
          final j = await JsonPayloadLane.shared.decodeUncached('$planJson');
          final segs = j is Map ? j['segments'] : null;
          return segs is List ? segs.length : null;
        } catch (_) {
          return null;
        }
      }

      for (final r in await db.query(
        'triathlon_session',
        columns: ['id', 'status', 'updated_at', 'plan_json'],
        distinct: true,
      )) {
        final id = '${r['id']}';
        if (r['status'] == 'discarded') {
          protectedTriathlons.add(id);
        }
        final planned = await plannedSegments(r['plan_json']);
        if (planned == null || (haveSegments[id] ?? 0) < planned) {
          continue; // an interrupted import: let the next one finish it
        }
        triLastEdit[id] = (r['updated_at'] as num?)?.toInt() ?? 0;
      }
    } on DatabaseException {
      /* table absent in an older build of this file — nothing to protect */
    }
    var archiveSkipped = run?.archiveSkipped ?? 0;
    final resumedHad = <String>{};
    bool had(String t) => (counts[t] ?? 0) > 0 || resumedHad.contains(t);
    int? archiveEdgeSec;
    var impAttached = false;
    var finalizedDaysSnapshot = false;
    ImportCopyPlan? plan; // set before the first table when [onProgress] is

    String quoteSql(String name) => '"${name.replaceAll('"', '""')}"';
    String sourceColumn(String name) => 's.${quoteSql(name)}';
    String numericSql(String value) =>
        "typeof($value) IN ('integer', 'real')";

    // A resumed day_result table: the days the earlier run already landed.
    Future<void> seedImportedDays(int upToRowid) async {
      try {
        for (final r in await src.rawQuery(
            'SELECT DISTINCT day_id FROM day_result WHERE rowid <= ?',
            [upToRowid])) {
          importedDays?.add('${r['day_id']}');
        }
      } on DatabaseException {
        /* the export lacks day_result */
      }
    }

    // Preserve a copy failure, but never report success when cleanup failed.
    // Each cleanup is attempted even if an earlier one fails (main's contract).
    Future<void> cleanupRestore({bool protectedRows = false,
        bool rrRows = false, bool finalRows = false,
        bool closeSource = false, required bool preserveError}) async {
      Object? firstError;
      StackTrace? firstStack;
      if (protectedRows) {
        try {
          await db.execute('DROP TABLE IF EXISTS temp._restore_protected_day_results');
        } catch (e, st) { firstError ??= e; firstStack ??= st; }
      }
      if (rrRows) {
        try {
          await db.execute('DROP TABLE IF EXISTS temp._restore_rr_src_max');
        } catch (e, st) { firstError ??= e; firstStack ??= st; }
        try {
          await db.execute('DROP TABLE IF EXISTS temp._restore_rr_carried');
        } catch (e, st) { firstError ??= e; firstStack ??= st; }
      }
      if (finalRows) {
        try {
          await db.execute('DROP TABLE IF EXISTS temp._restore_finalized_days');
        } catch (e, st) { firstError ??= e; firstStack ??= st; }
      }
      if (closeSource) {
        try {
          if (impAttached) await db.execute('DETACH DATABASE imp');
        } catch (e, st) { firstError ??= e; firstStack ??= st; }
        try {
          await src.close();
        } catch (e, st) { firstError ??= e; firstStack ??= st; }
      }
      if (!preserveError && firstError != null) {
        Error.throwWithStackTrace(firstError, firstStack!);
      }
    }

    final perfPages = <String, int>{};
    final perfSerialized = <String, int>{};
    Future<bool> mergeBulkTable(String t, int index) async {
      if (!impAttached || !bulkTables.contains(t)) return false;
      final exists = await db.rawQuery(
        "SELECT 1 FROM imp.sqlite_master WHERE type = 'table' AND name = ?",
        [t],
      );
      if (exists.isEmpty) return true;

      if (t == 'day_result') {
        importedDays = <String>{};
        await seedImportedDays(run?.startRowid(index, order) ?? 0);
      }
      final destInfo = await db.rawQuery('PRAGMA main.table_info(${quoteSql(t)})');
      if (destInfo.isEmpty) return false;
      final sourceInfo = await db.rawQuery('PRAGMA imp.table_info(${quoteSql(t)})');
      final destColumns = [
        for (final column in destInfo) column['name'] as String,
      ];
      final sourceColumns = {
        for (final column in sourceInfo) column['name'] as String,
      };
      // Two indexed boundary lookups in one platform call; MIN+MAX as
      // aggregates in one scan would walk the whole source on mobile.
      final bounds = (await db.rawQuery(
          'SELECT (SELECT MIN(rowid) FROM imp.${quoteSql(t)}) AS lo, '
          '(SELECT MAX(rowid) FROM imp.${quoteSql(t)}) AS hi')).single;
      final maxRowid = (bounds['hi'] as num?)?.toInt();
      if (maxRowid == null) {
        counts[t] = 0;
        return true;
      }

      const deviceKeyed = {'samples', 'decoded_onehz', 'decoded_rr'};
      final isDeviceKeyed = deviceKeyed.contains(t);
      final sourceTsMs = sourceColumns.contains('ts_ms')
          ? sourceColumn('ts_ms')
          : 'NULL';
      final sourceDeviceId = sourceColumns.contains('device_id')
          ? sourceColumn('device_id')
          : "'${LocalDb.kPrimaryDeviceId}'";
      final sourceRecTs = sourceColumns.contains('rec_ts')
          ? sourceColumn('rec_ts')
          : 'NULL';
      final sourceRrTsMs = sourceColumns.contains('rr_ts_ms')
          ? sourceColumn('rr_ts_ms')
          : 'NULL';
      final recoveredRecTs = t == 'decoded_rr'
          ? 'CASE WHEN $sourceRecTs IS NULL THEN '
              'CASE WHEN ${numericSql(sourceRrTsMs)} '
              'THEN CAST($sourceRrTsMs AS INTEGER) / 1000 ELSE NULL END '
              'ELSE $sourceRecTs END'
          : sourceRecTs;
      final keyTime = t == 'samples'
          ? (sourceColumns.contains('ts') ? sourceColumn('ts') : 'NULL')
          : t == 'decoded_rr'
              ? recoveredRecTs
              : sourceRecTs;
      final derivedTsMs =
          'CASE WHEN $sourceTsMs IS NULL THEN CAST($keyTime AS INTEGER) * 1000 '
          'ELSE $sourceTsMs END';
      final derivedDeviceId =
          'CASE WHEN $sourceTsMs IS NULL THEN COALESCE($sourceDeviceId, '
          "'${LocalDb.kPrimaryDeviceId}') ELSE $sourceDeviceId END";

      final expressions = <String, String>{};
      for (final column in destColumns) {
        if (sourceColumns.contains(column)) {
          expressions[column] = sourceColumn(column);
        }
      }
      if (t == 'decoded_onehz') {
        if (destColumns.contains('on_wrist')) expressions['on_wrist'] = 'NULL';
        if (destColumns.contains('hr_valid')) expressions['hr_valid'] = 'NULL';
        if (destColumns.contains('skin_temp_c') &&
            sourceColumns.contains('skin_temp_c')) {
          final skinTemp = sourceColumn('skin_temp_c');
          expressions['skin_temp_c'] =
              'CASE WHEN ${numericSql(skinTemp)} AND $skinTemp <= -49.995 '
              'THEN NULL ELSE $skinTemp END';
        }
      }
      if (t == 'decoded_rr' && destColumns.contains('rec_ts')) {
        expressions['rec_ts'] = recoveredRecTs;
      }
      if (isDeviceKeyed && destColumns.contains('device_id')) {
        expressions['device_id'] = derivedDeviceId;
      }
      if (isDeviceKeyed && destColumns.contains('ts_ms')) {
        expressions['ts_ms'] = derivedTsMs;
      }
      final columns = [
        for (final column in destColumns)
          if (expressions.containsKey(column)) column,
      ];
      if (columns.isEmpty) return false;

      final filters = <String>[];
      if (t == 'decoded_rr') {
        // The oracle drops a beat with no rec_ts and no usable rr_ts_ms even
        // when ts_ms is present; letting it through fails NOT NULL for the
        // whole chunk.
        filters.add('NOT ($sourceRecTs IS NULL AND NOT (${numericSql(sourceRrTsMs)}))');
      }
      if (isDeviceKeyed) {
        filters.add('NOT ($sourceTsMs IS NULL AND NOT (${numericSql(keyTime)}))');
      }
      if (t == 'day_result') {
        filters.add('NOT EXISTS (SELECT 1 FROM temp._restore_protected_day_results p '
            'WHERE p.day_id = ${sourceColumn('day_id')} AND '
            'p.algo_version = ${sourceColumn('algo_version')})');
      }
      if (t == 'metric_series' ||
          t == 'metric_series_version' ||
          t == 'metric_method') {
        filters.add('NOT EXISTS (SELECT 1 FROM temp._restore_finalized_days p '
            'WHERE p.day_id = ${sourceColumn('date')})');
      }
      final unbounded = filters.isEmpty ? '1' : filters.join(' AND ');
      final where = ['s.rowid > ?', 's.rowid <= ?', ...filters].join(' AND ');
      final selectSql = 'SELECT ${[
        for (final column in columns)
          '${expressions[column]} AS ${quoteSql(column)}',
      ].join(', ')} FROM imp.${quoteSql(t)} s WHERE $where';
      // Rowid order: when derived keys collide, the later source row wins, as
      // on the per-row path.
      final insertSql = 'INSERT OR REPLACE INTO main.${quoteSql(t)} '
          '(${columns.map(quoteSql).join(', ')}) $selectSql ORDER BY s.rowid';

      // Small enough that a band-sync commit (which must land before the ACK)
      // never waits long behind one, and a salvage loses little to one
      // unreadable chunk.
      final chunkRows = ImportHooks.chunkRows ?? 25000;
      // A table keyed on its own INTEGER column has that column as its rowid,
      // so a row can sit at 0 or below (a zero counter): a walk that starts at
      // `rowid > 0` never reads it, and a table whose highest rowid is 0 was
      // skipped outright. Start just below the lowest rowid when there is one
      // at or under 0; the common case keeps its 0-based chunks.
      final minRowid = (bounds['lo'] as num?)?.toInt();
      final firstLower = minRowid != null && minRowid <= 0
          ? (minRowid == LocalDb._kBelowAnyRowid ? minRowid : minRowid - 1)
          : 0;
      final resumeLower = run?.startRowid(index, order) ?? 0;
      final startLower = resumeLower == 0 ? firstLower : resumeLower;
      var protectedDayResults = false;
      var rrSourceMax = false;
      var copied = 0;
      var copyFailed = true;
      try {
        // Main's row-count boundaries avoid one transaction per empty rowid
        // range. Keep the fork journal's cursor as the committed upper rowid.
        final ends = <int>[];
        for (var lo = firstLower;;) {
          final hi = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT MAX(r) FROM (SELECT rowid AS r FROM imp.${quoteSql(t)} '
            'WHERE rowid > ? ORDER BY rowid LIMIT $chunkRows)', [lo]));
          if (hi == null) break;
          ends.add(hi);
          lo = hi;
        }
        if (t == 'decoded_rr') {
          final rrWatch = Stopwatch()..start();
          var rrPages = 0;
          // The highest beat per second over the WHOLE source, not one chunk:
          // REPLACE renumbers rowids, so one second's beats can straddle
          // chunks out of order, and a per-chunk max would clear beats an
          // earlier chunk just restored.
          await db.execute('DROP TABLE IF EXISTS temp._restore_rr_src_max');
          await db.execute('''CREATE TEMP TABLE _restore_rr_src_max
            (d TEXT, k INTEGER, m INTEGER, PRIMARY KEY (d, k))''');
          rrSourceMax = true;
          // Paged like the copy below, so a band-sync commit can land between
          // pages instead of waiting out a scan of the whole source.
          for (var pageIndex = 0; pageIndex < ends.length; pageIndex++) {
            final lo = pageIndex == 0 ? firstLower : ends[pageIndex - 1];
            final hi = ends[pageIndex];
            rrPages++;
            final rrPageWatch = Stopwatch()..start();
            // REPLACE with a LEFT JOIN rather than an UPSERT: Android 8-10
            // ship a system SQLite older than ON CONFLICT DO UPDATE.
            await db.execute('''INSERT OR REPLACE INTO temp._restore_rr_src_max
                (d, k, m)
              SELECT c.d, c.k, MAX(c.m, COALESCE(x.m, c.m))
              FROM (SELECT $derivedDeviceId AS d, $derivedTsMs AS k,
                      MAX(CAST(${sourceColumn('beat_index')} AS INTEGER)) AS m
                    FROM imp.${quoteSql(t)} s
                    WHERE s.rowid > ? AND s.rowid <= ? AND $unbounded
                      AND ${numericSql(sourceColumn('beat_index'))}
                    GROUP BY 1, 2) c
              LEFT JOIN temp._restore_rr_src_max x ON x.d = c.d AND x.k = c.k''',
                [lo, hi]);
            if (rrPageWatch.elapsedMilliseconds > 2000) {
              ImportPerf.write(perfId, 'chunk', 'table=decoded_rr path=bulk phase=rr_prepare page=$rrPages lo=$lo hi=${lo + chunkRows} ms=${rrPageWatch.elapsedMilliseconds}');
            }
          }
          ImportPerf.write(perfId, 'rr_prepare', 'table=decoded_rr pages=$rrPages ms=${rrWatch.elapsedMilliseconds}');
        }
        var lower = startLower;
        var lastChunkCopied = -1;
        for (final upper in ends.where((end) => end > startLower)) {
          final chunkWatch = Stopwatch()..start();
          final chunkLower = lower;
          final first = lower == startLower;
          final txnWatch = Stopwatch()..start();
          var writeMs = 0, cleanupMs = 0, journalMs = 0, bodyMs = 0;
          await src.mainTransaction(db, (txn) async {
            await beforePageCommit(txn);
            final bodyWatch = Stopwatch()..start();
            if (t == 'day_result' && first) {
              // Inside the first chunk's transaction, so a day the engine
              // finalizes while the restore runs is still protected.
              await txn.execute(
                  'DROP TABLE IF EXISTS temp._restore_protected_day_results');
              await txn.execute(
                  'CREATE TEMP TABLE _restore_protected_day_results AS '
                  'SELECT day_id, algo_version FROM main.day_result '
                  'WHERE finalized = 1');
              protectedDayResults = true;
            }
            if (t == 'day_result') {
              final days = await txn.rawQuery(
                'SELECT DISTINCT ${sourceColumn('day_id')} AS day_id '
                'FROM imp.${quoteSql(t)} s WHERE $where',
                [lower, upper],
              );
              importedDays?.addAll(
                days.map((row) => '${row['day_id']}'),
              );
            }
            // Transitions are bumped once per chunk (the union of the days
            // they reach), not once per row (Sol r2 finding 2). The earliest
            // ts covers a displaced row too: its key is the hex, which names
            // the same event time.
            final spanTable = t == 'events' || t == 'band_events';
            int? spanFrom;
            if (spanTable && sourceColumns.contains('ts')) {
              spanFrom = Sqflite.firstIntValue(await txn.rawQuery(
                  'SELECT MIN(CAST(s.ts AS INTEGER)) FROM imp.${quoteSql(t)} s '
                  'WHERE $where',
                  [lower, upper]));
            }
            if (spanTable) await beginBulkSpans(txn);
            final writeWatch = Stopwatch()..start();
            await txn.execute(insertSql, [lower, upper]);
            writeMs = writeWatch.elapsedMilliseconds;
            final chunkCopied = Sqflite.firstIntValue(
                  await txn.rawQuery('SELECT changes()'),
                ) ??
                0;
            final cleanupWatch = Stopwatch()..start();
            if (spanTable) await endBulkSpans(txn, spanFrom);
            copied += chunkCopied;
            lastChunkCopied = chunkCopied;
            if (t == 'decoded_rr') {
              // Materialised and driven from the chunk's seconds, so the
              // delete walks decoded_rr's (device_id, ts_ms, beat_index) key
              // once per carried second. A correlated EXISTS over the CTE
              // scanned every local beat against every carried second.
              await txn.execute('DROP TABLE IF EXISTS temp._restore_rr_carried');
              await txn.execute('''CREATE TEMP TABLE _restore_rr_carried AS
                SELECT DISTINCT x.d AS d, x.k AS k, x.m AS m
                FROM (SELECT $derivedDeviceId AS d, $derivedTsMs AS k
                      FROM imp.${quoteSql(t)} s WHERE $where) c
                JOIN temp._restore_rr_src_max x ON x.d = c.d AND x.k = c.k''',
                  [lower, upper]);
              await txn.execute('''DELETE FROM main.decoded_rr WHERE rowid IN (
                SELECT r.rowid FROM temp._restore_rr_carried c
                JOIN main.decoded_rr r
                  ON r.device_id = c.d AND r.ts_ms = c.k AND r.beat_index > c.m)''');
              await txn.execute('DROP TABLE temp._restore_rr_carried');
            }
            cleanupMs = cleanupWatch.elapsedMilliseconds;
            final journalWatch = Stopwatch()..start();
            if (run != null) {
              // In the chunk's own transaction: journal == data, always.
              await ImportJournal.advance(txn, run, index, t, upper, chunkCopied);
              final hook = ImportHooks.chunk;
              if (hook != null) {
                await Zone.current.runBinary(
                    hook, txn, ImportChunk(t, lower ~/ chunkRows, lower, upper));
              }
            }
            journalMs = journalWatch.elapsedMilliseconds;
            bodyMs = bodyWatch.elapsedMilliseconds;
          });
          txnWatch.stop();
          perfPages[t] = (perfPages[t] ?? 0) + 1;
          ImportPerf.page(perfId);
          pageCommitted();
          ImportJournal.notify();
          lower = upper;
          if (chunkWatch.elapsedMilliseconds > 2000) {
            ImportPerf.write(perfId, 'chunk', 'table=$t path=bulk lo=$chunkLower hi=$upper page=${perfPages[t]} rows=$lastChunkCopied ms=${chunkWatch.elapsedMilliseconds} write_ms=$writeMs cleanup_ms=$cleanupMs journal_ms=$journalMs txn_ms=${txnWatch.elapsedMilliseconds} body_ms=$bodyMs');
          }
          plan?.advance(t, upper);
        }
        copyFailed = false;
      } finally {
        await cleanupRestore(protectedRows: protectedDayResults,
            rrRows: rrSourceMax, preserveError: copyFailed);
      }
      counts[t] = copied;
      return true;
    }

    // Setup periods merge by coverage (rangesToAdd), not by REPLACE on id: the
    // source rows are read first (never the import source inside the main
    // transaction), the additions are computed against the local rows, and only
    // new rows are written, in one transaction with the journal step.
    Future<int> mergeSetupHistory(String t, int index) async {
      List<Map<String, Object?>> rows;
      try {
        rows = await src.query(t);
      } on DatabaseException catch (e) {
        if (e.isNoSuchTableError()) return 0;
        rethrow;
      }
      final incoming = <TrackSetupRange>[];
      for (final row in rows) {
        try {
          incoming.add(TrackSetupRange.fromJson(row));
        } catch (_) {
          if (!tolerant) rethrow;
        }
      }
      final additions = rangesToAdd(
        local: [
          for (final row in await db.query(t)) TrackSetupRange.fromJson(row),
        ],
        incoming: incoming,
        newId: const RandomRangeIds(),
      );
      await db.transaction((txn) async {
        if (additions.isNotEmpty) await beforePageCommit(txn);
        if (run != null) {
          await ImportJournal.advance(txn, run, index, t, rows.length, additions.length);
        }
        for (final range in additions) {
          await txn.insert(t, range.toJson());
        }
      });
      if (additions.isNotEmpty) pageCommitted();
      plan?.advance(t, rows.length);
      return additions.length;
    }

    var restoreFailed = true;
    try {
      ImportPerf.phase('open_policy', prepWatch, run: perfId);
      final attachWatch = Stopwatch()..start();
      var attachError = 'none';
      if (!LocalDb.debugRowByRowMerge) {
        try {
          // The copy stays in SQLite because row pages crossing the platform
          // channel cost minutes and held the database between band-sync
          // commits, which must land before the ACK.
          await db.execute('ATTACH DATABASE ? AS imp', [path]);
          impAttached = true;
        } on DatabaseException catch (e) {
          attachError = '${e.getResultCode()}';
          impAttached = false;
        }
        ImportPerf.write(perfId, 'attach', 'ok=$impAttached ms=${attachWatch.elapsedMilliseconds} error_code=$attachError');
        if (impAttached) {
          await db.execute('DROP TABLE IF EXISTS temp._restore_finalized_days');
          if (resumed) {
            await db.execute(
                'CREATE TEMP TABLE _restore_finalized_days (day_id TEXT)');
            for (final chunk in LocalDb._sqlVarChunks(finalizedDays.toList())) {
              await db.execute(
                  'INSERT INTO temp._restore_finalized_days (day_id) VALUES '
                  '${List.filled(chunk.length, '(?)').join(',')}',
                  chunk);
            }
          } else {
            await db.execute('CREATE TEMP TABLE _restore_finalized_days AS '
                'SELECT day_id FROM main.day_result WHERE finalized = 1');
          }
          finalizedDaysSnapshot = true;
        }
      }
      if (LocalDb.debugRowByRowMerge) {
        ImportPerf.write(perfId, 'attach', 'ok=false ms=0 error_code=forced_paged');
      }
      final config = <String>[];
      for (final pragma in ['journal_mode', 'synchronous', 'page_size', 'cache_size', 'wal_autocheckpoint', 'temp_store']) {
        final value = (await db.rawQuery('PRAGMA $pragma')).first.values.first;
        config.add('$pragma=$value');
      }
      final sqlite = (await db.rawQuery('SELECT sqlite_version()')).first.values.first;
      ImportPerf.write(perfId, 'config', 'sqlite=$sqlite ${config.join(' ')}');
      if ((only ?? tables).contains(SubstrateArchive.table)) {
        try {
          await SubstrateArchive.adoptPolicy(src, db);
        } catch (_) {
          if (!tolerant) rethrow;
        }
        // The data edge this database will have once the import lands — the
        // one the next housekeeping evicts the archive against.
        int? srcEdge;
        try {
          srcEdge = Sqflite.firstIntValue(
            await src.rawQuery(
              'SELECT MAX(rec_ts) FROM decoded_onehz '
              'WHERE rec_ts > 0 AND $kPrimaryBandSourceSql',
            ),
          );
        } on DatabaseException {
          srcEdge = null;
        }
        final localEdge = await LocalDb.lastDecodedRecTs();
        archiveEdgeSec = localEdge == null
            ? srcEdge
            : (srcEdge == null || localEdge > srcEdge ? localEdge : srcEdge);
      }
      // Rowid sizes up front (O(1) each), so every table reports its place in
      // its stage; see ImportCopyPlan for why stages are runs.
      if (onProgress != null) {
        final sizes = <(String, ImportStage, int)>[];
        final toCount = only ?? tables;
        var counted = 0;
        prep(ImportPrepStep.counting, 0, toCount.length);
        for (final t in toCount) {
          int? max;
          try {
            max = Sqflite.firstIntValue(
              await src.rawQuery('SELECT MAX(rowid) FROM ${quoteSql(t)}'),
            );
          } on DatabaseException catch (e) {
            // A table this export lacks has nothing to report; any other read
            // failure is the copy's to raise, with its own handling.
            if (!e.isNoSuchTableError()) rethrow;
          }
          sizes.add((t, LocalDb._importStageOf(t), max ?? 0));
          prep(ImportPrepStep.counting, ++counted, toCount.length);
        }
        plan = ImportCopyPlan(sizes, onProgress);
      }
      if (resumed && importedDays == null) {
        final dr = order.indexOf('day_result');
        if (dr >= 0 && dr < startIdx) {
          importedDays = <String>{};
          await seedImportedDays(1 << 62);
        }
      }
      ImportPerf.phase('policy_and_sizing', prepWatch, run: perfId);
      // Cancel-all deletes the schedule rows, so an empty table cannot tell
      // "cancelled" from "never set": the marker says which, and a cancelled
      // install keeps it empty. A fresh install has nothing to protect.
      var scheduleCancelled = false;
      if (!(run?.fresh ?? false)) {
        try {
          final sp = await SharedPreferences.getInstance();
          await sp.reload();
          scheduleCancelled = sp.getBool('alarm_schedule_cleared') == true;
        } on Object {
          // No preference store (a bare test host): nothing was cancelled.
        }
      }
      for (var index = startIdx; index < order.length; index++) {
        final t = order[index];
        if (scheduleCancelled && t == 'alarm_schedule') {
          counts[t] = 0;
          continue;
        }
        final tableWatch = Stopwatch()..start();
        var perfPath = impAttached && bulkTables.contains(t) ? 'bulk' : (t == SubstrateArchive.table ? 'archive' : 'paged');
        int? sourceMax;
        try {
          sourceMax = Sqflite.firstIntValue(await src.rawQuery('SELECT MAX(rowid) FROM ${quoteSql(t)}'));
        } on DatabaseException {
          // The normal copy path below decides how a missing/damaged table is handled.
        }
        final chunkSize = perfPath == 'bulk' ? (ImportHooks.chunkRows ?? 25000) : (perfPath == 'archive' ? 8 : 2000);
        ImportPerf.write(perfId, 'table_begin', 'table=$t path=$perfPath source_max_rowid=${sourceMax ?? 0} resume_rowid=${run?.startRowid(index, order) ?? 0} chunk_size=$chunkSize wal_bytes=${await ImportPerf.walBytes(db.path)}');
        // The previous table is complete (a `continue` below skips any
        // end-of-body marker, so it is recorded here, at the next one).
        if (run != null && index > startIdx) {
          await ImportJournal.tableDone(run, index, t,
              archiveSkipped: archiveSkipped);
        }
        try {
          plan?.start(t);
          await ImportHooks.table?.beforeTable(t);
          if (t == 'raw_archive') {
            counts[t] = await LocalDb._mergeRawArchive(src, db,
              beforePageCommit: beforePageCommit,
              onPageCommitted: pageCommitted);
            continue;
          }
          if (await mergeBulkTable(t, index)) continue;
          if (t == 'track_setup_history') {
            // CLAIM(range-restore-coverage) [review R3-1]: never REPLACE by id.
            counts[t] = await mergeSetupHistory(t, index);
            continue;
          }
          perfPath = t == SubstrateArchive.table ? 'archive' : 'paged';
          // PAGED SOURCE READ — never `SELECT *` a whole table.
          //
          // This used to be a single `src.query(t)`. sqflite serialises an entire
          // result set into Java objects on the platform side BEFORE any of it
          // crosses the channel, so importing another device's `decoded_onehz`
          // (86,400 rows per day of history) materialised the whole table on the
          // 256 MB Dalvik heap at once — and then held it live for the duration
          // of the insert loop below. That is the production
          // `java.lang.OutOfMemoryError` seen on 0.9.19 from ImportScreen
          // ("target footprint 268435456, growth limit 268435456"); the OOM
          // surfaced on whichever thread happened to allocate next, which is why
          // it was blamed on a BLE binder callback.
          //
          // Keyset pagination on `rowid` (none of these tables is WITHOUT ROWID),
          // NOT LIMIT/OFFSET — OFFSET re-scans the skipped prefix on every page,
          // which is quadratic over a full history.
          // `_rowid` is aliased into the projection so the cursor can advance;
          // it is filtered straight back out when the row is rebuilt below,
          // because the `cols.contains(e.key)` guard only admits real
          // destination columns and no table has a column by that name.
          // A substrate_archive row is a whole compressed day, so it is paged
          // small, and its blob is NEVER in the page: one oversized row is
          // more than an Android cursor window holds. [restoreRows] reads each
          // blob in chunks instead (see [SubstrateArchive.readBlob]).
          final isArchive = t == SubstrateArchive.table;
          final pageSize = isArchive ? 8 : 2000;
          const rowidKey = '_rowid';
          // Start BELOW any possible rowid, not at 0: a table keyed by an
          // INTEGER PRIMARY KEY of its own (alarm_schedule.weekday, 0 = Monday)
          // has that value as its rowid, and `rowid > 0` never reads row 0.
          // The journal's 0 means "not started in this table".
          final resumeRowid = run?.startRowid(index, order) ?? 0;
          var lastRowid = resumeRowid == 0 ? LocalDb._kBelowAnyRowid : resumeRowid;
          final projection = isArchive
              ? SubstrateArchive.metaColumns.join(', ')
              : '*';
          var sourceQueryMs = 0;
          Future<List<Map<String, Object?>>> nextPage() async {
            final queryWatch = Stopwatch()..start();
            final rows = await src.rawQuery(
              'SELECT rowid AS $rowidKey, $projection FROM $t '
              'WHERE rowid > ? ORDER BY rowid ASC LIMIT ?',
              [lastRowid, pageSize],
            );
            sourceQueryMs += queryWatch.elapsedMilliseconds;
            return rows;
          }

          List<Map<String, Object?>> firstPage;
          try {
            firstPage = await nextPage();
          } on DatabaseException catch (e) {
            // ONLY "this export doesn't carry that table" is skippable. A blanket
            // catch here made every read failure — corruption, a truncated or
            // malformed source file, an I/O error — look identical to an absent
            // table: the table was skipped, `counts[t]` was never set, and the
            // summed total then reported a PARTIAL import as a success. Silent
            // partial success on someone's health history is the worst available
            // outcome, so anything that is not a missing table now propagates.
            if (e.isNoSuchTableError()) continue;
            rethrow;
          }
          if (t == 'day_result') {
            importedDays = <String>{};
            await seedImportedDays(lastRowid);
          }
          if (firstPage.isEmpty) {
            counts[t] = 0;
            continue;
          }
          final cols = await destCols(t);
          if (cols.isEmpty) continue; // table absent in THIS build
          final sourceHasActivityDecisions = (t == 'sleep_nap' || t == 'sessions' || t == 'moment_label') &&
              (await src.query('sqlite_master', columns: ['name'],
                where: "type = 'table' AND name = 'activity_suggestions'"))
                  .isNotEmpty;
          // FINALIZED-DAY PROTECTION: a local day_result row with finalized=1 is
          // LOCKED (this device's own fully-derived history — the long-term
          // system of record). A foreign export merged with REPLACE must never
          // clobber it on a (day_id, algo_version) collision; non-finalized rows
          // keep the plain REPLACE behavior (the import may well be fresher).
          var protectedKeys = const <String>{};
          if (t == 'day_result') {
            final fin = await db.query(
              'day_result',
              columns: ['day_id', 'algo_version'],
              where: 'finalized = 1',
            );
            protectedKeys = {
              for (final r in fin) '${r['day_id']}|${r['algo_version']}',
            };
          }
          // live_coverage is a SUM with no natural key, so a REPLACE on `id`
          // would clobber or double-count local windows. Key on the window.
          String coverageKey(Map<String, Object?> r) =>
              '${r['start_ts']}|${r['end_ts']}|'
              '${r['source'] ?? LocalDb.kStepSourceBand}|'
              '${r['device_id'] ?? LocalDb.kPrimaryDeviceId}';
          final haveCoverage = <String>{
            if (t == 'live_coverage')
              for (final r in await db.query(
                'live_coverage',
                columns: ['start_ts', 'end_ts', 'source', 'device_id'],
              ))
                coverageKey(r),
          };
          // Phone rows are a per-day SNAPSHOT (replacePhoneCoverageForDay), not
          // windows: a backup taken mid-hour holds a partial current-hour row
          // whose key differs from the full hour this device has since written,
          // and same-device phone rows sum. So a day this device already has a
          // phone snapshot for keeps it whole; the backup's only fills days
          // with none.
          final havePhoneDays = <String>{
            if (t == 'live_coverage')
              for (final r in await db.query(
                'live_coverage',
                columns: ['day'],
                where: 'source = ?',
                whereArgs: [LocalDb.kStepSourcePhone],
                distinct: true,
              ))
                '${r['day']}',
          };
          // sleep_user_profile is an accumulator (one fold per finalized
          // night), so the local-wins rule below would let a few local nights
          // throw away a backup's months. The side that folded more nights
          // keeps it; restored nights arrive finalized and never re-fold.
          final localProfileNights = t == 'baselines'
              ? SleepProfilePolicy.foldedDays(
                  (await LocalDb.baseline('sleep_user_profile', executor: db))?['payload_json']
                      as String?,
                ).length
              : 0;
          // Hand-entered rows the user may have edited since the backup was
          // taken. A plain REPLACE handed every colliding key back to the
          // backup's older copy: a rewritten journal note, a corrected lab
          // value or sleep window, a finished workout turned back into the
          // 'live' one a mid-workout backup caught. So the newer side keeps
          // the key; a table with no edit stamp keeps the local row, and a
          // restore only adds what this install has lost.
          //
          // Snapshotted BEFORE the table merges, so a key the backup fills in
          // on page 1 does not read as "local" on page 2.
          final edited = LocalDb._restoreEditedKeys[t];
          final localEdits = <String, int>{};
          String editKey(Map<String, Object?> r) =>
              [for (final c in edited!.$1) '${r[c]}'].join('|');
          if (edited != null) {
            final keys = edited.$1.join(', ');
            final stamp = edited.$2 == null
                ? '0'
                : 'MAX(COALESCE(${edited.$2}, 0))';
            for (final r in await db.rawQuery(
              'SELECT $keys, $stamp AS f FROM $t GROUP BY $keys',
            )) {
              localEdits[editKey(r)] = (r['f'] as num?)?.toInt() ?? 0;
            }
          }
          // Sets already replaced wholesale by a newer backup copy — the
          // local set is cleared once, on the first row, never per page.
          final replacedSets = <String>{};
          var copied = 0;
          var page = firstPage;
          // ONE TRANSACTION PER PAGE, not per table. The whole-table transaction
          // this replaces could only ever commit if the entire table fit in
          // memory first, which is the bug. Per-page commits keep peak residency
          // at one page, and the import stays safe to interrupt or repeat: every
          // write is INSERT OR REPLACE keyed on the row's own identity, so a
          // re-run converges to the same state, and each decoded_onehz row's
          // orphan guard is still queued in the SAME transaction as the row it
          // guards — the invariant that matters is per-row, not per-table.
          while (page.isNotEmpty) {
            final pageWatch = Stopwatch()..start();
            var writeMs = 0, journalMs = 0, bodyMs = 0;
            perfSerialized[t] = (perfSerialized[t] ?? 0) + page.length;
            // A confirmed activity belongs to its review decision even when the
            // user moved its window. Match by that identity, not just overlap.
            // Read only the owners for this page; older backups have no ledger.
            final activityOwners = <String, List<String>>{};
            if (sourceHasActivityDecisions) {
              final kind = t == 'sleep_nap' ? 'nap' : t == 'moment_label' ? 'meal' : 'workout';
              final links = [for (final r in page)
                t == 'sleep_nap' ? '${r['day_id']}:${r['start_ts']}' :
                    t == 'moment_label' ? '${r['date']} ${r['hhmm']}' : r['id'] as String];
              for (final chunk in LocalDb._sqlVarChunks(links)) {
                final owners = await src.query('activity_suggestions',
                  columns: ['id', 'linked_id'],
                  where: "kind = '$kind' AND status = 'confirmed' AND "
                      "linked_id IN (${List.filled(chunk.length, '?').join(',')})",
                  whereArgs: chunk);
                for (final owner in owners) {
                  activityOwners.putIfAbsent(owner['linked_id'] as String, () => [])
                      .add(owner['id'] as String);
                }
              }
            }
            final pageLast = (page.last[rowidKey] as num).toInt();
            // Archive blobs are read HERE, before the transaction opens (see
            // ImportSourceGuard): a second connection's read inside it is
            // SQLITE_BUSY on Android. Per row, so the progress moves.
            final archiveBlobs = <(String, int), Uint8List?>{};
            if (t == SubstrateArchive.table) {
              for (final r in page) {
                final d = r['device_id'], day = r['utc_day'];
                if (d is String && day is int) {
                  archiveBlobs[(d, day)] = await SubstrateArchive.readBlob(src, d, day, perfRun: perfId);
                }
                plan?.advance(t, (r[rowidKey] as num).toInt());
              }
            }
            final txnWatch = Stopwatch()..start();
            await src.mainTransaction(db, (txn) async {
              await beforePageCommit(txn);
              final bodyWatch = Stopwatch()..start();
              final journalWatch = Stopwatch()..start();
              if (run != null) {
                await ImportJournal.advance(
                    txn, run, index, t, pageLast, page.length);
              }
              journalMs = journalWatch.elapsedMilliseconds;
              if (t == SubstrateArchive.table) {
                final archiveWatch = Stopwatch()..start();
                final r = await SubstrateArchive.restoreRows(
                  txn,
                  archiveBlobs,
                  [
                    for (final r in page)
                      {
                        for (final e in r.entries)
                          if (cols.contains(e.key)) e.key: e.value,
                      },
                  ],
                  tolerant: tolerant,
                  dataEdgeSec: archiveEdgeSec,
                  perfRun: perfId,
                );
                copied += r.copied;
                archiveSkipped += r.skipped;
                writeMs = archiveWatch.elapsedMilliseconds;
                bodyMs = bodyWatch.elapsedMilliseconds;
                return;
              }
              // CHUNKED, for the same reason commitSyncBatch chunks: sqflite
              // serialises a whole batch's args into ONE platform message, and
              // the orphan guard below adds an op per decoded_onehz row on top.
              const chunkOps = 4000;
              var batch = txn.batch();
              var ops = 0;
              Future<void> flush() async {
                if (ops == 0) return;
                final batchWatch = Stopwatch()..start();
                await batch.commit(noResult: true);
                writeMs += batchWatch.elapsedMilliseconds;
                batch = txn.batch();
                ops = 0;
              }

              final rows = <Map<String, Object?>>[];
              for (final r in page) {
                final row = <String, Object?>{
                  for (final e in r.entries)
                    if (cols.contains(e.key)) e.key: e.value,
                };
                if (row.isEmpty) continue;
                if (t == 'sleep_edit_job') {
                  // Foreign revision counters never become local identities.
                  // Recreate only unfinished intent against the restored edit.
                  if (row['phase'] != 'done' || row['applied_revision'] != row['revision']) {
                    await SleepEditStore.enqueue(txn, row['day_id'] as String);
                  }
                  copied++;
                  continue;
                }
                if (t == 'sleep_nap' || t == 'sessions' || t == 'moment_label') {
                  var keepLocalDecision = false;
                  final link = t == 'sleep_nap'
                      ? '${row['day_id']}:${row['start_ts']}' : t == 'moment_label'
                          ? '${row['date']} ${row['hhmm']}' : row['id'];
                  final owners = activityOwners[link];
                  for (final chunk in LocalDb._sqlVarChunks(owners ?? <String>[])) {
                    final decided = await txn.query('activity_suggestions',
                      columns: ['id'],
                      where: "status != 'pending' AND "
                          "id IN (${List.filled(chunk.length, '?').join(',')})",
                      whereArgs: chunk, limit: 1);
                    if (decided.isNotEmpty) {
                      keepLocalDecision = true;
                      break;
                    }
                  }
                  if (keepLocalDecision) {
                    // The decision merge below keeps this local answer. Do not
                    // import the losing answer's activity, including after discard.
                    // Recompose any day bundle that the backup may bring back.
                    if (t == 'sleep_nap') {
                      await ActivityStore.markDayChanged(txn, row['day_id'] as String);
                    }
                    continue;
                  }
                }
                if ((t == 'sleep_nap' || t == 'sleep_override') && sleepPre != null) {
                  // LOCAL WINS (owner S7): a differing local row keeps its
                  // columns and payload together, whichever created_at is
                  // newer; identical rows skip silently; refusals are listed.
                  final v = SleepImportRules.judge(t, row, sleepPre);
                  if (v == SleepImportVerdict.refuseConflict ||
                      v == SleepImportVerdict.refuseOverlap) {
                    sleepNotes.add(SleepImportRules.refusal(t, row, v));
                  }
                  if (v != SleepImportVerdict.copy) continue;
                }
                if (edited != null) {
                  final key = editKey(row);
                  final mine = localEdits[key];
                  if (mine != null) {
                    final stamp = edited.$2;
                    final theirs =
                        stamp == null ? null : (row[stamp] as num?)?.toInt();
                    if (theirs == null || theirs <= mine) continue;
                    // The backup's day is newer, and a day's fields are a SET:
                    // patching it row by row would keep a field the backup's
                    // version had already removed.
                    if (t == 'journal_metric' && replacedSets.add(key)) {
                      batch.delete(t, where: 'date = ?', whereArgs: [row['date']]);
                      if (++ops >= chunkOps) await flush();
                    }
                  }
                }
                if (t == 'activity_suggestions') {
                  final local = await txn.query(t, where: 'id = ?', whereArgs: [row['id']], limit: 1);
                  if (local.isNotEmpty && (local.single['status'] != 'pending' ||
                      (row['status'] == 'pending' &&
                       (local.single['updated_at'] as int) >= (row['updated_at'] as int)))) { continue; }
                }
                if (t == 'activity_review_meta') {
                  final local = await txn.query(t, limit: 1);
                  if (local.isNotEmpty) {
                    final old = local.single;
                    final a = old['activated_at'] as int, b = row['activated_at'] as int;
                    row['activated_at'] = a < b ? a : b;
                    row['revision'] = (old['revision'] as int) + (row['revision'] as int) + 1;
                  }
                }

                if (t == 'decoded_onehz') {
                  // A pre-v46 export still carries the retired columns as
                  // VALUES (the disproven on_wrist/hr_valid reads and the
                  // -50.00 °C skin-temp error sentinel). Importing them
                  // verbatim would reinstate exactly the rows the v46
                  // data-retirement cleaned, so the same rule applies at this
                  // boundary — the migration only runs on version bumps and
                  // never sees imported rows.
                  if (cols.contains('on_wrist')) row['on_wrist'] = null;
                  if (cols.contains('hr_valid')) row['hr_valid'] = null;
                  final st = row['skin_temp_c'];
                  if (st is num && st <= -49.995) row['skin_temp_c'] = null;
                }
                // THE PRIMARY DEVICE IS NOT PORTABLE. Its `remote_id` is a
                // per-install handle — a CBPeripheral UUID that is unique to
                // the phone AND the app install on iOS, a rotating RPA on
                // Android — so a foreign export's copy names a peripheral this
                // phone cannot connect to. Importing it would REPLACE the local
                // pairing (id `''` is the primary, permanently) and leave the
                // app claiming a band that is not there. A restore onto the
                // same install needs nothing from here: the row is already
                // present, and the SharedPreferences mirror re-establishes it
                // if the database was rebuilt.
                //
                // HOW the band is worn is the person's, not the install's, and
                // `step_calibration*` (keyed by it) does come across — so the
                // explicit choice rides along onto a local row that has none.
                if (t == 'device' && row['id'] == LocalDb.kPrimaryDeviceId) {
                  final w = row['wearing'];
                  final ts = row['wearing_set_ts'];
                  if (w is num && ts is num) {
                    // No band paired yet (the usual new-phone restore runs at
                    // Welcome, before pairing): nothing to update, so it waits
                    // for the pairing to adopt it.
                    final local = await txn.query('device',
                        columns: ['id'],
                        where: 'id = ?',
                        whereArgs: [LocalDb.kPrimaryDeviceId]);
                    if (local.isEmpty) {
                      restoredWornOn = ['', '${w.toInt()}', '${ts.toInt()}'];
                    } else {
                      batch.rawUpdate(LocalDb._adoptWearingSql,
                          [w.toInt(), ts.toInt(), LocalDb.kPrimaryDeviceId]);
                      if (++ops >= chunkOps) await flush();
                    }
                  }
                  continue;
                }
                // Foreign hardware handles cannot identify a sensor on this phone.
                if (t == 'device') {
                  final local = await txn.query('device', columns: ['id'],
                      where: 'id = ?', whereArgs: [row['id']]);
                  if (local.isNotEmpty) continue;
                  row['remote_id'] = null;
                }
                if (t == 'sync_cursor') {
                  final name = '${row['name']}';
                  // Only a successful restore on THIS install establishes it.
                  if (name == LocalDb._kSettingsImported) continue;
                  if (localCursors.containsKey(name)) {
                    if (name != LocalDb.kDecodedPrunedBeforeCursor) continue;
                    final mine = int.tryParse('${localCursors[name]}');
                    final theirs = int.tryParse('${row['value']}');
                    if (theirs == null || (mine != null && theirs <= mine)) {
                      continue;
                    }
                  }
                }
                if (t == 'hyrox_session' &&
                    isHyroxProtected('${row['id']}', row)) {
                  skippedHyrox.add('${row['id']}');
                  continue; // locally discarded/finalized, or newer than the snapshot
                }
                if (t == 'hyrox_session') {
                  // The session pass runs before the segment pass and FKs are
                  // off: a replaced parent would keep local segment rows the
                  // backup does not carry. Delete them so the restored race
                  // shows exactly the backup's segments. Skipped (protected)
                  // sessions never reach here, so their segments stay protected.
                  // MUST run on the transaction (txn), not db — calling db.*
                  // inside db.transaction deadlocks.
                  await txn.delete(
                    'hyrox_segment',
                    where: 'session_id = ?',
                    whereArgs: ['${row['id']}'],
                  );
                }
                if (t == 'hyrox_segment' &&
                    (isHyroxProtected('${row['session_id']}', null) ||
                        skippedHyrox.contains('${row['session_id']}'))) {
                  continue; // parent skipped — the segments follow its verdict
                }
                if (t == 'triathlon_session' &&
                    triProtected('${row['id']}', row)) {
                  // Locally discarded, or newer than the snapshot. Its
                  // segments are skipped with it: the parent table is merged
                  // first, so the verdict is already known when they arrive.
                  skippedTriathlons.add('${row['id']}');
                  continue;
                }
                if (t == 'triathlon_segment' &&
                    (protectedTriathlons.contains('${row['session_id']}') ||
                        skippedTriathlons.contains('${row['session_id']}'))) {
                  continue;
                }
                if (t == 'day_result') {
                  if (protectedKeys.contains(
                    '${row['day_id']}|${row['algo_version']}',
                  )) {
                    continue; // locally finalized — never overwritten by import
                  }
                  importedDays?.add('${row['day_id']}');
                }
                if ((t == 'metric_series' ||
                        t == 'metric_series_version' ||
                        t == 'metric_method') &&
                    finalizedDays.contains('${row['date']}')) {
                  continue;
                }
                if (t == 'live_coverage') {
                  row.remove('id');
                  if (row['source'] == LocalDb.kStepSourcePhone &&
                      havePhoneDays.contains('${row['day']}')) {
                    continue;
                  }
                  if (!haveCoverage.add(coverageKey(row))) continue;
                }
                // A LEGACY export's decoded_rr carries no rec_ts column; derive
                // it from rr_ts_ms (= rec_ts*1000) so the NOT NULL PK column is
                // always populated. SQLite storage classes are per VALUE, not per
                // column, so a foreign export can hand back a String where
                // INTEGER is declared — a bare `as num` there throws inside the
                // transaction and takes the whole restore down with it. Leave a
                // non-numeric value alone and let the row fail its own NOT NULL
                // check instead of aborting every other row's import.
                if (t == 'decoded_rr' && row['rec_ts'] == null) {
                  final rrTsMs = row['rr_ts_ms'];
                  if (rrTsMs is! num) {
                    // Nothing to key this beat by. Dropping the one row keeps the
                    // rest of the restore alive; letting it through would fail
                    // the NOT NULL check inside the transaction and take every
                    // other row on the page down with it.
                    continue;
                  }
                  row['rec_ts'] = rrTsMs.toInt() ~/ 1000;
                }
                // A PRE-v47 EXPORT CARRIES NO `device_id` / `ts_ms`. Left
                // alone they take the column DEFAULTS — ('', 0) — so every
                // imported row would collide on ONE primary key and REPLACE
                // the whole table down to a single row. Derive the key exactly
                // as [_rekeyTableByDevice] does: the primary band, and the
                // row's own time in ms. AFTER the rec_ts recovery above, which
                // is what decoded_rr's key is built from.
                // NAMED, not sniffed off `ts_ms`: `workout_route` declares that
                // column too and is in the merge list, but it was never re-keyed —
                // it has no `device_id` and no `rec_ts`, so a null `ts_ms` there
                // falls to the `t0 is! num` drop below and the route point vanishes
                // without a word. NOT NULL keeps that unreachable from a database
                // this app wrote; the table NAME is what keeps it unreachable after
                // the next schema change.
                const deviceKeyed = {'samples', 'decoded_onehz', 'decoded_rr'};
                if (deviceKeyed.contains(t) && row['ts_ms'] == null) {
                  row['device_id'] ??= LocalDb.kPrimaryDeviceId;
                  final t0 = row[t == 'samples' ? 'ts' : 'rec_ts'];
                  // Non-numeric (storage classes are per VALUE in a foreign
                  // export) ⇒ drop the one row rather than key it at 0, where
                  // it would REPLACE another row that genuinely belongs there.
                  if (t0 is! num) continue;
                  row['ts_ms'] = t0.toInt() * 1000;
                }
                rows.add(row);
              }
              // REPLACE the beat set for a colliding second, don't patch it.
              // decoded_rr is keyed by (device_id, ts_ms, beat_index), so a
              // row-by-row replace-insert only overwrites the indices the
              // foreign export actually reaches: importing [500] over a local [700, 710, 720]
              // leaves beats 1 and 2 behind and hands that second a spliced
              // foreign/local RR series — silently wrong RMSSD, out of a restore.
              // [_queueDecodedOneHz] guards the identical hazard on the write
              // path with a DELETE ahead of its inserts.
              //
              // Here the delete has to TRAIL the inserts and be bounded by the
              // highest index this page carried, because a second's beats can
              // straddle a page boundary: a leading `DELETE WHERE rec_ts = ?` on
              // page 2 would wipe the beats page 1 just imported. Trailing +
              // bounded is idempotent across the split — page 1 inserts 0,1 and
              // clears >1; page 2 inserts 2,3 and clears >3 — and beat_index is
              // dense by construction, so "everything past the last one" is
              // exactly the stale local tail.
              // v47: keyed on (device_id, ts_ms), the beat's real key — so the
              // tail sweep can only ever clear the WRITING device's stale
              // beats, never the other band's for the same second.
              final highestBeat = <(Object?, Object?), int>{};
              for (final row in rows) {
                // water_moment uses a stable TEXT id, so the generic REPLACE
                // merge is repeatable without collapsing equal clock minutes.
                if (t == 'wake_meta' &&
                    LocalDb._wakeMetaTransientKeys.contains(row['key'])) {
                  continue;
                }
                if (t == 'wake_trace') {
                  // Foreign row IDs are allocation order, never event identity.
                  // Insert directly so another row on this page sees it too.
                  // A local acknowledgement also keeps its local dream answer.
                  if (!LocalDb.wakeJournalKinds.contains(row['kind'])) continue;
                  final ack = row['kind'] == 'ack';
                  final existing = await txn.query(t,
                    columns: ['id'],
                    where: ack
                        ? 'wake_epoch = ? AND kind = ?'
                        : 'wake_epoch = ? AND kind = ? AND at_ms = ? AND data_json = ?',
                    whereArgs: [row['wake_epoch'], row['kind'],
                      if (!ack) ...[row['at_ms'], row['data_json']]],
                    limit: 1);
                  if (existing.isNotEmpty) continue;
                  row.remove('id');
                  await txn.insert(t, row);
                  copied++;
                  continue;
                }
                if (t == 'track_learning_log') {
                  // CLAIM(audit-identity): audit rows merge by what they say
                  // (track, day, field, before, after, reason), never by their
                  // local AUTOINCREMENT id, so a foreign row cannot replace a
                  // local entry and a repeated import adds nothing [S10;
                  // tracks_learning_storage_test].
                  final existing = await txn.query(
                    t,
                    columns: ['id'],
                    where:
                        'track_id = ? AND date = ? AND field = ? AND reason = ? '
                        'AND before_value IS ? AND after_value IS ?',
                    whereArgs: [
                      row['track_id'],
                      row['date'],
                      row['field'],
                      row['reason'],
                      row['before_value'],
                      row['after_value'],
                    ],
                    limit: 1,
                  );
                  if (existing.isNotEmpty) continue;
                  // ↳ CLAIM(audit-identity)
                  row.remove('id');
                  await txn.insert(t, row);
                  copied++;
                  continue;
                }
                if (t == 'spectral_archive') {
                  // Never REPLACE: part numbers are local allocation order, so
                  // a matching key says nothing about matching bytes. Reconcile
                  // by absolute coverage (sample_import.dart).
                  if (await importSamplePart(txn, row)) copied++;
                  continue;
                }
                batch.insert(
                  t,
                  row,
                  // A device with its own finalized history keeps its own
                  // baselines (the frozen movement floor among them).
                  conflictAlgorithm: LocalDb._keepLocalOnImport.contains(t)
                      ? ConflictAlgorithm.ignore
                      : t == 'baselines' &&
                          (row['key'] == 'sleep_user_profile'
                              ? SleepProfilePolicy.foldedDays(
                                          row['payload_json'] as String?)
                                      .length <=
                                  localProfileNights
                              : finalizedDays.isNotEmpty)
                      ? ConflictAlgorithm.ignore
                      : ConflictAlgorithm.replace,
                );
                copied++;
                if (t == 'decoded_rr') {
                  final idx = row['beat_index'];
                  final key = (row['device_id'], row['ts_ms']);
                  if (key.$2 != null && idx is num) {
                    final n = idx.toInt();
                    final prev = highestBeat[key];
                    if (prev == null || n > prev) highestBeat[key] = n;
                  }
                }
                if (++ops >= chunkOps) await flush();
              }
              for (final e in highestBeat.entries) {
                batch.delete(
                  'decoded_rr',
                  where: 'device_id = ? AND ts_ms = ? AND beat_index > ?',
                  whereArgs: [e.key.$1, e.key.$2, e.value],
                );
                if (++ops >= chunkOps) await flush();
              }
              await flush();
              bodyMs = bodyWatch.elapsedMilliseconds;
            });
            txnWatch.stop();
            perfPages[t] = (perfPages[t] ?? 0) + 1;
            ImportPerf.page(perfId);
            if (pageWatch.elapsedMilliseconds > 2000) {
              ImportPerf.write(perfId, 'chunk', 'table=$t path=$perfPath lo=$lastRowid hi=$pageLast page=${perfPages[t]} rows=${page.length} ms=${pageWatch.elapsedMilliseconds} write_ms=$writeMs journal_ms=$journalMs txn_ms=${txnWatch.elapsedMilliseconds} body_ms=$bodyMs source_query_ms=$sourceQueryMs');
            }
            sourceQueryMs = 0;
            pageCommitted();
            // Advance past the last row this page actually delivered. Read the
            // cursor BEFORE dropping the page, and stop on a short page rather
            // than issuing one more query to discover the end.
            lastRowid = pageLast;
            plan?.advance(t, lastRowid);
            if (page.length < pageSize) break;
            page = await nextPage();
          }
          counts[t] = copied;
        } catch (_) {
          // One table's worth of loss, not the whole salvage. A user-initiated
          // restore still rethrows: reporting a partial import as a success is
          // the worst available outcome there, whereas a rebuild has no better
          // file to fall back to.
          if (!tolerant) rethrow;
          counts[t] = 0;
        } finally {
          ImportPerf.write(perfId, 'table_end', 'table=$t path=$perfPath rows=${counts[t] ?? 0} pages=${perfPages[t] ?? 0} serialized_in_rows=${perfSerialized[t] ?? 0} wal_bytes=${await ImportPerf.walBytes(db.path)} ms=${tableWatch.elapsedMilliseconds}');
        }
      }
      ImportPerf.phase('tables', prepWatch, run: perfId);
      plan?.finish();
      if (run != null && order.isNotEmpty) {
        await ImportJournal.tableDone(run, order.length, null,
            archiveSkipped: archiveSkipped);
      }
      if (resumed) {
        // The counts of tables the first run copied are gone with it; ask the
        // source instead, so the follow-up steps below still run for them.
        for (final t in const [
          'workout_suggestions', 'sleep_nap', 'activity_suggestions',
          'day_result', 'ecg_raw_packet', 'ecg_gesture_session',
        ]) {
          try {
            if ((await src.rawQuery('SELECT 1 FROM $t LIMIT 1')).isNotEmpty) {
              resumedHad.add(t);
            }
          } on DatabaseException {
            /* the export lacks that table */
          }
        }
      }
      if (sleepPre != null) {
        try {
          final srcNaps = await src.query('sleep_nap');
          final srcOverrides = await src.query('sleep_override');
          sleepNotes.addAll(SleepImportRules.closePairs(
            srcNaps: srcNaps,
            srcOverrides: srcOverrides,
            pre: sleepPre,
            refused: {
              for (final n in sleepNotes)
                if (n.refused) SleepImportRules.refusedId(n),
            },
          ));
        } on DatabaseException {
          /* the export lacks one of the sleep tables: nothing to list */
        }
      }
      restoreFailed = false;
    } finally {
      await cleanupRestore(protectedRows: impAttached, rrRows: impAttached,
          finalRows: finalizedDaysSnapshot, closeSource: true,
          preserveError: restoreFailed);
    }
    // AFTER every table, sync_cursor included: that table is a plain REPLACE
    // from the source, so a stale `decoded_pruned_before` in the file would
    // otherwise reinstate itself over an earlier lowering. The cursor may not
    // sit above the oldest decoded second actually present.
    final cleanupWatch = Stopwatch()..start();
    // The report outlives the import screen. A resumed run adds to what the
    // interrupted one already listed.
    if (sleepPre != null) {
      await SleepImportReport.save(sleepNotes, unionWithStored: resumed);
    }
    if (order.contains('decoded_onehz') || order.contains('sync_cursor')) {
      // Main keeps the greater edge while copying. The fork must still
      // preserve the ORIGINAL local holes on resume: its edge cannot be
      // clamped to the newest row of an older backup. Only a newly imported
      // claim (no local edge) uses the raw-aware initial clamp.
      final current = await LocalDb.getCursorInt(LocalDb.kDecodedPrunedBeforeCursor);
      final retainedEdge = cursorBeforeImport == null ? null
          : (current != null && current > cursorBeforeImport ? current : cursorBeforeImport);
      await LocalDb._reconcilePrunedCursor(retainedEdge);
    }
    ImportPerf.phase('reconcile_cursor', cleanupWatch, run: perfId);
    if (resumed || counts.values.any((count) => count > 0)) {
      await ActivityStore.suppressImportedAlerts(db);
    }
    ImportPerf.phase('suppress_alerts', cleanupWatch, run: perfId);
    if (had('workout_suggestions')) {
      await db.update('activity_review_meta', {'legacy_migrated': 0});
      await ActivityStore(db).migrateLegacy();
    }
    ImportPerf.phase('migrate_activities', cleanupWatch, run: perfId);
    if (had('sleep_nap') || had('activity_suggestions')) {
      // Imported day bundles may be older than a decision we kept locally.
      // Recompose accepted naps after the merge, in bounded transactions.
      String cursor = '';
      while (true) {
        final days = await db.rawQuery('''SELECT DISTINCT day_id FROM sleep_nap
          WHERE day_id > ? ORDER BY day_id LIMIT 100''', [cursor]);
        if (days.isEmpty) break;
        await db.transaction((tx) async {
          for (final day in days) {
            await ActivityStore.markDayChanged(tx, day['day_id'] as String);
          }
        });
        cursor = days.last['day_id'] as String;
      }
    }
    ImportPerf.phase('review_days', cleanupWatch, run: perfId);
    final wornOn = restoredWornOn;
    if (wornOn != null) {
      final prefs = await SharedPreferences.getInstance();
      // A forgotten band's stash is a choice made on THIS install; it wins.
      if (!prefs.containsKey(LocalDb.kPendingWornOnPref)) {
        await prefs.setStringList(LocalDb.kPendingWornOnPref, wornOn);
      }
    }
    // An import writes day_result rows with a raw batch.insert, deliberately
    // bypassing putDayResult (and therefore the curve-encode seam), so the rows
    // arrive in whatever shape the source device stored — legacy, if it was on
    // an older build. The re-encode walk is forward-only and latches `done`, so
    // once it has finished those rows would never be looked at again and the
    // growth this walk exists to remove would come straight back with the
    // import. Rewind it.
    if (had('day_result')) {
      await LocalDb.putComputeFreshness(LocalDb.kReencodeCursorKey, jsonEncode({}));
    }
    // A resumed nap-edit copy can recompose a kept day without importing it.
    if (had('day_result') || had('sleep_nap')) {
      await LocalDb.deleteComputeFreshness(LocalDb.kNapNextNightCleanupKey);
    }
    // A restored ecg_raw_packet row from an older export has no `origin`
    // and REPLACEs any tagged local copy; re-apply every known gesture
    // interval so gesture contact is never demoted to an ECG packet.
    if (had('ecg_raw_packet') || had('ecg_gesture_session')) {
      await LocalDb._retagAllGesturePackets(db);
    }
    ImportPerf.phase('retag_and_rewind', cleanupWatch, run: perfId);
    // One running experiment per track (review T16): a restored experiment
    // overlapping a local one would send two, possibly opposite, reminders.
    // Unconditional: a resumed import skips tables the first run committed, so
    // the current copy counts say nothing about what is in the table (review
    // R2-10). Idempotent, and cheap on an empty table.
    final droppedExperiments = await _ldbReconcileOverlappingExperiments(db);
    if (droppedExperiments > 0) {
      counts['_track_experiment_overlap_dropped'] = droppedExperiments;
    }
    // Last, so it can never be mistaken for a table row count by anything that
    // walks this map in order.
    final days = importedDays;
    if (days != null) counts['_days'] = days.length;
    // Archive buckets that could not be merged (a codec this build does not
    // know) — kept out of the row counts, never silently.
    if (archiveSkipped > 0) counts['_substrate_archive_skipped'] = archiveSkipped;
    return counts;
  }

/// Keeps, per track, the earliest-created experiment of every overlapping
/// group (ties by id) and deletes the others with their days. Returns how
/// many experiments were dropped.
// CLAIM(one-experiment-per-track): after a restore no two experiments of a
// track overlap [review T16; tracks_experiments_t3_test.dart].
Future<int> _ldbReconcileOverlappingExperiments(DatabaseExecutor db) async {
  final rows = await db.rawQuery(
    'SELECT id, track_id, start_date, end_date FROM track_experiment '
    'ORDER BY created_ms, id',
  );
  final kept = <String, List<Map<String, Object?>>>{};
  var dropped = 0;
  for (final row in rows) {
    final mine = kept.putIfAbsent(row['track_id'] as String, () => []);
    final clash = mine.any(
      (k) =>
          (k['start_date'] as String).compareTo(row['end_date'] as String) <= 0 &&
          (k['end_date'] as String).compareTo(row['start_date'] as String) >= 0,
    );
    if (!clash) {
      mine.add(row);
      continue;
    }
    await db.execute('DELETE FROM track_experiment_day WHERE experiment_id = ?', [row['id']]);
    await db.execute('DELETE FROM track_experiment WHERE id = ?', [row['id']]);
    dropped++;
  }
  return dropped;
  }
