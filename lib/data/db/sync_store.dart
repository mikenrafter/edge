part of '../db.dart';

Future<List<Map<String, Object?>>> _ldbOnehzHrAccelBetween(int sinceEpochSec, int untilEpochSec) async {
    final db = await LocalDb.instance;
    return db.query(
      'decoded_onehz',
      columns: const ['rec_ts', 'hr', 'ax', 'ay', 'az'],
      where: 'rec_ts >= ? AND rec_ts <= ? '
          'AND hr IS NOT NULL AND ax IS NOT NULL AND ay IS NOT NULL AND az IS NOT NULL',
      whereArgs: [sinceEpochSec, untilEpochSec],
      orderBy: 'rec_ts ASC',
    );
  }

Future<void> _ldbPrivExtendCoverageVia(DatabaseExecutor txn, {required String deviceId, required List<Sample?> samples, required List<int> sampleSecs, required List<NeutralSample>? neutrals, required Map<String, int>? toleranceSec, required String? deviceFamily}) async {
    assert(samples.length == sampleSecs.length,
        'sampleSecs must be parallel to samples');
    final seen = <String, List<int>>{};
    void observe(String signal, int sec) =>
        (seen[signal] ??= <int>[]).add(sec);
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      if (s == null) continue;
      final sec = sampleSecs[i];
      // A record with no usable timestamp describes no second, so it can
      // found no interval. `_queueDecodedOneHz` refuses the same rows.
      if (sec <= 0) continue;
      if (s.hr > 0) observe('hr1Hz', sec);
      if (s.ax != null && s.ay != null && s.az != null) {
        observe('accel1Hz', sec);
      }
      if (s.spo2RedRaw != null || s.spo2IrRaw != null) {
        observe('ppgRedIr', sec);
      }
      if (s.skinTempRaw != null) observe('skinTempRaw', sec);
      if (s.rrIntervalsMs.isNotEmpty) observe('rrIntervals', sec);
    }
    // A wearable storing HR a minute or more apart covers `hrSparse`, never
    // `hr1Hz`: its rows must not be spliced into a 1 Hz substrate. Its spans
    // tolerate two of its own gaps, or every reading would be its own row.
    final sparseSec =
        kAdapterSignals[deviceFamily]?[InputSignal.hrSparse]?.inSeconds ?? 0;
    final hrSignal = sparseSec > 1 ? 'hrSparse' : 'hr1Hz';
    if (sparseSec > 1) {
      toleranceSec = {'hrSparse': 2 * sparseSec, ...?toleranceSec};
    }
    if (neutrals != null) {
      for (final n in neutrals) {
        if (n.tsEpoch <= 0) continue;
        if (n.hr != null) observe(hrSignal, n.tsEpoch);
        if (n.rrMs.isNotEmpty) observe('rrIntervals', n.tsEpoch);
      }
    }
    if (seen.isEmpty) return;

    const kBucket = 60; // seconds — the resolver's grid, same as the backfill
    for (final e in seen.entries) {
      final signal = e.key;
      final tolerance = toleranceSec?[signal] ?? (2 * kBucket);
      // ONE TOLERANCE, TWO JOBS: it splits this batch's seconds into spans AND
      // decides whether the first span extends the stored open interval. The
      // same number for both is what makes the result independent of where the
      // batch boundaries happened to fall — the run of seconds a device was
      // emitting is the same fact whether it arrived in one commit or five.
      final secs = e.value..sort();
      final spans = <(int, int)>[]; // [start, end) — end exclusive
      var spanStart = secs.first;
      var prev = secs.first;
      for (final sec in secs.skip(1)) {
        if (sec - prev > tolerance) {
          spans.add((spanStart, prev + 1));
          spanStart = sec;
        }
        prev = sec;
      }
      spans.add((spanStart, prev + 1));

      // Only the FIRST span can extend the stored open interval: the rest are
      // later than it by more than `tolerance` (that is what split them), so
      // the extend test below would reject them anyway.
      final open = await txn.query(
        'device_coverage',
        columns: ['start_ts', 'end_ts'],
        where: 'device_id = ? AND signal = ?',
        whereArgs: [deviceId, signal],
        orderBy: 'start_ts DESC',
        limit: 1,
      );
      final startTs =
          open.isEmpty ? null : (open.single['start_ts'] as num).toInt();
      final endTs =
          open.isEmpty ? null : (open.single['end_ts'] as num).toInt();
      for (var i = 0; i < spans.length; i++) {
        final (firstSec, lastSec) = spans[i];
        // EXTEND ONLY A SPAN THAT STARTS AT OR AFTER THE OPEN INTERVAL and is
        // within tolerance of its end. `firstSec - endTs <= tolerance` on its
        // own is also true when the whole span PREDATES the interval (the
        // difference is negative), and the `lastSec > endTs` body then wrote
        // nothing at all. That is the normal WHOOP path: a live commit opens an
        // interval at "now", the historical drain then commits records from
        // hours earlier, and those hours got no coverage row — after which
        // `resolveOwnership` reports no owner for them and the substrate load
        // can drop the matching rows. Same-device intervals may overlap (see
        // `_createDeviceCoverage`) and every reader unions them, so the safe
        // repair is a separate interval.
        if (i == 0 &&
            startTs != null &&
            endTs != null &&
            firstSec >= startTs &&
            firstSec - endTs <= tolerance) {
          if (lastSec > endTs) {
            await txn.update(
              'device_coverage',
              {'end_ts': lastSec},
              where: 'device_id = ? AND signal = ? AND start_ts = ?',
              whereArgs: [deviceId, signal, startTs],
            );
          }
        } else {
          await txn.insert(
            'device_coverage',
            {
              'device_id': deviceId,
              'signal': signal,
              'start_ts': firstSec,
              'end_ts': lastSec,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
    }
  }

Future<void> _ldbAddLiveCoverage(int startTs, int endTs, int steps, String day, {required String source, required String deviceId}) async {
    final w = sanitizeCoverageWindow(startTs, endTs, steps);
    if (w == null) return;
    final db = await LocalDb.instance;
    await db.insert('live_coverage', {
      'start_ts': w.startTs,
      'end_ts': w.endTs,
      'steps': steps,
      'day': day,
      'source': source,
      'device_id': deviceId,
    });
  }

Future<void> _ldbAddLiveCoverageRuns(List<({int startTs, int endTs, int steps, String day})> runs, {required String source, required String deviceId}) async {
    final rows = <Map<String, Object?>>[];
    for (final r in runs) {
      final w = sanitizeCoverageWindow(r.startTs, r.endTs, r.steps);
      if (w == null) continue;
      rows.add({
        'start_ts': w.startTs,
        'end_ts': w.endTs,
        'steps': r.steps,
        'day': r.day,
        'source': source,
        'device_id': deviceId,
      });
    }
    if (rows.isEmpty) return;
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      for (final row in rows) {
        await txn.insert('live_coverage', row);
      }
    });
  }

Future<void> _ldbReplacePhoneCoverageForDay(String day, List<({int startTs, int endTs, int steps})> windows) async {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      await txn.delete(
        'live_coverage',
        where: 'day = ? AND source = ?',
        whereArgs: [day, LocalDb.kStepSourcePhone],
      );
      for (final w in windows) {
        if (w.steps < 0 || w.endTs <= w.startTs) continue;
        await txn.insert('live_coverage', {
          'start_ts': w.startTs,
          'end_ts': w.endTs,
          'steps': w.steps,
          'day': day,
          'source': LocalDb.kStepSourcePhone,
        });
      }
    });
  }

Future<int> _ldbPhoneStepsForDay(String day) async {
    final db = await LocalDb.instance;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(steps),0) s FROM live_coverage '
      'WHERE day = ? AND source = ?',
      [day, LocalDb.kStepSourcePhone],
    );
    return (r.first['s'] as num?)?.toInt() ?? 0;
  }

Future<ResolvedDaySteps> _ldbResolvedStepsForDay(String day) async {
    InputReads.note('step_coverage', day);
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

Future<List<List<int>>> _ldbCoverageWindowsOverlapping(int loSec, int hiSec, {required String source}) async {
    InputReads.note('step_coverage', '');
    final db = await LocalDb.instance;
    final rows = await db.query(
      'live_coverage',
      where: 'end_ts >= ? AND start_ts < ? AND source = ?',
      whereArgs: [loSec, hiSec, source],
    );
    return [
      for (final r in rows)
        [(r['start_ts'] as num).toInt(), (r['end_ts'] as num).toInt()],
    ];
  }

Future<List<List<int>>> _ldbWristOffSpans(int loSec, int hiSec, {required String deviceId}) =>
      LocalDb._toggleSpans(
        loSec,
        hiSec,
        onId: proto.EventId.wristOn,
        offId: proto.EventId.wristOff,
        deviceId: deviceId,
      );

Future<List<List<int>>> _ldbPrivToggleSpans(int loSec, int hiSec, {required int onId, required int offId, required String deviceId}) async {
    if (hiSec <= loSec) return const [];
    InputReads.note('events', '');
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

Future<void> _ldbBeginOffloadSession() => LocalDb._withCommitGate(() async {
    try {
      // The already-open handle only — never `instance`. A session is a speed
      // optimisation, so it must not be what opens (or hangs opening) the
      // store; with no open handle the commits keep their own bracket.
      final db = LocalDb._db;
      if (db == null || !db.isOpen) return;
      if (identical(LocalDb._offloadSessionDb, db)) return;
      await db.execute('PRAGMA synchronous=FULL');
      final got = await db.rawQuery('PRAGMA synchronous');
      final level = got.isEmpty ? null : got.first.values.firstOrNull;
      if (level is num && level.toInt() == 2) {
        LocalDb._offloadSessionDb = db;
      } else {
        LocalDb._syncFullDowngrades++;
      }
    } catch (_) {
      LocalDb._syncFullDowngrades++;
    }
  });

Future<void> _ldbCommitSyncBatch(List<RawRecord> raws, List<Sample?> samples, {required String? trimToken, required Map<String, String>? extraCursors, required List<ArchiveRecord>? archives, required List<NeutralSample>? neutrals, required List<EcgRawPacket>? ecgRawPackets, required void Function(String)? onCheckpoint, required String? deviceFamily, required String deviceId, required Map<String, int>? coverageToleranceSec}) =>
      LocalDb._withCommitGate(() => LocalDb._commitSyncBatchLocked(
            raws,
            samples,
            trimToken: trimToken,
            extraCursors: extraCursors,
            archives: archives,
            neutrals: neutrals,
            ecgRawPackets: ecgRawPackets,
            onCheckpoint: onCheckpoint,
            deviceFamily: deviceFamily,
            deviceId: deviceId,
            coverageToleranceSec: coverageToleranceSec,
          ));

Future<void> _ldbPrivCommitSyncBatchLocked(List<RawRecord> raws, List<Sample?> samples, {required String? trimToken, required Map<String, String>? extraCursors, required List<ArchiveRecord>? archives, required List<NeutralSample>? neutrals, required List<EcgRawPacket>? ecgRawPackets, required void Function(String)? onCheckpoint, required String? deviceFamily, required String deviceId, required Map<String, int>? coverageToleranceSec}) async {
    // NEUTRAL ROWS BELONG TO A NON-PRIMARY DEVICE. "" is the primary band
    // permanently (see kPrimaryDeviceId); a neutral-sample writer is by
    // definition a band with no framed record, which the primary is not.
    assert(
      neutrals == null || neutrals.isEmpty || deviceId != LocalDb.kPrimaryDeviceId,
      'neutral rows belong to a non-primary device; "" is the primary band '
      'permanently (see kPrimaryDeviceId).',
    );
    // AND THEY MUST NAME THEIR SOURCE. `source` is what separates a secondary
    // band's rows from the primary's: NULL there IS the primary band
    // (kPrimaryBandSourceSql) and is admitted by derivableSourceSql(), so an
    // unnamed neutral row would not merely lose provenance — it would be read
    // as the strap's own. Refused rather than asserted: a release build must
    // not be the one place this can happen, and the caller (BandHost) already
    // re-buffers a failed batch. Every writer today passes `adapter.id`.
    if (neutrals != null && neutrals.isNotEmpty && deviceFamily == null) {
      throw ArgumentError.notNull('deviceFamily');
    }
    void checkpoint(String msg) {
      try {
        onCheckpoint?.call(msg);
      } catch (_) {
        /* a logging callback must never affect the commit */
      }
    }

    final db = await LocalDb.instance;
    // POWER-LOSS DURABILITY WINDOW. This is the ACK-gating commit: once it
    // returns, the caller writes the BLE batch-ACK and the band trims its flash.
    // Under WAL + synchronous=NORMAL (the default this connection opens with) a
    // commit is durable only at the next checkpoint — so a kernel panic /
    // battery-yank AFTER the ACK but BEFORE the -wal is checkpointed loses these
    // just-committed rows from the phone while they are already gone from the
    // band. Raise durability to FULL (fsync AT commit) for THIS commit only,
    // leaving every other path at NORMAL — they are all recomputable and FULL
    // everywhere is brutally slow. `synchronous` is per-connection and CANNOT be
    // changed mid-transaction, so it is set on the connection BEFORE
    // db.transaction opens and reset AFTER it commits. The reset lives in a
    // finally: a leaked FULL from a throwing commit would fsync every subsequent
    // write on this connection forever. `PRAGMA synchronous=FULL/NORMAL` returns
    // NO rows → execute() (not rawQuery), kept non-fatal like the open-time
    // PRAGMAs so a PRAGMA throw can never fail a durable commit. Every ACK-gating
    // commit — the foreground drain AND the headless iOS-restore recovery drain
    // (background_sync.dart) — funnels through here, so this one choke point
    // covers them all. `synchronous` is per-connection, so the bracket is only
    // safe because these drains never OVERLAP on a shared connection: the offload
    // processor is single-flight (ble_engine.dart) and BandOwnership makes the
    // headless drain yield when the foreground owns the band. Do not add a second
    // concurrent caller of commitSyncBatch on the main-isolate connection without
    // reinstating that serialization — a mid-window reset would silently
    // downgrade this commit back to NORMAL.
    // Best-effort, and deliberately NOT fatal. Failing the commit when the
    // upgrade is refused would mean never committing, therefore never ACKing,
    // therefore never trimming — the strap re-floods the same backlog forever
    // and sync is dead on any platform that rejects the pragma. NORMAL under
    // WAL still commits atomically; FULL narrows the power-loss window, it is
    // not itself the safe-trim invariant.
    //
    // What it must not do is fail SILENTLY, which is what "best-effort" meant
    // before: read it back, so a downgrade shows up in the log and the counter
    // instead of being invisible for the life of the install.
    // Inside an offload session FULL is already held and verified on this very
    // connection ([beginOffloadSession]), so the three pragma round trips per
    // chunk are skipped; outside one (headless drains, one-off commits) the
    // bracket below is unchanged.
    final inSession = identical(LocalDb._offloadSessionDb, db);
    if (!inSession) {
    try {
      await db.execute('PRAGMA synchronous=FULL');
      final got = await db.rawQuery('PRAGMA synchronous');
      final level = got.isEmpty ? null : got.first.values.firstOrNull;
      // 2 == FULL. sqflite reports the numeric level.
      if (level is num && level.toInt() != 2) {
        LocalDb._syncFullDowngrades++;
        checkpoint(
          '[DB] synchronous=FULL did not take (reads back as '
          '$level) — the ACK-gating commit is running at a weaker '
          'durability level (downgrades_total=${LocalDb._syncFullDowngrades}).',
        );
      }
    } catch (e) {
      LocalDb._syncFullDowngrades++;
      checkpoint(
        '[DB] PRAGMA synchronous=FULL was refused ($e) — the '
        'ACK-gating commit is running at NORMAL '
        '(downgrades_total=${LocalDb._syncFullDowngrades}).',
      );
    }
    }
    try {
      await db.transaction((txn) async {
        // Read the existing high-water THROUGH the txn — never via the global db
        // handle, which would deadlock against this same open transaction.
        final kCounter = LocalDb.cursorKeyFor('counter_hw', deviceId);
        final kRecTs = LocalDb.cursorKeyFor('rec_ts_hw', deviceId);
        var maxCounter = await LocalDb._cursorIntVia(txn, kCounter) ?? 0;
        var maxRecTs = await LocalDb._cursorIntVia(txn, kRecTs) ?? 0;
        // For the coverage writer (§6.5): each record's OWN second, parallel to
        // `samples`, never the cursor high-water (which predates the batch and
        // would claim coverage for seconds this commit never touched) and never
        // a single batch-wide span (which would claim every signal for every
        // second any signal appeared in — see [_extendCoverageVia]).
        // Sized off `samples`, not `raws`: the raws loop only walks
        // `raws.length`, and a caller that passed a longer sample list must not
        // trip the parallel-length assert. An unvisited slot stays 0, which
        // [_extendCoverageVia] reads as "no second", so it claims nothing.
        final sampleSecs = List<int>.filled(samples.length, 0);
        // CHUNKED BATCH: sqflite serialises an ENTIRE batch's operations+args into
        // ONE platform-channel message, and the native side builds a single
        // ArrayList of every argument. A large backlog offload (raws in the
        // hundreds-of-thousands) blew the native heap in SqlCommand.getSqlArguments
        // → OutOfMemoryError (Crashlytics 0.9.13). Committing in bounded chunks
        // flushes and frees each message's args. These commits all happen INSIDE
        // the single `db.transaction` below, so the safe-trim invariant holds: the
        // whole offload (raw_archive + samples + decoded_onehz + decoded_rr +
        // cursor) is still one atomic transaction — every row is durable before the
        // caller echoes the HISTORY_END trim token, or none is.
        const chunkOps = 4000;
        var batch = txn.batch();
        var ops = 0;
        Future<void> flushChunk() async {
          if (ops == 0) return;
          await batch.commit(noResult: true);
          batch = txn.batch();
          ops = 0;
        }

        // SAFE-TRIM INVARIANT: archive the undecodable records in the SAME
        // transaction as the raw records + trim cursor, so they are durably set
        // aside BEFORE the caller writes the batch-ACK that lets the band trim.
        if (archives != null) {
          for (final a in archives) {
            batch.insert('raw_archive', {
              'device_id': deviceId,
              'counter': a.counter,
              'hex': a.hex,
              'packet_type': a.packetType,
              'rec_ts': a.recTs,
              'captured_at': a.capturedAt,
              'reason': a.reason,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
            if (++ops >= chunkOps) await flushChunk();
          }
        }
        // SAFE-TRIM INVARIANT, same rule: the raw ECG records land in this
        // transaction, before the ACK that lets the band trim them.
        if (ecgRawPackets != null && ecgRawPackets.isNotEmpty) {
          // A packet inside a known gesture interval is stored as gesture
          // contact, never linked to a reading. One tiny SELECT per device in
          // this batch, inside the same transaction; it changes neither the
          // rows nor the order the commit-before-ACK contract depends on.
          final bands = <String, List<(int, int)>>{};
          for (final e in ecgRawPackets) {
            if (!bands.containsKey(e.deviceId)) {
              bands[e.deviceId] = await LocalDb._gestureBands(txn, e.deviceId);
            }
          }
          for (final e in ecgRawPackets) {
            final gesture = bands[e.deviceId]!.any(
              (b) => e.strapSeconds >= b.$1 && e.strapSeconds <= b.$2,
            );
            batch.insert('ecg_raw_packet', {
              'hex': e.hex,
              'device_id': e.deviceId,
              'sequence': e.sequence,
              'strap_seconds': e.strapSeconds,
              'strap_subsec': e.strapSubsec,
              'captured_at': e.capturedAt,
              if (gesture) 'origin': 'gesture',
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
            if (++ops >= chunkOps) await flushChunk();
          }
        }
        for (var i = 0; i < raws.length; i++) {
          final raw = raws[i];
          final recTs = LocalDb._recTsFor(raw);
          final sample = samples[i];
          if (sample != null) {
            batch.insert('samples', {
              'device_id': deviceId,
              // From `ts`, not `recTs`: `toDbMap` writes `ts: sample.tsEpoch`
              // and the migration derives `ts_ms` from `ts`, so the key and the
              // column it is built from must not be allowed to disagree.
              'ts_ms': sample.tsEpoch * 1000,
              'counter': raw.counter,
              ...sample.toDbMap(),
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
            ops++;
          }
          ops += LocalDb._queueDecodedOneHz(
            batch,
            raw,
            sample,
            deviceFamily: deviceFamily,
            deviceId: deviceId,
          );
          if (raw.counter > maxCounter) maxCounter = raw.counter;
          if (recTs > maxRecTs) maxRecTs = recTs;
          sampleSecs[i] = recTs;
          if (ops >= chunkOps) await flushChunk();
        }
        // NEUTRAL ROWS. No flash counter to advance maxCounter from — both
        // current writers (ble_hrs, oura) hard-code counter: 0 and leave a
        // ponytail note saying so; maxCounter stays a WHOOP-only concept.
        if (neutrals != null) {
          for (final n in neutrals) {
            ops += LocalDb._queueNeutralOneHz(
              batch,
              n,
              // Non-null by the refusal at the top of this method.
              deviceFamily: deviceFamily!,
              deviceId: deviceId,
            );
            if (n.tsEpoch > maxRecTs) maxRecTs = n.tsEpoch;
            if (ops >= chunkOps) await flushChunk();
          }
        }
        checkpoint(
          'decoded_archive_queued raws=${raws.length} '
          'archives=${archives?.length ?? 0} '
          'ecg_raw=${ecgRawPackets?.length ?? 0}',
        );
        await flushChunk();
        checkpoint('decoded_archive_committed');
        // COVERAGE, in the same transaction as the rows it describes — so an
        // interval can never claim a second whose row did not commit, and the
        // safe-trim invariant covers both. See _extendCoverageVia.
        await LocalDb._extendCoverageVia(
          txn,
          deviceId: deviceId,
          samples: samples,
          sampleSecs: sampleSecs,
          neutrals: neutrals,
          toleranceSec: coverageToleranceSec,
          deviceFamily: deviceFamily,
        );
        await LocalDb.setCursor(kCounter, '$maxCounter', txn: txn);
        await LocalDb.setCursor(kRecTs, '$maxRecTs', txn: txn);
        if (trimToken != null) {
          await LocalDb.setCursor(LocalDb.cursorKeyFor('strap_trim', deviceId), trimToken,
              txn: txn);
        }
        if (extraCursors != null) {
          for (final e in extraCursors.entries) {
            await LocalDb.setCursor(e.key, e.value, txn: txn);
          }
        }
        checkpoint(
          'cursor_advanced counter_hw=$maxCounter rec_ts_hw=$maxRecTs '
          'trim=${trimToken != null}',
        );
        // Freshness rides the batch transaction: it used to be a select +
        // insert after COMMIT, two extra round trips per chunk that the band
        // waits out, and a window where rows were durable but the "capture is
        // fresh" marker was not. It is only a derive trigger, so atomicity with
        // the rows is the correct failure mode (rolls back with them).
        await LocalDb._writeCaptureFreshness(txn, raws);
      });
    } finally {
      // ALWAYS restore NORMAL — even if the commit threw — so a leaked FULL does
      // not fsync every subsequent write on this connection. Non-fatal. A
      // session commit leaves FULL up: [endOffloadSession] owns that reset.
      if (!inSession) {
        try {
          await db.execute('PRAGMA synchronous=NORMAL');
        } catch (_) {
          /* non-fatal — see open-time PRAGMA discipline */
        }
      }
    }
  }

int _ldbDecodeRecTs(String hex, {required int fallbackSec}) {
    // Historical type-24 carries the canonical ts; decodeRecord covers 0x28/R10/R24.
    try {
      final s = proto.decodeRecord(hex);
      if (s != null && s.ts > 0) return s.ts;
    } catch (_) {
      /* fall through */
    }
    // RR-bearing live frames (0x28) as a secondary path.
    try {
      final rr = proto.realtimeRr(hex);
      if (rr != null && rr.ts > 0) return rr.ts;
    } catch (_) {
      /* fall through */
    }
    return fallbackSec;
  }

Future<void> _ldbPrivWriteCaptureFreshness(DatabaseExecutor txn, List<RawRecord> raws) async {
    if (raws.isEmpty) return;
    var latest = 0;
    for (final raw in raws) {
      final recTs = LocalDb._recTsFor(raw);
      if (recTs > latest) latest = recTs;
    }
    if (latest <= 0) return;
    // Through the txn, never the global handle: that would deadlock against
    // the open commit transaction.
    final prevRows = await txn.query(
      'compute_freshness',
      where: 'key = ?',
      whereArgs: ['capture'],
      limit: 1,
    );
    Map<String, dynamic> payload = const {};
    final rawJson = prevRows.isEmpty ? null : prevRows.first['payload_json'];
    if (rawJson is String && rawJson.isNotEmpty) {
      try {
        final d = jsonDecode(rawJson);
        if (d is Map) payload = d.cast<String, dynamic>();
      } catch (_) {
        payload = const {};
      }
    }
    payload = {
      ...payload,
      'latest_raw_rec_ts': latest,
      'latest_raw_day': LocalDb._localDayLabelFromEpoch(latest),
    };
    await LocalDb.putComputeFreshness('capture', jsonEncode(payload), txn: txn);
  }

Sample? _ldbPrivDecodeOneHzSample(RawRecord raw, {required Sample? preferred}) {
    // Reject Gen4 R10-lite even when a complete preferred Sample is supplied.
    // Invalid/placeholder hex (test fixtures, corrupt imports) must NOT abort
    // before the preferred paths — commit 1f85b10 returned null on hexToBytes
    // failure and zeroed decoded_onehz for every insertRecord that used non-hex
    // placeholders. The bytes are now parsed lazily, below, for that reason too.
    if (LocalDb._isGen4R10LiteHistorical(raw.hex)) return null;
    if (preferred != null && preferred.hasDecodedOneHz) return preferred;
    // The band's OWN decode outranks the other generation's decoder. A gen5 v18
    // has no gen4 optics so hasDecodedOneHz is false, and feeding it to the v24
    // map is not harmless: HR sits at byte 14 in both layouts and gravity is
    // exactly one byte off, so whenever an axis lands in |g| ∈ [0.746, 0.75)
    // the misread collapses into a believable vector instead of failing the
    // plausibility gate — about 0.6% of records, ~550 rows a day. Those rows
    // keep the right hr and ts (so they look fine) while carrying a fabricated
    // gravity vector, fabricated optics, and none of the gen5 RR beats.
    if (preferred != null && preferred.tsEpoch > 0) return preferred;
    Uint8List? bytes;
    try {
      bytes = proto.hexToBytes(raw.hex);
    } catch (_) {}
    if (bytes != null) {
      // GEN5 FIRST — and only on a full gen5 decode. This whole fallback used
      // to be gen4-only, so any gen5 frame arriving without a pre-decoded
      // sample (a raw replay, an archive re-drive, a raw-hex import) was fed
      // to the R24 map, which is precisely the misread the comment above
      // describes: same HR byte, gravity one byte off, a believable-looking
      // fabricated vector.
      //
      // Order is safe in this direction and not the other:
      // `parseGen5Historical` dispatches off the record version and returns
      // null for anything it does not recognise, so a gen4 R24/R12 frame
      // (version 24/12) falls straight through to the chain below.
      try {
        final g = proto.parseGen5Historical(bytes);
        // Only the per-second v18 record maps onto a 1 Hz Sample; the deep
        // buffers (v20/v21/v26) are correctly identified and deliberately not
        // storable here — same contract as the live drain's mapper in
        // ble_engine.dart, which this duplicates because lib/data must not
        // depend on lib/ble.
        if (g is proto.Gen5HistorySample && g.unix > 0) {
          return Sample(
            tsEpoch: g.unix,
            counter: g.recordIndex,
            hr: g.heartRate,
            rrIntervalsMs: List<int>.from(g.rrIntervalsMs),
            ax: g.gravityG.isNotEmpty ? g.gravityG[0] : null,
            ay: g.gravityG.length > 1 ? g.gravityG[1] : null,
            az: g.gravityG.length > 2 ? g.gravityG[2] : null,
            stepCount: g.stepMotionCounter,
            stepCadence: g.stepCadence,
            activityClass: g.activityClassKnown,
            // Same honesty contract as the live mapper: the -50.00 °C code is
            // the sensor's unavailable sentinel, and body-60 bits 0-1 / body-15
            // bit7 are disproven as wear / HR-validity (see
            // sampleFromGen5Historical) — a replay must not resurrect them.
            skinTempC: g.skinTempCOrNull,
            hrAlt: g.heartRateAlt,
            // MT-12's three columns exist (v43) and the write below names
            // them. Carried here because they are free and the point of
            // storing them is to make it possible to find out later whether
            // they mean anything — see Sample.tempCh2C for why they are not
            // named after a body part.
            tempCh2C: g.tempAux1C,
            tempCh3C: g.tempAux2C,
            signalQualityLogVar: g.signalQualityLogVariance,
            dynAccelG: g.dynamicAccelerationG,
            tsSubsec: g.tsSubsec,
            bandSleepState: g.sleepStateRawNibble,
          );
        }
      } catch (_) {}
      try {
        // Legacy decoder first, firmware-fallback chain second — see
        // FirmwareAwareR24Decoder. This path only runs when no pre-decoded
        // `preferred` sample was supplied (e.g. a raw-hex import/merge), so a
        // fresh per-call instance is fine — no session state to preserve.
        final r = proto.FirmwareAwareR24Decoder().decode(bytes);
        // v25 NEVER BECOMES A SECOND, on any path into this table.
        //
        // The live drain already excludes it (see `_ingestHistoricalFrame`),
        // but this seam is the one every OTHER path shares — the mid-ladder
        // `_backfillDecodedStore` replay of `raw_records`, `insertRecord` with
        // no pre-decoded sample, a raw-hex import, `redriveArchivedRecords` —
        // and `FirmwareAwareR24Decoder` routes v25 straight to `_parseV25`,
        // which returns a gravity vector that ISN'T ONE: measured across all
        // 28,395 v25 records in `whoop-4.db`, its "z" takes three distinct
        // values, its "y" seventeen, its "x" is the high half of an f32, and
        // the median angle to the real v24 gravity at the SAME second is 83°.
        // A near-constant vector reads downstream as a perfectly still wrist,
        // which is the one thing the nullable accel columns exist to prevent.
        //
        // Banking it would also REPLACE (the second is the PK) the v24 row for
        // that second on 49% of records, deleting real HR and R-R. Refused at
        // the seam so no future caller can reintroduce it by accident. The
        // bytes stay in `raw_archive`, whole and unpruned.
        if (r != null && r.histVersion == 25) return null;
        if (r != null && r.tsEpoch > 0) {
          return Sample(
            tsEpoch: r.tsEpoch,
            counter: r.counter,
            hr: r.hr,
            rrIntervalsMs: List<int>.from(r.rrIntervalsMs),
            // ABSENT ACCEL STAYS ABSENT. These used to coalesce to 0, which is
            // a reading — a perfectly still wrist — and it is the same
            // fabricated stillness the nullable columns and the v25 refusal
            // above exist to prevent. protocol now returns an empty `accelG`
            // for a record whose accelerometer it will not vouch for, so the
            // fallback is null, exactly as the gen5 `gravityG` path above does.
            ax: r.accelG.isNotEmpty ? r.accelG[0] : null,
            ay: r.accelG.length > 1 ? r.accelG[1] : null,
            az: r.accelG.length > 2 ? r.accelG[2] : null,
            spo2RedRaw: r.spo2RedRaw,
            spo2IrRaw: r.spo2IrRaw,
            // raw column passthrough, same as the ble path. not read as a temp.
            // ignore: deprecated_member_use
            skinTempRaw: r.skinTempRaw,
            // gen4 ambient-light ADC. 0 (unconfirmed optical block) is turned
            // into NULL at the write, not here — see _queueDecodedOneHz.
            ambientRaw: r.ambientRaw,
            tsSubsec: r.tsSubsec,
          );
        }
      } catch (_) {}
    }
    return null;
  }

int _ldbPrivQueueDecodedOneHz(Batch batch, RawRecord raw, Sample? sample, {required String? deviceFamily, required String deviceId, required bool preDeviceKey}) {
    final decoded = LocalDb._decodeOneHzSample(raw, preferred: sample);
    if (decoded == null) {
      // Gen4 R10-lite has no accel/optical, so it stays out of decoded_onehz —
      // but it DOES carry an R-R block (protocol 539a97b), and dropping it here
      // is permanent, not degraded: the record commits as decoded, so it is
      // never archived, and the band is then acked to trim it. Persist the
      // beats on their own. `samples` cannot hold them — it is (counter, ts, hr).
      if (sample != null &&
          sample.rrIntervalsMs.isNotEmpty &&
          LocalDb._isGen4R10LiteHistorical(raw.hex)) {
        return LocalDb._queueRrBeats(
          batch,
          LocalDb._recTsFrom(raw, sample),
          sample,
          deviceFamily: deviceFamily,
          deviceId: deviceId,
          preDeviceKey: preDeviceKey,
        );
      }
      return 0;
    }
    final recTs = LocalDb._recTsFrom(raw, decoded);
    final ambient = decoded.ambientRaw == 0 ? null : decoded.ambientRaw;
    // TIME-KEYED, NEWEST-WINS (dedupe records by their embedded timestamp,
    // not by the volatile counter). decoded_onehz is keyed by
    // (device_id, ts_ms) and decoded_rr by (device_id, ts_ms, beat_index),
    // with ts_ms = rec_ts * 1000; rec_ts is the indexed range field. We use
    // REPLACE, not IGNORE: a freshly-offloaded record for a given second
    // should win over a stale one. Because the second is the key, the strap's
    // per-reboot counter reset can no longer make one second's record evict
    // another's (the pre-fix counter-PK eviction that silently, unrecoverably
    // deleted 1 Hz rows).
    batch.insert('decoded_onehz', {
      // v47: WHICH DEVICE, in front of the key. '' is the primary band and
      // nothing else may ever use it — see _createDecodedStore for why an
      // unstable BLE remoteId must never reach this column.
      'device_id': ?(preDeviceKey ? null : deviceId),
      // `rec_ts * 1000` EXACTLY, never `+ tsSubsec`. The key has to stay as
      // unique as `rec_ts` was or the newest-wins dedupe splits into one row
      // per sub-second and every count in the app changes. The millisecond
      // resolution is headroom for a faster-than-1-Hz source, not a place to
      // put this record's own sub-second (which already has `ts_subsec`).
      'ts_ms': ?(preDeviceKey ? null : recTs * 1000),
      'rec_ts': recTs,
      'counter': raw.counter,
      // v43: ABSENCE IS NULL HERE TOO. `hr == 0` is the off-skin sentinel, so
      // writing a 0 for a record that simply has no heart-rate field asserts
      // the band was off the wrist. Every reader gates `hr > 0` (SQL) or maps
      // NULL to the same 0 (Dart), so this changes no number — it stops the
      // ledger from claiming something the record never said, and it is what
      // lets an accel-only record (gen4 v25) be banked at all. See
      // _createDecodedStore.
      'hr': decoded.hr > 0 ? decoded.hr : null,
      // NO `?? 0` on ANY of these (schema v39 made the sensor columns
      // nullable): a null must land in the DB as NULL. Zeroing invented a real
      // 0 g gravity vector, a real ADC count of 0, a 0-step second and a 0 °C
      // skin temperature for every record that simply did not carry the field.
      'ax': decoded.ax,
      'ay': decoded.ay,
      'az': decoded.az,
      'spo2_red_raw': decoded.spo2RedRaw,
      'spo2_ir_raw': decoded.spo2IrRaw,
      'skin_temp_raw': decoded.skinTempRaw,
      'step_count': decoded.stepCount,
      'step_cadence': decoded.stepCadence,
      'activity_class': decoded.activityClass,
      'skin_temp_c': decoded.skinTempC,
      'on_wrist': decoded.onWrist,
      'hr_valid': decoded.hrValid == null ? null : (decoded.hrValid! ? 1 : 0),
      'hr_alt': decoded.hrAlt,
      // MT-12 — gen5's second/third temperature channels and its own
      // signal-quality figure. Stored, unnamed, unread. See Sample.tempCh2C.
      'temp_ch2_c': decoded.tempCh2C,
      'temp_ch3_c': decoded.tempCh3C,
      'signal_quality_logvar': decoded.signalQualityLogVar,
      // OMITTED when null, unlike the three above: this column is newer than
      // the mid-ladder `_backfillDecodedStore`, which writes through this map
      // on the oldV<11 / oldV<20 rungs — before any step has handed the column
      // back. Naming a column that does not exist yet throws inside
      // onUpgrade's single transaction and quarantines the database. Only a
      // gen5 record carries a value, and no gen5 record is in a pre-v11
      // `raw_records`, so omitting-when-null loses nothing.
      'dyn_accel_g': ?decoded.dynAccelG,
      // The record's own sub-second. Omitted-when-null for the same
      // mid-ladder-backfill reason as `dyn_accel_g` directly above.
      'ts_subsec': ?decoded.tsSubsec,
      // The band's own wake/sleep envelope. gen5/MG only, so it is null on
      // everything the mid-ladder backfill can replay — but omitted-when-null
      // regardless, for the same reason.
      'band_sleep_state': ?decoded.bandSleepState,
      // 0 IS THE ABSENT SENTINEL, NOT A READING. records.dart:501 emits
      // `ambientRaw: optical ? u16@70 : 0`, so every unconfirmed record version
      // reports 0 — writing that through would turn "we did not read the
      // channel" into a real measurement of total darkness on a one-sided
      // signal where dark already means nothing. Omitted-when-null (same form
      // as device_family) so the mid-ladder backfill can't name a column a
      // pre-v42 rebuild has not handed back yet.
      'ambient_raw': ?ambient,
      // Which strap measured this second. Stamped from the live link; unknown
      // provenance is NULL, never a guess. See _ensureDeviceFamilyColumns.
      //
      // OMITTED when null rather than written as null — same stored value (the
      // column has no DEFAULT), but this map is also used by the MID-LADDER
      // `_backfillDecodedStore`, which runs before the v41 rung adds the
      // column. Naming a column that does not exist yet throws inside
      // onUpgrade's single transaction and quarantines the whole database.
      'device_family': ?deviceFamily,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return 1 /* the decoded_onehz insert */ +
        LocalDb._queueRrBeats(
          batch,
          recTs,
          decoded,
          deviceFamily: deviceFamily,
          deviceId: deviceId,
          preDeviceKey: preDeviceKey,
        );
  }

int _ldbPrivQueueRrBeats(Batch batch, int recTs, Sample decoded, {required String? deviceFamily, required String deviceId, required bool preDeviceKey}) {
    // SCOPED TO THE WRITING DEVICE (v47). Unscoped, this cleared every device's
    // beats for the second — so a second band writing one row deleted the
    // first band's R-R for that second, permanently (no raw copy is kept to
    // rebuild it). Same key prefix as the parent row, so the PK serves the
    // delete.
    if (preDeviceKey) {
      batch.rawDelete('DELETE FROM decoded_rr WHERE rec_ts = ?', [recTs]);
    } else {
      batch.rawDelete(
        'DELETE FROM decoded_rr WHERE device_id = ? AND ts_ms = ?',
        [deviceId, recTs * 1000],
      );
    }
    final beatTs = beatTimesMs(recTs, decoded.tsSubsec, decoded.rrIntervalsMs);
    var ops = 1;
    for (var i = 0; i < decoded.rrIntervalsMs.length; i++) {
      final rr = decoded.rrIntervalsMs[i];
      if (rr <= 0) continue;
      batch.insert('decoded_rr', {
        // Same key prefix as the parent row — see _createDecodedStore. Omitted
        // on the mid-ladder replay for the reason _queueDecodedOneHz gives.
        'device_id': ?(preDeviceKey ? null : deviceId),
        'ts_ms': ?(preDeviceKey ? null : recTs * 1000),
        'rec_ts': recTs,
        'beat_index': i,
        // UNCHANGED, DELIBERATELY. `rr_ts_ms` stays `rec_ts * 1000` and
        // `beat_ts_ms` lands beside it instead of replacing it, for one
        // concrete reason: the sub-second is NOT RECOVERABLE for a row already
        // on disk. Nothing stores it, and the raw frames it could be re-read
        // from are pruned at the retention edge — so redefining this column
        // would leave two different quantities living in it with nothing able
        // to tell them apart. A nullable column beside it says the true thing:
        // NULL is "we did not keep the sub-second for this beat", which is
        // exactly the case for every row written before today.
        //
        // The compute layer (substrate.dart, derive_prepare.dart) now prefers
        // `beat_ts_ms` and falls back to this column, so `rr_ts_ms` stays the
        // honest answer for every row that has no sub-second — which is every
        // row written before the column existed.
        'rr_ts_ms': recTs * 1000,
        'rr_ms': rr,
        // Omitted when null — see _queueDecodedOneHz. Also newer than the
        // mid-ladder backfill, same trap.
        'beat_ts_ms': ?beatTs[i],
        'device_family': ?deviceFamily,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      ops++;
    }
    return ops;
  }

int _ldbPrivQueueNeutralOneHz(Batch batch, NeutralSample n, {required String deviceFamily, required String deviceId}) {
    final recTs = n.tsEpoch;
    batch.insert(
      'decoded_onehz',
      {
        'device_id': deviceId,
        'ts_ms': recTs * 1000,
        'rec_ts': recTs,
        'counter': 0,
        // Absent is NULL, never zeroed — same rule _queueDecodedOneHz
        // follows for hr/accel/optical.
        'hr': n.hr,
        'skin_temp_c': n.skinTempC,
        'device_family': deviceFamily,
        'source': deviceFamily,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    var ops = 1;
    // SCOPED TO THE WRITING DEVICE. Clear the second before reinserting so a
    // shrinking beat count can't strand stale high-index beats — same
    // reasoning as _queueRrBeats, and it must run even when this sample
    // carries no beats, so a later re-read with fewer beats can't leave a
    // stale tail from an earlier one.
    batch.rawDelete(
      'DELETE FROM decoded_rr WHERE device_id = ? AND ts_ms = ?',
      [deviceId, recTs * 1000],
    );
    for (var i = 0; i < n.rrMs.length; i++) {
      final rr = n.rrMs[i];
      if (rr <= 0) continue;
      batch.insert(
        'decoded_rr',
        {
          'device_id': deviceId,
          'ts_ms': recTs * 1000,
          'rec_ts': recTs,
          'beat_index': i,
          'rr_ts_ms': recTs * 1000,
          'rr_ms': rr,
          // The beat's own end time when the host kept it (a strap's chain);
          // NULL otherwise, as on every row before it was kept.
          'beat_ts_ms': ?n.beatTsMs?[i],
          'device_family': deviceFamily,
          'source': deviceFamily,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      ops++;
    }
    return ops;
  }

Future<void> _ldbPutBandBacklog({required int ts, required String deviceId, required int? written, required int? used, required int? capacity, required int? trimPage, required int? wrapCount, required int? freeRecords, required String? deviceFamily}) async {
    final db = await LocalDb.instance;
    await db.insert('band_backlog', {
      'device_id': deviceId,
      'ts': ts,
      'written': written,
      'used': used,
      'capacity': capacity,
      'trim_page': trimPage,
      'wrap_count': wrapCount,
      'free_records': freeRecords,
      // Unknown provenance stays NULL — never defaulted to gen4.
      'device_family': deviceFamily,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

Future<void> _ldbInsertEvent(int eventId, int ts, String hex, {required String deviceId, required proto.BandProfile profile, required int? tsSubsec, required DateTime? receivedAt}) async {
    final capturedAt = (receivedAt ?? DateTime.now()).millisecondsSinceEpoch;
    // Parse BEFORE acquiring the handle so both inserts run back-to-back on one
    // validated `db` with no intervening await — minimizing the closed-DB race
    // window. Best-effort: a background teardown that closes the DB mid-write
    // must not crash the app (the band re-sends events).
    final parsed = () {
      try {
        return proto.parseEvent(proto.hexToBytes(hex), profile: profile);
      } catch (_) {
        return null;
      }
    }();
    final battery = parsed == null ? null : LocalDb.batteryRowFromEvent(parsed);
    // One transaction: the three rows are one event, and a drain issues one of
    // these per event, so single statements would each take the writer in turn.
    await LocalDb._guardedWrite((handle) => handle.transaction((db) async {
      await db.insert('events', {
        'device_id': deviceId,
        'hex': hex,
        'event_id': eventId,
        'ts': ts,
        'captured_at': capturedAt,
        'ts_subsec': tsSubsec ?? parsed?.tsSubsec ?? 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await db.insert('band_events', {
        'device_id': deviceId,
        'hex': hex,
        'event_id': eventId,
        'name': parsed?.name ?? proto.EventId.name(eventId),
        'ts': parsed?.tsEpoch ?? ts,
        'payload_json': jsonEncode(
          parsed?.decoded ?? const <String, dynamic>{},
        ),
        'captured_at': capturedAt,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      // A gen5 row stored before the profile reached this method sits as a
      // bare `EVENT_<id>` with `{}`. When the band re-sends that frame the
      // ignored insert above leaves it so; rewrite such an undecoded row, never
      // a decoded one. INSERT OR IGNORE + UPDATE, as in [upsertDevice].
      if (profile.isGen5 && parsed != null && parsed.name != 'EVENT_$eventId') {
        await db.update(
          'band_events',
          {'name': parsed.name, 'payload_json': jsonEncode(parsed.decoded)},
          where: 'device_id = ? AND hex = ? AND name = ?',
          whereArgs: [deviceId, hex, 'EVENT_$eventId'],
        );
      }
      if (battery != null) {
        await db.insert(
          'band_battery',
          {'device_id': deviceId, ...battery},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }), bestEffort: true);
  }

Future<List<StrapEvent>> _ldbStrapEvents({required String? deviceId, required int? eventId, required int? sinceTsEpoch, required int limit}) async {
    final db = await LocalDb.instance;
    final where = <String>[];
    final args = <Object?>[];
    if (deviceId != null) {
      where.add('device_id = ?');
      args.add(deviceId);
    }
    if (eventId != null) {
      where.add('event_id = ?');
      args.add(eventId);
    }
    if (sinceTsEpoch != null) {
      where.add('ts >= ?');
      args.add(sinceTsEpoch);
    }
    final rows = await db.query(
      'events',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args,
      orderBy: 'ts ASC, ts_subsec ASC',
      limit: limit,
    );
    return [
      for (final r in rows)
        StrapEvent(
          eventId: (r['event_id'] as num?)?.toInt() ?? 0,
          tsEpoch: (r['ts'] as num?)?.toInt() ?? 0,
          tsSubsec: (r['ts_subsec'] as num?)?.toInt() ?? 0,
          receivedAt: DateTime.fromMillisecondsSinceEpoch(
            (r['captured_at'] as num).toInt(),
            isUtc: true,
          ),
          hex: r['hex'] as String,
          deviceId: r['device_id'] as String,
        ),
    ];
  }

Map<String, Object?>? _ldbBatteryRowFromEvent(proto.EventInfo e) {
    if (e.tsEpoch <= 0) return null;
    if (e.eventId == proto.EventId.batteryLevel) {
      final pct = e.decoded['battery_pct'];
      final mv = e.decoded['battery_mv'];
      final charging = e.decoded['charging'];
      if (pct == null && mv == null) return null;
      return {
        'ts': e.tsEpoch,
        'battery_pct': pct is num ? pct.toDouble() : null,
        'charging': charging is bool ? (charging ? 1 : 0) : null,
        'wrist_on': null,
        'millivolts': mv is num ? mv.toInt() : null,
        'charge_units': null,
        'source': 'band_event',
      };
    }
    if (e.eventId == LocalDb.kExtendedBatteryInfoEventId) {
      final units = LocalDb.extendedChargeUnits(e.body);
      if (units == null) return null;
      return {
        'ts': e.tsEpoch,
        'battery_pct': null,
        'charging': null,
        'wrist_on': null,
        'millivolts': null,
        'charge_units': units,
        'source': 'band_event_ext',
      };
    }
    return null;
  }

int? _ldbExtendedChargeUnits(Uint8List body) {
    if (body.isEmpty) return null;
    // Offset is per BODY REVISION, never per length: a future revision that
    // happens to be 12 or 28 bytes long would otherwise be read at an offset
    // that was only ever verified for this one.
    final at = switch (body[0]) {
      3 => 9, // gen5 / MG
      1 => 11, // gen4
      _ => null,
    };
    if (at == null || body.length < at + 2) return null;
    final units = body[at] | (body[at + 1] << 8);
    // 0 is the absent/uninitialised read, not a flat pack — a strap reporting a
    // real battery level in the same second has not measured zero charge.
    return units > 0 ? units : null;
  }

Future<void> _ldbInsertBandBatterySample({required int ts, required String deviceId, required double? batteryPct, required bool? charging, required bool? wristOn, required int? millivolts, required String source}) async {
    // Best-effort background ingest — same closed-DB teardown race as
    // insertEvent; never crash over a battery row (it re-arrives on the poll).
    await LocalDb._guardedWrite((db) async {
      await db.insert('band_battery', {
        'device_id': deviceId,
        'ts': ts,
        'battery_pct': batteryPct,
        'charging': charging == null ? null : (charging ? 1 : 0),
        'wrist_on': wristOn == null ? null : (wristOn ? 1 : 0),
        'millivolts': millivolts,
        'source': source,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }, bestEffort: true);
  }

Future<Map<String, dynamic>> _ldbBatteryHealth({required int lookback}) async {
    final db = await LocalDb.instance;
    final rows = await LocalDb.recentBandBatterySamples(limit: lookback);
    final fullCharge = await db.rawQuery(
      'SELECT MAX(millivolts) AS mv FROM band_battery WHERE charging = 1',
    );
    final cycleRows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM band_events WHERE event_id = ?',
      [proto.EventId.chargingOn],
    );
    final fullChargeMv = (fullCharge.first['mv'] as num?)?.toInt();
    final cycles = (cycleRows.first['n'] as num?)?.toInt() ?? 0;
    // The most recent reading of each — NOT of the newest row. The sources
    // write different columns (the device tick has no voltage, the strap's
    // extended event has no percentage), so the newest row is routinely missing
    // one of the two and reading it alone reported "no voltage" on a series
    // that had one a few seconds earlier.
    T? newest<T>(String column, T? Function(Object?) read) {
      for (final r in rows) {
        final v = read(r[column]);
        if (v != null) return v;
      }
      return null;
    }

    return {
      'samples': rows.length,
      'full_charge_mv': fullChargeMv,
      'charge_cycles': cycles,
      'latest_pct': newest('battery_pct', (v) => (v as num?)?.toDouble()),
      'latest_mv': newest('millivolts', (v) => (v as num?)?.toInt()),
    };
  }

Future<void> _ldbArchiveRawRecord(ArchiveRecord a, {required String deviceId}) async {
    final db = await LocalDb.instance;
    await db.insert('raw_archive', {
      'device_id': deviceId,
      'counter': a.counter,
      'hex': a.hex,
      'packet_type': a.packetType,
      'rec_ts': a.recTs,
      'captured_at': a.capturedAt,
      'reason': a.reason,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

Future<int> _ldbRedriveArchiveOnce({required Duration budget}) async {
    Map<String, dynamic> state = {};
    if ((await LocalDb.computeFreshness(LocalDb.kArchiveRedriveKey))?['payload_json']
        case final String j) {
      final v = jsonDecode(j);
      if (v is Map) state = v.cast<String, dynamic>();
    }
    if (state['done'] == true) return 0;
    final row = await LocalDb.computeFreshness(LocalDb.kRedriveExcludedKey);
    final excluded =
        row == null ? const <(int, int)>[] : LocalDb._parseWindows(row['payload_json']);
    // Deleted days we can no longer read back: replaying could refill one,
    // so the replay waits rather than guess.
    if (excluded == null) return 0;
    final r = await LocalDb._redrive(
      await LocalDb.instance,
      reasons: LocalDb.redrivableArchiveReasons,
      honourDeletions: true,
      startHex: state['after_hex'] as String? ?? '',
      startDevice: state['after_device'] as String? ?? '',
      budget: budget,
    );
    final total = ((state['recovered'] as num?)?.toInt() ?? 0) + r.recovered;
    await LocalDb.putComputeFreshness(
      LocalDb.kArchiveRedriveKey,
      jsonEncode({
        'recovered': total,
        if (r.resume == null) 'done': true,
        if (r.resume case (final h, final d)) ...{
          'after_hex': h,
          'after_device': d,
        },
      }),
    );
    return r.recovered;
  }

Future<int> _ldbRedriveArchivedRecords(Database db, {required List<String> reasons}) async =>
      (await LocalDb._redrive(db, reasons: reasons)).recovered;

Future<({int recovered, (String, String)? resume})> _ldbPrivRedrive(Database db, {required List<String> reasons, required String startHex, required String startDevice, required Duration? budget, required bool honourDeletions}) async {
    final clock = Stopwatch()..start();
    // Both are cheap and both are required: a DB whose ladder has not created
    // the archive yet (or is mid-ladder) must no-op rather than throw — a throw
    // in here rolls the WHOLE upgrade back and quarantines the database.
    for (final t in const ['raw_archive', 'decoded_onehz']) {
      final present = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        [t],
      );
      if (present.isEmpty) return (recovered: 0, resume: null);
    }
    // SELF-DETECTING, because this runs from BOTH sides of the v47 rung: from
    // the oldV<44 ladder step, where `decoded_onehz` is still keyed by rec_ts
    // alone and naming `device_id` would throw inside onUpgrade (quarantining
    // the database), and from the app/tests on a re-keyed table. One PRAGMA.
    final preDeviceKey =
        !(await LocalDb._columnsOf(db, 'decoded_onehz')).contains('device_id');

    // Same self-detection as `preDeviceKey` above, for `raw_archive`'s own
    // rekey (v51): this function runs from the oldV<44 rung too, i.e. BEFORE
    // the v51 rekey, so at that point `raw_archive` is still hex-keyed and the
    // row-value comparison below must fall back to comparing `hex` alone.
    final preArchiveDeviceKey =
        !(await LocalDb._columnsOf(db, 'raw_archive')).contains('device_id');

    final marks = List.filled(reasons.length, '?').join(',');
    // Paged on the primary key, (device_id, hex) post-v51 and hex before it —
    // a stable, total order that needs no extra index and no offset scan.
    // Post-v51, `hex` alone is no longer unique
    // (two devices can share a byte-identical undecodable frame), so a plain
    // `hex > ?` cursor would silently skip the second device's row.
    var afterHex = startHex;
    var afterDevice = startDevice;
    var recovered = 0;
    while (true) {
      final rows = preArchiveDeviceKey
          ? await db.rawQuery(
              'SELECT hex, counter, packet_type, rec_ts, captured_at '
              'FROM raw_archive WHERE reason IN ($marks) AND hex > ? '
              'ORDER BY hex ASC LIMIT 500',
              [...reasons, afterHex],
            )
          : await db.rawQuery(
              'SELECT device_id, hex, counter, packet_type, rec_ts, captured_at '
              // Primary-key order (device_id, hex), so each page continues
              // down the key's own index instead of re-sorting the archive.
              'FROM raw_archive WHERE reason IN ($marks) AND (device_id, hex) > (?, ?) '
              'ORDER BY device_id ASC, hex ASC LIMIT 500',
              [...reasons, afterDevice, afterHex],
            );
      if (rows.isEmpty) return (recovered: recovered, resume: null);
      final pageHex = afterHex, pageDevice = afterDevice;
      afterHex = rows.last['hex'] as String;
      afterDevice = preArchiveDeviceKey ? '' : rows.last['device_id'] as String;

      // Decode first, keyed by (device, second) each record claims. Two
      // archived frames for the SAME device and second collapse here rather
      // than fighting over the primary key inside the batch — but two
      // DIFFERENT devices sharing a second (or a byte-identical frame, the
      // exact case the v51 rekey exists to preserve) must not collapse into
      // one another.
      final byDeviceRecTs = <(String, int), (RawRecord, Sample)>{};
      for (final r in rows) {
        final deviceId =
            preArchiveDeviceKey ? LocalDb.kPrimaryDeviceId : r['device_id'] as String;
        final raw = RawRecord(
          counter: (r['counter'] as num?)?.toInt() ?? 0,
          packetType: (r['packet_type'] as num?)?.toInt() ?? 0,
          hex: r['hex'] as String,
          capturedAt: (r['captured_at'] as num?)?.toInt() ?? 0,
          recTs: (r['rec_ts'] as num?)?.toInt(),
        );
        final s = LocalDb._decodeOneHzSample(raw);
        // Still undecodable under today's decoders. Left in the archive,
        // untouched, for the build that can read it.
        if (s == null) continue;
        final recTs = LocalDb._recTsFrom(raw, s);
        // `rec_ts` is NULL on every archived row on all three real exports (we
        // archive a frame precisely because we never learned its time), so this
        // is the decoded timestamp — and a record with no plausible time has
        // nowhere to land in a table keyed by one.
        if (recTs <= 0) continue;
        byDeviceRecTs[(deviceId, recTs)] = (raw, s);
      }
      if (byDeviceRecTs.isEmpty) {
        if (budget != null && clock.elapsed > budget) {
          return (recovered: recovered, resume: (afterHex, afterDevice));
        }
        continue;
      }

      // "Already decoded" must be checked PER DEVICE once decoded_onehz
      // carries device_id — otherwise device B's second looks "taken" because
      // device A already has a row at that same rec_ts.
      final taken = <(String, int)>{};
      if (preDeviceKey) {
        final keys = [for (final k in byDeviceRecTs.keys) k.$2];
        for (var i = 0; i < keys.length; i += 400) {
          final end = i + 400 < keys.length ? i + 400 : keys.length;
          final slice = keys.sublist(i, end);
          for (final e in await db.rawQuery(
            'SELECT rec_ts FROM decoded_onehz WHERE rec_ts IN '
            '(${List.filled(slice.length, '?').join(',')})',
            slice,
          )) {
            taken.add((LocalDb.kPrimaryDeviceId, (e['rec_ts'] as num).toInt()));
          }
        }
      } else {
        final byDevice = <String, List<int>>{};
        for (final k in byDeviceRecTs.keys) {
          (byDevice[k.$1] ??= []).add(k.$2);
        }
        for (final entry in byDevice.entries) {
          final keys = entry.value;
          for (var i = 0; i < keys.length; i += 400) {
            final end = i + 400 < keys.length ? i + 400 : keys.length;
            final slice = keys.sublist(i, end);
            for (final e in await db.rawQuery(
              'SELECT rec_ts FROM decoded_onehz WHERE device_id = ? AND '
              'rec_ts IN (${List.filled(slice.length, '?').join(',')})',
              [entry.key, ...slice],
            )) {
              taken.add((entry.key, (e['rec_ts'] as num).toInt()));
            }
          }
        }
      }

      // Deleted days are read in the SAME transaction as the write, so a
      // deletion that commits while this page decodes cannot be refilled. An
      // unreadable list stops the replay at this page. (The ladder path runs
      // inside onUpgrade's own transaction and has nothing deleted to honour.)
      var unreadable = false;
      Future<void> write(DatabaseExecutor ex) async {
        var excluded = const <(int, int)>[];
        if (honourDeletions) {
          final row = await ex.query('compute_freshness',
              where: 'key = ?', whereArgs: [LocalDb.kRedriveExcludedKey], limit: 1);
          if (row.isNotEmpty) {
            final w = LocalDb._parseWindows(row.first['payload_json']);
            if (w == null) {
              unreadable = true;
              return;
            }
            excluded = w;
          }
        }
        final batch = ex.batch();
        var queued = 0;
        for (final e in byDeviceRecTs.entries) {
          if (taken.contains(e.key)) continue;
          final t = e.key.$2;
          if (excluded.any((w) => t >= w.$1 && t < w.$2)) continue;
          final (raw, sample) = e.value;
        // `sample` is handed back as `preferred` so the hex is decoded once,
        // not twice; `_queueDecodedOneHz` returns it straight back out.
        // `deviceFamily` is deliberately omitted — see the doc comment.
          if (LocalDb._queueDecodedOneHz(
                batch,
                raw,
                sample,
                deviceId: e.key.$1,
                preDeviceKey: preDeviceKey,
              ) >
              0) {
            queued++;
          }
        }
        if (queued > 0) await batch.commit(noResult: true);
        recovered += queued;
      }

      if (honourDeletions) {
        await db.transaction(write);
      } else {
        await write(db);
      }
      if (unreadable) {
        return (recovered: recovered, resume: (pageHex, pageDevice));
      }
      if (budget != null && clock.elapsed > budget) {
        return (recovered: recovered, resume: (afterHex, afterDevice));
      }
    }
  }

Future<Map<String, dynamic>> _ldbRawArchiveStats() async {
    final db = await LocalDb.instance;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM raw_archive'),
        ) ??
        0;
    final byReason = await db.rawQuery(
      'SELECT reason, COUNT(*) AS n FROM raw_archive '
      'GROUP BY reason ORDER BY n DESC, reason ASC',
    );
    return {
      'count': count,
      'by_reason': {
        for (final row in byReason)
          (row['reason']?.toString() ?? 'unknown'):
              (row['n'] as num?)?.toInt() ?? 0,
      },
    };
  }

Future<Map<String, dynamic>> _ldbBandSignalsStats() async {
    final db = await LocalDb.instance;
    final eventCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM band_events'),
        ) ??
        0;
    final batteryCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM band_battery'),
        ) ??
        0;
    final eventSpan = (await db.rawQuery(
      'SELECT MIN(ts) AS lo, MAX(ts) AS hi FROM band_events',
    )).first;
    final batterySpan = (await db.rawQuery(
      'SELECT MIN(ts) AS lo, MAX(ts) AS hi FROM band_battery',
    )).first;
    final eventKinds = await db.rawQuery(
      'SELECT name, COUNT(*) AS n FROM band_events GROUP BY name ORDER BY n DESC, name ASC',
    );
    return {
      'event_count': eventCount,
      'battery_count': batteryCount,
      'event_min_ts': (eventSpan['lo'] as num?)?.toInt(),
      'event_max_ts': (eventSpan['hi'] as num?)?.toInt(),
      'battery_min_ts': (batterySpan['lo'] as num?)?.toInt(),
      'battery_max_ts': (batterySpan['hi'] as num?)?.toInt(),
      'event_kinds': {
        for (final row in eventKinds)
          (row['name']?.toString() ?? 'unknown'):
              (row['n'] as num?)?.toInt() ?? 0,
      },
    };
  }

Future<void> _ldbInsertRecordsBatch(List<RawRecord> raws, List<Sample?> samples) async {
    if (raws.isEmpty) return;
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < raws.length; i++) {
        final raw = raws[i];
        final sample = samples[i];
        LocalDb._queueDecodedOneHz(batch, raw, sample);
      }
      await batch.commit(noResult: true);
    });
  }

Future<void> _ldbUpsertSyncLedgerEntry({required String chunkId, required String kind, required String status, required int? ackedAt, required String? lastError, required Map<String, dynamic>? metaPatch, required DatabaseExecutor? txn}) async {
    final db = txn ?? await LocalDb.instance;
    final existing = await LocalDb.syncLedgerEntry(chunkId, txn);
    final now = DateTime.now().millisecondsSinceEpoch;
    final meta = <String, dynamic>{};
    if (existing != null) {
      final rawMeta = existing['meta_json'];
      if (rawMeta is String && rawMeta.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawMeta);
          if (decoded is Map) {
            meta.addAll(decoded.cast<String, dynamic>());
          }
        } catch (_) {
          /* keep empty */
        }
      }
    }
    if (metaPatch != null) meta.addAll(metaPatch);
    await db.insert('sync_ledger', {
      'chunk_id': chunkId,
      'kind': kind,
      'status': status,
      'created_at': (existing?['created_at'] as num?)?.toInt() ?? now,
      'updated_at': now,
      'acked_at': ackedAt ?? (existing?['acked_at'] as num?)?.toInt(),
      'last_error': lastError,
      'meta_json': jsonEncode(meta),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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

Future<Sample?> _ldbLatestSample() async {
    final db = await LocalDb.instance;
    final decodedRows = await db.query(
      'decoded_onehz',
      columns: LocalDb._decodedSampleColumns,
      where: kPrimaryBandSourceSql,
      orderBy: 'rec_ts DESC, counter DESC',
      limit: 1,
    );
    if (decodedRows.isNotEmpty) {
      return Sample.fromDecodedRow(decodedRows.first);
    }
    final rows = await db.query('samples', orderBy: 'ts DESC', limit: 1);
    return rows.isEmpty ? null : Sample.fromDbMap(rows.first);
  }

Future<(int?, int?)> _ldbFirstAndLastRecordTs() async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      // rec_ts > 0, matching rawStats()/lastDecodedRecTs() — a stray rec_ts=0
      // row (e.g. via _queueDecodedOneHz's `raw.recTs ?? decoded.tsEpoch`,
      // which only substitutes on null, not on an explicit 0) would otherwise
      // make MIN(rec_ts) return 0 and render "Data from Jan 1" (1970 epoch).
      'SELECT MIN(rec_ts) AS lo, MAX(rec_ts) AS hi FROM decoded_onehz '
      'WHERE rec_ts > 0 AND ${derivableSourceSql()}',
    );
    if (rows.isEmpty) return (null, null);
    final lo = (rows.first['lo'] as num?)?.toInt();
    final hi = (rows.first['hi'] as num?)?.toInt();
    return (lo, hi);
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

Future<List<Map<String, dynamic>>> _ldbDecodedOneHzBatchByRecTsRange({required int limit, required int fromRecTs, required int toRecTs, required int? afterRecTs, required int? afterCounter}) async {
    InputReads.note('decoded', '');
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

Future<List<Map<String, dynamic>>> _ldbDecodedRrByRecTsRange({required int fromRecTs, required int toRecTs}) async {
    InputReads.note('decoded', '');
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

Future<List<Map<String, dynamic>>> _ldbDecodedRrSecondsByRecTsRange({required int fromRecTs, required int toRecTs, required bool onlyBeatOnly}) async {
    InputReads.note('decoded', '');
    final db = await LocalDb.instance;
    final lo = fromRecTs <= toRecTs ? fromRecTs : toRecTs;
    final hi = fromRecTs <= toRecTs ? toRecTs : fromRecTs;
    final noRow = onlyBeatOnly
        ? 'AND NOT EXISTS (SELECT 1 FROM decoded_onehz o '
            'WHERE o.rec_ts = decoded_rr.rec_ts '
            'AND o.device_id = decoded_rr.device_id '
            'AND ${derivableSourceSql('o.source')}) '
        : '';
    return db.rawQuery(
      'SELECT DISTINCT rec_ts, device_id '
      'FROM decoded_rr '
      'WHERE rec_ts >= ? AND rec_ts <= ? AND ${derivableSourceSql()} '
      '$noRow'
      'ORDER BY rec_ts ASC',
      [lo, hi],
    );
  }

Future<List<String>> _ldbSignalPriority(InputSignal signal) async {
    InputReads.note('device_coverage', '');
    final db = await LocalDb.instance;
    final rows = await db.query(
      'signal_priority',
      columns: ['device_id'],
      where: 'signal = ?',
      whereArgs: [signal.name],
      orderBy: 'rank ASC, device_id ASC',
    );
    return [for (final r in rows) r['device_id'] as String];
  }

Future<void> _ldbSetSignalPriority(InputSignal signal, List<String> order) async {
    final db = await LocalDb.instance;
    final name = signal.name;
    await db.transaction((txn) async {
      await txn.delete('signal_priority', where: 'signal = ?', whereArgs: [name]);
      for (var i = 0; i < order.length; i++) {
        await txn.insert('signal_priority', {
          'signal': name,
          'device_id': order[i],
          'rank': i,
          'user_set': 1,
        });
      }
    });
  }

Future<List<CoverageInterval>> _ldbCoverageIntervals(InputSignal signal, int from, int to) async {
    InputReads.note('device_coverage', '');
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

Future<Map<String, List<String>>> _ldbCoverageDevicesByDay({required List<String> signals, required int fromSec, required int toSec}) async {
    if (signals.isEmpty || toSec <= fromSec) return const {};
    final db = await LocalDb.instance;
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

Future<void> _ldbNoteBandFirmware(String fw, {required int? nowSec}) =>
      LocalDb._updateFreshnessJson(LocalDb.kBandFirmwareKey, (m) {
        final now = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final history = [
          for (final e in (m['history'] as List?) ?? const [])
            if (e is Map) e.cast<String, dynamic>(),
        ];
        if (history.isEmpty || history.last['fw'] != fw) {
          history.add({'fw': fw, 'first_seen': now});
        }
        // Bounded: firmware changes a handful of times a year.
        final kept = history.length > 20
            ? history.sublist(history.length - 20)
            : history;
        return {'fw': fw, 'last_seen': now, 'history': kept};
      });

Future<List<Map<String, dynamic>>> _ldbHrSamplesInRange(int fromTs, int toTs) async {
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

Future<
      ({
        Map<String, Map<String, num>> stats,
        Map<String, List<int>> samples,
      })> _ldbSessionHrReads(int fromTs, int toTs, {required int maxHrCeiling, required int minHrFloor}) async {
    if (LocalDb.sessionSensorSources.isEmpty) {
      return (
        stats: await LocalDb._sessionHrStatsSql(fromTs, toTs, maxHrCeiling, minHrFloor),
        samples: await LocalDb._sessionHrSamplesSql(fromTs, toTs),
      );
    }
    final r = await groupSessionWindows(fromTs, toTs,
        maxHrCeiling: maxHrCeiling, minHrFloor: minHrFloor);
    return (stats: r.stats, samples: r.samples);
  }

Future<Map<String, Map<String, num>>> _ldbSessionHrStats(int fromTs, int toTs, {required int maxHrCeiling, required int minHrFloor}) async {
    if (LocalDb.sessionSensorSources.isNotEmpty) {
      return (await LocalDb.sessionHrReads(fromTs, toTs,
              maxHrCeiling: maxHrCeiling, minHrFloor: minHrFloor))
          .stats;
    }
    return LocalDb._sessionHrStatsSql(fromTs, toTs, maxHrCeiling, minHrFloor);
  }

Future<Map<String, Map<String, num>>> _ldbPrivSessionHrStatsSql(int fromTs, int toTs, int maxHrCeiling, int minHrFloor) async {
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

Future<Map<String, List<int>>> _ldbPrivSessionHrSamplesSql(int fromTs, int toTs) async {
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

Future<int> _ldbPruneDecodedBeforeRecTs(int cutoffSec, {required String? cursorName, required SubstrateArchivePolicy? archive, required int? hardFloorSec, required void Function(String message)? log, required bool Function()? shouldYield, required int? maxArchiveBuckets, required int? expectedRevSum}) async {
    final db = await LocalDb.instance;
    final policy = archive ?? await LocalDb.substrateArchivePolicy();
    // `deleted` used to just stay 0 forever - none of the txn.delete() calls'
    // return values (rows actually deleted) were ever added to it, so the
    // caller's `if (deleted > 0) log(...)` never fired even on a real prune.
    var skipped = false;
    int deleted = 0;
    // The archive step deletes in its own per-bucket transactions, so the
    // revision is checked before it as well: a record that landed since the
    // caller looked means the day is not fully derived (invariant 9).
    if (expectedRevSum != null &&
        await LocalDb._revSumBefore(db, cutoffSec) != expectedRevSum) {
      return -1;
    }
    var expectedAfterArchive = expectedRevSum;
    if (policy.enabled) {
      deleted += await SubstrateArchive.archiveAndDeleteBefore(
        db,
        cutoffSec,
        hardFloorSec: hardFloorSec,
        log: log,
        shouldYield: shouldYield,
        maxBuckets: maxArchiveBuckets,
        onDeleted: cursorName == null
            ? null
            : (txn, beforeSec) => LocalDb._raiseCursorVia(txn, cursorName, beforeSec),
      );
      // The archive's own deletes move the revision (the triggers fire on
      // DELETE). Re-read it so the check below catches a record landing after
      // the archive, not the archive itself. A record that landed during it
      // either went into a bucket still to be archived (archived losslessly
      // with it) or sits in one already done, where it stays live: the
      // delete below takes only rows with no record time.
      if (expectedAfterArchive != null) {
        expectedAfterArchive = await LocalDb._revSumBefore(db, cutoffSec);
      }
    }
    // With archiving on, only the undatable rows are left for this delete;
    // a bucket the archive kept live must stay live.
    final decodedWhere = policy.enabled ? 'rec_ts <= 0' : 'rec_ts < ?';
    final decodedArgs = policy.enabled ? const <Object?>[] : [cutoffSec];
    await db.transaction((txn) async {
      if (expectedAfterArchive != null &&
          await LocalDb._revSumBefore(txn, cutoffSec) != expectedAfterArchive) {
        skipped = true;
        return;
      }
      if (cursorName != null) {
        await LocalDb._raiseCursorVia(txn, cursorName, cutoffSec);
      }
      // A beat lives on its parent's second (decoded_rr's key extends the
      // parent's `(device_id, ts_ms)`, and both carry the same `rec_ts`), so a
      // plain rec_ts range delete covers every beat in the window — no counter
      // subquery, no orphan sweep.
      deleted += await txn.delete(
        'decoded_rr',
        where: decodedWhere,
        whereArgs: decodedArgs,
      );
      deleted += await txn.delete(
        'decoded_onehz',
        where: decodedWhere,
        whereArgs: decodedArgs,
      );
      deleted += await txn.delete(
        'samples',
        where: 'ts < ?',
        whereArgs: [cutoffSec],
      );
      deleted += await txn.delete(
        'events',
        where: 'ts < ?',
        whereArgs: [cutoffSec],
      );
      // band_events keeps its WEAR AND CHARGE TRANSITIONS forever; everything
      // else in it goes at the cutoff. `detectNaps` rejects bouts that overlap
      // an off-wrist or on-charger span, and those spans are built by
      // `_toggleSpans` out of exactly these four ids — so with them pruned at
      // `rawRetentionDays`, any re-derive of an older day ran the nap detector
      // with BOTH rejection lists empty and a charging session on the desk
      // could score as a nap. Nap history rewrote itself, quietly, just for
      // being looked at.
      //
      // Same shape as the band_battery exemption below (a retention cap
      // structurally destroys a lifetime series), and the same size argument:
      // on the three real exports these four ids are 87, 22 and 12 rows across
      // 8 to 11 days — a few thousand a year. Event 33 alone is ~1900 A DAY,
      // which is why the exemption is four ids and not the whole table.
      deleted += await txn.delete(
        'band_events',
        where: 'ts < ? AND event_id NOT IN (?, ?, ?, ?)',
        whereArgs: [
          cutoffSec,
          proto.EventId.chargingOn,
          proto.EventId.chargingOff,
          proto.EventId.wristOn,
          proto.EventId.wristOff,
        ],
      );
      // THE UNDECODABLE ARCHIVE IS THINNED, NOT KEPT WHOLE. See
      // [thinRawArchiveBefore] — this is the only caller, so the archive is
      // capped by the same retention pass that caps the substrate.
      deleted += await LocalDb._thinRawArchiveVia(txn, cutoffSec * 1000);
      // band_battery is NOT pruned here. It was, at the substrate cutoff,
      // which structurally capped the battery-health series at
      // `rawRetentionDays` — while batteryHealth() reports `charge_cycles`
      // (rising 0→1 charging edges) and `full_charge_mv` (rolling max mV while
      // charging), both of which only mean anything across the life of the
      // pack. A year-old band would have reported 1 cycle. Six narrow columns a
      // few minutes apart is not a storage problem; the 1 Hz substrate is.
      // ponytail: unbounded, so give it its own multi-year cutoff if a real
      // install's table ever shows up big.
    });
    return skipped ? -1 : deleted;
  }

Future<int> _ldbVacuumIfBloated({required int minFreeBytes}) async {
    final free = await LocalDb.freelistBytes();
    if (free < minFreeBytes) return 0;
    final db = await LocalDb.instance;
    await db.execute('VACUUM');
    // VACUUM rewrites the file and renumbers every btree root page. CoachDb
    // caches the root pages of its allow-listed views to decide what a coach
    // query is allowed to touch, and nothing else calls CoachDb.close() — so
    // after this ran, every valid coach query started failing its own guard
    // ("Query reaches storage outside the coach views") for the rest of the
    // process. The invariant belongs to whoever moves the pages.
    await CoachDb.close();
    return free;
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

