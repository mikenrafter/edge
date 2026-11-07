part of '../db.dart';

Future<String> _ldbExportCopy({
    bool includeSubstrateArchive = true,
    Directory? into,
  }) async {
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
        // Leave the archive out at copy time: copying it only to delete it
        // and VACUUM again needs roughly three times its size in free space,
        // which fails every backup on a nearly full phone.
        await attachCopy(
            db.path,
            dest,
            (_, table) async =>
                !includeSubstrateArchive && table == SubstrateArchive.table
                    ? null
                    : '');
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
        await copyRows('journal', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('journal_metric', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('cycle_log', where: 'date = ?', whereArgs: [dayId]);
        await copyRows('notifications', where: 'date = ?', whereArgs: [dayId]);
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
      }
      // Custom journal field definitions are not day-scoped, so they ride along
      // whole. Without them an exported day carries numbers under keys like
      // `custom_magnesium` with no label, no unit and no idea what scale they
      // are on — the values survive the export and their meaning does not.
      await copyRows('journal_field_def');
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

Future<Set<String>> _ldbForeignFamilyDates({
    Iterable<String> ignore = const [],
  }) async {
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

Future<Map<String, int>> _ldbImportFromDbFile(String path) async {
    if (!await File(path).exists()) {
      throw const FileSystemException('Backup file not found');
    }
    if (await sniffFile(path) != ImportContainer.gzip) {
      return LocalDb._mergeFromDbFile(path);
    }
    final work = await Directory.systemTemp.createTemp('openstrap_restore_');
    try {
      final inflated = await inflateGzip(path, work);
      if (inflated == null ||
          await sniffFile(inflated) != ImportContainer.sqlite) {
        throw const ImportFormatException(
          'That file unpacked to something that is not an OpenStrap database.',
        );
      }
      return await LocalDb._mergeFromDbFile(inflated);
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

Future<int> _ldbMergeRawArchive(Database src, Database db) async {
    var copied = 0;
    Future<void> pageFrom(String table, String hexSql) async {
      if (await LocalDb._objectType(src, table) != 'table') return;
      // Pre-v51 files have no device_id: every row is the primary band's.
      final hasDevice = (await src.rawQuery('PRAGMA table_info($table)'))
          .any((c) => c['name'] == 'device_id');
      final deviceSql =
          hasDevice ? 'device_id' : "'${LocalDb.kPrimaryDeviceId}' AS device_id";
      var after = 0;
      while (true) {
        final page = await src.rawQuery(
          'SELECT rowid AS _r, $deviceSql, $hexSql AS hex, counter, '
          'packet_type, rec_ts, captured_at, reason FROM $table '
          'WHERE rowid > ? ORDER BY rowid LIMIT 500',
          [after],
        );
        if (page.isEmpty) return;
        after = (page.last['_r'] as num).toInt();
        final batch = db.batch();
        for (final r in page) {
          final hex = r['hex'];
          if (hex is! String) continue;
          batch.insert(
            LocalDb.rawArchiveTable,
            LocalDb.rawArchiveRow(
              deviceId: r['device_id'] as String? ?? LocalDb.kPrimaryDeviceId,
              hex: hex,
              counter: (r['counter'] as num?)?.toInt(),
              packetType: (r['packet_type'] as num?)?.toInt() ?? 0,
              recTs: (r['rec_ts'] as num?)?.toInt(),
              capturedAt: (r['captured_at'] as num?)?.toInt() ?? 0,
              reason: r['reason'] as String? ?? 'unknown',
            ),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          copied++;
        }
        await batch.commit(noResult: true);
      }
    }

    await pageFrom('raw_archive', 'hex'); // a table only in older files
    await pageFrom(LocalDb.rawArchiveTable, LocalDb._rawArchiveHexSql);
    await pageFrom(LocalDb._rawArchiveLegacy, 'hex');
    return copied;
  }

Future<Map<String, int>> _ldbMergeFromDbFileImpl(
    String path, {
    List<String>? only,
    bool tolerant = false,
  }) async {
    final db = await LocalDb.instance;
    final src = await openDatabase(path, readOnly: true);
    const tables = LocalDb._restoreTables;
    const bulkTables = {
      'decoded_onehz',
      'decoded_rr',
      'samples',
      // Not raw_archive: it has its own merge (_mergeRawArchive), which keeps
      // the row already on this device instead of replacing it.
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

    final counts = <String, int>{};
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
    // Days this device already finalized itself, read BEFORE anything merges.
    // The day_result guard below protects their bundle; their series scalars,
    // version stamp and this device's baselines are the same day's history and
    // get the same protection, or trends and the rolling baselines would be
    // rebuilt from the other export's numbers while day detail serves ours.
    final finalizedDays = <String>{};
    var archiveSkipped = 0;
    int? archiveEdgeSec;
    var impAttached = false;
    var failed = true;

    // Attempt every cleanup operation. Preserve the original restore error,
    // but surface a cleanup failure when the copy otherwise succeeded.
    Future<void> cleanupRestore({
      List<String> tempTables = const [],
      bool closeSource = false,
      required bool preserveError,
    }) async {
      Object? firstError;
      StackTrace? firstStack;
      Future<void> attempt(Future<void> Function() action) async {
        try {
          await action();
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }

      for (final name in tempTables) {
        await attempt(() => db.execute('DROP TABLE IF EXISTS temp.$name'));
      }
      if (closeSource) {
        if (impAttached) {
          await attempt(() => db.execute('DETACH DATABASE imp'));
        }
        await attempt(src.close);
      }
      final error = firstError;
      if (!preserveError && error != null) {
        Error.throwWithStackTrace(error, firstStack!);
      }
    }

    String quoteSql(String name) => '"${name.replaceAll('"', '""')}"';
    String sourceColumn(String name) => 's.${quoteSql(name)}';
    String numericSql(String value) =>
        "typeof($value) IN ('integer', 'real')";

    Future<bool> mergeBulkTable(String t) async {
      if (!impAttached || !bulkTables.contains(t)) return false;
      final exists = await db.rawQuery(
        "SELECT 1 FROM imp.sqlite_master WHERE type = 'table' AND name = ?",
        [t],
      );
      if (exists.isEmpty) return true;

      if (t == 'day_result') importedDays = <String>{};
      final destInfo = await db.rawQuery('PRAGMA main.table_info(${quoteSql(t)})');
      if (destInfo.isEmpty) return false;
      final sourceInfo = await db.rawQuery('PRAGMA imp.table_info(${quoteSql(t)})');
      final destColumns = [
        for (final column in destInfo) column['name'] as String,
      ];
      final sourceColumns = {
        for (final column in sourceInfo) column['name'] as String,
      };
      final maxRowid = Sqflite.firstIntValue(
        await db.rawQuery('SELECT MAX(rowid) FROM imp.${quoteSql(t)}'),
      );
      if (maxRowid == null || maxRowid <= 0) {
        counts[t] = 0;
        return true;
      }

      if (!sourceColumns.any(destColumns.contains)) return false;

      const deviceKeyed = {'samples', 'decoded_onehz', 'decoded_rr'};
      final isDeviceKeyed = deviceKeyed.contains(t);
      final sourceTsMs = sourceColumns.contains('ts_ms')
          ? sourceColumn('ts_ms')
          : 'NULL';
      final sourceDeviceId = sourceColumns.contains('device_id')
          ? sourceColumn('device_id')
          : 'NULL';
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
        // The oracle compares interpolated strings, before destination
        // affinity can coerce a foreign TEXT version such as '0100' to 100.
        filters.add('NOT EXISTS (SELECT 1 FROM temp._restore_protected_day_results p '
            'WHERE CAST(p.day_id AS TEXT) = CAST(${sourceColumn('day_id')} AS TEXT) AND '
            'CAST(p.algo_version AS TEXT) = CAST(${sourceColumn('algo_version')} AS TEXT))');
      }
      if (t == 'metric_series' ||
          t == 'metric_series_version' ||
          t == 'metric_method') {
        filters.add('NOT EXISTS (SELECT 1 FROM temp._restore_finalized_days p '
            'WHERE CAST(p.day_id AS TEXT) = CAST(${sourceColumn('date')} AS TEXT))');
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
      const chunkRows = 25000;
      var failed = true;
      var copied = 0;
      try {
        // Chunk ends by row count, not fixed rowid ranges: a legacy
        // `rec_ts INTEGER PRIMARY KEY` table has rowids near 1.8e9, which
        // fixed 25k ranges walked as ~70k mostly empty transactions.
        final ends = <int>[];
        for (var lo = 0;;) {
          final hi = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT MAX(r) FROM (SELECT rowid AS r FROM imp.${quoteSql(t)} '
            'WHERE rowid > ? ORDER BY rowid LIMIT $chunkRows)',
            [lo],
          ));
          if (hi == null) break;
          ends.add(hi);
          lo = hi;
        }
        if (t == 'decoded_rr') {
          // The highest beat per second over the WHOLE source, not one chunk:
          // REPLACE renumbers rowids, so one second's beats can straddle
          // chunks out of order, and a per-chunk max would clear beats an
          // earlier chunk just restored.
          // Unlike the oracle's per-2k-page sweep, this also retains an earlier
          // high beat when a later oracle page carries only lower indices.
          await db.execute('DROP TABLE IF EXISTS temp._restore_rr_src_max');
          await db.execute('''CREATE TEMP TABLE _restore_rr_src_max
            (d TEXT, k INTEGER, m INTEGER, PRIMARY KEY (d, k))''');
          // Paged like the copy below, so a band-sync commit can land between
          // pages instead of waiting out a scan of the whole source.
          for (var i = 0; i < ends.length; i++) {
            // REPLACE with a LEFT JOIN rather than an UPSERT: Android 8-10
            // ship a system SQLite older than ON CONFLICT DO UPDATE.
            // GROUP BY ordinals, not d/k: a source column of the same name
            // would win over the alias.
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
                [i == 0 ? 0 : ends[i - 1], ends[i]]);
          }
        }
        var lower = 0;
        for (final upper in ends) {
          final first = lower == 0;
          await db.transaction((txn) async {
            if (t == 'day_result' && first) {
              // Inside the first chunk's transaction, so a day the engine
              // finalizes while the restore runs is still protected.
              await txn.execute(
                  'DROP TABLE IF EXISTS temp._restore_protected_day_results');
              await txn.execute(
                  'CREATE TEMP TABLE _restore_protected_day_results AS '
                  'SELECT day_id, algo_version FROM main.day_result '
                  'WHERE finalized = 1');
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
            await txn.execute(insertSql, [lower, upper]);
            copied += Sqflite.firstIntValue(
                  await txn.rawQuery('SELECT changes()'),
                ) ??
                0;
            if (t == 'decoded_rr') {
              // Materialised and driven from the chunk's seconds, so the
              // delete walks decoded_rr's (device_id, ts_ms, beat_index) key
              // once per carried second. A correlated EXISTS over the CTE
              // scanned every local beat against every carried second.
              await txn.execute('DROP TABLE IF EXISTS temp._restore_rr_carried');
              await txn.execute('''CREATE TEMP TABLE _restore_rr_carried AS
                SELECT DISTINCT x.d AS d, x.k AS k, x.m AS m
                FROM (SELECT $derivedDeviceId AS d, $derivedTsMs AS k
                      FROM imp.${quoteSql(t)} s WHERE $where
                        AND ${numericSql(sourceColumn('beat_index'))}) c
                JOIN temp._restore_rr_src_max x ON x.d = c.d AND x.k = c.k''',
                  [lower, upper]);
              await txn.execute('''DELETE FROM main.decoded_rr WHERE rowid IN (
                SELECT r.rowid FROM temp._restore_rr_carried c
                JOIN main.decoded_rr r
                  ON r.device_id = c.d AND r.ts_ms = c.k AND r.beat_index > c.m)''');
              await txn.execute('DROP TABLE temp._restore_rr_carried');
            }
          });
          lower = upper;
        }
        failed = false;
      } finally {
        await cleanupRestore(
          tempTables: [
            if (t == 'day_result') '_restore_protected_day_results',
            if (t == 'decoded_rr') ...[
              '_restore_rr_carried', '_restore_rr_src_max',
            ],
          ],
          preserveError: failed,
        );
      }
      counts[t] = copied;
      return true;
    }

    try {
      if (!LocalDb.debugRowByRowMerge) {
        try {
          await db.execute('ATTACH DATABASE ? AS imp', [path]);
          impAttached = true;
        } on DatabaseException {
          // A damaged-file salvage can still try the per-row reader. A public
          // restore must propagate its failure instead of claiming success.
          if (!tolerant) rethrow;
        }
      }
      await db.transaction((txn) async {
        finalizedDays.addAll({
          for (final r in await txn.query(
            'day_result',
            columns: ['day_id'],
            where: 'finalized = 1',
            distinct: true,
          ))
            '${r['day_id']}',
        });
        if (impAttached) {
          await txn.execute('DROP TABLE IF EXISTS temp._restore_finalized_days');
          await txn.execute('CREATE TEMP TABLE _restore_finalized_days AS '
              'SELECT day_id FROM main.day_result WHERE finalized = 1');
        }
      });
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
      for (final t in (only ?? tables)) {
        if (t == 'raw_archive') {
          try {
            counts[t] = await LocalDb._mergeRawArchive(src, db);
          } catch (_) {
            if (!tolerant) rethrow;
            counts[t] = 0;
          }
          continue;
        }
        try {
          if (await mergeBulkTable(t)) continue;
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
          var lastRowid = 0;
          final projection = isArchive
              ? SubstrateArchive.metaColumns.join(', ')
              : '*';
          Future<List<Map<String, Object?>>> nextPage() => src.rawQuery(
            'SELECT rowid AS $rowidKey, $projection FROM $t '
            'WHERE rowid > ? ORDER BY rowid ASC LIMIT ?',
            [lastRowid, pageSize],
          );

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
          if (t == 'day_result') importedDays = <String>{};
          if (firstPage.isEmpty) {
            counts[t] = 0;
            continue;
          }
          final cols = await destCols(t);
          if (cols.isEmpty) continue; // table absent in THIS build
          final sourceHasActivityDecisions = (t == 'sleep_nap' || t == 'sessions') &&
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
          // sync_cursor is this install's own bookkeeping, so a row it already
          // has wins. A backup's older copy would otherwise lower the prune edge
          // (which is only ever raised): the derive engine would then stop
          // treating a restored day whose rows end at the backup moment as
          // truncated, and overwrite its finalized full-day result from that
          // partial substrate. The prune edge takes the higher of the two;
          // every other key the backup has that this install lacks still comes
          // across, which is what a restore onto a new phone needs.
          final localCursors = <String, String?>{
            if (t == 'sync_cursor')
              for (final r in await db.query(
                'sync_cursor',
                columns: ['name', 'value'],
              ))
                '${r['name']}': r['value'] as String?,
          };
          // sleep_user_profile is an accumulator (one fold per finalized
          // night), so the local-wins rule below would let a few local nights
          // throw away a backup's months. The side that folded more nights
          // keeps it; restored nights arrive finalized and never re-fold.
          final localProfileNights = t == 'baselines'
              ? SleepProfilePolicy.foldedDays(
                  (await LocalDb.baseline('sleep_user_profile'))?['payload_json']
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
            // A confirmed activity belongs to its review decision even when the
            // user moved its window. Match by that identity, not just overlap.
            // Read only the owners for this page; older backups have no ledger.
            final activityOwners = <String, List<String>>{};
            if (sourceHasActivityDecisions) {
              final kind = t == 'sleep_nap' ? 'nap' : 'workout';
              final links = [for (final r in page)
                t == 'sleep_nap' ? '${r['day_id']}:${r['start_ts']}' : r['id'] as String];
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
            await db.transaction((txn) async {
              if (t == SubstrateArchive.table) {
                final r = await SubstrateArchive.restoreRows(
                  txn,
                  src,
                  [
                    for (final r in page)
                      {
                        for (final e in r.entries)
                          if (cols.contains(e.key)) e.key: e.value,
                      },
                  ],
                  tolerant: tolerant,
                  dataEdgeSec: archiveEdgeSec,
                );
                copied += r.copied;
                archiveSkipped += r.skipped;
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
                await batch.commit(noResult: true);
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
                if (t == 'sleep_nap' || t == 'sessions') {
                  var keepLocalDecision = false;
                  final link = t == 'sleep_nap'
                      ? '${row['day_id']}:${row['start_ts']}' : row['id'];
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
                if (t == 'sleep_nap') {
                  final local = await txn.query('sleep_nap',
                    where: 'start_ts < ? AND end_ts > ? AND created_at >= ?',
                    whereArgs: [row['end_ts'], row['start_ts'], row['created_at']]);
                  // A newer local correction has already answered this window.
                  if (local.isNotEmpty) continue;
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
                // A SENSOR'S HANDLE IS NOT PORTABLE EITHER, for the same
                // reason, but its row is: it names the `device_id` its
                // history carries. So the row comes across WITHOUT the
                // `remote_id`. Kept verbatim, it would never connect, and
                // because a sensor's id is minted from that handle
                // (`HrsLink.mintDeviceId`) re-pairing the same strap here
                // writes a NEW row instead of overwriting it — two such rows
                // filled the sensor cap and refused every pair until each was
                // forgotten by hand. Every link already refuses to arm a row
                // with no handle, and `sensorCapReached` does not count one.
                // A row this phone already has is its own live pairing and
                // stays untouched: replacing it would blank a working handle.
                if (t == 'device') {
                  final local = await txn.query('device',
                      columns: ['id'], where: 'id = ?', whereArgs: [row['id']]);
                  if (local.isNotEmpty) continue;
                  row['remote_id'] = null;
                }
                if (t == 'sync_cursor') {
                  final name = '${row['name']}';
                  if (localCursors.containsKey(name)) {
                    if (name != LocalDb.kDecodedPrunedBeforeCursor) continue;
                    final mine = int.tryParse('${localCursors[name]}');
                    final theirs = int.tryParse('${row['value']}');
                    if (theirs == null || (mine != null && theirs <= mine)) {
                      continue;
                    }
                  }
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
                batch.insert(
                  t,
                  row,
                  // A device with its own finalized history keeps its own
                  // baselines (the frozen movement floor among them).
                  conflictAlgorithm: t == 'baselines' &&
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
            });
            // Advance past the last row this page actually delivered. Read the
            // cursor BEFORE dropping the page, and stop on a short page rather
            // than issuing one more query to discover the end.
            lastRowid = (page.last[rowidKey] as num).toInt();
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
        }
      }
      failed = false;
    } finally {
      await cleanupRestore(
        tempTables: impAttached ? [
          '_restore_rr_carried', '_restore_rr_src_max',
          '_restore_protected_day_results', '_restore_finalized_days',
        ] : const [],
        closeSource: true,
        preserveError: failed,
      );
    }
    if (counts.values.any((count) => count > 0)) {
      await ActivityStore.suppressImportedAlerts(db);
    }
    if ((counts['workout_suggestions'] ?? 0) > 0) {
      await db.update('activity_review_meta', {'legacy_migrated': 0});
      await ActivityStore(db).migrateLegacy();
    }
    if ((counts['sleep_nap'] ?? 0) > 0 || (counts['activity_suggestions'] ?? 0) > 0) {
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
    if ((counts['day_result'] ?? 0) > 0) {
      await LocalDb.putComputeFreshness(LocalDb.kReencodeCursorKey, jsonEncode({}));
    }
    // Same for the raw-free nap cleanup: imported old days, or legacy nap
    // edits recomposed into kept days, may carry the next-night nap double
    // count it removes, so it runs again.
    if ((counts['day_result'] ?? 0) > 0 || (counts['sleep_nap'] ?? 0) > 0) {
      await LocalDb.deleteComputeFreshness(LocalDb.kNapNextNightCleanupKey);
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
    final decodedOneHz = count;
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

Future<Map<String, dynamic>?> _ldbSyncLedgerSummary([
    String chunkId = 'capture',
  ]) async {
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

Future<List<Map<String, dynamic>>> _ldbRecentDayDiagnostics(
    int limit,
  ) async {
    final rows = await LocalDb.recentDayResults(limit);
    final rawByDay = await LocalDb.decodedRecTsMaxByDay();
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      final decoded =
          SeriesCodec.decodePayloadJson(row['payload_json']) ??
          const <String, dynamic>{};
      final scalars = ((decoded['scalars'] as Map?) ?? const {})
          .cast<String, dynamic>();
      final dayId = row['day_id'] as String? ?? '';
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
    return out;
  }
