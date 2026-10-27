part of '../derivation_engine.dart';

extension _EngineDayCompute on DerivationEngine {
  /// The coverage verdict for [dayId]: null when no coverage was recorded for
  /// its stored result (the cursor rule applies); otherwise the recorded
  /// baseline and a description of what is now missing (null: nothing).
  Future<({({int own, int? prev}) baseline, String? loss})?> _coverageLoss(
      String dayId) async {
    final baseline = await LocalDb.derivedCoverage(dayId);
    if (baseline == null) return null;
    final prevId = DerivationEngine._adjacentDayIds(dayId).first;
    final fps = await LocalDb.decodedDayFingerprints({dayId, prevId});
    final own = DerivedFingerprint.rowCount(fps[dayId]) ?? 0;
    final prev = DerivedFingerprint.rowCount(fps[prevId]) ?? 0;
    final lost = <String>[
      if (own < baseline.own) '$dayId has $own rows, was derived from ${baseline.own}',
      if (baseline.prev != null && prev < baseline.prev!)
        '$prevId has $prev rows, was derived from ${baseline.prev}',
    ];
    return (baseline: baseline, loss: lost.isEmpty ? null : lost.join('; '));
  }

  /// [DayDerive.refused] when a frozen (finalized) row refused the write:
  /// nothing was stored, so the caller must not count, fingerprint or publish
  /// the day. [DayDerive.declined] when the day deliberately kept its existing
  /// result: not a derive, so the caller must not count it as done, and settles
  /// it instead (see engine/settled.dart).
  Future<DayDerive> _derivePreparedDay(
    PreparedDerivationDay day,
    Profile profile,
    int dataNowSec,
    _BaselineHistoryCache history, {
    bool forceFinalize = false,
    bool suppliedSubstrate = false,
    ana.CalculationMode calculationMode = ana.CalculationMode.forced,
    DayResultWrite reason = DayResultWrite.derive,
    // The finalization audit's reference pass: the same computation from the
    // whole day with nothing carried over, stopped where the write would be
    // (the bundle is left in [_batchBundles]); it writes nothing.
    bool batchReference = false,
    // Told when the day would finalize but tonight's sleep (the next day's
    // stored window) changed since it was prepared; the day is then written
    // provisional and the caller re-derives it. Null: finalize as decided.
    void Function(String day)? onStaleTonight,
  }) async {
    _declineReasons.remove(day.date);
    // No state from an earlier pass in this process (a headless wake, a cold
    // start): resume from the stored checkpoint when what it folded is still
    // what the day holds. A user-driven re-derive never resumes; it rebuilds.
    final ckptReuse = reason == DayResultWrite.derive && !batchReference;
    DayCalculationState? previousState =
        batchReference ? null : _calculationStates[day.date];
    // Whether the day's beat-driven figures may continue the checkpoint it was
    // loaded against. A warm calculation state has no RR/curve state of its own,
    // so the stored checkpoint is the worker's input for that tail; it is judged
    // by the gate a cold resume passes (context, folded rows, revisions) and
    // never trusted for having been probed: ownership, the zone or the rows
    // before its cursor may have moved under a process that stayed up.
    var resumed = false;
    if (previousState != null) {
      final probe = day.rrResume;
      if (probe != null && ckptReuse) {
        var gate = _checkpointGate(day, profile, probe.cp);
        if (gate.resume) gate = _foldedGate(day, probe.cp, probe.folded);
        resumed = _noteGate(day, gate, probe.folded);
      }
    } else if (ckptReuse) {
      final restored = await _restoreCheckpoint(day, profile);
      if (restored != null) {
        previousState = restored.state;
        resumed = true;
      }
    }
    // A day loaded without the beats its checkpoint folded takes the beat-driven
    // figures (24/7 screen, day curves) from the checkpoint's streaming state
    // plus the tail; when it cannot, the missing beats are read back.
    DayTailResult? stream;
    if (day.rrResume != null) {
      // Tonight's sleep begun before midnight cuts daytime HRV, which the
      // streamed value has no cut for and the tail's beats alone cannot give
      // (same rule as the wake series and the HR dip: D16/D25): that day reads
      // its whole beats.
      if (resumed && day.tonightSleepOnsetSec <= 0) {
        stream = await _streamDayTail(day);
      }
      if (stream == null) day = await _withFullRr(day);
    }
    final streamedBeats = stream?.tailRr.length ?? 0;
    perf.addCount('day_rr_beats_folded', streamedBeats);
    // Wearable days deliberately do not use the band's checkpoint stream.
    if (stream == null && !day.isWearable) {
      perf.addCount('day_rr_batch_runs', 1);
    }
    perf.addCount('curve_beats_folded',
        stream != null ? streamedBeats : day.daySub.rrMs.length);
    final daySub = day.daySub;
    final sleepSub = day.sleepSub;
    // Every edge this day is judged by (the wear window, aging, the stored
    // data_edge_sec, the overnight-settled freeze) is the edge of the device
    // that supplied it. The run's max over band and wearable is for scope
    // and pruning only: a band day judged on the ring's later edge counts
    // the band's unsynced hours as off-wrist and settles a half-drained night.
    // An import supplies its own substrate and edge (sub.lastTs): the live
    // band's DB edge never holds the imported rows.
    if (!suppliedSubstrate) {
      dataNowSec =
          await _agingEdgeFor(daySub.deviceFamily, dataNowSec, history);
    }
    // Per-second 4-class stage labels (the single source): 'wake'|'light'|
    // 'deep'|'rem'. analytics' segmentSleep exposes the 4-class stream directly
    // (NREM split into Light/Deep via the LOW-CONFIDENCE HR-depth overlay); we
    // pass it through verbatim so the UI can render Light vs Deep. Fall back to
    // the 3-class enum (light = plain NREM) only if stages4 is unexpectedly empty.
    // Resolved PER WINDOW, not per day: each span of the day goes to the best
    // source that actually covered it. Read HERE — before the pipeline input
    // is built — because BOTH energy passes price walking off these spans:
    // the pipeline's early-read mirror below and the second-half
    // `applyDayActivity`. One read, one span list, or the two figures drift.
    final liveSteps = await LocalDb.resolvedStepsForDay(day.date);
    final stepSpans = [
      for (final s in liveSteps.spans) [s.startTs, s.endTs, s.steps],
    ];
    // Step-counter calibration profile, keyed by (family, wearing). Wearing
    // is 0 (refused: no profile, no learning) when the stored code is one
    // this build does not know, or the day started before the last wearing
    // change and may have been worn at the old location.
    final devRow = await LocalDb.deviceRow();
    final rawWearing = (devRow?['wearing'] as num?)?.toInt();
    final wearingSetTs = (devRow?['wearing_set_ts'] as num?)?.toInt();
    final dayStartTs = daySub.tsSec.isEmpty ? null : daySub.tsSec.first;
    final counterWearing = rawWearing == null
        ? Wearing.wrist
        : (wearingSetTs != null &&
                dayStartTs != null &&
                dayStartTs < wearingSetTs)
            ? 0
            : (Wearing.parse(rawWearing) ?? 0);
    final counterProfile = counterWearing == 0 || daySub.deviceFamily == null
        ? null
        : await LocalDb.stepCalibrationProfile(
            daySub.deviceFamily!, counterWearing);
    final input = DayBundleInput(
      date: day.date,
      dayTsSec: daySub.tsSec,
      dayHr: daySub.hr,
      stepSpans: stepSpans,
      // A streamed day has no whole-day beats to hand over: its screen is the
      // streaming state's, handed in whole.
      dayRrTsMs: stream != null ? const [] : daySub.rrTsMs,
      dayRrMs: stream != null ? const [] : daySub.rrMs,
      dayIrregular: stream?.irregular,
      sleepTsSec: sleepSub.tsSec,
      sleepHr: sleepSub.hr,
      sleepRrTsMs: sleepSub.rrTsMs,
      sleepRrMs: sleepSub.rrMs,
      sleepSkinTemp: sleepSub.skinTemp,
      sleepJson: day.sleepJson,
      hypnoStages: day.hypnoStages,
      sleepOnsetSec: day.sleepOnsetSec,
      sleepOffsetSec: day.sleepOffsetSec,
      tonightSleepOnsetSec: day.tonightSleepOnsetSec,
      profile: profile.toMap(),
      dayConfidence: day.confidence,
      dayFlags: day.flags,
      // WHICH STRAP measured this day, so the pipeline can dispatch its
      // per-family constants (today: the HR ceiling) and REFUSE on an unknown
      // family instead of borrowing gen4's.
      deviceFamily: daySub.deviceFamily,
      // Whether the sleep window was the user's own assertion or the detector's
      // guess — sleep-onset latency only means what people think it means on a
      // forced window.
      sleepSource: day.sleepSource,
    );
    final withHistory = _attachHistory(input, history);

    // Cancellable: on timeout the isolate is KILLED, not merely abandoned to
    // keep burning a core behind the worker pool's back.
    final first = batchReference
        ? await _runAuditBatch(withHistory, day.date)
        : await perf.stage('bundle_isolate', () =>
      DerivationEngine._runDayBundleCancellable(withHistory,
      previousState, calculationMode, _perDayTimeout,
      label: 'day-bundle ${day.date}'));
    var bundle = first.bundle;
    var candidateState = first.state;
    // Readiness came back absent for TODAY specifically (not a historical
    // backfill day, which would just be noise) — log why. This ran inside
    // Isolate.run so it couldn't call Firebase itself; it just returned the
    // per-input diagnostic (see onehz_pipeline.dart's readinessAbsentDiag).
    // Throttled to once/day so repeated light-pass re-derives of today don't
    // spam the outbox with the same finding.
    final absentDiag = bundle['readiness_absent_diag'];
    if (absentDiag != null &&
        day.date == todayLabel() &&
        _loggedReadinessAbsentFor != day.date) {
      _loggedReadinessAbsentFor = day.date;
      TelemetryService.instance.breadcrumb('readiness absent: $absentDiag');
      // Flattened, not the raw nested map: record()'s Analytics forwarding
      // only keeps num/String values as-is and stringifies everything else,
      // so passing {'hrv': {'value': ..., 'baseline_n': ...}, ...} directly
      // would turn each input into one unqueryable "{value: true, ...}"
      // string instead of separately filterable fields.
      final diag = (absentDiag as Map).cast<String, dynamic>();
      final flat = <String, dynamic>{};
      for (final key in ['hrv', 'rhr', 'resp', 'temp']) {
        final v = (diag[key] as Map?)?.cast<String, dynamic>();
        if (v == null) continue;
        flat['${key}_value'] = v['value'];
        flat['${key}_baseline_n'] = v['baseline_n'];
      }
      flat['note'] = diag['note'];
      TelemetryService.instance.record(
        kind: 'event',
        level: 'warn',
        message: 'readiness_absent',
        context: flat,
      );
      // Also surface the SURPRISING case — readiness absent when it should NOT
      // be (adequate inputs, not the honest cold-start `need_baseline` note) —
      // as a queryable Crashlytics non-fatal, so a residual "readiness '—' even
      // with sleep present" is diagnosable from the per-input flags WITHOUT GA4
      // access. Cold-start (need_baseline) absences stay Analytics-only so this
      // stays low-noise (and, post the MAD/SD-z fallback, rare).
      //
      // GATE: only fire the Crashlytics non-fatal when at least one input
      // actually HAD a value with an adequate baseline (`value == true` — the
      // "should have computed" case) — a day with literally no sleep session
      // and no day-HR (every input false) is an honest, unremarkable miss, not
      // a surprise, and was previously alarming here just as loudly as a real
      // regression (analytics-only note above still records it either way).
      final note = (diag['note'] as String?) ?? '';
      final anyValuePresent = ['hrv', 'rhr', 'resp', 'temp'].any((key) {
        final v = (diag[key] as Map?)?.cast<String, dynamic>();
        return v != null && v['value'] == true;
      });
      if (!note.startsWith('need_baseline') && anyValuePresent) {
        final summary = StringBuffer('readiness_absent');
        for (final key in ['hrv', 'rhr', 'resp', 'temp']) {
          final v = (diag[key] as Map?)?.cast<String, dynamic>();
          if (v == null) continue;
          summary.write(
              ' $key=${v['value'] == true ? 'Y' : 'n'}/${v['baseline_n']}');
        }
        summary.write(' | $note');
        TelemetryService.instance.recordNonFatal(
          StateError(summary.toString()),
          StackTrace.current,
          reason: 'readiness_absent',
        );
      }
    }

    // Where this day's sleep window came from (auto / auto_fallback / manual /
    // confirmed) — drives the Sleep screen's "is this right?" prompt + the
    // manual-edit affordance. Carried verbatim from the segmentation candidate.
    bundle['sleep_source'] = day.sleepSource;
    // A sparse watch's day (inputs/canonical.dart): our own HR-led night,
    // served beside the watch's. Never on a band's day.
    final hrNight = await sparseHrNight(daySub,
        DerivationEngine._localDayLabelToSec(day.date), DerivationEngine._localNextDayLabelToSec(day.date));
    if (hrNight != null) bundle['hr_sleep_window'] = hrNight;
    final ringDay = await ultrahumanDayBlock(daySub, day.sleepOnsetSec,
        day.sleepOffsetSec, DerivationEngine._localNextDayLabelToSec(day.date),
        tonightOnsetSec: day.tonightSleepOnsetSec);
    if (ringDay != null) bundle['ring_day'] = ringDay;

    final scMap = (bundle['scalars'] as Map?)?.cast<String, dynamic>();

    // ── NEVER WRITE NOTHING OVER SOMETHING ───────────────────────────────────
    // Raw retention is `rawRetentionDays`, but derived history is forever — so
    // a day older than retention has a good `day_result` and NO raw.
    // Re-deriving it (which "Advanced data → Select all → Re-analyze" does for
    // EVERY listed day, via runDays(force: true) → _prepareTargetDay, whose
    // empty substrate yields an all-absent bundle) used to overwrite that good
    // row: `putDayResult` is ConflictAlgorithm.replace on BOTH `day_result` and
    // `metric_series`, so every scalar for the date was NULLed — and, because
    // an empty bundle's endSec was 0, the blank was written FINALIZED and could
    // never re-derive. Only `run()` had a pruned-raw guard, and only for
    // user-override days.
    //
    // Detect it BEFORE the offloaded second half so its own writes
    // (wake_day_features) can't clobber the early-read path either. With no day
    // substrate and no sleep substrate the second half has nothing to add — its
    // scalars are all derived from those two.
    final producedNothing = daySub.isEmpty &&
        sleepSub.isEmpty &&
        (scMap == null || !scMap.values.any((v) => v != null));

    // ── THE USER'S OWN BLANKING IS NOT A REGRESSION ──────────────────────────
    // Both guards below protect a good night from a derive that merely SEES
    // LESS (raw pruned out from under it). "Not sleep", and a window the band
    // cannot back, are the opposite: the user's word that the night is not a
    // night. Left to the guards they read as a regression, decline to write,
    // and the old night keeps being served, scored and baselined — the reported
    // "it keeps the data it had before". A blanked night is written, in full,
    // and its sleep rows are removed from `metric_series`.
    final blankSource = await _userBlankedNight(day.date, scMap);
    if (blankSource != null) {
      bundle['sleep_source'] = blankSource;
      // A typed window the band recorded none of: the night is the user's
      // window with nothing staged in it (D27 revised). Keep the window they
      // typed on the day; the stage ranges, if staging wrote them, say any
      // stage is possible for all of it.
      final sleep = bundle['sleep'];
      final ov = blankSource == 'manual'
          ? await LocalDb.getSleepOverride(day.date)
          : null;
      if (ov != null && sleep is Map && sleep['window'] is Map) {
        (sleep['window'] as Map)['value'] = {
          'onset_ms': (ov['onset_ts'] as num).toInt() * 1000,
          'offset_ms': (ov['offset_ts'] as num).toInt() * 1000,
        };
      }
      if (producedNothing) {
        if (batchReference) return DayDerive.committed;
        final committed = await _blankStoredNight(day, bundle, blankSource, reason);
        if (committed) await _dropFrozenHeadline(day.date);
        return committed ? DayDerive.committed : DayDerive.refused;
      }
    }
    if (producedNothing && blankSource == null) {
      final existing = await LocalDb.dayResult(day.date);
      if (DerivationEngine._isRealDayResult(existing)) {
        _log('derive ${day.date}: no substrate (raw pruned) — kept the '
            'existing result rather than blanking it');
        _declineReasons[day.date] = 'raw_pruned';
        return DayDerive.declined;
      }
    }

    // ── NEVER WRITE NIGHT-NULL OVER NIGHT-REAL (edge#305) ───────────────────
    // The guard above only catches a day with literally NOTHING. A day at the
    // retention-cutoff EDGE can have plenty of daytime HR (daySub non-empty)
    // while its sleep window's own RR/HR substrate has aged out from under it
    // (sleepSub empty) — sleep STAGING survives regardless (it replays the
    // durable `sleep_session_candidates` row, not raw), so `daySub`/`sleepSub`/
    // `scMap` all look like "something" and `producedNothing` is false — but
    // every night-physiology scalar (rhr/rmssd/readiness) comes back null.
    // `putDayResult` replaces `metric_series` wholesale (it's UNVERSIONED), so
    // this null silently overwrites a good historical baseline point and
    // collapses every later night's readiness baseline out from under it.
    //
    // v85 (edge#305 fully closed): this no longer requires THIS pass to have
    // found a sleep window. A re-stage whose RR/HR substrate aged out can come
    // back with no window at all (`NO_SLEEP_DETECTED`), not just a truncated
    // one — that shape is exactly as much a regression against an existing
    // real result, and v83's `hasSleepWindow` requirement missed it (the exact
    // counterexample #305 named). What actually distinguishes this from an
    // honest "this day never had sleep" derive is the existingHadNight check
    // right below, not whether this pass sees a window — a day that never had
    // real sleep never had an existing result with real night scalars either.
    // Decline the same way: keep the existing (older-version) row being served
    // (`_servedDayJoin` already serves the highest version <= ceiling, so
    // nothing needs to change there) rather than writing a new, worse row. A
    // `partial` row was considered instead, but `partial` still gets written
    // to `day_result` and would still shadow the better older row for
    // day-detail reads; declining is what actually protects it.
    //
    // Same decline when the prune has cut into this day's window: the midnight
    // cut keeps the oldest kept day's own rows but drops the evening half of
    // its night, so sleepSub is non-empty and the scalars come back from a
    // partial night. Every path (algo bump, force, override, rescan) lands here.
    // (Not for the audit's reference pass: it is a pure computation, judged
    // against the stored row by the comparison, not declined by it.)
    //
    // Whether the prune cut this night is decided by COVERAGE, not by the
    // global cursor (which cannot describe holes or a partial restore): the
    // decoded rows now hold fewer rows, on this day or on the one before,
    // than the stored result was derived from. Equal or more proceeds whatever
    // the cursor says. A row with no recorded coverage (imported, legacy)
    // keeps the cursor rule.
    final judgeNight = !producedNothing &&
        blankSource == null &&
        !batchReference &&
        !suppliedSubstrate &&
        day.sleepSource != 'rejected';
    final coverage = judgeNight ? await _coverageLoss(day.date) : null;
    if (!producedNothing &&
        blankSource == null &&
        !batchReference &&
        (DerivationEngine.nightSubstrateRegressed(
              sleepRejected: day.sleepSource == 'rejected',
              sleepSubEmpty: sleepSub.isEmpty,
              nightScalarsNull: scMap == null ||
                  (scMap['rhr'] == null &&
                      scMap['rmssd'] == null &&
                      scMap['readiness'] == null),
            ) ||
            // An import brings its own substrate, the prune can't have cut it.
            // A rejected night has nothing to protect either.
            (judgeNight &&
                (coverage != null
                    ? coverage.loss != null
                    : DerivationEngine.windowTruncatedByPrune(
                  day.date,
                  await LocalDb.getCursorInt(DerivationEngine._prunedBeforeCursor),
                  forcedOnsetSec: day.sleepSource == 'manual' ||
                          day.sleepSource == 'confirmed'
                      ? day.sleepOnsetSec
                      : null,
                    ))))) {
      final existingNight = await LocalDb.dayResult(day.date);
      final existingHadNight = existingNight != null &&
          (existingNight['rhr'] != null ||
              existingNight['rmssd'] != null ||
              existingNight['readiness'] != null);
      if (existingHadNight && coverage?.loss != null) {
        _log('derive ${day.date}: decoded-row coverage fell below what the '
            'stored result was derived from (${coverage!.loss}) — kept the '
            'existing result rather than overwrite it from an incomplete '
            'night (edge#305)');
        final declined = _diag['declined_days'] as List<String>;
        if (!declined.contains(day.date)) declined.add(day.date);
        // The baseline a later derive is judged by must outlive the
        // fingerprint a declined day records over it.
        await LocalDb.putDerivedCoverage(day.date, coverage.baseline);
        _declineReasons[day.date] = 'coverage_fell';
        return DayDerive.declined;
      }
      if (existingHadNight) {
        _log('derive ${day.date}: sleep-window substrate pruned out from '
            "under a day that already had real night scalars — kept the "
            'existing result rather than overwriting the readiness baseline '
            '(edge#305)');
        _declineReasons[day.date] = 'night_substrate_pruned';
        return DayDerive.declined;
      }
    }

    // ── SECOND HALF — OFFLOADED to a background isolate ──────────────────────
    // Everything that turns the isolate-1 bundle into the full day result (wake
    // features, hybrid steps + TDEE, all-day HRV/RSA/skin-temp Timeline lines,
    // naps, workout detection + HRR, wrist orientation, restlessness map, fit
    // quality) used to run on the CALLING isolate — the UI isolate for the
    // foreground light pass that fires on every sync — hanging the main thread
    // for seconds (the rolling-RSA Lomb-Scargle over the 24 h day + nap
    // re-staging + workout detection are the trig/CPU hogs). It is all PURE
    // compute over the two substrates + a few scalars, so it now runs in
    // Isolate.run. DB reads that it needs are done HERE (this is the DB-owning
    // isolate); the DB writes + notification it produces are returned as
    // descriptors and applied below. Same _perDayTimeout guard as isolate 1.
    // NON-FATAL: a failure OR timeout anywhere in the offloaded second half must
    // never skip the whole day. Isolate 1 already computed the headline scalars
    // (readiness / RHR / RMSSD) into bundle['scalars']; we persist those and just
    // drop the optional detail blocks. (Previously an exception here threw out of
    // _derivePreparedDay → the day was marked skipped → readiness rendered "-"
    // even though it had been computed fine — the "readiness randomly goes -" bug.)
    // `secondHalfOk` tracks whether this actually completed: a headline-only
    // row must be marked `partial` below so it never locks as finalized and
    // never counts as "derived" for the raw-pruning guard (see
    // LocalDb.dayResultIds) — otherwise a transient failure here permanently
    // loses the ability to ever back-fill naps/workouts/HRR/wear/curves for
    // this day once its raw substrate is pruned.
    var secondHalfOk = true;
    // The intraday calorie series this derive built (null: none to store).
    Map<String, dynamic>? kcalMinutes;
    try {
      final dayLo = daySub.length == 0 ? 0 : daySub.tsSec.first;
      final dayHi = daySub.length == 0 ? 0 : daySub.tsSec.last + 60;
      // `liveSteps`/`stepSpans` were read above, before the pipeline input —
      // one resolution serves both energy passes. `.strap` is carried
      // alongside the total so the bundle can name the sensor that counted.
      //
      // Sessions are queried over the FULL local calendar day, not
      // [dayLo, dayHi] — those bounds come from daySub's own first/last
      // sample, so a completed session the band's PPG lost contact for
      // entirely (zero HR samples at all, e.g. a wrist-gripping lift) can
      // fall outside them and never reach the zero-coverage credit below.
      final savedSessions = await LocalDb.sessionsInRange(
        DerivationEngine._localDayLabelToSec(day.date),
        localNextMidnightSecForDayLabel(day.date),
      );
      // A finished session's observed ceiling does not change unless its
      // samples do: a periodic awake pass reuses the result whose signature
      // still matches. Every other mode computes in full.
      final ceilingSigs = await _ceilingSignatures(day, savedSessions);
      final ceilingReuse =
          <String, ({Map<String, dynamic> json, double? bpm})>{};
      if (calculationMode == ana.CalculationMode.periodicAwake) {
        ceilingSigs.forEach((id, sig) {
          final hit = _ceilingCache['${day.date}|$id'];
          if (hit != null && hit.sig == sig) {
            ceilingReuse[id] = (json: hit.json, bpm: hit.bpm);
          }
        });
        _ceilingHits += ceilingReuse.length;
      }

      // Off-wrist / charging spans over the NAP window (which runs past this
      // day's end), read here because the isolate has no DB handle. These are
      // the strap's own reports: a band on a table or a charger is perfectly
      // still and otherwise reads as deep rest to a motion-based detector.
      final napLo =
          day.napSub.length == 0 ? dayLo : day.napSub.tsSec.first;
      final napHi =
          day.napSub.length == 0 ? dayHi : day.napSub.tsSec.last + 60;
      // ...and back to SLEEP ONSET, which is routinely EARLIER than napLo. This
      // day's sleep is the night that ENDED this morning, so its onset sits at
      // ~23:00 YESTERDAY — before local midnight, before the day's first
      // record. `_toggleSpans` carries an already-open state in from before its
      // window, so a charge that straddles midnight was always covered; one
      // that opened AND closed at 23:20 was invisible. That is the shape of a
      // battery-pack top-up before bed, i.e. the exact case this feeds.
      final spanLo = day.sleepOnsetSec > 0
          ? math.min(napLo, day.sleepOnsetSec)
          : napLo;
      // M5: per-owner masking. A window owned by device A is masked by
      // device A's off-body and charging events, NEVER by device B's —
      // put B on the charger while A is worn and A's real night must not
      // be excluded. Spans from different owners cannot overlap (ownership
      // is exclusive) and `_toggleSpans` returns each owner's spans in time
      // order, so concatenating owners in span order needs no merge pass.
      //
      // NO RESOLVED OWNER ⇒ MASK AS A SINGLE-DEVICE INSTALL DOES. The `??`
      // alone covered only a MISSING key (the import path). A present key can
      // still hold nothing but `deviceId: null` — `resolveOwnership` returns
      // one null-owner span whenever no candidate device covers the window, so
      // a day with no `device_coverage` rows, or one whose only covering
      // device has no `signal_priority` rank, took the null branch below,
      // asked for no spans at all, and lost wrist-off and charger masking
      // outright. That is a derived-output change on a single-device install.
      final resolvedOneHz = day.ownership[InputSignal.hr1Hz] ?? const [];
      final oneHzOwnership = resolvedOneHz.any((s) => s.deviceId != null)
          ? resolvedOneHz
          : [(start: spanLo, end: napHi, deviceId: LocalDb.kPrimaryDeviceId)];
      final wristOffSpans = <List<int>>[];
      final chargingSpans = <List<int>>[];
      // The window the user rejected or set by hand. Its metrics are blank, and
      // the same still, low-HR hours must not come back as a nap — shown as
      // "Asleep" and credited to sleep need.
      final blankedSpans = <List<int>>[];
      if (blankSource != null) {
        final ov = await LocalDb.getSleepOverride(day.date);
        final lo = (ov?['onset_ts'] as num?)?.toInt();
        final hi = (ov?['offset_ts'] as num?)?.toInt();
        if (lo != null && hi != null && hi > lo) blankedSpans.add([lo, hi]);
      }
      for (final s in oneHzOwnership) {
        final d = s.deviceId;
        if (d == null) continue; // nothing recording: nothing to mask
        final lo = math.max(spanLo, s.start);
        final hi = math.min(napHi, s.end);
        if (hi <= lo) continue;
        wristOffSpans.addAll(await LocalDb.wristOffSpans(lo, hi, deviceId: d));
        chargingSpans.addAll(await LocalDb.chargingSpans(lo, hi, deviceId: d));
      }

      // PERSONAL movement floor — ESTIMATED ONCE, THEN FROZEN.
      //
      // Freezing is the whole point and it is not an optimisation. This
      // threshold is derived from the same signal it thresholds, so a floor
      // that keeps tracking the user cancels the trend it exists to report.
      // Measured by scaling a real day's dynAmp and recomputing both ways:
      //
      //     activity x     FROZEN     recomputed
      //          1.00          23             37
      //          1.50          66             37
      //          2.00         128             37
      //          3.00         254             37
      //
      // A recomputed floor reports the SAME number whether the user tripled
      // their activity or did nothing at all. So: accumulate `dyn_p90` for an
      // enrollment window, commit the median, and keep using it. It re-freezes
      // only on events that genuinely change the signal's scale (see
      // `ana.shouldRefreezeFloor`) — never merely because time passed.
      //
      // Self-exclusion (days STRICTLY BEFORE this one) is retained for the
      // enrollment estimate: a day must not help set the threshold it is then
      // scored against. Below the minimum history the floor is null and the
      // estimator abstains rather than substituting a constant.
      final dynFloorG = await DerivationEngine._frozenMovementFloor(history, day.date);
      final dynHistory = history.valuesBefore('dyn_p90', day.date);

      // Built on THIS isolate so the Isolate.run closure captures only this plain
      // sendable object (never `this`, `day`, or `bundle`).
      // Read HERE, on the main isolate — the worker has no database.
      final reviewDb = await LocalDb.instance;
      final previousDay = await LocalDb.dayResult(day.date);
      if (previousDay != null) {
        await reviewDb.transaction((tx) => ActivityStore.preserveLegacyNaps(tx, day.date,
          Map<String, dynamic>.from(jsonDecode(previousDay['payload_json'] as String) as Map)));
      }
      // WHOOP 4 ambient check: how closely the night's skin temp moves with
      // the band's ambient channel. Read here (the isolate has no DB) and
      // stored, so the illness watch can leave ambient-driven nights out.
      if (scMap != null &&
          scMap['skin_temp_z'] != null &&
          (daySub.deviceFamily == null || daySub.deviceFamily == 'gen4') &&
          day.sleepOffsetSec > day.sleepOnsetSec) {
        scMap['skin_temp_ambient_r'] = skinTempAmbientR(
            await LocalDb.skinTempAmbientMinutes(
                day.sleepOnsetSec, day.sleepOffsetSec));
      }
      final napEdits = await ActivityStore.napEdits(reviewDb, day.date);
      final blocksInput = _DayBlocksInput(
        calculationState: candidateState, calculationMode: calculationMode,
        streamed: stream,
        ceilingReuse: ceilingReuse,
        daySub: daySub,
        napSub: day.napSub,
        napEdits: napEdits,
        sleepSub: sleepSub,
        profile: profile,
        onsetSec: day.sleepOnsetSec,
        offsetSec: day.sleepOffsetSec,
        napExcludeEndSec: day.sleepOffsetSec +
            ((day.sleepJson['band_offset_trim_sec'] as num?)?.toInt() ?? 0),
        // NOCTURNAL-ONLY. `scalars.rhr` is allowed to fall back to daytime HR
        // for the resting-HR card; feeding that into TRIMP charged a day
        // against an awake reference and published a strain the pure pipeline
        // had already refused to publish. `rhr_nocturnal` is null unless a
        // sleep session was detected — exactly the gate readiness uses.
        rhr: (scMap?['rhr_nocturnal'] as num?)?.toDouble(),
        // Same fallback, same order as the pure half: the typed value wins,
        // so this is only set when there is none.
        rhrFallback: profile.restingHrManual != null
            ? null
            : rhrFallbackFromHistory(history.valuesBefore('rhr', day.date,
                family: DerivationEngine._baselineFamily('rhr', daySub.deviceFamily))),
        maxHrUsed: (bundle['max_hr_used'] as num?)?.round(),
        liveStepsReal: liveSteps.total,
        liveStepsFromStrap: liveSteps.strap,
        counterProfile: counterProfile,
        counterWearing: counterWearing,
        // The same resolution's credited spans, so the walking-cadence term
        // prices exactly the steps the day's total already counted — never a
        // raw row the ladder took back.
        stepSpans: stepSpans,
        dynFloorG: dynFloorG,
        dynHistoryDays: dynHistory.length,
        // Per method family like every other baseline: a wearable's day is
        // priced on its own resolution's levels (a band's: unchanged).
        quietHrrHistory: history.valuesBefore('quiet_hrr', day.date,
            family: DerivationEngine._baselineFamily('quiet_hrr', daySub.deviceFamily)),
        savedSessions: savedSessions,
        typicalMealMinutes: await TypicalMealTimes.load(),
        wristOffSpans: wristOffSpans,
        chargingSpans: chargingSpans,
        blankedSpans: blankedSpans,
        mainTstMin: (scMap?['tst_min'] as num?)?.round(),
        // The scalar is a PERCENT (onehz_pipeline.dart:914); the period
        // contract and the card both want 0..1, the same normalization
        // `_daySleep` does on read.
        mainEfficiency: (scMap?['efficiency'] as num?) == null
            ? null
            : (scMap!['efficiency'] as num).toDouble() / 100.0,
        date: day.date,
        // Local midnight from the day LABEL, not from the substrate — this has
        // to be where `napSub`'s slice window opens (`_localDayLabelToSec`),
        // not where its first surviving sample happens to land, or the
        // contiguity test compares a timestamp against itself and is
        // vacuously true on every day with a gap at the boundary.
        dayStartSec: DerivationEngine._localDayLabelToSec(day.date),
        dayEndSec: day.endSec,
        dataNowSec: dataNowSec,
        tonightSleepOnsetSec: day.tonightSleepOnsetSec,
        tonightSleepOffsetSec: day.tonightSleepOffsetSec,
      );
      await DerivationEngine.debugSecondHalfHook?.call(day.date);
      final blocks = await perf.stage('blocks_isolate',
          () => DerivationEngine._runDayBlocksCancellable(blocksInput, _perDayTimeout));
      candidateState = blocks.calculationState;
      // Keep what was computed. An entry is a pure function of its signature,
      // so it is safe to keep even if a later step of this day fails.
      for (final e in blocks.ceilingComputed.entries) {
        final sig = ceilingSigs[e.key];
        if (sig == null) continue;
        _ceilingComputed++;
        final key = '${day.date}|${e.key}';
        _ceilingCache.remove(key);
        _ceilingCache[key] = (sig: sig, json: e.value.json, bpm: e.value.bpm);
        while (_ceilingCache.length > DerivationEngine._ceilingCacheMax) {
          _ceilingCache.remove(_ceilingCache.keys.first);
        }
      }
      await debugAfterDayBlocks?.call(day.date);

      // Merge the computed blocks back into the isolate-1 bundle. scMap is the
      // CastMap view over bundle['scalars'], so addAll writes through — nap_min /
      // hrr_bpm reach the persisted series map below.
      // `addAll` REPLACES `absent_notes` wholesale, and the two halves own
      // different keys: `trimp` is only ever the pure pipeline's (nothing in the
      // second half recomputes it), while strain/calories/max_hr_used are
      // the recompute's. Keep the pipeline's trimp reason across the merge or
      // the Activity screen's "training load" goes absent with nothing to say.
      // `zones` is the pipeline's too (same set as `zone_timeline`); its
      // reason is present only when the zones are empty.
      final trimpNote = (bundle['absent_notes'] as Map?)?['trimp'] as String?;
      final zonesNote = (bundle['absent_notes'] as Map?)?['zones'] as String?;
      bundle.addAll(blocks.bundlePatch);
      if (trimpNote != null && (bundle['scalars'] as Map?)?['trimp'] == null) {
        (bundle['absent_notes'] as Map?)?['trimp'] = trimpNote;
      }
      if (zonesNote != null) {
        (bundle['absent_notes'] as Map?)?['zones'] = zonesNote;
      }
      (bundle['series'] as Map?)?.cast<String, dynamic>().addAll(
            blocks.seriesPatch,
          );
      scMap?.addAll(blocks.scalarPatch);
      kcalMinutes = blocks.kcalMinutes;

      // M5: COVERAGE. Same map, one key, written only when there is
      // something to attribute. `ownersOf` counts DISTINCT NON-NULL owners
      // across every anchor signal's spans: one owner means the day had one
      // contributor and the key is omitted entirely — not `{}` — because
      // `day_result` is permanent and nearly every install is single-device.
      //
      // REBUILT as a plain `Map<String, dynamic>`, not written through the
      // existing `series` map's cast view: every other value under `series`
      // is a curve (`List<Map<String, dynamic>>`), so Dart's map-literal
      // inference locked THAT map's value type to exactly that shape —
      // writing a differently-shaped value (this one is a `Map`) through a
      // `.cast<String, dynamic>()` VIEW checks the write against the
      // underlying (non-dynamic) value type and throws. Copying into a
      // fresh dynamic-valued map first sidesteps that entirely.
      final owners = ownersOf(day.ownership);
      if (owners.length > 1) {
        final seriesMap = Map<String, dynamic>.from(
          (bundle['series'] as Map?) ?? const {},
        );
        seriesMap['coverage'] = {
          for (final e in day.ownership.entries)
            e.key.name: coverageToJson(e.value),
        };
        bundle['series'] = seriesMap;
      }

      // ONE ANSWER FOR STRAIN. The second half just recomputed it from the same
      // nocturnal-or-user resting HR the pure pipeline gated on, and its scalar
      // is what every surface reads. When that recompute abstains, stamp
      // `clinical.strain` absent alongside the null scalar: the two were
      // written by different code paths off different resting HRs, and a stored
      // bundle could hold "—" in one and a confident 5.99 in the other.
      if (scMap != null && scMap['strain'] == null) {
        final strainEnv = (bundle['clinical'] as Map?)?['strain'];
        if (strainEnv is Map) {
          strainEnv['value'] = '—';
          strainEnv['confidence'] = 0;
          // The note is stamped even when the envelope was ALREADY absent. It
          // used to be gated on `value != '—'`, so on every day where both
          // halves abstained — which is every day this matters on — the reason
          // never landed and the envelope kept the scorer's "strain needs a
          // TRIMP", naming a sibling metric instead of the missing input.
          strainEnv['note'] =
              blocks.wake['strain_absent'] ?? kUnknownAbsenceNote;
        }
      }
      // A session floor raised the scalar above the HR-only envelope: the
      // envelope carries the same number and says why. `series.strain_curve`
      // stays the HR build-up through the day.
      final strainEnv = (bundle['clinical'] as Map?)?['strain'];
      final scStrain = scMap?['strain'];
      if (strainEnv is Map &&
          scStrain is num &&
          strainEnv['value'] is num &&
          scStrain > (strainEnv['value'] as num)) {
        final hrStrain = (strainEnv['value'] as num).toDouble();
        strainEnv['value'] = scStrain;
        strainEnv['note'] = 'the day\'s headline strain, which a workout '
            'logged this day can raise (heart-rate strain '
            '${hrStrain.toStringAsFixed(1)})';
      }
      // Method, family and class on each envelope of a wearable's day
      // (inputs/canonical.dart). A band's day is untouched.
      tagEnvelopes(bundle['clinical'] as Map?, daySub.deviceFamily);

      // DB writes + notification the pure compute deferred to us (DB-owning isolate).
      // The audit's batch reference pass writes nothing; otherwise the HRR
      // stamps and suggestions land in one transaction.
      if (!batchReference) {
        final deferredAt = DateTime.now().millisecondsSinceEpoch;
        await LocalDb.putDerivedSessionWrites(
          hrr: [for (final w in blocks.sessionHrrWrites) (w.$1, w.$2)],
          suggestions: [
            for (final sug in blocks.suggestionsToPersist)
              {...sug, 'created_at': deferredAt},
          ],
        );
      }
      final activityStore = ActivityStore(await LocalDb.instance);
      // The audit's batch reference pass writes nothing and prompts nothing.
      final newSuggestions = [
        if (!batchReference)
          ...await activityStore.reconcile(
              ActivityKind.workout, blocks.suggestionsToPersist),
        if (!batchReference)
          ...await activityStore.reconcile(ActivityKind.nap, blocks.napSuggestions),
        if (!batchReference)
          ...await activityStore.reconcile(ActivityKind.meal, blocks.mealSuggestions),
      ];
      for (final suggestion in newSuggestions) {
        // The rows are already banked; a failed prompt must not mark the day partial.
        try {
          // Meal candidates belong in review. The existing alert preferences
          // opt into nap/workout prompts and do not authorize meal alerts.
          if (suggestion.kind == ActivityKind.meal || forceFinalize ||
              !await activityStore.mayNotifyNew(suggestion)) {
            continue;
          }
          final nap = suggestion.kind == ActivityKind.nap;
          await NotificationCenter.instance.emit(NotificationEvent(
            dedupeKey: '${day.date}:activity:${suggestion.id}',
            category: NotifCategory.reminders, priority: NotifPriority.normal,
            title: nap ? 'Did you nap?' : 'Did you work out?',
            body: 'A possible ${nap ? 'nap' : 'workout'} is ready to review.',
            date: day.date, route: activitySuggestionRoute(suggestion.id, suggestion.kind.name),
          ), allowPermissionPrompt: false);
        } catch (e) {
          _log('activity prompt failed for ${suggestion.id}: $e');
        }
      }

      if (!batchReference) {
        await _persistWakeDayFeatures(dayId: day.date, wake: blocks.wake);
      }
    } catch (e, st) {
      secondHalfOk = false;
      _log('day-blocks (offloaded second half) failed for ${day.date} — '
          'persisting headline day (partial): $e');
      TelemetryService.instance.recordNonFatal(e, st, reason: 'day_blocks_failed');
    }

    // Finalize once the DATA EDGE has moved >48 h past the day's last record — we
    // have continuous drained data well beyond it, so no more flash can land for
    // this day. (Anchored on the last record ts, NOT the wall clock.) Imports
    // force-finalize: there is no stored raw to ever recompute them from, so
    // forceFinalize wins even for a partial (headline-only) result — there's
    // nothing left to retry regardless. Outside of that, never let a partial
    // result lock in as finalized purely by age, or its missing naps/
    // workouts/HRR/wear/curves would never get a chance to be filled in by a
    // later retry.
    final ageFinalized = (day.endSec + _finalizationSec) < dataNowSec;
    // A result with NOTHING in it is never finalized — not even by
    // forceFinalize. Locking an all-absent row is what made the destructive
    // re-analyze permanent; leaving it unlocked means a later pass (or a
    // restored/backfilled substrate) can still fill the day in.
    final finalized =
        !producedNothing && (forceFinalize || (ageFinalized && secondHalfOk));

    // A failed/timed-out second half yields a headline-only bundle, and
    // putDayResult replaces the row wholesale — so re-deriving an already
    // complete day (a force re-derive deliberately revisits finalized days) destroyed
    // its naps, sleep periods, workouts, HRR, wear and curves. Carry the
    // previous result's detail forward instead of blanking it. Same principle as
    // the producedNothing guard above and the skip-marker guard in
    // _markDaySkipped: never let a thinner result overwrite a richer one.
    var effectiveFinalized = finalized;
    var effectivePartial = !secondHalfOk;
    if (!secondHalfOk) {
      final existing = await LocalDb.dayResult(day.date);
      if (DerivationEngine._isRealDayResult(existing)) {
        final prev = DerivationEngine._decodeBundle(existing!['payload_json']);
        if (prev != null) {
          final recovered = DerivationEngine.carryForwardDetail(
            prev,
            bundle,
            blankSource: blankSource,
          );
          final prevVersion = (existing['algo_version'] as num?)?.toInt();
          final outcome = DerivationEngine.recoveryOutcome(
            recovered: recovered,
            prevPartial: (existing['partial'] as num?)?.toInt() == 1,
            prevVersion: prevVersion,
            prevFinalized: (existing['finalized'] as num?)?.toInt() == 1,
            finalizedByAge: finalized,
          );
          effectivePartial = outcome.partial;
          effectiveFinalized = outcome.finalized;
          _log('derive ${day.date}: second half failed — carried the previous '
              "result's detail blocks forward (v$prevVersion -> v$kAlgoVersion, "
              'partial=$effectivePartial)');
        }
      }
    }

    if (batchReference) {
      // A reference only counts when the whole computation completed.
      if (secondHalfOk) _batchBundles[day.date] = bundle;
      return DayDerive.committed;
    }
    bundle = debugAccumulatorTamper?.call(day.date, bundle) ?? bundle;
    // OWED A STRAIN SCORE ([kQuietRepassKeyPrefix]). Marked conservatively
    // ([_quietRepassOwed]), BEFORE the row, so no interruption can leave an
    // unmarked, prunable day still waiting on a score. CLEARED ONLY ON PROOF
    // (after the row, below): a derive that completed BOTH halves — no
    // timeout, no carried-forward previous row — and is either no longer
    // blocked on the quiet level or provably never can be
    // ([_quietLevelUnreachable]). A second half that failed leaves `trimp_net`/
    // `quiet_hrr` unwritten even when the pipeline's strain came back, so it
    // proves nothing. While marked the day is never locked, by age or by a
    // carried-forward row. An import force-finalizes regardless: it has no
    // raw to re-score from, and is never marked.
    final quietKey = '${DerivationEngine.kQuietRepassKeyPrefix}${day.date}';
    final quietSettled = !forceFinalize &&
        secondHalfOk &&
        (!DerivationEngine.quietBlocked(bundle) || await _quietLevelUnreachable(day.date));
    var quietMarked = false;
    if (!forceFinalize) {
      if (!quietSettled &&
          (await LocalDb.computeFreshness(quietKey) != null ||
              await _quietRepassOwed(day.date, bundle))) {
        quietMarked = true;
      }
      if (quietMarked) {
        await LocalDb.putComputeFreshness(quietKey, '{}');
        effectiveFinalized = false;
      }
    }

    // OWED A PROFILE FIELD ([kProfileRepassKeyPrefix]). A metric that abstained
    // for a missing age/sex/height/weight is not final: the user can still
    // supply it and the day re-derives while its raw is held. Bounded by the
    // raw-hold window (past it the prune releases the raw anyway, so the day
    // finalizes with the abstention stated in its absent notes) so a user who
    // never enters age does not keep every day open. Marker BEFORE the row,
    // cleared AFTER it, like the quiet marker above.
    final profileKey = '${DerivationEngine.kProfileRepassKeyPrefix}${day.date}';
    final profileBlocked = DerivationEngine.profileBlockedFields(bundle);
    final profileHeld = !forceFinalize &&
        profileBlocked.isNotEmpty &&
        dataNowSec - day.endSec < DerivationEngine._maxRawHoldDays * 86400;
    if (profileHeld) {
      await LocalDb.putComputeFreshness(
          profileKey, (profileBlocked.toList()..sort()).join(','));
      effectiveFinalized = false;
    }
    final profileSettled = !profileHeld &&
        (forceFinalize || secondHalfOk) &&
        await LocalDb.computeFreshness(profileKey) != null;

    // Tonight's sleep is the next day's stored window, read when this day was
    // prepared. A concurrent derive of the next day can write it after that
    // read (or still will: it is in this pass and not done), so the waking
    // series behind strain/TRIMP/zones/calories, daytime HRV and the HR dip
    // may be cut on an older night. A provisional row
    // converges on the next derive; a frozen one never would. So the day is
    // left provisional and the pass derives it again once the pool is done.
    if (effectiveFinalized &&
        reason == DayResultWrite.derive &&
        onStaleTonight != null &&
        (_passPendingDays.contains(
                localDateLabel(DerivationEngine._localNextDayLabelToSec(day.date))) ||
            (_tonightSpanAtPrep.containsKey(day.date) &&
                await _nextDayWindowSpan(day.date) !=
                    _tonightSpanAtPrep[day.date]))) {
      effectiveFinalized = false;
      onStaleTonight(day.date);
    }

    // The finalization audit sits between the decision and the write: only a
    // day that finalizes by derive (a user override already is a from-scratch
    // run; an import has no raw).
    if (effectiveFinalized && reason == DayResultWrite.derive) {
      bundle = await _auditAtFinalization(
          day, profile, dataNowSec, history, bundle);
    }
    final scalars =
        (bundle['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    double? sc(String k) => (scalars[k] as num?)?.toDouble();
    final ring = daySub.deviceFamily == kOuraFamily
        ? (await activeWearable())?.$1
        : null;
    final strapNight = ring != null &&
        await ouraStrapOwnsNight(ring, day.sleepJson['window']);
    final persistWatch = Stopwatch()..start();
    final committed = await LocalDb.putDayResult(
      dayId: day.date,
      algoVersion: kAlgoVersion,
      // Held to the revisions the shared baseline history was loaded at.
      inputStamp: stampNotLaterThan(day.inputStamp, history.metricSeriesRevs),
      // The data edge this row was derived against. The cross-day settled
      // test compares the row's wake with THIS edge, not a fresher one read
      // later: ingest keeps committing during a pass, and a newer edge would
      // call a night settled whose wake came from a truncated substrate.
      payloadJson: jsonEncode({...bundle, 'data_edge_sec': dataNowSec}),
      windowJson: jsonEncode(
        ((day.sleepJson['window'] as Map?) ?? const {}).cast<String, dynamic>(),
      ),
      finalized: effectiveFinalized,
      partial: effectivePartial,
      rhr: sc('rhr'),
      rmssd: sc('rmssd'),
      readiness: sc('readiness'),
      // export-provenance: this day's scalars came out of the 1 Hz substrate
      // the strap recorded. An importer's day is a DIFFERENT vendor's derived
      // score and must carry its own tag; a day whose provenance is genuinely
      // unknown stays NULL and is never retro-filled with this.
      source: 'band',
      // WHICH BAND'S UNITS these scalars are in (B5). Already null when the
      // day's substrate spans two straps or carries no stamp — the same
      // "unknown, never guessed" value the column is documented with.
      deviceFamily: daySub.deviceFamily,
      // M5: the day's contributor set. Null exactly like `deviceFamily`
      // above when there is nothing to attribute (the import path, which
      // never populates `deviceIds`).
      coverageDevices: daySub.deviceIds.isEmpty
          ? null
          : (daySub.deviceIds.toList()..sort()).join(','),
      // M5: the priority order actually used to resolve this day — CARRIED
      // from `_prepareTargetDay` (`day.priority`, empty-table fallback
      // already applied there), not reconstructed from the resolved spans (a
      // span list only names OWNERS, not the full ranked candidate list) and
      // not re-read here. Re-reading could stamp an order the user changed
      // while the day was computing, i.e. one no output of this day used.
      // Null only when no resolve ran at all (the import path).
      priorityHash:
          day.priority.isEmpty ? null : priorityKey(day.priority),
      // Per key: the method, method family and class (inputs/canonical.dart).
      // Its own table, so no band row this already wrote moves.
      seriesMethod: seriesMethodFor(daySub.deviceFamily,
          vendorNight: day.sleepSource == 'vendor_staged',
          strapNight: strapNight,
          provisionalReadiness: ((bundle['clinical'] as Map?)?[
                  'readiness_composite'] as Map?)?['provisional'] ==
              true),
      // State, not event: a day the user has an override on and that holds no
      // night owns no sleep rows. Keyed on freshness instead, a later pass (no
      // longer "fresh") would write the NULL rows back and flip the table.
      blankKeys: (blankSource != null ||
              (sc('tst_min') == null &&
                  await LocalDb.getSleepOverride(day.date) != null))
          ? kSleepDerivedMetricKeys
          : const {},
      series: {
        'rhr': sc('rhr'),
        'rmssd': sc('rmssd'),
        'sdnn': sc('sdnn'),
        'readiness': sc('readiness'),
        'readiness_z': sc('readiness_z'),
        'ln_rmssd': sc('ln_rmssd'),
        'resp_rate': sc('resp_rate'),
        'skin_temp_z': sc('skin_temp_z'),
        // RAW nightly ADC mean — the baseline series for skin_temp_z. Written
        // EVERY day (even during the bootstrap window where skin_temp_z is null)
        // so the baseline fills and z begins computing from ~day 4.
        'skin_temp_adc': sc('skin_temp_adc'),
        'dip_pct': sc('dip_pct'),
        // Headline 0–21 strain (for trend/sparkline); raw TRIMP kept too.
        // Written even when NULL: an abstaining day must overwrite a value a
        // previous version's daytime-RHR strain left behind, not keep it.
        'strain': sc('strain'),
        'trimp': sc('trimp'),
        // This day's own quiet-waking level: the series LATER days' strain is
        // priced against (median of the trailing 28, strictly before). Never
        // written for an imported day — imports carry no 1 Hz wake series.
        'quiet_hrr': sc('quiet_hrr'),
        // Banister TRIMP earned ABOVE the quiet level, exercise unoffset — the
        // per-day load a CTL/ATL training-load read takes, where gross `trimp`
        // would count being awake as training.
        'trimp_net': sc('trimp_net'),
        // `strain_effort`, `spo2` and `odi_per_hour` used to be listed here.
        // Nothing in the tree ever produced them (12 rows, 0 values per key on
        // a real install), so they were three permanently-null series with a
        // card-less key in the coach's contract. A metric this app does not
        // produce has no entry and no key — the same rule metric_detail.dart
        // states and the UI already followed.
        // New metrics → trends (day/week/month/3M).
        'stress': sc('stress'),
        'calories': sc('calories'),
        // Steps = REAL pedometer counts only (band 100 Hz / phone / NOOP
        // import, all via `live_coverage`). Absent — written as a NULL row, so
        // a previously fabricated value is overwritten rather than left
        // standing — on any day nothing gait-capable measured.
        'steps': sc('steps'),
        // Movement minutes: activity VOLUME, not locomotion. Steps are NOT
        // derived from this and never will be again (see the v55/v56 note).
        'active_min': sc('active_min'),
        // This day's high quantile of the calibration-invariant dynamic accel
        // amplitude. Not a user-facing metric: it is the per-day summary the
        // NEXT day's derive pools to anchor its personal ambulatory floor, so
        // the threshold never depends on a single day (see _BaselineHistoryCache).
        'dyn_p90': sc('dyn_p90'),
        'calories_total': sc('calories_total'),
        // Daytime nap minutes (principled van Hees + HR-dip) → trend + Sleep Coach.
        'nap_min': sc('nap_min'),
        // Sleep-stage minutes + HRV freq/stability trends.
        'rem_min': sc('rem_min'),
        'deep_min': sc('deep_min'),
        'light_min': sc('light_min'),
        'tst_min': sc('tst_min'),
        'lf_hf': sc('lf_hf'),
        'hrv_cv': sc('hrv_cv'),
        'efficiency': sc('efficiency'),
        'worn_min': sc('worn_min'),
        // v25: 24/7 irregular-rhythm screen flag, breathing-rate variability,
        // and mean heart-rate recovery across the day's detected bouts.
        'irregular_rhythm_flag': sc('irregular_rhythm_flag'),
        'brv_cv': sc('brv_cv'),
        'hrr_bpm': sc('hrr_bpm'),
        // Recovery time constant (s) from the same tail `hrr_bpm` comes off.
        // Alongside it, never instead of it — the fit gate abstains often.
        'hrr_tau_s': sc('hrr_tau_s'),
        // Deceleration capacity (ms), personal trend only — no reference range,
        // no colour, no threshold, ever.
        'prsa_dc': sc('prsa_dc'),
        // How much of the sleep window the temp channel actually covered.
        'skin_temp_coverage_frac': sc('skin_temp_coverage_frac'),
        // Sleep shape: hours nobody watched, sustained awakenings (a floor),
        // longest unbroken stretch, and forced-window sleep-onset latency.
        'unobserved_min': sc('unobserved_min'),
        'awakenings': sc('awakenings'),
        'longest_sleep_min': sc('longest_sleep_min'),
        'sol_min': sc('sol_min'),
        // SLP-09 / L10 — where on the clock the night sat, tz-corrected and
        // UNWRAPPED (signed seconds either side of 04:00 local; see
        // onehz_pipeline's sleepClockOffsetSec). Written so a schedule-shift
        // segmentation has a series to run on in six months. FORWARD-ONLY:
        // mid-sleep was never persisted, the 1 Hz substrate it comes from is
        // gone at `rawRetentionDays`, and days lock ~48 h after wake — so every
        // night before this shipped has no value and cannot be given one.
        'midsleep_sec': sc('midsleep_sec'),
        'sleep_onset_sec': sc('sleep_onset_sec'),
        // TS-03 — this day's observed HR ceiling (bpm), or NULL on the ordinary
        // day that held none. The app-wide "highest we've seen" is the max of
        // this series; the date/session behind it lives in that day's bundle.
        'hr_ceiling_bpm': sc('hr_ceiling_bpm'),
      },
      reason: reason,
    );
    if (!committed) {
      _log('derive ${day.date}: frozen result refused the write');
      return DayDerive.refused;
    }
    _persistMs[day.date] = persistWatch.elapsedMilliseconds;
    if (blankSource != null) await _dropFrozenHeadline(day.date);
    if (secondHalfOk) await _storeKcalMinutes(day, profile, kcalMinutes);
    // AFTER the row: retired only once the row that proves it is durable.
    if (quietSettled) await LocalDb.deleteComputeFreshness(quietKey);
    if (profileSettled) await LocalDb.deleteComputeFreshness(profileKey);
    // NOTE: the sweep's `history` snapshot is deliberately NOT updated here.
    // See _BaselineHistoryCache — mutating the shared snapshot mid-sweep is the
    // duplicate-day pollution bug, and each day already derives its own
    // date-bounded window from the frozen snapshot.
    _log(
      'derived ${day.date} v$kAlgoVersion '
      '(sleep=${day.sleepOffsetSec > day.sleepOnsetSec}, final=$effectiveFinalized)',
    );
    await _maybeFreezeHeadlineReadiness(day, dataNowSec, sc('readiness'));
    // Learn the step-counter calibration from finalized days only (a partial
    // day has the phone running ahead of the last offload), and only from
    // phone-only days: on a mixed day the phone spans are what is left after
    // band spans claimed their windows, not an independent reference.
    if (finalized && counterWearing != 0 && !liveSteps.mixed) {
      await updateStepCalibration(
        day.date,
        daySub,
        counterWearing,
        phoneSpans: [
          for (final s in liveSteps.spans)
            if (!s.fromBand) s,
        ],
      );
    }
    // A partial, carried-forward result or any failed write must not advance
    // the reusable checkpoint. Both workers only mutate isolate-owned copies.
    if (secondHalfOk) {
      _publishCalculationState(day.date, candidateState, finalized: finalized);
      await _refreshCheckpoint(day, profile, dataNowSec,
          finalized: finalized,
          reuse: ckptReuse,
          state: candidateState,
          stream: stream);
      // Its bytes are in the checkpoint now; do not carry them (and copy them
      // into the next worker) with the retained state.
      candidateState.exportedNightJson = null;
    }
    return DayDerive.committed;
  }

  /// After a day's result committed: advances its checkpoint to the newest
  /// closed 15-minute boundary (folding only the rows since the one it had,
  /// or the whole closed prefix when it had none usable), drops it for a
  /// finalized day, and drops those of days the engine no longer resumes.
  /// Scratch only: a failure here is logged and never fails the derive.
  Future<void> _refreshCheckpoint(
    PreparedDerivationDay day,
    Profile profile,
    int dataNowSec, {
    required bool finalized,
    required bool reuse,
    required DayCalculationState state,
    DayTailResult? stream,
  }) async {
    try {
      // A day stays resumable until it finalizes, 48 h after it ends, so the
      // newest data's day and the two before it are the ones that can still
      // be re-derived by a light pass. Counted from the data, not the clock:
      // a phone that has not synced in a week resumes the day it last heard of.
      final newest = DateTime.fromMillisecondsSinceEpoch(dataNowSec * 1000);
      final keep = {
        for (var i = 0; i < DerivationEngine._retainedCalculationDays; i++)
          dayLabelOf(DateTime(newest.year, newest.month, newest.day - i)),
      };
      await LocalDb.pruneDayCheckpoints(keepDays: keep);
      if (finalized || !keep.contains(day.date)) {
        await LocalDb.deleteDayCheckpoints(day.date);
        return;
      }
      final revs = day.inputRevs;
      final sub = day.daySub;
      final ts = sub.tsSec;
      if (revs == null || ts.isEmpty) return;
      final boundary = (ts.last ~/ kRevBucketSec) * kRevBucketSec;
      final hi = firstIndexAtOrAfter(ts, boundary);
      if (hi == 0) return; // no closed bucket yet
      final existing = reuse ? await LocalDb.dayCheckpoint(day.date, kAlgoVersion) : null;
      var lo = 0;
      Uint8List? base;
      if (existing != null) {
        final cpBucket = existing.cpRecTs ~/ kRevBucketSec;
        final decision = decideResume(
          cp: existing,
          algoVersion: kAlgoVersion,
          ctxSig: _checkpointContext(day, profile, clipEndSec: existing.cpRecTs).sig,
          liveRevs: {
            for (final e in revs.entries)
              if (e.key < cpBucket) e.key: e.value,
          },
        );
        if (decision.resume) {
          if (existing.cpRecTs >= boundary) return; // already as far
          lo = firstIndexAtOrAfter(ts, existing.cpRecTs);
          base = existing.state;
        }
      }
      // A streamed day holds only the beats after the checkpoint it resumed
      // from, so it can only extend THAT checkpoint: one that is gone or moved
      // since is left for the next (full) pass to rewrite.
      if (stream != null &&
          (base == null || existing!.cpRecTs != day.rrResume!.cp.cpRecTs)) {
        return;
      }
      // The beats this checkpoint adds: those from the edge of the last one's
      // (all of them for a first fold) to this one's, off the day's beats or, for
      // a streamed day, its tail.
      final srcRr = stream?.tailRr ?? sub.rrMs;
      final srcTs = stream?.tailTs ?? sub.rrTsMs;
      final edgeOld =
          base == null ? double.negativeInfinity : rrFoldEdgeMs(existing!.cpRecTs);
      final edgeNew = rrFoldEdgeMs(boundary);
      final addRr = <double>[], addTs = <double>[];
      for (var i = 0; i < srcRr.length; i++) {
        if (srcTs[i] >= edgeOld && srcTs[i] < edgeNew) {
          addRr.add(srcRr[i]);
          addTs.add(srcTs[i]);
        }
      }
      final ctx = _checkpointContext(day, profile, clipEndSec: boundary);
      final sc = sub.stepCount;
      // The night's streaming state and the cardio rows of the day's staging
      // window ride in the blob as plain data; the worker encodes them. A new
      // pass adopts the night only if its slice proves to extend it.
      final window = _targetDayWindow(day.date);
      final rowsLo = window.$1 - kCardioRowsSlackSec;
      final rowsHi = window.$2 + kCardioRowsSlackSec;
      final blob = await perf.stage('checkpoint', () => DerivationEngine._foldCheckpoint(
            base: base,
            alreadyFolded: lo,
            ts: ts.sublist(lo, hi),
            hr: sub.hr.sublist(lo, hi),
            ax: sub.ax.sublist(lo, hi),
            ay: sub.ay.sublist(lo, hi),
            az: sub.az.sublist(lo, hi),
            stepCounter: [for (var i = lo; i < hi; i++) i < sc.length ? sc[i] : -1],
            age: ctx.age,
            stepModulus: ctx.stepModulus,
            // The priced wake minutes up to the checkpoint, so the next pass
            // prices only what moved. They follow this pass's window, which the
            // folded state does not.
            bills: state.minuteBills(beforeMinute: boundary ~/ 60),
            rrMs: addRr,
            rrTsMs: addTs,
            throughSec: boundary,
            quietCutG: ana.calibrationFor(DerivationEngine._quietEnmoCutG, sub.deviceFamily) ?? 0.02,
            nightJson: state.exportedNightJson,
            cardioRowChunks: [
              for (final c in _cardioRowChunks)
                if (c.overlaps(rowsLo, rowsHi)) c.json,
            ],
            cardioRowsLoSec: rowsLo,
            cardioRowsHiSec: rowsHi + 1,
            timeout: _perDayTimeout,
            label: 'checkpoint ${day.date}',
          ));
      perf.addCount('cp_folded', hi - lo);
      if (blob == null) {
        // The stored blob cannot be extended (a pass that resumed from it would
        // fall short of the next boundary again and again): drop it, and the
        // next pass folds the day from its start.
        if (base != null) await LocalDb.deleteDayCheckpoints(day.date);
        return;
      }
      await LocalDb.putDayCheckpoint(DayCheckpoint(
        dayId: day.date,
        algoVersion: kAlgoVersion,
        fmt: kDayCheckpointFmt,
        ctxSig: ctx.sig,
        cpRecTs: boundary,
        revVec: encodeRevVec({
          for (final e in revs.entries)
            if (e.key < boundary ~/ kRevBucketSec) e.key: e.value,
        }),
        state: blob,
        nightRef: null,
        computedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (e) {
      _log('checkpoint ${day.date} not refreshed: $e');
    }
  }
}
