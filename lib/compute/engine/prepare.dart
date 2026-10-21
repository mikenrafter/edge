part of '../derivation_engine.dart';

extension _EnginePrepare on DerivationEngine {
  /// [reuse]: this pass may resume from the day's stored checkpoint (it is not a
  /// user-driven re-derive). A resumable day is then loaded without the beats
  /// the checkpoint already folded (see [DayRrResume]).
  Future<PreparedDerivationDay?> _prepareTargetDay(String dayId,
      {bool reuse = false, bool banked = false}) async {
    // Per-day page/row totals used to live in the shared `_diag` map (reset
    // then accumulated across this day's 2-3 substrate loads). Under
    // concurrent per-day processing (see `run()`), multiple days resetting/
    // incrementing the SAME shared fields would race and produce garbage
    // diagnostics (never a correctness issue for the derived VALUES — this
    // is telemetry-only). Each day now gets its own local accumulator,
    // merged into the shared running max exactly once, below.
    final stats = _PrepareStats();
    // The day's raw as it stands BEFORE anything below reads it: the input
    // signature of the calorie artifact this derive stores.
    final inputFp = (await perf.stage(
        'fingerprints', () => LocalDb.decodedDayFingerprints([dayId])))[dayId];
    final dayStart = DerivationEngine._localDayLabelToSec(dayId);
    final dayEnd = DerivationEngine._localNextDayLabelToSec(dayId);
    // The same, for the day checkpoint: the revision of each 15-minute bucket
    // of the day before any of its rows is read.
    final inputRevs = await LocalDb.inputRevisions(
        dayStart ~/ kRevBucketSec, (dayEnd - 1) ~/ kRevBucketSec + 1);
    // The checkpoint carries the day's RR and curve states independently of
    // the calculation state retained by this process. Probe it on warm passes
    // too, so their substrate load contains only the tail that extends it.
    final rrResume = reuse ? await _probeRrResume(dayId, inputRevs) : null;
    // A COLD day's windows are cut from one cross-day union (one read of the
    // hours they and the neighbouring days share). A day with a checkpoint to
    // resume from or loads kept from the last pass is WARM: its loads already
    // read only the rows that can have changed (substrate_retention.dart), so
    // they stay window by window.
    final unionHolder = !debugDisableSubstrateUnionLoad &&
            !_lowMemory &&
            rrResume == null &&
            !_retained.containsKey(DerivationEngine._retainedKey(dayId, 'load_day')) &&
            !_retained.containsKey(DerivationEngine._retainedKey(dayId, 'load_search'))
        ? _UnionHolder()
        : null;
    final candidate = await _sleepCandidateForDay(dayId,
        stats: stats, banked: banked, union: unionHolder);

    // M5: resolve ownership ONCE, over the union of every window this method
    // loads, and pass the same span lists to both the row filter and the
    // bundle write — the equality between them is then true by
    // construction, not an agreement between separate computations.
    // `_targetDayWindow` is cheap/pure (it has its own test seam,
    // `debugTargetDayWindow`) — called again here rather than hoisting the
    // call already inside `_sleepCandidateForDay`, which stays local to that
    // function and runs before `candidate` exists.
    final range = _targetDayWindow(dayId);
    final unionFrom = [
      dayStart,
      range.$1,
      if (candidate.present) candidate.sleepOnsetSec,
    ].reduce(math.min);
    final unionTo = [
      dayEnd - 1 + napBoundaryBufferSec,
      range.$2,
      if (candidate.present) candidate.sleepOffsetSec,
    ].reduce(math.max);

    final (ownership, priority) = await _resolveOwnership(unionFrom, unionTo);

    // Load the day PLUS the nap boundary buffer in ONE pass (each
    // _loadSubstrateRange spawns its own isolate, so a second load would
    // double that cost) and slice the calendar day back out of it. Without
    // this, the live decoded path — run()/runDays()/rescanRecent(), i.e. every
    // non-import day — fell back to napSub == daySub and went on bisecting
    // naps at midnight.
    final sleepSpan = candidate.present &&
            candidate.sleepOffsetSec > candidate.sleepOnsetSec
        ? (candidate.sleepOnsetSec, candidate.sleepOffsetSec - 1)
        : null;
    if (unionHolder != null && unionHolder.load == null) {
      // The night came from the stored candidate, so no search window was
      // read: the day and the staged night are the union.
      unionHolder.load = await _loadUnion(
          dayId,
          math.min(dayStart, sleepSpan?.$1 ?? dayStart),
          math.max(dayEnd - 1 + napBoundaryBufferSec, sleepSpan?.$2 ?? 0),
          stats: stats);
    }
    var napSub = (await _cutWindow(unionHolder?.load, dayId, 'load_day',
                dayStart, dayEnd - 1 + napBoundaryBufferSec, ownership,
                retain: true, stats: stats))
            ?.sub ??
        await _loadSubstrateRange(
          dayStart,
          dayEnd - 1 + napBoundaryBufferSec,
          dayId: dayId,
          stats: stats,
          label: 'load_day',
          ownership: ownership,
          rrFromRecTs: rrResume?.skipBelowRecTs,
          retain: true,
        );
    // A day the primary band never saw is the ACTIVE WEARABLE's, when one is
    // chosen and flagged on (inputs/canonical.dart). Never mixed: a day with
    // a single primary row stays the primary's, so WHOOP days cannot move.
    // "Saw" is the calendar day, the same test the scope and the re-derive
    // use (`decodedRecTsMaxByDay`): band rows only in the next morning's nap
    // buffer do not keep the wearable off a day it alone covers.
    final wearable =
        napSub.slice(dayStart, dayEnd).isEmpty ? await activeWearable() : null;
    if (wearable != null) {
      await _resolveSparseOwnership(
          unionFrom, unionTo, wearable.$1, ownership, priority);
      napSub = await wearableSubstrate(
          wearable, dayStart, dayEnd - 1 + napBoundaryBufferSec);
    }
    final daySub = napSub.slice(dayStart, dayEnd);
    Substrate sleepSub = Substrate.empty;
    if (candidate.present &&
        candidate.sleepOffsetSec > candidate.sleepOnsetSec) {
      sleepSub = wearable != null
          ? await wearableSubstrate(wearable, candidate.sleepOnsetSec,
              candidate.sleepOffsetSec - 1)
          : (await _cutWindow(unionHolder?.load, dayId, 'load_sleep',
                      candidate.sleepOnsetSec, candidate.sleepOffsetSec - 1,
                      ownership, stats: stats))
                  ?.sub ??
              await _loadSubstrateRange(
                candidate.sleepOnsetSec,
                candidate.sleepOffsetSec - 1,
                dayId: dayId,
                stats: stats,
                label: 'load_sleep',
                ownership: ownership,
              );
    }
    _noteHeldRows(napSub.length + sleepSub.length);
    if (stats.fullReload) perf.addCount('substrate_full_reloads', 1);
    // Single safe merge into the shared max-tracking diagnostics — one
    // statement, no `await` in between, so it's atomic relative to any other
    // concurrently-running day's identical merge.
    if (stats.pages > (_diag['max_day_raw_pages'] as int)) {
      _diag['max_day_raw_pages'] = stats.pages;
    }
    if (stats.rows > (_diag['max_day_raw_rows'] as int)) {
      _diag['max_day_raw_rows'] = stats.rows;
    }
    // Tonight's sleep is the NEXT day's main sleep; it is only known once
    // that day has derived, and this day keeps re-deriving until it
    // finalizes, so it converges on the following pass.
    final nextSpan = await _nextDayWindowSpan(dayId);
    _tonightSpanAtPrep[dayId] = nextSpan;
    final tonight = DerivationEngine.tonightSleep(
      nextSpan,
      dayStartSec: dayStart,
      dayEndSec: dayEnd,
      sleepOffsetSec: candidate.present ? candidate.sleepOffsetSec : 0,
    );
    return candidate.toPreparedDay(
      daySub: daySub,
      napSub: napSub,
      sleepSub: sleepSub,
      tonightSleepOnsetSec: tonight?.startSec ?? 0,
      tonightSleepOffsetSec: tonight?.endSec ?? 0,
      ownership: ownership,
      priority: priority,
      inputFp: inputFp,
      inputRevs: inputRevs,
      // A wearable's day is read whole from its own store: the checkpoint's
      // beat skip applies to the band's rows only, and the full-beat reload
      // after a stream refusal ([_withFullRr]) reads the band's table, which
      // would hand the derive an empty day.
      rrResume: wearable != null ? null : rrResume,
      isWearable: wearable != null,
    );
  }

  Future<SleepSessionCandidate> _sleepCandidateForDay(
    String dayId, {
    _PrepareStats? stats,
    bool banked = false,
    // Non-null: this day's windows are cut from one cross-day union; the
    // search window's cut is the first, so the union is loaded here and left
    // in the holder for the day and staged-night windows.
    _UnionHolder? union,
  }) async {
    // A user sleep override is the source of truth — never serve the cached auto
    // candidate, and don't cache the override result (so a later edit / clear is
    // not shadowed by a stale artifact). The auto path keeps its finalized cache.
    final overrideRow = await LocalDb.getSleepOverride(dayId);
    final override = overrideRow == null
        ? null
        : SleepWindowOverride(
            dayId: dayId,
            onsetSec: (overrideRow['onset_ts'] as num).toInt(),
            offsetSec: (overrideRow['offset_ts'] as num).toInt(),
            source: overrideRow['source'] as String? ?? 'manual',
          );

    // The night's confirmed wake (owner rule, see sleep_block_policy.dart),
    // read from the DB so it holds across restarts and headless passes. Null =
    // not final: the night follows the data exactly as it always did. A user
    // window never reaches it (putSleepOverride deletes the row).
    final confirmedWake =
        override == null ? (await LocalDb.wakeConfirmation(dayId))?.atSec : null;

    if (override == null) {
      final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
      // [banked]: the audit's batch reference takes the night the pass banked
      // as it is. Staging again would read the rolling sleep profile as it is
      // NOW (it folded this night in since) and the cardio row cache, so a
      // difference could come from the profile rather than the derivation.
      if (banked || finalized.contains(dayId)) {
        final cached = await LocalDb.sleepSessionCandidate(dayId, kAlgoVersion);
        final raw = cached?['payload_json'];
        if (raw is String && raw.isNotEmpty) {
          try {
            final decoded = jsonDecode(raw);
            final cachedNight = decoded is Map
                ? SleepSessionCandidate.fromJson(
                    decoded.cast<String, dynamic>())
                : null;
            // A device's night is re-staged, not served from the cache: its
            // device may have had its flag turned off or lost the active
            // slot since (rule R6), and then nothing of it may remain.
            if (cachedNight != null &&
                !DerivationEngine._deviceStaged(cachedNight)) {
              return cachedNight;
            }
          } catch (_) {
            // Fall through to rebuild the artifact.
          }
        }
      }
      if (banked) throw StateError('no banked sleep candidate for $dayId');
    }
    final range = _targetDayWindow(dayId,
      overrideOnsetSec: override?.onsetSec,
      overrideOffsetSec: override?.offsetSec);
    // OWNED ROWS ONLY, the same as every other substrate load. This window is
    // candidate-independent, so ownership CAN be resolved before the candidate
    // exists — and it has to be: staging the night off both devices' rows
    // while `napSub`/`sleepSub` score it off one device's is a window found in
    // a night that was never scored.
    final (searchOwnership, _) = await _resolveOwnership(range.$1, range.$2);
    // What the staged-sleep key stands on instead of the samples (see
    // [StagingProvenance]): read BEFORE the rows, so a row landing during the
    // load leaves the key stale, never falsely current.
    final useCache = !debugDisableStagedSleepCache;
    StagingProvenance? provenance;
    var keyMs = 0;
    if (useCache) {
      final t0 = DateTime.now().microsecondsSinceEpoch;
      try {
        final gen = LocalDb.storeGeneration;
        provenance = StagingProvenance(
          fromSec: range.$1,
          toSec: range.$2,
          revs: await LocalDb.inputRevisions(
              range.$1 ~/ kRevBucketSec, range.$2 ~/ kRevBucketSec + 1),
          ownership: searchOwnership,
          wipeEpoch: gen.wipeEpoch,
          openCount: gen.openCount,
        );
      } catch (e) {
        provenance = null;
        _log('[derive] staged-sleep provenance failed for $dayId: $e');
      }
      keyMs += DateTime.now().microsecondsSinceEpoch - t0;
    }
    Substrate? cutSearch;
    if (union != null) {
      // The union holds the search window and the day's (with its nap buffer):
      // one read for both, instead of the night's hours twice.
      final dStart = DerivationEngine._localDayLabelToSec(dayId);
      final dEnd = DerivationEngine._localNextDayLabelToSec(dayId);
      union.load = await _loadUnion(dayId, math.min(range.$1, dStart),
          math.max(range.$2, dEnd - 1 + napBoundaryBufferSec),
          stats: stats);
      cutSearch = (await _cutWindow(union.load, dayId, 'load_search',
              range.$1, range.$2, searchOwnership,
              retain: true, stats: stats))
          ?.sub;
    }
    final searchSub = cutSearch ??
        await _loadSubstrateRange(
          range.$1,
          range.$2,
          dayId: dayId,
          stats: stats,
          label: 'load_search',
          ownership: searchOwnership,
          retain: true,
        );
    // PERSONALIZED STAGER (v42): stage on a WORKER isolate, NOT the main/UI
    // thread. cardioStager reads analytics "ambient" globals — the rolling sleep
    // profile (`cardioUserProfile`) it blends in (bounded ≤0.5) and the
    // observation-recording flag it folds back afterwards. Those globals are
    // ISOLATE-LOCAL (they don't cross `Isolate.run`), which is why v42 originally
    // ran staging on the main isolate — and, per-30-s-epoch over a full night,
    // that landed the trig/Lomb–Scargle load on the UI thread and produced the
    // recurring multi-second freezes → Android ANRs (Crashlytics 0.9.13). We now
    //   (1) read the profile from the DB HERE (the main isolate owns the DB) as
    //       plain JSON,
    //   (2) re-arm the ambient globals and run the staging + EWMA profile fold
    //       INSIDE the worker ([stageSleepCandidateHeavy]), and
    //   (3) return the staged candidate + the raw observation as plain JSON to
    //       persist back on main.
    // The worker isolate dies after dispatch, so the recording flag can't leak
    // into the next day's derivation — no try/finally reset needed.
    final profileJson = await _loadSleepUserProfileJson();
    // Which day_ids have ALREADY been folded into that profile. See
    // [_kFoldedDaysKey] for why this exists and why a legacy profile that
    // lacks it is discarded rather than trusted.
    final foldedDays = SleepProfilePolicy.foldedDays(profileJson);
    // A fold is once per day_id, ever, so it must not take a pass that staged
    // the night while it was still going (the first light pass after 00:15
    // sees an hour of it). The day re-stages until it finalizes, so a pass
    // after the day's window has closed is always still to come.
    final mayFold = SleepProfilePolicy.nightOver(
          dataEdgeSec: await LocalDb.lastDecodedRecTs(),
          dayEndSec: range.$2,
        ) &&
        SleepProfilePolicy.shouldFold(
          alreadyFolded: foldedDays,
          dayId: dayId,
          hasOverride: override != null,
        );
    // The habitual-midsleep prior needs 14 distinct days and this call carries
    // ~36 h of substrate, so without the STORED windows the prior can never
    // fire in production and every night is anchored to the 03:30 cold start.
    // Read on main (the DB lives here) and capture into the worker.
    final priorSleep = await _storedSleepHistory(excludeDay: dayId);
    // The band's own hypnogram, from its own table — never `observation`.
    // Gated inside calendarDays; an override outranks it, so skip the read.
    // Only a device that owns hr1Hz over the night may stage it — or any
    // device, when our own rows never saw that night (an unclaimed night).
    // Never a device whose flag is off (rule R6), nor one that is not the
    // active wearable.
    var vendorNights = override != null
        ? const <VendorNight>[]
        : ownedVendorNights(
            await enabledVendorNights(
                await LocalDb.vendorSleepNights(range.$1, range.$2)),
            searchOwnership[InputSignal.hr1Hz] ?? const [],
            primaryDeviceId: LocalDb.kPrimaryDeviceId,
            ourTsSec: searchSub.tsSec,
          );
    // A day the primary band never saw, staged by us off the active
    // wearable's own records when it keeps no hypnogram (inputs/canonical.dart).
    // "Saw" is the calendar day, the test that hands the day to the wearable
    // ([_prepareTargetDay]): band rows from the previous afternoon, before
    // the ring went on, must not leave the ring's night unstaged.
    final ownNight = override == null &&
            searchSub.slice(DerivationEngine._localDayLabelToSec(dayId), range.$2 + 1).isEmpty
        ? await wearableNight(range.$1, range.$2)
        : null;
    if (ownNight != null) vendorNights = [...vendorNights, ownNight];
    // Cancellable + TIMED OUT. This site previously used a bare `Isolate.run`
    // with no timeout at all, so a hung staging pass never completed its future
    // — `_running` stayed true and `DeriveScheduler._drain` never returned, i.e.
    // all derivation was dead until app restart.
    // Begin/end rather than CalcStatus.run: a wrapping closure would capture
    // `this` into the context the worker closure below shares, and the engine
    // (and its _diag map) cannot be sent to the isolate.
    final stagesStep = CalcStatus.instance.begin('Sleep stages');
    final stagingStartedAt = DateTime.now().millisecondsSinceEpoch;
    // The encoded rows that may overlap this call's window +- 1 h. They go to
    // the worker as they are; it decodes, merges, cuts and prunes them and
    // hands back one chunk to replace them.
    final rowsLo = range.$1 - kCardioRowsSlackSec;
    final rowsHi = range.$2 + kCardioRowsSlackSec;
    final sentChunks = [
      for (final c in _cardioRowChunks)
        if (c.overlaps(rowsLo, rowsHi)) c,
    ];
    final input = SleepStagingInput(
      dayId: dayId,
      searchSub: searchSub,
      override: override,
      priorSleep: priorSleep,
      confirmedWakeSec: confirmedWake,
      vendorNights: vendorNights,
      profileJson: profileJson,
      mayFold: mayFold,
      rowChunks: [for (final c in sentChunks) c.json],
      rowsLoSec: rowsLo,
      rowsHiSec: rowsHi,
      nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    final inputs = DerivationEngine._workerInputs();
    // Reuse the staged night when this exact input was staged at this algo
    // version already (a rescan after a heavy pass). The key is built here from
    // the very objects handed to the worker.
    (int, int)? digest;
    StagedSleepEntry? hit;
    final keyStartedAt = DateTime.now().microsecondsSinceEpoch;
    if (useCache && provenance != null) {
      // A key that cannot be computed only costs the reuse: stage as before,
      // and the Sleep stages status still ends on the staging path (4.3).
      try {
        digest = stagingInputDigest(inputs, input,
            zoneKey: DerivationEngine._zoneKey(), provenance: provenance);
        hit = _stagedSleep.lookup(dayId, kAlgoVersion, digest,
            mayFold: mayFold);
      } catch (e) {
        digest = null;
        hit = null;
        _log('[derive] staged-sleep key failed for $dayId: $e');
      }
    }
    if (useCache) {
      perf.addStage('stage_candidate_key',
          (keyMs + DateTime.now().microsecondsSinceEpoch - keyStartedAt) ~/
              1000);
    }
    final String candidateJson;
    final String? observationJson;
    if (hit != null) {
      candidateJson = hit.candidateJson;
      // A caller that must not fold gets none, as a fresh staging gives.
      observationJson = mayFold ? hit.observationJson : null;
      perf.addCount('staged_sleep_reuse', 1);
      CalcStatus.instance.end(stagesStep);
      perf.addStage('stage_candidate',
          DateTime.now().millisecondsSinceEpoch - stagingStartedAt);
    } else {
      final SleepStagingResult staged;
      try {
        staged = await DerivationEngine._runIsolateCancellable(
          () => stageSleepCandidateHeavy(inputs, input),
          _perDayTimeout,
          label: 'sleep-staging $dayId',
        );
      } finally {
        CalcStatus.instance.end(stagesStep);
        perf.addStage('stage_candidate',
            DateTime.now().millisecondsSinceEpoch - stagingStartedAt);
      }
      candidateJson = staged.candidateJson;
      observationJson = staged.observationJson;
      // Only a staging that returned is kept; a throw (timeout, cancel, a bad
      // night) left here before this line.
      if (digest != null) {
        _stagedSleep.store(
            dayId,
            StagedSleepEntry(
              algoVersion: kAlgoVersion,
              digestA: digest.$1,
              digestB: digest.$2,
              stagedWithFold: mayFold,
              candidateJson: candidateJson,
              observationJson: observationJson,
            ),
            debugStagedSleepCacheMaxDays);
      }
      // The returned chunk holds everything the sent ones did (less what aged
      // out), so it replaces them; only plain ints are compared here.
      _cardioRowChunks.removeWhere(sentChunks.contains);
      final rowsOut = staged.rowsJson;
      if (rowsOut != null) {
        _cardioRowChunks
            .add(CardioRowsChunk(rowsOut, staged.rowsLoSec, staged.rowsHiSec));
      }
      final keepFrom = input.nowSec - kCardioRowsKeepSec;
      _cardioRowChunks.removeWhere((c) => c.hiSec < keepFrom);
      perf.addCount('cardio_rows_hit', staged.rowHits);
      perf.addCount('cardio_rows_miss', staged.rowMisses);
    }
    final candidate = SleepSessionCandidate.fromJson(
        (jsonDecode(candidateJson) as Map).cast<String, dynamic>());
    for (final f in candidate.flags) {
      if (f.startsWith('VENDOR_SLEEP_IGNORED:')) _log('derive $dayId: $f');
    }
    if (override == null) {
      // NEVER RE-STAGE A NIGHT SHORTER THAN THE ONE ALREADY BANKED (#242).
      //
      // A day re-stages on every pass for its first 48 h, and the substrate it
      // stages over does not only grow: `pruneDecodedBeforeRecTs` runs once the
      // covering day is derived, so a later pass can look at the same night
      // through less data and produce a shorter one — which then REPLACED the
      // good candidate, and the day rebuilt from it. That is the reported "it
      // got fixed, then a few syncs later it went back", and it is a write-path
      // defect, not a staging one (a mid-night wake bridges and sums correctly).
      //
      // The guard belongs HERE rather than on the day result: the candidate is
      // upstream of the sleep block, the hypnogram AND every sleep scalar, so
      // keeping the richer one keeps the whole day internally consistent.
      // Swapping a richer sleep block into a thinner day's bundle would pair
      // last pass's night with this pass's stage minutes.
      //
      // Keyed at this algo version, so a bump still re-stages from scratch —
      // that is what a bump is for. An override never reaches this branch, so a
      // user shortening their own night is untouched.
      //
      // NOT for a confirmed night: its end is an observed event, so a banked
      // candidate that ran past it (staged before the confirmation arrived) is
      // the one that is wrong, and the confirmed one replaces it. Passes after
      // that re-stage the same truncated night, so it cannot move again.
      final stored = confirmedWake != null
          ? null
          : await LocalDb.sleepSessionCandidate(dayId, kAlgoVersion);
      final storedJson = stored?['payload_json'];
      if (storedJson is String && storedJson.isNotEmpty) {
        try {
          final prev = SleepSessionCandidate.fromJson(
              (jsonDecode(storedJson) as Map).cast<String, dynamic>());
          // A banked device night is kept over a fresh pass only while the
          // same device stages this one: otherwise its device may no longer
          // stage here (flag off, or another wearable made active; rule R6).
          // The same device's fresh night can be shorter only because its
          // HR rows from the evening before were pruned.
          final sourceGone = DerivationEngine._deviceStaged(prev) &&
              (prev.deviceId == null || prev.deviceId != candidate.deviceId);
          if (!sourceGone && DerivationEngine.keepsBankedNight(prev, candidate)) {
            _log('derive $dayId: kept the banked night '
                '(${DerivationEngine._tstSec(prev)} s) over this pass\'s '
                '${DerivationEngine._tstSec(candidate)} s — less substrate, not a shorter night');
            return prev;
          }
        } catch (_) {
          // Undecodable stored candidate — the fresh one is strictly better.
        }
      }
      await LocalDb.putSleepSessionCandidate(
        dayId: dayId,
        algoVersion: kAlgoVersion,
        payloadJson: candidateJson,
      );
      if (observationJson != null) {
        // BEST-EFFORT, and deliberately isolated from the day's success path.
        // The fold is bookkeeping; the day's real result is already persisted
        // above. `updateBaseline` takes an exclusive SQLite write lock, and the
        // whole point of this change is that two derivation isolates contend
        // for it — so SQLITE_BUSY here is an EXPECTED outcome, not an
        // exceptional one. Letting it escape would hit processDay's broad
        // catch, which calls `_markDaySkipped` and increments `failures`,
        // throwing away a fully computed day (and holding the timezone) over a
        // bookkeeping write.
        //
        // KNOWN LIMITATION — a swallowed failure here is PERMANENT for this
        // day, not retried. Once the day finalizes, the cached-candidate
        // short-circuit at the top of this method returns before staging runs,
        // so `observationJson` is never regenerated and the fold never happens.
        // Same for a day whose override is later removed if it already has a
        // cached candidate from before the override.
        //
        // Accepted deliberately rather than fixed: the profile is an EWMA with
        // a ~14-night horizon and a hard 0.5 blend cap, so one missing night is
        // a small perturbation, whereas a retry path needs durable pending
        // state and a way to distinguish "failed, retry" from "declined
        // permanently" (a <120-epoch nap never folds, and would otherwise
        // bypass the candidate cache and re-stage on every sweep forever).
        // If the fold ever stops being best-effort, that state machine is the
        // thing to build — do not simply bypass the cache.
        try {
          await _foldObservationIntoProfile(dayId, observationJson);
        } catch (e) {
          _log('sleep profile fold skipped for $dayId (day result kept, '
              'this night will not contribute to the profile): $e');
        }
      }
    }
    return candidate;
  }

  /// Fold one night's observation into the shared profile, serialised against
  /// every other day in the sweep.
  ///
  /// The profile is RE-READ inside the lock and [SleepProfilePolicy.shouldFold]
  /// re-checked, because the value this day read before staging is stale by
  /// definition — a concurrently-derived day may have folded since. Skipping
  /// that re-check is what turns a read-modify-write race into a lost fold plus
  /// a lost day_id, and the day then re-folds forever.
  Future<void> _foldObservationIntoProfile(
      String dayId, String observationJson) async {
    final Map<String, dynamic> o;
    try {
      o = (jsonDecode(observationJson) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final observed = DerivationEngine._observationFromJson(o);
    // The whole read-modify-write happens inside ONE exclusive DB transaction.
    // A Dart mutex cannot do this job: derivation can run from MORE THAN ONE
    // ISOLATE (Android headless sync wakes construct their own DerivationEngine
    // off the main one), and a `static` lock has one copy per isolate — so a
    // background heavy pass and a foreground sweep would each read the same
    // profile, fold, and clobber the other, losing both the fold and its
    // day_id from folded_days. SQLite's write lock is cross-connection and
    // therefore cross-isolate.
    await LocalDb.updateBaseline('sleep_user_profile', (current) {
      // Re-derive freshness INSIDE the transaction: the value this day read
      // before staging is stale by definition, another lane may have folded
      // since. Returning null leaves the row untouched.
      final usable = SleepProfilePolicy.usableProfileJson(current);
      final freshDays = SleepProfilePolicy.foldedDays(usable);
      if (!SleepProfilePolicy.shouldFold(
          alreadyFolded: freshDays, dayId: dayId, hasOverride: false)) {
        return null;
      }
      final ana.SleepUserProfile base;
      try {
        base = usable == null
            ? const ana.SleepUserProfile()
            : ana.SleepUserProfile.fromJson(
                (jsonDecode(usable) as Map).cast<String, dynamic>());
      } catch (_) {
        return null; // unreadable — leave it for the cold-start path
      }
      return jsonEncode({
        ...SleepProfilePolicy.withFoldedDays(
            base.fold(observed).toJson(), freshDays, dayId),
        // The observation itself, so the night can be taken back out if the
        // user later blanks it (see [_forgetBlankedNightsInSleepProfile]).
        SleepProfilePolicy.foldedObsKey: SleepProfilePolicy.withObservation(
            SleepProfilePolicy.foldedObservations(usable), dayId, o),
      });
    });
  }

  /// [from, to] of one day as a single load: the cross-day union (see
  /// [_unions]). What the last days of this pass already hold of it is cut out
  /// of them; only the stretches no one holds are read from `decoded_onehz`
  /// (booked as `load_day`), and the pieces are joined as one load would have
  /// built them. Null when it cannot be built exactly; the caller then loads
  /// its windows one by one.
  Future<RetainedLoad?> _loadUnion(String dayId, int from, int to,
      {_PrepareStats? stats}) async {
    if (to < from) return null;
    final previous = _unionTurn;
    final turnDone = Completer<void>();
    _unionTurn = turnDone.future;
    try {
      await previous;
      final startedAt = DateTime.now().millisecondsSinceEpoch;
      final (resolved, _) = await _resolveOwnership(from, to);
      final ownership = {
        for (final sig in kExclusiveOwnershipSignals)
          sig: resolved[sig] ?? const <OwnedSpan>[],
      };
      final multiOwner = ownersOf(ownership).length > 1;
      final generation = LocalDb.storeGeneration;
      // Before any row, here or in a part: a row landing during the load
      // leaves the next check stale, never falsely current.
      final revs = await LocalDb.inputRevisions(
          from ~/ kRevBucketSec, to ~/ kRevBucketSec + 1);
      final cutStartedAt = DateTime.now().millisecondsSinceEpoch;
      final stretches = usableStretches(_unions,
          from: from,
          to: to,
          revs: revs,
          ownership: ownership,
          multiOwner: multiOwner,
          generation: generation);
      // The cuts run in a worker (the arrays are read there); the bases are
      // sent once, however many stretches each supplies.
      final bases = <RetainedLoad>[];
      for (final st in stretches) {
        if (!bases.any((x) => identical(x, st.base))) bases.add(st.base);
      }
      final borrowed = <RetainedLoad>[];
      if (stretches.isNotEmpty) {
        final cut = (await runUnionCut(UnionCutInput(
          kind: UnionCutKind.borrow,
          loads: bases,
          ownership: ownership,
          multiOwner: multiOwner,
          stretches: [
            for (final st in stretches)
              (
                base: bases.indexWhere((x) => identical(x, st.base)),
                a: st.a,
                b: st.b
              ),
          ],
        )))
            .loads;
        for (final w in cut) {
          if (w != null) borrowed.add(w);
        }
      }
      var cutMs = DateTime.now().millisecondsSinceEpoch - cutStartedAt;
      Future<RetainedLoad?> read(int a, int b) async {
        final got = <RetainedLoad>[];
        await _loadSubstrateRange(a, b,
            dayId: dayId,
            stats: stats,
            label: 'load_day',
            ownership: ownership,
            runOut: got);
        return got.isEmpty ? null : got.single;
      }

      final parts = <RetainedLoad>[];
      var pos = from;
      var borrowedRows = 0;
      for (final part in borrowed) {
        if (part.from > pos) {
          final gap = await read(pos, part.from - 1);
          if (gap == null) return null;
          parts.add(gap);
        }
        parts.add(part);
        borrowedRows += part.samples;
        pos = part.to + 1;
      }
      if (pos <= to) {
        final gap = await read(pos, to);
        if (gap == null) return null;
        parts.add(gap);
      }
      final joinStartedAt = DateTime.now().millisecondsSinceEpoch;
      var union = (await runUnionCut(UnionCutInput(
        kind: UnionCutKind.join,
        loads: parts,
        ownership: ownership,
        multiOwner: multiOwner,
        revs: revs,
        generation: generation,
      )))
          .loads
          .single;
      cutMs += DateTime.now().millisecondsSinceEpoch - joinStartedAt;
      if (union == null) {
        // The parts do not make one load (a different skin-temperature unit in
        // each): read the whole range, as a window load would.
        borrowedRows = 0;
        union = await read(from, to);
        if (union == null) return null;
      }
      perf.addStage('union_cut', cutMs);
      perf.addCount('union_borrowed_rows', borrowedRows);
      _unions.add(union);
      while (_unions.length > 2) {
        _unions.removeAt(0);
      }
      _noteHeldRows(union.samples);
      perf.addStage(
          'union_load', DateTime.now().millisecondsSinceEpoch - startedAt);
      return union;
    } finally {
      // Whatever happened, the next day gets its turn (4.3).
      turnDone.complete();
    }
  }

  /// The window [a, b] of [union] as the load `label` would have returned
  /// (`load_search`, `load_day`, `load_sleep`), or null when the union cannot
  /// stand in for it and the caller loads it from the database. [retain]
  /// keeps it for the next pass of the day, the way the load would have.
  Future<RetainedLoad?> _cutWindow(
    RetainedLoad? union,
    String dayId,
    String label,
    int a,
    int b,
    Map<InputSignal, List<OwnedSpan>> ownership, {
    bool retain = false,
    _PrepareStats? stats,
  }) async {
    if (union == null || b < a) return null;
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final window = (await runUnionCut(UnionCutInput(
      kind: UnionCutKind.window,
      loads: [union],
      ownership: ownership,
      multiOwner: ownersOf(ownership).length > 1,
      a: a,
      b: b,
    )))
        .loads
        .single;
    perf.addStage(label, DateTime.now().millisecondsSinceEpoch - startedAt);
    if (window == null) {
      perf.addCount('union_refused_$label', 1);
      return null;
    }
    perf.addCount('union_cut_rows_$label', window.samples);
    if (retain && !_lowMemory && window.samples > 0) {
      final zone = DerivationEngine._zoneKey();
      if (_retainedZone != zone) {
        if (_retained.isNotEmpty && stats != null) stats.fullReload = true;
        _retained.clear();
        _retainedZone = zone;
      }
      _retained[DerivationEngine._retainedKey(dayId, label)] = window;
      _boundRetained();
    }
    return window;
  }

  Future<Substrate> _loadSubstrateRange(
    int fromRecTs,
    int toRecTs, {
    required String dayId,
    _PrepareStats? stats,
    // Which of a day's loads this is, for the `[perf]` stage line only.
    String label = 'load',
    // M5: the resolved ownership spans for this call's window, keyed by
    // anchor signal. Every production caller supplies them (see
    // [_resolveOwnership]); the empty default is unfiltered, which is what a
    // single-device install resolves to anyway and what the direct-load tests
    // pass.
    Map<InputSignal, List<OwnedSpan>> ownership = const {},
    // Beats are read only from this second on; the seconds before it that have
    // beats are still given to the substrate (as slots with no beat), so its 1 Hz
    // axis is the one a full load builds. Null reads every beat.
    int? rrFromRecTs,
    // Keep this load for the next pass of the same day (see [_retained]) and
    // start from the one kept last time when nothing behind its tail has
    // changed. [label] names it. Null: always a full read, nothing kept.
    bool retain = false,
    // Hand the load over as a [RetainedLoad] too (not kept in [_retained]):
    // the cross-day union reads its gaps this way and joins them to the parts
    // it already holds. Added once, when the load finishes with rows' facts.
    List<RetainedLoad>? runOut,
  }) async {
    if (toRecTs < fromRecTs) return Substrate.empty;
    final loadStartedAt = DateTime.now().millisecondsSinceEpoch;
    // The retained load is judged BEFORE any row is read (and its revisions
    // with it), so a row landing mid-load leaves the next pass's check stale
    // rather than falsely current.
    final retainKey = retain && !_lowMemory ? DerivationEngine._retainedKey(dayId, label) : null;
    RetainedLoad? prior;
    int? cut;
    var keepBeats = true;
    Map<int, int>? revsNow;
    var multiOwner = false;
    final generation = LocalDb.storeGeneration;
    if (retainKey != null || runOut != null) {
      // A move to another zone moves every day boundary: nothing kept for the
      // days of the old zone is a window of the new one.
      if (retainKey != null) {
        final zone = DerivationEngine._zoneKey();
        if (_retainedZone != zone) {
          if (_retained.isNotEmpty && stats != null) stats.fullReload = true;
          _retained.clear();
          _retainedZone = zone;
        }
      }
      revsNow = await LocalDb.inputRevisions(
          fromRecTs ~/ kRevBucketSec, toRecTs ~/ kRevBucketSec + 1);
      multiOwner = ownersOf(ownership).length > 1;
    }
    if (retainKey != null) {
      prior = _retained.remove(retainKey);
      if (prior != null) {
        final r = prior.reuse(
          from: fromRecTs,
          to: toRecTs,
          rrFrom: rrFromRecTs,
          revs: revsNow!,
          ownership: ownership,
          multiOwner: multiOwner,
          generation: generation,
        );
        cut = r?.cut;
        keepBeats = r?.keepBeats ?? true;
        if (r == null && stats != null) stats.fullReload = true;
      }
    }
    // Rows are read from here; the part of the range before it is [prior]'s.
    final readFrom = cut == null || cut < fromRecTs ? fromRecTs : cut;
    final priorCut = prior?.cut;
    Map<String, dynamic>? retainExtras;
    // The rec_ts of the last decoded_onehz row read, ownership or not.
    int? lastRowRecTs;
    var loadedRows = 0;
    var pagerPages = 0;
    var pagerBytes = 0;
    var rrRowsRead = 0;
    var rrSlotRows = 0;
    // The `decoded_rr` rows of [from, to] for the substrate: every beat, or for
    // the part below [rrFromRecTs] only which seconds have beats.
    Future<List<Map<String, dynamic>>> readRr(int from, int to) async {
      final low = rrFromRecTs;
      final out = <Map<String, dynamic>>[];
      if (low != null && from < low) {
        final slots = await LocalDb.decodedRrSecondsByRecTsRange(
          fromRecTs: from,
          toRecTs: math.min(to, low - 1),
          onlyBeatOnly: ownersOf(ownership).length <= 1,
        );
        rrSlotRows += slots.length;
        for (final r in slots) {
          out.add({'rec_ts': r['rec_ts'], 'device_id': r['device_id']});
        }
        from = low;
      }
      if (from <= to) {
        final rows = await LocalDb.decodedRrByRecTsRange(
          fromRecTs: from,
          toRecTs: to,
        );
        rrRowsRead += rows.length;
        out.addAll(rows);
      }
      return out;
    }

    final port = ReceivePort();
    // onError/onExit are LOAD-BEARING. Without them, an uncaught throw inside
    // the worker (a malformed SQLite row reaching one of the numeric reads in
    // its 'page' handler — the worker only ever reported errors from its
    // 'finish' branch) killed the isolate silently, and this side awaited
    // `result.future` FOREVER with `_running == true`: DeriveScheduler._drain
    // never returned and ALL derivation was dead until app restart. Now a
    // worker death fails the future, and the timeout below bounds the wait
    // even if no signal arrives at all.
    final prepareDispatch =
        WorkerAudit.dispatched(Dispatcher.spawn, 'derivation prepare');
    final spawnStartedAt = DateTime.now().millisecondsSinceEpoch;
    final isolate = await Isolate.spawn(
      derivationPrepareWorker,
      port.sendPort,
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    perf.addCount('worker_spawns_$label', 1);
    final ready = Completer<SendPort>();
    final result = Completer<Substrate>();
    // A failure completes BOTH completers, but we may bail out via `ready` and
    // never await `result` — register a listener so that error is never an
    // unobserved async error. (The real error still propagates via `ready`.)
    unawaited(result.future.catchError((_) => Substrate.empty));
    late final StreamSubscription<dynamic> sub;
    void fail(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
      if (!result.isCompleted) result.completeError(error);
    }

    sub = port.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is Map && message['type'] == 'result') {
        final kind = message['kind']?.toString();
        if (kind == 'substrate') {
          final extras = message['retain'];
          if (extras is Map) retainExtras = extras.cast<String, dynamic>();
          final payload = ((message['payload'] as Map?) ?? const {})
              .cast<String, dynamic>();
          if (!result.isCompleted) {
            // P2.0a: what the UI isolate pays to adopt the worker's map.
            final adoptStartedAt = DateTime.now().millisecondsSinceEpoch;
            final adopted = Substrate.fromTransfer(payload);
            perf.addStage('substrate_adopt_$label',
                DateTime.now().millisecondsSinceEpoch - adoptStartedAt);
            perf.addCount('substrate_adopt_samples_$label', adopted.length);
            result.complete(adopted);
          }
        }
        return;
      }
      if (message is Map && message['type'] == 'error') {
        fail(Exception('prepare worker error: ${message['error']}'));
        return;
      }
      if (message is List) {
        // `onError` wire format ([error, stackTrace]) — an uncaught throw.
        fail(Exception('prepare worker crashed: '
            '${message.isNotEmpty ? message.first : "no detail"}'));
        return;
      }
      if (message == null) {
        // `onExit` — the isolate ended without ever sending a result.
        fail(StateError('prepare worker exited without a result'));
      }
    });
    // M5: the resolved spans for this call's window, one list per anchor
    // signal. Read once, outside the loop — `ownership` never changes while
    // this range loads.
    final rrOwnedSpans = ownership[InputSignal.rrIntervals] ?? const <OwnedSpan>[];
    bool owned(List<OwnedSpan> spans, Map<String, dynamic> r) {
      if (spans.isEmpty) return true;
      final owner = spanAt(spans, (r['rec_ts'] as num).toInt())?.deviceId;
      if (owner == null) return true;
      return owner == (r['device_id'] as String? ?? LocalDb.kPrimaryDeviceId);
    }
    try {
      final worker = await ready.future;
      perf.addStage('worker_spawn_$label',
          DateTime.now().millisecondsSinceEpoch - spawnStartedAt);
      // Test-only (null in production): hand the worker the audit port so it
      // reports which registered entry ran, from inside its own isolate.
      final auditPort = WorkerAudit.auditPort;
      if (auditPort != null) {
        worker.send({
          'type': 'audit',
          'port': auditPort,
          'dispatch': prepareDispatch,
        });
      }
      worker.send({
        'type': 'config',
        'mode': 'substrate',
        if (retainKey != null || runOut != null) 'retain': true,
      });
      if (prior != null && cut != null) {
        worker.send(prior.seedMessage(cut, rrFromRecTs, keepBeats));
        perf.addCount('substrate_reused_rows_$label', prior.samples);
        if (!keepBeats) {
          // The seed holds fewer beats than this load wants: read the ones of
          // its seconds again, as a full load would (in slices, like its pages).
          final lo = math.max(fromRecTs, rrFromRecTs ?? fromRecTs);
          final hi = math.min(cut - 1, toRecTs);
          for (var a = lo; a <= hi; a += DerivationEngine._rrPrefixSliceSec) {
            final rows = await LocalDb.decodedRrByRecTsRange(
              fromRecTs: a,
              toRecTs: math.min(a + DerivationEngine._rrPrefixSliceSec - 1, hi),
            );
            rrRowsRead += rows.length;
            final kept = [
              for (final r in rows)
                if (owned(rrOwnedSpans, r)) r,
            ];
            if (kept.isNotEmpty) worker.send({'type': 'rr_prefix', 'rr': kept});
          }
        }
      }
      int? afterRecTs;
      int? afterCursor;
      var rangePages = 0;
      var rangeRows = 0;
      // Low water mark for the BEAT read, which is NOT the same window as the
      // frame read. Paging is driven by `decoded_onehz`, but a beat can exist
      // for a second with no 1 Hz row at all (gen4 R10-lite is hr-only and
      // stays out of that table — see db.dart `_queueDecodedOneHz`). Clamping
      // each page's beat read to that page's own first/last frame second
      // dropped every such beat that fell before the day's first frame, after
      // its last, or in the seam between two pages. Each page instead reads
      // beats from wherever the previous page stopped, and the tail is swept
      // after the loop — so the day's beat window is covered exactly once.
      var rrFrom = readFrom;
      // A contended second's OTHER row can land on the far side of a page
      // boundary — `decodedOneHzBatchByRecTsRange`'s LIMIT is applied after
      // ordering by rec_ts, not aligned to rec_ts groups. Composing a page
      // whose trailing rec_ts group is only half-present would keep the
      // hr1Hz-owner's own accel/ppg/skin-temp value for that ONE boundary
      // second instead of splicing in the other device's, so the group's
      // rows that arrived this round are held here until the rest of the
      // group is seen (or the range ends). Rare in practice — it takes a
      // page-sized batch of rows to land exactly mid-group — but the fix is
      // cheap and the alternative is a silent one-second attribution miss.
      var carry = const <Map<String, dynamic>>[];
      while (true) {
        final decodedRows = await LocalDb.decodedOneHzBatchByRecTsRange(
          limit: DerivationEngine._rawDecodeBatchSize,
          fromRecTs: readFrom,
          toRecTs: toRecTs,
          afterRecTs: afterRecTs,
          afterCounter: afterCursor,
        );
        if (decodedRows.isNotEmpty) {
          _trackPrepareBatch(decodedRows.length);
          rangePages += 1;
          rangeRows += decodedRows.length;
          loadedRows = rangeRows;
          pagerPages += 1;
          // The byte sum walks every cell: only when somebody reads it.
          if (perf.enabled) pagerBytes += rowsByteEstimate(decodedRows);
          if (stats != null) {
            stats.pages += 1;
            stats.rows += decodedRows.length;
          }
          _enforcePrepareBudget(
            dayId: dayId,
            fromRecTs: fromRecTs,
            toRecTs: toRecTs,
            rangePages: rangePages,
            rangeRows: rangeRows,
          );
          // THE CURSOR ADVANCES OFF THE UNFILTERED PAGE, ALWAYS. `afterRecTs`/
          // `afterCursor` and the `decodedRows.length < _rawDecodeBatchSize`
          // break are driven by `decodedRows` alone — never by `carry` or the
          // filtered `frames`/`rrRows` sent to the worker. Filtering first
          // would stall the keyset cursor on a page whose surviving rows are
          // fewer than the batch size and silently truncate the day.
          final isFinalPage = decodedRows.length < DerivationEngine._rawDecodeBatchSize;
          final combined =
              carry.isEmpty ? decodedRows : [...carry, ...decodedRows];
          final splitIdx = trailingRecTsGroupStart(combined);
          // splitIdx == 0 means the WHOLE page-sized batch shares one
          // rec_ts — a pathological amount of contention no real pairing
          // produces. Send it as-is rather than risk carrying forever.
          final toSend =
              (isFinalPage || splitIdx == 0) ? combined : combined.sublist(0, splitIdx);
          carry = (isFinalPage || splitIdx == 0)
              ? const <Map<String, dynamic>>[]
              : combined.sublist(splitIdx);
          if (toSend.isNotEmpty) {
            // decoded_rr carries the same rec_ts as its decoded_onehz parent,
            // so [rrFrom, lastSentRecTs] is a range read on decoded_rr's
            // rec_ts index — no counter span (which broke across the strap's
            // reboot reset).
            final lastSentRecTs = (toSend.last['rec_ts'] as num).toInt();
            final rawRrRows = await readRr(rrFrom, lastSentRecTs);
            rrFrom = lastSentRecTs + 1;
            final frames = composeOneHzFrames(toSend, ownership);
            final rrRows = [
              for (final r in rawRrRows)
                if (owned(rrOwnedSpans, r)) r,
            ];
            worker.send({'type': 'page', 'frames': frames, 'rr': rrRows});
          }
          final last = decodedRows.last;
          afterRecTs = (last['rec_ts'] as num?)?.toInt() ?? afterRecTs;
          lastRowRecTs = afterRecTs;
          afterCursor = (last['counter'] as num?)?.toInt() ?? afterCursor;
          if (isFinalPage) break;
          continue;
        }
        break;
      }
      // A page landed EXACTLY on `_rawDecodeBatchSize` as the true last page
      // (the next fetch came back empty) — its trailing group is still held.
      if (carry.isNotEmpty) {
        final lastRecTs = (carry.last['rec_ts'] as num).toInt();
        final rawRrRows = await readRr(rrFrom, lastRecTs);
        rrFrom = lastRecTs + 1;
        final frames = composeOneHzFrames(carry, ownership);
        final rrRows = [
          for (final r in rawRrRows)
            if (owned(rrOwnedSpans, r)) r,
        ];
        worker.send({'type': 'page', 'frames': frames, 'rr': rrRows});
      }
      // The tail: beats after the last frame second (or, on a range with no
      // frames at all, the whole range). Usually zero rows and one indexed
      // lookup; when it is not, these are seconds the band recorded and only
      // reported beats for.
      if (rrFrom <= toRecTs) {
        final rawTailRr = await readRr(rrFrom, toRecTs);
        final tailRr = [
          for (final r in rawTailRr)
            if (owned(rrOwnedSpans, r)) r,
        ];
        if (tailRr.isNotEmpty) {
          worker.send({
            'type': 'page',
            'frames': const <Map<String, dynamic>>[],
            'rr': tailRr,
          });
        }
      }
      worker.send(const {'type': 'finish'});
      // BOUNDED. `result.future` had no timeout at all, so any path that left
      // the worker unable to answer hung this call — and with it the whole
      // engine — permanently.
      final loaded = await result.future.timeout(
        _perDayTimeout,
        onTimeout: () => throw TimeoutException(
          'substrate prepare for $dayId timed out after $_perDayTimeout',
        ),
      );
      final extras = retainExtras;
      // The newest row this load read, or the old cut when it read none (the
      // retained load held every row there is). No row at all: nothing to cut by.
      final newCut = lastRowRecTs != null
          ? (lastRowRecTs ~/ kRevBucketSec) * kRevBucketSec
          : priorCut;
      if ((retainKey != null || runOut != null) && extras != null) {
        // A range with no row at all still proves it had none (as of [revsNow]);
        // that is only worth keeping for a union part, never as a warm load.
        final cutAt = newCut ?? (fromRecTs ~/ kRevBucketSec) * kRevBucketSec;
        final run = RetainedLoad(
          from: fromRecTs,
          to: toRecTs,
          rrFrom: rrFromRecTs,
          revs: revsNow!,
          ownership: {
            for (final sig in kExclusiveOwnershipSignals)
              sig: ownership[sig] ?? const <OwnedSpan>[],
          },
          multiOwner: multiOwner,
          generation: generation,
          cut: cutAt,
          sub: loaded,
          rrStart: extras['rr_start'] as Int32List,
          rrTsRaw: extras['rr_ts_raw'] as Float64List,
          meta: [
            for (final w in (extras['meta'] as List))
              BucketMeta.fromWire((w as List).cast<Object?>()),
          ],
        );
        if (retainKey != null && newCut != null && !_lowMemory) {
          _retained[retainKey] = run;
          _boundRetained();
        }
        runOut?.add(run);
      }
      _noteHeldRows(loaded.length);
      return loaded;
    } finally {
      // ALWAYS tear down: on success, on error, and on timeout. The isolate is
      // killed rather than abandoned so a wedged worker can never outlive the
      // call that spawned it.
      await sub.cancel();
      port.close();
      isolate.kill(priority: Isolate.immediate);
      perf.addStage(label, DateTime.now().millisecondsSinceEpoch - loadStartedAt);
      perf.addCount('rows_$label', loadedRows);
      perf.addCount('pager_pages_$label', pagerPages);
      perf.addCount('pager_rows_$label', loadedRows);
      perf.addCount('pager_bytes_$label', pagerBytes);
      // The day's own beats are `rr_rows_read`; the night's loads read theirs
      // under their own names (the night is not streamed).
      perf.addCount(label == 'load_day' ? 'rr_rows_read' : 'rr_rows_$label',
          rrRowsRead);
      if (rrSlotRows > 0) perf.addCount('rr_slot_rows_$label', rrSlotRows);
    }
  }

  Future<_DeriveScope> _deriveScope({
    required bool heavy,
    required bool force,
  }) async {
    final rawByDay = await LocalDb.decodedRecTsMaxByDay();
    // Days only the active wearable saw (inputs/canonical.dart) are up for
    // derivation too. No wearable chosen and flagged on = unchanged.
    final wearable = await activeWearable();
    if (wearable != null) {
      for (final MapEntry(:key, :value)
          in (await wearableRecTsMaxByDay(wearable)).entries) {
        rawByDay.putIfAbsent(key, () => value);
      }
    }
    if (rawByDay.isEmpty) {
      return const _DeriveScope(
        fullHistory: true,
        targetDays: [],
        reason: 'empty',
      );
    }
    final rawDays = rawByDay.keys.toList()..sort();
    if (force) {
      // A full restage resolves any held-back timezone-adjacent days on its
      // own, so it clears the guard — but only once it has actually RUN. See
      // the reset at the end of run(): clearing it here, at scope-selection
      // time, meant an interrupted restage still dropped the hold.
      return _scopeForDays(
        rawDays,
        reason: 'full-history',
        fullHistory: true,
        rawDays: rawDays,
      );
    }

    // A settled day (declined, raw unchanged) is done for selection.
    final finalized = await _finalizedOrSettled();
    var pending = [
      for (final day in rawDays)
        if (!finalized.contains(day)) day,
    ];

    // decodedRecTsMaxByDay() buckets by the CURRENT device timezone, but
    // `finalized` was frozen under whatever timezone was active when each day
    // was derived. A real cross-timezone trip (not an ~1h DST shift) can make
    // the SAME rec_ts rows relabel to a day adjacent to one already finalized
    // — looking like a brand-new "pending" night that's really a duplicate, or
    // silently landing on an already-finalized day_id and looking lost. Once
    // that's detected, hold off auto-deriving anything adjacent to finalized
    // data until "Re-analyze data" (full restage) resolves it properly.
    if (await _timezoneTravelSuspected()) {
      final adjacent = <String>{
        for (final day in finalized) ...DerivationEngine._adjacentDayIds(day),
      };
      final held = pending.where(adjacent.contains).toList();
      if (held.isNotEmpty) {
        _log(
          'derive: possible timezone change — holding ${held.length} day(s) '
          'adjacent to finalized data until Re-analyze data runs: $held',
        );
        pending = pending.where((d) => !adjacent.contains(d)).toList();
        if (pending.isEmpty) {
          // Everything pending was held. Falling through to the
          // 'latest-finalized-check' below would re-derive rawDays.last —
          // one of the very days just held — defeating the hold entirely.
          return _DeriveScope(
            fullHistory: false,
            targetDays: const [],
            reason: 'tz-travel-hold',
            rawDays: rawDays,
          );
        }
      }
    }
    if (pending.isEmpty) {
      return _scopeForDays(
        [rawDays.last],
        reason: 'latest-finalized-check',
        rawDays: rawDays,
      );
    }

    if (heavy) {
      return _scopeForDays(pending, reason: 'pending-span', rawDays: rawDays);
    }

    final light = selectLightDeriveDays(
      rawDays: rawByDay.keys.toSet(),
      pendingDays: pending,
      today: LocalDb.localDayLabelNow(),
    );
    return _scopeForDays(light.days, reason: light.reason, rawDays: rawDays);
  }
}
