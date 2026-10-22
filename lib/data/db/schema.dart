part of '../db.dart';

Future<Database> _ldbPrivOpenOrRebuild() async {
    try {
      return await LocalDb._open();
    } catch (e) {
      final dir = await getDatabasesPath();
      final path = p.join(dir, LocalDb.dbName);
      // A UNIQUE quarantine name every time. A fixed one would let a SECOND
      // rebuild overwrite the first rebuild's file — the one holding whatever
      // the tolerant salvage could not read — which is the one outcome this
      // whole path exists to prevent. Disk is the cheaper thing to spend here.
      final quarantine = p.join(
        dir,
        '${LocalDb.dbName}.unopenable-${DateTime.now().millisecondsSinceEpoch}',
      );
      // The -wal/-shm siblings belong to the file being moved. Leaving them
      // beside a FRESH database of the same name hands that database someone
      // else's journal, which is how a recovery corrupts the thing it just
      // created. All three move together or none of them do — a rebuild that
      // cannot quarantine cleanly must fail loudly rather than half-destroy.
      final moved = <String>[];
      for (final suffix in const ['', '-wal', '-shm']) {
        final f = File('$path$suffix');
        if (!f.existsSync()) continue;
        await f.rename('$quarantine$suffix');
        moved.add(suffix);
      }
      final Database fresh;
      try {
        fresh = await LocalDb._open();
      } catch (_) {
        // A FRESH database at the current schema will not open either, so this
        // is not something a rebuild fixes. Put the user's file back exactly
        // where it was — leaving them with the quarantine and no database is
        // strictly worse than leaving them where they started.
        for (final suffix in moved) {
          await File('$quarantine$suffix').rename('$path$suffix');
        }
        rethrow;
      }
      // Published BEFORE the salvage so `_mergeFromDbFile`'s own `instance`
      // resolves to the new file instead of re-entering this method.
      LocalDb._db = fresh;
      // A rebuild replaces the store by itself, whether or not the salvage that
      // follows commits a page (it may not even open its source). Marking here
      // makes the transition differ from [generationAfterFirstOpen]'s plain
      // first-open prediction, so a cache cannot mistake a rebuild for the
      // ordinary open it was waiting for.
      LocalDb._markStoreReplaced();
      var salvaged = const <String, int>{};
      try {
        // `_`-prefixed keys (`_days`, `_substrate_archive_skipped`) are the
        // importer's bookkeeping, not tables. The rebuild card prints this map
        // verbatim, so it read "Recovered: … _days 312 …" as though a table by
        // that name had survived — or "Empty: _days" as though one had been
        // lost. Drop them here; the card is the one surface whose whole job is
        // telling the truth about a data-loss event.
        salvaged = Map.of(
          await LocalDb._mergeFromDbFile(
            quarantine,
            only: LocalDb._salvageTables,
            tolerant: true,
          ),
        )..removeWhere((k, _) => k.startsWith('_'));
      } catch (_) {
        // The quarantined file gave us nothing. The app still opens, and the
        // file is still there — that is the whole point of not deleting it.
      }
      LocalDb.lastRebuild = (
        cause: '$e',
        quarantinePath: quarantine,
        salvaged: salvaged,
      );
      return fresh;
    }
  }

Future<Database?> _ldbPrivOpenReader(Database writer) async {
    final path = writer.path;
    if (path == inMemoryDatabasePath || path == ':memory:') return null;
    final epoch = LocalDb._wipeEpoch;
    await LocalDb._closeReader();
    Database? opened;
    try {
      opened =
          await (LocalDb.readerOpenerForTest?.call(path) ??
              openDatabase(
                path,
                readOnly: false,
                singleInstance: false,
                onConfigure: (db) async {
                  await db.rawQuery('PRAGMA query_only=ON');
                  // A WAL reader can still meet SQLITE_BUSY briefly (wal-index
                  // recovery, checkpoint restart); wait instead of failing the
                  // screen read. rawQuery: the pragma returns a row.
                  await db.rawQuery('PRAGMA busy_timeout=2000');
                  try {
                    // Per-connection and cold: without it hot pages are re-read
                    // from disk on every screen open (default cache ~2 MB).
                    await db.execute('PRAGMA cache_size=-16000');
                  } catch (_) {}
                },
              ));
      // Without WAL the writer's lock would block this connection outright.
      final mode = await opened.rawQuery('PRAGMA journal_mode');
      if ('${mode.first.values.first}'.toLowerCase() != 'wal') {
        throw StateError('not WAL');
      }
      // The store moved on (closed, replaced) while this was opening.
      if (!identical(LocalDb._db, writer) || epoch != LocalDb._wipeEpoch) {
        throw StateError('store changed');
      }
    } catch (_) {
      final o = opened;
      if (o != null) {
        try {
          await o.close();
        } catch (_) {}
      }
      LocalDb._readerFailedFor = writer;
      LocalDb._readerFailedEpoch = epoch;
      return null;
    }
    // Backgrounded while this was opening: not a failure (a later foreground
    // may open one), so do not mark it failed, and do not keep the handle.
    if (!LocalDb._foreground) {
      try {
        await opened.close();
      } catch (_) {}
      return null;
    }
    LocalDb._readDb = opened;
    LocalDb._readerBeside = writer;
    return opened;
  }

Future<T?> _ldbPrivGuardedWrite<T>(Future<T> Function(Database db) op, {required bool bestEffort}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      Database? handle;
      try {
        handle = await LocalDb.instance;
        return await op(handle);
      } on DatabaseException catch (e) {
        final closed =
            e.toString().contains('closed') || !(handle?.isOpen ?? false);
        if (closed && attempt == 0) {
          // Drop only the dead handle we actually used. A concurrent caller may
          // have already reopened `_db` to a fresh handle between our failure
          // and here — keep that one so `instance` reuses it on the retry
          // instead of forcing a redundant reopen.
          if (identical(LocalDb._db, handle)) LocalDb._db = null;
          continue;
        }
        if (bestEffort && closed) return null;
        rethrow;
      }
    }
    return null;
  }

Future<Database> _ldbPrivOpen() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, LocalDb.dbName);
    final opened = await openDatabase(
      path,
      onConfigure: (db) async {
        // WRITE PERFORMANCE. The default rollback journal (journal_mode=delete)
        // with synchronous=FULL fsyncs the whole DB on every commit — brutal for
        // the high-volume sync-ingest and the raw re-decode migration on a large
        // ledger. WAL + synchronous=NORMAL is the standard mobile config: writers
        // append to a -wal file and don't block readers, with one fsync per
        // checkpoint instead of per commit. journal_mode is persistent per-file;
        // synchronous/cache_size are per-connection so we set them every open.
        // Durability trade-off under NORMAL: a crash/power-loss can lose only the
        // last uncheckpointed transactions, never corrupt the DB — fine here since
        // raw is re-syncable from the band and derived is recomputable.
        //
        // CRITICAL: a perf PRAGMA must NEVER prevent the DB from opening (a throw
        // here fails openDatabase → the app is stuck on the loading screen). And
        // `PRAGMA journal_mode=WAL` RETURNS A ROW ("wal"), so on the iOS sqflite
        // Darwin backend it MUST be issued via rawQuery — `execute()` on a
        // value-returning pragma throws DatabaseException("not an error") and
        // bricks the open (confirmed on device). So: rawQuery + try/catch.
        try {
          await db.rawQuery('PRAGMA journal_mode=WAL');
        } catch (_) {
          /* keep the default journal — this is a perf tweak, not a requirement */
        }
        try {
          await db.execute('PRAGMA synchronous=NORMAL');
          // ~40 MB page cache (negative = KiB) so hot b-tree pages stay resident
          // on a 150 MB+ DB instead of being re-read from disk each query.
          await db.execute('PRAGMA cache_size=-40000');
        } catch (_) {
          /* non-fatal */
        }
      },
      onCreate: (db, version) async {
        await LocalDb._createSamples(db);
        await LocalDb._createDecodedStore(db);
        await db.execute('CREATE INDEX idx_samples_ts ON samples(ts)');
        await LocalDb._createEvents(db);
        await LocalDb._createBandSignals(db);
        await LocalDb._createRawArchive(db);
        await LocalDb._createDerived(db);
        await LocalDb._createDayResult(db);
        await LocalDb._createUserTables(db);
        await LocalDb._createSyncState(db);
        await LocalDb._createSyncCursor(db);
        await LocalDb._createComputeState(db);
        await LocalDb._createPrimitiveArtifacts(db);
        await LocalDb._createLiveCoverage(db);
        await LocalDb._createDevice(db);
        await LocalDb._createDeviceCoverage(db);
        await LocalDb._createSignalPriority(db);
        await LocalDb._createEcgTables(db);
        await LocalDb._ensureEcgPhase1Columns(db);
        await LocalDb._createWorkoutSuggestions(db);
        await LocalDb._createSleepOverride(db);
        await LocalDb._createSleepNap(db);
        await LocalDb._createVendorSleepEpoch(db);
        await ImportJournal.ensureSchema(db);
        await ActivityStore.create(db);
        await LocalDb._createWorkoutRoute(db);
        await LocalDb._createNotifFired(db);
        await LocalDb._createNotifSlots(db);
        await LocalDb._createAlarmSchedule(db);
        await LocalDb._createWakeTables(db);
        await LocalDb._ensureCoachViews(db);
        await LocalDb._ensureStoreRevisions(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) await LocalDb._createEvents(db);
        if (oldV < 3) {
          // Re-key raw_records by frame hex so LIVE packets (0x28/0x33) — which
          // have no per-record counter — can be queued without PK collisions.
          // Pending unuploaded raw is re-syncable from the band, so a clean
          // rebuild is acceptable.
          await db.execute('DROP TABLE IF EXISTS raw_records');
          await LocalDb._createRaw(db);
        }
        if (oldV < 4) {
          // The old samples table cached decoded sensor fields (spo2/skin_temp) that
          // (a) were read from MISIDENTIFIED offsets and (b) nothing ever read. The
          // edge no longer decodes sensors — drop + recreate as a header-only index.
          await db.execute('DROP TABLE IF EXISTS samples');
          await LocalDb._createSamples(db);
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts)',
          );
        }
        if (oldV < 5) {
          // LOCAL-FIRST re-layer: the on-device DerivationEngine now computes the
          // full 1 Hz analytics family from raw and stores PERMANENT derived rows.
          // Purely additive — raw tables are untouched.
          await LocalDb._createDerived(db);
        }
        if (oldV < 6) {
          // BUCKET-BY-REAL-TIME fix. Add `rec_ts` (epoch SECONDS, the decoded
          // record time) to raw_records and backfill it for every existing row by
          // decoding the stored hex once. The DerivationEngine now buckets days by
          // rec_ts (not captured_at), so a multi-day flash backfill received in one
          // sync no longer collapses into a single "today" bucket. Additive + safe
          // on a populated DB.
          // GUARDED add: an oldV <= 2 DB already had raw_records DROPped and
          // re-created by the step-3 block above using the CURRENT `_createRaw`
          // DDL — which already carries rec_ts. A bare ALTER … ADD COLUMN then
          // threw "duplicate column name: rec_ts", and because onUpgrade runs
          // inside ONE exclusive transaction the whole ladder rolled back and
          // openDatabase rethrew → app stuck on the loading screen, forever.
          await LocalDb._addRecTsColumn(db);
          await LocalDb._backfillRecTs(db);
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_raw_rects ON raw_records(rec_ts)',
          );
        }
        if (oldV < 7) {
          // LOCAL-FIRST user-data layer: journal, menstrual cycle log, workout
          // sessions, and the notifications feed — all on-device, additive.
          await LocalDb._createUserTables(db);
        }
        if (oldV < 8) {
          // RE-KEY raw_records by `counter` (drop the hex PRIMARY KEY, which
          // roughly DOUBLED on-disk size) and PURGE the live high-rate bloat
          // (0x28/0x2B/0x33). CRITICAL: we must NOT drop the 1 Hz historical
          // substrate (0x2F / R24) — the band will not re-send records its read
          // cursor has already passed, and they may not be derived yet, so a
          // blind rebuild would lose real data. Instead: rename aside, create the
          // new counter-keyed table, migrate the historical rows across (their
          // counters are unique), and discard only the live frames + the old
          // hex-PK overhead.
          await db.execute('ALTER TABLE raw_records RENAME TO _raw_old');
          await LocalDb._createRaw(db);
          await db.execute(
            'INSERT OR IGNORE INTO raw_records '
            '(counter, hex, packet_type, captured_at, rec_ts, uploaded) '
            'SELECT counter, hex, packet_type, captured_at, rec_ts, uploaded '
            'FROM _raw_old WHERE packet_type = 47 AND counter IS NOT NULL',
          );
          await db.execute('DROP TABLE _raw_old');
        }
        if (oldV < 9) {
          // VERSIONED IMMUTABLE DERIVED STORE (ARCHITECTURE_V2 invariant 6).
          // Replace the single-row `derived_day` (PK date) with
          // `day_result(day_id, algo_version)` so an algo bump writes a NEW
          // version instead of mutating, and the serve seam reads the latest
          // version per day. Additive: create the new table and best-effort
          // migrate any existing derived_day rows across at the prior version, so
          // history survives the upgrade (raw is the source of truth regardless).
          await LocalDb._createDayResult(db);
          try {
            await db.execute(
              'INSERT OR IGNORE INTO day_result '
              '(day_id, algo_version, payload_json, window_json, computed_at, '
              ' finalized, rhr, rmssd, readiness) '
              "SELECT date, 1, payload_json, '{}', computed_at, 0, rhr, rmssd, readiness "
              'FROM derived_day',
            );
          } catch (_) {
            /* derived_day may be absent — fine, raw rebuilds it */
          }
        }
        if (oldV < 10) {
          await LocalDb._createSyncState(db);
          // RESUMABLE SYNC. Durable key→value cursor store so the historical
          // offload survives app restarts / disconnects: we persist the strap's
          // continuation token + counter/rec_ts high-water BEFORE ACKing a
          // HISTORY_END (the safe-trim invariant), and reconnect detectors read
          // it to tell a stalled cursor from a healthy one. Additive.
          await LocalDb._createSyncCursor(db);
        }
        if (oldV < 11) {
          await LocalDb._createDecodedStore(db);
          await LocalDb._backfillDecodedStore(db);
          // Live workout steps (Tier-A pedometer over the session's 100 Hz
          // R10 accel). Additive nullable column — old rows read null.
          //
          // GUARDED add: an oldV <= 6 DB gets `sessions` from the step-7
          // `_createUserTables` block above, which uses the CURRENT DDL — and
          // that already declares `steps`. A bare ALTER … ADD COLUMN then threw
          // "duplicate column name: steps", rolling back the whole (single,
          // exclusive) onUpgrade transaction so openDatabase rethrew → app
          // permanently stuck on the loading screen.
          await LocalDb._addColumnIfMissing(db, 'sessions', 'steps', 'INTEGER');
        }
        if (oldV < 12) {
          // PURGE the old 1 Hz step ESTIMATE. 1 Hz can't count steps (Nyquist),
          // and the prior ambulatory-minutes×cadence estimate inflated badly
          // (resting noise cleared the floor → ~100k/day). `steps` is recomputed
          // by the new hybrid (live 100 Hz real count + bounded 1 Hz estimate);
          // wipe the bogus history so trends don't carry it.
          await db.execute("DELETE FROM metric_series WHERE key = 'steps'");
        }
        if (oldV < 13) {
          // 100 Hz step coverage: the device-time windows the live pedometer
          // actually counted, so the 1 Hz estimate can EXCLUDE them (prefer the
          // real count, never double-count). Also drop the stale 'active_min'
          // trend — active-minutes was replaced by the steps hybrid.
          await LocalDb._createBandSignals(db);
          await LocalDb._ensureSyncStateSchema(db);
          await LocalDb._createLiveCoverage(db);
          await db.execute(
            "DELETE FROM metric_series WHERE key = 'active_min'",
          );
          await db.execute("DELETE FROM metric_series WHERE key = 'steps'");
        }
        if (oldV < 14) {
          await LocalDb._createComputeState(db);
        }
        if (oldV < 16) {
          // Historically both the v15 and v16 steps called this (idempotent
          // CREATE IF NOT EXISTS); collapsed into one call — any pre-v16 DB
          // gets the primitive_artifacts table exactly once here.
          await LocalDb._createPrimitiveArtifacts(db);
        }
        if (oldV < 17) {
          await LocalDb._rebuildCanonicalDecodedStore(db);
        }
        if (oldV < 18) {
          // Menstrual symptom log (full cycle screen) — one row per date, a JSON
          // list of symptom tags + optional note. Separate from cycle_log (whose
          // `date` PK is a period-start marker) so a date can carry both.
          await LocalDb._createCycleSymptom(db);
        }
        if (oldV < 19) {
          // The v17 step (or a v11-16 origin) may leave OLD counter-keyed decoded
          // tables here; the backfill below writes through the rec_ts-keyed
          // _queueDecodedOneHz, so convert to the current schema first (preserving
          // any existing rows), then reconstruct the rest from raw_records.
          await LocalDb._rekeyDecodedStoreByRecTs(db);
          await LocalDb._backfillDecodedStore(db);
          await LocalDb._dropRawStore(db);
          await LocalDb._ensureSessionSchema(db); // adds hrr_bpm
          await LocalDb._createWorkoutSuggestions(db);
        }
        if (oldV < 20) {
          await LocalDb._createSleepOverride(db);
        }
        if (oldV < 21) {
          // FIRMWARE RESILIENCE: durable archive of historical records we could
          // NOT decode (unknown/unsupported version). They used to be dropped
          // unseen — lost forever. Now they land in raw_archive (kept, except
          // the thinning in [thinRawArchiveBefore]) so a future firmware's
          // records can be re-decoded. Also add `millivolts` to band_battery
          // for the battery-health series. Both additive.
          await LocalDb._createRawArchive(db);
          await LocalDb._ensureBandBatteryMillivolts(db);
        }
        if (oldV < 22) {
          // GPS workout routes (run/ride/walk). Additive, on-device only —
          // never uploaded, never touches derivation output (no kAlgoVersion
          // bump). Pruned with its session.
          await LocalDb._createWorkoutRoute(db);
        }
        if (oldV < 23) {
          // Additive: per-point smoothed instantaneous speed (m/s), captured
          // for the live speed/pace readout and kept with the point for a
          // future finished-route speed graph. Existing rows get null (no
          // speed was ever recorded for them) — never backfilled/guessed.
          await LocalDb._ensureWorkoutRouteSpeed(db);
        }
        if (oldV < 24) {
          // day_result rows written by _markDaySkipped (a day whose
          // derivation threw) look identical to a real derived day to
          // anything just checking "is there a row at this algo_version" -
          // which is exactly what the raw-pruning guard does. that let a day
          // that failed to derive get treated as safe-to-prune, deleting its
          // raw substrate for good. this column lets the guard tell the two
          // apart. existing rows default to 0 (not skipped) - can't know in
          // hindsight which old rows were skip markers, but going forward
          // this is right.
          await LocalDb._ensureDayResultSkippedColumn(db);
        }
        if (oldV < 25) {
          // Same class of bug as `skipped` above, different failure mode: the
          // offloaded second-half day-blocks compute (naps/workouts/HRR/wear/
          // curves/wake-features) can throw or time out AFTER the first-half
          // headline scalars (readiness/RHR/RMSSD) already succeeded. That
          // path is non-fatal by design (the day still gets a real,
          // non-skipped day_result row so headline scalars display), but the
          // raw-pruning guard only excluded `skipped` rows - a headline-only
          // partial row still counted as "derived" and let the raw substrate
          // it would need to fill in those missing blocks get pruned for
          // good. This column lets the guard exclude partial rows too.
          // Existing rows default to 0 (not partial) - can't know in
          // hindsight which old rows were partial, but going forward this is
          // right.
          await LocalDb._ensureDayResultPartialColumn(db);
        }
        if (oldV < 26) {
          // Cross-isolate fire-once for notifications. The dedupe guard used to
          // live entirely in SharedPreferences, where a check and a record are
          // two separate operations — so the foreground and WorkManager derive
          // isolates could both read "not fired" and both alert (issue #136's
          // tail). This table makes the claim a single atomic INSERT OR IGNORE.
          // Purely additive; the legacy prefs keys are migrated lazily on first
          // use by FiredKeyStore, so nothing is lost on upgrade.
          await LocalDb._createNotifFired(db);
        }
        if (oldV < 27) {
          // `live_coverage` gains a `source` column so a phone-pedometer count
          // can be told apart from the band's 100 Hz wrist count. Existing rows
          // default to 'band', which is what they are.
          //
          // This matters because the two sources must NEVER be summed: they
          // both count the same walk from different places on the body. The
          // reader prefers phone rows for a day when any exist (a
          // pocket-carried pedometer sees gait; a wrist one confuses arm work
          // for steps), and falls back to band rows otherwise.
          await LocalDb._ensureLiveCoverageSource(db);
        }
        if (oldV < 28) {
          // The numeric half of a journal entry, plus definitions for
          // user-invented fields. Purely new tables — the existing `journal`
          // row for a day is untouched, so an upgrade loses no tags and no
          // notes, and a day with only tags simply has no metric rows.
          await LocalDb._createJournalMetric(db);
          await LocalDb._createJournalFieldDef(db);
        }
        if (oldV < 29) {
          // Hand-entered blood work. Purely new tables; nothing existing is
          // read or rewritten.
          await LocalDb._createLabTables(db);
        }
        if (oldV < 30) {
          // Paced-breathing history. New table only.
          await LocalDb._createBreathingSessions(db);
        }
        if (oldV < 31) {
          // User edits to a day's naps. New table only — the detector's own
          // output is untouched and the edits replay over it.
          await LocalDb._createSleepNap(db);
        }
        if (oldV < 32) {
          // Re-key raw_archive off the volatile `counter` onto frame `hex`.
          // `counter INTEGER PRIMARY KEY` + IGNORE silently DROPPED a distinct
          // undecodable frame whenever a post-reboot counter (reset to ~0)
          // collided with a still-present pre-reboot row — data loss in the
          // "never lose" table. Rebuild keyed by content. Existing rows have
          // unique counters, so the copy loses nothing; at most it collapses an
          // exact-duplicate hex, which is the dedup we want.
          //
          // raw_archive is normally created lazily in onOpen (_repairOpenSchema),
          // NOT in this ladder, so on an old DB it may not exist yet here — in
          // which case there is nothing to migrate and a fresh (hex-keyed) create
          // is all that's needed. DROP the old index name before the fresh CREATE
          // so it can't collide on the name the rename carried onto the aside
          // table (the leaked-`_new`-index footgun documented on the decoded
          // rebuild).
          final hasArchive = (await db.rawQuery(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='raw_archive'",
          )).isNotEmpty;
          if (hasArchive) {
            await db.execute(
              'ALTER TABLE raw_archive RENAME TO _raw_archive_old',
            );
            await db.execute('DROP INDEX IF EXISTS idx_raw_archive_captured');
            await LocalDb._createRawArchive(db);
            await db.execute(
              'INSERT OR IGNORE INTO raw_archive '
              '(hex, counter, packet_type, rec_ts, captured_at, reason) '
              'SELECT hex, counter, packet_type, rec_ts, captured_at, reason '
              'FROM _raw_archive_old',
            );
            await db.execute('DROP TABLE _raw_archive_old');
          } else {
            await LocalDb._createRawArchive(db);
          }
        }
        if (oldV < 33) {
          // RE-KEY the decoded ledger off the volatile record `counter` onto
          // rec_ts. The counter resets to ~0 on every reboot, so counter-as-PK
          // let a post-reboot second REPLACE-evict a pre-reboot one — silently,
          // unrecoverably deleting a 1 Hz row (raw_records is dropped).
          await LocalDb._rekeyDecodedStoreByRecTs(db);
        }
        if (oldV < 34) {
          // Keep the per-second fields the band computes itself instead of
          // decoding and discarding them. Additive columns only — see
          // _ensureDecodedOneHzBandFields. MUST run after the v33 re-key, which
          // rebuilds decoded_onehz from an explicit column list.
          await LocalDb._ensureDecodedOneHzBandFields(db);
        }
        if (oldV < 35) {
          // Nutrition. Purely new tables — nothing existing is read or
          // rewritten, and water stays in journal_metric.water_ml rather than
          // being duplicated here.
          await createNutritionTables(db);
        }
        if (oldV < 36) {
          // Medication and supplements. New tables only.
          await createMedTables(db);
        }
        if (oldV < 38) {
          // Strength sets. New tables only — `sessions` is untouched and the
          // sets hang off its id. (37 is reserved for symptoms, UI_WIRING §5.3;
          // skipping it costs nothing, and _repairOpenSchema creates these
          // idempotently anyway if the ladder lands out of order.)
          await LocalDb._createStrengthTables(db);
        }
        if (oldV < 39) {
          // Make ABSENCE representable in the decoded ledger: the six sensor
          // columns lose their NOT NULL so a record that carried no accel /
          // no optical / no thermal reading stops being written as a real zero.
          await LocalDb._relaxDecodedSensorNulls(db);
        }
        if (oldV < 40) {
          // `sessions.private` — the per-workout "keep this off the shared
          // surfaces" flag. Existing rows read 0, which is what they have
          // always meant. ADD COLUMN only, deliberately NOT the whole
          // `_ensureSessionSchema`: that also creates an index, which throws on
          // a DB whose `sessions` table this ladder has not created yet — and a
          // throw in here rolls the ENTIRE ladder back and quarantines the
          // user's database. `_addColumnIfMissing` is a no-op on a missing
          // table, and `_repairOpenSchema` does the rest at onOpen.
          await LocalDb._addColumnIfMissing(
            db,
            'sessions',
            'private',
            'INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldV < 41) {
          // Which strap measured the row (see _ensureDeviceFamilyColumns).
          // ADD COLUMN only, idempotent, and a no-op on a table this ladder has
          // not created yet — a throw in here rolls the WHOLE ladder back.
          await LocalDb._ensureDeviceFamilyColumns(db);
        }
        if (oldV < 42) {
          // ADDITIVE ONLY, and every step is a no-op on a table this ladder has
          // not created yet — a throw in here rolls the WHOLE ladder back.
          //
          //  * decoded_onehz.ambient_raw — the gen4 ambient-light channel,
          //    which until now was decoded and thrown away on every record.
          //  * sessions.trace_json / trace_samples — the frozen session trace.
          //  * metric_series_version — which build's maths wrote each day's
          //    scalars, backfilled from the version day_result already carries.
          //  * band_backlog — the strap's ring-buffer bookkeeping.
          //
          // No rewrite pass and no delete: `onUpgrade` runs inside openDatabase
          // under iOS's CPU watchdog (invariant 11). The raw_archive thinning
          // that lands with this version is deliberately NOT here — it runs on
          // the retention path, off the launch path, where a 500 MB back
          // catalogue can be cleared without a launch hang.
          await LocalDb._ensureDecodedOneHzBandFields(db);
          await LocalDb._ensureSessionTraceColumns(db);
          await LocalDb._createMetricSeriesVersion(db);
          await LocalDb._backfillMetricSeriesVersion(db);
          await LocalDb._createBandBacklog(db);
        }
        if (oldV < 43) {
          // `decoded_onehz.source` / `decoded_rr.source` — which SENSOR produced
          // the row (see _ensureSourceColumns), plus the session-scoped landing
          // table for a standard Bluetooth heart-rate sensor. Both are ADD
          // COLUMN / CREATE TABLE only and no-ops on a table this ladder has not
          // created yet — a throw in here rolls the WHOLE ladder back.
          await LocalDb._ensureSourceColumns(db);
          await LocalDb._createExternalHr(db);
          await LocalDb._createImportedMeasurement(db);
          // ADD COLUMN / CREATE TABLE only, each a no-op on a table this ladder
          // has not created yet:
          //  * decoded_onehz.temp_ch2_c / temp_ch3_c / signal_quality_logvar —
          //    the gen5 channels the mapper decoded and dropped (MT-12).
          //  * sessions.rpe — session-level self-reported exertion (TS-09).
          //  * metric_series_version.source — measured vs imported, in every
          //    export (export-provenance), on L13's existing side table.
          //  * workout_split — per-km splits frozen at finalize (CV-01/TS-07),
          //    because `decoded_onehz` is gone at `rawRetentionDays` and
          //    cannot be re-read.
          await LocalDb._ensureDecodedOneHzBandFields(db);
          await LocalDb._addColumnIfMissing(db, 'sessions', 'rpe', 'REAL');
          await LocalDb._addColumnIfMissing(db, 'sessions', 'cadence_spm', 'INTEGER');
          await LocalDb._addColumnIfMissing(
            db,
            'metric_series_version',
            'source',
            'TEXT',
          );
          await LocalDb._createWorkoutSplit(db);
          // LAST, and the only rewrite in this rung: `decoded_onehz.hr` loses
          // its NOT NULL. Runs after every ADD COLUMN above so the rebuild
          // carries them across.
          await LocalDb._relaxDecodedHrNull(db);
        }
        if (oldV < 44) {
          // GATES 4b — NO SCHEMA CHANGE. The one rung on this ladder that is a
          // data recovery rather than a DDL step: archived records that this
          // build's decoders can now read are replayed into `decoded_onehz`.
          //
          // Here and not on the retention path (where `thinRawArchiveBefore`
          // runs) for two reasons: the recovered seconds are OLDER than the
          // retention edge, so a prune-time replay would insert them and delete
          // them in the same pass; and derivation has to see them, which means
          // landing before the next derive, not after it.
          //
          // Bounded by `_ladderRedriveReasons` precisely so it is not the
          // heavy pass the v42 rung refuses to do here: it is 1,035 short
          // frames on the largest real export, not the 492 MB of v20 hex
          // sitting beside them.
          await LocalDb.redriveArchivedRecords(db, reasons: LocalDb._ladderRedriveReasons);
        }
        if (oldV < 45) {
          // `band_battery.charge_units` — ADD COLUMN, idempotent, a no-op on a
          // table this ladder has not created yet — plus the one-time replay of
          // stored band events into the series that had a reader, a widget and
          // no writer. Both bounded; see _backfillBandBatteryFromEvents for why
          // the replay is safe to run on the launch path and the v42 rung's
          // rewrite was not.
          await LocalDb._ensureBandBatteryChargeUnits(db);
          await LocalDb._backfillBandBatteryFromEvents(db);
        }
        if (oldV < 46) {
          // Retire the disproven gen5 columns that v34-era dev builds banked
          // (`on_wrist` / `hr_valid`, plus the -50.00 °C skin-temp sentinel).
          // Data-only: the DDL is untouched, so this does NOT diverge an
          // upgraded install's schema from a fresh one. See
          // _retireDisprovenOneHzColumns for the evidence.
          await LocalDb._retireDisprovenOneHzColumns(db);
        }
        if (oldV < 47) {
          // Put `device_id` in front of the key of the three stores whose
          // identity was a WHOOP-shaped quantity (a record second, the band's
          // flash counter). The one item on the band-agnostic list that cannot
          // be done after a second device has written — see
          // [_rekeyStoresByDeviceId]. Rewrites no value and moves no derived
          // number, so it ships without a kAlgoVersion bump.
          //
          // LAST on the ladder, after every ADD COLUMN above, because the
          // rebuild reconstructs its DDL from `PRAGMA table_info` and so
          // carries across exactly the columns that exist when it runs.
          await LocalDb._rekeyStoresByDeviceId(db);
        }
        if (oldV < 48) {
          // The observation store — vendor-computed, typed-in and imported
          // scalars. CREATE TABLE IF NOT EXISTS + two indexes and NOTHING
          // else: no backfill, no rewrite, no ADD COLUMN, nothing read. It is
          // a new empty table, so the CHECK and the UNIQUE index have no
          // existing row to fail on — which matters, because a throw in here
          // rolls the WHOLE ladder back and quarantines the user's database
          // (invariant 11), and this rung runs after the v47 re-key that every
          // upgrading install is already paying for on the launch path.
          //
          // Ships without a kAlgoVersion bump, deliberately: nothing writes
          // this table, nothing reads it, and no derived number can move.
          await LocalDb._createObservation(db);
        }
        if (oldV < 49) {
          // The device store, and the `live_coverage` column that lets the step
          // ladder tell two sensors apart. CREATE TABLE IF NOT EXISTS + ONE
          // guarded ADD COLUMN: no backfill, no rewrite, nothing read, and both
          // are no-ops on a table this ladder has not created yet — which is
          // what keeps it off the wrong side of invariant 11 (a throw in here
          // rolls the WHOLE ladder back and quarantines the user's database).
          //
          // ADD COLUMN with a constant DEFAULT does not rewrite the table, so
          // this rung is O(1) in `live_coverage` rows rather than O(n) — unlike
          // the v47 re-key every upgrading install is already paying for.
          //
          // Ships without a kAlgoVersion bump: every existing row takes
          // `device_id = ''`, one id is one sensor, and [resolveDaySteps]
          // returns exactly the totals it returned yesterday.
          await LocalDb._createDevice(db);
          await LocalDb._ensureLiveCoverageDeviceId(db);
        }
        if (oldV < 50) {
          // The weekly alarm schedule — one row per weekday (0=Mon..6=Sun,
          // matching the 0-indexed convention `workout_screen.dart` already
          // uses for weekday array positions; DateTime.weekday itself stays
          // 1=Mon..7=Sun everywhere else). CREATE TABLE IF NOT EXISTS and
          // NOTHING else: a new empty table has no existing row for the PK to
          // reject, so a throw here has nothing to roll back onto — which
          // matters, because a throw in here rolls the WHOLE ladder back and
          // quarantines the user's database (invariant 11). The legacy
          // single-alarm value (`alarm_epoch` in SharedPreferences) is seeded
          // into this table from AppState at startup, not here — this layer
          // never touches SharedPreferences (see the doc on _createDevice's
          // neighbours), and a plugin-channel read has no place inside a
          // migration ladder step running under iOS's CPU watchdog.
          //
          // Ships without a kAlgoVersion bump: the alarm is not a health
          // metric and nothing here changes a derived number.
          await LocalDb._createAlarmSchedule(db);
        }
        if (oldV < 51) {
          // MULTI-DEVICE ATTRIBUTION, commit 1 of 7 (M3). Two new empty
          // tables only in this commit — device_coverage / signal_priority —
          // no backfill, nothing read. Rewrites no existing row's value, so
          // this ships without a kAlgoVersion bump. Later M3 commits add
          // steps 2-7 to this SAME rung (device.role/.wearing, the four
          // rekeys, the coverage backfill); do not add a new `if (oldV < 51)`
          // block for them.
          await LocalDb._createDeviceCoverage(db);
          await LocalDb._createSignalPriority(db);
          // Step 2: device.role / .wearing. ADD COLUMN with a constant
          // DEFAULT does not rewrite the table, so this is O(1) in device
          // rows. The primary band's row IS the primary, permanently — that
          // is what `id = ''` (kPrimaryDeviceId) means. Roles move, keys do
          // not. A no-op on a database with no device row yet.
          await LocalDb._addColumnIfMissing(
            db, 'device', 'role', "TEXT NOT NULL DEFAULT 'paired'",
          );
          await LocalDb._addColumnIfMissing(
            db, 'device', 'wearing', 'INTEGER NOT NULL DEFAULT 1',
          );
          // A rung must no-op on a table this ladder has not created yet
          // (the same rule _addColumnIfMissing follows above).
          if ((await LocalDb._columnsOf(db, 'device')).isNotEmpty) {
            await db.execute(
              "UPDATE device SET role = 'primary' WHERE id = ?",
              [LocalDb.kPrimaryDeviceId],
            );
          }
          // Step 3 (metric_series_version.coverage_devices/.priority_hash)
          // needs NO rung code: _createMetricSeriesVersion adds them with its
          // own guarded ALTERs and is already reached from _createDerived,
          // which _repairOpenSchema calls on every open.

          // Step 4: band_backlog. Keyed by one epoch second, so two devices
          // connecting in the same second overwrite each other. Re-keyed, NOT
          // dropped: the series is what establishes the records-per-day
          // divisor (see _createBandBacklog, which is why it is exempt from
          // retention), and `_recordPagesBehind` reads the newest row back to
          // see whether `wrap_count` moved — a drop loses the history and
          // blinds that check for a connect. Same helper as step 5, one rung
          // earlier so the table exists for a database that never had it.
          await LocalDb._createBandBacklog(db);
          await LocalDb._rekeyByDeviceIdV51(db, 'band_backlog', keyTail: const ['ts']);

          // Step 5: the four re-keys. LAST of the DDL, self-skipping,
          // idempotent. raw_archive first because it is the expensive one
          // and a crash after it means the rest re-runs cheaply; the temp
          // table is dropped up front so a re-run is clean either way.
          await LocalDb._rekeyByDeviceIdV51(db, 'raw_archive', keyTail: const ['hex']);
          await LocalDb._rekeyByDeviceIdV51(db, 'band_events', keyTail: const ['hex']);
          await LocalDb._rekeyByDeviceIdV51(db, 'events', keyTail: const ['hex']);
          await LocalDb._rekeyByDeviceIdV51(
            db, 'band_battery', keyTail: const ['ts', 'source'],
          );

          // Step 6: coverage for the days the substrate still holds. Bounded,
          // minute-bucketed, and it claims nothing about pruned days.
          await LocalDb._backfillDeviceCoverage(db);

          // Step 7: signal_priority is DELIBERATELY NOT SEEDED. An empty
          // table IS the physics ladder (rankSources()), and a seeded copy
          // of it is a second source of truth that goes stale against the
          // adapter.
        }
        if (oldV < 52) {
          // Smart Wake Window: one additive column, default 0 (off), on an
          // existing per-weekday row — every existing alarm keeps firing at
          // exactly its configured time, unchanged. No kAlgoVersion bump:
          // this is not a health metric.
          await LocalDb._addColumnIfMissing(
            db, 'alarm_schedule', 'smart_window_minutes',
            'INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldV < 53) {
          // Cross-isolate atomic OS-notification-id slot allocation — the
          // same TOCTOU hazard `_createNotifFired` fixed for the fire-once
          // guard, but for id allocation: two isolates could allocate a slot
          // for two different dedupeKeys in the same category band at nearly
          // the same instant and land on the same id. Purely additive; the
          // legacy SharedPreferences-allocated ids are left as-is and simply
          // stop being consulted for new allocations going forward.
          await LocalDb._createNotifSlots(db);
        }
        if (oldV < 54) {
          // The WHOOP MG ECG store: three new tables, CREATE TABLE IF NOT
          // EXISTS and NOTHING else — no backfill, no rewrite, no ADD COLUMN,
          // nothing read — so a throw here has nothing to roll back onto
          // (invariant 11). The coach view over ecg_reading is created by
          // _ensureCoachViews on the onOpen repair pass, after every table
          // exists. Ships without a kAlgoVersion bump: nothing derived moves.
          //
          // This rung is 54: main took 51 for multi-device attribution (M3),
          // 52 for Smart Wake Window and 53 for notif-slot allocation while
          // this feature was on its own branch, so the store moved up to the
          // next free rung rather than collide with any of them.
          await LocalDb._createEcgTables(db);
        }
        if (oldV < 55) {
          // Strap-event sub-second remainder (1/32768 s) so two taps in one
          // strap second stay distinct occurrences. One ADD COLUMN, no
          // backfill (old rows read 0, which is what they were stored as);
          // _addColumnIfMissing makes a re-run a no-op. No kAlgoVersion bump:
          // nothing derived moves.
          await LocalDb._addColumnIfMissing(
            db,
            'events',
            'ts_subsec',
            'INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldV < 56) {
          // Natural Wake / Gradual Wake split. Additive only: four
          // columns on alarm_schedule, two new tables, and a once-only copy of
          // the legacy Smart Wake window into natural_window_minutes guarded
          // by a wake_meta marker. smart_window_minutes is kept, never
          // dropped. Gradual Wake is NEVER enabled here. No kAlgoVersion
          // bump: nothing derived moves. _repairOpenSchema re-runs all of
          // this on every open, so a same-version merged build self-heals.
          await LocalDb._ensureWakeSchema(db);
        }
        if (oldV < 57) {
          // Gesture ECG is never an ECG reading. One additive column
          // (ecg_raw_packet.origin, NULL = unknown/normal) and one tiny
          // interval table, both through _createEcgTables so there is exactly
          // one definition. No backfill, no rewrite, nothing read: cheap under
          // iOS's CPU watchdog (invariant 11). No kAlgoVersion bump: nothing
          // derived moves. _repairOpenSchema re-runs it on every open.
          await LocalDb._createEcgTables(db);
        }
        if (oldV < 58) {
          // Input revisions behind the "did this day's inputs
          // change" fingerprint. Last in the ladder on purpose: a rebuilt or
          // renamed decoded_* table above loses its triggers, so they are
          // attached only once every table is in its final shape. Table and
          // triggers only, no backfill (a missing bucket reads as revision 0),
          // so it is cheap under iOS's CPU watchdog (invariant 11). No
          // kAlgoVersion bump: nothing derived moves. _repairOpenSchema
          // re-runs it on every open.
          await LocalDb._createInputRev(db);
        }
        if (oldV < 59) {
          // The last good result of each slow screen read, kept across
          // restarts. One small additive table, no backfill (an empty table is
          // a screen's first-open state), so it is cheap under iOS's CPU
          // watchdog (invariant 11). No kAlgoVersion bump: nothing derived
          // moves. _repairOpenSchema re-runs it on every open.
          await LocalDb._createLastResult(db);
        }
        if (oldV < 60) {
          // The signature of the inputs a stored result was
          // computed from, so a result whose inputs have not moved is fresh.
          // One nullable column through the one helper, no backfill (a NULL
          // signature is never fresh, so an old row recomputes once): cheap
          // under iOS's CPU watchdog (invariant 11). No kAlgoVersion bump:
          // nothing derived moves. _repairOpenSchema re-runs it on every open.
          await LocalDb._addColumnIfMissing(db, 'last_result', 'input_sig', 'TEXT');
        }
        if (oldV < 61) {
          // Resume points of the incremental day derive: scratch, one small
          // additive table, no backfill (no row means "run the full pass"), so
          // it is cheap under iOS's CPU watchdog (invariant 11). No
          // kAlgoVersion bump: nothing derived moves. _repairOpenSchema
          // re-runs it on every open.
          await LocalDb._createDayCheckpoint(db);
        }
        if (oldV < 62) {
          // The instant a sleep block was confirmed awake (night is final).
          // One small additive table, no backfill (no row means "not final"),
          // so it is cheap under iOS's CPU watchdog (invariant 11). No
          // kAlgoVersion bump: a night without a confirmation scores exactly
          // as before. _repairOpenSchema re-runs it on every open.
          await LocalDb._createWakeConfirmation(db);
        }
        if (oldV < 63) {
          // The evidence behind that confirmation (app opened, band movement,
          // alarm events), kept so it survives a restart: an alarm that fired
          // while the app was dead still counts when it is opened. One small
          // additive table, no backfill, cheap under iOS's CPU watchdog
          // (invariant 11). No kAlgoVersion bump: nothing derived moves.
          // _repairOpenSchema re-runs it on every open.
          await LocalDb._createWakeEvidence(db);
        }
        if (oldV < 64) {
          // The wearer's answer to a marked moment. One small additive table,
          // no backfill (no row means "unanswered"), cheap under iOS's CPU
          // watchdog (invariant 11). No kAlgoVersion bump: nothing derived
          // moves. _repairOpenSchema re-runs it on every open.
          await LocalDb._createMomentLabel(db);
        }
        if (oldV < 65) {
          // Two small additive tables, no backfill (no row means "nothing was
          // assumed" / "no symptom described"), cheap under iOS's CPU watchdog
          // (invariant 11): the assumed water glasses of "Assume I drank water"
          // and the structured Symptom answer of a marked moment. No
          // kAlgoVersion bump: nothing derived reads either. _repairOpenSchema
          // re-runs both on every open.
          await LocalDb._createAssumedWater(db);
          await LocalDb._createSymptomEntry(db);
        }
        if (oldV < 66) {
          // ECG results (ecg-features): one nullable column, why a partial
          // reading stopped. Through _createEcgTables so the rung and the
          // every-open repair share one definition; no backfill, nothing
          // read, cheap under iOS's CPU watchdog (invariant 11). No
          // kAlgoVersion bump: nothing derived moves.
          await LocalDb._createEcgTables(db);
        }
        if (oldV < 67) {
          // (Numbered 66 on the experimental branch; renumbered at the merge
          // because 66 is the ECG stop_reason rung. Every creator here is
          // idempotent and _repairOpenSchema re-runs it, so a dev database
          // left at the branch's 68 self-heals.)
          // One additive side table, no backfill (no row means "nothing was
          // archived"), cheap under iOS's CPU watchdog (invariant 11): the
          // lossy sample archive of the 1 Hz signals. No kAlgoVersion bump:
          // nothing derived reads it (a reconstruction is an approximation,
          // invariant 3). _repairOpenSchema re-runs it on every open.
          await LocalDb._createSampleArchive(db);
        }
        if (oldV < 68) {
          // The first table shape (the branch-era 66) merged devices and held one blob per signal-day.
          // _createSampleArchive rebuilds an old-shape table additively
          // (rows keep their bytes: primary device, part 0) and
          // _createSampleStatus adds the per-day outcome ledger.
          await LocalDb._createSampleArchive(db);
          await LocalDb._createSampleStatus(db);
        }
        if (oldV < 69) {
          // origin_sec / n_slots / slot_sec: a part's absolute origin, so
          // coverage reconciles across time zones. _createSampleArchive adds
          // the columns and gives legacy parts their origin (see there).
          await LocalDb._createSampleArchive(db);
        }
        if (oldV < 70) {
          // ECG attempt groups and provenance (design 04 phase 1): ten nullable
          // columns and one index on ecg_reading, no backfill (a legacy row
          // stays NULL = "not recorded" and is a group of one), cheap under
          // iOS's CPU watchdog (invariant 11). No kAlgoVersion bump: nothing
          // derived reads them. _repairOpenSchema re-runs it on every open.
          await LocalDb._ensureEcgPhase1Columns(db);
        }
        if (oldV < 71) {
          // Side-table revisions avoid rewriting large payload rows and need
          // no backfill; legacy rows read as revision zero until next write.
          await LocalDb._ensureStoreRevisions(db);
        }
        // 72-75: upstream's 55-58. Both lines numbered their rungs from v54
        // without seeing each other, so upstream's steps take the next free
        // rungs here. Each one is idempotent and additive, and
        // _repairOpenSchema re-runs the creators on every open, so an install
        // that ran either ladder converges (merge log D13).
        if (oldV < 72) {
          // One-time heal of the °C skin_temp_z older WHOOP imports wrote.
          // Here, not on the onOpen repair pass: it reads every day_result
          // payload, and new imports no longer write the key, so once is enough.
          await LocalDb._scrubImportedSkinTempZ(db);
        }
        if (oldV < 73) {
          // Step calibration tables, plus when `device.wearing` was last
          // changed (NULL = never; that column has had DEFAULT 1 since v51).
          await LocalDb._addColumnIfMissing(
            db, 'device', 'wearing_set_ts', 'INTEGER',
          );
          await LocalDb._createStepCalibration(db);
        }
        if (oldV < 74) {
          await LocalDb._createSleepNap(db);
          await ActivityStore.create(db);
        }
        if (oldV < 75) {
          // A band's own hypnogram (`vendor_staged`). New table only.
          await LocalDb._createVendorSleepEpoch(db);
        }
        if (oldV < 76) {
          // The import journal (D38): one small additive table, no backfill
          // (no row means "no import ever journaled"), cheap under iOS's CPU
          // watchdog (invariant 11). No kAlgoVersion bump: nothing derived
          // moves. _repairOpenSchema re-runs it on every open.
          await ImportJournal.ensureSchema(db);
        }
        if (oldV < 77) {
          // Per-input revisions (design 06 1c): one small table plus triggers
          // on the catalogued tables, no backfill (no row reads as revision
          // 0), so it is cheap under iOS's CPU watchdog (invariant 11). No
          // kAlgoVersion bump: nothing derived reads them yet.
          // _repairOpenSchema re-runs it on every open.
          await LocalDb._createInputRev(db);
        }
        if (oldV < 78) {
          // group_row (design 06 1d): one empty table, no backfill.
          await createGroupRow(db);
        }
        if (oldV < 79) {
          // day_manifest (design 06 1e): one empty table, no backfill.
          await createDayManifest(db);
        }
      },
      onOpen: (db) async {
        await LocalDb._repairOpenSchema(db);
      },
      version: LocalDb.schemaVersion,
    );
    LocalDb._openCount++;
    LocalDb._markStoreReplaced();
    return opened;
  }

Future<void> _ldbPrivRepairOpenSchema(Database db) async {
    // Same-version merged builds can still need additive schema repair on an
    // existing install. Keep this idempotent and cheap: create missing tables,
    // indexes, and additive columns the current code assumes are present.
    await LocalDb._createSamples(db);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts)',
    );
    await LocalDb._createEvents(db);
    await LocalDb._createBandSignals(db);
    await LocalDb._ensureBandBatteryMillivolts(db);
    await LocalDb._ensureBandBatteryChargeUnits(db);
    await LocalDb._createRawArchive(db);
    await LocalDb._createDerived(db);
    await LocalDb._createDayResult(db);
    await LocalDb._createUserTables(db);
    await LocalDb._createSyncState(db);
    await LocalDb._createSyncCursor(db);
    await LocalDb._createComputeState(db);
    await LocalDb._createPrimitiveArtifacts(db);
    await LocalDb._createDecodedStore(db);
    // The compressed copy of what the retention prune deletes from the decoded
    // store. CREATE IF NOT EXISTS here and NO schema version bump, for the
    // reason given at _createImportedWorkout below: additive, no backfill —
    // days already pruned are gone, so there is nothing to backfill.
    await LocalDb._createSubstrateArchive(db);
    // Drop leftover DUPLICATE indexes from an old canonical-store rebuild. When
    // `_rebuildCanonicalDecodedStore` renamed `_decoded_*_new` → `decoded_*`, the
    // temp `_new`-named indexes rode along and now shadow the canonical ones on
    // the SAME columns — so every decoded insert (the hottest write path) updated
    // twice as many b-trees as needed. The canonical indexes are (re)created by
    // _createDecodedStore just above; these `_new` duplicates are pure write tax.
    //
    // Plus `idx_decoded_onehz_counter`, which was never on a read path at all —
    // see _createDecodedStore for why it is gone rather than merely unused.
    for (final ix in const [
      'idx_decoded_onehz_new_rects',
      'idx_decoded_onehz_new_rec_ts_unique',
      'idx_decoded_rr_new_counter',
      'idx_decoded_rr_new_ts',
      'idx_decoded_rr_new_ts_beat_unique',
      'idx_decoded_onehz_counter',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $ix');
    }
    await LocalDb._createLiveCoverage(db);
    await LocalDb._ensureLiveCoverageSource(db);
    await LocalDb._ensureLiveCoverageDeviceId(db);
    await LocalDb._createDevice(db);
    await LocalDb._createDeviceCoverage(db);
    await LocalDb._createSignalPriority(db);
    await LocalDb._createExternalHr(db);
    await LocalDb._createImportedMeasurement(db);
    // CREATE TABLE IF NOT EXISTS on the every-open repair path, and NO schema
    // version bump: this table is additive with no backfill, so the repair pass
    // creates it on a fresh install and on an existing one alike. Spending a
    // version number here would collide with the other branches reaching for
    // the next one, and buy nothing a no-op CREATE does not already do.
    await LocalDb._createImportedWorkout(db);
    await LocalDb._createObservation(db);
    await LocalDb._createCycleSymptom(db);
    await LocalDb._ensureSessionSchema(db);
    await LocalDb._ensureSyncStateSchema(db);
    await LocalDb._createWorkoutSuggestions(db);
    await LocalDb._createSleepOverride(db);
    await LocalDb._createSleepNap(db);
    await LocalDb._createVendorSleepEpoch(db);
    await ImportJournal.ensureSchema(db);
    await ActivityStore.create(db);
    await LocalDb._createWorkoutRoute(db);
    await LocalDb._ensureWorkoutRouteSpeed(db);
    await LocalDb._createWorkoutSplit(db);
    await LocalDb._ensureBreathingWindowColumns(db);
    // Self-skipping (one PRAGMA) unless the table really is still NOT NULL —
    // the same-version merged-build case this whole method exists for.
    await LocalDb._relaxDecodedHrNull(db);
    await LocalDb._ensureDayResultSkippedColumn(db);
    await LocalDb._ensureDayResultPartialColumn(db);
    await LocalDb._createNotifFired(db);
    await LocalDb._createNotifSlots(db);
    await LocalDb._createAlarmSchedule(db);
    // CREATE TABLE IF NOT EXISTS on the every-open repair path, no schema
    // version bump needed — additive, no backfill (see _createImportedWorkout
    // just above for the same reasoning).
    await LocalDb._createLiveWorkoutTally(db);
    await LocalDb._addColumnIfMissing(
      db, 'alarm_schedule', 'smart_window_minutes',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await LocalDb._ensureWakeSchema(db);
    await LocalDb._createEcgTables(db);
    await LocalDb._addColumnIfMissing(
      db, 'device', 'wearing_set_ts', 'INTEGER',
    );
    // A paired device's last reported battery and when — additive, no
    // version bump (same reasoning as the columns above).
    await LocalDb._addColumnIfMissing(db, 'device', 'battery_pct', 'INTEGER');
    await LocalDb._addColumnIfMissing(db, 'device', 'battery_ts', 'INTEGER');
    await LocalDb._createStepCalibration(db);
    await LocalDb._ensureEcgPhase1Columns(db);
    // After every step above that can rebuild decoded_* (_relaxDecodedHrNull):
    // a rebuilt table drops its triggers, this puts them back.
    await LocalDb._createInputRev(db);
    await LocalDb._createLastResult(db);
    await LocalDb._addColumnIfMissing(db, 'last_result', 'input_sig', 'TEXT');
    await LocalDb._createDayCheckpoint(db);
    await createGroupRow(db);
    await createDayManifest(db);
    await LocalDb._createWakeConfirmation(db);
    await LocalDb._createWakeEvidence(db);
    await LocalDb._createMomentLabel(db);
    await LocalDb._createAssumedWater(db);
    await LocalDb._createSymptomEntry(db);
    await LocalDb._createSampleArchive(db);
    await LocalDb._createSampleStatus(db);
    // Views LAST — they depend on metric_series / day_result / baselines / sessions
    // / notifications all existing. DROP+CREATE so a shape change takes effect.
    await LocalDb._ensureCoachViews(db);
    await LocalDb._ensureStoreRevisions(db);
    // After every table it triggers on exists in its final shape.
    await LocalDb._createInputRev(db);
    await LocalDb._dropRawStore(db);
  }

Future<void> _ldbPrivScrubImportedSkinTempZ(Database db) async {
    try {
      await db.execute(
        "UPDATE day_result SET payload_json = "
        "json_remove(payload_json, '\$.scalars.skin_temp_z') "
        "WHERE payload_json LIKE '%skin_temp_z%' "
        "AND payload_json LIKE '%whoop_export%' "
        'AND json_valid(payload_json) '
        "AND json_extract(payload_json, '\$.source') = 'whoop_export' "
        "AND json_type(payload_json, '\$.scalars.skin_temp_z') IS NOT NULL",
      );
    } catch (_) {
      // best-effort, see above
    }
  }

Future<void> _ldbPrivCreateInputRev(DatabaseExecutor db) async {
    // Empty except inside a bulk transition restore (beginBulkSpans).
    await db.execute(
        'CREATE TABLE IF NOT EXISTS input_rev_bulk (flag INTEGER NOT NULL)');
    await db.execute(
      'CREATE TABLE IF NOT EXISTS input_rev ('
      'bucket INTEGER PRIMARY KEY, rev INTEGER NOT NULL)',
    );
    String bump(String row) =>
        'INSERT INTO input_rev(bucket, rev) SELECT $row.rec_ts / 900, 0 '
        'WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = $row.rec_ts / 900); '
        'UPDATE input_rev SET rev = rev + 1 WHERE bucket = $row.rec_ts / 900;';
    const live = 'NEW.rec_ts IS NOT NULL AND NEW.rec_ts > 0';
    const gone = 'OLD.rec_ts IS NOT NULL AND OLD.rec_ts > 0';
    for (final t in const ['decoded_onehz', 'decoded_rr']) {
      final present = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [t],
      );
      if (present.isEmpty) continue;
      await db.execute(
        'CREATE TRIGGER IF NOT EXISTS ${t}_rev_ai AFTER INSERT ON $t '
        'WHEN $live BEGIN ${bump('NEW')} END',
      );
      await db.execute(
        'CREATE TRIGGER IF NOT EXISTS ${t}_rev_au AFTER UPDATE ON $t '
        'WHEN $live BEGIN ${bump('NEW')} END',
      );
      await db.execute(
        'CREATE TRIGGER IF NOT EXISTS ${t}_rev_au_old AFTER UPDATE ON $t '
        'WHEN $gone AND (NEW.rec_ts IS NULL OR '
        'NEW.rec_ts / 900 != OLD.rec_ts / 900) BEGIN ${bump('OLD')} END',
      );
      await db.execute(
        'CREATE TRIGGER IF NOT EXISTS ${t}_rev_ad AFTER DELETE ON $t '
        'WHEN $gone BEGIN ${bump('OLD')} END',
      );
    }
    // Design 06 1c: the per-input revision table and its triggers, here so the
    // DDL lives in the one pinned input-revision member. Tables that do not
    // exist yet are skipped; the end of _repairOpenSchema calls this again.
    await db.execute(kCreateInputRevisionTable);
    final master = await db.rawQuery(
      "SELECT type, name, sql FROM sqlite_master "
      "WHERE type IN ('table', 'trigger')",
    );
    final tables = <String>{};
    final triggers = <String, String>{};
    for (final r in master) {
      final name = r['name'] as String;
      if (r['type'] == 'table') {
        tables.add(name);
      } else {
        triggers[name] = (r['sql'] as String?) ?? '';
      }
    }
    // What a REPLACE into each catalogued table would delete.
    final keys = await inputRevisionKeys(db, [
      for (final spec in kInputCatalogue)
        for (final t in spec.tables)
          if (spec.kind == InputKind.table && tables.contains(t.name)) t.name,
    ]);
    for (final sql in inputRevisionTriggerSql(tables, triggers, keys: keys)) {
      await db.execute(sql);
    }
  }

Future<void> _ldbPrivCreateLiveWorkoutTally(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS live_workout_tally (
        workout_id     TEXT PRIMARY KEY,
        updated_ts     INTEGER NOT NULL,
        per_minute_hr  TEXT NOT NULL,
        zone_seconds   TEXT NOT NULL,
        seconds_by_bpm TEXT NOT NULL,
        max_hr_seen    INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

Future<void> _ldbPrivAddColumnIfMissing(Database db, String table, String column, String ddlType) async {
    if ((await LocalDb._columnsOf(db, table)).contains(column)) return;
    try {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $ddlType');
    } catch (_) {
      /* another opener won the race — the column exists now */
    }
  }

Future<void> _ldbPrivEnsureDecodedOneHzBandFields(Database db) async {
    const cols = {
      'step_count': 'INTEGER',
      'step_cadence': 'INTEGER',
      'activity_class': 'INTEGER',
      'skin_temp_c': 'REAL',
      'on_wrist': 'INTEGER',
      'hr_valid': 'INTEGER',
      'hr_alt': 'INTEGER',
      // Ambient-light ADC, u16 @inner[70] on a gen4 R24 record. A RELATIVE
      // count on the user's own scale, never lux — and one-sided: bright means
      // bright, dark means nothing (a sleeve or a duvet reads dark in a lit
      // room). 0 is the absent sentinel, not a reading — see _queueDecodedOneHz.
      'ambient_raw': 'INTEGER',
      // v43 (MT-12): the gen5 record's SECOND and THIRD temperature channels
      // (i16 ÷10 °C), decoded by protocol and dropped by the mapper until now.
      //
      // DELIBERATELY NOT NAMED AFTER A BODY PART. protocol itself calls their
      // semantics loose, and naming one of them is exactly how gen4's
      // `skin_temp_raw` came to feed readiness as if it were a skin
      // temperature. `temp_ch2` / `temp_ch3` is the channel index and nothing
      // else. If they turn out to be die or battery temperature they are not
      // body signals and stay unread — persisting them claims NOTHING, which
      // is the entire point of the column. Assume dual-heat-flux core temp is
      // UNAVAILABLE: that method needs two characterised sensors and a known
      // thermal resistance, and we have neither.
      'temp_ch2_c': 'REAL',
      'temp_ch3_c': 'REAL',
      // The band's own per-second signal-quality figure (log-variance, f32).
      // Its scale is the band's, so it can only ever be a WITHIN-NIGHT rank or
      // a weight — never a percentage, never a bar, never "HRV confidence 82%".
      'signal_quality_logvar': 'REAL',
      // MT-12's last channel: the band's own gravity-removed motion magnitude
      // for this second (f32 g). Named for what protocol says it is and
      // nothing more. It is NOT our ENMO — we do not know the band's window,
      // filter or statistic — so it may not be substituted for one, and
      // nothing reads it. Same contract as the two temp channels: persisting
      // claims nothing, and that is what makes it possible to find out later
      // whether it agrees with the ENMO we compute over the same seconds.
      //
      // Not a ladder rung. `_ensureDecodedOneHzBandFields` runs from
      // `_createDecodedStore`, which `_repairOpenSchema` calls on EVERY open,
      // so an existing install gets the column for one PRAGMA without
      // spending a schema version other branches are also reaching for.
      'dyn_accel_g': 'REAL',
      // The record's own sub-second, u16 in units of 1/32768 s. BOTH
      // GENERATIONS SEND IT and both decoders have always read it; nothing
      // carried it past the decoder, so every record in this table was pinned
      // to a whole second. Stored as the strap's own ticks, NOT converted to
      // ms: the conversion is lossy and the raw count is what the strap said.
      // See Sample.tsSubsec and beatTimesMs.
      'ts_subsec': 'INTEGER',
      // The band's own coarse wake/sleep code (2 bits: 0 wake, 1 still,
      // 2 sleep, 3 up) — GEN5/MG ONLY, null on gen4.
      //
      // AN ENVELOPE, NOT A STAGE, and the column may only ever be read as one:
      // deep, light and REM all read `sleep`, and it lags true onset by ~10
      // minutes. It cannot improve a hypnogram and must never be written into
      // one. Its value is that it is an OUTSIDE OPINION on a staging pipeline
      // that is otherwise single-source — the disagreement between our sleep
      // window and the band's is a thing this app currently cannot even see.
      // Stored as the raw code rather than a name: a name freezes a meaning.
      // See Sample.bandSleepState for the evidence that it varies and means
      // what it says.
      'band_sleep_state': 'INTEGER',
    };
    final have = await LocalDb._columnsOf(db, 'decoded_onehz');
    if (have.isEmpty) return; // table not created yet — the DDL carries them
    for (final e in cols.entries) {
      if (have.contains(e.key)) continue;
      await LocalDb._addColumnIfMissing(db, 'decoded_onehz', e.key, e.value);
    }
  }

Future<void> _ldbPrivEnsureSourceColumns(Database db) async {
    for (final t in const ['decoded_onehz', 'decoded_rr']) {
      await LocalDb._addColumnIfMissing(db, t, 'source', 'TEXT');
    }
  }

Future<void> _ldbPrivRetireDisprovenOneHzColumns(Database db) async {
    final have = await LocalDb._columnsOf(db, 'decoded_onehz');
    // Pre-v34 tables never had the columns; nothing to retire.
    if (!have.contains('on_wrist')) return;
    await db.execute(
      'UPDATE decoded_onehz SET '
      'on_wrist = NULL, '
      'hr_valid = NULL, '
      'skin_temp_c = CASE WHEN skin_temp_c <= -49.995 THEN NULL '
      'ELSE skin_temp_c END '
      'WHERE on_wrist IS NOT NULL OR hr_valid IS NOT NULL '
      'OR skin_temp_c <= -49.995',
    );
  }

Future<void> _ldbPrivCreateNotifSlots(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notif_slots (
        category TEXT NOT NULL,
        dedupe_key TEXT NOT NULL,
        slot INTEGER NOT NULL,
        PRIMARY KEY (category, dedupe_key)
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_notif_slots_owner '
      'ON notif_slots(category, slot)',
    );
  }

Future<void> _ldbPrivEnsureWakeSchema(Database db) async {
    // Mid-ladder the table may not exist yet on an old DB (it is created by the
    // v50 rung and by repair); IF NOT EXISTS makes this safe either way.
    await LocalDb._createAlarmSchedule(db);
    await LocalDb._createWakeTables(db);
    await LocalDb._addColumnIfMissing(db, 'alarm_schedule', 'natural_window_minutes',
        'INTEGER NOT NULL DEFAULT 0');
    await LocalDb._addColumnIfMissing(db, 'alarm_schedule', 'gradual_window_minutes',
        'INTEGER NOT NULL DEFAULT 0');
    await LocalDb._addColumnIfMissing(
        db, 'alarm_schedule', 'gradual_pattern', "TEXT NOT NULL DEFAULT 'ramp'");
    await LocalDb._addColumnIfMissing(db, 'alarm_schedule', 'gradual_cadence_sec',
        'INTEGER NOT NULL DEFAULT 180');
    try {
      await LocalDb._migrateWakeSplit(db);
    } catch (_) {
      // Never brick an open over a copy of one number (invariant 11). No marker
      // is written on failure, so the next open's repair pass retries.
    }
  }

Future<void> _ldbPrivCreateWakeTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wake_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wake_trace (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        wake_epoch INTEGER NOT NULL,
        at_ms      INTEGER NOT NULL,
        kind       TEXT NOT NULL,
        data_json  TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_wake_trace_wake '
        'ON wake_trace(wake_epoch, id)');
  }

Future<void> _ldbPrivMigrateWakeSplit(DatabaseExecutor db) async {
    final done = await db.query('wake_meta',
        where: 'key = ?', whereArgs: ['wake_split_v1'], limit: 1);
    if (done.isNotEmpty) return;
    final rows = await db.query('alarm_schedule',
        columns: ['weekday', 'smart_window_minutes'],
        where: 'smart_window_minutes > 0');
    for (final r in rows) {
      final smart = (r['smart_window_minutes'] as num).toInt();
      final steps = (smart / 15).round().clamp(1, 8).toInt();
      await db.update('alarm_schedule', {'natural_window_minutes': steps * 15},
          where: 'weekday = ?', whereArgs: [r['weekday']]);
    }
    if (rows.isNotEmpty) {
      await db.insert('wake_meta', {'key': LocalDb._wakeUpgradeKey, 'value': 'pending'},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.insert('wake_meta', {'key': 'wake_split_v1', 'value': '1'},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

Future<void> _ldbPrivCreateEcgTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ecg_reading (
        id                    TEXT PRIMARY KEY,
        device_id             TEXT NOT NULL,
        source                TEXT NOT NULL,
        wrist                 TEXT NOT NULL,
        start_ts              INTEGER NOT NULL,
        end_ts                INTEGER NOT NULL,
        strap_terminal_ts     INTEGER,
        strap_terminal_subsec INTEGER,
        result_code           INTEGER NOT NULL,
        category              TEXT NOT NULL,
        avg_hr                INTEGER,
        quality               INTEGER,
        unreadable_mask       INTEGER NOT NULL DEFAULT 0,
        interruptions         INTEGER NOT NULL DEFAULT 0,
        sample_rate_hz        INTEGER NOT NULL DEFAULT 100,
        sample_unit           TEXT NOT NULL DEFAULT 'filtered_input_referred_uv',
        sample_count          INTEGER NOT NULL,
        min_uv                INTEGER,
        max_uv                INTEGER,
        rms_uv                REAL,
        missing_segments      INTEGER NOT NULL DEFAULT 0,
        status                TEXT NOT NULL,
        notes                 TEXT,
        created_at            INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ecg_reading_start '
      'ON ecg_reading(start_ts DESC)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ecg_reading_packet (
        reading_id     TEXT NOT NULL,
        ordinal        INTEGER NOT NULL,
        sequence       INTEGER NOT NULL,
        strap_seconds  INTEGER,
        strap_subsec   INTEGER,
        sample_count   INTEGER NOT NULL,
        samples        BLOB NOT NULL,
        inner_hex      TEXT NOT NULL,
        is_placeholder INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (reading_id, ordinal)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ecg_raw_packet (
        hex           TEXT PRIMARY KEY,
        device_id     TEXT NOT NULL,
        sequence      INTEGER,
        strap_seconds INTEGER,
        strap_subsec  INTEGER,
        captured_at   INTEGER NOT NULL,
        reading_id    TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ecg_raw_packet_strap '
      'ON ecg_raw_packet(strap_seconds)',
    );
    // v57. NULL = unknown/normal, 'gesture' = recorded while a tap
    // gesture held the ECG stream open. Added by ALTER so a table created by
    // an older build gains it; the CREATE above deliberately keeps the old
    // shape so a fresh install and an upgrade run the same code.
    await LocalDb._addColumnIfMissing(db, 'ecg_raw_packet', 'origin', 'TEXT');
    // v66. Why a partial reading stopped ('paused' | 'timeout' |
    // 'disconnected'); NULL for every other status. By ALTER for the same
    // reason as `origin`.
    await LocalDb._addColumnIfMissing(db, 'ecg_reading', 'stop_reason', 'TEXT');
    // One row per gesture session: the strap-clock interval and the outcome,
    // NOTHING else (invariant 14: no samples). The key is the natural one so a
    // restore (INSERT OR REPLACE) can never overwrite a different session.
    // strap_start/strap_end are NULL when the session never learned the strap
    // clock; such a row tags nothing.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ecg_gesture_session (
        device_id   TEXT NOT NULL,
        created_at  INTEGER NOT NULL,
        strap_start INTEGER,
        strap_end   INTEGER,
        final_count INTEGER,
        outcome     TEXT NOT NULL,
        reason      TEXT,
        PRIMARY KEY (device_id, created_at)
      )
    ''');
  }

Future<void> _ldbPrivEnsureEcgPhase1Columns(Database db) async {
    // The table itself first: a database that reached this rung without it
    // (a fixture, a partial restore) gets the whole ECG store, not a failed
    // ALTER that would quarantine the user's data.
    await LocalDb._createEcgTables(db);
    const cols = {
      'mask_any': 'INTEGER',
      'superseded_by': 'TEXT',
      'attempt_group': 'TEXT',
      'attempt': 'INTEGER',
      'live_hr': 'INTEGER',
      'variability_raw': 'INTEGER',
      'firmware_version': 'TEXT',
      'capture_app_version': 'TEXT',
      'capture_table_version': 'INTEGER',
      'start_offset_min': 'INTEGER',
    };
    for (final e in cols.entries) {
      await LocalDb._addColumnIfMissing(db, 'ecg_reading', e.key, e.value);
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ecg_reading_group '
      'ON ecg_reading(attempt_group, attempt)',
    );
  }

Future<void> _ldbPrivCreateStepCalibration(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS step_calibration (
        device_family TEXT NOT NULL,
        wearing       INTEGER NOT NULL,
        factor        REAL NOT NULL,
        n_days        INTEGER NOT NULL,
        version       INTEGER NOT NULL,
        updated_ts    INTEGER NOT NULL,
        PRIMARY KEY (device_family, wearing)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS step_calibration_day (
        day           TEXT NOT NULL,
        device_family TEXT NOT NULL,
        wearing       INTEGER NOT NULL,
        reference_steps INTEGER,
        counter_ticks   INTEGER,
        PRIMARY KEY (day, device_family, wearing)
      )
    ''');
  }

Future<void> _ldbPrivCreateSleepNap(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sleep_nap (
        day_id TEXT NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (day_id, start_ts)
      )
    ''');
  }

Future<void> _ldbPrivCreateVendorSleepEpoch(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vendor_sleep_epoch (
        device_id TEXT NOT NULL,
        night_onset_ts INTEGER NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        stage TEXT NOT NULL,
        source TEXT NOT NULL,
        decoded_at INTEGER NOT NULL,
        PRIMARY KEY (device_id, start_ts)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_vendor_sleep_epoch_night '
        'ON vendor_sleep_epoch(night_onset_ts)');
  }

Future<void> _ldbPrivCreateImportedMeasurement(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS imported_measurement (
        uuid TEXT PRIMARY KEY,
        ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        value REAL NOT NULL,
        unit TEXT NOT NULL,
        source TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_imported_measurement_kind '
      'ON imported_measurement(kind, ts)',
    );
  }

Future<void> _ldbPrivCreateDevice(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS device (
        id          TEXT PRIMARY KEY,
        adapter_id  TEXT,
        remote_id   TEXT,
        label       TEXT,
        tier        TEXT,
        first_seen  INTEGER NOT NULL,
        last_seen   INTEGER NOT NULL,
        role        TEXT NOT NULL DEFAULT 'paired',
        wearing     INTEGER NOT NULL DEFAULT 1
      )
    ''');
  }

Future<void> _ldbPrivCreateObservation(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS observation (
        device_id    TEXT NOT NULL DEFAULT '',
        ts_ms        INTEGER NOT NULL,
        date         TEXT NOT NULL,
        source_kind  TEXT NOT NULL,
        vendor_key   TEXT,
        key          TEXT,
        value        REAL,
        unit         TEXT,
        attribution  TEXT NOT NULL,
        CHECK (vendor_key IS NOT NULL OR key IS NOT NULL)
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_observation_identity '
      'ON observation(device_id, ts_ms, source_kind, COALESCE(vendor_key, key))',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_observation_date '
      'ON observation(date, source_kind)',
    );
  }

Future<void> _ldbPrivCreateImportedWorkout(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS imported_workout (
        uuid TEXT PRIMARY KEY,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        energy_kcal REAL,
        distance_m REAL,
        steps INTEGER,
        source TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_imported_workout_start '
      'ON imported_workout(start_ts)',
    );
  }

Future<void> _ldbPrivCreateExternalHr(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS external_hr (
        ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        hr INTEGER NOT NULL,
        rr_ms TEXT,
        session_id TEXT,
        PRIMARY KEY (ts, source)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_external_hr_session '
      'ON external_hr(session_id)',
    );
  }

Future<void> _ldbPrivCreateDeviceCoverage(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS device_coverage (
        device_id TEXT NOT NULL,
        signal    TEXT NOT NULL,
        start_ts  INTEGER NOT NULL,
        end_ts    INTEGER NOT NULL,
        PRIMARY KEY (device_id, signal, start_ts)
      )
    ''');
    // The resolver's only query shape: every device's coverage for ONE signal
    // over ONE window. `signal` leads because it is always an equality, then
    // start_ts for the range scan.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_coverage_window '
      'ON device_coverage(signal, start_ts, end_ts)',
    );
    // The ingest writer's query: the OPEN interval for one (device, signal),
    // which is the one with the highest start_ts. Without this, extending an
    // interval on every commit is a scan of the whole table.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_coverage_device '
      'ON device_coverage(device_id, signal, start_ts DESC)',
    );
  }

Future<void> _ldbPrivCreateSignalPriority(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS signal_priority (
        signal    TEXT NOT NULL,
        device_id TEXT NOT NULL,
        rank      INTEGER NOT NULL,
        user_set  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (signal, device_id)
      )
    ''');
  }

Future<void> _ldbPrivBackfillDeviceCoverage(Database db) async {
    // A DB whose ladder has not created these must no-op rather than throw.
    for (final t in const ['decoded_onehz', 'device_coverage']) {
      final present = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [t],
      );
      if (present.isEmpty) return;
    }
    // Pre-v47 shape has no device_id; every row is the primary by definition.
    final cols = await LocalDb._columnsOf(db, 'decoded_onehz');
    final dev = cols.contains('device_id') ? 'device_id' : "'${LocalDb.kPrimaryDeviceId}'";

    const kBucket = 60; // seconds — the resolver's grid
    // One interval may absorb a gap of up to this many buckets and stay open.
    // Two buckets, not one: a 1 Hz stream that drops a single second must not
    // split an interval, and anything longer is a real gap the resolver
    // should see. ponytail: fixed at 2; make it cadence-derived only if a
    // real capture shows 2 is wrong.
    const kMaxGapBuckets = 2;

    final specs = <String, String>{
      'hr1Hz': 'hr IS NOT NULL',
      'accel1Hz': 'ax IS NOT NULL AND ay IS NOT NULL AND az IS NOT NULL',
      'ppgRedIr': 'spo2_red_raw IS NOT NULL OR spo2_ir_raw IS NOT NULL',
      'skinTempRaw': 'skin_temp_raw IS NOT NULL',
    };

    final batch = db.batch();
    var queued = 0;

    Future<void> emit(String signal, List<Map<String, Object?>> buckets) async {
      String? openDev;
      int? openStart, openEnd;
      void flush() {
        if (openDev == null) return;
        batch.insert('device_coverage', {
          'device_id': openDev,
          'signal': signal,
          'start_ts': openStart,
          'end_ts': openEnd,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        queued++;
        openDev = null;
      }

      for (final r in buckets) {
        final d = (r['d'] as String?) ?? LocalDb.kPrimaryDeviceId;
        final b = (r['b'] as num).toInt() * kBucket;
        final oe = openEnd;
        if (openDev == d && oe != null && b - oe <= kMaxGapBuckets * kBucket) {
          openEnd = b + kBucket;
          continue;
        }
        flush();
        openDev = d;
        openStart = b;
        openEnd = b + kBucket;
      }
      flush();
    }

    for (final e in specs.entries) {
      // ORDER BY device THEN bucket: the coalescer is a single pass and must
      // see one device's buckets contiguously.
      final rows = await db.rawQuery(
        'SELECT $dev AS d, rec_ts / $kBucket AS b FROM decoded_onehz '
        'WHERE rec_ts > 0 AND (${e.value}) '
        'GROUP BY d, b ORDER BY d ASC, b ASC',
      );
      await emit(e.key, rows);
    }
    // RR beats live in their own table, one row per beat.
    final rrCols = await LocalDb._columnsOf(db, 'decoded_rr');
    if (rrCols.isNotEmpty) {
      final rrDev =
          rrCols.contains('device_id') ? 'device_id' : "'${LocalDb.kPrimaryDeviceId}'";
      final rows = await db.rawQuery(
        'SELECT $rrDev AS d, rec_ts / $kBucket AS b FROM decoded_rr '
        'WHERE rec_ts > 0 GROUP BY d, b ORDER BY d ASC, b ASC',
      );
      await emit('rrIntervals', rows);
    }
    if (queued > 0) await batch.commit(noResult: true);
  }

Future<void> _ldbPrivCreateDerived(Database db) async {
    // derived_day — one row per physiological day. `payload_json` is the full
    // result bundle (all clinical/sleep/respiration/motion/wellness/human metrics,
    // each keeping its tier/confidence/inputs_used) PLUS the per-minute/curve
    // series the UI needs (HR curve, HRV timeline, hypnogram). Frequently queried
    // scalars are indexed into columns for cheap trends.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS derived_day (
        date TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        version INTEGER NOT NULL,
        last_raw_ts INTEGER NOT NULL,
        computed_at INTEGER NOT NULL,
        rhr REAL,
        rmssd REAL,
        readiness REAL
      )
    ''');
    await LocalDb._createBaselines(db);
    // metric_series — long-format scalars for trends / sparklines.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS metric_series (
        date TEXT NOT NULL,
        key TEXT NOT NULL,
        value REAL,
        PRIMARY KEY (date, key)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_metric_series_key ON metric_series(key, date)',
    );
    await LocalDb._createMetricSeriesVersion(db);
  }

Future<void> _ldbPrivCreateMetricSeriesVersion(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS metric_series_version (
        date TEXT PRIMARY KEY,
        algo_version INTEGER NOT NULL,
        source TEXT
      )
    ''');
    // v43 (export-provenance): `source` — WHO produced this day's scalars.
    // ONE table with L13, not two: same day key, same write, same read.
    //
    // `v_daily` is a pure pivot over `metric_series` with no source and no
    // version, so an imported vendor snapshot day and a 1 Hz-derived day are
    // BYTE-IDENTICAL in an export. A file presenting another vendor's derived
    // score beside your band's measured one, unlabelled, is the export
    // surface's version of the fabricated-number law.
    //
    // 'band' means this app derived the day from 1 Hz records. NULL means
    // UNKNOWN and is NEVER retro-filled with a guess — every day written before
    // this column existed reads NULL, and `csvField` already renders that as an
    // empty cell rather than a claim.
    //
    // Hand it back on a table an older build created without it. This helper
    // takes a `DatabaseExecutor` (it is called from inside a transaction), so
    // it cannot use `_addColumnIfMissing`; the throw when the column is already
    // there is the check.
    try {
      await db.execute(
        'ALTER TABLE metric_series_version ADD COLUMN source TEXT',
      );
    } catch (_) {
      /* already present */
    }
    // WHICH BAND'S UNITS this day's scalars are in (B5). Same table, same
    // write, same read as `source` — and the same rules: nullable, no DEFAULT,
    // NEVER retro-filled, because a guessed provenance is worse than none.
    //
    // This is live TODAY on a gen4→gen5 swap, with no second device involved:
    // `skin_temp_adc` holds gen4 ADC COUNTS on one side of the swap and gen5
    // CENTI-DEGREES on the other, under one `metric_series` key, feeding one
    // 28-day baseline that every nightly z-score is taken against. The seam is
    // a step change in the units, not in the person.
    //
    // NOT the same as [_importedDatesSql]'s question. Imported days are ANOTHER
    // ALGORITHM'S OUTPUT and are masked out of every baseline. A foreign family
    // is this app's own maths over a different sensor, so it is masked
    // PER-METRIC — only where the seam makes the number WRONG (different
    // units), never merely noisier. See [foreignFamilyDates].
    try {
      await db.execute(
        'ALTER TABLE metric_series_version ADD COLUMN device_family TEXT',
      );
    } catch (_) {
      /* already present */
    }
    // v51: WHICH DEVICES contributed to this day at all, and WHICH PRIORITY
    // ORDER was in force when it derived.
    //
    // Same rules as `source` and `device_family` above, and they matter more
    // here: nullable, NO DEFAULT, and NEVER retro-filled. A day derived before
    // this column existed has no recorded contributor set, and the honest
    // answer is "not recorded" — attributing it to the primary by assumption
    // would fabricate the one fact this column exists to carry.
    //
    // `coverage_devices` is a comma-joined device_id list, not JSON: it is read
    // as a set for a label ("Ring + Band") and written once per day. A day with
    // one contributor writes that one id, so a single-device install's column
    // reads '' — which is the primary, and is not the same as NULL.
    //
    // `priority_hash` is a short hash of the priority order, for the same
    // reason `algo_version` is here: a change-point search must refuse to run
    // across a priority seam rather than report the day the arbitration
    // changed as a finding about the user.
    for (final c in const ['coverage_devices TEXT', 'priority_hash TEXT']) {
      try {
        await db.execute('ALTER TABLE metric_series_version ADD COLUMN $c');
      } catch (_) {
        /* already present */
      }
    }
    // PER-(date, key) METHOD AND CLASS, beside the per-day stamp above and
    // NOT a column of it or of `metric_series`: both are pivoted into views
    // (and pinned by the band's freeze goldens), so a new column would move
    // every existing day's row. `method` is the method that produced the
    // value; `family` its method family (`hr_1hz`, `hr_1min`, `hr_5min`, or
    // `device`); `class` is ours / device / estimated. Baselines are kept per
    // method family off `family`.
    // Additive, no backfill: a day written before it has no row here, which
    // reads as unknown and is never guessed at.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS metric_method (
        date TEXT NOT NULL,
        key TEXT NOT NULL,
        method TEXT NOT NULL,
        family TEXT NOT NULL,
        class TEXT NOT NULL,
        PRIMARY KEY (date, key)
      )
    ''');
  }

Future<void> _ldbPrivBackfillMetricSeriesVersion(Database db) async {
    // `day_result` may not exist yet on an upgrade path that has not reached
    // the rung which creates it (or on a DB that never had it). A SELECT from a
    // missing table throws, and a throw inside onUpgrade rolls the WHOLE ladder
    // back and quarantines the user's database — the standing trap this file is
    // full of guards against. Nothing to infer from, so infer nothing.
    if ((await LocalDb._columnsOf(db, 'day_result')).isEmpty) return;
    await db.execute(
      'INSERT OR IGNORE INTO metric_series_version (date, algo_version) '
      'SELECT day_id, MAX(algo_version) FROM day_result '
      'WHERE skipped = 0 AND partial = 0 GROUP BY day_id',
    );
  }

Future<void> _ldbPrivCreateDayResult(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS day_result (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        window_json TEXT NOT NULL DEFAULT '{}',
        computed_at INTEGER NOT NULL,
        finalized INTEGER NOT NULL DEFAULT 0,
        rhr REAL,
        rmssd REAL,
        readiness REAL,
        skipped INTEGER NOT NULL DEFAULT 0,
        partial INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day_id, algo_version)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_day_result_day ON day_result(day_id, algo_version)',
    );
  }

Future<void> _ldbPrivEnsureStoreRevisions(Database db) async {
    // Sparse legacy fixtures and partially merged databases may report a
    // schema version whose source table is absent; triggers require its DDL.
    await LocalDb._createBaselines(db);
    await LocalDb._createDayResult(db);
    await LocalDb._createPrimitiveArtifacts(db);
    await db.execute('''
      CREATE TABLE IF NOT EXISTS store_rev (
        id INTEGER PRIMARY KEY AUTOINCREMENT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS row_rev (
        kind TEXT NOT NULL,
        k1 TEXT NOT NULL,
        k2 INTEGER NOT NULL DEFAULT 0,
        rev INTEGER NOT NULL,
        PRIMARY KEY (kind, k1, k2)
      ) WITHOUT ROWID
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS day_result_rev_insert
      AFTER INSERT ON day_result BEGIN
        INSERT INTO store_rev (id) VALUES (NULL);
        INSERT OR REPLACE INTO row_rev (kind, k1, k2, rev)
          VALUES ('day_result', NEW.day_id, NEW.algo_version, last_insert_rowid());
        DELETE FROM store_rev;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS day_result_rev_delete
      AFTER DELETE ON day_result BEGIN
        DELETE FROM row_rev
          WHERE kind = 'day_result' AND k1 = OLD.day_id AND k2 = OLD.algo_version;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS baselines_rev_insert
      AFTER INSERT ON baselines BEGIN
        INSERT INTO store_rev (id) VALUES (NULL);
        INSERT OR REPLACE INTO row_rev (kind, k1, k2, rev)
          VALUES ('baselines', NEW.key, 0, last_insert_rowid());
        DELETE FROM store_rev;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS baselines_rev_update
      AFTER UPDATE OF payload_json ON baselines BEGIN
        INSERT INTO store_rev (id) VALUES (NULL);
        INSERT OR REPLACE INTO row_rev (kind, k1, k2, rev)
          VALUES ('baselines', NEW.key, 0, last_insert_rowid());
        DELETE FROM store_rev;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS baselines_rev_delete
      AFTER DELETE ON baselines BEGIN
        DELETE FROM row_rev WHERE kind = 'baselines' AND k1 = OLD.key AND k2 = 0;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS wake_day_features_rev_insert
      AFTER INSERT ON wake_day_features BEGIN
        INSERT INTO store_rev (id) VALUES (NULL);
        INSERT OR REPLACE INTO row_rev (kind, k1, k2, rev)
          VALUES ('wake_day_features', NEW.day_id, NEW.algo_version, last_insert_rowid());
        DELETE FROM store_rev;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS wake_day_features_rev_update
      AFTER UPDATE OF payload_json ON wake_day_features BEGIN
        INSERT INTO store_rev (id) VALUES (NULL);
        INSERT OR REPLACE INTO row_rev (kind, k1, k2, rev)
          VALUES ('wake_day_features', NEW.day_id, NEW.algo_version, last_insert_rowid());
        DELETE FROM store_rev;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS wake_day_features_rev_delete
      AFTER DELETE ON wake_day_features BEGIN
        DELETE FROM row_rev
          WHERE kind = 'wake_day_features' AND k1 = OLD.day_id AND k2 = OLD.algo_version;
      END
    ''');

    // NO BACKFILL of `row_rev` for wake rows written before these triggers
    // existed. The only way to number them in one statement is a window
    // function (ROW_NUMBER() OVER), which is SQLite 3.25; minSdk 26 ships 3.18,
    // and this runs on every open (`_repairOpenSchema`), so it would stop the
    // database opening on Android 8-10. A legacy row simply has no revision
    // (the same as `day_result` rows from before P2.1, never backfilled): the
    // JSON lane never caches a revision-less row and compares its text when it
    // revalidates, and the row gains a revision the next time it is written.
  }

Future<void> _ldbPrivCreateJournalMetric(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal_metric (
        date TEXT NOT NULL,
        field TEXT NOT NULL,
        value REAL NOT NULL,
        at_min INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (date, field)
      )
    ''');
    // Correlations read one field across every day, so the index is on the
    // field first — the primary key already covers day-scoped reads.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_journal_metric_field '
      'ON journal_metric(field, date)',
    );
  }

Future<void> _ldbPrivCreateJournalFieldDef(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal_field_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        kind TEXT NOT NULL,
        unit TEXT NOT NULL DEFAULT '',
        max_value REAL NOT NULL,
        step REAL NOT NULL,
        has_time INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
  }

Future<void> _ldbPrivCreateLabTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_result (
        marker TEXT NOT NULL,
        taken_on TEXT NOT NULL,
        value REAL NOT NULL,
        unit TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (marker, taken_on)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_marker_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        unit TEXT NOT NULL,
        category TEXT NOT NULL,
        decimals INTEGER NOT NULL DEFAULT 1,
        ref_low REAL,
        ref_high REAL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

Future<void> _ldbPrivCreateBreathingSessions(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS breathing_session (
        started_at INTEGER PRIMARY KEY,
        ended_at INTEGER NOT NULL,
        pattern TEXT NOT NULL,
        seconds INTEGER NOT NULL,
        coherence REAL,
        confidence REAL,
        pre_rmssd REAL,
        post_rmssd REAL
      )
    ''');
  }

Future<void> _ldbPrivCreateStrengthTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS strength_set (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        exercise_key TEXT NOT NULL,
        set_index INTEGER NOT NULL,
        reps INTEGER,
        load_kg REAL,
        rpe INTEGER,
        hold_sec INTEGER,
        rest_sec INTEGER,
        at_ts INTEGER,
        note TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (session_id, seq)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_strength_set_ex '
      'ON strength_set(exercise_key, at_ts)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS exercise_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        muscles_json TEXT NOT NULL DEFAULT '{}',
        equipment TEXT NOT NULL DEFAULT '',
        unilateral INTEGER NOT NULL DEFAULT 0,
        custom INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
  }

Future<void> _ldbPrivCreateUserTables(Database db) async {
    // journal — one row per day; tags is a JSON string list, note free text.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal (
        date TEXT PRIMARY KEY,
        tags_json TEXT NOT NULL DEFAULT '[]',
        note TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL
      )
    ''');
    await LocalDb._createJournalMetric(db);
    await LocalDb._createJournalFieldDef(db);
    await LocalDb._createLabTables(db);
    await LocalDb._createBreathingSessions(db);
    await LocalDb._createStrengthTables(db);
    // Nutrition (food_entry + food_def) and medication (med_def + med_dose).
    // Both live in their own files with their models and rollup logic — the
    // DDL belongs next to the code that reads it, not two thousand lines away.
    await createNutritionTables(db);
    await createMedTables(db);
    // cycle_log — menstrual cycle markers; `kind` is 'start' (cycle start) etc.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cycle_log (
        date TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        note TEXT
      )
    ''');
    // sessions — manual/live/auto workouts; status 'live'|'done', zone tallies JSON.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        calories REAL,
        strain REAL,
        max_hr INTEGER,
        duration_min INTEGER,
        zone_min_json TEXT,
        steps INTEGER,
        cadence_spm INTEGER,
        hrr_bpm REAL,
        source TEXT NOT NULL DEFAULT 'manual',
        private INTEGER NOT NULL DEFAULT 0,
        device_family TEXT,
        trace_json TEXT,
        trace_samples INTEGER,
        rpe REAL,
        created_at INTEGER NOT NULL
      )
    ''');
    // workout_suggestions — opt-in "did you work out?" auto-detections. Never a
    // real session until the user confirms; `dismissed` hides a rejected one.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workout_suggestions (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        avg_bpm INTEGER,
        peak_bpm INTEGER,
        duration_min INTEGER,
        sport TEXT,
        dismissed INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    // notifications — locally-generated insight feed (illness/anomaly/temp/readiness).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notifications (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        date TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        read INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

Future<void> _ldbPrivCreateSyncState(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_ledger (
        chunk_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        acked_at INTEGER,
        last_error TEXT,
        meta_json TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_quarantine (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        reason TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_quarantine_created ON sync_quarantine(created_at)',
    );
  }

Future<void> _ldbPrivCreateComputeState(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS compute_freshness (
        key TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS compute_jobs (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        scope TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 0,
        state TEXT NOT NULL,
        reason TEXT,
        depends_on TEXT,
        input_from_ts INTEGER,
        input_to_ts INTEGER,
        algo_version INTEGER,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_run_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_compute_jobs_state_pri ON compute_jobs(state, priority DESC, updated_at ASC)',
    );
  }

Future<void> _ldbPrivCreatePrimitiveArtifacts(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sleep_session_candidates (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        computed_at INTEGER NOT NULL,
        PRIMARY KEY(day_id, algo_version)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wake_day_features (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        computed_at INTEGER NOT NULL,
        PRIMARY KEY(day_id, algo_version)
      )
    ''');
  }

Future<void> _ldbPrivEnsureSessionTraceColumns(Database db) async {
    await LocalDb._addColumnIfMissing(db, 'sessions', 'trace_json', 'TEXT');
    await LocalDb._addColumnIfMissing(db, 'sessions', 'trace_samples', 'INTEGER');
  }

Future<void> _ldbPrivEnsureSessionSchema(Database db) async {
    await LocalDb._addColumnIfMissing(db, 'sessions', 'steps', 'INTEGER');
    await LocalDb._addColumnIfMissing(db, 'sessions', 'hrr_bpm', 'REAL');
    // Mean HR over the session window. Stored rather than recomputed because
    // the 1 Hz substrate it comes from is pruned at `rawRetentionDays`: without
    // a column every workout older than that permanently loses its average,
    // while `max_hr` (already a column) survives. Additive + nullable, so old
    // rows read NULL — the truth for them — and the read path still recomputes
    // from the substrate while it is there.
    await LocalDb._addColumnIfMissing(db, 'sessions', 'avg_hr', 'INTEGER');
    // Submax VO2max estimate (ml/kg/min), backfilled from a completed km
    // route split — see `_submaxVo2maxFromSplits` in local_repository_impl.
    // ESTIMATE tier always; absent (NULL) is the honest default, not 0.
    await LocalDb._addColumnIfMissing(db, 'sessions', 'vo2max_estimate', 'REAL');
    // v43 (TS-09) — SESSION RPE. A SELF-REPORT, and labelled as one everywhere
    // it is ever shown. It exists to score the sessions heart rate cannot see
    // (lifting, climbing, anything intermittent) and its real value is the
    // DISAGREEMENT with TRIMP — a feeling compared against a measurement.
    //
    // NULLABLE WITH NO DEFAULT, and that is load-bearing: the set-level picker
    // already defaults to 7, which is a garbage-data mechanism already running.
    // A session nobody rated must read as UNRATED, not as a 7 somebody typed.
    // Skippable forever.
    await LocalDb._addColumnIfMissing(db, 'sessions', 'rpe', 'REAL');
    // Private session (v40): the user's "don't surface this one" flag. NOT NULL
    // DEFAULT 0 because every session that already exists was not marked
    // private — absence here is a real answer, not a missing measurement.
    await LocalDb._addColumnIfMissing(
      db,
      'sessions',
      'private',
      'INTEGER NOT NULL DEFAULT 0',
    );
    // Which strap measured this workout (v41) — see _ensureDeviceFamilyColumns.
    // NULL on every existing row, on a hand-entered session, and on an import:
    // no link produced them, so their provenance is genuinely unknown.
    await LocalDb._addColumnIfMissing(db, 'sessions', 'device_family', 'TEXT');
    // Measured walking cadence for the session (v43, steps/min) — the median of
    // the gait-like minutes the live 100 Hz pedometer counted (see
    // `ble/live_cadence.dart`). NULL means the session had no walking to have a
    // cadence for, which is most of them: it is an absence, never a 0.
    await LocalDb._addColumnIfMissing(db, 'sessions', 'cadence_spm', 'INTEGER');
    // Set only by `_reconcileOrphanedLiveWorkout` on a stale `status='live'`
    // row it finalizes without ever having seen the real finish: `end_ts` there
    // is reconcile-time, not a measurement. `_writeOneWorkout` skips any row
    // with this set so that fabricated duration never reaches Apple
    // Health/Health Connect on the next periodic export pass. NOT NULL DEFAULT
    // 0: every existing/normal row really did finish for real.
    await LocalDb._addColumnIfMissing(
      db,
      'sessions',
      'end_ts_fabricated',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await LocalDb._ensureSessionTraceColumns(db);
    // Which workout sensors scored a session ([stampSessionSensor]), one row
    // each: a strap serving both heart-rate services can hand the live
    // source from one to the other mid-workout. A side table, not a
    // `sessions` column: the stamp outlives the sensor's raw rows, which are
    // pruned at `rawRetentionDays`.
    await db.execute(
      'CREATE TABLE IF NOT EXISTS session_sensor '
      '(session_id TEXT NOT NULL, source TEXT NOT NULL, '
      'PRIMARY KEY (session_id, source))',
    );
    // A pre-release build keyed it by session alone; rebuild that shape so a
    // second sensor stops replacing the first. Every open, so a no-op after.
    final pk = await db.rawQuery('PRAGMA table_info(session_sensor)');
    if (!pk.any((c) => c['name'] == 'source' && (c['pk'] as int? ?? 0) > 0)) {
      // Plain statements, no transaction: this also runs inside onUpgrade's.
      await db.execute('ALTER TABLE session_sensor RENAME TO session_sensor_v1');
      await db.execute(
        'CREATE TABLE session_sensor (session_id TEXT NOT NULL, '
        'source TEXT NOT NULL, PRIMARY KEY (session_id, source))',
      );
      await db.execute('INSERT INTO session_sensor SELECT session_id, source '
          'FROM session_sensor_v1');
      await db.execute('DROP TABLE session_sensor_v1');
    }
    // `sessions` is keyed by a TEXT id, so every read that matters — the
    // workouts list, the activity tab, both `decoded_onehz` HR joins,
    // [sessionsInRange], [liveSessions] — was a full table scan plus a full
    // sort on an unindexed column. Nothing prunes `sessions` either (only an
    // explicit day delete), so the scan grows for the life of the install.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sessions_start ON sessions(start_ts)',
    );
  }

Future<void> _ldbPrivEnsureCoachViews(Database db) async {
    const views = [
      'v_metric',
      'v_daily',
      'v_series',
      'v_hypnogram',
      'v_sessions',
      'v_baselines',
      'v_insights',
      'v_ecg_readings',
    ];
    for (final v in views) {
      await db.execute('DROP VIEW IF EXISTS $v');
    }
    // Long-form scalar trends — the natural per-metric time series.
    await db.execute('''
      CREATE VIEW v_metric AS
      SELECT date, key, value FROM metric_series
    ''');
    // One row per day, common scalars pivoted from metric_series (no JSON path
    // drift; metric_series is the canonical scalar store).
    await db.execute('''
      CREATE VIEW v_daily AS
      SELECT date,
        MAX(CASE WHEN key='rhr' THEN value END)            AS resting_hr,
        MAX(CASE WHEN key='rmssd' THEN value END)          AS hrv,
        MAX(CASE WHEN key='sdnn' THEN value END)           AS sdnn,
        MAX(CASE WHEN key='readiness' THEN value END)      AS readiness,
        MAX(CASE WHEN key='strain' THEN value END)         AS strain,
        MAX(CASE WHEN key='resp_rate' THEN value END)      AS resp_rate,
        MAX(CASE WHEN key='stress' THEN value END)         AS stress,
        MAX(CASE WHEN key='efficiency' THEN value END)     AS sleep_efficiency,
        MAX(CASE WHEN key='tst_min' THEN value END)        AS sleep_min,
        MAX(CASE WHEN key='deep_min' THEN value END)       AS deep_min,
        MAX(CASE WHEN key='rem_min' THEN value END)        AS rem_min,
        MAX(CASE WHEN key='light_min' THEN value END)      AS light_min,
        MAX(CASE WHEN key='nap_min' THEN value END)        AS nap_min,
        MAX(CASE WHEN key='steps' THEN value END)          AS steps,
        MAX(CASE WHEN key='calories' THEN value END)       AS active_calories,
        MAX(CASE WHEN key='calories_total' THEN value END) AS total_calories,
        MAX(CASE WHEN key='skin_temp_z' THEN value END)    AS skin_temp_z,
        MAX(CASE WHEN key='lf_hf' THEN value END)          AS lf_hf,
        MAX(CASE WHEN key='hrv_cv' THEN value END)         AS hrv_cv,
        MAX(CASE WHEN key='dip_pct' THEN value END)        AS dip_pct,
        MAX(CASE WHEN key='odi_per_hour' THEN value END)   AS odi_per_hour,
        MAX(CASE WHEN key='worn_min' THEN value END)       AS worn_min,
        MAX(CASE WHEN key='hrr_bpm' THEN value END)        AS hrr_bpm,
        MAX(CASE WHEN key='brv_cv' THEN value END)         AS brv_cv,
        MAX(CASE WHEN key='irregular_rhythm_flag' THEN value END) AS irregular_flag
      FROM metric_series GROUP BY date
    ''');
    // Intra-day curves UNNESTED from the latest day_result bundle. HEAVY — always
    // filter by date AND series. zone_timeline uses 'z'; activity_curve is root.
    //
    // THREE SHAPES, one row each. A curve is stored either legacy
    // (`[{t,v},…]`), grid (`{t0,dt,v[]}`) or offset (`{t0,to[],v[]}`) — see
    // data/series_codec.dart for why. Old rows keep their legacy shape forever,
    // so this view must read all three, and the branch guards are what keep a
    // row from being emitted twice: legacy requires an `array`, grid requires
    // `.dt`, offset requires `.to` AND no `.dt`. The codec never writes both,
    // but "never" is not enforced by the storage layer — a foreign or corrupted
    // curve carrying both fields matched the grid and offset branches at once
    // and silently doubled the curve. The `.dt` precedence also matches
    // SeriesCodec.decodeCurve, so SQL and Dart resolve an ambiguous curve the
    // same way rather than disagreeing.
    //
    // `latest` filters on json_valid first: json_extract raises on a malformed
    // document, and without the guard ONE corrupt payload fails the entire
    // v_series query instead of dropping that one day. Same guard, same reason,
    // as daysWithSleepTst.
    //
    // The grid branch needs no running sum because json_each exposes an array's
    // index as `key`, so t = t0 + key*dt. Verified row-for-row against the
    // pre-codec view on the three tracked bundle fixtures, including a database
    // holding both shapes at once (test/coach_views_series_shapes_test.dart).
    //
    // The offset branch walks `.v` ONCE and indexes into `.to` by that key. The
    // obvious form — json_each over `.to` joined to json_each over `.v` on
    // `key` — is quadratic: SQLite cannot index a table-valued function, so the
    // join degrades to a full cross product of the two and the cost grows with
    // the SQUARE of the curve length. hrv_day, hrv_timeline and resp_day are
    // all irregularly sampled and therefore all offset-encoded, so this is the
    // hot path, not a corner: on 365 real days a `SELECT AVG(v)` measured 877 ms
    // against 89 ms, and on 1440-point curves a 30-day slice took 2.1 s. The
    // `e.key < json_array_length(.to)` bound is what keeps the rewrite
    // row-for-row identical rather than merely equivalent on well-formed data —
    // the join emitted min(len(to), len(v)) rows, and without the bound a `to`
    // shorter than `v` would gain rows with a NULL `t`. Pinned by a query-plan
    // assertion in test/coach_views_series_shapes_test.dart: two nested virtual
    // table scans in this branch is the regression.
    await db.execute('''
      CREATE VIEW v_series AS
      WITH latest AS (
        SELECT r.day_id, r.payload_json FROM day_result r
        ${LocalDb._servedDayJoin}
        WHERE json_valid(r.payload_json)
      ),
      curve(sk, pth, vk) AS (
        SELECT 'hr_curve','\$.series.hr_curve','\$.v'
        UNION ALL SELECT 'strain_curve','\$.series.strain_curve','\$.v'
        UNION ALL SELECT 'hrv_timeline','\$.series.hrv_timeline','\$.v'
        UNION ALL SELECT 'hrv_day','\$.series.hrv_day','\$.v'
        UNION ALL SELECT 'resp_day','\$.series.resp_day','\$.v'
        UNION ALL SELECT 'skin_temp_day','\$.series.skin_temp_day','\$.v'
        UNION ALL SELECT 'zone_timeline','\$.series.zone_timeline','\$.z'
        UNION ALL SELECT 'activity_curve','\$.activity_curve','\$.v'
      )
      SELECT l.day_id AS date, c.sk AS series,
             json_extract(e.value,'\$.t') AS t,
             json_extract(e.value, c.vk) AS v
      FROM latest l JOIN curve c
      JOIN json_each(json_extract(l.payload_json, c.pth)) e
      WHERE json_type(json_extract(l.payload_json, c.pth)) = 'array'
      UNION ALL
      SELECT l.day_id, c.sk,
             json_extract(l.payload_json, c.pth||'.t0')
               + e.key * json_extract(l.payload_json, c.pth||'.dt'),
             e.value
      FROM latest l JOIN curve c
      JOIN json_each(json_extract(l.payload_json, c.pth||'.v')) e
      WHERE json_extract(l.payload_json, c.pth||'.dt') IS NOT NULL
      UNION ALL
      SELECT l.day_id, c.sk,
             json_extract(l.payload_json, c.pth||'.t0')
               + json_extract(l.payload_json, c.pth||'.to['||e.key||']'),
             e.value
      FROM latest l JOIN curve c
      JOIN json_each(json_extract(l.payload_json, c.pth||'.v')) e
      WHERE json_extract(l.payload_json, c.pth||'.dt') IS NULL
        AND json_extract(l.payload_json, c.pth||'.to') IS NOT NULL
        AND e.key < json_array_length(json_extract(l.payload_json, c.pth||'.to'))
    ''');
    // Sleep stage segments (different element shape from the {t,v} curves).
    // Same json_valid guard as v_series and for the same reason: without it one
    // malformed payload_json anywhere in day_result makes this view THROW, so a
    // single corrupt row takes every day's sleep stages away from the coach
    // instead of just its own.
    await db.execute('''
      CREATE VIEW v_hypnogram AS
      WITH latest AS (
        SELECT r.day_id, r.payload_json FROM day_result r
        ${LocalDb._servedDayJoin}
        WHERE json_valid(r.payload_json)
      )
      SELECT l.day_id AS date,
             json_extract(e.value,'\$.start') AS start_ts,
             json_extract(e.value,'\$.end')   AS end_ts,
             json_extract(e.value,'\$.stage') AS stage
      FROM latest l, json_each(json_extract(l.payload_json,'\$.series.hypnogram')) e
    ''');
    // Workouts (incl. HRR + steps). `date` is the session's LOCAL calendar day
    // (device-local, same 'localtime' pattern as dataHistoryDays()) — added so
    // "today's workout" can be resolved with `WHERE date = 'YYYY-MM-DD'`
    // instead of the coach having to convert a local day back into a raw
    // start_ts/end_ts epoch range itself, which silently drifted to UTC
    // (issue #129: coach mis-dated workouts near local-midnight boundaries).
    // Private sessions stay out: this view is what the coach and the CSV
    // export read, and private means hidden from both.
    // A session only a now flag-off device measured serves its scores empty
    // here too (rule R6); [refreshSessionScoreMask] keeps the mask current.
    await db.execute(
      'CREATE TABLE IF NOT EXISTS session_score_mask '
      '(session_id TEXT PRIMARY KEY)',
    );
    await db.execute('''
      CREATE VIEW v_sessions AS
      SELECT id, start_ts, end_ts,
             strftime('%Y-%m-%d', start_ts, 'unixepoch', 'localtime') AS date,
             type, status,
             CASE WHEN m.session_id IS NULL THEN calories END AS calories,
             CASE WHEN m.session_id IS NULL THEN strain END AS strain,
             CASE WHEN m.session_id IS NULL THEN max_hr END AS max_hr,
             duration_min, steps,
             CASE WHEN m.session_id IS NULL THEN hrr_bpm END AS hrr_bpm,
             source,
             CASE WHEN m.session_id IS NULL THEN zone_min_json END
               AS zone_min_json
      FROM sessions
      LEFT JOIN session_score_mask m ON m.session_id = sessions.id
      WHERE private = 0
    ''');
    // Rolling personal baselines (json_extract; missing paths return NULL safely).
    await db.execute('''
      CREATE VIEW v_baselines AS
      SELECT key,
             json_extract(payload_json,'\$.value')           AS value,
             json_extract(payload_json,'\$.mean')            AS mean,
             json_extract(payload_json,'\$.z')               AS z,
             json_extract(payload_json,'\$.delta')           AS delta,
             json_extract(payload_json,'\$.ratio')           AS ratio,
             json_extract(payload_json,'\$.n')               AS n,
             updated_at
      FROM baselines
    ''');
    // Locally-generated insight / notification feed.
    await db.execute('''
      CREATE VIEW v_insights AS
      SELECT id, kind, title, body, date, created_at, read FROM notifications
    ''');
    // WHOOP MG ECG readings — SUMMARY ONLY, and from `ecg_reading` ALONE.
    // The coach's structural (btree) guard admits every base table a view
    // reads, so joining ecg_reading_packet or ecg_raw_packet here would make
    // the exact sample bytes / raw frames reachable through run_sql. The
    // bounded waveform envelope is served by the typed get_ecg_reading tool
    // instead. No device_id (band identity) and no free-text notes. `date` is
    // the LOCAL day like v_sessions; start_ts/end_ts are epoch SECONDS.
    //
    // Design 04: superseded attempts are not listed (the latest attempt of a
    // group is the reading), and the stored band value is exposed as
    // `band_category` because it is only what the BAND said. What the reading
    // MEANS (not readable / inconclusive / partial / a band-reported rhythm) is
    // decided in Dart by ecgOutcome and reaches the coach through
    // get_ecg_reading; SQL never computes it.
    await db.execute('''
      CREATE VIEW v_ecg_readings AS
      SELECT id, start_ts, end_ts,
             strftime('%Y-%m-%d', start_ts, 'unixepoch', 'localtime') AS date,
             wrist, status, category AS band_category, result_code, avg_hr,
             quality, unreadable_mask, interruptions, stop_reason,
             (end_ts - start_ts) AS duration_s,
             sample_count, sample_rate_hz, sample_unit,
             min_uv, max_uv, rms_uv, missing_segments
      FROM ecg_reading
      WHERE superseded_by IS NULL
    ''');
  }

Future<void> _ldbPrivMigrateLegacyTable(Database db, {required String table, required bool Function(Set<String> columns) isCurrent, required Future<void> Function(DatabaseExecutor ex) create, required Future<void> Function(DatabaseExecutor ex, List<Map<String, Object?>> legacyRows, int nowMs) copy, required bool copyOnlyIntoEmpty}) async {
    final legacy = '${table}_legacy';
    await db.transaction((txn) async {
      Future<bool> exists(String t) async => (await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [t],
      )).isNotEmpty;
      Future<Set<String>> columnsOf(String t) async {
        final info = await txn.rawQuery('PRAGMA table_info($t)');
        return {
          for (final c in info)
            if (c['name'] is String) c['name'] as String,
        };
      }

      if (!await exists(legacy)) {
        // Normal path.
        if (!await exists(table)) {
          await create(txn);
          return;
        }
        if (isCurrent(await columnsOf(table))) return;
        await txn.execute('ALTER TABLE $table RENAME TO $legacy');
      }
      // From here on `<table>_legacy` holds the rows of record. `<table>` is
      // either absent (crash between RENAME and CREATE) or the new shape
      // (possibly half-copied, or fully copied by an older build that then
      // died before the DROP) — create it if needed and re-copy; the copy is
      // idempotent, so a repeat is a no-op rather than a duplication.
      if (!await exists(table)) await create(txn);
      final skipCopy =
          copyOnlyIntoEmpty &&
          (Sqflite.firstIntValue(
                    await txn.rawQuery('SELECT COUNT(*) FROM $table'),
                  ) ??
                  0) >
              0;
      if (!skipCopy) {
        await copy(
          txn,
          await txn.query(legacy),
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      await txn.execute('DROP TABLE $legacy');
    });
  }

Future<void> _ldbPrivEnsureSyncCursorSchema(Database db) =>
      LocalDb._migrateLegacyTable(
        db,
        table: 'sync_cursor',
        isCurrent: (c) =>
            c.contains('name') &&
            c.contains('value') &&
            c.contains('updated_at'),
        create: LocalDb._createSyncCursor,
        copy: (ex, legacyRows, now) async {
          for (final row in legacyRows) {
            final name = row['name'] as String?;
            if (name == null || name.isEmpty) continue;
            await ex.insert('sync_cursor', {
              'name': name,
              'value': row['value']?.toString(),
              'updated_at': (row['updated_at'] as num?)?.toInt() ?? now,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        },
      );

Future<void> _ldbPrivEnsureSyncLedgerSchema(Database db) =>
      LocalDb._migrateLegacyTable(
        db,
        table: 'sync_ledger',
        isCurrent: (c) => c.contains('chunk_id'),
        create: LocalDb._createSyncState,
        copy: (ex, legacyRows, now) async {
          for (final row in legacyRows) {
            final meta = <String, dynamic>{
              'last_batch_token': row['last_batch_token'],
              'last_batch_id': row['last_batch_id'],
              'last_batch_records': row['last_batch_records'],
              'last_history_complete_at': row['last_history_complete_at'],
              'last_trim_cutoff_ms': row['last_trim_cutoff_ms'],
              'last_trimmed_at': row['last_trimmed_at'],
              if (row['note'] != null) 'legacy_note': row['note'],
            };
            await ex.insert('sync_ledger', {
              'chunk_id': (row['id'] as String?) ?? 'capture',
              'kind': 'historical',
              'status': row['last_history_complete_at'] != null
                  ? 'complete'
                  : row['last_batch_acked_at'] != null
                  ? 'acknowledged'
                  : 'legacy',
              'created_at': (row['updated_at'] as num?)?.toInt() ?? now,
              'updated_at': (row['updated_at'] as num?)?.toInt() ?? now,
              'acked_at': (row['last_batch_acked_at'] as num?)?.toInt(),
              'last_error': null,
              'meta_json': jsonEncode(meta),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        },
      );

Future<void> _ldbPrivEnsureSyncQuarantineSchema(Database db) =>
      LocalDb._migrateLegacyTable(
        db,
        table: 'sync_quarantine',
        isCurrent: (c) => c.contains('payload_json'),
        create: LocalDb._createSyncState,
        // `id INTEGER PRIMARY KEY AUTOINCREMENT` — no natural key to REPLACE
        // on, so a resume must not re-copy into a destination that already has
        // rows or the quarantine log would double on every retry.
        copyOnlyIntoEmpty: true,
        copy: (ex, legacyRows, now) async {
          for (final row in legacyRows) {
            await ex.insert('sync_quarantine', {
              'kind': (row['source_role'] as String?) ?? 'legacy',
              'payload_json': jsonEncode({
                'fingerprint': row['fingerprint'],
                'packet_type': row['packet_type'],
                'hex': row['hex'],
                'counter': row['counter'],
                'captured_at': row['captured_at'],
              }),
              'reason': (row['reason'] as String?) ?? 'legacy_migrated',
              'created_at': (row['created_at'] as num?)?.toInt() ?? now,
            });
          }
        },
      );

Future<void> _ldbPrivCreateDecodedStore(Database db) async {
    // KEYED BY rec_ts, NOT the band's record `counter`. The strap resets its
    // per-record counter to ~0 on every reboot, so `counter INTEGER PRIMARY KEY`
    // let a post-reboot record (counter=c, rec_ts=T2) REPLACE-evict a still-present
    // pre-reboot row (counter=c, rec_ts=T1) — silently and UNRECOVERABLY deleting
    // T1's only decoded 1 Hz row (raw_records is DROPped, so this store is the sole
    // system of record). rec_ts is unique per real second, so newest-wins REPLACE
    // on rec_ts is safe. `counter` is demoted to a NOT NULL forensic column (also
    // the keyset-cursor tiebreak in decodedOneHzBatchByRecTsRange, which never
    // fires now that rec_ts is unique).
    //
    // v47: KEYED BY (device_id, ts_ms), NOT rec_ts alone. `rec_ts` stays as the
    // indexed READ key — every query in this file and in health_export ranges
    // over it — but it can no longer be the identity, because a second device
    // measuring the same second is a DIFFERENT reading, and REPLACE on a
    // shared rec_ts silently deletes the first one (and no raw copy is kept
    // to rebuild it, so that loss is permanent). See [_rekeyTableByDevice].
    //
    // `device_id = ''` IS RESERVED PERMANENTLY FOR THE PRIMARY BAND. Not a
    // migration default — a standing rule, and it is load-bearing twice over:
    //  * The newest-wins dedupe above only works if every row from the one
    //    physical band shares one key value. A post-reboot counter reset and a
    //    re-drained record must still collide on (device_id, ts_ms).
    //  * A BLE `remoteId` is NOT STABLE (per-app CBPeripheral UUID on iOS, a
    //    rotating RPA on Android). Letting one reach this column would
    //    fragment one band into N identities across reinstalls, each with its
    //    own baseline. Only a SECONDARY device gets a real id, and only one an
    //    adapter issues from something the band emits across the handshake.
    //
    // `ts_ms` is `rec_ts * 1000` for every WHOOP row and for every row this
    // migration rewrites, so the key is EXACTLY as unique as it was — no
    // number moves. The millisecond resolution is there so a source faster
    // than 1 Hz has somewhere to land instead of REPLACE-ing itself down to
    // one row per second, which is the same defect in a different table.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_onehz (
        device_id TEXT NOT NULL DEFAULT '',
        ts_ms INTEGER NOT NULL DEFAULT 0,
        -- NOT re-asserted NOT NULL, deliberately: [_rekeyTableByDevice] copies
        -- this column verbatim out of a table where SQLite never enforced it
        -- (a declared PRIMARY KEY on a legacy rowid table does not imply NOT
        -- NULL), and a constraint failure inside onUpgrade's one exclusive
        -- transaction quarantines the whole database (invariant 11).
        rec_ts INTEGER,
        counter INTEGER NOT NULL,
        hr INTEGER,
        ax REAL,
        ay REAL,
        az REAL,
        spo2_red_raw INTEGER,
        spo2_ir_raw INTEGER,
        skin_temp_raw INTEGER,
        step_count INTEGER,
        step_cadence INTEGER,
        activity_class INTEGER,
        skin_temp_c REAL,
        on_wrist INTEGER,
        hr_valid INTEGER,
        hr_alt INTEGER,
        ambient_raw INTEGER,
        device_family TEXT,
        source TEXT,
        temp_ch2_c REAL,
        temp_ch3_c REAL,
        signal_quality_logvar REAL,
        dyn_accel_g REAL,
        PRIMARY KEY (device_id, ts_ms)
      )
    ''');
    // v43: `hr` IS NULLABLE TOO, and it is the last sensor column to get there.
    //
    // `hr == 0` is this app's OFF-SKIN SENTINEL, and the NOT NULL forced every
    // record carrying no heart-rate field at all to be written as one. That is
    // a different claim — "the band was off your wrist" instead of "this record
    // has no HR" — and it is the reason the gen4 v25 record is archived instead
    // of banked: a 24 Hz PPG burst with a decoder-validated gravity vector and
    // genuinely no beat anywhere in it (ble_engine's own note says so), ~50 000
    // seconds per real export. NULL says the honest thing, and the app already
    // agrees with it everywhere: every SQL read of this column is gated
    // `hr > 0` (which NULL fails) or is an aggregate (which skips NULL), and
    // every Dart read lands NULL on the same 0 the substrate has always used
    // for "no heart rate this second".
    //
    // What it does NOT buy: a NULL-hr second is observed for the REST window
    // and UNOBSERVED for staging. It carries no beat, so it can never
    // contribute to a stage, an RHR, an HRV or the cardiac-evidence test —
    // analytics' observed mask is `sampled[i] && hrNear[i]` and only `sampled`
    // flips. Expect a 1-5 pp lift in observed fraction plus denser gravity.
    //
    // Every band-computed column above is NULLABLE ON PURPOSE: only a gen5 band
    // sends them, and a gen4 row must read back as "not reported", not as zero
    // steps / 0 °C / "off wrist". No DEFAULT, ever.
    //
    // v39: the SENSOR columns (ax/ay/az, spo2_*, skin_temp_raw) are nullable for
    // the same reason. They were `NOT NULL`, so `commitSyncBatch` coerced an
    // absent reading to `?? 0` and the ledger stored a fabricated measurement —
    // a real 0 g gravity vector and a real ADC count of 0. A record can
    // legitimately carry HR without accel (gen5 v18, and the gen4 R10-historical
    // path decodes HR/counter only), and gen5 has no equivalent of the gen4
    // optical/thermal ADCs at all, so those three are ALWAYS absent there.
    // Absence now lands as NULL. `_relaxDecodedSensorNulls` (v39) rebuilds the
    // table on existing installs.
    // `on_wrist` and `hr_valid` currently have NO honest writer at all — the
    // gen5 v18 bits once mapped onto them are disproven (see
    // `sampleFromGen5Historical` and _retireDisprovenOneHzColumns), so every
    // row written since that mapping change stores NULL. The columns are kept, nullable and
    // correctly shaped, for a source that can actually supply them; they are
    // NOT a place to park a plausible-looking bit.
    await LocalDb._ensureDecodedOneHzBandFields(db);
    // NO index on `counter`. There was one, described as a forensic-only
    // lookup — and nothing in the app ever filtered or ordered by `counter`
    // alone (every decoded read is `ORDER BY rec_ts, counter`, which a
    // single-column counter index cannot serve). It cost a b-tree insert per
    // 1 Hz record on the hottest write path in the app, ~1.7 MB/day of disk,
    // and the inserts were NON-SEQUENTIAL because `counter` resets to ~0 on a
    // band reboot — so it was paying page splits on the ingest path for a
    // query nobody makes. Dropped for existing installs in _repairOpenSchema.
    // decoded_rr shares its parent's key EXACTLY, one level deeper: PRIMARY KEY
    // (device_id, ts_ms, beat_index) against the parent's (device_id, ts_ms).
    // Parent and child still delete/replace by the SAME key, so no orphan guard
    // is needed — and that is the whole reason the two keys must move together.
    // Before v47 `_queueRrBeats` cleared the second with an unscoped
    // `DELETE ... WHERE rec_ts = ?`, which for a second device deleted the
    // FIRST band's beats for that second and could not be undone.
    // rr_ts_ms (= rec_ts*1000) stays as the per-beat timestamp the compute
    // worker reads; `rec_ts` stays as the indexed range key.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_rr (
        device_id TEXT NOT NULL DEFAULT '',
        ts_ms INTEGER NOT NULL DEFAULT 0,
        rec_ts INTEGER NOT NULL,
        beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        device_family TEXT,
        source TEXT,
        PRIMARY KEY (device_id, ts_ms, beat_index)
      )
    ''');
    // rec_ts USED TO BE THE KEY, and the key was the only index — every read in
    // this file and in health_export ranges over it. Without these the v47
    // re-key turns each of them into a full table scan.
    //
    // GUARDED ON THE COLUMN, not on IF NOT EXISTS. This helper runs MID-LADDER
    // too (`_rekeyDecodedStoreByRecTs`, oldV<33), where `decoded_rr` is still
    // the counter-keyed shape and has no `rec_ts` at all — and an index on a
    // missing column throws inside onUpgrade's one exclusive transaction and
    // quarantines the whole database (invariant 11).
    //
    // TWO COLUMNS EACH, matching each table's `ORDER BY` exactly — `rec_ts,
    // counter` on the parent and `rec_ts, beat_index` on the child — so the
    // ordering comes out of the index and the planner needs no temp b-tree.
    //
    // ponytail: rec_ts kept as a second, indexed time axis. `ts_ms` is
    // `rec_ts * 1000` for every row this app writes, so these reads COULD range
    // on ts_ms and ride the PK for free — measured ~4.5 MB per 3-day store per
    // index, on the hottest write path. Not done here because ~20 call sites in
    // this file plus health_export range on rec_ts, and phase 2 is meant to
    // change no read. Fold it in when a reader is being touched anyway.
    for (final t in const {
      'decoded_onehz': 'rec_ts, counter',
      'decoded_rr': 'rec_ts, beat_index',
    }.entries) {
      if ((await LocalDb._columnsOf(db, t.key)).contains('rec_ts')) {
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_${t.key}_rects ON ${t.key}(${t.value})',
        );
      }
    }
    // Existing installs get these here (ADD COLUMN, idempotent).
    await LocalDb._ensureDeviceFamilyColumns(db);
    await LocalDb._ensureSourceColumns(db);
    await LocalDb._ensureBeatTimeColumn(db);
  }

Future<void> _ldbPrivRebuildCanonicalDecodedStore(Database db) async {
    // FROZEN v17 step: it dedups the OLD counter-keyed decoded tables by rec_ts
    // via a `decoded_rr.counter` join. If the store is ALREADY rec_ts-keyed (the
    // ladder created it fresh at v11 with the current schema, so decoded_rr has
    // no `counter` column), it is already canonical — this rebuild is impossible
    // and unnecessary, so skip it. A genuinely old (counter-keyed) store still
    // gets the original rebuild here, and the v33 re-key converts it afterward.
    final rrCols = await db.rawQuery('PRAGMA table_info(decoded_rr)');
    if (rrCols.isNotEmpty && !rrCols.any((c) => c['name'] == 'counter')) return;
    // Guarantee the OLD-schema source tables exist before we SELECT from them.
    // On upgrade paths from before the decoded store landed they were never
    // created, so this rebuild threw "no such table" and bricked openDatabase.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_onehz (
        counter INTEGER PRIMARY KEY, rec_ts INTEGER NOT NULL,
        hr INTEGER NOT NULL, ax REAL NOT NULL, ay REAL NOT NULL, az REAL NOT NULL,
        spo2_red_raw INTEGER NOT NULL, spo2_ir_raw INTEGER NOT NULL,
        skin_temp_raw INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_rr (
        counter INTEGER NOT NULL, beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL, rr_ms INTEGER NOT NULL,
        PRIMARY KEY (counter, beat_index)
      )
    ''');
    await db.execute('DROP TABLE IF EXISTS _decoded_onehz_new');
    await db.execute('DROP TABLE IF EXISTS _decoded_rr_new');
    // Drop any leftover temp-named indexes BEFORE recreating them. SQLite index
    // names are database-GLOBAL, and a prior rebuild's `ALTER TABLE _decoded_*_new
    // RENAME TO decoded_*` leaks these `_new` index names onto the FINAL tables
    // (a renamed table keeps its indexes, names and all). On a re-run the plain
    // `CREATE INDEX idx_decoded_onehz_new_rects ...` then throws "index already
    // exists", which fails openDatabase → the upgrade never commits → the rebuild
    // re-runs every launch → app stuck on the loading screen. Dropping the names
    // first makes this rebuild fully idempotent and breaks that loop.
    for (final ix in const [
      'idx_decoded_onehz_new_rects',
      'idx_decoded_onehz_new_rec_ts_unique',
      'idx_decoded_rr_new_counter',
      'idx_decoded_rr_new_ts',
      'idx_decoded_rr_new_ts_beat_unique',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $ix');
    }
    await db.execute('''
      CREATE TABLE _decoded_onehz_new (
        counter INTEGER PRIMARY KEY,
        rec_ts INTEGER NOT NULL,
        -- `hr` IS NULLABLE ON EVERY INTERMEDIATE TABLE OF THE LADDER, not just
        -- the final one. These rebuilds are copy TARGETS for rows an EARLIER
        -- rung already wrote, and since v43 `_queueDecodedOneHz` writes NULL
        -- for a record with no heart rate (`hr == 0` was the off-skin
        -- sentinel — ordinary, not rare). A NOT NULL here fails the copy,
        -- throws inside the one exclusive onUpgrade transaction, and
        -- quarantines the database. See _relaxDecodedHrNull.
        hr INTEGER,
        ax REAL NOT NULL,
        ay REAL NOT NULL,
        az REAL NOT NULL,
        spo2_red_raw INTEGER NOT NULL,
        spo2_ir_raw INTEGER NOT NULL,
        skin_temp_raw INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_decoded_onehz_new_rects ON _decoded_onehz_new(rec_ts, counter)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_decoded_onehz_new_rec_ts_unique '
      'ON _decoded_onehz_new(rec_ts)',
    );
    await db.execute('''
      CREATE TABLE _decoded_rr_new (
        counter INTEGER NOT NULL,
        beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        PRIMARY KEY (counter, beat_index)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_decoded_rr_new_counter ON _decoded_rr_new(counter, beat_index)',
    );
    await db.execute(
      'CREATE INDEX idx_decoded_rr_new_ts ON _decoded_rr_new(rr_ts_ms)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_decoded_rr_new_ts_beat_unique '
      'ON _decoded_rr_new(rr_ts_ms, beat_index)',
    );
    await db.execute(
      'INSERT OR IGNORE INTO _decoded_onehz_new '
      '(counter, rec_ts, hr, ax, ay, az, spo2_red_raw, spo2_ir_raw, skin_temp_raw) '
      'SELECT d.counter, d.rec_ts, d.hr, d.ax, d.ay, d.az, '
      'd.spo2_red_raw, d.spo2_ir_raw, d.skin_temp_raw '
      'FROM decoded_onehz d '
      'JOIN ('
      '  SELECT rec_ts, MIN(counter) AS keep_counter '
      '  FROM decoded_onehz GROUP BY rec_ts'
      ') k '
      'ON k.rec_ts = d.rec_ts AND k.keep_counter = d.counter '
      'ORDER BY d.rec_ts ASC, d.counter ASC',
    );
    await db.execute(
      'INSERT OR IGNORE INTO _decoded_rr_new(counter, beat_index, rr_ts_ms, rr_ms) '
      'SELECT rr.counter, rr.beat_index, rr.rr_ts_ms, rr.rr_ms '
      'FROM decoded_rr rr '
      'JOIN _decoded_onehz_new onehz ON onehz.counter = rr.counter '
      'ORDER BY rr.rr_ts_ms ASC, rr.beat_index ASC, rr.counter ASC',
    );
    await db.execute('DROP TABLE IF EXISTS decoded_rr');
    await db.execute('DROP TABLE IF EXISTS decoded_onehz');
    await db.execute('ALTER TABLE _decoded_onehz_new RENAME TO decoded_onehz');
    await db.execute('ALTER TABLE _decoded_rr_new RENAME TO decoded_rr');
  }

Future<void> _ldbPrivRelaxDecodedSensorNulls(Database db) async {
    // No table yet (fresh-ish upgrade path) ⇒ the current DDL already carries
    // the nullable columns and there is nothing to rebuild.
    if ((await LocalDb._columnsOf(db, 'decoded_onehz')).isEmpty) return;
    await LocalDb._ensureDecodedOneHzBandFields(db);
    await db.execute('DROP TABLE IF EXISTS _decoded_onehz_v39');
    await db.execute('''
      CREATE TABLE _decoded_onehz_v39 (
        rec_ts INTEGER PRIMARY KEY,
        counter INTEGER NOT NULL,
        hr INTEGER, -- nullable on every intermediate: see _decoded_onehz_new
        ax REAL,
        ay REAL,
        az REAL,
        spo2_red_raw INTEGER,
        spo2_ir_raw INTEGER,
        skin_temp_raw INTEGER,
        step_count INTEGER,
        step_cadence INTEGER,
        activity_class INTEGER,
        skin_temp_c REAL,
        on_wrist INTEGER,
        hr_valid INTEGER,
        hr_alt INTEGER
      )
    ''');
    const cols =
        'rec_ts, counter, hr, ax, ay, az, spo2_red_raw, spo2_ir_raw, '
        'skin_temp_raw, step_count, step_cadence, activity_class, skin_temp_c, '
        'on_wrist, hr_valid, hr_alt';
    await db.execute(
      'INSERT OR REPLACE INTO _decoded_onehz_v39 ($cols) '
      'SELECT $cols FROM decoded_onehz ORDER BY rec_ts ASC',
    );
    await db.execute('DROP TABLE IF EXISTS decoded_onehz');
    await db.execute('ALTER TABLE _decoded_onehz_v39 RENAME TO decoded_onehz');
  }

String _ldbPrivRebuildDdlBody(List<Map<String, Object?>> info, {required Set<String> dropNotNull, required List<String> prepend, required List<String>? primaryKey}) {
    final own = [
      for (final c in info)
        if ((((c['pk'] as num?)?.toInt()) ?? 0) > 0) c,
    ]..sort(
        (a, b) => ((a['pk'] as num).toInt()).compareTo((b['pk'] as num).toInt()),
      );
    final key = primaryKey ?? [for (final c in own) c['name'] as String];
    final inline = key.length == 1 ? key.first : null;
    final defs = <String>[...prepend];
    for (final c in info) {
      final name = c['name'] as String;
      final dflt = c['dflt_value'];
      final notNull =
          (((c['notnull'] as num?)?.toInt()) ?? 0) == 1 &&
          !dropNotNull.contains(name);
      defs.add(
        '$name ${(c['type'] as String?) ?? ''}'
        '${name == inline ? ' PRIMARY KEY' : ''}'
        '${notNull ? ' NOT NULL' : ''}'
        '${dflt == null ? '' : ' DEFAULT $dflt'}',
      );
    }
    if (inline == null && key.isNotEmpty) {
      defs.add('PRIMARY KEY (${key.join(', ')})');
    }
    return defs.join(', ');
  }

Future<void> _ldbPrivRekeyStoresByDeviceId(Database db) async {
    await LocalDb._rekeyTableByDevice(db, 'decoded_onehz');
    await LocalDb._rekeyTableByDevice(db, 'decoded_rr', keyTail: const ['beat_index']);
    await LocalDb._rekeyTableByDevice(db, 'samples', timeCol: 'ts');
  }

Future<void> _ldbPrivRekeyTableByDevice(Database db, String table, {required String timeCol, required List<String> keyTail}) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    // Table absent on this upgrade path ⇒ the current DDL already carries the
    // new key and there is nothing to rebuild.
    if (info.isEmpty) return;
    final names = [for (final c in info) c['name'] as String];
    if (names.contains('device_id')) return;
    final tmp = '_${table}_v47';
    await db.execute('DROP TABLE IF EXISTS $tmp');
    await db.execute(
      'CREATE TABLE $tmp (${LocalDb._rebuildDdlBody(
        info,
        prepend: const [
          "device_id TEXT NOT NULL DEFAULT ''",
          'ts_ms INTEGER NOT NULL DEFAULT 0',
        ],
        primaryKey: ['device_id', 'ts_ms', ...keyTail],
      )})',
    );
    final cols = names.join(', ');
    // COALESCE because a declared PRIMARY KEY on a legacy rowid table does NOT
    // enforce NOT NULL — a NULL time column would put a NULL in the new key,
    // where it compares unequal to itself and escapes the retention prune
    // forever. 0 is behind every cutoff, so such a row is pruned on the next
    // pass instead of leaking.
    await db.execute(
      'INSERT OR REPLACE INTO $tmp (device_id, ts_ms, $cols) '
      "SELECT '', COALESCE($timeCol, 0) * 1000, $cols "
      'FROM $table ORDER BY $timeCol ASC',
    );
    // The COPIED column is normalised too, or the row escapes anyway:
    // `pruneDecodedBeforeRecTs` and `deleteDays` both filter the ORIGINAL
    // time column (`rec_ts < ?`), never the key, and `NULL < ?` is NULL.
    // Without this the row is immortal AND invisible — every read gates > 0.
    await db.execute('UPDATE $tmp SET $timeCol = 0 WHERE $timeCol IS NULL');
    await db.execute('DROP TABLE IF EXISTS $table');
    await db.execute('ALTER TABLE $tmp RENAME TO $table');
  }

Future<void> _ldbPrivRekeyByDeviceIdV51(Database db, String table, {required List<String> keyTail}) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    if (info.isEmpty) return;
    final names = [for (final c in info) c['name'] as String];
    if (names.contains('device_id')) return;
    final tmp = '_${table}_v51';
    await db.execute('DROP TABLE IF EXISTS $tmp');
    await db.execute(
      'CREATE TABLE $tmp (${LocalDb._rebuildDdlBody(
        info,
        prepend: ["device_id TEXT NOT NULL DEFAULT '${LocalDb.kPrimaryDeviceId}'"],
        primaryKey: ['device_id', ...keyTail],
      )})',
    );
    final cols = names.join(', ');
    await db.execute(
      "INSERT OR IGNORE INTO $tmp (device_id, $cols) SELECT '', $cols FROM $table",
    );
    await db.execute('DROP TABLE IF EXISTS $table');
    await db.execute('ALTER TABLE $tmp RENAME TO $table');
  }

Future<void> _ldbPrivRelaxDecodedHrNull(Database db) async {
    final info = await db.rawQuery('PRAGMA table_info(decoded_onehz)');
    // No table yet on this upgrade path ⇒ the current DDL already carries a
    // nullable `hr` and there is nothing to rebuild.
    if (info.isEmpty) return;
    final hr = info.where((c) => c['name'] == 'hr');
    if (hr.isEmpty || (hr.first['notnull'] as num?)?.toInt() != 1) return;

    final names = [for (final c in info) c['name'] as String];
    await db.execute('DROP TABLE IF EXISTS _decoded_onehz_v43');
    await db.execute(
      'CREATE TABLE _decoded_onehz_v43 '
      '(${LocalDb._rebuildDdlBody(info, dropNotNull: const {'hr'})})',
    );
    final cols = names.join(', ');
    await db.execute(
      'INSERT OR REPLACE INTO _decoded_onehz_v43 ($cols) '
      'SELECT $cols FROM decoded_onehz ORDER BY rec_ts ASC',
    );
    await db.execute('DROP TABLE IF EXISTS decoded_onehz');
    await db.execute('ALTER TABLE _decoded_onehz_v43 RENAME TO decoded_onehz');
  }

Future<void> _ldbPrivRekeyDecodedStoreByRecTs(Database db) async {
    // The source tables may not exist on a pre-decoded-store upgrade path; a
    // create (new schema, IF NOT EXISTS) makes the copy a safe no-op there. On a
    // normal path the OLD-schema tables already exist and this is a no-op — the
    // columns we SELECT (rec_ts, counter, hr, …; beat_index, rr_ts_ms, rr_ms)
    // are present in both the old and new decoded schemas.
    await LocalDb._createDecodedStore(db);
    await db.execute('DROP TABLE IF EXISTS _decoded_onehz_v33');
    await db.execute('DROP TABLE IF EXISTS _decoded_rr_v33');
    await db.execute('''
      CREATE TABLE _decoded_onehz_v33 (
        rec_ts INTEGER PRIMARY KEY,
        counter INTEGER NOT NULL,
        hr INTEGER, -- nullable on every intermediate: see _decoded_onehz_new
        ax REAL,
        ay REAL,
        az REAL,
        spo2_red_raw INTEGER,
        spo2_ir_raw INTEGER,
        skin_temp_raw INTEGER
      )
    ''');
    // Sensor columns nullable from the start (the v39 shape). They used to be
    // NOT NULL here, which bricked step 19: the rung backfills straight into
    // this rebuilt table via _queueDecodedOneHz, which writes a real NULL for
    // an absent reading. Same reason as _relaxDecodedSensorNulls — absence is
    // not a zero g vector and not an ADC count of 0.
    await db.execute('''
      CREATE TABLE _decoded_rr_v33 (
        rec_ts INTEGER NOT NULL,
        beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        PRIMARY KEY (rec_ts, beat_index)
      )
    ''');
    // Deterministic newest-wins: ORDER BY rec_ts, counter so INSERT OR REPLACE on
    // the rec_ts PK keeps the highest-counter (latest-offloaded) row per second.
    await db.execute(
      'INSERT OR REPLACE INTO _decoded_onehz_v33 '
      '(rec_ts, counter, hr, ax, ay, az, spo2_red_raw, spo2_ir_raw, skin_temp_raw) '
      'SELECT rec_ts, counter, hr, ax, ay, az, spo2_red_raw, spo2_ir_raw, skin_temp_raw '
      'FROM decoded_onehz ORDER BY rec_ts ASC, counter ASC',
    );
    // rec_ts derived from rr_ts_ms (= rec_ts*1000 by construction). Pre-fix orphan
    // beats (owning row evicted) re-home onto their real second here.
    await db.execute(
      'INSERT OR REPLACE INTO _decoded_rr_v33 (rec_ts, beat_index, rr_ts_ms, rr_ms) '
      'SELECT rr_ts_ms / 1000, beat_index, rr_ts_ms, rr_ms '
      'FROM decoded_rr ORDER BY rr_ts_ms ASC, beat_index ASC',
    );
    await db.execute('DROP TABLE IF EXISTS decoded_rr');
    await db.execute('DROP TABLE IF EXISTS decoded_onehz');
    await db.execute('ALTER TABLE _decoded_onehz_v33 RENAME TO decoded_onehz');
    await db.execute('ALTER TABLE _decoded_rr_v33 RENAME TO decoded_rr');
    // The rebuild drops the band-computed columns, so put them straight back.
    // Step 33 got away with it because step 34 re-adds them on the next rung;
    // step 19 does NOT — it backfills through _queueDecodedOneHz on the very
    // next line, which names step_count/…/hr_alt, so SQLite threw `no such
    // column: step_count`, the whole exclusive ladder rolled back, and every
    // upgrade from schema <= 18 went down the quarantine-and-rebuild path.
    // Idempotent (ADD COLUMN only when missing), so step 34 stays a no-op.
    await LocalDb._ensureDecodedOneHzBandFields(db);
    // The rec_ts PK auto-indexes and nothing reads by `counter`, so the rebuilt
    // tables carry no secondary index at all.
  }

Future<void> _ldbPrivBackfillRecTs(Database db) async {
    final rows = await db.query(
      'raw_records',
      columns: ['hex', 'captured_at'],
      where: 'rec_ts = 0 OR rec_ts IS NULL',
    );
    if (rows.isEmpty) return;
    final batch = db.batch();
    for (final r in rows) {
      final hex = r['hex'] as String;
      final capturedSec = ((r['captured_at'] as int?) ?? 0) ~/ 1000;
      final ts = LocalDb.decodeRecTs(hex, fallbackSec: capturedSec);
      batch.update(
        'raw_records',
        {'rec_ts': ts},
        where: 'hex = ?',
        whereArgs: [hex],
      );
    }
    await batch.commit(noResult: true);
  }

Future<void> _ldbPrivBackfillDecodedStore(Database db) async {
    // MUST run before the first insert. This backfill writes through
    // `_queueDecodedOneHz`, which since v43 writes NULL for a record with no
    // heart rate — and it is called from the oldV<11 and oldV<20 rungs, where
    // `decoded_onehz.hr` is still `NOT NULL`. An off-skin record (hr = 0, which
    // is ordinary, not rare) would then fail the constraint, throw inside
    // `onUpgrade`, roll the WHOLE ladder back and quarantine the database — the
    // standing trap this file is full of guards against. Self-skipping (one
    // PRAGMA) once the column is already nullable.
    await LocalDb._relaxDecodedHrNull(db);
    // SAME REASON, THE OTHER DIRECTION: these two columns are NEWER than this
    // backfill, and unlike `ambient_raw` / `dyn_accel_g` (which are null on
    // everything a pre-v11 `raw_records` can hold, so the omit-when-null form
    // never names them) the sub-second is present on every real gen4 record
    // being replayed here. Naming a column the ladder has not handed back yet
    // throws inside onUpgrade's single transaction and quarantines the whole
    // database. Both are ADD COLUMN, idempotent, and no-ops on a missing table.
    await LocalDb._addColumnIfMissing(db, 'decoded_onehz', 'ts_subsec', 'INTEGER');
    await LocalDb._ensureBeatTimeColumn(db);
    const pageSize = 1000;
    int afterCounter = -1;
    while (true) {
      final rows = await db.query(
        'raw_records',
        columns: ['counter', 'hex', 'packet_type', 'captured_at', 'rec_ts'],
        where: 'counter > ? AND packet_type = ?',
        whereArgs: [afterCounter, 47],
        orderBy: 'counter ASC',
        limit: pageSize,
      );
      if (rows.isEmpty) return;
      final batch = db.batch();
      for (final row in rows) {
        final raw = RawRecord(
          counter: (row['counter'] as num?)?.toInt() ?? 0,
          packetType: (row['packet_type'] as num?)?.toInt() ?? 0,
          hex: row['hex'] as String,
          capturedAt: (row['captured_at'] as num?)?.toInt() ?? 0,
          recTs: (row['rec_ts'] as num?)?.toInt(),
        );
        // MID-LADDER: `device_id` / `ts_ms` do not exist yet (v47 rung). See
        // _queueDecodedOneHz's `preDeviceKey`.
        LocalDb._queueDecodedOneHz(batch, raw, null, preDeviceKey: true);
      }
      await batch.commit(noResult: true);
      afterCounter = (rows.last['counter'] as num?)?.toInt() ?? afterCounter;
      if (rows.length < pageSize) return;
    }
  }

Future<void> _ldbPrivCreateEvents(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        device_id TEXT NOT NULL DEFAULT '${LocalDb.kPrimaryDeviceId}',
        hex TEXT NOT NULL,
        event_id INTEGER,
        ts INTEGER,
        captured_at INTEGER NOT NULL,
        ts_subsec INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (device_id, hex)
      )
    ''');
    // Same-version builds whose table predates schema 55 self-heal here: this
    // runs on every open via _repairOpenSchema.
    await LocalDb._addColumnIfMissing(
      db,
      'events',
      'ts_subsec',
      'INTEGER NOT NULL DEFAULT 0',
    );
    // The PK is the frame hex, so a `ts` window (the timeline's day query, and
    // the retention prune) was a full table scan. Cheap to build — `events` is
    // pruned to the retention window.
    await db.execute('CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)');
  }

Future<void> _ldbPrivCreateBandSignals(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS band_events (
        device_id TEXT NOT NULL DEFAULT '${LocalDb.kPrimaryDeviceId}',
        hex TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        ts INTEGER NOT NULL,
        payload_json TEXT NOT NULL DEFAULT '{}',
        captured_at INTEGER NOT NULL,
        PRIMARY KEY (device_id, hex)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_band_events_ts ON band_events(ts, event_id)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS band_battery (
        device_id TEXT NOT NULL DEFAULT '${LocalDb.kPrimaryDeviceId}',
        ts INTEGER NOT NULL,
        battery_pct REAL,
        charging INTEGER,
        wrist_on INTEGER,
        millivolts INTEGER,
        charge_units INTEGER,
        source TEXT NOT NULL,
        PRIMARY KEY (device_id, ts, source)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_band_battery_ts ON band_battery(ts DESC)',
    );
    await LocalDb._createBandBacklog(db);
  }

Future<void> _ldbPrivCreateBandBacklog(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS band_backlog (
        device_id TEXT NOT NULL DEFAULT '${LocalDb.kPrimaryDeviceId}',
        ts INTEGER NOT NULL,
        written INTEGER,
        used INTEGER,
        capacity INTEGER,
        trim_page INTEGER,
        wrap_count INTEGER,
        free_records INTEGER,
        device_family TEXT,
        PRIMARY KEY (device_id, ts)
      )
    ''');
  }

Future<void> _ldbPrivBackfillBandBatteryFromEvents(DatabaseExecutor db) async {
    // A DB whose ladder has not created these yet (or is mid-ladder) must
    // NO-OP rather than throw. `redriveArchivedRecords` guards the same way and
    // for the same reason: a throw in here rolls the WHOLE upgrade back and
    // quarantines the database.
    for (final t in const ['band_events', 'band_battery']) {
      final present = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        [t],
      );
      if (present.isEmpty) return;
    }
    const cap = 20000;
    final rows = await db.query(
      'band_events',
      columns: ['hex'],
      where: 'event_id IN (?, ?)',
      whereArgs: [proto.EventId.batteryLevel, LocalDb.kExtendedBatteryInfoEventId],
      orderBy: 'ts DESC',
      limit: cap,
    );
    if (rows.isEmpty) return;
    final batch = db.batch();
    var queued = 0;
    for (final r in rows) {
      final hex = r['hex'] as String?;
      if (hex == null) continue;
      Map<String, Object?>? row;
      try {
        final e = proto.parseEvent(proto.hexToBytes(hex));
        row = e == null ? null : LocalDb.batteryRowFromEvent(e);
      } catch (_) {
        // A frame this build cannot parse is one battery row we do not get.
        // It must never take the upgrade down with it.
        continue;
      }
      if (row == null) continue;
      batch.insert(
        'band_battery',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      queued++;
    }
    if (queued > 0) await batch.commit(noResult: true);
  }

Future<void> _ldbPrivCreateRawArchive(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS raw_archive (
        device_id TEXT NOT NULL DEFAULT '${LocalDb.kPrimaryDeviceId}',
        hex TEXT NOT NULL,
        counter INTEGER,
        packet_type INTEGER NOT NULL,
        rec_ts INTEGER,
        captured_at INTEGER NOT NULL,
        reason TEXT NOT NULL,
        PRIMARY KEY (device_id, hex)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_archive_captured '
      'ON raw_archive(captured_at DESC)',
    );
  }

Future<void> _ldbPrivCreateSubstrateArchive(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS substrate_archive (
        device_id     TEXT    NOT NULL DEFAULT '',
        utc_day       INTEGER NOT NULL,
        codec         INTEGER NOT NULL,
        from_ts       INTEGER NOT NULL,
        to_ts         INTEGER NOT NULL,
        onehz_rows    INTEGER NOT NULL,
        rr_rows       INTEGER NOT NULL,
        raw_bytes     INTEGER NOT NULL,
        fingerprint   INTEGER NOT NULL,
        tz_offset_min INTEGER,
        blob          BLOB    NOT NULL,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        PRIMARY KEY (device_id, utc_day)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_substrate_archive_day '
      'ON substrate_archive(utc_day)',
    );
  }

Future<void> _ldbPrivCreateSampleArchive(Database db) async {
    const old = '_spectral_archive_v66';
    final have = await LocalDb._columnsOf(db, 'spectral_archive');
    if (have.isNotEmpty && !have.contains('device_id')) {
      await db.execute('DROP TABLE IF EXISTS $old');
      await db.execute('ALTER TABLE spectral_archive RENAME TO $old');
    }
    await db.execute(
      'CREATE TABLE IF NOT EXISTS spectral_archive ('
      "day_id TEXT NOT NULL, device_id TEXT NOT NULL DEFAULT '', "
      'signal TEXT NOT NULL, codec_version INTEGER NOT NULL, '
      'part INTEGER NOT NULL DEFAULT 0, blob BLOB NOT NULL, '
      'n_valid INTEGER NOT NULL, rms_err REAL NOT NULL, '
      'max_err REAL NOT NULL, created_at INTEGER NOT NULL, '
      'origin_sec INTEGER, n_slots INTEGER, '
      'slot_sec INTEGER NOT NULL DEFAULT 1, '
      'PRIMARY KEY (day_id, device_id, signal, codec_version, part))',
    );
    final leftover = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [old],
    );
    if (leftover.isNotEmpty) {
      await db.execute(
        'INSERT OR IGNORE INTO spectral_archive(day_id, device_id, signal, '
        'codec_version, part, blob, n_valid, rms_err, max_err, created_at) '
        "SELECT day_id, '', signal, codec_version, 0, blob, n_valid, rms_err, "
        'max_err, created_at FROM $old',
      );
      await db.execute('DROP TABLE $old');
    }
    // Schema 68: the absolute origin (epoch second of slot 0), the slot count
    // and the slot length in seconds. Legacy parts are positional relative to
    // the start of their day id in the zone they were archived in, which was not
    // recorded; ASSUMPTION: the device is still in that zone, so the origin is
    // the start of the day id here and now. n_slots comes from the blob header
    // (the day length when the blob cannot be read). Only rows still NULL are
    // touched, so a re-run changes nothing.
    await LocalDb._addColumnIfMissing(db, 'spectral_archive', 'origin_sec', 'INTEGER');
    await LocalDb._addColumnIfMissing(db, 'spectral_archive', 'n_slots', 'INTEGER');
    await LocalDb._addColumnIfMissing(
        db, 'spectral_archive', 'slot_sec', 'INTEGER NOT NULL DEFAULT 1');
    final legacy = await db.rawQuery(
      'SELECT rowid AS rid, day_id, blob FROM spectral_archive '
      'WHERE origin_sec IS NULL OR n_slots IS NULL',
    );
    for (final r in legacy) {
      final day = r['day_id'] as String;
      var n = localDayLengthSec(day) ?? 86400;
      try {
        n = SampleCodec.readHeader(
                Uint8List.fromList((r['blob'] as List).cast<int>()))
            .length;
      } catch (_) {
        /* unreadable: the day length stands */
      }
      await db.rawUpdate(
        'UPDATE spectral_archive SET origin_sec = COALESCE(origin_sec, ?), '
        'n_slots = COALESCE(n_slots, ?) WHERE rowid = ?',
        [localDayStartSec(day), n, r['rid']],
      );
    }
  }

Future<void> _ldbPrivCreateWorkoutSplit(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workout_split (
        session_id TEXT NOT NULL,
        km INTEGER NOT NULL,
        meters REAL NOT NULL,
        duration_sec INTEGER NOT NULL,
        avg_hr REAL,
        net_elev_m REAL,
        PRIMARY KEY (session_id, km)
      )
    ''');
  }

