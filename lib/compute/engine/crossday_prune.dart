part of '../derivation_engine.dart';

extension _EngineCrossDayPrune on DerivationEngine {
  /// The second pass behind [quietLevelRepassDays]: reload the history once
  /// and re-derive the owed days that have a level now, raw still on disk. One
  /// pass converges — a day's own `quiet_hrr` reads no history, so the
  /// reloaded snapshot holds every level the first pass produced. A day it
  /// scores clears its own marker ([_derivePreparedDay]); one it fails keeps
  /// it, stays unfinalized with its raw held, and is retried next run.
  /// [rawDays] (every day with substrate left) retires markers for days whose
  /// raw is gone, and so does a night the prune already cut into (the
  /// [_maxRawHoldDays] floor can): re-deriving it would replace a full-night
  /// result with a truncated one, exactly as [rescanDayIds] refuses to. Either
  /// way the day's raw has aged out and its abstention is final.
  ///
  /// Held, like [rescanRecent], while a timezone change is suspected: these
  /// days are bucketed in the CURRENT zone, so re-deriving them would relabel
  /// and overwrite the nights that hold protects. They stay owed (unfinalized,
  /// raw held) until "Re-analyze data" clears it.
  ///
  /// [rawDays] defaults to every day with substrate, read only when a marker
  /// exists. Returns how many days it re-derived, so the caller's cross-day
  /// refresh runs for them.
  /// Retires `profile_repass:` markers of days whose raw is gone (pruned, or
  /// cut by the prune): nothing can re-derive them, so the abstention is final.
  /// Settled like [_quietLevelRepass] settles truncated days; a day with no
  /// rows at all has no fingerprint, so it is settled on the empty one and
  /// reopens if raw ever returns. Days that still have raw stay owed (their
  /// next derive finalizes them by the hold bound).
  Future<void> _retireProfileOwed(Iterable<String>? rawDays) async {
    try {
      final owed = {
        for (final k in await LocalDb.computeFreshnessKeys(
            DerivationEngine.kProfileRepassKeyPrefix))
          k.substring(DerivationEngine.kProfileRepassKeyPrefix.length),
      };
      if (owed.isEmpty) return;
      final prunedBeforeSec =
          await LocalDb.getCursorInt(DerivationEngine._prunedBeforeCursor);
      final withRaw = {
        for (final d in rawDays ?? (await LocalDb.decodedRecTsMaxByDay()).keys)
          if (!DerivationEngine.windowTruncatedByPrune(d, prunedBeforeSec)) d,
      };
      final gone = owed.difference(withRaw);
      if (gone.isEmpty) return;
      final fps = await LocalDb.decodedDayFingerprints({
        for (final d in gone) ...[d, DerivationEngine._adjacentDayIds(d).first],
      });
      final edits = await _editSigs(gone);
      for (final d in gone) {
        if (fps[d] == null) {
          await LocalDb.putSettledDay(d, kAlgoVersion,
              own: '', prev: null, edit: edits[d] ?? '');
        } else {
          await _settleDay(d, fps, edits);
        }
        await LocalDb.deleteComputeFreshness(
            '${DerivationEngine.kProfileRepassKeyPrefix}$d');
      }
    } catch (e) {
      _log('profile repass retire failed (markers kept): $e');
    }
  }

  Future<int> _quietLevelRepass(
    Profile profile,
    int dataNowSec, [
    Iterable<String>? rawDays,
  ]) async {
    var done = 0;
    await _retireProfileOwed(rawDays);
    try {
      final owed = await DerivationEngine._quietRepassOwedDays();
      if (owed.isEmpty) return 0;
      if (await _timezoneTravelSuspected()) {
        _log('quiet repass: possible timezone change — held');
        return 0;
      }
      // Raw fingerprints taken BEFORE the hook, the retire loop and every
      // prepare: a day that declines is settled on what it was prepared from,
      // so rows landing meanwhile leave it reopened rather than "handled".
      final fps = await LocalDb.decodedDayFingerprints({
        for (final d in owed) ...[d, DerivationEngine._adjacentDayIds(d).first],
      });
      final edits = await _editSigs(owed);
      final prunedBeforeSec = await LocalDb.getCursorInt(DerivationEngine._prunedBeforeCursor);
      final withRaw = {
        for (final d in rawDays ?? (await LocalDb.decodedRecTsMaxByDay()).keys)
          if (!DerivationEngine.windowTruncatedByPrune(d, prunedBeforeSec)) d,
      };
      for (final d in owed.difference(withRaw)) {
        // Retired for truncation: the abstention is final, so the day is
        // settled, not left pending for every later pass to pick again.
        await _settleDay(d, fps, edits);
        await LocalDb.deleteComputeFreshness('${DerivationEngine.kQuietRepassKeyPrefix}$d');
      }
      await DerivationEngine.debugQuietRepassHook?.call(null);
      final after = await _BaselineHistoryCache.load();
      final days = DerivationEngine.quietLevelRepassDays(
        owed.intersection(withRaw),
        // The day's own method family, as its derive reads it.
        after: (d) => after.valuesBefore('quiet_hrr', d,
            family: after._families['quiet_hrr']?[d]),
      )..sort((a, b) => b.compareTo(a)); // newest first, like the sweep
      if (days.isEmpty) return 0;
      _log('derive: re-scoring ${days.length} day(s) owed a quiet level');
      await runWithConcurrency(days, _deriveConcurrency, (dayId) async {
        try {
          await DerivationEngine.debugQuietRepassHook?.call(dayId);
          final prepared = await _prepareTargetDay(dayId);
          if (prepared != null && !prepared.daySub.isEmpty) {
            final r = await _derivePreparedDay(prepared, profile, dataNowSec, after);
            if (r == DayDerive.committed) {
              done++;
            } else if (r == DayDerive.declined) {
              // Kept its existing result: final for this raw, so retire the
              // marker and settle rather than retry forever.
              await _settleDay(dayId, fps, edits);
              await LocalDb.deleteComputeFreshness(
                  '${DerivationEngine.kQuietRepassKeyPrefix}$dayId');
            }
          }
        } catch (e) {
          _log('quiet repass day $dayId FAILED (kept owed, raw held): $e');
        }
      });
    } catch (e) {
      _log('quiet repass failed (days kept owed, raw held): $e');
    }
    return done;
  }

  Future<bool> _runCrossDayUntimed(Profile profile) async {
    try {
      final reviewRevision = await LocalDb.activityReviewRevision();
      final days = await _crossDayInputDays();
      if (days.length < 3) {
        _log('crossday: only ${days.length} usable day(s) — skip');
        return true;
      }
      final profileMap = profile.toMap();
      // Her own logged cycle starts. Read on the DB-owning isolate (sqflite),
      // passed in as plain strings so the bundle stays pure. Only `start`
      // markers — the other kinds are not what a cycle is counted from.
      final cycleStarts = <String>[
        for (final r in await LocalDb.cycleLogs())
          if (r['kind'] == 'start' && r['date'] is String) r['date'] as String,
      ];
      // TS-11's grouping key. Read here (sqflite is main-isolate only) and
      // handed in as plain strings so the bundle stays pure.
      final sessionTypes = await DerivationEngine._sessionTypesByDate(days);
      // Encode INSIDE the isolate too — a real ~3.5-4.7s main-isolate hang was
      // caught in production (Crashlytics jank_watchdog, correlated with a
      // heavy derive pass) coming from jsonEncode-ing this bundle back on the
      // main isolate after Isolate.run returned it. Returning the already-
      // encoded string avoids both the main-isolate encode cost AND transfers
      // a flat string across the isolate boundary instead of a large nested Map.
      // Stamped so the READER can fail closed. Without these the bundle was
      // indistinguishable from a current one: after a version bump — or on any
      // path that leaves the stored artifact untouched (the `< 3 days` return
      // above, or the catch below) — VO₂max, fitness age, sleep need, strain
      // target, glass-box readiness and the illness flags all kept serving the
      // PREVIOUS version's answers with nothing on screen to say so. Same
      // defect as `crossDayArtifactUsableToday` guards on the INPUT artifact,
      // one layer up on the output.
      final builtForDay = LocalDb.localDayLabelNow();
      final builtAtEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // The bundle is a pure function of exactly these. When the stored one was
      // built from the same, recomputing it would write the same bundle: keep
      // it, and only restamp it as written now (the "as of" label reads that).
      // A false mismatch is harmless (it recomputes); a false match is not
      // possible short of a SHA-256 collision.
      final inputSig = DerivationEngine._crossDayInputSig(
        days: days,
        profile: profileMap,
        cycleStarts: cycleStarts,
        sessionTypes: sessionTypes,
        builtForDay: builtForDay,
      );
      if (inputSig != null &&
          await LocalDb.baselineJsonString('crossday', r'$.input_sig') ==
              inputSig) {
        await LocalDb.touchBaseline('crossday');
        _log('crossday: inputs unchanged — kept the stored bundle');
        return true;
      }
      _crossDayComputed++;
      final (bundleJson, dropped) = await DerivationEngine._runIsolateCancellable(
        () {
          final bundle =
              buildCrossDayBundle(
                  days,
                  profileMap,
                  cycleStartDates: cycleStarts,
                  sessionTypesByDate: sessionTypes,
                )
                ..['algo_version'] = kAlgoVersion
                ..['built_for_day'] = builtForDay
                ..['built_at_epoch'] = builtAtEpoch;
          if (inputSig != null) bundle['input_sig'] = inputSig;
          // Encode-safety BEFORE jsonEncode, never a try/catch around it: one
          // non-finite leaf must cost that leaf, not the whole artifact.
          final paths = <String>[];
          final safe = sanitizeForJson(bundle, paths) as Map<String, dynamic>;
          if (paths.isNotEmpty) safe['encode_dropped_fields'] = paths;
          return (jsonEncode(safe), paths);
        },
        DerivationEngine._crossDayTimeout,
        label: 'crossday',
      );
      if (!await LocalDb.putReviewedBaseline('crossday', bundleJson, reviewRevision)) {
        _log('crossday: newer activity review; leaving its refresh queued');
        return false;
      }
      if (dropped.isNotEmpty) {
        // Loud, not debug-only: a dropped field is a metric the user will see
        // as absent, and the reason lives here and nowhere else.
        debugPrint('[derive] crossday: ${dropped.length} field(s) were not '
            'JSON-encodable and were stored as absent: ${dropped.join(", ")}');
      }
      _log('crossday: stored over ${days.length} day(s)');
      return true;
    } catch (e, st) {
      // NOT a debug line. A failure here means the stored bundle is now STALE
      // — the reader's version/day stamp will reject it and the whole
      // cross-day family goes absent — so it has to be visible in a release
      // build, with the stack, or the cause is unrecoverable after the fact.
      debugPrint('[derive] crossday BUNDLE DROPPED — the stored artifact is '
          'now stale and every cross-day metric will read absent: $e\n$st');
      _log('crossday FAILED/skipped: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _refreshCrossDayInputArtifact() async {
    // A review (accepting or editing a nap or workout) started after this read
    // must not be overwritten by it (putReviewedBaseline below). Imported days'
    // vendor scores are masked out of the rollup (crossDayInputRecord).
    final reviewRevision = await LocalDb.activityReviewRevision();
    final imported = await LocalDb.importedDates();
    // Per-day records are kept between passes (see crossday_input.dart): the
    // payload-free read says which days' stored result changed, and only those
    // payloads are read and decoded. Before, every pass read and decoded all of
    // the 90 (~8 MB), although only today's row moves during the day. The DB
    // reads stay on the main isolate (sqflite); decoding and encoding still
    // happen in a worker, which is where the ~3.5-4.7 s jank_watchdog hang came
    // from when all 90 were decoded on this one.
    final meta = await LocalDb.recentDayResultsMeta(DerivationEngine._crossDayWindow);
    final today = LocalDb.localDayLabelNow();
    Object? previous;
    final stored = (await LocalDb.baseline('crossday_input'))?['payload_json'];
    if (stored is String && stored.isNotEmpty) {
      try {
        previous = jsonDecode(stored);
      } catch (_) {
        // Rebuild from the stored results.
      }
    }
    // Only an artifact of THIS version has the record shape this build writes.
    final sameVersion =
        previous is Map && (previous['algo_version'] as num?)?.toInt() == kAlgoVersion;
    if (sameVersion &&
        DerivationEngine.crossDayArtifactUsableToday(previous, today) &&
        crossDayInputCurrent(previous, meta)) {
      perf.addCount('crossday_payload_rows', 0);
      return [
        for (final row in previous['days'] as List)
          if (row is Map) row.cast<String, dynamic>(),
      ];
    }
    final kept = sameVersion
        ? keptCrossDayInput(previous)
        : const <String, CrossDayKept>{};
    final fullRows = await LocalDb.dayResultsByIds(crossDayDaysToRead(meta, kept));
    perf.addCount('crossday_payload_rows', fullRows.length);
    // Measured only when the perf instance is enabled (a walk over every row).
    perf.addCountLazy('crossday_payload_chars', () => fullRows.fold(0, (n, r) {
      final p = r['payload_json'];
      return n + (p is String ? p.length : 0);
    }));
    final full = {for (final r in fullRows) r['day_id'] as String: r};
    final (days, json) = await DerivationEngine._runIsolateCancellable(() {
      final out = assembleCrossDayInput(
        meta: meta,
        today: today,
        kept: kept,
        full: full,
        makeRecord: (row, payload) => DerivationEngine.crossDayInputRecord(row, payload,
            today: today, imported: imported),
        unsettled: (rec, m) {
          final wakeSec = (rec['wake_sec'] as num?)?.toInt();
          final edgeSec = (rec['data_edge_sec'] as num?)?.toInt();
          return (m['finalized'] as num?) != 1 &&
              (wakeSec == null ||
                  edgeSec == null ||
                  edgeSec < wakeSec + _headlineFreezeMarginSec);
        },
      );
      // `built_for_day` is what makes the `is_today` stamps inside `days`
      // interpretable later. Without it the envelope carries day-relative facts
      // with no day attached, and any reader has to assume freshness.
      // `row_keys` names the stored result each record came from.
      return (
        out.days,
        jsonEncode({
          'algo_version': kAlgoVersion,
          'built_for_day': today,
          'review_revision': reviewRevision,
          'days': out.days,
          'row_keys': out.keys,
        })
      );
    }, DerivationEngine._crossDayTimeout, label: 'crossday-input');
    await LocalDb.putReviewedBaseline('crossday_input', json, reviewRevision);
    return days;
  }

  Future<void> _runNotificationsUntimed({String? today}) async {
    try {
      final cdRow = await LocalDb.baseline('crossday');
      final cd = DerivationEngine._decodeBundle(cdRow?['payload_json']);
      if (cd == null) return;
      // The whole decision is `planExceptionNotices` (findings.dart), pure
      // and tested; this only reads its inputs and emits what it returns.
      today ??= LocalDb.localDayLabelNow();
      final anchor = exceptionAnchor(cd);
      // Only a pin taken on the anchor day's own night (LocalDb.headlinePinFor).
      final pinValue =
          anchor == null ? null : await LocalDb.headlinePinFor(anchor.date);
      final notices = planExceptionNotices(
        cd,
        today: today,
        irregularFlag: anchor == null
            ? null
            : await LocalDb.metricValueOn(anchor.date, 'irregular_rhythm_flag'),
        pin: pinValue == null ? null : (day: anchor!.date, value: pinValue),
        storedReadiness: anchor == null
            ? null
            : await LocalDb.metricValueOn(anchor.date, 'readiness'),
      );

      // One notice per day the findings are ABOUT. The key's date is that
      // day, so a night fires at most once however many passes see it.
      //
      // The key carries the day's HIGHEST severity class, not just the day.
      //
      // With a bare '$date:exception' the first pass of the day claimed the
      // slot whatever it found, so a day that opened with nothing but "low
      // readiness" and then turned an illness flag RED in the evening
      // discarded the illness flag — the one class of notification the design
      // does sanction, suppressed by a low-priority sibling of the same day.
      // Keyed this way an ESCALATION still gets through exactly once, while a
      // re-derive that finds the same class again (or merely adds another
      // finding of a class already announced) stays silent.
      // The other direction needs saying too: a day that opens RED and then
      // DE-escalates (the illness flag clears by evening, "low readiness"
      // remains) used to buzz a second time under the still-unclaimed plain
      // key, about a finding the morning's aggregate already carried. So a
      // presented medical exception burns the day's plain slot as well —
      // only on a real present, or a medical one lost to quiet hours would
      // take the plain one down with it.
      // Composed here, with no BuildContext, so the words come from the ARBs
      // in the language the app is showing (findingTitle / findingDetail).
      final strings =
          notices.isEmpty ? null : await LocaleController.currentStrings();
      for (final notice in notices) {
        final fired = await NotificationCenter.instance.emit(
          NotificationEvent(
            dedupeKey: notice.dedupeKey,
            category: NotifCategory.health,
            priority: NotifPriority.critical,
            title: notice.title(strings!),
            body: notice.body(strings),
            date: notice.date,
            route: '/heart',
          ),
        );
        if (notice.medical && fired) {
          await const FiredKeyStore().recordFired('${notice.date}:exception');
        }
      }
    } catch (e) {
      _log('notifications FAILED/skipped: $e');
    }
  }

  /// Prune raw older than [rawRetentionDays] BEHIND THE DATA EDGE. Retention is
  /// measured against the last record timestamp we actually drained
  /// ([dataNowSec]), never the wall clock, and rows are deleted by their record
  /// time (`rec_ts`), never receive time (`captured_at`) — a multi-day flash
  /// backfill received in one sync must not be pruned just because it landed
  /// "now".
  ///
  /// RAW-FIRST, DAY-SCOPED. A day in [rawDayIds] not yet finalized at the
  /// current algo version pulls the cutoff back to its derive window instead of
  /// aborting the whole prune — the old all-or-nothing guard meant a single
  /// stuck day kept every older day's substrate too. Bounded by
  /// [_maxRawHoldDays] so a permanently-stuck day cannot wedge it.
  ///
  /// [rawDayIds] must be every day that still HAS substrate (`scope.rawDays`),
  /// not the days this pass targeted: the day at risk is precisely the one that
  /// fell out of the scope while still un-derived.
  ///
  /// WHY THIS CANNOT RACE A COMPUTATION THAT STILL NEEDS THE ROWS:
  ///   * Both call sites are inside `run()`, which holds the process-wide
  ///     `_running` latch across its entire body — no other derive, restage,
  ///     rescan or import pass can be reading substrate while this runs.
  ///   * Within this run it is reached only after `runWithConcurrency` has
  ///     awaited every day's `processDay` (prepare + compute + persist) and
  ///     after the cross-day rollup, so nothing in flight still holds a claim.
  ///   * It does not move the retention window — that is still
  ///     `rawRetentionDays` behind the data edge, exactly as documented. This
  ///     change only makes the documented window actually apply. Anything that
  ///     must outlive it has to be PERSISTED into `day_result` when the day is
  ///     derived rather than re-read from `decoded_onehz` on demand — which is
  ///     why a workout's average HR is written into the bundle (it was once
  ///     re-derived lazily and vanished the moment its substrate aged out).
  Future<void> _pruneOldDecoded(List<String> rawDayIds, int dataNowSec) async {
    final cutoffSec = DerivationEngine.rawPruneCutoffSec(
      dataNowSec: dataNowSec,
      rawDayIds: rawDayIds,
      // Finalized AND complete: a finalized partial row (an import can be
      // both) is still not derived, so its raw is held (invariant 9). The
      // merge took upstream's finalized rule; ours held on completeness.
      // FINALIZED only, never settled (AGENTS 3.9): a settled day is one
      // that kept an older result because this raw could not improve it, but
      // its raw is not "fully derived" at this version. A later algo version
      // (which invalidates the settling) or a re-derive may still want it, and
      // the retention floor already bounds how long it is held.
      finalizedDayIds: (await LocalDb.finalizedDayIds(kAlgoVersion))
          .difference(await LocalDb.partialDayIds(kAlgoVersion)),
    );
    if (cutoffSec == null) return;
    // Lossy sample archive of the 1 Hz signals BEFORE the rows go (write
    // only: nothing derived ever reads it back - invariant 3). Best effort: a
    // failure here must not hold the prune, which is what enforces
    // `rawRetentionDays`. `created_at` is the data-edge second, not a wall
    // clock.
    //
    // RACE: an offload can land during this pass behind a window the archive
    // already read. The input revision at or before the cutoff is read BEFORE
    // the archive and the delete runs only if it is unchanged (checked inside
    // the delete's transaction); otherwise nothing is pruned this pass and the
    // next one archives the straggler first. If the archive itself threw there
    // is nothing to protect, so the prune is unguarded exactly as before.
    int? revSum;
    try {
      revSum = await LocalDb.decodedRevSumBefore(cutoffSec);
      await SampleArchiver.archiveBefore(cutoffSec,
          nowSec: dataNowSec, log: _log);
    } catch (e) {
      revSum = null;
      _log('sample archive skipped: $e');
    }
    // Highest cutoff ever applied: a held-back pass can cut lower, but rows
    // below an earlier cut are still gone. See [rescanDayIds]. Advanced inside
    // the delete's own transaction, so a kill can't split the two and a
    // concurrent lower-cutoff run can't write it backwards.
    //
    // ARCHIVED, NOT LOST: the rows go to `substrate_archive` first (see
    // LocalDb.pruneDecodedBeforeRecTs). The cut stays a local midnight; an
    // archive bucket it splits (buckets are UTC days) merges on the next pass.
    final deleted = await LocalDb.pruneDecodedBeforeRecTs(
      cutoffSec,
      cursorName: DerivationEngine._prunedBeforeCursor,
      hardFloorSec: dataNowSec - DerivationEngine._maxRawHoldDays * 86400,
      log: _log,
      shouldYield: offloadActive,
      // A background engine runs on a short, throttled budget in its own
      // isolate, where the foreground offload flag is not visible: one bucket
      // per pass bounds how long it can hold the write lock.
      maxArchiveBuckets: background ? 1 : null,
      expectedRevSum: revSum,
    );
    if (deleted < 0) {
      _log('prune deferred: records landed behind the archive pass');
    }
    if (deleted > 0) {
      _log('pruned $deleted decoded rows with rec_ts < $cutoffSec');
    }
    // Superseded generations of the recomputable per-day intermediates. Runs
    // here rather than inside the decoded prune so it stays off the path to a
    // durable commit.
    final stale = await LocalDb.pruneSupersededIntermediates();
    if (stale > 0) {
      _log('pruned $stale superseded intermediate rows');
    }
  }
}
