part of '../db.dart';

Future<int> _ldbClaimNotifSlot(
    String category,
    String dedupeKey, {
    required int startAt,
    required int bandSize,
    int maxProbes = 1024,
  }) async {
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

Future<void> _ldbUpsertDevice({
    String id = LocalDb.kPrimaryDeviceId,
    String? adapterId,
    String? remoteId,
    String? label,
    String? tier,
    bool clearAdapterId = false,
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await LocalDb.instance;
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

Future<void> _ldbExtendCoverageVia(
    DatabaseExecutor txn, {
    required String deviceId,
    required List<Sample?> samples,
    required List<int> sampleSecs,
    List<NeutralSample>? neutrals,
    Map<String, int>? toleranceSec,
    String? deviceFamily,
  }) async {
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

Future<void> _ldbAddLiveCoverage(
    int startTs,
    int endTs,
    int steps,
    String day, {
    String source = LocalDb.kStepSourceBand,
    // WHICH physical sensor counted (see [_ensureLiveCoverageDeviceId]). The
    // phone is the primary device's own pedometer, so it keeps `''` too —
    // `source` is what tells wrist from pocket.
    String deviceId = LocalDb.kPrimaryDeviceId,
  }) async {
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

Future<void> _ldbReplacePhoneCoverageForDay(
    String day,
    List<({int startTs, int endTs, int steps})> windows,
  ) async {
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

Future<void> _ldbCommitSyncBatch(
    List<RawRecord> raws,
    List<Sample?> samples, {
    String? trimToken,
    Map<String, String>? extraCursors,
    List<ArchiveRecord>? archives,
    /// Rows from a band with no framed record to decode — a notify sensor's
    /// beats, a ring's stamped temperature. Queued into the SAME transaction
    /// as [raws], so a source with no flash still gets the one durable write
    /// path and the one conflict policy. Null on every WHOOP commit, where it
    /// costs exactly one null check.
    List<NeutralSample>? neutrals,
    // WHOOP MG raw ECG (R16) records recovered by this burst. Same
    // transaction as everything else here — they have no other durable home.
    List<EcgRawPacket>? ecgRawPackets,
    void Function(String)? onCheckpoint,
    String? deviceFamily,
    String deviceId = LocalDb.kPrimaryDeviceId,
    // Per-signal (InputSignal.name) tolerance for the coverage writer's
    // "still the same interval" gap check. db.dart cannot read a
    // BandAdapter's declared cadence (it imports nothing from lib/ble/), so
    // the host supplies it; a signal absent from the map defaults to
    // 2*kBucket (120s) inside [_extendCoverageVia].
    Map<String, int>? coverageToleranceSec,
    // [ResetGate.generation] when the writing session began. Checked inside
    // the commit gate, where it cannot be raced: a batch from a session that
    // started before a "delete everything" is refused even once the reset has
    // finished and the gate is down again. Null checks only that no reset is
    // running right now.
    int? resetGeneration,
  }) =>
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
            resetGeneration: resetGeneration,
          ));

Future<void> _ldbCommitSyncBatchLocked(
    List<RawRecord> raws,
    List<Sample?> samples, {
    String? trimToken,
    Map<String, String>? extraCursors,
    List<ArchiveRecord>? archives,
    List<NeutralSample>? neutrals,
    // WHOOP MG raw ECG (R16) records recovered by this burst. Same
    // transaction as everything else here — they have no other durable home.
    List<EcgRawPacket>? ecgRawPackets,
    void Function(String)? onCheckpoint,
    // Which strap this batch came off, from the LIVE LINK (the engine pins it at
    // service discovery). Null = the caller could not name it, which lands as
    // NULL = unknown provenance. Never defaulted to gen4.
    String? deviceFamily,
    // WHICH PHYSICAL DEVICE these rows belong to (see [kPrimaryDeviceId]).
    String deviceId = LocalDb.kPrimaryDeviceId,
    Map<String, int>? coverageToleranceSec,
    int? resetGeneration,
  }) async {
    // A batch queued on the gate before "delete everything" started reaches
    // here only after the wipe ([wipeAll] runs on the same gate). Every
    // caller re-checks ResetGate before calling, but this one runs LATER than
    // any of those checks, so it is the one that cannot be raced. Thrown, so
    // the caller keeps its buffer and never ACKs.
    if (resetGeneration == null
        ? ResetGate.active
        : ResetGate.changedSince(resetGeneration)) {
      throw StateError('data reset in progress');
    }
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
            batch.insert(
              LocalDb.rawArchiveTable,
              LocalDb.rawArchiveRow(
                deviceId: deviceId,
                hex: a.hex,
                counter: a.counter,
                packetType: a.packetType,
                recTs: a.recTs,
                capturedAt: a.capturedAt,
                reason: a.reason,
              ),
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
            if (++ops >= chunkOps) await flushChunk();
          }
        }
        // SAFE-TRIM INVARIANT, same rule: the raw ECG records land in this
        // transaction, before the ACK that lets the band trim them.
        if (ecgRawPackets != null) {
          for (final e in ecgRawPackets) {
            batch.insert('ecg_raw_packet', {
              'hex': e.hex,
              'device_id': e.deviceId,
              'sequence': e.sequence,
              'strap_seconds': e.strapSeconds,
              'strap_subsec': e.strapSubsec,
              'captured_at': e.capturedAt,
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
        // Only a real record moves the frontier. A commit that banked none (a
        // bare HISTORY_END token, gate-dropped archives) on an install with no
        // cursor yet would otherwise persist '0', which every `?? fallback`
        // reader takes as a real frontier at the 1970 epoch.
        if (maxCounter > 0) {
          await LocalDb.setCursor(kCounter, '$maxCounter', txn: txn);
        }
        if (maxRecTs > 0) {
          await LocalDb.setCursor(kRecTs, '$maxRecTs', txn: txn);
        }
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
        // Freshness must roll back with the rows and cursor on failure.
        await LocalDb._writeCaptureFreshness(txn, raws);
      });
    } finally {
      // ALWAYS restore NORMAL — even if the commit threw — so a leaked FULL does
      // not fsync every subsequent write on this connection. Non-fatal.
      try {
        await db.execute('PRAGMA synchronous=NORMAL');
      } catch (_) {
        /* non-fatal — see open-time PRAGMA discipline */
      }
    }
  }

Future<void> _ldbWriteCaptureFreshness(
    DatabaseExecutor txn,
    List<RawRecord> raws,
  ) async {
    if (raws.isEmpty) return;
    var latest = 0;
    for (final raw in raws) {
      final recTs = LocalDb._recTsFor(raw);
      if (recTs > latest) latest = recTs;
    }
    if (latest <= 0) return;
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

Sample? _ldbDecodeOneHzSample(RawRecord raw, {Sample? preferred}) {
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

int _ldbQueueDecodedOneHz(
    Batch batch,
    RawRecord raw,
    Sample? sample, {
    String? deviceFamily,
    String deviceId = LocalDb.kPrimaryDeviceId,
    // TRUE ONLY FROM A MID-LADDER REPLAY, and it is not a style choice. This
    // map is also written by `_backfillDecodedStore` (rungs oldV<11 / oldV<20)
    // and `redriveArchivedRecords` (rung oldV<44), both of which run BEFORE the
    // v47 rung hands `device_id` / `ts_ms` back — and naming a column that does
    // not exist yet throws inside onUpgrade's one exclusive transaction and
    // quarantines the whole database. Their rows are re-keyed by
    // [_rekeyTableByDevice] a few rungs later, from `rec_ts`, which is the same
    // value this path would have written.
    //
    // The default is FALSE and the key columns are named, deliberately: the
    // opposite default would let a forgotten argument write every row at
    // ('', 0), where REPLACE collapses the entire store to ONE row.
    bool preDeviceKey = false,
  }) {
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

int _ldbQueueRrBeats(
    Batch batch,
    int recTs,
    Sample decoded, {
    String? deviceFamily,
    String deviceId = LocalDb.kPrimaryDeviceId,
    bool preDeviceKey = false,
  }) {
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

int _ldbQueueNeutralOneHz(
    Batch batch,
    NeutralSample n, {
    // NOT nullable, unlike the framed path's: see the refusal in
    // [_commitSyncBatchLocked] — an unnamed `source` reads as the primary band.
    required String deviceFamily,
    required String deviceId,
  }) {
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

Future<void> _ldbPutBandBacklog({
    required int ts,
    String deviceId = LocalDb.kPrimaryDeviceId,
    int? written,
    int? used,
    int? capacity,
    int? trimPage,
    int? wrapCount,
    int? freeRecords,
    String? deviceFamily,
  }) async {
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

Map<String, Object?> _ldbRawArchiveRow({
    required String deviceId,
    required String hex,
    required int? counter,
    required int packetType,
    required int? recTs,
    required int capturedAt,
    required String reason,
  }) {
    final bytes = LocalDb._canonicalHexBytes(hex);
    return {
      'device_id': deviceId,
      'hash': Uint8List.fromList(
        bytes != null
            ? sha1.convert(bytes).bytes
            : sha1.convert(utf8.encode('text:$hex')).bytes,
      ),
      'counter': counter,
      'packet_type': packetType,
      'rec_ts': recTs,
      'captured_at': capturedAt,
      'reason': reason,
      'hex': bytes == null ? hex : null,
      'frame': bytes,
    };
  }

Future<void> _ldbInsertEvent(
    int eventId,
    int ts,
    String hex, {
    required String deviceId,
    // Required, not defaulted: a default of gen4 is exactly how every gen5
    // BATTERY_PACK_INFO / condition-report / haptics event was stored as a
    // bare `EVENT_<id>` with an empty payload.
    required proto.BandProfile profile,
  }) async {
    final capturedAt = DateTime.now().millisecondsSinceEpoch;
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
    await LocalDb._guardedWrite((db) async {
      await db.insert('events', {
        'device_id': deviceId,
        'hex': hex,
        'event_id': eventId,
        'ts': ts,
        'captured_at': capturedAt,
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
    }, bestEffort: true);
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

Future<void> _ldbInsertBandBatterySample({
    required int ts,
    required String deviceId,
    double? batteryPct,
    bool? charging,
    bool? wristOn,
    int? millivolts,
    required String source,
  }) async {
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

Future<Map<String, dynamic>> _ldbBatteryHealth({
    int lookback = 2000,
  }) async {
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

Future<int> _ldbRedriveArchiveOnce({
    Duration budget = const Duration(seconds: 20),
  }) async {
    Map<String, dynamic> state = {};
    if ((await LocalDb.computeFreshness(LocalDb.kArchiveRedriveKey))?['payload_json']
        case final String j) {
      final v = jsonDecode(j);
      if (v is Map) state = v.cast<String, dynamic>();
    }
    if (state['done'] == true) return 0;
    // Wait for the legacy archive to finish moving: the replay reads the new
    // store only, and marking it done over a half-moved archive would skip
    // the rest for good.
    if (await LocalDb._objectType(await LocalDb.instance, LocalDb._rawArchiveLegacy) == 'table') {
      return 0;
    }
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

Future<({int recovered, (String, String)? resume})> _ldbRedrive(
    Database db, {
    required List<String> reasons,
    String startHex = '',
    String startDevice = '',
    Duration? budget,
    bool honourDeletions = false,
  }) async {
    final clock = Stopwatch()..start();
    // Both are cheap and both are required: a DB whose ladder has not created
    // the archive yet (or is mid-ladder) must no-op rather than throw — a throw
    // in here rolls the WHOLE upgrade back and quarantines the database.
    // The archive is the `raw_archive` table on the ladder's older layouts,
    // and [rawArchiveView] over [rawArchiveTable] once converted.
    final framesLayout = await LocalDb._objectType(db, LocalDb.rawArchiveView) == 'view';
    for (final t in [framesLayout ? LocalDb.rawArchiveView : 'raw_archive',
        'decoded_onehz']) {
      final present = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') "
        'AND name=?',
        [t],
      );
      if (present.isEmpty) return (recovered: 0, resume: null);
    }
    // The converted store pages on its own rowid (the hex is computed, so
    // paging on it would sort the archive every page). Its cursor travels in
    // the same (String, String) slot, marked by [_redriveRowidCursor]; a
    // position from the old hex-ordered pass restarts at the top, which the
    // replay's skip-what-is-decoded rule makes safe.
    var afterRowid = framesLayout && startDevice == LocalDb._redriveRowidCursor
        ? int.tryParse(startHex) ?? 0
        : 0;
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
    final preArchiveDeviceKey = !framesLayout &&
        !(await LocalDb._columnsOf(db, 'raw_archive')).contains('device_id');

    final marks = List.filled(reasons.length, '?').join(',');
    // Paged on the primary key, (device_id, hex) post-v51 and hex before it —
    // a stable, total order that needs no extra index and no offset scan.
    // Post-v51, `hex` alone is no longer unique
    // (two devices can share a byte-identical undecodable frame), so a plain
    // `hex > ?` cursor would silently skip the second device's row.
    var afterHex = framesLayout ? '$afterRowid' : startHex;
    var afterDevice = framesLayout ? LocalDb._redriveRowidCursor : startDevice;
    var recovered = 0;
    while (true) {
      final rows = framesLayout
          ? await db.rawQuery(
              'SELECT rowid AS _r, device_id, ${LocalDb._rawArchiveHexSql} AS hex, '
              'counter, packet_type, rec_ts, captured_at '
              'FROM ${LocalDb.rawArchiveTable} WHERE reason IN ($marks) AND rowid > ? '
              'ORDER BY rowid ASC LIMIT 500',
              [...reasons, afterRowid],
            )
          : preArchiveDeviceKey
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
      if (framesLayout) {
        afterRowid = (rows.last['_r'] as num).toInt();
        afterHex = '$afterRowid';
      } else {
        afterHex = rows.last['hex'] as String;
        afterDevice =
            preArchiveDeviceKey ? '' : rows.last['device_id'] as String;
      }

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

Future<int> _ldbThinRawArchiveVia(
    DatabaseExecutor txn,
    int beforeMs,
  ) async {
    var deleted = 0;
    // The store and, until [migrateLegacyRawArchive] has emptied it, the
    // renamed-aside legacy table: the same rule over both.
    for (final t in [
      LocalDb.rawArchiveTable,
      if (await LocalDb._objectType(txn, LocalDb._rawArchiveLegacy) == 'table')
        LocalDb._rawArchiveLegacy,
    ]) {
      deleted += await txn.delete(
        t,
        // `counter` is NOT NULL in practice but the column is nullable, and
        // `NULL % 60` is NULL — so a counter-less row would never match and
        // would be kept. Keeping an unsampleable frame is the safe direction.
        where: 'reason = ? AND captured_at < ? AND counter % ? != 0',
        whereArgs: [LocalDb._thinnedArchiveReason, beforeMs, LocalDb.rawArchiveKeepEvery],
      );
    }
    return deleted;
  }

Future<Map<String, dynamic>> _ldbRawArchiveStats() async {
    final db = await LocalDb.instance;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ${LocalDb.rawArchiveView}'),
        ) ??
        0;
    final byReason = await db.rawQuery(
      'SELECT reason, COUNT(*) AS n FROM ${LocalDb.rawArchiveView} '
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

Future<void> _ldbUpsertSyncLedgerEntry({
    String chunkId = 'capture',
    String kind = 'historical',
    required String status,
    int? ackedAt,
    String? lastError,
    Map<String, dynamic>? metaPatch,
    DatabaseExecutor? txn,
  }) async {
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

Future<int> _ldbPruneDecodedBeforeRecTs(
    int cutoffSec, {
    String? cursorName,
    SubstrateArchivePolicy? archive,
    int? hardFloorSec,
    void Function(String message)? log,
    bool Function()? shouldYield,
    int? maxArchiveBuckets,
  }) async {
    final db = await LocalDb.instance;
    final policy = archive ?? await LocalDb.substrateArchivePolicy();
    // `deleted` used to just stay 0 forever - none of the txn.delete() calls'
    // return values (rows actually deleted) were ever added to it, so the
    // caller's `if (deleted > 0) log(...)` never fired even on a real prune.
    int deleted = 0;
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
    }
    // With archiving on, only the undatable rows are left for this delete;
    // a bucket the archive kept live must stay live.
    final decodedWhere = policy.enabled ? 'rec_ts <= 0' : 'rec_ts < ?';
    final decodedArgs = policy.enabled ? const <Object?>[] : [cutoffSec];
    await db.transaction((txn) async {
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
    return deleted;
  }

Future<int> _ldbVacuumIfBloated({int minFreeBytes = 64 << 20}) async {
    final free = await LocalDb.freelistBytes();
    if (free < minFreeBytes) return 0;
    final db = await LocalDb.instance;
    await LocalDb._resetRedriveResume();
    await db.execute('VACUUM');
    // VACUUM rewrites the file and renumbers every btree root page. CoachDb
    // caches the root pages of its allow-listed views to decide what a coach
    // query is allowed to touch, and nothing else calls CoachDb.close() — so
    // after this ran, every valid coach query started failing its own guard
    // ("Query reaches storage outside the coach views") for the rest of the
    // process. The invariant belongs to whoever moves the pages.
    await CoachDb.close();
    // The VACUUM wrote the whole database through the -wal. Copy it back and
    // truncate it now, rather than at the next write; the size limit set on
    // open covers it if a reader holds this checkpoint back.
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {
      /* non-fatal: the bytes are reclaimed, the -wal shrinks on a later write */
    }
    return free;
  }

Future<int> _ldbPruneSupersededIntermediates({
    int keepVersions = 2,
  }) async {
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
