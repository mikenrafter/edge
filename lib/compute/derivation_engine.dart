// DerivationEngine — the on-device compute COORDINATOR (MAIN ISOLATE).
//
// Current flow (per trigger):
//   1. Decide WHICH calendar days need compute (force / pending span / latest
//      freshness-critical day).
//   2. Build / refresh the first primitive, `sleep_session_candidates`, from a
//      bounded overlap window only when needed.
//   3. Load the exact calendar-day substrate + exact sleep-window substrate for
//      the target day, then build one PreparedDerivationDay from those pieces.
//   4. Run the pure day pipeline off-isolate, then compute the second
//      primitive, `wake_day_features`, directly from the local-day substrate.
//   5. Persist day_result as the materialized UI surface, plus compact baseline
//      artifacts (`rolling_artifact`, `crossday_input`) for downstream reuse.
//   6. Run cross-day / notifications from those compact artifacts and prune raw
//      only after a force/full-history sweep, never before derived.
//
// Finalized-day rescans are still allowed for baseline-dependent scalars
// (readiness/recovery, illness/anomaly, stress), but they now gate off the
// rolling baseline artifact instead of recomputing the signature ad hoc from
// metric_series each time.

import '../data/activity_store.dart';
import '../data/db/input_read_tracker.dart';
import '../data/db/input_revision_store.dart' show observeInputZone;
import 'accepted_naps.dart' show composeAcceptedNaps;
import '../models/activity_suggestion.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, ProcessInfo;
import 'dart:isolate';
import 'dart:math' as math;

import 'quiet_level_seed.dart' show seedQuietHrrHistoryOnce;
import 'strain_backfill.dart' show backfillStrainScale;
import 'readiness_calibration_backfill.dart'
    show
        backfillReadinessCalibration,
        readinessCalibrationDone,
        seedRecentReadinessZ;

import 'package:crypto/crypto.dart' show sha1, sha256;
import 'package:flutter/foundation.dart';
import 'findings.dart';
import 'nap_overlap_cleanup.dart';
import 'nap_edits.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../data/live_coverage_policy.dart' show CoverageSpan;
import '../data/step_calibration.dart';

import '../ble/adapters/signals.dart';
import '../data/coverage_resolver.dart';
import '../data/db.dart';
import '../data/day_label.dart';
import '../data/series_codec.dart';
import '../data/sample_archive.dart' show SampleArchiver;
import '../notify/fired_keys.dart';
import '../state/locale_controller.dart' show LocaleController;
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/tap_router.dart' show activitySuggestionRoute;
import '../telemetry/firebase_bridge.dart';
import '../telemetry/telemetry_service.dart';
import 'calc_power_policy.dart';
import 'calc_status.dart';
import 'finalization_audit.dart';
import 'crossday_input.dart';
import 'crossday_pipeline.dart';
import 'kcal_minutes.dart';
import 'sleep_blank.dart';
import 'derive_outcome.dart';
import 'derive_pacing.dart';
import 'inputs/canonical.dart';
import 'inputs/garmin_inputs.dart'
    show
        isWearableFamily,
        kHrCadenceSec,
        kOneHzRunGapSec,
        kWearableFamilies,
        methodFamily;
import 'inputs/oura_inputs.dart' show kOuraFamily, ouraStrapOwnsNight;
import 'inputs/ultrahuman_inputs.dart' show ultrahumanDayBlock;
import 'derive_perf.dart';
import 'hr_max.dart'
    show estimatedMaxHr, kHrFloorBpm, smoothedMaxHr, smoothedMinHr;
import 'movement_floor_policy.dart' as mfp;
import 'sleep_profile_policy.dart';
import 'derive_prepare.dart';
import 'onehz_pipeline.dart';
import 'day_calculation_state.dart';
import 'day_checkpoint_fold.dart';
import 'day_checkpoint_policy.dart';
import 'day_resume_state.dart';
import 'cardio_rows_blob.dart';
import 'sleep_staging_worker.dart';
import 'staged_sleep_cache.dart';
import 'day_tail_fold.dart';
import 'minute_bills.dart';
import 'step_cadence.dart';
import 'profile.dart';
import 'substrate.dart';
import 'substrate_retention.dart';
import 'union_cut_heavy.dart';
import 'vendor_sleep.dart';
import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_init.dart' show WorkerInputs;
import '../util/worker_entries.dart' show Dispatcher;

part 'engine/top_level.dart';
part 'engine/prepare.dart';
part 'engine/day_compute.dart';
part 'engine/crossday_prune.dart';
part 'engine/settled.dart';

/// Analytics/bundle version — bump to force a recompute of non-finalized days.
/// v3: Walch 2019 stager + 4-class stages (light/deep/rem), robust nocturnal HRV,
/// 0–21 strain, skin-temp-z baseline fix, baseline-need signals.
/// v4: finalization + retention anchored on the DATA EDGE (last drained record
/// timestamp), not the wall clock — a buffer-and-sync band's wall-clock time is
/// irrelevant. Bumping resets per-version finalization so any day the old wall-
/// clock logic prematurely LOCKED (before its flash fully drained) re-derives.
/// v5: sleep HR-dip is confidence-only — no longer relocates onset. Validated on
/// real data: the old trim shoved a true 02:15 onset to 02:41, discarding ~26
/// min of real early sleep. Window onset now stands; stager decides wake within.
/// v6: replaced the Walch ML stager with a transparent cardiorespiratory rule
/// stager (motion + HR + RMSSD vs the night's own baseline). Walch over-called
/// wake (solid night read 60% eff) and ignored RR; the rule stager uses RR and,
/// on real data, lifts a true solid night to ~94–99% eff with a plausible
/// light/deep/REM mix. Honest ESTIMATE (conf scales with RR coverage).
/// v7: CALENDAR-day model (local midnight→midnight) replaces wake-to-wake. A
/// day's sleep = the main sleep that ENDED that morning; recovery follows into
/// the day, strain = that day's waking activity. Deletes the wake-scan day
/// boundaries / 36 h horizon / back-extension; recompute = the calendar day(s)
/// new data touches. Day keys are now plain calendar dates.
/// v8: STRESS (Baevsky SI, windowed median → 0–100 score) + relative SpO₂
/// (overnight desaturation index) now computed, persisted to day_result +
/// metric_series, and surfaced (Today tiles, stress screen, day/week/month/3M
/// trends). Stress validated on real data (SI ~47–52, low/normal resting).
/// v9: ACTIVITY-MINUTES — coarse 1 Hz movement proxy (wrist orientation change;
/// 1 Hz can't do ENMO/steps — Nyquist). Persisted + trended. Validated on real
/// data (~477 active min on a full day). True step counts remain live-IMU only.
/// v10: active calories (Keytel), HR zones, nocturnal nadir/waking, sleep-need
/// 8 h default; activeMin stored as double (fixes the int→double? derive crash).
/// v11: SLEEP CYCLES corrected to Rosenblum 2024 "fractal cycles" (HRV-adapted):
/// peak-to-peak of the smoothed per-minute RMSSD series, NOT categorical REM-
/// episode counting. Validated on real data (4 / 2 cycles, ~90–100 min each).
/// v12: nocturnal nadir INSTANT (`sleeping_hr_nadir_ts`) added so the card shows
/// "NADIR @ HH:MM" instead of "@ -"; seam-side, getDayStrain now routes the
/// cross-day EWMA-ACWR `load` to the strain detail. Full seam↔screen audit.
/// v13: computable gaps filled — HRV stability (CV) + Poincaré irregular-beat
/// screen (pipeline), and engine-injected blocks: wear segments, waking
/// daytime-HRV timeline, nocturnal restlessness, and sleep periods (main+naps).
/// v14: trend scalars for sleep-stage minutes (rem/deep/light/tst) + lf_hf +
/// hrv_cv (→ metric_series); per-5-min day `activity_curve` for the "Your day"
/// timeline. (Peak/lowest-HR + their @times are computed seam-side from the HR
/// curve, no derived change.)
/// v15: efficiency + worn_min scalars → metric_series (sleep-efficiency & wear
/// trends); + _trendKey fixes (resting_hr→rhr, skin_temp→skin_temp_z, sleep→tst_min).
/// v16: ADDITIVE analytics surfaced into the bundle — (a) an Edwards zone-sum
/// "effort" strain beside the 0–21 headline: NEVER SHIPPED, and removed
/// entirely at v68 — no producer was ever written, so `strain_effort` was a
/// permanently-null key in `metric_series`; (b) top-level `baselines` block: Winsorized-EWMA personal baselines (rhr/hrv/resp) with
/// z/delta/ratio + cold-start status; (c) `advanced_sleep` block: a 4-class
/// Cole–Kripke/DoG stager's main-session AASM metrics + hypnogram (parallel
/// ESTIMATE; the single-source `sleep` block stays the headline). Bumping
/// re-derives non-finalized recent days so the new blocks populate.
/// v17: STEPS (24/7 ESTIMATE = ambulatory-minutes × cadence, personalized by the
/// live 100 Hz pedometer's cadence calibration) + TOTAL DAILY ENERGY (TDEE via
/// HR-flex: Mifflin BMR floor + active Keytel surplus). New scalars `steps` +
/// `calories_total` → metric_series; `steps`/`calories_total` bundle blocks. 1 Hz
/// still can't COUNT steps (Nyquist) — real counts come from live streaming, which
/// also tunes this estimate. Bumping re-derives non-finalized days so they fill.
// v20: principled nap detection (van Hees immobility + HR-dip) → `naps` block +
// `nap_min` scalar; cross-day Sleep Coach (need/bedtime/cycle-wake/performance),
// Strain Coach (recovery-gated target), VO₂max + Fitness Age, all in the crossday
// bundle.
// v21: all-day HRV line (`series.hrv_day`, epoch rolling RMSSD over 24/7 RR).
// v22: all-day RESP line (`series.resp_day`, rolling RSA br/min) + relative
// SKIN-TEMP trend (`series.skin_temp_day`) for the Timeline graph.
// v23: all-day HRV (`series.hrv_day`) now rejects ectopic/missed-beat pairs
// (Malik 20% rule) + clips to ≤220 ms, killing the non-physiological 400+ ms
// spikes.
// v24: picks up the analytics sleep-algorithm rewrite (multi-session detection +
// bridging + main-session pick via AdvancedSleepStager). Bumping re-derives
// non-finalized days so past nights restage; "Re-analyze data" restages all.
// v25: 24/7 irregular-rhythm SCREEN (day-span RR → `irregular_rhythm_flag` +
// notification), heart-rate recovery (HRR) per auto-detected bout → `hrr_bpm`,
// breathing-rate variability (`brv_cv`/`brv_slope`), opt-in auto-workout
// SUGGESTIONS (workout_suggestions table + notification), and low-confidence
// WRIST ORIENTATION during sleep (NOT body position). Bumping re-derives
// non-finalized days; "Re-analyze data" restages all.
// v26: integration bump — the oxygen/workout PR externalized active-calorie
// compute to `Calories.activeEnergy` (Keytel + height term) without a version
// bump; combined with the v25 features above, bump so finalized days recompute
// onto the new calorie formula instead of silently carrying the old values.
// v27: WEAR fix — worn-time / coverage / on-off segments were defined as hr>0,
// which misreads daytime PPG drop-out as off-wrist and collapsed a 24 h-worn day
// to ~the sleep window (~7-8 h). Wear is now RECORD presence (gap-detected), in
// both the `worn_min` scalar (onehz_pipeline) and the `_wearBlock` detail. Bump
// so finalized days recompute the corrected wear ("Re-analyze data" restages all).
// v28: SLEEP rescue — manual sleep entry + HR-led fallback. When accel-led
// detection finds nothing, an HR-dip fallback now proposes a window (source
// 'auto_fallback', low confidence); a user can type/confirm a window
// (sleep_override table → source 'manual'/'confirmed') which force-derives even
// a finalized day. Bump so fallback-eligible days restage.
// v29: COUNTER-RESET RECOVERY. The decoded substrate now dedupes by timestamp
// (rec_ts, newest-wins) instead of by the strap counter, which resets on reboot
// and silently quarantined every post-reboot day (empty "today", strain –). The
// DB v17 migration (_rebuildCanonicalDecodedStore) rebuilt decoded_onehz/
// decoded_rr time-keyed, the write path REPLACEs on rec_ts, and the substrate
// loader falls back to decoding raw_records directly for ranges whose decoded
// rows are absent — so previously-quarantined days now have data. Bump so those
// days (and any finalized day derived while data was missing) recompute against
// the recovered substrate.
// v32: SLEEP-STAGE fix — the REM detector depended on a respiration signal
// (`resp`) that no real caller ever supplied (WHOOP 4's R24 record has no
// respiration-ADC channel), so it was unconditionally NaN and the primary
// REM rule could never fire — nights collapsed to almost-all-light. Also
// resolved a three-implementation ambiguity (`cardioStager` vs
// `AdvancedSleepStager` v1/v2 — only v1 was ever actually wired, despite
// `cardioStager` being the one documented as fixing Walch 2019's WAKE-bias)
// via a head-to-head comparison; `cardioStager` (StagingMethod.cardio) is now
// the wired default. ALSO in this same (unshipped) bump: `dailyStepEstimate`'s
// doc had always promised a "run of >= minBoutMin consecutive ambulatory
// minutes" bout gate that was never actually implemented — every minute that
// individually passed the ENMO+HR gate summed directly into steps, so a
// handful of scattered, non-contiguous minutes overnight (a brief HR lift
// during a turn-over) could report several thousand phantom steps the moment
// someone woke up having never walked. `minBoutMin` (default 3) is now a real
// gate. Bumping re-derives non-finalized days so past nights/days restage;
// ALREADY-FINALIZED history needs "Re-analyze data" to pick up BOTH corrected
// staging and corrected steps — this is the one bump so far where that's
// worth actually telling users about, since it affects months of history,
// not just going forward.
// v37: SLEEP-STAGE fix #2 (real-device root cause, not synthetic) — v32 fixed
// the dead REM path but a real overnight capture showed cardioStager still
// massively over-called WAKE (~6h on a night truth was ~3min) and under-
// called REM (~40min vs a ~2h42m truth). Root cause: BOTH the motion
// ("gravity 1 g reference") and HR ("sleeping HR baseline") features were
// single WHOLE-NIGHT scalars. This real device's decoded gravity-vector
// magnitude is NOT perfectly orientation-invariant — different STATIC sleep
// postures read up to ~13% apart in |accel| despite near-zero within-epoch
// variance (i.e. genuinely still), so 389/421 "big move" epochs that night
// were this artifact, not real movement, and produced WAKE blocks too long
// for Webster rescore to bridge back. Separately, the whole-night HR arousal
// threshold misread the sleep-onset HR-decay transient (elevated HR for the
// first ~60-90 min while settling) as sustained arousal. `cardio_stager.dart`
// now computes both references as LOCALLY-ADAPTIVE rolling windows, plus a
// local p25 (not median) floor specifically for the REM gate — REM recurs on
// ~90 min ultradian cycles and is a minority of any local window, so a local
// MEDIAN self-dilutes from REM's own periodic elevation. Verified on the real
// capture: wake 294->1 min, light 173->337 min, deep 26->58 min, rem 41->139
// min, against an Apple Watch Ultra ground truth of wake=3 light=330 deep=38
// rem=162 min for the same night. Bump so this genuinely different (much more
// accurate) staging recomputes; "Re-analyze data" needed for finalized nights.
// v38: audit-fix sweep, two changes actually touch output. (1) analytics'
// `readinessLnRmssd` was including tonight's own value in its own baseline
// window (`historyLnRmssd.sublist(start)` ran to the end of the list instead
// of stopping before it) - pulled the mean/sd toward tonight, understating
// how far off a genuinely suppressed/elevated night reads, worst exactly
// when the window is smallest. Now strictly prior nights only, changing
// `readiness_lnrmssd`'s z/cv/value for every day. (2) day windows here used
// `_localDayLabelToSec(day) + 86400`, assuming every local day is exactly
// 24h - wrong on the two DST-transition days a year (23h/25h), which could
// clip or over-include a day's substrate window right at the boundary. Now
// `_localNextDayLabelToSec` asks DateTime for the actual start of the next
// day. Bump so recent days recompute onto the corrected readiness baseline;
// only matters for history on the rare day that crossed a DST transition.
// v39: night-tail sleep runs shorter than the 60-min standalone floor are no
// longer dropped when they continue the overnight chain (advanced_stager
// detectSleep) — a pre-dawn arousal that split off a <60-min tail was
// truncating the sleep-window offset at the arousal. Bump so affected days
// recompute the corrected (later) offset and downstream sleep/readiness metrics.
// v42: PERSONALIZED, self-improving cardio stager. (1) REM feature upgrades in
// cardioStager — LF/HF from the RR Lomb–Scargle spectrum + R(k)=mean|ΔIHR|,
// OR-combined with the RMSSD drop and gated by atonia + an HR floor (recovers
// under-called REM), plus a 3-epoch median flicker filter. (2) A rolling
// per-user sleep profile (baselines key `sleep_user_profile`) EWMA-folded after
// each finalized night and blended (bounded ≤0.5, growing with nights, 0 at
// cold start) with tonight's per-night-local baselines — so staging gets better
// over time while per-night-local always leads. Deep stays a low-confidence
// NREM sub-split (deep_low_confidence). The profile self-seeds across this
// re-derivation sweep; no explicit migration. Bump so every day re-stages.
// v43: readinessComposite now falls back to a mean/SD z when the robust (median
// +MAD) z is degenerate (MAD==0 on a tightly-clustered quantized baseline —
// whole-bpm RHR / integer skin-temp ADC), which was intermittently blanking the
// whole readiness score to "—" on nights that had valid sleep. Bump so days that
// were previously absent-for-that-reason recompute a real score.
// v44: two consistency fixes; neither changes a scalar that a previously
// FINALIZED day_result already had right, but both affect data availability/
// consistency going forward. (1) A day whose offloaded second-half compute
// (naps/workouts/HRR/wear/curves/wake-features) failed or timed out — but
// whose headline scalars (readiness/RHR/RMSSD) already succeeded — could get
// marked finalized and treated as fully "derived" by the raw-pruning guard,
// permanently losing the raw substrate needed to ever fill in those missing
// fields on retry. Now tracked via a new `partial` day_result column and
// excluded from both age-based finalization and the pruning guard until the
// second half actually completes. (2) The wake_day_features early-read
// artifact (what the Today repo shows before the full day result is ready)
// was copying the pre-hybrid-correction 1Hz-only step/calorie estimate
// instead of the corrected real-100Hz+1Hz hybrid value computed moments
// later in the same pass — the final day_result was always correct, only
// this transient early read was stale. Bump so any day currently sitting
// non-finalized re-derives with both fixes in effect.
// v45: cardioStager REM LF/HF hot-path fix. `_windowRemFeatures` fed ABSOLUTE
// epoch seconds (~1.75e9) into the per-30-s-epoch Lomb–Scargle, forcing every
// sin/cos onto libm's __kernel_rem_pio2 multi-precision slow path. Over a full
// night (~1000 epochs × 240 freqs × ~180 beats × 2 loops) that is tens of
// millions of slow-path trig calls — and because v42 runs staging on the MAIN
// isolate (for the ambient profile blend), it landed on the UI thread and
// produced recurring multi-second freezes → Android ANRs (Crashlytics 0.9.13:
// libm.so __kernel_rem_pio2 / sin / cos, "slow operations in main thread").
// Fix rebases beat times to the window start; L-S is time-shift invariant so
// LF/HF is unchanged in exact arithmetic (only last-ULP float differences, which
// is why a bump is warranted). Bump so non-finalized days re-stage on the fast
// path. Paired with this: `_sleepCandidateForDay` now runs the whole staging +
// profile-fold on a WORKER isolate (the analytics ambient profile globals are
// re-armed inside the `Isolate.run` closure and returned as plain JSON) instead
// of the main/UI thread — so the residual staging CPU no longer blocks the UI
// even before the ~10× trig win.
// v46: readiness-blank-"—" fix — `_seriesMean` trailing-28 window fix +
// analytics re-pin picking up the `robustZ`->`z` fallback (v43 above,
// analytics#26) so quantized baselines with MAD==0 stop intermittently
// blanking a legitimate score.
// v47: readiness's RHR input (`rhrToday` in onehz_pipeline.dart) no longer
// accepts the `rhr` metric's daytime-HR fallback — it now requires an actual
// detected sleep session (`hasSleep && sleepHr.isNotEmpty`), matching how
// HRV/resp/temp were already gated. Previously a no-sleep day could still
// produce a full numeric readiness score off RHR alone (a few minutes of live
// daytime HR masquerading as overnight resting HR), which is how a fresh
// install could show "Readiness 100" ~10 minutes after first wearing the
// strap. Also removed `getDayStress`'s `100 - readiness` fallback in
// local_repository_impl.dart — it fabricated a stress-looking number whenever
// the real Baevsky SI was absent, violating the never-impute rule; the UI
// already correctly renders "—" when `score` is null. Bump so affected days
// re-derive without a same-day, no-sleep readiness/stress score.
// v48: audit sweep across compute + the sibling analytics package.
//
// EDGE-LOCAL changes, which ship the moment this constant lands:
//   - The per-sweep baseline snapshot is genuinely frozen. `appendScalars` is
//     gone; the history is dated and loaded once, and `valuesBefore(key, date)`
//     excludes the target day from its own baseline. A re-derive sweep could
//     previously append each finished day back into the shared window and evict
//     a real old day, collapsing median/MAD toward duplicated recent values —
//     the same pollution shape edge#108 fixed on the load path.
//   - A day is no longer allowed to sit inside its own readiness baseline, and
//     lnRMSSD no longer double-appends today.
//   - `nocturnalRhr` is now fed the positionally-dense day series instead of a
//     compacted one, so its 30-minute window is real wall-clock again.
//   - Profile imputation (age 30 / 70 kg / sex m / RHR 60) no longer persists
//     strain, calories and zones as if they were measured.
//   - SRI no longer drops the one hypnogram segment per night that crosses
//     local midnight; CTL/ATL/TSB now sees a calendar-dense series so fitness
//     and fatigue decay across rest days.
//   - Historical days resolve their timezone offset at their own timestamp
//     rather than through today's offset.
//
// SIBLING-PACKAGE changes ride along with this bump: the analytics sweep from
// the same review (sleep no longer reporting a no-data window as light sleep,
// the Lipponen-Tarvainen threshold on the signed dRR series, abstention on
// degenerate dispersion, the reconciled TRIMP stack, circular social jetlag)
// and the protocol decode fixes. This was NOT true when v48 was first written —
// pubspec.yaml still pointed at the pre-fix SHAs then, and this note said so.
// The pins were moved as part of v49; see the pin-status note above it.
// v49: steps/activity rebuilt on a calibration-invariant feature.
//
// Diagnosed on a real user database: the day reported 39,384 steps against a
// true value of ~2,000. ENMO is `mean(max(0, |a| - gRef))` and gRef is
// auto-calibrated per day from the stillest samples — which are the long sleep
// block, where the wrist sits in a different orientation. gRef came out at
// 0.9797 that day vs ~1.032 on every other, and since ENMO subtracts it from
// every sample, a reference 0.05 g low adds 0.05 g to every minute: exactly the
// 0.05 g walking floor. Sweeping gRef over the identical samples gave 42,155
// steps at 0.97 and 0 at 1.02 — the signal and the calibration error are both
// ~0.05 g, so no threshold could have fixed it.
//
// The analytics package now decides activity from the per-axis high-passed
// dynamic amplitude (gravity is DC in the sensor frame; any per-axis offset or
// gain error cancels exactly), anchored on a PERSONAL floor pooled from
// trailing days rather than an absolute constant or a same-day baseline — both
// of which were measured to fail, in opposite directions.
//
// Edge side of that change:
//   - `dyn_p90` joins the baseline series: each day persists its own high
//     quantile of the dynamic amplitude, and the next day's derive takes the
//     MEDIAN across trailing days (self-excluded, like every other baseline) as
//     its floor. Below the minimum history the estimator ABSTAINS — a day with
//     no personal baseline now reports the real 100 Hz count only, instead of a
//     fabricated 1 Hz number.
//   - `active_min` is persisted as a first-class series. Minutes are what 1 Hz
//     can resolve; steps are derived from them as a range.
//   - The steps bundle carries the range + the floor used, and says plainly
//     when the 1 Hz estimate is absent.
//
// This bump also re-derives days whose stored step figure came from the old
// estimator.
//
// PIN STATUS: as of this bump pubspec.yaml points at the analytics and protocol
// PR-branch commits, so everything described in v48 AND v49 is genuinely in the
// build — the edge code physically cannot compile against the older analytics
// pin, which is how we know. Those pins must move to the merge commits (and
// this must bump again) when the sibling PRs land. Verify any analytics claim
// made here with `git show <pinned-sha>:<file>` before trusting it; a changelog
// citing a change the pinned SHA never contained is how v43 documented a
// readiness fix that stayed broken for three releases.

// v50: the sibling PRs merged; pubspec.yaml now pins the resulting `main`
// commits (analytics f5ccae6, protocol a98cd70) instead of the PR-branch heads
// v49 briefly pointed at.
//
// A version bump is required even though no edge SOURCE line changed with it.
// kAlgoVersion identifies the code that PRODUCED a day_result, and that code
// includes the pinned siblings: a device holding v49 rows built against the
// PR-branch SHAs must re-derive against the merged ones rather than serve them
// as equivalent. Treating "same content, different commit" as not worth a bump
// is the assumption that lets a stale bundle survive a dependency change.
//
// Verified at the merge commits themselves, not inferred from the PRs being
// green: steps.dart carries the new step API, rr_correction.dart has the
// signed-dRR `seg.add(x[k])`, advanced_stager.dart has maxAccelCarryForwardSec,
// live.dart has kKnownRecordVersions.

// v51: edge#170 — autoDetectWorkouts' motion-confirmation gate (tuned for
// arm-swing activities) silently dropped every low-limb-swing cardio window
// (cycling/rowing: the wrist stays still on a handlebar/oar) no matter how
// strong the HR signal was. analytics#32 (PR-branch head, pinned above —
// repin to main once merged) adds an HR-ONSET bypass: the gate is skipped
// only when mean bpm over the candidate's first 3 min rises >=25 bpm versus
// the 3 min immediately before it (Whipp & Wasserman 1972 phase-II kinetics),
// which fires on genuine exercise starts but NOT on slow-drifting elevations
// (fever/heat/anxiety) that have no discernible onset — so this changes which
// suggestions autoDetectWorkouts emits without loosening the false-positive
// gate it exists to protect.
// v52: the rolling per-user sleep profile (`sleep_user_profile`) was folded on
// EVERY staging pass for a day, not once per day — a real 12-day export carried
// `nights: 1348`. Two consequences, both bad: `personalWeight` pinned at its
// 0.5 cap from the first sweep, and an EWMA collapsed onto whichever day was
// re-derived last. Replaying that profile against the same 11 nights moved wake
// 4.3% -> 36.4% and deep 1.9% -> 0.0% on the worst night, i.e. the
// personalization layer was re-creating the wake over-call cardioStager exists
// to avoid. Fixed by (1) folding at most once per day_id (tracked in the
// profile payload), (2) withholding the profile from staging until
// kMinNightsForSleepProfile nights (van der Aar 2025: gains need >=3 nights and
// ~17.5% of subjects get WORSE from personalization), and (3) discarding
// pre-tracking profiles, which cannot be repaired, so they rebuild honestly.
// Bump so every day re-stages without the corrupt blend.
// v53: repin analytics to main @ #34 — the sleep-stager decision layer is
// rewritten. Deep and REM were boolean conjunctions AND-ing one informative
// axis with one null one (rmssd, Cohen's d -0.13 deep / -0.02 REM) and one
// INVERTED one (mean HR, d +0.31 for deep, i.e. deep sleep runs slightly
// FASTER than light on the wrist), so all three could only co-fire by
// coincidence — which is why deep sleep came out as isolated 30-second specks
// that the 3-min minimum-bout rule then deleted. Scored against 99 PSG-labelled
// wrist nights those rules managed kappa 0.036, with deep PPV 5.7% against a
// 4.5% base rate and REM 12.1% against 14.0% — at or below chance for both.
// Now weighted robust-z scores (weights = the measured effect sizes) over
// Rk / hrSd / sdnn / lfhf, with rmssd and mean HR dropped: kappa 0.128, 0.132
// on held-out subjects, deep 53.0/12.9 and REM 52.6/20.7 sens/PPV. Every day's
// hypnogram, stage minutes and sleep-derived scalars change, so every day must
// re-derive. Also picks up the protocol realtimeRr bound (live HRV no longer
// sees implausible sub-100ms "beats" from a misaligned 0x28 frame).
// v54: NOOP CSV imports now bank the export's `step_counter` as REAL steps.
// NOOP's schema gained a `steps` stream (and a `band_sleep_state` column that
// shifted event_kind/event_payload) — the importer read columns by name so it
// never misparsed, but it dropped `steps` into its default branch and every
// imported day reported steps = 0 while the band had actually counted them
// (2,572 over the 3.5 h in the OpenStrap/edge#160 export). The counter is now
// differenced into contiguous runs and written to `live_coverage`, the same
// table the live 100 Hz pedometer uses, so imported and live days count steps
// identically and the 1 Hz estimate still cannot double-count those minutes.
// Only the `steps`/`active_min` block of IMPORTED days changes; no live-sync
// output moves. NOTE this bump does not retro-fix an existing import — imported
// days are force-finalized snapshots with no stored raw to recompute from, so
// an already-imported day needs a re-import to pick its steps up.
// v55: NAPS. Daytime naps were "detected" by the NOCTURNAL detector, which
// rejects them on purpose — `AdvancedSleepStager.minSleepMin = 60` exists so
// "daytime naps and stray still-blocks stay excluded", and anything centred
// 11:00–20:00 local additionally needed ≥90 min plus an HR dip. So the 20–45
// min afternoon nap was STRUCTURALLY undetectable, and `detectNaps` advertised
// a 20-min floor it could never reach, returning an empty list with a
// reassuring (and false) "no qualifying naps (20 min–3 h)" note.
//
// SIBLING (analytics): new `sleep/nap.dart` — the only nap source. Enumerates
// every van Hees z-angle immobility bout on the complement of the main sleep
// window (an ANGLE, so it does not inherit the ~13% |accel| spread across
// static postures), requires an HR dip against the AWAKE-DAYTIME baseline
// rather than a night-dominated whole-day median, and reports TST and in-bed
// separately. No sleep-stage claim: a 30-min nap holds no complete cycle and
// the daytime HR duty cycle will not support a 4-class partition. The shared
// immobility primitive is factored out as `immobilityMask` so night and nap
// run one implementation. Specifics worth knowing:
//   - The awake baseline excludes the main sleep AND every detected bout. It
//     cannot include the candidate's own seconds or the hours of tonight's
//     sleep the nap window borrows, or the dip gate becomes self-suppressing —
//     the quieter the sleep, the lower the bar it must beat.
//   - Under 10 min of awake HR, the day is not judged at all. A median over a
//     handful of samples is not a baseline, and every verdict hangs off it.
//   - Durations are WALL CLOCK, not sample counts. The substrate is a
//     positional array with pruning/sync holes, so a run also breaks at a
//     timestamp discontinuity; otherwise an unobserved hour reads as unbroken
//     stillness and 20 min of evidence reports a 2 h nap.
//   - Deferral is CHAIN-aware. Deferring only the bout that touches the array
//     end is not enough: an ordinary 6-min awakening at 01:50 splits tonight's
//     sleep, and only the trailing half touches the end. Every bout chained to
//     an unfinished one (within napChainGapSec) is unfinished too.
// Verify the analytics pin actually contains this before shipping the bump
// (AGENTS §3.5).
//
// EDGE-LOCAL changes, which ship the moment this constant lands:
//   - `_sleepPeriods` no longer runs its OWN nap detector (20-min stillness
//     runs). That second notion disagreed with `detectNaps` on real days —
//     the committed `payload.json` shows a 21-minute period alongside
//     `naps.count: 0` — and fed a different screen. One source now (§3.8).
//   - Periods speak the contract the Sleep-periods screen actually reads
//     (`onset_ts`/`wake_ts`/`duration_min`/`efficiency`), which it never did:
//     every nap card rendered "0m" with a red confidence dot regardless of
//     what was detected. `duration_min` is minutes ASLEEP for both the main
//     sleep and naps, which were previously different units under one label.
//   - `nap_min` is TST, not the in-bed span. It is subtracted 1:1 from sleep
//     need, so crediting in-bed minutes over-credited every nap by its awake
//     time and always erred toward recommending LESS sleep.
//   - An unfinished bout is DEFERRED, not emitted (see the sibling notes). With
//     a 3 h post-midnight buffer the first hours of TONIGHT'S sleep were being
//     written as a multi-hour "nap" for the day that was ending, then counted
//     again as tomorrow's main sleep.
//   - The main sleep period's TST/efficiency are carried into the day-blocks
//     isolate. That isolate builds its own `scMap` seeded with `rhr` alone, so
//     reading `scMap['tst_min']` there yields null forever — which would have
//     made every main-sleep card read "—". Efficiency is normalized from the
//     stored percent to the 0..1 the card contract uses.
//   - `total_asleep_min` is null when any listed period's minutes are unknown.
//     Summing a null as 0 printed a confident total short by exactly the part
//     we could not measure, and the hero arc divides by it.
//   - `sleep_coach.nap_credit_min` is the credit ACTUALLY applied, not the raw
//     nap minutes: `sleepNeed` clamps to [6 h, 11 h] after subtracting, so a
//     large credit is only partly realized.
//   - Today-scoped reads require an explicit `is_today` stamp on the cross-day
//     record. Taking the last record positionally is yesterday on any day whose
//     row has not been derived yet.
//   - Off-wrist and charging spans are passed to the detector from the strap's
//     own WRIST_OFF/WRIST_ON and CHARGING_ON/OFF events. These were decoded
//     and persisted to `band_events` all along and never used; a band on a
//     table or charger is motionless and is the dominant nap false positive.
//   - Absent ≠ zero: when nap detection cannot judge a day, `nap_min` is left
//     UNWRITTEN, and the sleep-need credit reads TODAY only. It previously
//     fell back through `_lastNum` to YESTERDAY's nap minutes (§3.3).
//   - `sleep_coach.nap_credit_min` exposes the credit that was subtracted, so
//     the coach card can show it instead of silently shrinking the ring.
//
// Days re-derive so naps, nap_min, sleep_periods and sleep need are rebuilt.
// v56: the STRAIN half of the same today-scoping bug. v55 fixed `nap_min` but
// left `sleep_coach.need`'s other today-scoped input reading through
// `_lastNum`, so a day whose strain compute abstained built tonight's strain
// bonus out of an EARLIER day's workout — the identical §3.3 imputation, in the
// identical function, two lines apart. Measured on a 7-day fixture: a carried
// strain of 18 inflated `need_sec` by 2314 s (38.6 min) over a today-abstained
// day. Now `_todayNum`.
//
// Direction note, because it differs from v55 and the difference matters: naps
// are SUBTRACTED and strain is ADDED, so while both inputs floor at 0, that
// floor is an upper bound on need for naps and a LOWER bound for strain.
// Abstaining to 0 strain therefore recommends up to 45 min LESS sleep, not
// more. It is still correct — carrying yesterday forward is not a safety margin
// but noise around the true value (it inflates need only when yesterday
// happened to be harder than today), and strain is a same-day accumulating
// quantity that genuinely starts at 0 — but it is not the cautious direction.
// Because it is not, it is not allowed to be silent either:
//   - `sleep_coach.strain_bonus_min` reports the minutes the bonus ACTUALLY
//     added, measured like `nap_credit_min` (re-run with strain zeroed and
//     diff), so the [6 h, 11 h] clamp cannot make the card claim an increase
//     `need_sec` never took.
//   - It is NULL, never 0, when today produced no strain reading. A confident 0
//     says "you rested"; null says "we could not measure today's strain, so
//     tonight's need is short by up to 45 min". Collapsing those would re-hide
//     exactly what the today-scoping fix exposed.
//   - The Sleep Coach card renders the applied bonus as a "+Xm added for
//     today's strain" line (`strainBonusCaption`), mirroring the nap credit.
//     The card stays SILENT on null, matching the nap precedent — surfacing
//     "today's strain was not measured" to the user is a product decision, and
//     the bundle carries the distinction for whoever takes it.
//
// Days re-derive so sleep need, bedtime, wake and sleep performance are rebuilt.

// NOTE ON NUMBERING: v55 and v56 above are the nap/strain work (PR #204),
// which merged first. The three entries below are this branch's, renumbered
// from 55/56/57 to 57/58/59 so the constant stays STRICTLY MONOTONIC. That is
// load-bearing, not cosmetic: the derive gate matches algo_version EXACTLY
// while the read seam serves MAX(algo_version), so a version that goes
// backwards writes rows nobody reads and re-derives forever.
//
// v57: THE 1 Hz STEP ESTIMATE IS DELETED. Steps are now real-measured only.
//
// Diagnosis on a real user DB (2026-08-03): the app reported 2,645 steps for a
// day the user took under 400. It was 23 "active minutes" x an assumed 115 spm.
// Both halves of that conversion are invalid at 1 Hz, and neither is fixable by
// re-tuning:
//   * Cadence is NOT IDENTIFIABLE. Gait is 1.4-2.3 Hz (Straczkiewicz 2023,
//     doi:10.1038/s41746-022-00745-z); at 1 Hz every fundamental is sub-Nyquist
//     and 80/100/140/160 spm alias to the same 0.333 Hz. No published step
//     detector exists below 10 Hz.
//   * The minutes were never specifically ambulation. At the wrist, arm work
//     out-accelerates walking (stirring ~104 mg, chopping ~139 mg vs walking
//     ~66 mg ENMO), so a movement threshold cannot isolate gait even at full
//     rate: wrist devices emit 22-27 false steps/min during dishes, reaching
//     and driving (O'Connell 2017, doi:10.1371/journal.pone.0169616) while
//     detecting slow walking at sensitivity 0.05. The two errors have OPPOSITE
//     sign, so no gain constant corrects both.
// Confirmed against this DB's own ground truth: the single window where the
// 100 Hz pedometer and 1 Hz overlap had HR 95->108 and dynAmp 0.31-0.40 g, and
// the REAL count was 11 steps in 3.1 min (3.5 spm) where the estimator would
// have assigned ~115 spm.
//
// What changes: `scalars.steps` is now ABSENT unless a gait-capable source
// measured the day (band 100 Hz, phone pedometer, or a NOOP import — all in
// `live_coverage`). Days with no such source lose their step number entirely
// rather than showing an invented one. `active_min` survives as an explicitly
// NON-locomotion movement-volume index (bundle key `movement`) and is no longer
// coverage-excluded, since there is no longer a step total it could double-count
// into. Steps also stopped being written to Apple Health / Health Connect, both
// because the old value was fabricated and because we now READ the phone's own
// pedometer from that store and must not feed our copy back to ourselves.
// Every day's steps/active_min move, so every day must re-derive.
// v58: movement minutes rebuilt on MEASURED evidence. Every change below was
// proven against 4 days of this user's real 1 Hz substrate before being made;
// two proposals were REFUTED by the same tests and deliberately NOT built.
//
//   * HR GATE DELETED. `restingHr + 8 bpm` changed active minutes by exactly
//     ZERO on every day tested. At RHR ~62 it sits at ~6% of heart-rate
//     reserve — below every ACSM band — and 73-100% of covered minutes already
//     cleared it. It also failed in the wrong direction: PPG HR is least
//     reliable during the motion being gated, so a dropout deleted minutes the
//     accelerometer measured fine. `dailyActiveMinutes` no longer accepts HR.
//   * x3 CEILING DELETED. It rejected ZERO minutes on all 4 days with
//     0.42-0.55 g of headroom, and cannot fire on artifacts (a 3 s knock
//     averages ~0.23 g, below the FLOOR). The only thing it could ever exclude
//     was a genuinely hard session.
//   * FLOOR IS NOW FROZEN after a 14-day enrollment, not recomputed daily. A
//     threshold derived from the signal it thresholds cancels the trend it
//     exists to report: scaling a real day's dynAmp gave 37 active minutes at
//     1x, 1.5x, 2x AND 3x activity when recomputed, versus 23 -> 254 frozen.
//     Re-freezes only on device/wrist change, a 30-day wear gap, or 365 days.
//   * NOT BUILT (proven unnecessary): accel autocalibration — offset and
//     uniform gain cancel exactly through the high-pass and the floor
//     normalisation (+5% gain moves the gate decision by 0.0000); only
//     anisotropic gain survives at ~1-3%. And gravity/forearm orientation —
//     it solved the ambulation problem v55 deleted. A sleep-anchored floor was
//     also tested and REFUTED: CV 138.6% across days vs 9.3%, and on one night
//     it landed above the entire day's range (would report zero).
//   * SEMANTICS CORRECTED. The R24 1 Hz accel field is a fused GRAVITY vector,
//     not acceleration: across 269,486 real samples ||a|| is p50 1.027 g with
//     0.030% above 1.3 g, and during the single most vigorous minute of a day
//     it was 1.033 g +- 0.006 (0 of 420 samples above 1.2 g). So `dynAmp`
//     measures how fast the wrist RE-ORIENTS, not how hard it accelerates, and
//     ENMO/MAD over this substrate are ~(1.03 - gRef): a pure calibration
//     artifact with zero signal. That is the true root cause of the original
//     42,155-steps-at-gRef-0.97 / 0-at-1.02 collapse.
// active_min moves on every day; steps are unaffected by this bump.
//
// v59 - review follow-up: the ABSENT `steps` block stops labelling itself. It
//   carried `tier: 'ESTIMATE'` alongside `value: null`, and `Metric.parse` maps
//   that tier to `beta: true`, so a day with no measurement at all rendered the
//   estimate badge. Absent now means absent: `tier: null` (parsing to
//   MetricTier.unknown) and an empty `inputs_used`. No VALUE changes, but the
//   persisted bundle does, so days derived at v58 must be re-derived to pick it
//   up. `ABSENT` was deliberately NOT invented as a fifth tier — `Tier.all` in
//   analytics is a closed set of four published grades.
//
// v60 - the all-day HRV and respiratory curves advance their cadence cursor on
//   every ATTEMPT rather than only on a successful estimate. `_dayRespCurve`
//   left `lastEmit` unset whenever rsaRespRate came back absent — and absent is
//   the EXPECTED daytime case, because daytime RSA is movement-confounded — so a
//   confounded stretch re-ran the triple Lomb-Scargle once per beat instead of
//   once per five minutes. That is what exhausted the 90 s day-blocks budget and
//   left days persisted headline-only. `_dayHrvCurve` had the same shape plus an
//   O(window) sum that ran before its cadence gate was checked. Both curves keep
//   their sampling intent; points that were previously emitted a beat or two
//   after a failed attempt now land on the next cadence tick instead.
// v61 - NAP EDITS. The nap detector's answer is now a PROPOSAL: a nap the user
//   logged is added, and one they rejected is suppressed, replayed over the
//   detector's output on every derivation rather than written into it (so a
//   better detector later still respects "there was no nap here"). Rejection
//   matches by OVERLAP, not by exact bounds, because the detector's boundaries
//   shift between runs and an edit that stopped applying when a boundary moved
//   by a minute would be worse than useless.
//
//   This moves numbers, which is why it is a version bump rather than a read
//   path: `nap_min` is summed over the merged list, so a logged nap credits
//   against sleep need and sleep debt exactly as a detected one does — that
//   was the explicit product decision, not an accident of where the code sat.
//   Days carrying an edit are force-derived alongside sleep-override days, so
//   an edit to an already-finalized day actually takes effect.
// v62 - ONE CALORIE PASS PER DAY, with the wake/whole-day split made explicit.
//   The day's energy figures were produced twice, by two different pieces of
//   code, and the two did not agree.
//
//   * `calories` was summed by a derivation-local copy of Keytel
//     (`_keytelCaloriesWake`) that billed the FULL Keytel rate on every active
//     minute, while `Calories.dailyEnergy`'s active component nets the basal
//     minute out because the total already counts it. The same minute was paid
//     for twice — `calories` high by basalPerMin x active-minutes, ~70 kcal on
//     a day with one hard hour, scaling with active time.
//   * `calories_total` was then OVERWRITTEN further down the day block by a
//     second `dailyEnergy` call with different gating and a different span (a
//     flat 1440 minutes of BMR rather than the minutes actually covered), so
//     the persisted pair came from two different estimates.
//   * Both propagated: the Health export writes BASAL_ENERGY_BURNED as
//     `calories_total - calories`, so the exported basal was wrong by tens of
//     kcal/day, in either direction.
//
//   Both scalars and the TDEE bundle block now come from ONE `wakeDayEnergy`
//   pass, published in one place, so `total - active == basal` holds by
//   construction. The local Keytel copy is deleted and the duplicate
//   `dailyEnergy` is gone.
//
//   THE SPLIT, stated once so it stops drifting. `calories` is ACTIVE energy
//   over the WAKE span. `calories_total` is TDEE: Mifflin BMR pro-rated over
//   the minutes of the calendar day the substrate actually covers — sleep
//   included, because basal metabolism does not stop overnight — plus that same
//   active surplus. Feeding the whole-day series to the active term bills sleep
//   as exercise: `dailyEnergy`'s HR-flex gate is 0.50 x Tanaka HRmax, i.e.
//   104 - 0.35*age bpm, only 79.5 bpm at age 70, so an older sleeper's ordinary
//   nocturnal heart rate clears it for the whole night. `onehz_pipeline`'s
//   early-read `calories` is the same active-over-wake quantity off the same
//   series; `wakeDayEnergy` is canonical and the pipeline mirrors it.
//
//   SAME BUMP, second change: the day's calories now require a real HEIGHT and
//   go absent without one. `dailyEnergy` defines active as the SURPLUS over the
//   Mifflin basal minute, so the Mifflin height term sits inside the active
//   figure as well as the total — standing 170 cm in for an unknown height
//   moves both. On a 35 y / 80 kg male with 600 wake minutes at 130 bpm, 150 cm
//   against 195 cm is active 6500 vs 6383 and total 8068 vs 8232 kcal. Those
//   are persisted scalars and they are exported to Apple Health / Health
//   Connect, so the stand-in writes a body the user does not have into their
//   health record. An absent input makes the dependent metric absent. A
//   height-less profile that used to get an active figure now gets none until
//   height is filled in; nothing else about the day changes.
//
//   SAME BUMP, third change: TRIMP's sex constant read `sex == 'f'` while the
//   calorie path beside it accepted 'female' too, so a profile written by the
//   profile screen (whose options are male/female/other) scored female calories
//   and MALE strain off one field. Both now go through `workoutSex`. This moves
//   strain, not just calories, for anyone stored as 'female'.
//
//   There is no fitness model here and no sleep gate on the calorie path. An
//   earlier cut of this change fed a resting-HR-derived VO2max into Keytel's
//   fitness-adjusted variant, gated on the day having produced a sleep-derived
//   resting HR. Both are gone: the estimator's error exceeds the spread of the
//   quantity it estimates, and running it made a trait metric move by tens of
//   kcal/day on ordinary night-to-night resting-HR noise. The published
//   age/mass/sex model is the only one used.
//
//   Each of these moves numbers on a derived day, hence the bump; finalized
//   days recompute onto the corrected figures.
//
//   The SESSION paths changed alongside them and carry no algo version of their
//   own, which is NOT the same as being recomputed on read. `stopWorkout`
//   writes the live figure into `sessions.calories`, and the substrate re-score
//   only replaces it when the band handed over at least 90% of the window; a
//   session whose stream came back sparse keeps the live number permanently.
//   That number changed here: the tick used to bill a bare Keytel rate every
//   second the band reported a heart rate, with no activity gate and no resting
//   floor, and now bills through the same per-sample gate, resting floor and
//   gap cap as the re-score. Already-stored sessions are left alone — they are
//   not re-derived — so the change applies from this version forward.
// v63 - RR BEATS ARE FETCHED BY rec_ts, NOT BY COUNTER SPAN.
//   The derivation pages 1 Hz frames ordered by rec_ts and then pulled that
//   page's RR beats with `decodedRrByCounterRange(first.counter, last.counter)`.
//   The strap's counter resets on every reboot, so the moment a page straddled
//   one the span was inverted or nonsensical and the query returned nothing:
//   the page decoded with an EMPTY beat list, and every beat-derived figure for
//   that stretch — RMSSD, SDNN, the HRV curve, and the readiness that leans on
//   them — silently came back absent or computed off whatever beats survived on
//   the other pages. Both tables carry rec_ts (indexed), so the lookup uses the
//   page's own rec_ts bounds and pulls exactly its beats.
//
//   Days already finalized at v62 hold those RR-less results permanently — they
//   are never revisited at the same version — so this needs the bump to be
//   re-derived onto real beats.
// v64 - THREE CHANGES TO WHAT REACHES THE 1 Hz SUBSTRATE.
//   1. R-R beats are no longer read for record versions whose field map is
//      unconfirmed. v7 carries hr at offset 27 and v18 at 14, so those layouts
//      are demonstrably not v24's, yet the beats were being read off v24's map
//      and the 200..2500 ms filter passed enough of them to hand RMSSD a full
//      set of invented intervals. RMSSD/SDNN/HRV move for any day built from
//      those versions.
//   2. A record only decodes if its packet type says it is one. The dispatch
//      keyed on inner[1], which is the version on a data frame but the sequence
//      byte on a control frame, so roughly 2 in 256 control frames decoded as a
//      trusted record — hr and an accel vector read out of log text. The
//      substrate re-decodes stored hex, so any such row is gone now.
//   3. Gen4 v25 records stay archived instead of being banked. They carry a
//      timestamp and a gravity vector and no heart rate at all, and hr is NOT
//      NULL with 0 meaning off-skin — so banking them would have asserted the
//      band was off the wrist for every one of those seconds.
//
//   day_result is keyed (day_id, algo_version), so days finalized at v63 keep
//   results built on the old substrate unless the version moves.
//
//   NOT in this bump, though both were candidates: the accel-coverage gate and
//   the R10-lite exclusion both landed at v63 already. Check the pinned SHA
//   before citing a sibling-package change here — a bump whose stated cause is
//   not in the pinned code is how a fix was believed shipped for three releases
//   while the pin never carried it.
//
// v65: THE 0–21 HEADLINE STRAIN SCALE IS RECALIBRATED.
//
//   `strainScore` was `min(21, ln(TRIMP+1)/ln(1.5))` over whole-waking-day
//   Banister TRIMP. Two things were wrong with that, and they compounded:
//
//     * Whole-day TRIMP counts every waking minute above resting, so ~16 h of
//       ordinary living accrues ~180 TRIMP before any exercise. Log base 1.5 is
//       steepest near zero, so that overhead alone bought ~13 of the 21 points:
//       on a real bundle an INACTIVE full-wear day scored 12.8.
//     * Each further point cost 1.5x the load, so 21 sat at TRIMP ~4987 —
//       roughly 35 h at 80 % HRR. The top third of the scale was unreachable;
//       a marathon read ~15.8. The whole usable range was about 8 to 16.
//
//   Strain is now the load earned ABOVE a quiet-waking baseline (20 % of HRR,
//   scaled by the wake window actually observed, so partial wear is not charged
//   a full day's overhead), mapped by 21·ln(1+u·14)/ln(15) with u = net/400.
//   Anchored on real days: inactive ~0, rest + a walk 2-4, a 45-min moderate
//   run 8-11, a 90-min hard session 14-17, 5 h at 160 bpm 21.
//
//   SAME BUMP: `strainTarget`'s recovery bands are rebased onto that
//   distribution (they asked for "recover 4-8" on a scale whose floor was 13),
//   and its fatigue/freshness tests are now ratios against CTL — they compared
//   raw TRIMP in the hundreds against thresholds of 10 and 5, sized for the
//   0-21 scale, so they fired on ordinary week-to-week noise. The intraday
//   `strain_curve` also picks up Banister's 0.64/0.86 scale coefficient, which
//   it had been dropping entirely (it accumulated a TRIMP 1.5625x the day's).
//
//   Days inside the raw-retention window re-derive from substrate on this bump.
//   Older days have no raw to re-derive from, so `strain_backfill.dart` rebuilds
//   their headline from the stored TRIMP + wake window instead — see that file
//   for why that is exact and what it deliberately drops.
// v66: THREE analytics outputs change shape or value.
//
//   1. CIRCADIAN, newly computed. `circadianNonparametric` (IS/IV/RA/L5/M10,
//      van Someren 1999) and `cosinor` (Halberg/Nelson 1979) were written,
//      tested and never called from edge. They now run in the cross-day rollup
//      over a new per-day field, `hourly_hr` — 24 local-hour HR means projected
//      from the stored `series.hr_curve`. HR, not accelerometry, because the
//      1 Hz substrate is pruned at `rawRetentionDays` and `day_result` is
//      not: no multi-day accel exists to analyse. Only runs of
//      calendar-CONSECUTIVE days whose 24 bins are ALL covered are admitted
//      (no imputation — a filled hour is exactly the smooth signal IS
//      rewards), and each family abstains with the standard
//      `need_baseline:have=H,need=N` note below its own minimum (7 days
//      nonparametric, 3 cosinor). New bundle keys: `circadian_rhythm`,
//      `circadian_cosinor`, `circadian_coverage`.
//
//   2. STEPS on gen5. `stepMotionCounter` was decoded, stored in
//      `decoded_onehz.step_count` and read back, but `Substrate` had no field
//      for it, so derivation never saw it and a WHOOP 5 user with a real wrist
//      pedometer got no steps unless they enabled the phone one. The channel is
//      now carried end to end; the counter is cumulative u16, so the day's total
//      is the sum of PLAUSIBLE positive deltas — a wrap is recovered modulo
//      65536, a reset fails the plausibility budget and contributes nothing.
//      The band counter outranks `live_coverage`; both are disclosed. Gen4 has
//      no such counter and is unaffected (its every second reads ABSENT, not 0).
//
//   3. SLEEP CYCLES gain their Metric envelope. `sleep.cycles_metric` is
//      `sleepCyclesMetric` over the same detection the raw `cycle_count` /
//      `cycles_mean_min` keys already carried, so tier and confidence are read
//      rather than asserted by the UI. The raw keys are unchanged.
//
//   ALSO on this bump: `crossDayArtifactUsableToday` now checks the
//   `algo_version` it has always stamped. It did not, so a bump that changes the
//   per-day row SHAPE (as this one does, adding `hourly_hr`) would have been
//   served the pre-bump artifact for the rest of that day.
// v67: ABSENCE STOPS READING AS A MEASUREMENT. Schema v39 makes the six sensor
//   columns of `decoded_onehz` nullable, so a record that carried no accel /
//   no optical / no thermal reading is no longer written as a real zero, and the
//   readers that consumed those zeros now see absence.
//
//   1. ACCEL. `(0, 0, 0)` has a z-angle of exactly 0.0° and an ENMO of 1.0 —
//      i.e. absent accel read as a PERFECTLY STILL wrist to active minutes, the
//      activity curve, restlessness, the sleep restlessness map and ENMO, and
//      as a motionless wrist to auto-workout detection (a missed workout).
//      `Substrate.accelPresentAt` existed and had exactly one consumer, the van
//      Hees coverage gate; every other feed now consults it too, and
//      `accelSamples()` marks absent seconds `valid: false` (which `enmoSeries`
//      and `positionSeries` already honour). Active minutes, the activity curve
//      and restlessness are now fractions over OBSERVED seconds, not over all
//      seconds — a day with accel gaps moves.
//
//   2. HEART RATE gains a physiological bound at the substrate. The gen4
//      TRUSTED decode path (v24/v12) returned the HR byte verbatim, so one
//      corrupt-but-CRC-valid byte of 250 passed the `hr > 0` filter and became
//      the day's max HR. Out-of-range now reads as the existing "no usable HR
//      this second" 0 — never clamped into the range, which would invent a
//      plausible reading. Applied here rather than in the decoder because
//      rejecting there costs the whole record, accel and RR with it.
//
//   3. `fit_quality` / `fit_warning` are GONE. They scored band tightness from
//      `skinContact`, which is not a contact measurement (it is the sign+
//      exponent half of a float32) and was a hardcoded 0 on the decoded path.
//
//   4. CPC IS WITHDRAWN, not absent. `cpc_ratio` is gone from the bundle and
//      from `metric_series`: its "respiration surrogate" was the NN series
//      itself, so the number was the RR periodogram HF/LF ratio under another
//      name (measured agreement 1.0000085). It never measured cardiopulmonary
//      coupling; it needs a real respiration channel to come back.
//
//   5. FROM ANALYTICS (verify the pinned SHA carries these before shipping —
//      the v43 lesson): `lf_hf`/`lf`/`hf`/`total` are now physical PSD in
//      ms²/Hz rather than dimensionless (0.095 → 2.20 on a synthetic) and are
//      Welch-averaged over band-appropriate segments; `ulf` is absent rather
//      than 0.0; sleep staging, the illness CUSUM and the anomaly detector all
//      moved (a real night went wake 17.5 → 26.0 min, TST 516.5 → 508.0); and
//      `round6` returns null on a non-finite input instead of passing a NaN on.
//
//   6. THREE substituted inputs stop being substituted. `hrRecovery` now gets
//      `tsSec`, so "+60 s" is clock time rather than +60 ARRAY POSITIONS on a
//      gappy tail (it overstated the drop, read as a fitness marker);
//      `enmoSeries` gets `expectedMinutes: 1440`, so coverage is not 1.0 for a
//      day worn 4 h out of 24; and the sleep coach no longer substitutes a
//      population 8 h for a missing personal OSD — need, bedtime, wake and
//      sleep performance are ABSENT until an OSD estimate exists.
//
//   ALSO on this bump: the cross-day rollup artifact is stamped with
//   `algo_version` / `built_for_day` / `built_at_epoch` so the reader can fail
//   closed instead of serving a previous version's VO₂max, fitness age, sleep
//   need, strain target and illness flags; and its encode is sanitised, because
//   ONE non-finite double used to make `jsonEncode` throw and drop the ENTIRE
//   bundle (see `sanitizeForJson`).
//
// v68 — ONE bump for the whole sweep (compute + analytics). Everything below is
// recomputed by the same derive pass this constant gates, so it is deliberately
// a single increment rather than one per fix:
//
//   1. STRAIN STOPS BEING BUILT ON A DAYTIME "RESTING" HR. The offloaded second
//      half took its TRIMP reference from `scalars.rhr`, which back then fell
//      back to daytime HR for the general resting-HR card (it no longer does),
//      and then overwrote `scalars.strain` with the result — so a day where the
//      pure pipeline abstained (`clinical.strain` "—") still published a
//      number, off an awake reference ~20 bpm high. It now reads the
//      nocturnal-only `scalars.rhr_nocturnal` (the same value readiness uses),
//      and when neither that nor a user-entered resting HR exists, strain is
//      ABSENT: the scalar is written NULL (overwriting any stale value) and
//      `clinical.strain` is stamped absent with it. Affected days lose or lower
//      their strain — that is the fix, not a regression.
//
//   2. `hrv_timeline`'s `t` is EPOCH SECONDS. It was seconds-since-the-first-NN
//      (`correctRr` re-bases its clock to 0) on a view whose contract — and the
//      coach's prompt — say epoch, so coach SQL over it returned 1970 and no
//      join to `hr_curve` could ever match. Its first point also now requires a
//      full 5-min window instead of being an RMSSD over 10 beats (~8 s) drawn
//      on the same line as the real windows.
//
//   3. `strain_effort`, `spo2` and `odi_per_hour` are gone from `metric_series`
//      (and from the coach's advertised keys). Nothing has ever produced them:
//      12 rows, 0 values, on every install. A metric this app does not produce
//      has no entry and no key.
//
//   4. The one-shot strain rescale prices the quiet-waking baseline over the
//      window the pipeline actually used (`series.strain_curve`, one point per
//      wake minute) instead of `worn_min − tst_min`, which was off by −15..+22
//      min on every real day measured. Days that cannot supply it now abstain.
//
//   5. Personal baselines withhold z/delta/ratio/in_normal_range until at least
//      one real night has been folded (analytics no longer seeds a baseline at
//      the midpoint of the metric's physiological bounds), and the resting-HR
//      percentile-of-you is oriented lower-is-better.
//
//   6. FROM ANALYTICS on this bump: `correctRr` advances its clock by the REAL
//      interval on a spline-corrected beat (it was dropping ~1 s of record per
//      correction, inflating cvhr per-hour and shortening hrvFreq's span).
//
// v69 — the sweep bump, and the repin that should have come with v67. The pins
// sat on analytics cef6fe4 / protocol 3ea0290 while every local run built the
// sibling working copies through pubspec_overrides.yaml, so v67 and v68 both
// cite analytics behaviour no shipped build ever had. pubspec.yaml now pins
// analytics beaeafa and protocol e33e53a, and those SHAs are repeated below as
// kAnalyticsPin/kProtocolPin so a future repin cannot skip this constant.
//
// What moves on a re-derive:
//
//   1. ACTIVE MINUTES are the z-angle wake quantity, always — never ENMO. Days
//      derived after the movement floor froze change value, which is the point.
//      With no usable accel (or under 60 samples) `active_min`, `activity.value`
//      and the restlessness block are NULL rather than 0: a day nobody wore the
//      band was reporting a measured zero.
//
//   2. THE IRREGULAR-RHYTHM SCREEN is analytics' shared one, not edge's second
//      copy. Differences are taken only between beats adjacent in the INPUT (a
//      dropped artifact run was manufacturing one huge spurious difference), it
//      needs 500 beats rather than 20, it is ABSENT instead of publishing
//      sd2 = 0 with "regular" on a degenerate series, the flag now also wants
//      pNN70 >= 30%, and confidence scales with beat count and artifact
//      fraction instead of sitting at a hardcoded 0.5. `flag` can be null.
//
//   3. SLEEP SEGMENTATION uses the habitual-midsleep prior, which was written
//      and never called. Anyone with 14+ stored nights whose midsleep is far
//      from 03:30 can see a different sleep block picked on nights with
//      competing candidates — so TST, staging, nocturnal RHR/RMSSD and
//      readiness all move with it. Biggest behavioural change in the batch.
//
//   4. SKIN TEMP EXISTS ON GEN5. `skin_temp_adc`, `skin_temp_z` and readiness's
//      temp driver were permanently absent there. Units stay relative either
//      way (gen4 ADC, gen5 centi-°C) and are only ever read as a z against the
//      user's own baseline — but a history that crosses a gen4 -> gen5 swap
//      takes one baseline step while the z re-settles.
//
//   5. FROM ANALYTICS (beaeafa, and this time the pin carries them): personal
//      baselines withhold z/delta/ratio/in_normal_range until a real night is
//      folded instead of seeding at the midpoint of the physiological bounds;
//      resting-HR percentile-of-you is lower-is-better; the circadian
//      non-parametrics (m10/l5/relative amplitude and their onsets) are OMITTED
//      when any hour of day was unobserved rather than filled with the grand
//      mean and 0.0; readiness_composite drops the `meaningful` key and the
//      SWC-gated tail on its note; chronotype's absent-note text changed.
//
//   6. FROM PROTOCOL (e33e53a): a gen4 band on a record version whose field map
//      we never confirmed (v7/v9/v18, unknown) reports spo2/skin-temp/ppg/
//      ambient ABSENT instead of bytes read off a guess — relative ODI and the
//      ADC-derived wellness inputs go from a number to honest absence on those
//      bands. v24/v12 are untouched. A gen5 v18 record with an out-of-range HR
//      byte now decodes (hr absent, beats/temp/steps kept) instead of landing
//      in raw_archive, so gen5 gains decoded_onehz rows it never had.
//
//   ALSO: `crossday.recent[]` carries an `unsettled` bool, `hrv_timeline` keeps
//   the v68 epoch fix, and the strain/energy paths are unchanged.
// v70 — the device seam. Which band measured a day is now an INPUT to the
// numbers derived from it, and a day that cannot say which band that was gets
// no number instead of gen4's. Pins move to analytics 98d42b6; protocol stays
// at e33e53a, unchanged and sealed.
//
// READ THIS FIRST — WHAT WILL LOOK LIKE A REGRESSION AND IS NOT:
//
//   `decoded_onehz.device_family` arrived at schema 41. It is NULL on every row
//   written before that, on every import and on every raw replay — which is all
//   of today's data. So on a re-derive of any EXISTING day, everything
//   downstream of the HR ceiling goes ABSENT: strain, TRIMP, the day's HR
//   zones, wake-day calories, and every session's zone_bands/zone_min. That is
//   the contract working, not a break. We do not know what measured those
//   seconds, so we cannot say where their ceiling is, and gen4's number is not
//   a default for a strap we did not identify. Days recorded from here on carry
//   the family and keep their numbers. Already-banked session strain/kcal/zone
//   splits are NOT destroyed — reconcile keeps the stored value; it is the
//   re-score and the on-read recompute that abstain.
//
// What moves on a re-derive:
//
//   1. ONE HR CEILING, DEVICE-DISPATCHED. There were five: `220 − age` in
//      local_repository_impl, app_state and analytics' load_trimp; Tanaka
//      `208 − 0.7·age` inlined in onehz_pipeline and crossday_pipeline; and
//      `(220 − age) + 25` in hr_max. A session stored its zone_min against one
//      and its detail screen recomputed zone_bands against the other, for the
//      same session, with nothing on screen saying so. Everything routes
//      through `estimatedMaxHr(age, family)` now. At 30 the ceiling goes
//      190 → 187 and at 60 160 → 166, so BAND MEMBERSHIP CHANGES: 150 bpm at
//      age 30 was Z3 and is now Z4. `hrCeilingForAge` is deliberately NOT
//      folded in — it is an artefact-plausibility bound with headroom, and
//      clipping it to the training ceiling would eat real effort.
//
//   2. Both families carry Tanaka today, and they are listed SEPARATELY on
//      purpose. The ceiling a strap's zones sit on is a property of what that
//      strap can measure at intensity, so the day gen5 earns its own number it
//      changes one entry in hr_max.dart rather than everyone's.
//
//   3. TWO NEW `metric_series` KEYS: `midsleep_sec` and `sleep_onset_sec` —
//      signed seconds either side of 04:00 LOCAL, tz-corrected per instant and
//      unwrapped. Not a second-of-day, not an epoch. FORWARD-ONLY: midsleep was
//      never persisted, the 1 Hz substrate they come from is pruned at
//      `rawRetentionDays` and a day locks ~48 h after wake, so no past night
//      can be given one.
//
//   4. `day_result` stamps `source: 'band'`. An importer's day is a different
//      vendor's derived score and must carry its own tag; a day whose
//      provenance is genuinely unknown stays NULL and is never retro-filled.
//
//   5. `decoded_onehz.hr` stores NULL where it stored 0 — off-skin is absence,
//      not a heartbeat. No number the app produces changes (every reader
//      already gated `hr > 0`), but a new query must not assume NOT NULL.
//
//   6. FROM ANALYTICS (98d42b6, the device-seam commit — and only that):
//      * `device.dart`: `calibrationFor()` returning null for an unstamped
//        strap, or for one this metric has no numbers for, rather than handing
//        back gen4's constants. This is what (1) dispatches on. No registry, no
//        shared constants file and no closed list of families — a metric
//        declares its own String-keyed map next to itself and refuses when the
//        stamp is not a key in it.
//      * journal correlations ran 9 numeric fields against 4 outcomes behind a
//        per-test gate. That is 36 simultaneous tests, so ~2 spurious
//        "meaningful" findings per user were guaranteed by construction.
//        Benjamini-Hochberg over the grid now, so FINDINGS DISAPPEAR and an
//        empty result is a real answer the card has to be able to say.
//      * habits are custom fields with max == 1, so a 0/1 variable was getting
//        a Spearman rho and a Theil-Sen "slope per unit". They route to
//        difference-of-means.
//      * `hrRecovery` publishes a fitted tau off a 180 s tail with a residual
//        gate, alongside hrr-60 rather than replacing it. It abstains often —
//        the recovery is biphasic and one exponential conflates the phases.
//      * the weekday effect is Kruskal-Wallis first, then a permutation test on
//        the max deviation, so the 7-way selection is paid for. Without that it
//        is a machine for manufacturing superstitions about Saturdays.
//      * sleep runs terminate at unobserved instead of merging across it.
//      * the apnea screen returns the per-cycle depths and widths it was
//        already accumulating and throwing away.
//      * `vo2maxEstimate` and `physiologicalAge` are GONE: 15.3·maxHr/rhr is
//        k/rhr, a restatement of a line already on screen, and the age function
//        then counted rhr twice in the same direction. Edge stopped calling
//        both before this pin, so nothing on screen loses a value.
//
//   7. FROM PROTOCOL: nothing. e33e53a is unchanged and sealed.
//
//   NOT IN THIS PIN, SO NOT AT THIS VERSION: the rest of this wave's analytics
//   work is UNCOMMITTED in the sibling working copy — the journal lag
//   realignment, SRI's `pairs`, the sleep stage ranges, `stageIntervals`,
//   `cvhrPersonalDistribution`, `alertnessForecast`, `sessionHrCeiling`,
//   `tempCircadian`'s family dispatch. Local runs see them through
//   pubspec_overrides.yaml; a clean checkout does not, and edge lib/ already
//   calls nine of those symbols. Commit analytics and repin at the NEXT
//   version — this is exactly the v67/v68 failure, one commit from repeating.
//
//   ALSO, not a re-derive: schema 43 (`source` on decoded_onehz/decoded_rr,
//   `external_hr`, `imported_measurement`, `sessions.cadence_spm`,
//   `sessions.rpe`) and `Substrate.hrValid` (gen5-only, no consumer yet).
//
// v71 — the algorithms audit. No new feature in here. Every item is a number we
// could not stand behind, either corrected or withdrawn. Pins do not move:
// analytics stays 391ede4, protocol stays e33e53a, sealed and unread.
//
// READ THIS FIRST — THE PIN DOES NOT CARRY THE FIXES BELOW, YET.
//
//   Every analytics change in this block is UNCOMMITTED in the sibling working
//   copy. 391ede4 is analytics HEAD and predates all of it. So a local build
//   (pubspec_overrides.yaml) derives a day at v71 with these numbers and a
//   clean checkout derives the SAME day at v71 with v70's — the collision this
//   constant exists to prevent, and the v67/v68 failure with the sides swapped.
//   Do not cut a build off this pin. Commit analytics, repin, and bump again in
//   the same change; then this block is true. Until then v71 is local-only.
//   Both sibling branches are also UNPUSHED (analytics
//   `fix/numerical-correctness`, protocol `fix/gen5-bounds-and-write-guard`),
//   so these SHAs resolve on this machine and nowhere else.
//
// WHAT DROPS OR GOES ABSENT — the part that reads like a regression:
//
//   1. ACTIVE ENERGY FALLS, HARD. `dailyEnergy` bills only the minutes actually
//      above the flex-HR gate. Measured through the real code on the real DBs:
//      gen4 median daily ACTIVE 1,955 -> 48 kcal, total 1,544-5,582 -> 793-3,437
//      kcal/day; MG active 539 -> 9, 3,042 -> 680, 695 -> 0. A quiet day now
//      reads essentially basal, because that is what it was. This is the number
//      people eat against, and the Apple Health / Health Connect ACTIVE_ENERGY
//      export moves with it. Already-derived days keep the old inflated figure
//      until re-derived. Strain, TRIMP, steps and active minutes are unchanged.
//
//   2. NIGHTLY RMSSD REFUSES ON A JITTERY NIGHT. The lag-1 autocorrelation of
//      the NN difference series (`diff_acf1`, new key on every night) separates
//      real beat-to-beat variability from per-second beat quantisation. Both
//      WHOOP 5 nights in the corpus refuse — so readiness on a W5 runs on its
//      other three drivers — MG drops 87.7/82.9/76.9 -> 58.0/52.7/48.0 ms, and
//      gen4 comes down 2-13%. `rmssd_ms`/`pnn50_pct` are absent on all five
//      gen5/MG nights and none of the thirteen gen4 ones; `rmssd_nocturnal` is
//      absent on gen5/MG and 0.1-1.8 ms lower on gen4. `confidence` moved on
//      every night, 0.95 -> 0.30..0.82 — the old value was a constant wearing a
//      measurement's clothes. Refusal note prefix `rmssd_refused:acf1=`.
//      Everyone's `ln_rmssd` history is now on a slightly different scale than
//      the days before it: the trailing baseline re-converges, the transition
//      day reads off. Deliberately NOT a device-family gate — MG and W5 are the
//      same family and land on opposite sides of it, so the night's own signal
//      is the better judge and an unknown strap gets judged on its data.
//
//   3. READINESS REFUSES ON A COLD START. Under 2 surviving inputs, or under
//      0.5 of the weight, the composite is '—' rather than a score built out of
//      one driver and a shrug. Two of seventeen real gen4 days go: 2026-08-03
//      (was 44.7) and 08-07 (was 0.8). Note prefix `need_inputs:`.
//
//   4. THE TEMP DRIVER REFUSES UNTIL WE MEASURE A SETTLED FRACTION. A nightly
//      skin-temp mean over a window that includes warm-up and off-wrist is not
//      a nightly skin temp. Nothing supplies a settled fraction yet (see
//      BLOCKED), so the driver is refused everywhere and readiness runs on
//      three drivers: 7 of 17 gen4 days shift, all within 2.1 points except
//      08-14 at -7.6. THE CHANNEL IS UNTOUCHED — `skin_temp_raw` ingest,
//      `skinTempAdc`, `skinTempZ`, `skinTempCoverage`, `tempIllnessFlag`,
//      `menstrualCoverline`, `tempCircadian` all still exist and still publish.
//      What is gated is one nightly mean's fitness to be used, and the band is
//      one-sided on purpose so a fever is never trimmed.
//
// BASELINES, AND THEREFORE EVERYTHING GATED ON A Z:
//
//   5. `Baselines.update` — the engine under recovery, illness and stress.
//      Measured on real gen4 nights: resting_hr spread +11.0%, hrv spread
//      +5.6%, |z| down 11.5% and 5.6%. Every z threshold in the stack shifts
//      with it. `nightsSinceUpdate` now also increments on a hard-outlier
//      night, so fourteen consecutive rejected nights correctly read `stale`
//      instead of `trusted`.
//
//   6. SLEEP CONFIDENCE moves on 3 of 8 real gen4 nights, largest 0.440 ->
//      0.600. It scales `stageIntervals` half-widths and stamps three sleep
//      Metrics, so the stage ranges on screen widen or narrow with it.
//
// THINGS THAT COULD NEVER FIRE, AND NOW CAN:
//
//   7. `glassBoxReadiness` published an empty `drivers` list and "nothing moved
//      beyond your normal day-to-day noise" on essentially every night. Both
//      populate now. The `past_mdc` JSON key is unchanged on the wire but means
//      "outside your usual spread" (SWC), which is what the detail screen's
//      copy already said.
//
//   8. `overreachingConjunction` was structurally unable to fire.
//      `nights_elevated` can be non-zero and `both_point_same_way` true.
//
//   9. Cross-day circadian: `circadian_rhythm`, `circadian_cosinor` and
//      `circadian_coverage` go from permanently absent to populated.
//
// THINGS THAT DISAPPEAR:
//
//  10. JOURNAL INSIGHTS GET MUCH STRICTER — permutation p, Benjamini-Hochberg q
//      over the whole grid. A small journal now produces zero insight rows
//      where it produced several, and zero is the honest answer the card has to
//      be able to say. New optional `p`/`q`; thin rows come back
//      `insufficient` with `need_history:have=N,need=M`, which nothing reads
//      yet and should be surfaced.
//
//  11. `alertnessForecast` changes shape, LENGTH (the curve now ends with the
//      waking day, so it varies with sleep duration), trough window and note.
//      Any golden over that curve moves.
//
//  12. Withdrawn keys and wrong attributions: `prsa` loses `risk_tier` (no
//      readers), `segmentChangePoints` says GREEDY / Killick 2012 and doubles
//      its default penalty (no production callers), `sleepDebt` loses a
//      citation it never implemented.
//
//  13. `multivariateAnomaly`'s default gate is 1.25x-13.23x wider under 90
//      nights of baseline. Zero flags before and zero after on the real corpus,
//      so nothing on screen changes today — it removes ~4%/night of false-flag
//      exposure during a new user's first month.
//
// BLOCKED ON EDGE WIRING — INERT AT THIS VERSION, EACH ONE LINE, EACH ITS OWN
// BUMP WHEN IT LANDS:
//
//   * `onehz_pipeline.dart:296/:388` — `correctRr(d.sleepRrMs)` /
//     `correctRr(d.dayRrMs)` want `rrTsMs: d.sleepRrTsMs` / `d.dayRrTsMs`. The
//     default path is byte-identical, so nothing moves until they are passed.
//     The moment they are: the analysed span goes from 0.13-0.87 of the window
//     to 0.99-1.00, LF/HF moves on 12 of 13 nights and CROSSES 1.0 — the line
//     people read as sympathetic-vs-vagal — on three (MG 08-12 0.65 -> 1.53,
//     W5 08-11 0.72 -> 1.25, gen4 08-09 0.88 -> 1.01), VLF by up to 33x, and
//     rsaRespRate stops publishing 9.00 br/min on gen4.
//   * `onehz_pipeline.dart:329` — `hrvTime(nn, nnTimesMs: nnTimes)` wants
//     `artifactFraction: artifactFraction`, already in scope twelve lines above
//     where `hrvFreq` gets it. Worth 13.7-15.3% of confidence on the MG nights
//     and 1.8-5.1% on gen4; until then half of item 2's confidence fix is dead.
//   * `derivation_engine.dart:4010` — `ana.cusumChangePoints(rhrSeries, h: 5.0)`
//     wants `dates: rhrDates`, built four lines above it. Until then the
//     critical-priority "Your resting heart-rate trend shifted" notification
//     still accumulates evidence straight across a wear gap.
//   * Nothing measures a settled fraction, so `nightlySkinTemp` is unwired and
//     item 4 fails closed everywhere. When it lands, nightly skin temp becomes
//     the mean of the settled portion rather than of the window: +0.2 to +6.0
//     counts on real gen4 nights, and the stored `skin_temp_adc` history is
//     old-rule until a recompute regenerates it.
//
// RULINGS, unchanged and re-checked: protocol sealed, not read, not edited.
// The gen4 skin-temp channel stays. SpO2 still refuses on every day of every
// DB. `_crossDayWindow` is still 90. Water is still a reminder.
//
// STALE IN THIS FILE, not fixed here because it is another owner's diff: the
// comments at :4377, :4425, :5023 and the header block at :637-666 all still
// quote the old 0.50*HRmax flex gate that item 1 moved.
//
// v74: WEAR COVERAGE divided by the wrong thing, and a charging caveat.
//
//   1. `coverage_pct` was `wornSec / (last sample - first sample)` — the span
//      of the DATA, not the day. A band worn 9-11am and nowhere else reported
//      100%, and `day_strain` renders that number as the sentence "The band saw
//      N% of this day". The denominator is now the OBSERVABLE day: local
//      midnight → min(data edge, next local midnight), both bounds from the day
//      LABEL so the two DST days are 23 h/25 h rather than a hardcoded 86400.
//      A day still in progress divides by the part of it that has elapsed, so a
//      fully-worn morning still reads 100% instead of "60% missing" for hours
//      that have not happened. Every finalized day re-derives onto a LOWER
//      number wherever the band came off before the last record of the day —
//      on a partly-worn day this is the whole point, and it is the first time
//      that sentence has been true. Nothing else consumed the field: three
//      screens read it (day_strain, investigate, health_screen) and all three
//      already handle null.
//   2. `wear.segments` followed the same span, so the hole between midnight and
//      the first record was invisible — which would now contradict the
//      percentage beside it. Leading and trailing off-segments are emitted, and
//      `sum(on)/observable == coverage_pct` exactly. `longest_off_min` can grow
//      on a day that started late; that is the measurement, not a regression.
//   3. Charging INSIDE the scored sleep window is flagged (`sleep_charging`),
//      after being scored, staged and fed into baselines unremarked on 2 of 9
//      real nights. A battery-pack swap is not a wrist-off event — the strap
//      stays on the wrist and keeps logging, so no wear signal can see it. NO
//      confidence penalty: see `sleepChargingBlock` for the mechanism argument. The
//      charging/wrist-off span read also widened back to sleep ONSET, which is
//      before local midnight on any normal night, so a pre-bed top-up that
//      opened and closed before the day's first record is no longer missed.
//   4. Comment-only: the daytime-stress refusal at `_daytimeHrv` claimed gen5's
//      `signalQualityLogVariance` is "dropped before the DB". Since schema 43
//      it is written to `decoded_onehz.signal_quality_logvar`. Still unread, and
//      deliberately so — it is gen5/MG-only, so gating on it makes the same
//      night answer differently on two straps. The refusal's construct argument
//      is untouched and is the one that carries it.
// v75 — THE ISSUE AUDIT. Every issue and discussion ever filed was re-checked
// against the shipped tree; these are the ones that were still true. Four
// numbers move, and each moved because it was wrong, not because it was tuned:
//   1. READINESS carries its fourth driver. `tempInput` refused on every night
//      ever shipped, because `settledFraction` was never passed from this side
//      — the driver was documented, weighted 0.10, and unreachable. The other
//      three renormalised over 0.90 and quietly absorbed it. Nights the strap
//      cannot vouch for (device_family NULL, pre-schema-41, imports, gen5) are
//      refused BY NAME now instead of silently.
//   2. READINESS BANDS are the score's own quantiles. The composite is a
//      logistic with no scale parameter, so its centre is 50 — and 50 was
//      labelled "Take it easy". Half of every user's nights read as a warning
//      by construction, and "Good to go" needed every input ~1.4 SD above
//      personal median at once. The score did not change; the verdict did.
//   3. PEAK HR stopped contradicting itself. The workout producers smoothed
//      through hr_max.dart, the day peak still did reduce(math.max) over raw
//      1 Hz — so the strain card and the timeline printed different numbers off
//      the same beats (#127, closed once already). Manual saves and the
//      below-coverage reconcile fed it unsmoothed too.
//   4. CALORIES and STRAIN follow the analytics gates above, and both abstain
//      rather than guess: a day with no resting HR now has no calorie figure
//      instead of billing every waking minute as active.
// Also here, changing nothing derived: a night never re-stages shorter than the
// one already banked (#242 — the guard only fired on a FAILED pass and never
// compared tst_sec, which is why a fixed night came back wrong a few syncs
// later), and absent accel stays absent instead of coalescing to zero.
// v76 — IMPORTED DAYS WERE SETTING THE BASELINE THEY ARE SUPPOSED TO STAY OUT
// OF. The rule that a vendor export never feeds a personal baseline was enforced
// on the WRITE path only — three call sites check `isMeasuredDay`, while
// `_BaselineHistoryCache.load()` read `metric_series` with no source filter at
// all. Both importers write real series rows through `putDayResult`, so four of
// the eight baselines (`rhr`, `rmssd`, `readiness`, `resp_rate`) were being set
// partly by somebody else's algorithm. The other four escaped by accident, not
// design — the importers happen to write `skin_temp_z` rather than
// `skin_temp_adc`.
//
// NOOP is NOT foreign, which is the part worth remembering: `NoopIngest` holds a
// DerivationEngine and feeds it reconstructed 1 Hz substrate, so those days are
// our own maths and are stamped `source: 'band'`. Only `whoop_export` and
// `cloud_v2` are somebody else's.
//
// `source` is NULL for every day written before schema 43 and the backfill
// deliberately never fills it, so filtering on `source = 'band'` would have
// deleted genuine early history — a pollution bug traded for a data-loss one.
// It is decidable anyway: both importers put `imported: true` in the day
// bundle, which is what the write path has always tested. `importedDates()` is
// the union of both eras and the seam everything else reads through.
//
// Readiness, the illness CUSUM, and the training-zone and live-strain RHR
// anchors all move for anyone with an import in range. For a user who never
// imported this is a strict no-op: the set is empty and every read is unchanged.
// Days already finalized keep the score they were derived with — raw is pruned,
// so no bump can heal them.
// v77 — WALKING FINALLY PRICES INTO ACTIVE ENERGY (issue: "Walking calories
// are not counted"). MOT-02's HR-flex gate deliberately bills nothing below
// the ACSM moderate floor — right for HR (Keytel has no fitted data there),
// but it left a one-hour walk at 95 bpm adding ZERO active kcal while its
// steps counted fine. MT-05 established the 1 Hz accel cannot fill that gap;
// measured CADENCE can. `Calories.dailyEnergy` (analytics, CADENCE-Adults:
// 100/110/120/130 spm ↔ 3/4/5/6 METs) now prices sub-gate minutes whose
// measured cadence clears the study's own moderate floor, at (MET−1)
// basal-minutes of surplus. Edge feeds it the day's resolved `live_coverage`
// spans through ONE mapping (`cadenceSpmForMinutes`) from BOTH energy passes
// — the coordinator's canonical `wakeDayEnergy` and the pipeline's early-read
// mirror — so the two bill a walk identically. A minute the HR gate accepts
// still bills by HR alone (never both), an unmeasured minute stays basal, and
// a day with no pedometer coverage is byte-identical to v76. The TDEE block
// discloses the term (`live_coverage_pedometer` in inputs_used + the walking
// kcal in the note) only on days it actually priced something. Landed on
// main via edge#283/analytics#52 before this branch's own v78/v79 below;
// nothing here changes it.
//
// v78 — BAND-AGNOSTIC GROUPS A AND C (renumbered from this branch's own v77
// during the merge with #283 above — main had already claimed 77 for the
// walking term by the time this landed, and two different output changes
// cannot share one kAlgoVersion). The 1 Hz assumption comes out of the
// metrics that were counting array positions and calling them seconds, and four
// gen4 defects found on the way out. Eight entries move a published number:
//   1. A1 — BEAT TIMES REACH THE READ PATH. `decoded_rr.beat_ts_ms` (the
//      record's own sub-second anchor) was written and never SELECTed, so every
//      beat sat on a whole-second staircase and no dropout under 1 s was
//      visible. LF/HF and `span_sec` move with the re-anchored axis.
//
//      MAGNITUDE, CORRECTED 2026-08-23 against the owner's own gen5 export.
//      The +0.031% first recorded here was a LOWER BOUND — it came from a
//      measurement that forced `tsSubsec = 0`, isolating the staircase→chain
//      term and none of the real sub-second effect. On 2026-08-22: RMSSD
//      78.571 → 73.198 (−6.84%), pNN50 −0.56%, SDNN −1.36%, and n_beats
//      31177 → 30948 (−0.73%). 2026-08-23 moved the other way (+0.02%), so it
//      is per-night, not a constant shift.
//
//      SDNN and the beat COUNT both move, which the original note said they
//      would not. Not a defect: `beat_ts_ms` anchors a record's LAST beat and
//      walks backwards through the durations, so a 4-beat record's first beat
//      lands ~1444 ms BEFORE its own `rec_ts` (measured, and it scales one RR
//      per beat exactly as that model predicts). `_beatTimes`' dropout test is
//      `(rrTsMs[i] - rrTsMs[i-1]) - rrMs[i] > 1000`; on the staircase two beats
//      inside one record differed by 0 ms so it could NEVER fire. Sub-second
//      dropouts were structurally invisible. They fire now, the re-anchor set
//      changes, and `hrv_time`'s contiguous-pair mask changes with it — the
//      interval VALUES are untouched.
//
//      0.41% of beats (624/151,595, worst −1490 ms) step backwards where two
//      records overlap. Handled, not a hazard: `cur = (dropout && anchored >
//      cur) ? anchored : cur + rrMs[i]` never takes a backwards jump. `rr_ts_ms`
//      measured 0.00% non-monotonic only because a whole-second staircase is
//      trivially so — it hid the overlap rather than preventing it.
//
//      UNVALIDATED IN MAGNITUDE. Nothing available says whether 73.198 or
//      78.571 is closer to truth: the band's `hr` comes from the same beat
//      detector as `rr_ms`, so it is not independent evidence. That is the
//      simultaneous-H10 experiment, and this is its second reason to happen.
//   2. A2 — ACCEL VALIDITY SURVIVES SEGMENTATION. `AccelSample.valid` was
//      dropped converting to the segmenter's own type, so a night the strap
//      never vouched for was staged as if it had. Measured: 8 h of
//      `valid:false` published `TST 28619s, efficiency 100.0%`; it is absent
//      now.
//   3. A3 — BEATS WITH NO FRAME ARE KEPT. RR was looked up only inside the
//      frames loop, so a beat whose second has no `decoded_onehz` row was
//      discarded — and gen4's hr-only historical R10-lite produces exactly
//      those. The 1 Hz substrate is the UNION of frame and beat seconds now.
//   4. A4 — READINESS NEEDS 14 NIGHTS, not 3. A 3-night baseline is three
//      numbers: its MAD is routinely one quantum wide or zero, which is how a
//      degenerate z reached the logistic and the ring flashed a rail. Sub-
//      quantum spreads are refused outright rather than z-scored.
//   5. C1 — THE 30-MINUTE TROUGH IS 30 MINUTES. `nocturnalRhr` walks a wall
//      clock (`onehz_pipeline.dart`, `tsSec: sleepTs`) instead of counting 1800
//      positions. At a perfectly dense 1 Hz the two coincide; on real nights
//      they do not, because real nights have holes. Measured over this owner's
//      export: 2026-08-13 and 2026-08-14 are bit-identical (1 and 243 missing
//      seconds), 2026-08-12 moves 62.952 → 62.857 bpm (506 missing seconds of
//      25,262 — the positional window was averaging over ~30.5 min of clock and
//      missing the real trough). The wall-clock answer is the correct one, and
//      the same edit is what lets the metric exist at all at 60 s and 300 s,
//      where it previously abstained. It feeds readiness's 0.30-weight driver.
//   6. C9 — no metric credits a sample whose cadence cannot be measured. One
//      `sampleCadenceSeconds` with an ABSTENTION replaces three median-interval
//      helpers with numeric fallbacks; a band slower than 300 s used to have
//      every reading credited as one second (~300x zone undercount) and now has
//      no zone figure at all.
//   7. C13 — an unstamped substrate carrying a step counter reports
//      `band_measured: null`. Without a device stamp there is no modulus to
//      unwrap it with, and a guessed one publishes a step count at tier HIGH.
//   8. THE SAME TREATMENT FOR R-R AND FOR GRAVITY, which the list above missed
//      on the way past and which move published numbers exactly as items 1-7
//      do. `kMinPlausibleHr`/`kMaxPlausibleHr` had a sibling added either side
//      of it in `substrate.dart` and both are new here:
//        * `kMinPlausibleRrMs..kMaxPlausibleRrMs` (250..2400). Only `rr <= 0`
//          was dropped before, so a corrupt-but-CRC-valid interval reached
//          RMSSD, pNNx and every frequency-domain read. It drops the BEAT, not
//          the record — the surviving beats keep the placement `beatTimesMs`
//          already gave them.
//        * `kMaxSustainedAccelG` (4.0). `accelPresentAt` rejected only an exact
//          `(0,0,0)` fill; a second-long mean above 4 g is not a wrist either,
//          and it is now absent rather than present. That reaches every accel
//          consumer — van Hees, ENMO, movement minutes, the sleep segmenter —
//          because absent accel is NOT stillness.
//      Both refuse rather than clamp, for the reason `plausibleHrOrNull` does.
// v79 — REVIEW PASS ON v78 (renumbered along with it, see v78's note above).
// One edge fix and four analytics fixes, all in the same "a rejected reading
// must not still move a kept one" family v78 was itself about.
//   1. `beatTimesMs` (`substrate.dart`) let an interval `plausibleRrOrNull`
//      would go on to REJECT (positive but outside 250..2400 ms) still walk
//      every EARLIER beat in the record back by it, before the caller ever
//      saw the rejection. The interval that placed beat i-1 now has to pass
//      the same plausibility test placing beat i's own reading already does
//      — an implausible one breaks the chain (null, same as non-positive)
//      instead of silently displacing a beat that is kept.
//   2. `nocturnalRhr` (analytics) could reach a window with zero on-skin
//      samples and land `sum / count` as NaN, which then LATCHES as the
//      night's best trough (`m < best` is false for a NaN on either side) —
//      a present metric with a NaN value. Only reachable with
//      `minCoverage: 0`, which no call site in this repo passes; the fix is
//      defensive, no WHOOP output moves.
//   3. `_rescaleCounts` (analytics sleep stager) multiplied an
//      already-cadence-invariant gravity-delta sum by the cadence a second
//      time — the sum is already `epochSec * rate` independent of sample
//      count, so the extra factor inflated a slower-than-1Hz band's
//      Cole-Kripke score up to 5x. `cadenceSec == 1` at 1 Hz makes the factor
//      a no-op, so no WHOOP output moves.
//   4. `cardio_stager`'s epoch grid could silently drift from its own
//      reported `epochSec` whenever the measured cadence did not divide it
//      evenly — it abstains on that mismatch now rather than publish a grid
//      whose real spacing does not match its own label. WHOOP's 1 Hz cadence
//      always divides the 30 s epoch evenly, so no WHOOP output moves.
//   5. Readiness's sub-quantum-dispersion guard (analytics, following A4
//      above) only ran when `robustZ` came back null, missing a baseline
//      with nonzero MAD but still-quantized SD (whole-bpm RHR alternating
//      58/59: MAD 0.5, SD ~0.52, both below the 1-bpm quantum). Runs for
//      every quantized input now. THIS ONE CAN MOVE A WHOOP READINESS SCORE
//      — a baseline that happens to sit in that MAD-nonzero/SD-sub-quantum
//      gap now refuses by name instead of contributing a z-score built on
//      quantization noise.
// Days already finalized keep the score they were derived with — raw prunes at
// `rawRetentionDays`, so no bump can heal them.
//
// v80 — irregular-rhythm 24/7 SCREEN false-positive fix. `irregularBeatScreen`
// (analytics) computed one Poincaré SD1/SD2 + pNN70 ratio blended across an
// entire calendar day (sleep + rest + exercise + posture changes). Real user
// data showed EVERY sampled day sat at or over both thresholds (sd1/sd2
// 0.63-0.81 vs 0.70 cutoff; pnn70 27-56% vs 30% cutoff) — the "medical"
// notification was firing almost daily, because ordinary daily physiological
// variability alone clears these thresholds when blended into one number; the
// thresholds were never validated for a 24h aggregate (traced to an
// uncalibrated commit, PR #12). Fix: the screen now also requires the same
// two conditions hold independently in a real fraction (default 50%) of
// short (5-min) mostly-stationary windows across the day — i.e. sustained,
// not just present once in the blend. Wired at both call sites
// (`onehz_pipeline.dart`'s day-span AND sleep-only screens) via the new
// `nnTimesMs` param. THIS CAN MOVE `irregular_rhythm_flag` from 1→0 on days
// that were false-flagging; it cannot move it 0→1 (strictly stricter).
// PIN GATE (invariant #5): do not release with a pubspec pin that predates
// the analytics commit landing `_sustainedAcrossWindows` in
// irregular_rhythm.dart, or recomputing v80 against a sibling without it
// would silently keep firing the false positive.
//
// PIN GATE (invariant #5): v77 above cites the analytics walking term
// (OpenStrap/analytics#52). Do not release with a pubspec pin that predates
// that merge — recomputing v77+ against a sibling that cannot price walking
// would burn the version on nothing.
//
// v81 — ACTIVE ENERGY WORKOUT-GAP CREDIT. `applyDayActivity`'s calorie figure
// is built entirely from `daySub.hr` (the day's own continuous 1 Hz trace)
// and never read `sessions` at all — so a workout that scored its own
// calories through the SEPARATE session pipeline (`computeManualSessionStats`
// / the live-tick accumulator) contributed nothing to Active Energy whenever
// the band lost PPG contact for its whole window, which is common for a
// wrist-gripping or arm-swinging session (lifting, a brisk walk) next to a
// low-motion one (Pilates) that keeps contact. `applyDayActivity` now takes
// this day's `sessions` rows and credits a DONE, non-private session's own
// `calories` into the day total ONLY when `daySub` has ZERO real HR samples
// across that session's whole window — never a partial one, so a window the
// trace already priced is never double-billed. THIS CAN RAISE `calories` /
// `calories_total` for a day with a workout the day trace fully missed;
// every other day is unaffected.
// v82 — THE ZONE CEILING IS `max(observed, age estimate)`.
// `trainingZones` (compute/hr_max.dart) preferred `observedCeilingBpm` whenever
// one existed, in either direction. But that number is one-sided evidence:
// holding 195 proves the ceiling is at least 195, while holding 166 cannot tell
// "never went maximal" from "maxes at 166" — and on a wrist the first is far
// commoner. So a 25-year-old whose hardest HELD effort was 166 was banded at
// Z5 = 0.9·166 ≈ 149 bpm and banked 13 of the 16 minutes of a steady run in
// "Max effort". On the session-detail path the ceiling is even set by the
// session being graded — `_zoneAnchors` takes the all-time max including today
// (the day pipeline and the live tick do NOT: `observedHrCeilingBpm` is
// strictly-before, and `LiveWorkoutState.zoneSet` is pinned at start).
//
// The observed ceiling now anchors zones only when it REACHES the age line,
// which is the only direction in which it bounds anything. Below it, zones stay
// on `208 − 0.7·age`, LABELLED as the estimate. There is deliberately no
// tolerance band: a switch at `estimate − k` would move every edge k bpm on a
// 0.1 bpm change in a ceiling that creeps up over months, while `max` is
// continuous. `observed`/`karvonen` therefore now mean "this user beat the
// population line", which is a narrower and truer claim than before.
//
// WHAT ACTUALLY MOVES, for affected users only — narrower than it first looks,
// and the two exceptions are both worth knowing:
//
//   * `zone_timeline` and `zone_source` move: both come off the pure pipeline's
//     `trainingZones` set (onehz_pipeline.dart:630).
//   * The day's `zones` DO NOT, because they never sat on the observed ceiling
//     in the first place. The second derivation half recomputes them from
//     `estimatedMaxHr` alone (`_wakeZoneMinutes` at :4662, `zonesFromMaxHr` at
//     :4680) and `bundle['zones'] = wake['zones']` at :4920 overwrites the
//     pipeline's. So the day BARS have always been Tanaka-binned while the
//     footnote beside them read `zone_source`. That is a separate, pre-existing
//     one-source-per-concern break (§3.8) and it is NOT fixed here; fixing it
//     means threading the anchors through `_DayBlocksInput` across the isolate
//     boundary, which moves `zones` for every user and is its own change.
//   * Sessions rebin only where they still can. `getWorkout` recomputes
//     `zone_bands` on every open, from the substrate or the frozen trace, so
//     the DETAIL card is always current. The persisted `zone_min` behind the
//     bars is rewritten by `rescoreRecentSessions(sinceDays: 3)` and by the
//     rescore on open — but a session whose raw aged out past
//     `rawRetentionDays` keeps the split it was scored with. Old cards are not
//     healed by this bump, and no bump can heal them.
//
// TS-05's 28-day distribution disappears for anyone it was drawn for off a
// below-line ceiling, which is that gate working: `zonesAreMeasured` was never
// true of bands whose 100 % nobody reached. Strain, TRIMP and calories DO NOT
// MOVE — they anchor on `estimatedMaxHr`, never on the observed ceiling.
//
// `hr_ceiling_bpm` itself is untouched: the ceiling and its date are still
// measured, still stored and still served, so the zones screen keeps saying
// "highest we have seen: 166 on 3 Aug". It just no longer becomes everyone's
// 100 %. No sibling pin moves — this is entirely an edge-side anchor choice.
//
// RENUMBERED ON THE MERGE, 81 → 82. Both sides of this merge bumped to 81:
// main for the active-energy workout-gap credit above, this branch for the
// zone anchor. Two different derivations cannot share one number — that is
// the whole contract of this constant, and main's 81 is the one already on
// main, so it keeps it. Nothing about the zone change itself moved.
//
// 82 → 83 (edge#305): a re-derive at the retention-cutoff edge could produce
// null rhr/rmssd/readiness for a day whose sleep-window substrate had aged
// out while daytime HR survived, and — because `metric_series` is unversioned
// — silently clobber a good historical baseline point, collapsing the
// readiness baseline out from under later nights. That re-derive is now
// declined (see the guard in `_derivePreparedDay` right after `producedNothing`)
// so the older, complete row keeps being served. Also: the readiness z-cap
// abstention now populates `readiness_absent_diag` with its own
// `unstable_baseline:` reason instead of leaving it null (onehz_pipeline.dart).
//
// v83's guard was `hasSleepWindow && sleepSubEmpty && nightScalarsNull`
// (:4204) — #305's own writeup named this exact shape ("a sleep-window
// boundary check") as insufficient, with a counterexample: a day whose stager
// found NO window at all (`hasSleepWindow` false) still hit the original
// clobber, unprotected. The v83 fix also declined by early `return` rather
// than writing a protected row state, which is the OTHER approach #305 names
// and rejects ("wedges the pruner... retried every pass forever") —
// mitigated only by the pre-existing generic `_maxRawHoldDays` bound (14
// days), not by anything added for #305. v83 did ship #305's third proposed
// fix in full (the dedicated `unstable_baseline:` diagnostic).
//
// 83 → 84: repins both siblings to their main #-audit merges. protocol
// 6664854 -> 471034c (#42, live-decode-path fixes only — no persisted
// decoder moves, see the protocol pin comment). analytics 187e026 -> 1fa8144
// (#59): `sessionHrCeiling`'s corroboration window no longer lets a single
// un-averaged sample count as sustained motion (was reachable at the very
// first trailing-window iteration), and `irregularBeatScreen`'s
// sustained-window check no longer diffs across a beat that artifact
// rejection removed as if it were adjacent. Both feed stored scalars
// (`hr_ceiling_bpm` via `sessionHrCeiling` at :7662; the 24 h and sleep
// irregular-rhythm screens via `irregularBeatScreen` in onehz_pipeline.dart),
// so this bump is real, not a repin-only formality.
//
// 84 → 85 (edge#305, closing the gap left by v83): `nightSubstrateRegressed`
// no longer requires THIS pass to have found a sleep window (:4232). The
// counterexample v83 missed — a re-stage whose RR/HR substrate aged out and
// came back `NO_SLEEP_DETECTED` instead of a truncated window — is now
// declined the same way as the truncated-window case. Safety against
// clobbering a genuinely-honest "no sleep that night" derive still comes from
// the caller's existingHadNight check, not from this shape test: a day that
// never had real sleep never had an existing result with real night scalars
// to protect. #305 is now fully closed.
//
// 85 → 86 (analytics#40, closing edge#204's workaround): `_attachNaps`'s
// midnight dedup used to guess a bout was already-counted from
// `nap.startSec == 0`, which only ever matched the FIRST bout of the day's
// window — a fragment chained onto it by a brief arousal (`napChainGapSec`)
// has `startSec > 0` but is just as edge-anchored, and slipped through
// uncounted, double-crediting its minutes to both days. Analytics now
// propagates a real `NapWindow.startsAtRecordEdge` flag through the whole
// chain (nap.dart); `_attachNaps` tests that flag directly instead of
// re-deriving it from the index. Real output change (nap minutes / sleep
// need on days with a midnight-arousal-split nap), so the bump is real.
//
// 86 → 87 (M5, edge-only — no sibling repin): the multi-device coverage
// resolver lands. Three real output changes, all gated on more than one
// device actually having contributed to a day (a single-device install's
// `day_result.payload_json` is byte-identical — see coverage_resolver.dart
// §2 and test/multidevice_coverage_derive_test.dart's identity-case
// assertion):
//   1. THE SUBSTRATE ROW FILTER. `_loadSubstrateRange`'s page loop now
//      admits a `decoded_onehz`/`decoded_rr` row only when its `device_id`
//      matches the resolved span owner for its second, once more than one
//      device has real coverage. Before this, two devices' rows for the
//      same second both entered the substrate and the union/dedup logic in
//      `addDecodedPage` kept whichever page happened to arrive first —
//      order-dependent, not owner-decided.
//   2. PER-OWNER wristOff/charging MASKING. A window owned by device A is
//      masked by device A's own off-body/charging events only; before this,
//      one unfiltered query over the whole nap/sleep window meant band B on
//      the charger could exclude band A's real worn night.
//   3. `series.coverage` is written into the bundle (omitted entirely, not
//      `{}`, on any day with one contributor) — the per-signal span
//      attribution a future device-aware UI reads (M6).
// Do NOT read this as citing an analytics change: the baseline-dispersion-
// below-quantum guard (readiness_composite.dart) some earlier draft of this
// bump would have named is ALREADY IN the pinned SHA below — citing it here
// would repeat the v43 mistake (a changelog naming a change the pin already
// had) in exactly the shape that kept "readiness —" live for three releases.
// kAnalyticsPin/kProtocolPin are UNCHANGED: M5 touches no analytics or
// protocol code.
// v88 — THE BEAT AXIS IS HELD NON-DECREASING (`monotonizeBeatAxis`,
// substrate.dart). `beat_ts_ms` is a modelled beat position walked backwards
// from the record's sub-second anchor, so two records whose anchors sit closer
// than one beat place N+1's first beat before N's last. Measured on a live
// install: 94 inversions across 39,066 beats in a single day.
//
// Analytics binary-searches that axis and asserts it ascends. The assert is
// compiled out in RELEASE — so shipped builds did not throw, they mis-selected
// each 300 s window's beats, and every affected day was banked at v87 from a
// window gather that had silently skipped or duplicated beats. Those results
// cannot be told apart from good ones after the fact, which is exactly what a
// version bump is for: the days re-derive instead of being served from cache
// (`finalizedDayIds` / `sleepSessionCandidate` both key on kAlgoVersion).
//
// Real output change on affected days — window membership moves by up to the
// inversion depth (672 ms measured) — so the bump is real. Interval VALUES and
// their order are untouched by the repair; only the modelled clock moves.
// kAnalyticsPin/kProtocolPin are UNCHANGED: the repair is entirely edge-side.
//
// 88 → 89 (movement-floor DST fix): `daysSinceFrozen` (movement_floor_policy.dart)
// used to run `.difference().inDays` on the parsed LOCAL `DateTime`s directly.
// A span crossing a spring-forward transition loses that day's missing hour,
// so a real 10-day gap floored to 9 — the same trap `dayLabelBefore` above is
// built to avoid, just missed here. Now both dates are normalized to UTC
// midnight before diffing. Changes the movement-floor staleness/re-freeze
// decision (and therefore `active_min`) for any day whose gap from the
// frozen-on date spans a DST transition. Real output change, so the bump is
// real. kAnalyticsPin/kProtocolPin are UNCHANGED: edge-only fix.
//
// 89 → 90 (skin_temp_z quantum guard): onehz_pipeline.dart's `skinTempZ` was
// gated only on `sd > 0` against the raw-ADC baseline history, with no floor
// for the ADC channel's own quantization step. analytics already guards this
// exact channel (`tempInput(..., quantum: 1)` in readiness_composite.dart),
// refusing when the baseline SD sits below 1 ADC count even though a nonzero
// SD passed the naive check. `skinTempZ` now requires `sd >= 1` too, so a
// baseline oscillating between two adjacent ADC counts abstains instead of
// reporting an inflated z. Feeds `tempIllnessFlag`/`multivariateAnomaly` and
// the raw health_screen display value (readiness's own temp driver already
// went through the guarded `tempInput` path and is unaffected). Real output
// change on the affected sub-quantum-dispersion nights, so the bump is real.
// kAnalyticsPin/kProtocolPin are UNCHANGED: edge-only fix.
//
// 91 → 92 (baevskyStressIndex is now gap-aware): passes `nnTimesMs` at the
// one call site (onehz_pipeline.dart) so a charging/off-wrist hole inside a
// sleep window segments the 256-beat sliding window instead of one window
// straddling the gap and reading the pre/post-gap RR jump as MxDMn — the
// same bug class `cvhrApneaScreen` already had a fix for. Real output change
// for any night that had an internal gap. kAnalyticsPin bumped alongside
// this (analytics PR #70).
//
// 90 → 91 (`_resolveOwnership` drops newly-paired devices): once a signal's
// `signal_priority` had ANY stored row, a device that started declaring that
// signal afterward (paired later, no stored row) was never added to the
// candidate list `resolveOwnership` reads — its real `device_coverage` was
// silently excluded from ownership resolution forever. Now any coverage-only
// device is unioned in below the stored ranking (sorted, in-memory only,
// never persisted — same property as the empty-priority fallback). Real
// output change for any user who customized priority for a signal and then
// paired another device that also declares it. kAnalyticsPin/kProtocolPin
// UNCHANGED: edge-only fix.
//
// 92 → 93 (HRV frequency-domain Welch gap guard, analytics PR #72): the
// Welch segmenter in hrv_freq.dart only rejected a segment by beat count,
// never by time-completeness, so a mid-window gap (BLE reconnect, off-wrist
// moment) could still publish a bogus LF/HF/VLF/ULF/lf_hf/nu_lf/nu_hf/total
// reading at Tier.high. Now gated on both an endpoint-span check and a
// largest-single-gap check. Real output change for any night with an
// internal HRV-frequency-window gap. kAnalyticsPin bumped alongside this.
// Verified: `git show 82857106e41c346b4edf9ad617829a5ddd1cc5c1:lib/src/onehz/clinical/hrv_freq.dart |
//   grep -n 'segSec \* 0.8\|segSec \* 0.2'`
//
// 93 → 94 (`overreachingConjunction` rhr quantum guard, analytics PR #73):
// an alternating whole-bpm rhr baseline (58/59) has a small nonzero MAD that
// is unresolvable rounding noise, not real dispersion — the guard
// `dispersionBelowQuantum` already applies on this same rhr channel in
// illness_cusum/readiness_composite/event_detection. Without it, a 1bpm rise
// could clear the gate and fire the "both facts point the same way" card on
// nothing. kAnalyticsPin repinned to analytics PR #73's merged main SHA.
//
// 94 → 95 (`glassBoxReadiness` rhr/temp quantum guard, analytics PR #75):
// same gap as #73, but on the stored "readiness_glassbox" narrative/drivers
// key crossday_pipeline still writes — glassBoxReadiness never gated its
// 0.5*scale rhr/temp standardization with dispersionBelowQuantum, so a
// quantized baseline (e.g. alternating 58/59 bpm) could get named a driver
// off rounding noise. edge's `_glassInput` calls now pass `quantum: 1` on
// both channels. kAnalyticsPin repinned to analytics PR #75's merged main
// SHA. This changes the stored drivers list for real users, so it gets a
// version bump despite being narrative-only, not a headline-score change.
// 95 → 96 (`_resolveOwnership`/substrate splice, accel1Hz/ppgRedIr/
// skinTempRaw priority): `signal_priority` and the device-priority screen are
// generic over every InputSignal a paired device declares, but the substrate
// loader admitted a whole `decoded_onehz` row (accel + ppg + skin-temp
// bundled with hr in one row) purely on the hr1Hz ownership winner for that
// second — a user's explicit accel1Hz/ppgRedIr/skinTempRaw priority order had
// no effect at all. `_resolveOwnership` now resolves those three signals too,
// and a contended second splices each field group in from its OWN owner's row
// when that device has one, instead of following hr1Hz. No output change for
// any single-device install or any pairing where those three signals are not
// actually contended (`group.length < 2` short-circuits to the unchanged row).
// kAnalyticsPin/kProtocolPin UNCHANGED: edge-only fix.
// 96 → 97 (temp_circadian zero-variance guard, analytics main @ 0441ef9):
// `_nonparam` divided by `varTot/diffN` with no zero-variance guard, so a
// flat or heavily-quantized skin-temp window reported
// interdailyStability=0.0 / intradailyVariability=0.0 as measured instead of
// withheld — a fabricated-metric bug on `circadian_lifestyle`'s stored
// output. kAnalyticsPin repinned to analytics main's tip (one commit past
// PR #75's merge SHA).
// 97 → 98 (day zone bars on ONE set, edge#333): the second half recomputed
// the day's `zones` off `estimatedMaxHr` alone and overwrote the pipeline's,
// while `zone_timeline`/`zone_source`/`zone_max_hr` stayed on the pipeline's
// `trainingZones` set. Anyone whose observed ceiling reached the age line got
// age-estimate bars under a footnote naming the measured ceiling. The
// recompute is gone; `zones` is the pipeline's, binned off the same per-minute
// wake series and set as the timeline. Moves `zones` for those users, and
// marginally for everyone (per-minute means instead of raw 1 Hz). The bars
// also gate on the set, not the age estimate, so a manual or observed set with
// no age gets bars instead of "add your age". Edge-only.
// 98 → 99 (crossday sleep performance + SRI, edge#493): performance scored an
// older night's TST when last night had none; SRI paired non-adjacent nights
// across a missing day. Edge-only.
// 99 → 100 (SRI, edge#494): 'unobserved' minutes no longer count as asleep,
// and a gap of any length pads one grid. Edge-only.
// 100 → 101 (crossday, edge#501): imported days' vendor scores are masked out
// of the rollup, and today's night counts as settled once the data edge is
// past its wake, so illness/anomaly alerts can fire the same day. Edge-only.
// 101 → 102 (gen5 step counter calibration, edge#474): the strap_counter
// total is scaled by a per-(family, wearing) factor learned against
// phone-only days (step_calibration.dart; factor 1.0 until 3 admissible days
// exist), the steps bundle gains `counter_wearing` / `counter_calibration` /
// `counter_coverage`, and strap_counter confidence is 0.9..0.98 by evidence.
// `band_measured` stays the raw ticks. gen4 has no counter. Edge-only.
// 102 → 103 (band-state night END, gen5/MG): an AUTO night now ENDS at the
// band's own last SLEEP second when the band's continuously observed tail
// after it is ≥ 10 min awake (UP/WAKE, no re-settling) — the lie-in is no
// longer counted as sleep, so in-bed/TST/efficiency and the wake time move
// earlier on those mornings (`sleep.band_offset_trim_sec` records the seconds
// removed). Naps cannot reclaim that tail: the nap main-sleep exclusion runs
// to the UNTRIMMED end (`_DayBlocksInput.napExcludeEndSec`). A band-corrected
// night replaces a banked longer one with the same onset, bounded to the
// corroborated tail (`isRicherSleep`). The morning readiness pin, which fires
// at `sleepOffsetSec + 1 h`, now freezes earlier on those mornings. UNCHANGED:
// onset, stages, which day owns the night (decided on the untrimmed end),
// gen4 (no band envelope), manual/confirmed overrides and the HR-led
// fallback. Analytics change: OpenStrap/analytics PR #80; kAnalyticsPin
// repinned to analytics main @ 4fc2b12, which also carries #81-#85.
// 103 → 104: detected naps require review; only accepted naps receive sleep credit.
// Detector methods and sibling pins are unchanged.
// 104 → 105 (gen5 on-chip step counter spans, issue #475): a strap_counter
// day also stores hourly `steps.spans` off the counter's per-record times,
// scaled to the calibrated `value`, so the day screen can place them. Edge-only.
// 105 → 106 (sweep batch, edge#506 #512): manual HR zones reach the day
// derive (Profile.toMap dropped `hr_zone_bounds`, so zone timeline/zone_source
// banded on the automatic set); the habitual-midsleep prior reads the bare
// `SleepWindow.toJson()` every writer stores (it never had history and every
// night anchored on the 03:30 cold start); tonight's sleep begun before
// midnight leaves the waking series behind strain/TRIMP/zones/calories,
// daytime HRV and the HR dip, and is no longer also booked as this day's nap
// (`PreparedDerivationDay.tonightSleepOnsetSec`); a saved session's HRR
// abstains when recording resumed more than 30 s after its end. Edge-only.
// 106 → 107: analytics main @ c0effea, #86 rmssd gate refuses noise windows, so the stored rmssd/hrv can go null or move.
// 107 → 108: a ring's own hypnogram stages the main sleep (`vendor_staged`, above auto, below the user's override) when it passes the plausibility gate. Edge-only.
// 108 → 109: analytics main @ 27b0ba4, #87: at low resting hr a breathing line that stays steady in Hz across the night lets rmssd publish (floor confidence) where the jitter gate refused it.
// 109 → 110: analytics main @ b7d5819, #78 #88-#91. Sleep detection no longer bridges unobserved recording gaps; bridges capped at 90 min. rmssd is one nightly estimator, the mean of the sleep session's 5-min windows, absent when the RR stream banks more beat-time than elapsed or no window has 20 clean differences; the RSA respiratory rate survives sensor gaps; strain (and the new trimp_net) is priced against the user's own quiet-waking level (quiet_hrr, median of 28 prior days, abstains under 3). Days derived before 110 keep their stored values.
// 110 → 111 (#315): new scalar `sdnn_window`, the mean of 5-min-window SDNNs over the sleep NN (windows under 21 beats left out); the Apple Health HRV SDNN sample now carries it instead of the drift-inflated whole-night `sdnn`, which is unchanged. Edge-only.
// (no bump) The multi-device wearable paths (`compute/inputs/`, the partial readiness composite, wearable worn-minutes and skin-temp cadence, ring nights) only run for a wearable whose developer flag is on and which is the active wearable; flags default off and a flag-off device contributes nothing. WHOOP output is unchanged, pinned by test/whoop_freeze_golden_test.dart against goldens generated from main.
// 111 → 112 (recovery calibration): analytics main @ 77fe373 (#95). Readiness merges HRV and RHR into one autonomic input (mean of their oriented z's, weight 0.70) and maps the composite z through the user's own spread once 14 prior nights exist: score = logistic(0.65·(z − ĉ)/σ̂), σ̂ = MAD×1.4826 of the trailing `readiness_z` series floored at 0.3, ĉ = its median capped to ±0.5 (re-centring; calibrating before 14 nights). The per-day composite z is stored as `readiness_z`; `readiness_calibration_backfill.dart` rebuilds it from stored drivers and re-scores days whose raw is pruned. readiness_lnrmssd's z/SWC/band use the prior window's median + MAD.
// 112 → 113 (contributed-data study, edge-only): day strain is floored at the
// strain of a finished, non-private session that day; a main sleep under 3 h
// yields no resting HR (absent with the reason) and so no RHR readiness input
// or `rhr` baseline entry; a day with no night of its own prices strain and
// energy on the median of prior nightly RHR (3+ nights, typed RHR first); an
// HR-led fallback window under 3 h or starting 10:00-19:00 local is not the
// main sleep (day sleepers exempt); WHOOP 5 nights get `skin_temp_dev_c` (°C
// against the median of prior nightly means, 14+ nights); WHOOP 4 nights
// store `skin_temp_ambient_r` and the illness watch leaves out WHOOP 4 nights
// whose skin temp tracks ambient (|r| >= 0.8, or unmeasured). One-shot,
// raw-free: days derived before v106 drop naps overlapping the next night.
//
// FORK-ONLY HISTORY (mikenrafter/edge before the 2026-10-18 upstream catch-up).
// The fork numbered its own versions 98-104 from the shared v97; those numbers
// were never upstream's. The owner chose upstream's numbering (merge log D4):
// the integrated build is 113 and every fork day (stored at <= 104) re-derives.
// The fork entries, as written then:
// | v98: Manual sleep candidate loading unions the asserted interval with the
// | automatic search range, retaining daytime and atypical cross-midnight input.
// | v99 (sleep window without data): a window the user set over a stretch
// | the band did not record (`tst_min` null) is a night NOT RECORDED. The
// | cross-day rollup no longer counts it in social jetlag / chronotype (n and
// | free-day mid-sleep), sleep debt, or the bedtime/wake guidance; sleep
// | performance reads the LAST night only (it used to reach back to an earlier
// | night's sleep time via `_lastNum` and score that); `midsleep_sec` /
// | `sleep_onset_sec` are no longer published for such a night; and the
// | habitual-midsleep prior is fed only nights that have a total sleep time.
// | Edge-side only: kAnalyticsPin/kProtocolPin UNCHANGED.
// | v100 (a night the user blanked stays blank): "Not sleep", and a window of
// | the user's own ('Set the times myself'), now REMOVE the night instead of
// | leaving the old one in place; the user's window bounds are still stored and
// | shown, its metrics are blank. Three stores kept it: the edge#305
// | "never write night-null over night-real" guard read the user's own blanking
// | as a pruned-raw regression and declined to write, so the old `day_result`
// | went on being served and scored; `metric_series` is REPLACE-per-key, so a
// | sleep key the derive no longer writes (`odi_per_hour`, `spo2`) kept its old
// | row forever; and the frozen morning-readiness pin kept the old score. A
// | blanked night now writes its blank in full, deletes every sleep-derived
// | `metric_series` row for the day in the same transaction as the write
// | (`kSleepDerivedMetricKeys`), drops that day's readiness pin, and — for a day
// | whose raw is already pruned — replaces just the night's blocks in the stored
// | bundle. The next nights are re-derived after the edit
// | (`rederiveAfterSleepEdit`) so their baselines no longer hold it. Only
// | 'confirmed' (agreeing with the app's own window) still stages a night.
// | Follow-ups, same version (outputs of un-overridden nights are unchanged): the
// | blank no longer needs any decoded row (`run`/`runDays` with an empty
// | `decoded_onehz`); `putDayResult` deletes the blanked `metric_series` keys
// | even for a partial row and `carryForwardDetail` no longer carries the old
// | night back into a blanked bundle; the blanked window is excluded from nap
// | detection; and the rolling `sleep_user_profile` is refolded without a
// | blanked night (observations are now stored in its payload, `folded_obs`).
// | Edge-side only: kAnalyticsPin/kProtocolPin UNCHANGED.
// | v101 (analytics repin 7334289 -> 65c8901): `lombScargle` now measures time
// | from the first sample instead of from the raw epoch seconds. On ~1.8e9 s the
// | trig arguments reached ~1e10 rad and the periodogram was off by up to ~5e-6
// | relative per frequency; the spectrum is shift invariant, so after the shift
// | the error is ~1e-13. Every Lomb-Scargle consumer moves at that level: stored
// | `hrvFreq` band powers and LF/HF, `cardiacCoherence`, the respiration RSA
// | rate, and the cardio stager's LF/HF (so a stage on a threshold can flip,
// | rarely). Real data moves ~1e-14 relative, so this bump is for the immutable
// | per-version rows, not for a visible change. The same pin also carries the
// | incremental states edge now uses on awake passes (`hrDipFromDayTotals`,
// | `IncrementalMinuteMetrics`, `IncrementalEnmoSeries`, `CalculationCache`) and
// | `IntHistogram`; those are bit-for-bit (or 1e-9) equal to their batch
// | readers and change no output.
// | v102: streamed day RR. A resumed day pass folds only the new beats into
// | the checkpoint's RrCorrector + IrregularScreenState and the three day
// | curves (dayHrvCurve, dayRespCurve, daytime HRV) instead of re-running
// | correctRr / irregularBeatScreen over the whole day. The curves are
// | bit-identical by construction; the streamed irregular screen keeps running
// | sums where the batch screen makes two passes, so its raw SD1/SD2 differ by
// | up to ~1.6e-11 (0 persisted-text mismatches in 120 randomly chunked days),
// | and a value within ~1e-11 of a 6-decimal rounding boundary (or a flag on
// | its 0.70 / 30 % threshold) could flip. Bumped so no per-version row can mix
// | the two (owner decision; to be folded into upstream's numbering later).
// | v103: PRV diagnostics (design 04 R4 follow-up). The irregular-rhythm screen
// | now stores the evidence behind its verdict, for the 24 h screen
// | (`clinical.irregular_24h.diagnostics`) and the sleep screen
// | (`clinical.irregular.diagnostics`, plus the sleep `pnn_pct`, `n_beats` and
// | `sd1_sd2` it computed and used to discard): beats in / kept after the
// | [300, 2000] ms filter, the corrector's raw / corrected / dropped counts,
// | artifact fraction, per-5-minute-window counts (total, voting, flagged, the
// | final OPEN window and what became of it, sustained share seen vs required),
// | the thresholds, and, for an abstention, the gate that stopped it. The
// | verdicts and figures themselves do not change; the payload does, so every
// | stored day re-derives. Comes from analytics 0fc57682b988c44cb5943c6e39a0746167388d46
// | (bf1be1981ed4fcd2ecd9958f0e0c742859eea20f plus the empty-input fix: the artifact
// | fraction is absent, not 1.0, when the corrector saw no beats)
// | (`irregularBeatScreenDetailed`, `IrregularScreenState.evaluateDetailed`,
// | state checkpoint version 2) on mikenrafter/openstrap-analytics
// | feat/prv-diagnostics, repinned below; verified present with
// | `git show 0fc57682b988c44cb5943c6e39a0746167388d46:lib/src/onehz/clinical/irregular_diagnostics.dart`. The day
// | checkpoint layout moved 3 -> 4 with it (the screen state gained counters), so
// | no old checkpoint is resumed with counts it never kept.
// | v104: analytics 0fc57682 - PRV diagnostics artifact_fraction is null (not 1.0)
// | when the corrector saw no beats; a separate version so finalized v103 rows from
// | the bf1be198 pin are recomputed. v103 stays as written above: a (day, 103) row
// | finalized by a build on the bf1be198 pin holds artifact_fraction 1.0 for a day
// | or night with no beats, and without this bump the 0fc57682 build would serve it
// | as if derived under the new pin (AGENTS 3.4). No verdict or figure changes.
// INTEGRATION: upstream 113 plus the fork's derivation changes above and the
// analytics integration branch (upstream's metric rules, the fork's streams;
// see kAnalyticsPin).
// 114: our single bump atop upstream 113 (merge log D27 revised, owner
// 2026-10-19), so no (day, 113) row derived by upstream is served as ours and
// every fork (day, 101..104) row re-derives. It covers every stored-output
// change of the integration: D16 (the fork's derivation changes and the
// analytics merge), D25 (the waking-HR dip hand-off), D28 (ring/wearable
// derive fixes) and D27: a typed sleep window ('manual') is no longer blanked
// but staged inside exactly the typed bounds, and a user's window ('manual' /
// 'confirmed') stores `sleep.stage_ranges` ({wake, light, deep, rem} ->
// {lo, hi} minutes, analytics `stageMinuteRanges`, pin ddb61f7), widened by
// every 30 s of the window the band did not record. 'rejected' still blanks.
// 115: D36 (owner: "fix + bump"). The personal stager profile was being trained
// on the longest night in the staging window, labelled as the target day's own:
// a long previous night was folded under a shorter target's id. Only the
// target's own staged night is folded now (none when it has no night). Staging
// also skips earlier days that cannot change the target (under 14 distinct
// nights of history), which is exact and moves no output by itself. Outputs
// that move: the profile, so later nights staged from it; this bump recomputes
// stored days once. No sibling re-pin is involved.
const int kAlgoVersion = 115;
class DerivationEngine {
  DerivationEngine({
    this.log,
    this.background = false,
    this.offloadActive,
    this.isBackgrounded,
    DerivePerf? perf,
  }) : perf = perf ??
            DerivePerf(nowMs: () => DateTime.now().millisecondsSinceEpoch);
  final void Function(String)? log;

  /// True while a band offload is draining. The scheduler never STARTS a
  /// derive during one, but one can start mid-pass; the raw prune checks this
  /// before archiving each substrate bucket and stops for the pass, so a drain
  /// commit waits behind at most one in-flight bucket (see
  /// `SubstrateArchive.archiveAndDeleteBefore`). Null — never yield — for
  /// headless engines, which derive after the band has disconnected.
  final bool Function()? offloadActive;

  /// Whether the app is in the background right now, asked when a pass ends.
  /// [background] is fixed at construction and picks the pacing; this follows a
  /// long-lived engine across lifecycle changes and picks what stays in memory.
  final bool Function()? isBackgrounded;
  bool get _lowMemory => background || (isBackgrounded?.call() ?? false);

  /// True when this engine was constructed inside a headless/background entry
  /// (iOS BGProcessingTask / BGAppRefreshTask, Android WorkManager, the
  /// post-drain background sync pass). The OS throttles CPU hard in those
  /// contexts, which changes two tuning decisions — see [_deriveConcurrency]
  /// and [_perDayTimeout]. Set at construction, not per-run, so a long-lived
  /// foreground engine can never inherit background tuning by accident.
  final bool background;

  /// PROCESS-WIDE, not per-engine. The thing it protects is the DATABASE, and
  /// there is one of those however many engines exist — but engines are built
  /// per call site (`lib/sync/background_sync.dart` constructs a fresh one for
  /// every headless wake), so an instance flag guarded nothing across them. Two
  /// passes could then derive the same day at once, and `partial`/`finalized`
  /// are decided before the write transaction, so the slower one's PARTIAL row
  /// could land on top of the faster one's complete row.
  static bool _running = false;
  bool get running => _running;

  /// Hold or release the process-wide latch, as another pass would.
  @visibleForTesting
  static set debugRunning(bool v) => _running = v;
  // The one step the status line shows for this pass. Static for the same
  // reason as [_running]: one pass at a time, however many engines exist.
  static CalcToken? _stageToken;
  static String? _stageLabel;

  /// Moves the shown step to [label] (null = none open). The same label twice
  /// is one step, so stages that read alike do not restart the clock. Main
  /// isolate only; every exit of a pass ends in `_calcStage(null)`, and the
  /// next pass's first call closes anything an earlier one left behind.
  static void _calcStage(String? label) {
    if (label == _stageLabel) return;
    final old = _stageToken;
    _stageToken = label == null ? null : CalcStatus.instance.begin(label);
    _stageLabel = label;
    if (old != null) CalcStatus.instance.end(old);
  }

  /// Run [body] under the process-wide derivation lock, returning [busy]
  /// unchanged if a pass is already in flight. Only for entry points that do
  /// NOT call another locked entry point (which would deadlock-by-skip).
  static Future<T> _withRunLock<T>(T busy, Future<T> Function() body) async {
    if (_running) return busy;
    _running = true;
    try {
      return await body();
    } finally {
      _running = false;
    }
  }
  final Map<String, dynamic> _diag = {
    'running': false,
    'stage': 'idle',
    'mode': null,
    'force': false,
    'started_at': null,
    'finished_at': null,
    'duration_ms': null,
    'raw_pages': 0,
    'raw_rows': 0,
    'max_day_raw_pages': 0,
    'max_day_raw_rows': 0,
    'scope_days': 0,
    'scope_reason': null,
    'prepared_days': 0,
    'todo_days': 0,
    'done_days': 0,
    'skipped_days': 0,
    // List, not a single day — several days can be in flight concurrently
    // (see run()'s bounded worker pool).
    'active_days': <String>[],
    'concurrency': 1,
    'last_error': null,
    // How the last run() ended (see [lastOutcome]).
    'last_outcome': null,
    // Summary of the last pass that computed at least one day (see [perf]).
    'last_pass_perf': null,
  };

  Map<String, dynamic> snapshot() => Map<String, dynamic>.from(_diag);

  DeriveOutcome? _lastOutcome;

  /// How the last [run] call ended; null before the first. A call refused
  /// because a pass was in flight reports failed 'busy' (it did not do the
  /// requested work). [run] keeps returning the day count for its many
  /// callers; the scheduler reads this to decide whether its job is done.
  DeriveOutcome? get lastOutcome => _lastOutcome;

  void _setOutcome(DeriveOutcome o) {
    _lastOutcome = o;
    _diag['last_outcome'] = o.toMap();
  }

  /// Test seams, null in production. [debugDayHook] runs at the top of
  /// processDay's try, before the day is prepared (a throw is handled like a
  /// failed prepare); [debugScopeHook] runs right after `_deriveScope` (a
  /// throw is a pass-level failure).
  @visibleForTesting
  Future<void> Function(String dayId)? debugDayHook;
  @visibleForTesting
  Future<void> Function()? debugScopeHook;

  /// Timing of the current / last pass. The scheduler feeds it the queue wait
  /// and hold reasons before a pass starts; run()/runDays()/rescanRecent()
  /// feed it the per-day phases. Measurement only: no metric reads it.
  final DerivePerf perf;

  /// Persist time of each day currently inside [_derivePreparedDay], read back
  /// by [_derivePreparedDayTimed] to split compute from persist.
  final Map<String, int> _persistMs = {};

  final Map<String, DayCalculationState> _calculationStates = {};
  static const _retainedCalculationDays = 3;

  /// The substrate each recent day's band loads returned, keyed `day|label`
  /// (`load_day`, `load_search`), so a warm pass reads only the rows that can
  /// have changed (substrate_retention.dart). Kept only for the days that hold
  /// a calculation state: dropped when the state is evicted or the day
  /// finalizes, by [trimForBackground], and for any day without a state at the
  /// end of a pass ([_pruneRetained]). Never held in the background.
  final Map<String, RetainedLoad> _retained = {};

  /// The cross-day union loads of the last two days this pass prepared
  /// (substrate_retention.dart: `windowHeavy`, `joinHeavy`, `usableStretches`). A day's
  /// night search, day and staged night overlap each other and its
  /// neighbours' by 15 to 27 hours; the next day to be prepared takes the part
  /// of its range that one of these still holds exactly and reads only the
  /// rest, so a cold pass reads each stored row once. Two, not one, because
  /// the days of a pool start in order but do not all reach the load at once.
  /// Released when the pass ends and whenever the app is backgrounded.
  final List<RetainedLoad> _unions = [];

  /// The turn at the union load. Days load it one at a time, in the order they
  /// asked: a day that began while its neighbour was still reading would read
  /// the same hours again. Only the load is serialised, never the staging.
  Future<void> _unionTurn = Future.value();


  /// The zone [_retained] was loaded under ([_zoneKey]).
  String? _retainedZone;

  static String _zoneKey() {
    final now = DateTime.now();
    return '${now.timeZoneName}|${now.timeZoneOffset.inMinutes}';
  }

  /// Seconds of beats re-read per query for the seconds a retained load holds.
  static const _rrPrefixSliceSec = 3600;

  static String _retainedKey(String day, String label) => '$day|$label';
  static String _retainedDay(String key) => key.substring(0, key.indexOf('|'));

  void _dropRetained(String day) =>
      _retained.removeWhere((k, _) => _retainedDay(k) == day);

  /// Keeps retained loads for the days that have a calculation state only.
  void _pruneRetained() => _retained
      .removeWhere((k, _) => !_calculationStates.containsKey(_retainedDay(k)));

  /// At most [_retainedCalculationDays] days are held, the newest.
  void _boundRetained() {
    final days = {for (final k in _retained.keys) _retainedDay(k)}.toList()
      ..sort();
    while (days.length > _retainedCalculationDays) {
      _dropRetained(days.removeAt(0));
    }
  }

  /// The days whose loaded substrate rows are held for the next pass.
  @visibleForTesting
  Iterable<String> get debugRetainedSubstrateDays =>
      {for (final k in _retained.keys) _retainedDay(k)}.toList()..sort();

  /// A finished session's observed-HR-ceiling result, keyed `day|session id`.
  /// [sig] names everything the result was computed from (see
  /// [_ceilingSignatures]); an entry is reused only on an exact match, and only
  /// by a periodic awake pass. Oldest entries go first.
  final Map<String, ({String sig, Map<String, dynamic> json, double? bpm})>
      _ceilingCache = {};
  static const _ceilingCacheMax = 128;
  int _ceilingHits = 0, _ceilingComputed = 0;

  /// Exact cardio epoch rows reused across stagings (RAM only). A row's key
  /// carries a fingerprint of every input to it, so a hit is the row a fresh
  /// computation would produce. Held ONLY as encoded chunks with their time
  /// bounds: this isolate never parses, merges, filters or encodes the rows. A
  /// staging is handed the chunks that overlap its window and returns one chunk
  /// that replaces them; a checkpoint worker is handed the same and embeds the
  /// part in its window.
  final List<CardioRowsChunk> _cardioRowChunks = [];

  /// Staged sleep candidates reused across passes (RAM only). OWNER: this
  /// engine instance, on the UI isolate; it never crosses an isolate. Keyed by
  /// day, algo version and a digest of the exact staging input
  /// ([stagingInputDigest]), so a rescan over unchanged inputs skips the
  /// staging while any moved input re-stages. Bounded by
  /// [kStagedSleepCacheMaxDays], least recently used out first. The engine has
  /// no dispose or data-reset path of its own: a wiped database changes the
  /// digest (a miss), and a failed or cancelled staging throws before anything
  /// is stored.
  final StagedSleepCache _stagedSleep = StagedSleepCache();

  /// True: every staging runs from scratch and nothing is stored (the oracle
  /// the reuse law compares against).
  @visibleForTesting
  bool debugDisableStagedSleepCache = false;

  /// Test seam (red phase of the single-load work): true = every day's
  /// search, day and sleep windows are loaded one by one, as today. The union
  /// load (one read per pass of what a day needs, sliced in memory) does not
  /// exist yet; the law test compares both settings byte for byte.
  @visibleForTesting
  bool debugDisableSubstrateUnionLoad = false;

  /// Most rows the loader held in RAM at once for one day's prepare: the
  /// largest of any single load's rows and of the loads alive together
  /// (day/nap + sleep). Slices of a held load are views of it, not counted.
  @visibleForTesting
  int debugSubstrateRowsHeldHighWater = 0;

  void _noteHeldRows(int rows) {
    if (rows > debugSubstrateRowsHeldHighWater) {
      debugSubstrateRowsHeldHighWater = rows;
    }
  }

  /// Most days of staged sleep the engine keeps in RAM for reuse.
  static const int kStagedSleepCacheMaxDays = 14;

  /// Days held by the staged-sleep cache.
  @visibleForTesting
  int get debugStagedSleepCacheSize => _stagedSleep.size;

  /// Most days the cache holds.
  @visibleForTesting
  int debugStagedSleepCacheMaxDays = kStagedSleepCacheMaxDays;

  /// Re-keys every cached entry to [algoVersion], as if it had been filled
  /// under that algo version.
  @visibleForTesting
  void debugStagedSleepCacheRekey(int algoVersion) =>
      _stagedSleep.rekey(algoVersion);

  @visibleForTesting
  int get debugCeilingHits => _ceilingHits;

  @visibleForTesting
  int get debugCeilingComputed => _ceilingComputed;

  /// The signature of each finished session of [day] whose ceiling can be
  /// cached, by session id. The session window is clipped to the samples the
  /// day substrate holds, because that is all `_dayHrCeiling` reads. The
  /// signature carries the algorithm version, the strap family, the clipped
  /// window, the decoded-sample revision over it ([LocalDb.decodedWindowFingerprint],
  /// which also sees an in-place replacement), and the priority order and owned
  /// spans that decided whose rows fill the substrate. A live session, one with
  /// no decoded samples to fingerprint, or one without an id is left out and is
  /// computed every pass.
  Future<Map<String, String>> _ceilingSignatures(
    PreparedDerivationDay day,
    List<Map<String, dynamic>> sessions,
  ) async {
    final s = day.daySub;
    if (s.length == 0) return const {};
    final first = s.tsSec.first, last = s.tsSec.last;
    final out = <String, String>{};
    for (final row in sessions) {
      final id = row['id']?.toString();
      final start = (row['start_ts'] as num?)?.toInt();
      final end = (row['end_ts'] as num?)?.toInt();
      if (id == null || start == null || end == null || end <= start) continue;
      if (row['status'] == 'live') continue;
      final lo = math.max(start, first), hi = math.min(end, last);
      final fp = await LocalDb.decodedWindowFingerprint(lo, hi);
      if (fp == null) continue;
      final owners = <String>[
        for (final sig in const [InputSignal.hr1Hz, InputSignal.accel1Hz])
          for (final span in day.ownership[sig] ?? const <OwnedSpan>[])
            if (span.end > lo && span.start <= hi)
              '${sig.name}:${span.start}-${span.end}:${span.deviceId ?? ''}',
      ];
      out[id] = '$kAlgoVersion|${s.deviceFamily}|$start-$end|$lo-$hi|$fp|'
          '${priorityKey(day.priority)}|${owners.join(',')}';
    }
    return out;
  }

  /// Keeps [state] as [day]'s checkpoint for the next periodic pass.
  ///
  /// A [finalized] day is frozen and never recomputed incrementally, so it
  /// keeps none. In the background only the newest day keeps one, and its
  /// motion series is released ([trimForBackground]). Dropping a state never
  /// changes a result; the next pass for that day recomputes in full.
  void _publishCalculationState(String day, DayCalculationState state,
      {bool finalized = false}) {
    _calculationStates.remove(day);
    if (!finalized) {
      _calculationStates[day] = state;
    } else {
      _dropRetained(day);
    }
    // Prefer the newest calendar days when a heavy pass also visits history.
    final labels = _calculationStates.keys.toList()..sort();
    final keep = _lowMemory ? 1 : _retainedCalculationDays;
    while (labels.length > keep) {
      final evicted = labels.removeAt(0);
      _calculationStates.remove(evicted);
      _dropRetained(evicted);
    }
    if (_lowMemory) {
      _retained.clear();
      for (final s in _calculationStates.values) {
        s.compact();
      }
    }
  }

  /// The app went to the background: keep only the newest day's checkpoint and
  /// drop the samples it holds. Called from the lifecycle handler; costs
  /// nothing when there is nothing to drop.
  void trimForBackground() {
    _cardioRowChunks.clear();
    _retained.clear();
    _unions.clear();
    final before = _calculationStates.length;
    final labels = _calculationStates.keys.toList()..sort();
    while (labels.length > 1) {
      _calculationStates.remove(labels.removeAt(0));
    }
    for (final s in _calculationStates.values) {
      s.compact();
    }
    _log('[perf] mem trim states=$before->${_calculationStates.length} '
        '${_memLine()}');
  }

  /// RSS and what this engine holds, for the `[perf] mem` log lines.
  String _memLine() => DerivePerf.memLine(
        rssBytes: ProcessInfo.currentRss,
        states: _calculationStates.length,
        retainedSamples: debugRetainedSamples,
        cacheComputations: _calculationStates.values
            .fold(0, (n, s) => n + s.computations),
        cacheHits:
            _calculationStates.values.fold(0, (n, s) => n + s.hits),
      );

  @visibleForTesting
  int get debugRetainedSamples => _calculationStates.values
      .fold(0, (n, s) => n + s.retainedSamples);

  @visibleForTesting
  List<String> get debugCalculationStateDays =>
      _calculationStates.keys.toList()..sort();

  @visibleForTesting
  ({
    int computations,
    int hits,
    int minutes,
    int motionPoints,
    int hrSamples,
    int orientationSamples,
    int stepSamples,
  })?
      debugCalculationState(String day) {
    final state = _calculationStates[day];
    return state == null ? null : (computations: state.computations,
      hits: state.hits,
      minutes: state.processedMinutes, motionPoints: state.processedMotionPoints,
      hrSamples: state.processedHrSamples,
      orientationSamples: state.processedOrientationSamples,
      stepSamples: state.processedStepSamples);
  }

  /// Main-isolate failure seam after both workers completed, before their writes.
  @visibleForTesting
  Future<void> Function(String day)? debugAfterDayBlocks;

  /// Run once a pass's writes have landed (the end of [run], a rescan, an
  /// import's rollup, applied activity reviews). Upstream restamped Today's
  /// freshness here directly, because a night settled in an iOS background
  /// pass otherwise kept serving the previous one. The owner of the engine
  /// decides how: AppState requests a PublishGate publish (freshness, then
  /// the bump); the headless builder (`newHeadlessDerivationEngine`), which
  /// has no gate, refreshes freshness. Null does nothing.
  Future<void> Function()? onSettled;

  Future<void> _settled() async {
    try {
      await onSettled?.call();
    } catch (e) {
      _log('[derive] freshness refresh failed: $e');
    }
  }

  // ── the finalization audit ───────────────────────────────────────────────
  // When a day finalizes and the Calculations power policy allows heavy work,
  // the day is re-derived once on the pure batch path, compared with the
  // accumulator result about to be frozen, and the BATCH result is what gets
  // frozen. Either field null = feature off (no audit, no pending mark). The
  // owner of the engine assigns both; the power is read at the moment of
  // finalization, never cached.
  CalcPowerPolicy? auditPolicy;
  Future<PowerState> Function()? auditPowerRead;

  /// Applied to a finished accumulator-path bundle before the audit and the
  /// write; how a test injects "the accumulator path disagreed".
  @visibleForTesting
  Map<String, dynamic> Function(String day, Map<String, dynamic> bundle)?
      debugAccumulatorTamper;

  /// The bundle a batch-reference pass of [_derivePreparedDay] stops at, by day.
  final Map<String, Map<String, dynamic>> _batchBundles = {};

  /// [day]'s bundle derived on the pure batch path: freshly prepared with every
  /// beat (no checkpoint resume), no calculation state, no streamed figures, no
  /// row caches, no writes. Null when the day cannot be derived whole (the
  /// caller then does not audit it).
  Future<Map<String, dynamic>?> _batchBundle(String dayId, Profile profile,
      int dataNowSec, _BaselineHistoryCache history) async {
    perf.addCount('audit_batch_runs', 1);
    try {
      final prepared = await _prepareTargetDay(dayId, reuse: false, banked: true);
      if (prepared == null) return null;
      _batchBundles.remove(dayId);
      await _derivePreparedDay(prepared, profile, dataNowSec, history,
          batchReference: true);
      // The same JSON round trip the stored value takes.
      final b = _batchBundles.remove(dayId);
      return b == null
          ? null
          : (jsonDecode(jsonEncode(b)) as Map).cast<String, dynamic>();
    } catch (e) {
      _auditLog('[audit] $dayId batch derive failed: $e');
      return null;
    } finally {
      _batchBundles.remove(dayId);
    }
  }

  /// One audit event: log the verdict and fold it into the persistent counter
  /// (and clear [day] from the pending list).
  Future<void> _recordAudit(String day, AuditResult r) async {
    _auditLog(auditLogLine(day, r));
    await LocalDb.updateFinalizationAudit((s) {
      s.runs++;
      if (!r.ok) {
        s.diffs++;
        s.lastDiffDay = day;
        s.lastDiffKeys = r.diffKeys;
      }
      s.pending.remove(day);
    });
  }

  /// Audits every pending finalized day when the policy allows it now; returns
  /// how many were audited. The rows are frozen, so a diff here is LATE: it is
  /// logged and counted and the stored row is kept. A day whose raw is no longer
  /// what it was derived from is dropped with `[audit] <day> skipped`.
  Future<int> auditPendingFinalizations(Profile profile) async {
    final policy = auditPolicy, read = auditPowerRead;
    if (policy == null || read == null) return 0;
    final pending = (await LocalDb.finalizationAudit()).pending;
    if (pending.isEmpty || !policy.mayAuditFinalization(await read())) return 0;
    final dataNowSec = await LocalDb.lastDecodedRecTs() ?? 0;
    final profileSig = _profileSignature(profile);
    final derived = await LocalDb.derivedFingerprints(kAlgoVersion);
    final history = await _BaselineHistoryCache.load();
    var audited = 0;
    for (final day in pending) {
      final fps = await LocalDb.decodedDayFingerprints(
          {day, _adjacentDayIds(day).first});
      final fp = deriveFingerprint(
          profileSig: profileSig,
          own: fps[day],
          previous: fps[_adjacentDayIds(day).first]);
      final row = await LocalDb.dayResult(day);
      final stored =
          row == null ? null : _decodeBundle(row['payload_json']);
      final batch = fp != null && fp == derived[day] && stored != null
          ? await _batchBundle(day, profile, dataNowSec, history)
          : null;
      if (batch == null) {
        _auditLog('[audit] $day skipped');
        await LocalDb.updateFinalizationAudit((s) => s.pending.remove(day));
        continue;
      }
      await _recordAudit(
          day, auditFinalization(stored!, await _asWritten(row!, batch)));
      audited++;
    }
    return audited;
  }

  /// [batch] as the write that froze [row] would have stored it, for the late
  /// audit (which compares against the STORED payload): the write stamps the
  /// data edge (an input stamp like computed_at, not a metric, so the stored
  /// one is carried over) and `putDayResult` composes the day's reviewed naps
  /// into it.
  Future<Map<String, dynamic>> _asWritten(
      Map<String, Object?> row, Map<String, dynamic> batch) async {
    final out = <String, dynamic>{...batch};
    final stored = _decodeBundle(row['payload_json']);
    if (stored != null && stored.containsKey('data_edge_sec')) {
      out['data_edge_sec'] = stored['data_edge_sec'];
    }
    // A pending audit is always of a derive-finalized day, which the engine
    // writes as source 'band'.
    composeAcceptedNaps(out,
        await ActivityStore.napEdits(await LocalDb.instance, '${row['day_id']}'));
    return out;
  }

  /// The audit at a day's finalization: [bundle] is the accumulator result
  /// about to be frozen; the returned bundle is what gets frozen. With power
  /// the batch reference replaces it (after the comparison); without, the day
  /// is marked pending and finalizes as is.
  Future<Map<String, dynamic>> _auditAtFinalization(
    PreparedDerivationDay day,
    Profile profile,
    int dataNowSec,
    _BaselineHistoryCache history,
    Map<String, dynamic> bundle,
  ) async {
    final policy = auditPolicy, read = auditPowerRead;
    if (policy == null || read == null) return bundle;
    Future<void> markPending() => LocalDb.updateFinalizationAudit(
        (s) => s.pending.add(day.date));
    try {
      if (!policy.mayAuditFinalization(await read())) {
        await markPending();
        return bundle;
      }
      final batch = await _batchBundle(day.date, profile, dataNowSec, history);
      if (batch == null) {
        await markPending();
        return bundle;
      }
      await _recordAudit(day.date, auditFinalization(bundle, batch));
      return batch;
    } catch (e) {
      _auditLog('[audit] ${day.date} not audited: $e');
      return bundle;
    }
  }

  @visibleForTesting
  Future<void> debugDerivePreparedDay(PreparedDerivationDay day, Profile profile,
      int dataNowSec, {ana.CalculationMode calculationMode = ana.CalculationMode.forced}) async {
    await _derivePreparedDay(day, profile, dataNowSec,
      await _BaselineHistoryCache.load(), calculationMode: calculationMode);
  }


  /// [_derivePreparedDay] with its wall time reported to [perf]: persist as
  /// measured around `putDayResult`, compute as the rest.
  Future<DayDerive> _derivePreparedDayTimed(
    PreparedDerivationDay day,
    Profile profile,
    int dataNowSec,
    _BaselineHistoryCache history, {
    ana.CalculationMode calculationMode = ana.CalculationMode.forced,
    DayResultWrite reason = DayResultWrite.derive,
    void Function(String day)? onStaleTonight,
  }) async {
    final sw = Stopwatch()..start();
    try {
      return await _derivePreparedDay(day, profile, dataNowSec, history,
          calculationMode: calculationMode,
          reason: reason,
          onStaleTonight: onStaleTonight);
    } finally {
      final persist = _persistMs.remove(day.date);
      final total = sw.elapsedMilliseconds;
      perf.addPhase(
        day.date,
        DerivePhase.compute,
        persist == null ? total : (total - persist < 0 ? 0 : total - persist),
      );
      if (persist != null) perf.addPhase(day.date, DerivePhase.persist, persist);
    }
  }

  /// [_prepareTargetDay] with its wall time reported to [perf].
  Future<PreparedDerivationDay?> _prepareTargetDayTimed(String dayId,
      {bool reuse = false}) async {
    final sw = Stopwatch()..start();
    try {
      return await _prepareTargetDay(dayId, reuse: reuse);
    } finally {
      perf.addPhase(dayId, DerivePhase.prepare, sw.elapsedMilliseconds);
    }
  }

  /// Publish a finished pass's timing: on `snapshot()` and as one
  /// `[perf] derive …` log line.
  /// A pass that computed no day (nothing to do, refused) keeps the previous
  /// real pass on show instead of overwriting it with an empty one.
  void _finishPassPerf() {
    _pruneRetained();
    _unions.clear();
    perf.endPass();
    final s = perf.summary();
    if (((s['days'] as int?) ?? 0) == 0) return;
    _diag['last_pass_perf'] = s;
    _log(perf.logLine());
    _log('[perf] mem bg=$_lowMemory ${_memLine()}');
  }

  /// Run a derivation pass. [heavy]=false runs a bounded light pass over the
  /// freshness-critical day: TODAY when raw has reached today, else the latest
  /// pending day. [heavy]=true sweeps every recomputable day.
  /// [force]=true recomputes EVERY non-finalized day regardless of the cursor.
  /// Re-entrant calls are coalesced. Returns the number of days computed.
  ///
  /// [calculationMode] says whether cached calculations may be reused;
  /// [force] and [heavy] always override it with a full run.
  ///
  /// [changedOnly] (a manual sync) narrows the todo set to days whose input
  /// changed since they were last derived — see [selectChangedDays]. [onScope]
  /// is told how many days this pass will compute as soon as that is known
  /// (0 = nothing to do), before the first day starts. It is not called when
  /// the pass is refused (already running) or fails before it has a scope.
  /// [onScopeDays] hears the same scope as a newest-first day list (empty =
  /// nothing to do), and [onCrossDay] is true while the baseline / cross-day
  /// step runs, so a screen can tell which results are still on the way.
  Future<int> run(
    Profile profile, {
    bool heavy = false,
    bool force = false,
    bool changedOnly = false,
    ana.CalculationMode calculationMode = ana.CalculationMode.forced,
    void Function(String day, int index, int total)? onDayDone,
    void Function(int total)? onScope,
    void Function(List<String> days)? onScopeDays,
    void Function(bool active)? onCrossDay,
  }) async {
    // [changedOnly] only narrows the scope; the automatic light pass uses it,
    // so it must not turn reuse off.
    final selectedMode = force ? ana.CalculationMode.forced
        : heavy ? ana.CalculationMode.heavy : calculationMode;
    if (_running) {
      _setOutcome(const DeriveOutcome(failed: true, error: 'busy'));
      return 0;
    }
    _running = true;
    beginWearableDayIndexPass();
    _calcStage('Reading recordings');
    var passComputed = 0;
    var passTransient = 0;
    String? passError;
    perf.startPass();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    _diag
      ..['running'] = true
      ..['stage'] = 'scope'
      ..['mode'] = force ? 'force' : (heavy ? 'heavy' : 'light')
      ..['force'] = force
      ..['started_at'] = startedAt
      ..['finished_at'] = null
      ..['duration_ms'] = null
      ..['raw_pages'] = 0
      ..['raw_rows'] = 0
      ..['max_day_raw_pages'] = 0
      ..['max_day_raw_rows'] = 0
      ..['scope_days'] = 0
      ..['scope_reason'] = null
      ..['prepared_days'] = 0
      ..['todo_days'] = 0
      ..['done_days'] = 0
      ..['skipped_days'] = 0
      ..['unchanged_days'] = 0
      ..['active_days'] = <String>[]
      ..['concurrency'] = _deriveConcurrency
      ..['last_error'] = null;
      
    FirebaseTraceHandle? runTrace;
    try {
      // Heavy/force passes only. Light passes run many times a day (including
      // all night in the background), and each trace is buffered + eventually
      // uploaded — periodic radio wakeups from a local-first app, for timings
      // the _diag map already captures locally.
      if (FirebaseBridge.isInitialized && (heavy || force)) {
        runTrace = await FirebaseBridge.startTrace('derivation_engine_run');
        runTrace.putAttribute('mode', force ? 'force' : (heavy ? 'heavy' : 'light'));
      }
    } catch (_) {}

    try {
      // From the flags, every pass: a headless wake derives before (or
      // without) the app's own start-up load.
      await refreshSessionSensorSources();
      // FIRST, ahead of every early return below: it reads only stored bundles,
      // so an install with bundles but no decoded rows (a restore) or with
      // every day finalized still gets its quiet levels — the live gauge and
      // session scoring need them as much as a derive does. And before the
      // history snapshot, so this very sweep prices strain on them. One-shot
      // (`compute_freshness`); a failure leaves the key unset and the next pass
      // retries — never fatal to the derive.
      _diag['stage'] = 'quiet_hrr_seed';
      var seeded = 0;
      try {
        seeded = await seedQuietHrrHistoryOnce(
          ageYears: profile.ageYears,
          manualRestingHr: profile.restingHrManual?.toDouble(),
        );
        if (seeded > 0) _log('[derive] quiet_hrr seed: $seeded day(s)');
      } catch (e) {
        _log('[derive] quiet_hrr seed failed (will retry): $e');
      }
      // v112 readiness calibration: the readiness_z history the derive's
      // calibration reads, for the recent window only (bounded, decoded off
      // this isolate). The history-wide part and the re-score of days with
      // no substrate run after the sweep, in `finally`. One-shot.
      _diag['stage'] = 'readiness_z_seed';
      try {
        final z = await seedRecentReadinessZ();
        if (z > 0) {
          _log('[derive] readiness_z seed: $z day(s)');
          seeded += z;
        }
      } catch (e) {
        _log('[derive] readiness_z seed failed (will retry): $e');
      }
      // New levels move the baseline signature `rescanRecent` gates on.
      // Refreshed here, ahead of every early return: on a pass with nothing
      // to derive nothing else would, and the days the levels now price would
      // never be re-scored. Its own guard — the seed is already marked done,
      // so a failure here is not a seed failure; the next refresh catches up.
      if (seeded > 0) {
        try {
          await _refreshBaselines();
        } catch (e) {
          _log('[derive] baseline refresh after the quiet_hrr seed failed: $e');
        }
      }
      // Archived records today's decoder can read (old-firmware v12), back
      // into the decoded store ahead of the scope, so this pass derives the
      // days they fill. One-shot and foreground-only: it can be a million
      // frames, which a short background budget should not take on.
      if ((heavy || force) && !background) {
        _diag['stage'] = 'archive_redrive';
        try {
          final n = await LocalDb.redriveArchiveOnce();
          if (n > 0) _log('[derive] archive redrive: $n second(s) recovered');
        } catch (e) {
          _log('[derive] archive redrive failed (will retry): $e');
        }
        // Raw-free: old days that booked tonight's sleep as a nap.
        try {
          final n = await cleanNextNightNapsOnce();
          if (n > 0) _log('[derive] nap cleanup: $n day(s)');
        } catch (e) {
          _log('[derive] nap cleanup failed (will retry): $e');
        }
      }
      _diag['stage'] = 'scope';
      final scope = await _deriveScope(heavy: heavy, force: force);
      await debugScopeHook?.call();
      _diag
        ..['scope_days'] = scope.targetDays.length
        ..['scope_reason'] = scope.reason;
      final dataNowSec =
          await _withWearableEdge(await LocalDb.lastDecodedRecTs()) ?? 0;
      // No decoded row anywhere (everything pruned, only `day_result` left).
      // The only thing left to do is the user's blanking, which is a write
      // over stored results and needs no raw and no data edge.
      final noData = dataNowSec <= 0;
      final blankOnly = noData ? await _blankingOverrideDays() : <String>{};
      if (noData && blankOnly.isEmpty) {
        _log('derive: no decoded data');
        onScope?.call(0);
        onScopeDays?.call(const []);
        return 0;
      }
      // A forced pass is the user's own re-derive: settled days reopen for it.
      final finalized = force
          ? await LocalDb.finalizedDayIds(kAlgoVersion)
          : await _finalizedOrSettled();
      // A user sleep override (manual / confirmed) must take effect even on a
      // FINALIZED (locked) day — it's the user's word. Force those back into the
      // todo set. (No-raw days are guarded in the per-day loop so we never
      // clobber a good manual result with an empty re-derive once raw is pruned.)
      final overrideDays = {
        ...await LocalDb.sleepOverrideDays(),
        // A nap edit on a finalized day has to take effect too — same reason.
        ...await LocalDb.napEditDays(),
      };
      var todoDays = noData
          ? (blankOnly.toList()..sort())
          : [
              for (final day in scope.targetDays)
                if (!finalized.contains(day) || overrideDays.contains(day)) day,
            ];
      // What each candidate day's input looks like right now. Taken BEFORE the
      // derive reads anything, so rows that land mid-derive make the recorded
      // fingerprint stale (=> re-derive next time), never falsely current.
      final profileSig = _profileSignature(profile);
      final fps = todoDays.isEmpty
          ? const <String, String>{}
          : await LocalDb.decodedDayFingerprints({
              for (final d in todoDays) ...[d, _adjacentDayIds(d).first],
            });
      final dayFp = <String, String?>{
        for (final d in todoDays)
          d: deriveFingerprint(
            profileSig: profileSig,
            own: fps[d],
            previous: fps[_adjacentDayIds(d).first],
          ),
      };
      if (!noData && changedOnly && !force && todoDays.isNotEmpty) {
        final changed = selectChangedDays(
          todoDays: todoDays,
          current: dayFp,
          derived: await LocalDb.derivedFingerprints(kAlgoVersion),
          prunePending: prunePendingDays(
            rawDays: scope.rawDays,
            derivedDayIds: await LocalDb.dayResultIds(kAlgoVersion),
            dataNowSec: dataNowSec,
          ),
        );
        _diag['unchanged_days'] = todoDays.length - changed.length;
        if (changed.length != todoDays.length) {
          _log(
            'derive: ${todoDays.length - changed.length} of '
            '${todoDays.length} day(s) unchanged since their last derive — '
            'skipped',
          );
        }
        todoDays = changed;
      }
      if (todoDays.isEmpty) {
        _log(changedOnly && (_diag['unchanged_days'] as int) > 0
            ? 'derive: nothing changed — nothing to do'
            : 'derive: all days finalized — nothing to do');
        // A day still owed a strain score is unfinalized, so it is normally in
        // the todo set; re-score it here too rather than leave it a pass.
        final rescored = noData
            ? 0
            : await _quietLevelRepass(profile, dataNowSec, scope.rawDays);
        if (rescored > 0) {
          await _refreshBaselines();
          await _runCrossDay(profile);
          await _runNotifications();
        }
        onScope?.call(0);
        onScopeDays?.call(const []);
        if (!noData) await _pruneOldDecoded(scope.rawDays, dataNowSec);
        return rescored;
      }
      _diag['todo_days'] = todoDays.length;
      onScope?.call(todoDays.length);
      onScopeDays?.call(todoDays.reversed.toList());
      _diag['stage'] = 'history';
      _calcStage('Reading recordings');
      final history = await _BaselineHistoryCache.load();
      _log(
        'derive: ${todoDays.length} day(s) '
        '(${force
            ? "force"
            : heavy
            ? "heavy"
            : "light"}; '
        '${scope.reason}; v$kAlgoVersion; '
        'concurrency=$_deriveConcurrency)',
      );

      // Newest-first: `scope.targetDays` sorts ascending (oldest first), which
      // is exactly backwards from what the user actually wants when they open
      // the app after a backlog — today/most-recent should be among the very
      // FIRST days dispatched, not the last one a long sweep gets to. A no-op
      // for the light path (0-1 days), so always safe to apply.
      final orderedDays = todoDays.reversed.toList();

      var done = 0;
      var completed = 0;
      var failures = 0;
      final activeDays = <String>{};
      _diag['stage'] = 'per_day';
      _calcStage('Day calculations');
      _diag['active_days'] = const <String>[];

      // One day's full prepare→compute→persist body (identical to the old
      // sequential loop's per-iteration work) — extracted so it can run as a
      // unit inside the worker pool below. Concurrency-safe: everything it
      // touches is either (a) day_id-keyed DB rows (independent across days),
      // (b) the read-only `history` snapshot (frozen before this loop starts,
      // refreshed only after it ends — see `_BaselineHistoryCache`), or (c)
      // shared counters mutated via single, non-`await`-split statements,
      // which Dart's cooperative single-threaded scheduler makes atomic
      // relative to the other concurrent workers even though the actual
      // isolate CPU work they await genuinely runs in parallel across cores.
      // Days that would have finalized on a tonight's sleep the next day's
      // concurrent derive has since moved: derived again after the pool.
      final staleTonight = <String>{};
      Future<void> processDay(String dayId, {bool repass = false}) async {
        activeDays.add(dayId);
        _diag['active_days'] = activeDays.toList();
        var reportDone = true;
        try {
          await debugDayHook?.call(dayId);
          final prepared = await _prepareTargetDayTimed(dayId,
              reuse: !(force || overrideDays.contains(dayId)));
          // Override day whose raw has been pruned (≥14 d): re-deriving would
          // produce an empty/absent result and clobber the user's manual sleep.
          // Keep the existing locked result instead.
          if (prepared != null &&
              prepared.daySub.isEmpty &&
              overrideDays.contains(dayId) &&
              // ...unless the user blanked it: then the stored night is the
              // thing to remove, and `_derivePreparedDay` does that.
              await _userBlankedNight(dayId, null) == null) {
            _log('derive day $dayId skipped: override day, raw pruned — kept');
          } else if (prepared != null) {
            _diag['prepared_days'] = (_diag['prepared_days'] as int) + 1;
            final committed = await _derivePreparedDayTimed(
                prepared, profile, dataNowSec, history,
                calculationMode: selectedMode,
                // A force pass and a sleep/nap-edit day are the user's own
                // doing, so they may rewrite a frozen (finalized) row.
                reason: force || overrideDays.contains(dayId)
                    ? DayResultWrite.userOverride
                    : DayResultWrite.derive,
                onStaleTonight: repass ? null : staleTonight.add);
            if (repass) {
              // Counted and reported by its first derive.
              if (committed != DayDerive.refused) {
                await _recordDerivedFingerprint(dayId, dayFp[dayId]);
              }
              if (committed == DayDerive.declined) await _settleDay(dayId, fps);
              reportDone = false;
            } else if (committed == DayDerive.committed) {
              done++;
              _diag['done_days'] = done;
              await _recordDerivedFingerprint(dayId, dayFp[dayId]);
            } else if (committed == DayDerive.declined) {
              // Handled, not derived: no `done` (that would run baselines and
              // cross-day for nothing), but settled so it is not picked again.
              await _recordDerivedFingerprint(dayId, dayFp[dayId]);
              await _settleDay(dayId, fps);
            } else {
              reportDone = false;
            }
          } else {
            _log('derive day $dayId skipped: no bounded window payload');
            await _markDaySkipped(
              dayId,
              _localNextDayLabelToSec(dayId),
              dataNowSec,
              reason: 'no_bounded_window_payload',
            );
            _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
            _diag['last_error'] = 'no_bounded_window_payload day=$dayId';
            failures++;
            // Structural (the same input will fail the same way): record it so
            // an unchanged day is not retried on every sync. Transient
            // failures, below, are never recorded.
            await _recordDerivedFingerprint(dayId, dayFp[dayId]);
          }
        } catch (e) {
          _log('derive day $dayId FAILED/skipped: $e');
          final dayEndSec = _localNextDayLabelToSec(dayId);
          final skipReason = _skipReasonForError(e);
          await _markDaySkipped(
            dayId,
            dayEndSec,
            dataNowSec,
            reason: skipReason,
          );
          if (!_transientSkipReasons.contains(skipReason)) {
            await _recordDerivedFingerprint(dayId, dayFp[dayId]);
          } else {
            passTransient++;
          }
          _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
          _diag['last_error'] = '$e';
          failures++;
        }
        activeDays.remove(dayId);
        _passPendingDays.remove(dayId);
        _diag['active_days'] = activeDays.toList();
        if (reportDone) {
          completed++;
          onDayDone?.call(dayId, completed, orderedDays.length);
        }
      }

      _passPendingDays = orderedDays.toSet();
      try {
        await runWithConcurrency(orderedDays, _deriveConcurrency, processDay);
      } finally {
        _passPendingDays = <String>{};
      }
      if (staleTonight.isNotEmpty) {
        _diag['stage'] = 'tonight_repass';
        _log('derive: ${staleTonight.length} day(s) again, tonight\'s sleep '
            'moved under them');
        await runWithConcurrency(
            [for (final d in orderedDays) if (staleTonight.contains(d)) d],
            _deriveConcurrency,
            (d) => processDay(d, repass: true));
      }
      // BEFORE the prune below: a day still owed a strain score is re-scored
      // while its raw exists (and the prune holds it if this fails).
      _diag['stage'] = 'quiet_repass';
      done += await _quietLevelRepass(profile, dataNowSec, scope.rawDays);

      // 4. Cross-day rollup + notifications (best-effort).
      if (done > 0) {
        onCrossDay?.call(true);
        try {
          _diag['stage'] = 'baselines';
          _calcStage('Baselines');
          await _refreshBaselines();
          _diag['stage'] = 'cross_day';
          _calcStage('Trends across days');
          await _runCrossDay(profile);
        } finally {
          onCrossDay?.call(false);
        }
        _diag['stage'] = 'notifications';
        _calcStage('Notifications');
        await _runNotifications();
      }
      // 5. Prune raw — never for a day still inside its raw window / not finalized.
      // Runs on EVERY derive, not just a full restage: `rawRetentionDays` is
      // the only cap on the 1 Hz substrate, and behind `scope.fullHistory` it
      // fired only on a manual "Re-analyze data", so an ordinary install grew
      // ~12 MB/day without bound. `_pruneOldDecoded` is day-scoped and bounded,
      // so it is safe to run this often.
      _diag['stage'] = 'prune';
      _calcStage('Tidying up');
      if (!noData) await _pruneOldDecoded(scope.rawDays, dataNowSec);
      // The timezone hold is a FULL-RESTAGE concept — only a restage actually
      // re-derives every held day — so clearing it stays behind fullHistory.
      if (scope.fullHistory && !noData) {
        // Re-baseline the travel guard — but ONLY if every targeted day
        // actually got re-derived under the current timezone. processDay
        // swallows per-day errors and marks the day skipped, so a restage can
        // "finish" with days still unresolved; clearing the hold then would
        // drop it without the adjacency ever having been fixed. (A day kept
        // deliberately — a pruned override day — is not a failure.)
        if (failures == 0) {
          await LocalDb.putBaseline(
            'tz_travel_guard',
            jsonEncode({'offset_min': DateTime.now().timeZoneOffset.inMinutes}),
          );
        } else {
          _log(
            'derive: $failures day(s) unresolved — keeping the timezone hold',
          );
        }
      }
      passComputed = done;
      return done;
    } catch (e, st) {
      _diag['last_error'] = '$e';
      passError = '$e';
      _log('derive ERROR: $e\n$st');
      return 0;
    } finally {
      // Pending audits of earlier finalizations, once power allows. Before the
      // pass timing closes so its counter lands in this pass.
      try {
        await auditPendingFinalizations(profile);
      } catch (e) {
        _auditLog('[audit] pending audits failed: $e');
      }
      _setOutcome(DeriveOutcome(
        computed: passComputed,
        transientFailures: passTransient,
        failed: passError != null,
        error: passError,
      ));
      _finishPassPerf();
      // Storage housekeeping runs here, after everything, still holding
      // `_running`. See _runStorageHousekeeping — this is the only place every
      // entry path and every early return actually reaches.
      _diag['stage'] = 'housekeeping';
      _calcStage('Tidying up');
      await _runStorageHousekeeping();
      // ONE-SHOT: rescale stored strain onto the recalibrated scale. Days
      // inside the raw window re-derive from substrate above; everything older
      // has none, so its headline is rebuilt from the stored TRIMP + wake
      // window instead. No-ops after the first successful pass
      // (`compute_freshness`), and never fatal — a failed rescale must not take
      // the derive cycle down with it.
      //
      // AFTER the sweep, not before it. It used to be the first statement of
      // run(), so the one launch where it actually fires — the first after the
      // version bump, the launch the user is watching — spent a DB round trip
      // and a bundle decode+encode PER DAY OF HISTORY before today's data was
      // touched at all. Nothing in the sweep reads what it rewrites (it only
      // ever touches days older than `rawRetentionDays`, which no pass
      // re-derives), so the only thing the old ordering bought was that the
      // FIRST cross-day rollup after the bump saw the rescaled history rather
      // than the next one. Still holds `_running`, so nothing else can be
      // reading day_result while it rewrites.
      _diag['stage'] = 'strain_rescale';
      _calcStage('Strain rescale');
      try {
        final rescaled = await backfillStrainScale(
          female: workoutSex(profile.sex) == 'female',
        );
        if (rescaled.didWork) {
          _log('[derive] strain rescale: ${rescaled.bundleDays} day(s) '
              'rebuilt, ${rescaled.skipped} skipped (no TRIMP or no wake '
              'window)');
        }
      } catch (e) {
        _log('[derive] strain rescale failed (kept old values): $e');
      }
      // ONE-SHOT, after the sweep for the same reason as the strain rescale:
      // the rest of the readiness_z history, then a re-score of every day
      // below v112 that has no raw substrate left (substrate days were just
      // re-derived, or are retried next pass). A re-score rewrites stored
      // days, so the baselines and the cross-day rollup are refreshed here —
      // `finally` is reached by every early return, including "nothing to
      // derive" and "no decoded data".
      _diag['stage'] = 'readiness_calibration';
      try {
        final r = await readinessCalibrationDone()
            ? (seeded: 0, rescored: 0, forced: 0)
            : await backfillReadinessCalibration(
          // Both substrate sources, as `_deriveScope` reads them: a wearable
          // day with rows is the derive's, not the re-score's.
          rawDays: await substrateDays(),
          zHistoryLoader: () async {
            final h = await _BaselineHistoryCache.load();
            return (day, fam) => h.valuesBefore('readiness_z', day,
                family: _baselineFamily('readiness_z', fam));
          },
        );
        if (r.seeded > 0 || r.rescored > 0) {
          _log('[derive] readiness calibration: ${r.seeded} z seeded, '
              '${r.rescored} day(s) re-scored'
              '${r.forced > 0 ? ' (${r.forced} with substrate whose derive '
                  'never landed, from stored inputs)' : ''}');
          await _refreshBaselines();
        }
        if (r.rescored > 0) await _runCrossDay(profile);
      } catch (e) {
        _log('[derive] readiness calibration failed (will retry): $e');
      }
      // Restamp Today's freshness here, not in each caller: the iOS
      // background pass has no caller to do it, and getToday reads the
      // night from `overnight_day`, so a night settled in the background
      // kept serving the previous one.
      await _settled();
      _calcStage(null);
      endWearableDayIndexPass();
      _running = false;
      final finishedAt = DateTime.now().millisecondsSinceEpoch;
      _diag
        ..['running'] = false
        ..['stage'] = 'idle'
        ..['active_days'] = const <String>[]
        ..['finished_at'] = finishedAt
        ..['duration_ms'] = finishedAt - startedAt;
      
      try { await runTrace?.stop(); } catch (_) {}
    }
  }

  /// Remember what a day's input looked like when it was derived, so a later
  /// manual sync can prove nothing changed. Best-effort: a failed write only
  /// costs one redundant derive.
  Future<void> _recordDerivedFingerprint(String dayId, String? fingerprint) async {
    if (fingerprint == null) return;
    try {
      await LocalDb.putDerivedFingerprint(dayId, kAlgoVersion, fingerprint);
    } catch (e) {
      _log('derive $dayId: could not record fingerprint: $e');
    }
  }

  Future<int> runDays(
    Profile profile,
    Set<String> days, {
    bool force = true,
    void Function(String day, int index, int total)? onDayDone,
    void Function(String day)? onDayDerived,
    void Function(List<String> days)? onScopeDays,
  }) async {
    if (days.isEmpty) return 0;
    // The zone the day labels are cut in (interim for design 01): a change
    // since the last derive bumps the `zone` input. Best effort, and outside
    // the _running latch so a failure cannot wedge it.
    try {
      await observeInputZone();
    } catch (e) {
      // Rolled back whole (cursor and bump together), so the next derive sees
      // the old zone and retries; this derive runs on the old stamps.
      _diag['zone_observe_error'] = '$e';
    }
    if (_running) return 0;
    // The profile is passed in, not read from a store: note it here.
    InputReads.note('profile', '');
    InputReads.note('zone', '');
    _running = true;
    beginWearableDayIndexPass();
    _calcStage('Reading recordings');
    perf.startPass();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    _diag
      ..['running'] = true
      ..['stage'] = 'scope'
      ..['mode'] = 'selected'
      ..['force'] = force
      ..['started_at'] = startedAt
      ..['finished_at'] = null
      ..['duration_ms'] = null
      ..['raw_pages'] = 0
      ..['raw_rows'] = 0
      ..['max_day_raw_pages'] = 0
      ..['max_day_raw_rows'] = 0
      ..['scope_days'] = days.length
      ..['scope_reason'] = 'selected-days'
      ..['prepared_days'] = 0
      ..['todo_days'] = 0
      ..['done_days'] = 0
      ..['skipped_days'] = 0
      ..['active_days'] = <String>[]
      ..['concurrency'] = _deriveConcurrency
      ..['last_error'] = null;
    try {
      await refreshSessionSensorSources(); // as [run] does
      final scope = _scopeForDays(days.toList(), reason: 'selected-days');
      // No band data at all: a device's banked nights are still days to
      // derive (the active wearable's), so their edge stands in as "now, in
      // data time".
      final dataNowSec = await _withWearableEdge(
              await LocalDb.lastDecodedRecTs() ??
                  await enabledVendorSleepEndTs()) ??
          0;
      // With no decoded row anywhere only the user's blanking can still be
      // written (see run()); it needs no raw and no data edge.
      final noData = dataNowSec <= 0;
      final blankOnly =
          noData ? await _blankingOverrideDays(scope.targetDays) : <String>{};
      if (noData && blankOnly.isEmpty) {
        _log('derive selected: no decoded data');
        return 0;
      }
      final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
      final todoDays = noData
          ? (blankOnly.toList()..sort())
          : [
              for (final day in scope.targetDays)
                if (force || !finalized.contains(day)) day,
            ];
      if (todoDays.isEmpty) {
        _log('derive selected: all days finalized — nothing to do');
        return 0;
      }
      _diag['todo_days'] = todoDays.length;
      onScopeDays?.call(todoDays.reversed.toList());
      final profileSig = _profileSignature(profile);
      final fps = await LocalDb.decodedDayFingerprints({
        for (final d in todoDays) ...[d, _adjacentDayIds(d).first],
      });
      final dayFp = <String, String?>{
        for (final d in todoDays)
          d: deriveFingerprint(
            profileSig: profileSig,
            own: fps[d],
            previous: fps[_adjacentDayIds(d).first],
          ),
      };
      final history = await _BaselineHistoryCache.load();
      _calcStage('Day calculations');
      // Same bounded worker-pool pattern as run() — see its doc for why this
      // is safe (independent day_id-keyed writes + a frozen baseline shared
      // read-only across the whole batch).
      final orderedDays = todoDays.reversed.toList();
      var done = 0;
      var completed = 0;
      var failures = 0;
      final activeDays = <String>{};

      // Days that would have finalized on a tonight's sleep the next day's
      // concurrent derive has since moved: derived again after the pool.
      final staleTonight = <String>{};
      Future<void> processDay(String dayId, {bool repass = false}) async {
        activeDays.add(dayId);
        _diag['active_days'] = activeDays.toList();
        var reportDone = true;
        try {
          final prepared = await _prepareTargetDayTimed(dayId, reuse: !force);
          if (prepared != null) {
            _diag['prepared_days'] = (_diag['prepared_days'] as int) + 1;
            // `force` only ever comes from a user action (see callers), so it
            // is the one case allowed to rewrite a frozen (finalized) row.
            final committed = await _derivePreparedDayTimed(
                prepared, profile, dataNowSec, history,
                reason: force
                    ? DayResultWrite.userOverride
                    : DayResultWrite.derive,
                onStaleTonight: repass ? null : staleTonight.add);
            if (repass) {
              // Counted and reported by its first derive.
              if (committed == DayDerive.committed) {
                await _recordDerivedFingerprint(dayId, dayFp[dayId]);
              }
              reportDone = false;
            } else if (committed == DayDerive.committed) {
              done++;
              _diag['done_days'] = done;
              await _recordDerivedFingerprint(dayId, dayFp[dayId]);
              onDayDerived?.call(dayId);
            } else {
              reportDone = false;
            }
          } else {
            _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
            _diag['last_error'] = 'no_bounded_window_payload day=$dayId';
            failures++;
          }
        } catch (e) {
          _log('derive selected day $dayId FAILED/skipped: $e');
          _diag['skipped_days'] = (_diag['skipped_days'] as int) + 1;
          _diag['last_error'] = '$e';
          failures++;
        }
        activeDays.remove(dayId);
        _passPendingDays.remove(dayId);
        _diag['active_days'] = activeDays.toList();
        if (reportDone) {
          completed++;
          onDayDone?.call(dayId, completed, orderedDays.length);
        }
      }

      _passPendingDays = orderedDays.toSet();
      try {
        await runWithConcurrency(orderedDays, _deriveConcurrency, processDay);
      } finally {
        _passPendingDays = <String>{};
      }
      // As in [run]: days that would have finalized on a moved tonight.
      if (staleTonight.isNotEmpty) {
        await runWithConcurrency(
            [for (final d in orderedDays) if (staleTonight.contains(d)) d],
            _deriveConcurrency,
            (d) => processDay(d, repass: true));
      }
      done += await _quietLevelRepass(profile, dataNowSec);
      // A SELECTED re-analyze that happens to cover the whole raw history, with
      // every day resolved, is a full restage by any other name — it re-derived
      // every day under the current timezone, so it clears the travel hold too.
      // A partial selection deliberately does not: those days say nothing about
      // the ones still held.
      if (force && failures == 0) {
        final rawDays = (await LocalDb.decodedRecTsMaxByDay()).keys.toSet();
        if (rawDays.isNotEmpty && rawDays.difference(days).isEmpty) {
          await LocalDb.putBaseline(
            'tz_travel_guard',
            jsonEncode({
              'offset_min': DateTime.now().timeZoneOffset.inMinutes,
            }),
          );
          _log('derive selected: full-coverage restage — timezone hold cleared');
        }
      }
      if (done > 0) {
        _calcStage('Baselines');
        await _refreshBaselines();
        _calcStage('Trends across days');
        await _runCrossDay(profile);
        _calcStage('Notifications');
        await _runNotifications();
      }
      return done;
    } catch (e, st) {
      _diag['last_error'] = '$e';
      _log('derive selected ERROR: $e\n$st');
      return 0;
    } finally {
      _finishPassPerf();
      _calcStage('Tidying up');
      await _runStorageHousekeeping();
      _calcStage(null);
      final finishedAt = DateTime.now().millisecondsSinceEpoch;
      _diag
        ..['running'] = false
        ..['stage'] = 'idle'
        ..['finished_at'] = finishedAt
        ..['duration_ms'] = finishedAt - startedAt;
      endWearableDayIndexPass();
      _running = false;
    }
  }

  /// Re-derive [day] after the user changed its sleep (reject, set times,
  /// confirm, clear), then every LATER day that still has raw.
  ///
  /// Two passes, not one: a day's readiness is z-scored against the trailing
  /// window of EARLIER days' `metric_series`, and a sweep reads one frozen
  /// snapshot of it (`_BaselineHistoryCache`). Deriving them together would
  /// score tomorrow against a window that still holds the night just edited.
  /// Days past raw retention cannot be recomputed and keep what they have.
  /// Returns the days derived; stops after the first pass if it failed.
  Future<int> rederiveAfterSleepEdit(Profile profile, String day) async {
    // The profile first: the passes below stage with it.
    await _forgetBlankedNightsInSleepProfile();
    var done = await runDays(profile, {day}, force: true);
    if (_diag['last_error'] != null) return done;
    final later = {
      for (final d in (await LocalDb.decodedRecTsMaxByDay()).keys)
        if (d.compareTo(day) > 0) d,
    };
    if (later.isNotEmpty) done += await runDays(profile, later, force: true);
    return done;
  }

  /// The explicit, Advanced "Rebuild history with this priority" action: force
  /// re-derive [days] (finalized ones included) under the `signal_priority`
  /// orders stored NOW, restamping each day's `priority_hash`.
  ///
  /// Idempotent by construction: it is `runDays(force: true)`, whose writes are
  /// `day_id`-keyed REPLACEs, so a second run leaves one row per
  /// `(day_id, kAlgoVersion)` and re-writes the same `metric_series` values (no
  /// duplicate-day append). A day whose raw has been pruned keeps its stored row
  /// (the "never write nothing over something" guard in `_derivePreparedDay`).
  /// A save of a new order never calls this.
  ///
  /// Returns `days`, the ids actually rebuilt, and `priorityKey`, the encoding
  /// of the stored orders (see `priorityKey`). A day's own stamp can carry extra
  /// trailing ids for unranked devices that covered it; see `effectivePriority`.
  Future<Map<String, Object?>> rebuildHistoryWithPriority(
    Profile profile, {
    required Set<String> days,
  }) async {
    final rebuilt = <String>[];
    await runDays(profile, days, force: true, onDayDerived: rebuilt.add);
    return {
      'days': rebuilt..sort(),
      'priorityKey': priorityKey({
        for (final sig in kExclusiveOwnershipSignals)
          sig: effectivePriority(await LocalDb.signalPriority(sig), const []),
      }),
    };
  }

  static const int _rawDecodeBatchSize = 2000;
  static const int _maxDayRawRows = 500000;
  static const int _maxDayRawPages = 300;


  /// The stored main-sleep span of the day after [dayId], which decides
  /// [dayId]'s tonight's sleep ([tonightSleep]).
  Future<({int startSec, int endSec})?> _nextDayWindowSpan(String dayId) async =>
      storedWindowSpan(await LocalDb.sleepWindowJsonFor(
          localDateLabel(_localNextDayLabelToSec(dayId))));

  /// The next-day span each day was last prepared with ([_prepareTargetDay]),
  /// so the finalization decision can tell the input moved under it.
  final Map<String, ({int startSec, int endSec})?> _tonightSpanAtPrep = {};

  /// The days of the running pass's pool that have not committed yet. A day
  /// whose next day is among them does not finalize this round.
  Set<String> _passPendingDays = <String>{};

  /// [next] (the following day's main sleep) when it is TONIGHT's from this
  /// day's side: begun inside this day and after its own sleep ended.
  @visibleForTesting
  static ({int startSec, int endSec})? tonightSleep(
    ({int startSec, int endSec})? next, {
    required int dayStartSec,
    required int dayEndSec,
    required int sleepOffsetSec,
  }) {
    if (next == null) return null;
    if (next.startSec < dayStartSec || next.startSec >= dayEndSec) return null;
    if (next.startSec < sleepOffsetSec) return null;
    return next;
  }

  /// [dayId]'s stored checkpoint when it can be resumed from as far as can be
  /// told BEFORE the day's rows are read (the layout, algorithm version and the
  /// revisions of the buckets it folded; the context needs the loaded day and is
  /// decided later by [_restoreCheckpoint]), with its blob decoded. Null: load
  /// the whole day.
  Future<DayRrResume?> _probeRrResume(String dayId, Map<int, int> revs) async {
    try {
      final cp = await LocalDb.dayCheckpoint(dayId, kAlgoVersion);
      if (cp == null) return null;
      final cpBucket = cp.cpRecTs ~/ kRevBucketSec;
      final decision = decideResume(
        cp: cp,
        algoVersion: kAlgoVersion,
        ctxSig: cp.ctxSig,
        liveRevs: {
          for (final e in revs.entries)
            if (e.key < cpBucket) e.key: e.value,
        },
      );
      if (!decision.resume) return null;
      // The header only: this runs on every warm pass, on the engine's isolate,
      // so the blob is not decoded here. The gates ([_checkpointGate], [_foldedGate]) judge the
      // figure; the worker that folds the tail decodes the blob and refuses a
      // damaged one, which reads the day's whole beats.
      final folded = peekDayResumeFolded(cp.state);
      if (folded == null || folded == 0) return null;
      return DayRrResume(
        cp: cp,
        folded: folded,
        skipBelowRecTs: cp.cpRecTs - kRrReadSlackSec,
      );
    } catch (e) {
      _log('checkpoint $dayId not probed: $e');
      return null;
    }
  }

  /// Who owns each anchor signal over `[from, to]`, plus the order that
  /// answer resolved under.
  ///
  /// ONE resolver for every substrate load, because a window staged from one
  /// device's rows and scored from another's is two different nights. The two
  /// call sites pass different windows — staging's is candidate-INDEPENDENT
  /// (`_targetDayWindow`), the prepared day's is the union that includes the
  /// candidate — so the spans differ, but the rule producing them does not.
  Future<(Map<InputSignal, List<OwnedSpan>>, Map<InputSignal, List<String>>)>
      _resolveOwnership(int from, int to) async {
    // [from, to] is a load's range, `to` INCLUDED (`_loadSubstrateRange`);
    // spans are half-open (`spanAt`), so they are resolved up to `to + 1`.
    // Resolved up to `to`, the load's last second had no owner and kept every
    // device's rows, and two loads that share a second disagreed about it.
    final end = to + 1;
    final ownership = <InputSignal, List<OwnedSpan>>{};
    // The order each signal ACTUALLY resolved under, carried on the prepared
    // day so `priority_hash` names it by construction instead of re-reading
    // `signal_priority` after the day computed (which could stamp an order
    // the user changed mid-derive, and cost a query per signal per day).
    final priority = <InputSignal, List<String>>{};
    for (final sig in kExclusiveOwnershipSignals) {
      final rawPriority = await LocalDb.signalPriority(sig);
      final coverage = await LocalDb.coverageIntervals(sig, from, end);
      // One rule for the engine, the Sources view and `signalWinners`: see
      // `effectivePriority` for the empty-order and unranked-device cases.
      var resolved =
          effectivePriority(rawPriority, [for (final iv in coverage) iv.deviceId]);
      // Rule R6: a flag-off device ranked for (or covering) this signal owns
      // nothing; its windows fall through to the next flag-on device. Nor
      // does a flag-on one whose rows these loads never read (`bandDay`).
      // Nothing left = the empty-priority default, never "abstain".
      if (rawPriority.isNotEmpty) {
        final kept = await flagOnOrPrimary(resolved, bandDay: true);
        resolved = kept.isEmpty ? const [LocalDb.kPrimaryDeviceId] : kept;
      }
      priority[sig] = resolved;
      ownership[sig] = resolveOwnership(
        coverage: coverage,
        priority: resolved,
        from: from,
        to: end,
        signal: sig,
      );
    }
    return (ownership, priority);
  }

  /// Sparse HR (a wearable storing HR a minute or more apart; coverage stamps
  /// it `hrSparse`, never `hr1Hz`) over `[from, to]`, added to [ownership]
  /// and [priority]. Only on a day the ACTIVE wearable decides: a band's day
  /// never resolves it, so a watch worn beside the band cannot add an owner
  /// (and a `coverage` key) to that day's payload. Unranked, the active
  /// wearable owns it, so of two paired watches only the chosen one's
  /// minutes count; in the priority (and so `priority_hash`) only once the
  /// user ranks it.
  Future<void> _resolveSparseOwnership(
    int from,
    int to,
    String activeId,
    Map<InputSignal, List<OwnedSpan>> ownership,
    Map<InputSignal, List<String>> priority,
  ) async {
    final rawSparse = await LocalDb.signalPriority(InputSignal.hrSparse);
    final sparseCoverage =
        await LocalDb.coverageIntervals(InputSignal.hrSparse, from, to);
    // Flag-off devices dropped (rule R6); [activeId]'s flag is on.
    final ranked = rawSparse.isEmpty
        ? const <String>[]
        : await flagOnOrPrimary([
            ...rawSparse,
            ...{for (final iv in sparseCoverage) iv.deviceId}
                .difference(rawSparse.toSet())
                .toList()
              ..sort(),
          ]);
    final sparsePriority = ranked.isNotEmpty ? ranked : [activeId];
    if (ranked.isNotEmpty) priority[InputSignal.hrSparse] = sparsePriority;
    ownership[InputSignal.hrSparse] = resolveOwnership(
      coverage: sparseCoverage,
      priority: sparsePriority,
      from: from,
      to: to,
      signal: InputSignal.hrSparse,
    );
  }



  static ana.SleepNightObservation _observationFromJson(
      Map<String, dynamic> o) {
    double? d(String k) => (o[k] as num?)?.toDouble();
    return ana.SleepNightObservation(
      epochs: (o['epochs'] as num?)?.toInt() ?? 0,
      hrFloorP5: d('hr_floor_p5'),
      hrFloorP25: d('hr_floor_p25'),
      hrSleepMedian: d('hr_sleep_median'),
      hrArousal: d('hr_arousal'),
      rmssdMed: d('rmssd_med'),
      rmssdMad: d('rmssd_mad'),
      enmoStillCut: d('enmo_still_cut'),
      enmoMoveCut: d('enmo_move_cut'),
      lfhfMed: d('lfhf_med'),
      rkMed: d('rk_med'),
    );
  }

  /// Take every night the user blanked back out of the rolling sleep profile.
  ///
  /// A night folded in while it was an automatic one keeps shaping the staging
  /// thresholds after the user rejects it ("Not sleep"), which
  /// is "in a baseline" by another name. An EWMA cannot be un-folded, so the
  /// profile is REFOLDED, chronologically, from the observations stored beside
  /// it, minus the blanked nights. Days in the profile with no stored
  /// observation (written before they were kept) cannot be shown to exclude the
  /// blanked night and are dropped from it too: the profile falls back toward a
  /// cold start, and those nights fold again if they are ever re-staged.
  ///
  /// Idempotent: a profile that holds no blanked night is left untouched, and a
  /// rebuilt one holds none. Needs no raw. Cheap (at most
  /// [SleepProfilePolicy.maxStoredObservations] EWMA steps), so it stays on the
  /// calling isolate under the same exclusive transaction as the fold itself.
  Future<void> _forgetBlankedNightsInSleepProfile() async {
    // A typed window is a staged night (D27 revised): it stays in the profile.
    final blanked = await _blankingOverrideDays(null, true);
    if (blanked.isEmpty) return;
    await LocalDb.updateBaseline('sleep_user_profile', (current) {
      final usable = SleepProfilePolicy.usableProfileJson(current);
      if (usable == null) return null; // cold start / legacy: nothing in it
      if (SleepProfilePolicy.foldedDays(usable).intersection(blanked).isEmpty) {
        return null;
      }
      final kept = <String, Map<String, dynamic>>{
        for (final e in SleepProfilePolicy.foldedObservations(usable).entries)
          if (!blanked.contains(e.key)) e.key: e.value,
      };
      final days = kept.keys.toList()..sort();
      var profile = const ana.SleepUserProfile();
      for (final d in days) {
        profile = profile.fold(_observationFromJson(kept[d]!));
      }
      return jsonEncode({
        ...profile.toJson(),
        SleepProfilePolicy.foldedDaysKey: days,
        SleepProfilePolicy.foldedObsKey: kept,
      });
    });
  }

  /// Read the persisted per-user sleep profile (`baselines` key
  /// `sleep_user_profile`) as raw JSON, for passing into the staging worker
  /// isolate. Absent/corrupt ⇒ null (cold start). DB read stays on the main
  /// isolate (the DB owner); the worker reconstructs the profile from this JSON.
  ///
  /// A profile written before per-day fold tracking existed carries no
  /// [_kFoldedDaysKey] and therefore an untrustworthy `nights` count and an
  /// EWMA skewed by repeated re-folds of the same nights. We cannot repair it
  /// (there is no record of which days went in), so we DISCARD it and rebuild.
  /// That degrades to pure per-night-local baselines — the cold-start path
  /// cardio_stager.dart was validated on — and the profile re-earns its weight
  /// over the next few nights under the corrected accounting.
  Future<String?> _loadSleepUserProfileJson() async {
    final row = await LocalDb.baseline('sleep_user_profile');
    final raw = row?['payload_json'];
    if (raw is! String || raw.isEmpty) return null;
    // Validate here (mirrors the cached-candidate guard above) so a corrupt
    // payload becomes a cold start, per this method's contract — rather than
    // throwing later inside the staging worker's `jsonDecode(...) as Map`.
    return SleepProfilePolicy.usableProfileJson(raw);
  }

  /// Stored sleep windows for the trailing [days] days, as the history the
  /// habitual-midsleep prior takes ([calendarDays]'s `priorSleep`).
  ///
  /// `window_json` is a projected column, so this is one small query — no
  /// bundle decode. Days with no window contribute nothing; the prior itself
  /// abstains below 14 distinct days.
  ///
  /// [excludeDay] drops the day being staged: its stored window is the PREVIOUS
  /// derive's answer for the very question being asked, and a re-derive that
  /// reads its own last answer back is not reproducible.
  Future<List<({int startSec, int endSec, String dayKey})>>
  _storedSleepHistory({int days = 60, String? excludeDay}) async {
    final out = <({int startSec, int endSec, String dayKey})>[];
    try {
      // A window the user asserted over a stretch with no samples is a
      // night NOT RECORDED: it has a window but no total sleep time. Keep only
      // nights that have one, or the habitual-midsleep prior is fed a time
      // nobody slept at. (`metric_series` stores a null as NULL and
      // `metricSeries` filters those out.)
      final recorded = {
        for (final r in await LocalDb.metricSeries('tst_min')) r['date'],
      };
      for (final r in await LocalDb.sleepWindowRows(days)) {
        final dayKey = r['day_id'] as String?;
        if (dayKey == null || dayKey.isEmpty || dayKey == excludeDay) continue;
        if (!recorded.contains(dayKey)) continue;
        final span = storedWindowSpan(r['window_json']);
        if (span == null) continue;
        out.add((startSec: span.startSec, endSec: span.endSec, dayKey: dayKey));
      }
    } catch (e) {
      _log('sleep history for midsleep prior FAILED/skipped: $e');
    }
    return out;
  }

  /// One `day_result.window_json` as epoch seconds, or null when it holds no
  /// window. Every writer (this engine and both importers) stores a BARE
  /// `SleepWindow.toJson()`; only reading a `value` envelope skipped every row,
  /// so the midsleep prior never had history. Envelope still accepted (its
  /// `value` is the string '—' on a night with no sleep).
  @visibleForTesting
  static ({int startSec, int endSec})? storedWindowSpan(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final env = decoded['value'];
    final v = env is Map ? env : decoded;
    final onsetMs = (v['onset_ms'] as num?)?.toDouble();
    final offsetMs = (v['offset_ms'] as num?)?.toDouble();
    if (onsetMs == null || offsetMs == null) return null;
    final startSec = (onsetMs / 1000).round();
    final endSec = (offsetMs / 1000).round();
    if (startSec <= 0 || endSec <= startSec) return null;
    return (startSec: startSec, endSec: endSec);
  }




  // Cumulative across the WHOLE run — safe under concurrent per-day
  // processing since each field is a simple, non-`await`-split increment
  // (order across days doesn't matter for a total). Per-day max tracking
  // moved to `_PrepareStats` + the single merge at the end of
  // `_prepareTargetDay`, since that DOES need per-day isolation.
  void _trackPrepareBatch(int rows) {
    _diag['raw_pages'] = (_diag['raw_pages'] as int) + 1;
    _diag['raw_rows'] = (_diag['raw_rows'] as int) + rows;
  }

  void _enforcePrepareBudget({
    required String dayId,
    required int fromRecTs,
    required int toRecTs,
    required int rangePages,
    required int rangeRows,
  }) {
    if (rangeRows > _maxDayRawRows || rangePages > _maxDayRawPages) {
      throw Exception(
        'day_prepare_budget_exceeded day=$dayId rows=$rangeRows '
        'pages=$rangePages range=$fromRecTs-$toRecTs',
      );
    }
  }


  /// The day before and after [dayId] ('YYYY-MM-DD'), DST-safe (goes through
  /// real DateTime arithmetic, not a raw ±86400s offset).
  static List<String> _adjacentDayIds(String dayId) {
    final d = DateTime.tryParse(dayId);
    if (d == null) return const [];
    return [
      dayLabelOf(DateTime(d.year, d.month, d.day - 1)),
      dayLabelOf(DateTime(d.year, d.month, d.day + 1)),
    ];
  }

  /// True right after the device timezone jumps by more than a real DST shift
  /// ever would (>=3h) — a strong signal of actual cross-timezone travel
  /// rather than a seasonal clock change. Stays true across repeated calls
  /// (derive runs many times a day) by only ever updating the persisted
  /// baseline offset when NO jump is detected — updating it unconditionally
  /// would make the very next call see lastOffset == nowOffset and silently
  /// drop the guard after a single pass. `force` (full restage) is what
  /// resets it, per _deriveScope.
  static const int _tzJumpThresholdMin = 180;
  Future<bool> _timezoneTravelSuspected() async {
    final nowOffsetMin = DateTime.now().timeZoneOffset.inMinutes;
    final row = await LocalDb.baseline('tz_travel_guard');
    final raw = row?['payload_json'];
    int? lastOffsetMin;
    if (raw is String && raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) lastOffsetMin = (d['offset_min'] as num?)?.toInt();
      } catch (_) {
        // fall through — treat as unknown
      }
    }
    if (lastOffsetMin == null) {
      await LocalDb.putBaseline(
        'tz_travel_guard',
        jsonEncode({'offset_min': nowOffsetMin}),
      );
      return false;
    }
    final jumped = (nowOffsetMin - lastOffsetMin).abs() >= _tzJumpThresholdMin;
    if (!jumped) {
      await LocalDb.putBaseline(
        'tz_travel_guard',
        jsonEncode({'offset_min': nowOffsetMin}),
      );
    }
    return jumped;
  }

  _DeriveScope _scopeForDays(
    List<String> days, {
    required String reason,
    bool fullHistory = false,
    List<String> rawDays = const [],
  }) {
    final sorted = days.toSet().toList()..sort();
    if (sorted.isEmpty || fullHistory) {
      return _DeriveScope(
        fullHistory: true,
        targetDays: sorted,
        reason: reason,
        rawDays: rawDays,
      );
    }
    return _DeriveScope(
      fullHistory: false,
      targetDays: sorted,
      reason: reason,
      rawDays: rawDays,
    );
  }

  /// `compute_freshness` key prefix (`<prefix><YYYY-MM-DD>`) marking a day
  /// whose strain abstained for want of a quiet-waking level that prior days
  /// could still supply. DURABLE on purpose: the day is held unfinalized and
  /// its raw is held from the prune (see [_pruneOldDecoded]) until a pass
  /// actually scores it — so a failed second pass, or the app being killed
  /// between passes, leaves it for the next run instead of losing it.
  static const String kQuietRepassKeyPrefix = 'quiet_repass:';

  /// Test seam: awaited at the start of [_quietLevelRepass] (with null) and
  /// before each day it re-derives. A throw simulates the pass failing — or,
  /// at the start, the process dying before it ran. Null in production.
  @visibleForTesting
  static Future<void> Function(String? day)? debugQuietRepassHook;

  /// Test seam: awaited just before a day's offloaded second half. A throw
  /// lands exactly where a second-half timeout does. Null in production.
  @visibleForTesting
  static Future<void> Function(String day)? debugSecondHalfHook;

  /// Of the days still owed a strain score ([kQuietRepassKeyPrefix]), the ones
  /// that have a personal quiet level now — the days [_quietLevelRepass]
  /// re-derives.
  ///
  /// A sweep prices every day on ONE frozen history snapshot. On a fresh
  /// install whose first sync brings a week, that snapshot holds no `quiet_hrr`
  /// at all, so every day abstains on strain — while each writes its own level
  /// for the days after it. A day whose level merely MOVED is not here: that
  /// is ordinary baseline drift, refreshed by [rescanRecent] like every other.
  @visibleForTesting
  static List<String> quietLevelRepassDays(
    Iterable<String> owedDays, {
    required List<double> Function(String day) after,
  }) => [
    for (final day in owedDays)
      if (ana.personalQuietWakingHrr(after(day)).present) day,
  ];

  /// Whether [bundle] (day [date], about to be persisted) MAY be owed a strain
  /// re-score — deliberately an OVER-approximation, with no counting.
  ///
  /// Owed when strain abstained ON THE QUIET LEVEL (the `need_baseline` rung,
  /// last in the gate order, so no other input was missing) and ANY earlier
  /// day could have changed that: one whose raw is not finalized yet (a sweep
  /// derives newest-first and concurrently, so it may simply not be done) or
  /// one with a stored level (which may have landed after this day's
  /// snapshot). Deciding it exactly — "will the prior days reach three?" —
  /// meant counting across reads that concurrent day commits interleave with,
  /// and a miscount there finalized and pruned a day still owed a score.
  ///
  /// Race-free as ordered: raw days are never pruned mid-sweep and levels are
  /// only ever added, and a day's level lands in the SAME transaction as its
  /// row (`putDayResult`). So an earlier day either still reads as unfinalized
  /// raw below, or its level is already visible to the read after it.
  ///
  /// Over-marking costs a held raw day (under the [_maxRawHoldDays] floor) and
  /// a cheap check per run — never a number.
  Future<bool> _quietRepassOwed(String date, Map<String, dynamic> bundle) async {
    if (!quietBlocked(bundle)) return false;
    final finalized = await _finalizedOrSettled();
    final rawDays = (await LocalDb.decodedRecTsMaxByDay()).keys;
    if (rawDays.any((d) => d.compareTo(date) < 0 && !finalized.contains(d))) {
      return true;
    }
    await debugQuietBetweenReads?.call();
    return (await LocalDb.trailingSeriesValues('quiet_hrr', 1, before: date))
        .isNotEmpty;
  }

  /// PROOF that no pass can ever give [date] a quiet level from the data in
  /// hand — the one thing besides a scored derive that may clear a marker.
  /// Without it a day that can never reach [ana.quietHrrMinDays] (a cold
  /// start's days 2–3, or a user whose days are all too short to yield a
  /// level) stays owed until its raw ages out, and every later day is marked
  /// in turn because the one before it is still unfinalized.
  ///
  /// Counts, so it orders its reads where a concurrent commit cannot slip
  /// through: the DERIVED set first, then the levels. An earlier day that
  /// commits after the first read is counted as still pending; one that
  /// committed before it has its level (written in the same transaction as
  /// its row) visible to the second. Partial rows are not "derived" — they
  /// never wrote their series — so they count as pending too.
  Future<bool> _quietLevelUnreachable(String date) async {
    // A settled day is done: it will never give a level, nor is it waiting to.
    final derived = {
      ...await LocalDb.dayResultIds(kAlgoVersion),
      ...await _settledDays(),
    };
    await debugQuietBetweenReads?.call();
    final prior = await LocalDb.trailingSeriesValues(
        'quiet_hrr', ana.quietHrrWindowDays, before: date);
    final valid = prior
        .where((q) => q.isFinite && q > 0 && q <= ana.maxQuietHrr)
        .length;
    if (valid >= ana.quietHrrMinDays) return false;
    final pending = [
      for (final d in (await LocalDb.decodedRecTsMaxByDay()).keys)
        if (d.compareTo(date) < 0 && !derived.contains(d)) d,
    ].length;
    return valid + pending < ana.quietHrrMinDays;
  }

  /// Test seam onto [_quietLevelUnreachable].
  @visibleForTesting
  Future<bool> debugQuietLevelUnreachable(String date) =>
      _quietLevelUnreachable(date);

  /// Strain abstained for want of a quiet-waking level and nothing else.
  @visibleForTesting
  static bool quietBlocked(Map<String, dynamic> bundle) {
    if ((bundle['scalars'] as Map?)?['strain'] != null) return false;
    final note = (bundle['absent_notes'] as Map?)?['strain'];
    return note is String && note.startsWith('need_baseline:');
  }

  /// Test seam: awaited between the two reads of [_quietRepassOwed] and of
  /// [_quietLevelUnreachable], so a test can commit a concurrent earlier day
  /// exactly there.
  @visibleForTesting
  static Future<void> Function()? debugQuietBetweenReads;

  /// Test seam onto [_quietRepassOwed].
  @visibleForTesting
  Future<bool> debugQuietRepassOwed(
          String date, Map<String, dynamic> bundle) =>
      _quietRepassOwed(date, bundle);

  /// Days still owed a strain re-score, from their durable markers.
  static Future<Set<String>> _quietRepassOwedDays() async => {
    for (final k in await LocalDb.computeFreshnessKeys(kQuietRepassKeyPrefix))
      k.substring(kQuietRepassKeyPrefix.length),
  };


  // ── baseline-dirty recent rescan ─────────────────────────────────────────────

  /// Re-derive the recent (≤ raw-retention) window when the rolling baseline
  /// has actually shifted, so baseline-DEPENDENT scalars (readiness/recovery,
  /// illness/anomaly, stress) on still-provisional days refresh as later data
  /// moves their baseline. Days finalized at [kAlgoVersion] are frozen and
  /// skipped (logged once per pass); a day finalized only at an older version
  /// has no frozen row at this one and is still reached.
  ///
  /// CHEAP BY DEFAULT: we gate on a baseline SIGNATURE — a stable hash of the
  /// current rolling baseline compared to the stored `baseline_sig` cursor. If unchanged
  /// we do ~one read and return 0 (no redundant writes). Only a real baseline
  /// change re-derives, and only the recent window (older raw is already pruned).
  ///
  /// Re-entrant calls are coalesced (shares the `_running` guard with run()).
  /// Best-effort: returns the number of days re-derived (0 on skip/empty/error).
  Future<int> rescanRecent(
    Profile profile, {
    void Function(String day, int index, int total)? onDayDone,
    void Function(List<String> days)? onScopeDays,
  }) async {
    if (_running) return 0;
    _running = true;
    beginWearableDayIndexPass();
    // Measured only once the baseline gate lets a rescan through: the gated
    // no-op runs after every heavy pass and must not wipe the last real pass.
    var perfStarted = false;
    try {
      await refreshSessionSensorSources(); // as [run] does
      // Baseline gate: compute the CURRENT signature and compare to the stored
      // one. Unchanged → nothing to refresh; bail cheaply (no redundant writes).
      final sig = await _baselineSignature();
      final prev = await LocalDb.getCursor('baseline_sig');
      if (sig == prev) {
        _log('baseline unchanged — rescan skipped');
        return 0;
      }

      // Same hold `_deriveScope` installs, for the same reason. This re-derives
      // recent days, and `decodedRecTsMaxByDay` buckets them in the CURRENT
      // timezone — so after a real trip it relabels and overwrites
      // (ConflictAlgorithm.replace) the not-yet-frozen nights the hold was protecting,
      // minutes after `run()` logged that it was protecting them. Wait for
      // "Re-analyze data", which is what clears the guard.
      //
      // Deliberately BEFORE the `baseline_sig` cursor is stored: the baseline
      // change is still pending, so the rescan runs once the hold lifts.
      if (await _timezoneTravelSuspected()) {
        _log(
          'rescan: possible timezone change — held until Re-analyze data runs',
        );
        return 0;
      }

      // The active wearable's days are days with substrate too (none when no
      // wearable is on, so a band-only install rescans as before).
      final wearable = await activeWearable();
      final rawByDay = {
        if (wearable != null) ...await wearableRecTsMaxByDay(wearable),
        ...await LocalDb.decodedRecTsMaxByDay(),
      };
      if (rawByDay.isEmpty) {
        _log('rescan: no decoded data');
        return 0;
      }
      final dataNowSec =
          await _withWearableEdge(await LocalDb.lastDecodedRecTs()) ?? 0;
      if (dataNowSec <= 0) {
        _log('rescan: no data edge');
        return 0;
      }
      // A day finalized at this version is frozen (see LocalDb.putDayResult):
      // the rescan used to rewrite it to refresh its baseline-dependent
      // scalars, and that is exactly what the freeze ends.
      final finalized = await _finalizedOrSettled();
      final candidates = rescanDayIds(
        rawDayIds: rawByDay.keys,
        dataNowSec: dataNowSec,
        prunedBeforeSec: await LocalDb.getCursorInt(_prunedBeforeCursor),
      );
      final todoDays = [
        for (final dayId in candidates)
          if (!finalized.contains(dayId)) dayId,
      ];
      final frozen = candidates.length - todoDays.length;
      if (frozen > 0) {
        _log('rescan: $frozen finalized day(s) at v$kAlgoVersion left frozen');
      }
      if (todoDays.isEmpty) {
        _log('rescan: no recent decoded-backed days');
        await LocalDb.setCursor('baseline_sig', sig);
        return 0;
      }
      _log(
        'rescan: baseline changed — re-deriving ${todoDays.length} '
        'recent day(s) (v$kAlgoVersion)',
      );

      perf.startPass();
      perfStarted = true;
      _calcStage('Day calculations');
      onScopeDays?.call(todoDays.reversed.toList());
      final profileSig = _profileSignature(profile);
      final fps = await LocalDb.decodedDayFingerprints({
        for (final d in todoDays) ...[d, _adjacentDayIds(d).first],
      });
      final dayFp = <String, String?>{
        for (final d in todoDays)
          d: deriveFingerprint(
            profileSig: profileSig,
            own: fps[d],
            previous: fps[_adjacentDayIds(d).first],
          ),
      };
      final history = await _BaselineHistoryCache.load();
      // Same bounded worker-pool pattern as run()/runDays — up to
      // _rescanWindowDays (21) days is exactly the kind of sweep that used
      // to run fully sequentially for no reason (independent day_id-keyed
      // writes + one frozen baseline snapshot shared read-only here).
      final orderedDays = todoDays.reversed.toList();
      var done = 0;
      var completed = 0;

      Future<void> processDay(String dayId) async {
        var reportDone = true;
        try {
          final prepared = await _prepareTargetDayTimed(dayId, reuse: true);
          if (prepared != null) {
            final committed = await _derivePreparedDayTimed(
                prepared, profile, dataNowSec, history);
            if (committed == DayDerive.committed) {
              done++;
              await _recordDerivedFingerprint(dayId, dayFp[dayId]);
            } else if (committed == DayDerive.declined) {
              await _recordDerivedFingerprint(dayId, dayFp[dayId]);
              await _settleDay(dayId, fps);
            } else {
              reportDone = false;
            }
          }
        } catch (e) {
          _log('rescan day $dayId FAILED/skipped: $e');
          // Do NOT mark-skipped here — a finalized day already has a good row;
          // overwriting it with a skip marker would DISCARD real structure.
        }
        if (reportDone) {
          completed++;
          onDayDone?.call(dayId, completed, orderedDays.length);
        }
      }

      await runWithConcurrency(orderedDays, _deriveConcurrency, processDay);

      _calcStage('Baselines');
      await _refreshBaselines();
      // Cross-day rollup + notifications reflect the refreshed scalars.
      _calcStage('Trends across days');
      await _runCrossDay(profile);
      _calcStage('Notifications');
      await _runNotifications();
      // Store the new signature so the next tick is a cheap no-op until it moves.
      await LocalDb.setCursor('baseline_sig', await _baselineSignature());
      await _settled();
      return done;
    } catch (e, st) {
      _log('rescan ERROR: $e\n$st');
      return 0;
    } finally {
      if (perfStarted) _finishPassPerf();
      if (perfStarted) _calcStage('Tidying up');
      await _runStorageHousekeeping();
      _calcStage(null);
      endWearableDayIndexPass();
      _running = false;
    }
  }

  /// The days [rescanRecent] re-derives: every day with substrate inside the
  /// rescan window, minus any whose derive window ([_targetDayWindow], from the
  /// previous noon) reaches below [prunedBeforeSec]. The prune cuts on local
  /// midnight, so the oldest kept day has its own rows but lost the evening
  /// half of its night; re-deriving it would REPLACE a full-night result with
  /// a truncated one that no empty-substrate guard catches. Its stored result
  /// was computed from the whole night, so it keeps that.
  @visibleForTesting
  static List<String> rescanDayIds({
    required Iterable<String> rawDayIds,
    required int dataNowSec,
    int? prunedBeforeSec,
  }) {
    final cutoffSec = dataNowSec - _rescanWindowDays * 86400;
    return [
      for (final dayId in rawDayIds)
        if (_localNextDayLabelToSec(dayId) >= cutoffSec &&
            !windowTruncatedByPrune(dayId, prunedBeforeSec))
          dayId,
    ]..sort();
  }

  /// Whether [dayId]'s derive window ([_targetDayWindow], from the previous
  /// noon) starts below [prunedBeforeSec], i.e. part of its night is gone.
  /// A user-set sleep window ([forcedOnsetSec]) only needs its own onset kept.
  @visibleForTesting
  static bool windowTruncatedByPrune(
    String dayId,
    int? prunedBeforeSec, {
    int? forcedOnsetSec,
  }) =>
      prunedBeforeSec != null &&
      (forcedOnsetSec ??
              _localDayLabelToSec(dayId) - kNocturnalSearchLookbackSec) <
          prunedBeforeSec;

  /// A stable, cheap signature of the CURRENT rolling baseline — the same inputs
  /// the readiness/illness baselines fold over. We take the trailing
  /// _baselineWindowDays derived rows and the median of each baseline series
  /// (RHR, RMSSD, skin-temp ADC mean, respiration), rounded to a stable
  /// precision, joined into a string. When new days land (or a recent day is
  /// re-derived) these medians shift and the signature changes → a rescan fires;
  /// when nothing moved the signature is byte-identical → the rescan is skipped.
  Future<String> _baselineSignature() async {
    final artifact = await LocalDb.baseline('rolling_artifact');
    final raw = artifact?['payload_json'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final sig = decoded['signature']?.toString();
          if (sig != null && sig.isNotEmpty) return sig;
        }
      } catch (_) {
        // Fall back to rebuilding the signature.
      }
    }
    final history = await _BaselineHistoryCache.load();
    return history.toArtifactJson()['signature']?.toString() ??
        'v$kAlgoVersion|na';
  }

  /// Foreground vs background pacing — lane count and per-day wall-clock
  /// budget. See [DerivePacing] for why the background numbers differ.
  DerivePacing get _pacing =>
      DerivePacing(background: background, maxWorkers: maxWorkers);

  /// Worker cap from the Calculations power mode (Maximum battery = 1); null =
  /// none. Read at the start of each run, so a change lands on the next pass.
  int? maxWorkers;

  /// Max wall-clock for ONE day's off-isolate compute. On timeout the day is
  /// skipped so the sweep always makes progress.
  Duration get _perDayTimeout => _pacing.perDayTimeout;

  /// Throttle for the readiness-absent diagnostic log — one per calendar day
  /// so repeated light-pass re-derives of today don't spam the outbox.
  String? _loggedReadinessAbsentFor;

  /// Bounded worker-pool size for concurrent per-day derivation. Days within
  /// a single run share ONE frozen baseline snapshot (`_BaselineHistoryCache`
  /// is loaded once before the loop, refreshed once after — see `run()`) and
  /// each writes to an independent, day_id-keyed `day_result` row — there is
  /// no cross-day ordering dependency within a run. A multi-day backlog sweep
  /// was previously fully sequential (one day's prepare-isolate + prepare
  /// substrate loads + compute-isolate all finishing before the next day even
  /// started), which wastes every core beyond the one doing the current day's
  /// work. Running several days' isolate work genuinely concurrently gets
  /// real wall-clock speedup from the device's other cores — in the FOREGROUND.
  /// A headless background slot has no spare cores to soak up, so it takes one
  /// lane; [DerivePacing] owns that decision and explains it.
  int get _deriveConcurrency {
    try {
      return _pacing.concurrency(Platform.numberOfProcessors);
    } catch (_) {
      return 1; // Platform unavailable on this target — sequential fallback
    }
  }

  // ── imports (derive from a pre-built substrate, not from stored raw) ─────────

  /// Derive the named [dates] from a caller-supplied [sub] (e.g. a CSV import
  /// rebuilt into a Substrate), reusing the FULL per-day pipeline (sleep / HRV /
  /// strain / workouts / advanced_sleep) — so imported raw 1 Hz gets the exact
  /// same analytics as a live band sync. [sub] should span the requested dates
  /// PLUS the prior evening (a night's sleep starts before midnight, and the day
  /// model searches `prev 18:00 → noon`); the caller windows the stream so memory
  /// stays bounded. Each derived day is FORCE-FINALIZED (imports are immutable
  /// snapshots — there is no stored raw to recompute them from). Returns the
  /// number of days written. Does NOT prune raw or run the cross-day rollup —
  /// call [finalizeImport] once after all windows.
  Future<int> deriveImportedDays(
    Substrate sub,
    Profile profile,
    Set<String> dates, {
    void Function(String day)? onDayDone,
  }) async {
    if (sub.isEmpty || dates.isEmpty) return 0;
    // Under the SAME lock as run()/runDays(): this writes day_result rows, and
    // an import racing a background derive of the same day is exactly the
    // partial-overwrites-complete case the lock exists for.
    //
    // It WAITS for the lock instead of taking the busy skip: the substrate
    // lives only in the caller's buffer, which is evicted right after, so a
    // skipped import day is gone for good. No await between the loop's last
    // check and the lock taking it, so nothing can slip in between.
    while (_running) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return _withRunLock(0, () async {
      final days = calendarDays(sub);
      final dataNowSec = sub.lastTs ?? 0;
      var done = 0;
      for (var i = 0; i < days.length; i++) {
        final day = days[i];
        if (!dates.contains(day.date)) continue;
        // NEVER clobber a day the band measured. `forceFinalize: true` below
        // both replaces the measured result and locks the day out of every
        // future re-derive, and the raw it came from is pruned within days —
        // so importing a file that overlaps real history destroyed it
        // silently and permanently. Same guard the WHOOP importer has always
        // had; it just was not shared.
        if (await LocalDb.isMeasuredDay(day.date)) {
          _log('import day ${day.date} kept (already measured on this device)');
          continue;
        }
        try {
          final committed = await _deriveDay(sub, day, profile, dataNowSec,
              forceFinalize: true,
              next: i + 1 < days.length ? days[i + 1] : null,
              // The user's own import; isMeasuredDay above already kept
              // every day the band measured, so what is left (a previous
              // import, a skip marker) is theirs to replace.
              reason: DayResultWrite.userOverride);
          if (committed) {
            done++;
            onDayDone?.call(day.date);
          }
        } catch (e) {
          _log('import day ${day.date} FAILED/skipped: $e');
        }
      }
      return done;
    });
  }

  /// Run the cross-day rollup + notifications + baseline refresh once after an
  /// import completes (reflects the freshly imported day history).
  /// NOT under [_withRunLock]: `_refreshBaselines` takes the lock itself, so
  /// holding it here would make this method skip its own first step. The rollup
  /// and notification passes below write one artifact each (last write wins,
  /// and the artifact is version/day stamped), so they are safe to interleave.
  Future<void> finalizeImport(Profile profile) async {
    await _refreshBaselines();
    // A false here is a failed rollup or a newer review revision racing it; the
    // imported rows have landed either way and queued review jobs retry on
    // their own, so the import must not report failure.
    if (!await _runCrossDay(profile)) _log('import: crossday rollup deferred');
    await _runNotifications();
    await _settled();
  }

  /// Durable review jobs outlive a busy derive or a terminated process.
  Future<bool> refreshActivityReviews(Profile profile) async {
    if (_running) return false;
    _running = true;
    try {
      final revisions = await LocalDb.applyPendingActivityReviews();
      if (revisions.isEmpty) return true;
      // Rebuild from the accepted day rows, including when an input artifact
      // was already cached today. A failed rollup must leave the work durable.
      if (!await _runCrossDay(profile)) return false;
      await _settled();
      await LocalDb.finishActivityReviews(revisions);
      return (await (await LocalDb.instance).query('activity_review_days', limit: 1)).isEmpty;
    } finally {
      _running = false;
    }
  }

  // ── derive one day ──────────────────────────────────────────────────────────

  Future<bool> _deriveDay(
    Substrate sub,
    PhysioDay day,
    Profile profile,
    int dataNowSec, {
    bool forceFinalize = false,
    PhysioDay? next,
    DayResultWrite reason = DayResultWrite.derive,
  }) async {
    final daySub = sub.slice(day.startSec, day.endSec);
    // Same buffered slice prepareDerivationPayload uses — without it, imported
    // days fall back to daySub and a nap straddling midnight is bisected again
    // on exactly the path this PR set out to fix.
    final napSub = sub.slice(day.startSec, day.endSec + napBoundaryBufferSec);
    final sleepSub = day.hasSleep
        ? sub.sliceIdx(day.sleepLoIdx, day.sleepHiIdx)
        : Substrate.empty;
    final hypno = day.sleep.stages4.isNotEmpty
        ? List<String>.from(day.sleep.stages4)
        : <String>[
            for (final s in day.sleep.stages)
              s == ana.SleepStage.wake
                  ? 'wake'
                  : (s == ana.SleepStage.rem ? 'rem' : 'light'),
          ];
    final win = day.sleep.window;
    final onsetSec = win == null
        ? 0
        : (win.onsetMs != null
              ? (win.onsetMs! / 1000).round()
              : (sleepSub.firstTs ?? 0));
    final offsetSec = win == null
        ? 0
        : (win.offsetMs != null
              ? (win.offsetMs! / 1000).round() + 1
              : ((sleepSub.lastTs ?? -1) + 1));
    final nextWin = next?.sleep.window;
    final tonight = tonightSleep(
      nextWin?.onsetMs == null || nextWin?.offsetMs == null
          ? null
          : (
              startSec: (nextWin!.onsetMs! / 1000).round(),
              endSec: (nextWin.offsetMs! / 1000).round(),
            ),
      dayStartSec: _localDayLabelToSec(day.date),
      dayEndSec: _localNextDayLabelToSec(day.date),
      sleepOffsetSec: offsetSec,
    );
    return (await _derivePreparedDay(
      PreparedDerivationDay(
        date: day.date,
        endSec: day.endSec,
        confidence: day.confidence,
        flags: List<String>.from(day.flags),
        sleepJson: day.sleep.toJson(),
        hypnoStages: hypno,
        sleepOnsetSec: onsetSec,
        sleepOffsetSec: offsetSec,
        daySub: daySub,
        napSub: napSub,
        sleepSub: sleepSub,
        tonightSleepOnsetSec: tonight?.startSec ?? 0,
        tonightSleepOffsetSec: tonight?.endSec ?? 0,
      ),
      profile,
      dataNowSec,
      await _BaselineHistoryCache.load(),
      forceFinalize: forceFinalize,
      suppliedSubstrate: true,
      reason: reason,
    )) != DayDerive.refused;
  }


  /// Bank one day's (phone steps, counter ticks) pair for the (family,
  /// wearing) profile and refit it over the banked days. Never throws into
  /// the derive.
  @visibleForTesting
  Future<void> updateStepCalibration(
    String date,
    Substrate daySub,
    int wearing, {
    required List<CoverageSpan> phoneSpans,
  }) async {
    try {
      final family = daySub.deviceFamily;
      if (family == null) return;
      // Pair the two sensors over the same windows only. A whole-day ratio
      // reads a phone left on a desk, or the band off charging, as counter
      // error.
      final ticks = counterTicksPerWindow(
        daySub,
        [for (final s in phoneSpans) (s.startTs, s.endTs)],
        cumulativeCounterModulus:
            ana.calibrationFor(_stepCounterModulus, family),
      );
      // No counter on this family (gen4): nothing to learn, nothing to bank.
      if (ticks == null) return;
      var reference = 0;
      var counted = 0;
      for (var i = 0; i < ticks.length; i++) {
        final t = ticks[i];
        if (t == null) continue;
        reference += phoneSpans[i].steps;
        counted += t;
      }
      // Only bank a day the fit would admit. The refit reads the last 30
      // rows, so banking no-phone days would push the learned days out of
      // that window and reset the factor on exactly the days it is used.
      if (!stepCalibrationDayAdmissible(StepCalibrationDay(
        referenceSteps: reference,
        counterTicks: counted,
      ))) {
        return;
      }
      // Concurrent day workers each bank then refit; unserialized, a slower
      // refit over fewer rows can land last and replace a newer profile.
      await _stepCalibrationLock.run(() async {
        await LocalDb.putStepCalibrationDay(
          day: date,
          deviceFamily: family,
          wearing: wearing,
          referenceSteps: reference,
          counterTicks: counted,
        );
        final rows = await LocalDb.stepCalibrationDays(family, wearing);
        final profile = estimateStepCalibration(
          family,
          wearing,
          [
            for (final r in rows)
              StepCalibrationDay(
                referenceSteps: (r['reference_steps'] as num?)?.toInt() ?? 0,
                counterTicks: (r['counter_ticks'] as num?)?.toInt() ?? 0,
              ),
          ],
        );
        await LocalDb.putStepCalibrationProfile(profile);
      });
    } catch (e) {
      _log('step calibration update failed for $date: $e');
    }
  }

  /// The settings of the day's checkpoint that live outside its rows, for
  /// [dayContextSig]. [clipEndSec] is the cursor the checkpoint folded up to:
  /// ownership is signed only over the rows it folded, so a second device's
  /// coverage arriving later in the day does not retire a prefix that never
  /// held its rows.
  ({String sig, int? age, int? stepModulus}) _checkpointContext(
    PreparedDerivationDay day,
    Profile profile, {
    required int clipEndSec,
  }) {
    final dayStart = _localDayLabelToSec(day.date);
    final dayEnd = _localNextDayLabelToSec(day.date);
    final clipEnd = math.min(clipEndSec, dayEnd);
    int offsetMin(int sec) =>
        DateTime.fromMillisecondsSinceEpoch(sec * 1000).timeZoneOffset.inMinutes;
    final owners = <String>[
      for (final sig in kExclusiveOwnershipSignals)
        for (final span in day.ownership[sig] ?? const <OwnedSpan>[])
          if (span.end > dayStart && span.start < clipEnd)
            '${sig.name}:${math.max(span.start, dayStart)}-'
                '${math.min(span.end, clipEnd)}:${span.deviceId ?? ''}',
    ];
    final family = day.daySub.deviceFamily;
    return (
      sig: dayContextSig(
        profileSig: jsonEncode(profile.toMap()),
        priorityKey: '${priorityKey(day.priority)}#${owners.join(',')}',
        deviceFamily: family,
        dayStartSec: dayStart,
        dayEndSec: dayEnd,
        tzOffsetAtStartMin: offsetMin(dayStart),
        tzOffsetAtEndMin: offsetMin(dayEnd),
        sleepSource: day.sleepSource,
        // The window's bounds are not signed: nothing the checkpoint folds
        // reads them. Nor does the movement floor: the per-minute motion buckets hold
        // `dynAmp`, and the floor is applied when they are read.
        dynFloorG: null,
      ),
      age: profile.ageYears,
      stepModulus: _stepModulusFor(family),
    );
  }

  /// Whether [cp] may be continued over [day], first half: the gate a cold
  /// resume ([_restoreCheckpoint]) and a warm streamed tail
  /// ([_derivePreparedDay]) both pass, so a process that stayed up cannot trust
  /// a checkpoint a fresh one would refuse. [cp]'s algorithm version and layout,
  /// the day context (profile, ownership and priority, family, zone offsets,
  /// source) and the revisions of the buckets it folded. Pure: no decode, no
  /// seeding, no row chunks, no counters (see [_noteGate]). The second half is
  /// [_foldedGate], once the blob's folded figure is known.
  ResumeDecision _checkpointGate(
    PreparedDerivationDay day,
    Profile profile,
    DayCheckpoint cp,
  ) {
    final revs = day.inputRevs;
    if (revs == null || day.daySub.tsSec.isEmpty) {
      return const ResumeDecision.full('none');
    }
    final cpBucket = cp.cpRecTs ~/ kRevBucketSec;
    return decideResume(
      cp: cp,
      algoVersion: kAlgoVersion,
      ctxSig: _checkpointContext(day, profile, clipEndSec: cp.cpRecTs).sig,
      liveRevs: {
        for (final e in revs.entries)
          if (e.key < cpBucket) e.key: e.value,
      },
    );
  }

  /// Second half: the blob must have folded exactly the day's rows before the
  /// cursor ([folded] null: a blob that cannot be read).
  ResumeDecision _foldedGate(
      PreparedDerivationDay day, DayCheckpoint cp, int? folded) {
    if (folded == null) return const ResumeDecision.full('unreadable_state');
    final before = firstIndexAtOrAfter(day.daySub.tsSec, cp.cpRecTs);
    if (folded != before || before == 0) {
      return const ResumeDecision.full('folded');
    }
    return const ResumeDecision.resume();
  }

  /// Logs and counts a gate verdict (one line and one counter per
  /// resumed day, cold or warm).
  bool _noteGate(PreparedDerivationDay day, ResumeDecision decision, int? folded) {
    _log('[perf] checkpoint ${day.date} '
        '${decision.resume ? 'resume folded=$folded' : 'full ${decision.reason}'}');
    perf.addCount(decision.resume ? 'cp_resumed' : 'cp_full', 1);
    return decision.resume;
  }

  /// [day]'s stored checkpoint when it may be resumed, as a state whose
  /// summaries start where the checkpoint stopped (and the decoded checkpoint
  /// itself, whose streaming RR state a streamed day continues); null (a full
  /// pass) when there is none or anything it depends on changed. Any doubt is a
  /// full pass. A day loaded against a probed checkpoint ([DayRrResume]) is
  /// judged against that one, not a second read of the row.
  Future<({DayCalculationState state, DayResumeState resume})?>
      _restoreCheckpoint(
    PreparedDerivationDay day,
    Profile profile,
  ) async {
    final revs = day.inputRevs;
    final ts = day.daySub.tsSec;
    if (revs == null || ts.isEmpty) return null;
    try {
      final probed = day.rrResume;
      final cp = probed?.cp ?? await LocalDb.dayCheckpoint(day.date, kAlgoVersion);
      var decision = const ResumeDecision.full('none');
      DayResumeState? state;
      if (cp != null) {
        // Decoded only once the context and revisions have passed, and here
        // because the seeded calculation state needs it: this is the cold
        // path, once per process and day.
        decision = _checkpointGate(day, profile, cp);
        if (decision.resume) {
          state = decodeDayResumeState(cp.state);
          decision = _foldedGate(day, cp, state?.folded);
          if (!decision.resume) state = null;
        }
      }
      final decoded = state;
      _noteGate(day, decision, decoded?.folded);
      if (decoded == null) return null;
      // The rows the stager computed before the restart: staging finds them as
      // hits instead of recomputing the night. The night RR / spectral part
      // rides in `state` and is armed by seedFrom.
      final rows = decoded.cardioRowsJson;
      if (rows != null) {
        // Still encoded: the staging worker decodes and merges it. Its start
        // seconds lie in the staging window it was cut to when it was written.
        final window = _targetDayWindow(day.date);
        _cardioRowChunks.add(CardioRowsChunk(
            rows,
            window.$1 - kCardioRowsSlackSec,
            window.$2 + kCardioRowsSlackSec));
      }
      return (state: DayCalculationState()..seedFrom(decoded), resume: decoded);
    } catch (e) {
      _log('checkpoint ${day.date} not resumed: $e');
      return null;
    }
  }

  /// The beat-driven figures of a day loaded against its checkpoint: the
  /// checkpoint's streaming RR state and day curves, advanced over the beats
  /// after it (and the accelerometer rows after it), read as they stand now.
  /// Null when it cannot be done soundly: the day was not resumed from that
  /// checkpoint, its family has no quiet cut, the curves were folded under
  /// another one, or the tail does not continue the state. The caller then
  /// reads the day's whole beats.
  Future<DayTailResult?> _streamDayTail(PreparedDerivationDay day) async {
    final probe = day.rrResume!;
    final sub = day.daySub;
    final cut = ana.calibrationFor(_quietEnmoCutG, sub.deviceFamily);
    if (cut == null) return null;
    try {
      final from = probe.folded;
      // The worker decodes the STORED checkpoint blob itself and cuts the tail
      // off the beats read (it alone holds the state's last beat), so the blob
      // is neither decoded nor serialised on this isolate. It folds its own
      // copies, so a fold killed by the timeout leaves nothing behind.
      final input = DayTailInput(
        checkpoint: probe.cp.state,
        tailRr: sub.rrMs,
        tailTs: sub.rrTsMs,
        edgeMs: rrFoldEdgeMs(probe.cp.cpRecTs),
        cutG: cut,
        accTs: sub.tsSec.sublist(from),
        ax: sub.ax.sublist(from),
        ay: sub.ay.sublist(from),
        az: sub.az.sublist(from),
        onsetSec: day.sleepOnsetSec,
        offsetSec: day.sleepOffsetSec,
      );
      // The fold reads no clock, zone or locale; the record is the entry's
      // contract.
      final inputs = WorkerInputs(
        nowEpochMs: DateTime.now().millisecondsSinceEpoch,
        zoneId: 'UTC',
        localeTag: 'en',
      );
      // Locals, not fields, inside the closures: the worker closure shares
      // their context, and a context holding `this` would send the engine
      // (not sendable: its Futures) to the isolate.
      final timeout = _perDayTimeout;
      final label = 'day-stream ${day.date}';
      return await perf.stage(
        'day_stream',
        () => _runIsolateCancellable<DayTailResult?>(
          () => foldDayTailHeavy(inputs, input),
          timeout,
          label: label,
        ),
      );
    } catch (e) {
      _log('day-stream ${day.date} not used: $e');
      return null;
    }
  }

  /// [day] with every beat of the day read (the checkpoint it was loaded
  /// against is not going to be used).
  Future<PreparedDerivationDay> _withFullRr(PreparedDerivationDay day) async {
    final dayStart = _localDayLabelToSec(day.date);
    final dayEnd = _localNextDayLabelToSec(day.date);
    final napSub = await _loadSubstrateRange(
      dayStart,
      dayEnd - 1 + napBoundaryBufferSec,
      dayId: day.date,
      label: 'load_day',
      ownership: day.ownership,
      retain: true,
    );
    return day.withFullRr(
      daySub: napSub.slice(dayStart, dayEnd),
      napSub: napSub,
    );
  }


  /// [foldDayCheckpoint] in a killable worker isolate. Static so the closure
  /// captures only the plain lists, never the engine.
  static Future<Uint8List?> _foldCheckpoint({
    required Uint8List? base,
    required int alreadyFolded,
    required List<int> ts,
    required List<int> hr,
    required List<double> ax,
    required List<double> ay,
    required List<double> az,
    required List<int> stepCounter,
    required int? age,
    required int? stepModulus,
    required MinuteBills? bills,
    required List<double> rrMs,
    required List<double> rrTsMs,
    required int throughSec,
    required double quietCutG,
    required Uint8List? nightJson,
    required List<Uint8List> cardioRowChunks,
    required int cardioRowsLoSec,
    required int cardioRowsHiSec,
    required Duration timeout,
    required String label,
  }) => _runIsolateCancellable(
        () => foldDayCheckpoint(
          base: base,
          alreadyFolded: alreadyFolded,
          ts: ts,
          hr: hr,
          ax: ax,
          ay: ay,
          az: az,
          stepCounter: stepCounter,
          age: age,
          stepModulus: stepModulus,
          bills: bills,
          rrMs: rrMs,
          rrTsMs: rrTsMs,
          throughSec: throughSec,
          quietCutG: quietCutG,
          nightJson: nightJson,
          cardioRowChunks: cardioRowChunks,
          cardioRowsLoSec: cardioRowsLoSec,
          cardioRowsHiSec: cardioRowsHiSec,
        ),
        timeout,
        label: label,
      );

  /// Stores the day's intraday calorie series as the artifact
  /// `kcal_minutes|<day>`, AFTER the day's own row committed, under the
  /// signature [LocalRepositoryImpl.artifactSignature] gives the same inputs
  /// (the fingerprint read before the substrate was). A failure is logged and
  /// never fails the derive: the curve is derivable again and the warmer will.
  /// No series (the builder abstained) removes an older row of a day that still
  /// has raw, so a curve never outlives the figure it explains; a day without
  /// raw keeps what it has, and an import (no fingerprint) stores nothing.
  Future<void> _storeKcalMinutes(
    PreparedDerivationDay day,
    Profile profile,
    Map<String, dynamic>? kcal,
  ) async {
    final fp = day.inputFp;
    if (fp == null) return;
    final key = 'kcal_minutes|${day.date}';
    try {
      if (kcal == null) {
        if (!day.daySub.isEmpty) await LocalDb.deleteLastResult(key);
        return;
      }
      await LocalDb.putLastResult(
        key,
        DateTime.now().millisecondsSinceEpoch,
        jsonEncode(kcal),
        200, // the LastResultCache row cap, which every artifact shares
        sig: '$kAlgoVersion|${kcalSignatureBody(fp, profile)}',
      );
    } catch (e) {
      _log('derive ${day.date}: could not store the calorie curve: $e');
    }
  }

  /// The intraday calorie series of an already-derived day, rebuilt from its
  /// decoded raw while that lives: what the warmer stores for a day derived
  /// before artifact signatures were stored. The inputs are the stored day's own (its sleep window
  /// and nocturnal resting HR from `day_result`) and the same credited step
  /// spans, over the same substrate loader, so the answer is the series the
  /// derive would have stored. Null when the day has no raw, was never derived,
  /// or the builder abstains. The substrate load and the build both run off the
  /// calling isolate.
  Future<Map<String, dynamic>?> kcalMinutesForStoredDay(
    String day,
    Profile profile,
  ) async {
    final lo = localDayStartSec(day), hi = localDayEndSec(day);
    if (lo == null || hi == null) return null;
    final stored = await LocalDb.dayCalorieInputs(day);
    if (stored == null) return null; // not derived: no sleep window to honour
    int onset = 0, offset = 0;
    final win = stored.windowJson == null || stored.windowJson!.isEmpty
        ? null
        : (jsonDecode(stored.windowJson!) as Map)['value'];
    if (win is Map) {
      final on = (win['onset_ms'] as num?)?.toDouble();
      final off = (win['offset_ms'] as num?)?.toDouble();
      // A window without both ends cannot say what is sleep: abstain.
      if (on == null || off == null) return null;
      onset = (on / 1000).round();
      offset = (off / 1000).round() + 1;
    }
    final (ownership, _) = await _resolveOwnership(lo, hi - 1);
    final daySub = await _loadSubstrateRange(
      lo,
      hi - 1,
      dayId: day,
      label: 'load_kcal',
      ownership: ownership,
    );
    if (daySub.isEmpty) return null;
    final liveSteps = await LocalDb.resolvedStepsForDay(day);
    final spans = [
      for (final s in liveSteps.spans) [s.startTs, s.endTs, s.steps],
    ];
    final dispatchId = WorkerAudit.dispatched(Dispatcher.run, 'kcal minutes');
    // Null in production; a test's port so the worker reports its entry.
    final auditPort = WorkerAudit.auditPort;
    return Isolate.run(() {
      WorkerAudit.adopt(auditPort, dispatchId);
      return kcalMinutesForDayHeavy(
        daySub: daySub,
        profile: profile,
        nocturnalRhr: stored.rhr,
        sleepOnsetSec: onset,
        sleepOffsetSec: offset,
        stepSpans: spans,
      );
    });
  }

  /// The day's calorie series, or null wherever the day's stored calories would
  /// be absent: the energy pass runs only for a day with motion minutes, and
  /// prices against the nocturnal resting HR or the one the user entered, never
  /// a daytime fallback. Pure; the offloaded second half and the warmer's
  /// rebuild both go through here so they cannot disagree.
  @heavy
  static Map<String, dynamic>? kcalMinutesForDayHeavy({
    required Substrate daySub,
    required Profile profile,
    required double? nocturnalRhr,
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    List<List<int>> stepSpans = const [],
    DayCalculationState? state,
    ana.CalculationMode mode = ana.CalculationMode.forced,
  }) {
    WorkerAudit.entered('kcalMinutesForDayHeavy');
    // Same state and mode as the activity pass, so this is a cache hit rather
    // than a second full ENMO series over the day.
    if (_motionMinutes(daySub, state: state, mode: mode).isEmpty) return null;
    return buildKcalMinutes(
      daySub: daySub,
      profile: profile,
      restingHr: nocturnalRhr ?? profile.restingHrManual?.toDouble(),
      sleepOnsetSec: sleepOnsetSec,
      sleepOffsetSec: sleepOffsetSec,
      stepSpans: stepSpans,
    );
  }

  /// Pin today's morning readiness headline once its overnight is genuinely
  /// COMPLETE, so the Today hero + recovery story stop drifting through the day
  /// (#128). Only the headline is pinned — this row's `day_result`, the
  /// baselines, trends and finalisation all keep updating on later re-derives.
  Future<void> _maybeFreezeHeadlineReadiness(
    PreparedDerivationDay day,
    int dataNowSec,
    double? readiness,
  ) async {
    // Only today's headline is pinned. Historical/backfill + imported days never
    // reach the Today hero, and imports are immutable snapshots anyway.
    if (day.date != todayLabel()) return;
    final hasSleep = day.sleepOffsetSec > day.sleepOnsetSec;
    if (!hasSleep) return;
    final overnightComplete = overnightSettled(
      sleepOffsetSec: day.sleepOffsetSec,
      dataEdgeSec: dataNowSec,
    );
    final current = await LocalDb.frozenHeadline();
    final next = nextFrozenHeadline(
      today: day.date,
      overnightComplete: overnightComplete,
      liveReadiness: readiness?.round(),
      current: current,
      wakeSec: day.sleepOffsetSec,
      onsetSec: day.sleepOnsetSec,
    );
    if (next == null) return;
    // Already pinned to this exact value → skip the redundant write.
    if (current != null &&
        current.day == next.day &&
        current.value == next.value &&
        current.wakeSec == next.wakeSec) {
      return;
    }
    await LocalDb.setFrozenHeadline(next.day, next.value, wakeSec: next.wakeSec);
    _log('froze headline readiness ${next.value} for ${next.day}');
  }

  /// Skip reasons that describe a TRANSIENT failure of this particular pass
  /// rather than a permanently pathological day. These must never finalize:
  /// finalizing locks the day out of every future pass at this algo version.
  static const Set<String> _transientSkipReasons = {'timeout', 'error'};

  /// edge#305 — whether THIS derive's night-physiology substrate has
  /// regressed to nothing even though [producedNothing] (in
  /// `_derivePreparedDay`) is false: plenty of daytime HR survives, but
  /// [sleepSubEmpty] (the night's own RR/HR substrate) is gone and every
  /// night-physiology scalar ([nightScalarsNull]) came back null. Deliberately
  /// NOT gated on this pass finding a sleep window: v83 required
  /// `hasSleepWindow` and missed the exact counterexample #305 named — a
  /// re-stage whose RR/HR substrate aged out can come back `NO_SLEEP_DETECTED`
  /// too, not just a truncated-but-present window, and that shape is just as
  /// much a regression against an existing real result. A genuinely-honest
  /// "this day never had sleep" case is still safe: it never had an existing
  /// result with real night scalars, so the caller's existing-result check is
  /// what actually distinguishes the two, not this shape test. Pure so the
  /// shape is unit-testable without the full pipeline; the caller still has to
  /// confirm an EXISTING result actually had real night scalars before
  /// declining to write over it.
  ///
  /// [sleepRejected] (the user said "not sleep") is never a regression: the
  /// null night is what they asked for, and the existing row is the very
  /// night they rejected.
  static bool nightSubstrateRegressed({
    bool sleepRejected = false,
    required bool sleepSubEmpty,
    required bool nightScalarsNull,
  }) => !sleepRejected && sleepSubEmpty && nightScalarsNull;

  /// Days whose stored night the user replaced ('Not sleep', or a window of
  /// their own), optionally limited to [within]; with [rejectedOnly], only
  /// "Not sleep" (a typed window over recorded time is a staged night).
  /// Read from the override rows alone, so it holds when there is no raw and no
  /// data edge at all.
  Future<Set<String>> _blankingOverrideDays([
    Iterable<String>? within,
    bool rejectedOnly = false,
  ]) async {
    final only = within?.toSet();
    final out = <String>{};
    for (final day in await LocalDb.sleepOverrideDays()) {
      if (only != null && !only.contains(day)) continue;
      final ov = await LocalDb.getSleepOverride(day);
      final source = ov?['source'] as String? ?? 'manual';
      if (ov != null &&
          (rejectedOnly ? userBlanksNight(source) : userReplacesNight(source))) {
        out.add(day);
      }
    }
    return out;
  }

  /// Whether the user has blanked [dayId]'s night: the override source when
  /// this derive found no night to compute, else null. "Not sleep" always
  /// blanks; a window of the user's own ('manual') is staged, and blanks only
  /// when the band recorded none of it. 'confirmed' never blanks.
  /// A user's override beats the edge#305 "raw was pruned" reading: with it the
  /// stored night is the thing to remove, not to protect.
  Future<String?> _userBlankedNight(
    String dayId,
    Map<String, dynamic>? scalars,
  ) async {
    final ov = await LocalDb.getSleepOverride(dayId);
    if (ov == null || scalars?['tst_min'] != null) return null;
    final source = ov['source'] as String? ?? 'manual';
    return userReplacesNight(source) ? source : null;
  }

  /// Drop the pinned morning readiness when it belongs to [dayId]: the pin is a
  /// copy of a score the night no longer supports.
  Future<void> _dropFrozenHeadline(String dayId) async {
    final pin = await LocalDb.frozenHeadline();
    if (pin != null && pin.day == dayId) {
      await LocalDb.deleteCursor(LocalDb.kFrozenHeadlineCursor);
    }
  }

  /// Blank a day's stored night when there is no raw left to re-derive from.
  /// Everything that is not the night (strain, steps, naps, curves) stays.
  Future<bool> _blankStoredNight(
    PreparedDerivationDay day,
    Map<String, dynamic> absent,
    String source,
    DayResultWrite reason,
  ) async {
    final existing = await LocalDb.dayResult(day.date);
    final prev = _isRealDayResult(existing)
        ? _decodeBundle(existing!['payload_json'])
        : null;
    final payload =
        prev == null ? absent : blankNightInBundle(prev, absent, source: source);
    // Already blanked at this version: a repeat pass writes nothing.
    final stored =
        existing == null ? null : _decodeBundle(existing['payload_json']);
    if (stored != null &&
        (existing!['algo_version'] as num?)?.toInt() == kAlgoVersion &&
        jsonEncode(stored) == jsonEncode(payload)) {
      return true;
    }
    final window = (absent['sleep'] as Map?)?['window'];
    final committed = await LocalDb.putDayResult(
      dayId: day.date,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(payload),
      windowJson: jsonEncode(window ?? const {}),
      finalized: (existing?['finalized'] as num?)?.toInt() == 1,
      source: 'band',
      blankKeys: kSleepDerivedMetricKeys,
      reason: reason,
    );
    if (committed) {
      _log('derive ${day.date}: night blanked by the user ($source), no raw '
          'left — stored night replaced, rest of the day kept');
    }
    return committed;
  }

  /// Whether [row] is a REAL derived day result worth protecting — i.e. not a
  /// skip marker and not an all-absent shell.
  static bool _isRealDayResult(Map<String, dynamic>? row) {
    if (row == null) return false;
    if ((row['skipped'] as num?)?.toInt() == 1) return false;
    final payload = _decodeBundle(row['payload_json']);
    if (payload == null) return false;
    if (payload['skipped'] == true) return false;
    final scalars = payload['scalars'];
    if (scalars is Map && scalars.values.any((v) => v != null)) return true;
    return row['rhr'] != null || row['rmssd'] != null || row['readiness'] != null;
  }

  /// Fill [next]'s missing detail from [prev] when the second-half compute
  /// failed, so a headline-only pass never blanks a day that already had naps,
  /// workouts, HRR, wear and curves. Returns true if anything was carried over.
  ///
  /// Keyed on ABSENCE, not on null: isolate 1 writes its headline scalars
  /// explicitly and a null there is a real "we could not measure this today"
  /// that must survive. Only keys the failed second half never got to add are
  /// restored — a freshly computed value always wins.
  @visibleForTesting
  static bool carryForwardDetail(
    Map<String, dynamic> prev,
    Map<String, dynamic> next, {
    // Blocks that must not be inherited (the night's own, for a blanked night).
    Set<String> skip = const {},
    // The user blanked this night ('rejected', or a 'manual' window with
    // nothing recorded in it). The previous result
    // still holds the night, and the scalar / series / sleep-period maps below
    // merge per key, so without this a failed second half gave the old night
    // back to a day that is supposed to have none.
    String? blankSource,
  }) {
    final blanked = blankSource != null;
    // `next` as the first half wrote it: the engine's own blank envelopes, which
    // [blankNightInBundle] puts back over whatever the merge carried in.
    final absent = blanked
        ? (jsonDecode(jsonEncode(next)) as Map).cast<String, dynamic>()
        : null;
    var carried = false;
    for (final e in prev.entries) {
      if (e.key == 'scalars' ||
          e.key == 'series' ||
          skip.contains(e.key) ||
          (blanked && kNightOnlyBundleKeys.contains(e.key))) {
        continue;
      }
      if (next.containsKey(e.key) || e.value == null) continue;
      next[e.key] = e.value;
      carried = true;
    }
    // `scalars` and `series` are flat maps the second half patches INTO rather
    // than owning, so they merge per key instead of wholesale.
    for (final sub in const ['scalars', 'series']) {
      final p = prev[sub];
      if (p is! Map) continue;
      final n = next[sub];
      if (n is! Map) {
        next[sub] = Map<String, dynamic>.from(p.cast<String, dynamic>());
        carried = true;
        continue;
      }
      // JSON-decoded prior curves need a dynamic-valued destination: the
      // pipeline's inferred map can reject List<dynamic> or an int scalar.
      // Merge into a dynamic copy, made only when something is carried, so a
      // pass with nothing to carry leaves the fresh map itself in place.
      Map<String, dynamic>? merged;
      for (final e in p.entries) {
        if (n.containsKey(e.key) || e.value == null) continue;
        (merged ??= Map<String, dynamic>.from(n))[e.key] = e.value;
        carried = true;
      }
      if (merged != null) next[sub] = merged;
    }
    if (blanked) {
      final out = blankNightInBundle(next, absent!, source: blankSource);
      next
        ..clear()
        ..addAll(out);
    }
    return carried;
  }

  /// A night staged off a paired device's records (its hypnogram, or our
  /// window over its HR), not off the primary band's own rows. Not
  /// 'auto_fallback' by itself: the band's own HR-led night carries it too.
  static bool _deviceStaged(SleepSessionCandidate c) =>
      c.sleepSource == 'vendor_staged' || c.deviceNight;

  /// Whether the banked [prev] stays over the fresh [next]: [isRicherSleep],
  /// except that the ring's own night outranks ours even when ours ran longer
  /// — but only the SAME night. A ring night whose edges do not agree with the
  /// banked window (a partly-synced one) never replaces it.
  @visibleForTesting
  static bool keepsBankedNight(
    SleepSessionCandidate prev,
    SleepSessionCandidate next,
  ) {
    final vendorWins = next.sleepSource == 'vendor_staged' &&
        prev.sleepSource != 'vendor_staged' &&
        vendorEdgesAgree(next.sleepOnsetSec, next.sleepOffsetSec,
            prev.sleepOnsetSec, prev.sleepOffsetSec);
    return !vendorWins && isRicherSleep(prev, next);
  }

  /// The night's measured total sleep, seconds. Null when this candidate has no
  /// night in it at all.
  static num? _tstSec(SleepSessionCandidate c) =>
      c.sleepJson['tst_sec'] as num?;

  /// Whether the already-banked [prev] night is RICHER than the freshly staged
  /// [next] one, measured by total sleep time (#242).
  ///
  /// TST, not confidence and not the window: it is the quantity the user sees
  /// change, and the failure mode this guards is a re-stage over a pruned
  /// substrate seeing less of the same night. A night that grows is a night the
  /// band handed over more of, and it wins.
  ///
  /// A candidate with no night at all is never richer than one that has one, and
  /// EQUAL is not richer — a pass that reproduces the same night writes, so an
  /// otherwise-identical candidate still refreshes.
  ///
  /// One bounded exception: a candidate whose end the band corroborated
  /// (`band_offset_trim_sec` set), with the same onset (±60 s), whose UNTRIMMED
  /// end covers the banked end, and whose TST loss does not exceed what was
  /// removed from the banked window (+60 s), replaces the banked night — that is
  /// a corrected wake time, not less substrate.
  @visibleForTesting
  static bool isRicherSleep(
    SleepSessionCandidate prev,
    SleepSessionCandidate next,
  ) {
    final p = _tstSec(prev);
    if (p == null) return false;
    final n = _tstSec(next);
    if (n == null) return true;
    int? trimOf(SleepSessionCandidate c) =>
        (c.sleepJson['band_offset_trim_sec'] as num?)?.toInt();
    final sameOnset = (next.sleepOnsetSec - prev.sleepOnsetSec).abs() <= 60;
    final nextTrim = trimOf(next);
    // A band END correction is not "less substrate" — but only for the part of
    // the banked night that lies inside the tail the band corroborated as
    // awake: the banked end must fall WITHIN (next end, next untrimmed end],
    // and the TST lost may not exceed what was removed from the banked window.
    // "Within", not "equal to", because the morning record GROWS: an early
    // pass banks a night whose awake tail is still < 10 min; a later pass trims.
    if (sameOnset &&
        nextTrim != null &&
        next.sleepOffsetSec < prev.sleepOffsetSec &&
        prev.sleepOffsetSec <= next.sleepOffsetSec + nextTrim + 60 &&
        p - n <= (prev.sleepOffsetSec - next.sleepOffsetSec) + 60) {
      return false;
    }
    // NO mirror rule (deliberately — review round 3): the trim is a
    // deterministic function of the stored rows, and rows are only added or
    // replaced by the same record, so a later pass with no trim means the band
    // now shows SLEEP later (e.g. a backfilled gap) — new evidence, which must
    // be allowed to win through the ordinary comparison.
    return p > n;
  }

  /// How a day should be filed after its second half failed and the previous
  /// result's detail was carried forward.
  ///
  /// The version check is the subtle part. `LocalDb.dayResult` returns the
  /// HIGHEST algo_version stored for the day, so immediately after a bump the
  /// row it hands back belongs to the previous version. Carrying that detail
  /// forward still beats blanking the day — but it must not be filed as a
  /// finished CURRENT-version result, because the reason a bump exists is that
  /// those blocks are computed differently now. A cross-version carry therefore
  /// stays partial and unfinalized, so a later pass recomputes it for real
  /// instead of locking last version's curves in under this version's number.
  @visibleForTesting
  static ({bool partial, bool finalized}) recoveryOutcome({
    required bool recovered,
    required bool prevPartial,
    required int? prevVersion,
    required bool prevFinalized,
    required bool finalizedByAge,
  }) {
    final sameVersion = prevVersion == kAlgoVersion;
    if (!recovered || prevPartial || !sameVersion) {
      // Stays partial, but keep whatever the caller had already decided about
      // finalizing: an IMPORT force-finalizes even a partial day, because there
      // is no stored raw to ever recompute it from.
      return (partial: true, finalized: finalizedByAge);
    }
    // As complete as it was before this pass, so it keeps what it had earned.
    return (partial: false, finalized: finalizedByAge || prevFinalized);
  }

  /// Test seam for [_markDaySkipped] — the "a skip marker must never destroy a
  /// real result" guarantee is the whole point of the method, so it is pinned
  /// directly rather than through a full derive pass.
  @visibleForTesting
  Future<void> debugMarkDaySkipped(
    String dayId,
    int dayEndSec,
    int dataNowSec, {
    required String reason,
  }) =>
      _markDaySkipped(dayId, dayEndSec, dataNowSec, reason: reason);

  /// Persist a minimal skip marker so a pathological day isn't retried forever.
  ///
  /// A SKIP MARKER MUST NEVER OVERWRITE A REAL RESULT. `putDayResult` is
  /// ConflictAlgorithm.replace on both `day_result` AND `metric_series`, so this
  /// used to blank a good day's every scalar on a single [_perDayTimeout]
  /// overrun — and, once the day sat >48 h behind the data edge, wrote the
  /// blank FINALIZED, making it permanent (raw is pruned at `rawRetentionDays`,
  /// so there is nothing left to re-derive from). It hit TODAY too: a good
  /// 08:00 result replaced by a skip marker after one transient 09:00 timeout
  /// on a loaded phone. `rescanRecent` explicitly refuses to do this for
  /// exactly this reason; `run()` did it anyway. Now: write the marker only
  /// when there is no good row to lose, and never lock a transient failure.
  Future<void> _markDaySkipped(
    String dayId,
    int dayEndSec,
    int dataNowSec, {
    required String reason,
  }) async {
    try {
      final existing = await LocalDb.dayResult(dayId);
      if (_isRealDayResult(existing)) {
        _log('derive $dayId $reason — existing result kept (not overwritten '
            'with a skip marker)');
        return;
      }
      await LocalDb.putDayResult(
        dayId: dayId,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({'skipped': true, 'reason': reason}),
        windowJson: '{}',
        // Structural failures (a day that can never be prepared / blows the
        // prepare budget) still finalize once aged out, so they aren't retried
        // forever. A timeout or a one-off error does not — that day gets
        // another chance while it still has raw.
        finalized: !_transientSkipReasons.contains(reason) &&
            (dayEndSec + _finalizationSec) < dataNowSec,
        skipped: true,
      );
    } catch (_) {
      /* best-effort */
    }
  }

  /// The family [key]'s baseline is split by for a day of [deviceFamily]:
  /// its method family, except a wearable's skin temperature, which is that
  /// device family's own nights (see [_BaselineHistoryCache.load]).
  static String? _baselineFamily(String key, String? deviceFamily) =>
      key == 'skin_temp_adc' && isWearableFamily(deviceFamily)
          ? deviceFamily
          : methodFamily(deviceFamily);

  /// Attach trailing personal history (from metric_series) for the readiness
  /// pass — the trailing window of days STRICTLY BEFORE the day being derived.
  ///
  /// The self-exclusion (`date < input.date`) is load-bearing, not cosmetic: see
  /// [_BaselineHistoryCache.valuesBefore]. Every one of these series is a
  /// BASELINE the day's own value is scored against, so the day's own row (which
  /// a previous derive of the same day already persisted) must not be in it.
  Map<String, dynamic> _attachHistory(
    DayBundleInput input,
    _BaselineHistoryCache history,
  ) {
    final m = input.toJson();
    final date = input.date;
    // Per method family (see [_BaselineHistoryCache._families]).
    final fam = methodFamily(input.deviceFamily);
    List<double> before(String key) => history.valuesBefore(key, date,
        family: _baselineFamily(key, input.deviceFamily));
    m['ln_rmssd_history'] = before('ln_rmssd');
    m['rhr_history'] = before('rhr');
    m['resp_history'] = before('resp_rate');
    // Robust nocturnal RMSSD history (the `rmssd` series) — feeds the EWMA hrv
    // baseline so its center matches today's headline RMSSD (same metric).
    m['rmssd_history'] = before('rmssd');
    // BASELINE for skin_temp_z is the RAW nightly ADC-mean series (`skin_temp_adc`),
    // NOT the z-score series. Feeding z-scores back as the baseline was a unit
    // mismatch that left z permanently null. The raw mean is stored every day so
    // this series fills and z starts computing once ≥3 days exist.
    m['skin_temp_adc_history'] = before('skin_temp_adc');
    // TS-03/TS-04 — the observed ceiling this day's ZONES are banded on. A max,
    // not a window (see [maxBefore]), and strictly before today so a day is
    // never banded on a ceiling its own session set.
    m['observed_hr_ceiling_bpm'] =
        history.maxBefore('hr_ceiling_bpm', date, family: fam);
    // The quiet-waking levels strain is priced against — the SAME window the
    // second half's recompute gets (`_DayBlocksInput.quietHrrHistory`), so the
    // two cannot score the day on different levels.
    m['quiet_hrr_history'] = before('quiet_hrr');
    m['readiness_z_history'] = before('readiness_z');
    return m;
  }

  // ── cross-day rollup ─────────────────────────────────────────────────────────

  static const Duration _crossDayTimeout = Duration(seconds: 30);
  static const int _crossDayWindow = 90;

  /// Whether a persisted `crossday_input` artifact may be reused AS-IS today.
  ///
  /// Pure, so it is unit-testable without a database — the seam that consumes it
  /// ([_crossDayInputDays]) cannot be.
  ///
  /// The artifact stamps `is_today: true` on the row that was today WHEN IT WAS
  /// BUILT. That is a fact about a day stored as a bare boolean, in a DURABLE
  /// row, so a cached artifact served on a later day hands `_todayNum` a record
  /// that still claims to be today — and yesterday's strain and nap minutes land
  /// inside tonight's `need_sec`. That is the exact imputation the stamp exists
  /// to prevent (§3.3), arriving through the cache instead of through `_lastNum`.
  ///
  /// Every current `_runCrossDay` call site refreshes the artifact immediately
  /// beforehand, so the stale read is not reachable today. That is an unenforced
  /// ordering coincidence and not something to rely on: one new caller, or one
  /// early return inside `_refreshBaselines`, makes it live and silent.
  ///
  /// An artifact with no `built_for_day` (written before this field existed)
  /// cannot be SHOWN to be fresh, so it is rebuilt rather than assumed fresh.
  static bool crossDayArtifactUsableToday(Object? decoded, String today) {
    if (decoded is! Map) return false;
    if (decoded['days'] is! List) return false;
    // The artifact stamps `algo_version` and this gate used to ignore it, so a
    // version bump that CHANGES THE ROW SHAPE (a new per-day field, e.g.
    // `hourly_hr`) was served from the pre-bump artifact for the rest of the
    // day — the new cross-day family silently saw nothing on the very pass the
    // bump existed to trigger. A shape the current code did not write is not
    // reusable, whatever day it was built for.
    if ((decoded['algo_version'] as num?)?.toInt() != kAlgoVersion) return false;
    final builtFor = decoded['built_for_day'];
    return builtFor is String && builtFor.isNotEmpty && builtFor == today;
  }

  Future<bool> _runCrossDay(Profile profile) =>
      perf.stage('crossday', () => _runCrossDayUntimed(profile));


  /// How many times the cross-day bundle was actually computed (not reused).
  int _crossDayComputed = 0;

  @visibleForTesting
  int get debugCrossDayComputed => _crossDayComputed;

  @visibleForTesting
  Future<void> runCrossDayForTest(Profile profile) => _runCrossDayUntimed(profile);

  @visibleForTesting
  Future<List<Map<String, dynamic>>> refreshCrossDayInputForTest() =>
      _refreshCrossDayInputArtifact();

  /// SHA-256 over everything [buildCrossDayBundle] is computed from, plus the
  /// algo version, the local day and the time-zone offset (it reads local
  /// clock times). Null when the inputs cannot be encoded: then nothing is
  /// ever reused.
  static String? _crossDayInputSig({
    required List<Map<String, dynamic>> days,
    required Map<String, dynamic> profile,
    required List<String> cycleStarts,
    required Map<String, List<String>> sessionTypes,
    required String builtForDay,
  }) {
    try {
      return sha256
          .convert(utf8.encode(jsonEncode([
            kAlgoVersion,
            builtForDay,
            DateTime.now().timeZoneOffset.inMinutes,
            profile,
            cycleStarts,
            sessionTypes,
            days,
          ])))
          .toString();
    } catch (_) {
      return null;
    }
  }

  /// Every FINISHED saved session, grouped by the local day it started on
  /// (TS-11's `sessionTypesByDate`).
  ///
  /// A live session is excluded — it has no end and no next morning yet, and
  /// including it would make today look like a single-session day that it may
  /// not turn out to be.
  ///
  /// The key is the CALENDAR-local day label, the same alphabet the day rows
  /// use. It is not the wake-to-wake physiological boundary, so a session
  /// started between midnight and wake is filed under the calendar day it
  /// began rather than the physiological day it ends inside. That costs at most
  /// the attribution of a 1 a.m. workout; the analytics drops multi-session
  /// days and refuses under ten mornings per type either way.
  static Future<Map<String, List<String>>> _sessionTypesByDate(
    List<Map<String, dynamic>> days,
  ) async {
    if (days.isEmpty) return const {};
    final first = days.first['date'];
    if (first is! String || first.isEmpty) return const {};
    final fromSec = _localDayLabelToSec(first);
    final toSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final out = <String, List<String>>{};
    for (final r in await LocalDb.sessionsInRange(fromSec, toSec)) {
      if (r['status'] == 'live') continue;
      final start = (r['start_ts'] as num?)?.toInt();
      final type = r['type']?.toString();
      if (start == null || type == null || type.isEmpty) continue;
      out
          .putIfAbsent(
            dayLabelOf(DateTime.fromMillisecondsSinceEpoch(start * 1000)),
            () => <String>[],
          )
          .add(type);
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _crossDayInputDays() async {
    final reviewRevision = await LocalDb.activityReviewRevision();
    final artifact = await LocalDb.baseline('crossday_input');
    final raw = artifact?['payload_json'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        // Day-gated, NOT just well-formed. The rows carry `is_today`, which is a
        // fact about the day the artifact was BUILT on; serving them on a later
        // day makes `_todayNum` read yesterday's strain and nap minutes as
        // today's (§3.3). See [crossDayArtifactUsableToday].
        if (crossDayArtifactUsableToday(decoded, LocalDb.localDayLabelNow()) &&
            (decoded as Map)['review_revision'] == reviewRevision) {
          final rows = decoded['days'] as List;
          return [
            for (final row in rows)
              if (row is Map) row.cast<String, dynamic>(),
          ];
        }
      } catch (_) {
        // Fall through to rebuild from day_result.
      }
    }
    return _refreshCrossDayInputArtifact();
  }


  // ── notifications generator ─────────────────────────────────────────────────

  @visibleForTesting
  /// [today] pins the day the pass runs on, so a test's seed and the pass
  /// agree even across a real midnight.
  Future<void> runNotificationsForTest({String? today}) =>
      _runNotifications(today: today);

  Future<void> _runNotifications({String? today}) =>
      perf.stage('notifications', () => _runNotificationsUntimed(today: today));


  /// Decode a stored day bundle, normalizing the compact curve format back to
  /// plain [{t,v}] lists.
  ///
  /// The normalization is LOAD-BEARING on the re-derive path, not just hygiene:
  /// `_deriveOneDay` reads the previous row through here and merges its series
  /// into the fresh bundle. Without normalizing, an encoded `prev` would be
  /// merged beside newly-computed legacy lists and the day would carry two
  /// different shapes for the same curve.
  static Map<String, dynamic>? _decodeBundle(Object? json) =>
      SeriesCodec.decodePayloadJson(json);

  /// One `day_result` row as a cross-day input record, with the per-day
  /// masks the rollup needs. Static and pure so it runs in the isolate.
  @visibleForTesting
  static Map<String, dynamic>? crossDayInputRecord(
    Map<String, dynamic> row,
    Map<String, dynamic> payload, {
    required String today,
    required Set<String> imported,
  }) {
    final rec = _crossDayRecord(row, payload);
    if (rec == null) return null;
    // An imported day's scores are another vendor's maths. The baseline
    // cache already masks them; the cross-day families (illness CUSUM,
    // anomaly, glass-box, percentiles) need the same mask or tonight's
    // reading is scored against that vendor's history. Sleep timing and
    // load stay, they are not an algorithm's opinion of the night.
    if (imported.contains(row['day_id'])) {
      for (final k in _crossDayVendorScoreKeys) {
        rec[k] = null;
      }
    }
    // Today's own row updates on every derive pass while the night is
    // still syncing/settling — feeding that partial reading into the
    // illness/anomaly CUSUM can fire a false "possible illness onset" on
    // data that's really just a truncated/mid-drain night. Only exclude
    // TODAY specifically; older days already had their 48h to settle.
    //
    // FLAG it rather than DROP it: `days` is the single input list for the
    // whole cross-day bundle, so dropping today also silently removed it
    // from readiness/glass-box, the resting-HR trend-shift CUSUM, load,
    // sleep debt and `recent` (whose last row dates every notification).
    // buildCrossDayBundle nulls only the alert inputs for a flagged day.
    //
    // Today is never finalized (that waits 48 h behind the data edge), so
    // "not finalized" alone held the alerts off all day, every day. The night
    // is done once the data edge is [_headlineFreezeMarginSec] past its wake,
    // the same test the headline pin uses; no wake yet is no complete night.
    // The edge is the one the row was derived against (`data_edge_sec`), so
    // the wake and the edge come from the same substrate; a row without one
    // stays unsettled.
    final wakeSec = (rec['wake_sec'] as num?)?.toInt();
    final dataEdgeSec = (payload['data_edge_sec'] as num?)?.toInt();
    // Kept on the record so a cached record can be re-judged on a later pass
    // without its payload (crossday_input.dart's `unsettled`).
    rec['data_edge_sec'] = dataEdgeSec;
    if (row['day_id'] == today &&
        (row['finalized'] as num?) != 1 &&
        (wakeSec == null ||
            dataEdgeSec == null ||
            dataEdgeSec < wakeSec + _headlineFreezeMarginSec)) {
      rec['unsettled'] = true;
    }
    // Explicit identity for TODAY-scoped reads. `unsettled` cannot serve
    // this purpose — it is only set while today's night is unsettled. Without a
    // flag, a today-scoped consumer can only take the LAST record
    // positionally, which on a day with no derived row is YESTERDAY's.
    if (row['day_id'] == today) rec['is_today'] = true;
    return rec;
  }

  /// Build the cross-day record from a day_result row + its payload bundle.
  static Map<String, dynamic>? _crossDayRecord(
    Map<String, dynamic> row,
    Map<String, dynamic> payload,
  ) {
    final date = row['day_id'] as String?;
    if (date == null || date.isEmpty) return null;
    final scalars =
        (payload['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    num? sc(String k) => scalars[k] is num ? scalars[k] as num : null;
    num? col(String k) => row[k] is num ? row[k] as num : null;

    // Safe map cast: a metric envelope's `value` is the string '—' when the
    // metric is ABSENT (e.g. a no-sleep day), so a blind `as Map?` throws. Only
    // treat it as a map when it really is one.
    Map<String, dynamic>? asMap(Object? v) =>
        v is Map ? v.cast<String, dynamic>() : null;

    final sleep = asMap(payload['sleep']);
    final win = asMap(sleep?['window']);
    final winVal = asMap(win?['value']);
    final acct = asMap(sleep?['accounting']);
    final acctVal = asMap(acct?['value']);
    final series = asMap(payload['series']);

    final onsetMs = (winVal?['onset_ms'] as num?)?.toDouble();
    final offsetMs = (winVal?['offset_ms'] as num?)?.toDouble();
    final tstSec = (acctVal?['tst_sec'] as num?)?.toDouble();
    final inBedSec = (acctVal?['in_bed_sec'] as num?)?.toDouble();
    final observedSec = (acctVal?['observed_in_bed_sec'] as num?)?.toDouble();

    return {
      'date': date,
      'rhr': col('rhr') ?? sc('rhr'),
      'rmssd': col('rmssd') ?? sc('rmssd'),
      'readiness': col('readiness') ?? sc('readiness'),
      'resp_rate': sc('resp_rate'),
      'skin_temp_z': sc('skin_temp_z'),
      // Only the refusal is written: an eligible night reads as before.
      if (!skinTempIllnessEligible(
          payload['device_family'] as String?, sc('skin_temp_ambient_r')))
        'skin_temp_illness_ok': false,
      'trimp': sc('trimp'),
      // Headline 0–21 strain, daily steps, nap minutes — feed Sleep/Strain Coach
      // + VO₂max/Fitness Age in the cross-day rollup.
      'strain': sc('strain'),
      'steps': sc('steps'),
      'nap_min': sc('nap_min'),
      'efficiency': sc('efficiency'),
      'onset_sec': onsetMs == null ? null : (onsetMs / 1000).round(),
      'wake_sec': offsetMs == null ? null : (offsetMs / 1000).round(),
      'tst_min': tstSec == null ? null : (tstSec / 60).round(),
      // Fraction of the night we actually watched — wall-clock in-bed minus the
      // seconds nobody observed, over in-bed. TS-11 drops a morning whose night
      // is under half observed: a resting HR from two hours of contact is not a
      // morning, and it would otherwise be attributed to whatever session the
      // day before happened to hold.
      // Unknown stays NULL, never 0: a night whose segmentation did not report
      // what it watched is not a night we watched none of, and 0 would read as
      // a confident "no coverage".
      'sleep_coverage': (inBedSec == null || inBedSec <= 0 || observedSec == null)
          ? null
          : observedSec / inBedSec,
      'hypnogram': series?['hypnogram'],
      // 24 local-hour means of this day's HR curve — the ONLY intraday series
      // that survives long enough to support cross-day circadian analysis.
      // `day_result` is never pruned; the 1 Hz substrate is gone at
      // `rawRetentionDays`, so accelerometry (the textbook ENMO input) simply
      // does not exist far enough back. `circadianNonparametric` documents HR
      // as an accepted input alongside activity. 24 numbers a day, so the
      // artifact stays small.
      'hourly_hr': hourlyHrProfile(series?['hr_curve']),
    };
  }

  /// Mean HR per LOCAL hour-of-day (24 entries, `null` where the hour is not
  /// covered) from a stored `series.hr_curve` (`[{t: epochSec, v: bpm}]`).
  ///
  /// An hour counts as covered only with [minMinutes] real minute-samples in
  /// it, so a bin is always a mean over genuine readings — never an average of
  /// one stray second, and never an imputed value. Gaps stay null and the
  /// consumer excludes the day; nothing is filled in.
  static List<double?> hourlyHrProfile(Object? hrCurve, {int minMinutes = 5}) {
    final sums = List<double>.filled(24, 0);
    final counts = List<int>.filled(24, 0);
    if (hrCurve is List) {
      for (final e in hrCurve) {
        if (e is! Map) continue;
        final t = (e['t'] as num?)?.toInt();
        final v = (e['v'] as num?)?.toDouble();
        if (t == null || v == null || v <= 0) continue;
        // LOCAL hour. The day model is local-midnight-to-midnight, so the UTC
        // hour would smear a user's evening into the next bin (and, for a
        // non-integral-offset zone, into the wrong one entirely).
        final h = DateTime.fromMillisecondsSinceEpoch(t * 1000).hour;
        if (h < 0 || h > 23) continue;
        sums[h] += v;
        counts[h] += 1;
      }
    }
    return [
      for (var h = 0; h < 24; h++)
        counts[h] >= minMinutes ? sums[h] / counts[h] : null,
    ];
  }

  /// Refresh the persisted rolling-baseline artifact + signature caches.
  ///
  /// Rebuilds from the de-duplicated `metric_series` store (see
  /// [_BaselineHistoryCache.load]) rather than persisting the in-memory cache
  /// the sweep mutated via [_BaselineHistoryCache.appendScalars] — that list is
  /// correct for intra-sweep freshness but is append-only with no day identity,
  /// so persisting it let repeated same-day re-derives stack duplicate copies of
  /// today into the window (the blank-readiness root cause). The read path
  /// ([_BaselineHistoryCache.load]) no longer trusts this artifact for history,
  /// but it still backs the cheap `signature` rescan gate, so keep it fresh.
  Future<void> _refreshBaselines() =>
      perf.stage('baselines', _refreshBaselinesUntimed);

  Future<void> _refreshBaselinesUntimed() async {
    final history = await _BaselineHistoryCache.load();
    final artifact = history.toArtifactJson();
    final rolling = ((artifact['rolling'] as Map?) ?? const {})
        .cast<String, dynamic>();
    await LocalDb.putBaselines({
      'rolling_artifact': jsonEncode(artifact),
      'rolling': jsonEncode(rolling),
    });
    await _refreshCrossDayInputArtifact();
  }

  // ── raw pruning (raw-first invariant) ──────────────────────────────────────

  /// Longest the raw-first hold below may keep substrate past
  /// [rawRetentionDays] for a day that still hasn't finalized.
  ///
  /// The hold has to be bounded or it is not a hold, it is an off switch. A
  /// `partial` day is DELIBERATELY never finalized by age (see
  /// `_derivePreparedDay` — a headline-only row must keep its chance to be
  /// filled in), and a transient skip never finalizes, so a day whose second
  /// half fails every single time never becomes finalized. One such day used
  /// to latch pruning off for the whole install, forever, at ~12 MB/day.
  static const int _maxRawHoldDays = 14;

  /// Cursor holding the highest `rec_ts` cutoff the raw prune has applied.
  static const String _prunedBeforeCursor = LocalDb.kDecodedPrunedBeforeCursor;
  /// Days whose raw is held back by the prune only because they lack a
  /// COMPLETE result: they start before the retention cutoff and are not in
  /// [derivedDayIds]. PURE. A manual sync that skips unchanged days must still
  /// derive these (invariant 9), or a stuck day would never get another chance
  /// to finish and release its raw.
  @visibleForTesting
  static Set<String> prunePendingDays({
    required List<String> rawDays,
    required Set<String> derivedDayIds,
    required int dataNowSec,
  }) {
    final cutoffSec = dataNowSec - rawRetentionDays * 86400;
    if (cutoffSec <= 0) return const {};
    return {
      for (final day in rawDays)
        if (!derivedDayIds.contains(day) && _localDayLabelToSec(day) < cutoffSec)
          day,
    };
  }

  /// The `rec_ts` below which decoded substrate may be deleted, or null when
  /// nothing may be. PURE — the decision the raw prune is, separated from the
  /// two DB calls that surround it. See [_pruneOldDecoded] for the contract.
  @visibleForTesting
  static int? rawPruneCutoffSec({
    required int dataNowSec,
    required List<String> rawDayIds,
    required Set<String> finalizedDayIds,
  }) {
    final cutoffSec = dataNowSec - rawRetentionDays * 86400;
    if (cutoffSec <= 0) return null;
    // Pending = not FINALIZED, not merely "has a result": an unlocked day is
    // still re-derived, and a re-derive from a cut night overwrites the good
    // row and then locks it.
    final pending =
        rawDayIds.where((d) => !finalizedDayIds.contains(d)).toList()..sort();
    if (pending.isEmpty) return _localDayStartOf(cutoffSec);
    // Hold at the start of the oldest pending day's derive window (the
    // previous noon, where its night search begins, see [_targetDayWindow]),
    // floored so a permanently stuck day cannot hold the whole install (see
    // [_maxRawHoldDays]).
    final barrier = math.max(
      _localDayLabelToSec(pending.first) - kNocturnalSearchLookbackSec,
      dataNowSec - _maxRawHoldDays * 86400,
    );
    return _localDayStartOf(barrier < cutoffSec ? barrier : cutoffSec);
  }

  /// Local midnight of the day [sec] falls in. The prune deletes WHOLE days:
  /// a cutoff mid-day left that day half-pruned, still in `decodedRecTsMaxByDay`,
  /// so the next rescan re-derived it from the surviving afternoon and replaced
  /// its full curve/wear with one starting wherever the cutoff happened to sit
  /// (#450). A fully-pruned day drops out of the rescan and keeps its result.
  static int _localDayStartOf(int sec) => _localDayLabelToSec(
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(sec * 1000)),
      );


  /// Storage housekeeping that must run on EVERY derive.
  ///
  /// Deliberately NOT inside [_pruneOldDecoded]. Both of that method's call
  /// sites used to sit behind `if (scope.fullHistory)` (they now run on every
  /// derive, but only inside `run()`, past its early returns), and ordinary
  /// light/heavy derives ran with `fullHistory: false`. Putting the
  /// back-catalogue rewrite there made it resumable but effectively
  /// unreachable — a normal install would have converted nothing.
  ///
  /// CALLED FROM THE `finally` OF EVERY ENTRY PATH, and it swallows its own
  /// errors, for two reasons that were both live:
  ///
  ///   • Reach. Called from the body, it sat below `if (dataNowSec <= 0)
  ///     return 0` and below two other early returns — so the install that most
  ///     needs it, one restored from a backup with years of derived history and
  ///     no decoded rows at all (they are capped at `rawRetentionDays`, so a
  ///     backup carries almost none), converted nothing, ever. runDays and
  ///     rescanRecent never reached it at all.
  ///   • Blast radius. Called unguarded from the body, a throw — SQLITE_BUSY
  ///     from the other derivation isolate, a full disk — skipped the raw prune
  ///     that enforces `rawRetentionDays`, skipped the timezone re-baseline, and
  ///     landed in the run-wide catch, so a derive that had actually completed
  ///     every day reported 0 back to `reanalyzeAll`. This work is a storage
  ///     optimization; nothing it does may change what the derive returns.
  ///
  /// Bounded and resumable, so running it on every pass costs one small batch.
  /// Off the path to a durable commit, and never inside a migration: `onUpgrade`
  /// runs under iOS's CPU watchdog (invariant 11).
  Future<void> _runStorageHousekeeping() async {
    try {
      final reencoded = await LocalDb.reencodeLegacyDayResults();
      if (reencoded > 0) {
        _log('re-encoded $reencoded legacy day bundles');
      }
      // Substrate archive retention, measured against the data edge like the
      // live prune. Off the commit path; vacuumIfBloated reclaims the pages.
      final edge = await LocalDb.lastDecodedRecTs();
      if (edge != null) {
        final evicted = await LocalDb.evictSubstrateArchive(
          await LocalDb.substrateArchivePolicy(),
          edge,
        );
        if (evicted > 0) _log('evicted $evicted substrate archive buckets');
      }
    } catch (e) {
      _log('storage housekeeping skipped: $e');
    }
  }

  /// The wake-minute series WITH its bucket keys (epoch-seconds ~/ 60), so a
  /// per-minute companion series (the measured cadence) can be aligned to the
  /// same minutes instead of guessed from array position.
  static ({List<int> keys, List<double> hr}) _perMinuteMeanWake(
    Substrate s,
    int sleepOnsetSec,
    int sleepOffsetSec, {
    int tonightSleepOnsetSec = 0,
  }) {
    bool asleep(int t) =>
        (sleepOffsetSec > sleepOnsetSec &&
            t >= sleepOnsetSec &&
            t < sleepOffsetSec) ||
        // Tonight's sleep, begun before midnight: asleep, not waking.
        (tonightSleepOnsetSec > 0 && t >= tonightSleepOnsetSec);
    // A wearable storing one HR every few minutes has each reading stand for
    // the minutes up to the next (same rule as onehz_pipeline's wake series):
    // a strap's 1 Hz seconds laid over its day stand for their own minute
    // only, and no reading spreads past the next one.
    final span = (ana.calibrationFor(kHrCadenceSec, s.deviceFamily) ?? 60) ~/ 60;
    final n = math.min(s.hr.length, s.tsSec.length);
    final buckets = <int, List<double>>{};
    for (var i = 0; i < n; i++) {
      if (s.hr[i] <= 0) continue;
      final t = s.tsSec[i];
      if (asleep(t)) continue;
      (buckets[t ~/ 60] ??= []).add(s.hr[i].toDouble());
      // Inside a 1 Hz run (a second or two after the one before); a
      // reading further off is the wearable's own, the first after a strap
      // run included, and stands for its minutes.
      if (i > 0 && t - s.tsSec[i - 1] <= kOneHzRunGapSec) continue;
      final next = i + 1 < n ? s.tsSec[i + 1] : t + 60 * span;
      if (next - t < 60) continue;
      for (var k = 1;
          k < span && t + 60 * k < next && !asleep(t + 60 * k);
          k++) {
        (buckets[t ~/ 60 + k] ??= []).add(s.hr[i].toDouble());
      }
    }
    final keys = buckets.keys.toList()..sort();
    return (keys: keys, hr: [for (final k in keys) _meanWake(buckets[k]!)!]);
  }

  /// Test seam for [_perMinuteMeanWake] on a day with no sleep in it.
  @visibleForTesting
  static ({List<int> keys, List<double> hr}) debugPerMinuteMeanWake(
          Substrate s) =>
      _perMinuteMeanWake(s, 0, 0);

  /// Whether `daySub` has AT LEAST ONE real HR sample (`hr > 0`) inside
  /// `[fromSec, toSec)` — the gate for the workout-gap credit in
  /// [applyDayActivity]. Same "real sample" test as [_perMinuteMeanWake]'s own
  /// bucketing, so "covered" here means exactly what would have priced a
  /// minute there.
  static bool _hasHrCoverage(Substrate s, int fromSec, int toSec) {
    for (var i = 0; i < s.hr.length && i < s.tsSec.length; i++) {
      if (s.hr[i] <= 0) continue;
      final t = s.tsSec[i];
      if (t >= fromSec && t < toSec) return true;
    }
    return false;
  }

  /// ONE HR-flex pass, returning the day's active, basal and total figures
  /// TOGETHER so they cannot disagree. THE canonical day calorie computation —
  /// every other day-level site mirrors this one, never re-derives it.
  ///
  /// [wakeHrPerMin] is the per-minute mean HR over the WAKE span only, and
  /// [dayMinutes] is how many minutes of the whole calendar day the substrate
  /// actually covers. That split is deliberate and is the whole semantic:
  ///
  ///   * active = Keytel surplus over the wake minutes. Sleep is not exercise.
  ///     Passing the whole-day series here bills the night as active energy:
  ///     `dailyEnergy`'s flex gate is 0.50*HRmax = 104 - 0.35*age bpm, which is
  ///     79.5 bpm at age 70, so an older sleeper whose nocturnal HR sits above
  ///     it gains thousands of fabricated active kcal per night.
  ///   * basal = Mifflin BMR pro-rated over [dayMinutes] — the WHOLE day,
  ///     sleep included, because basal metabolism does not stop overnight.
  ///   * total = basal + active, i.e. TDEE.
  ///
  /// This replaces a derivation-local Keytel sum (`_keytelCaloriesWake`) that
  /// billed the full Keytel rate on every active minute while `calories_total`
  /// came from a SECOND, separately-gated `ana.Calories.dailyEnergy` call whose
  /// active component nets out the basal minute already counted inside the
  /// total. The same minute was paid for twice, so `calories` read high by
  /// basalPerMin x active-minutes and the basal the Health export derives as
  /// `total - active` read low by the same amount. Active and total now come
  /// from a single call, and `total - active == basal` holds by construction.
  ///
  /// Returns null when the profile lacks an anchor Keytel actually reads
  /// ([Profile.hasCalorieAnchors]), when it carries no HEIGHT, or when no wake
  /// heart rate was recorded — absent beats fabricated, and "no HR at all" is
  /// not the same claim as "this day burned exactly your BMR".
  ///
  /// HEIGHT IS REQUIRED even though Keytel does not read it, and all three
  /// figures go absent without it. That is not the shape I wanted: height only
  /// enters through the Mifflin basal floor, so in principle the ACTIVE figure
  /// could still be published for a height-less profile. It cannot, because of
  /// how `dailyEnergy` defines active — the SURPLUS of the Keytel rate over the
  /// basal minute, `Σ max(0, keytel(HR) − bmrDay/1440)`. The Mifflin term is
  /// inside active, not just inside total, so standing a height in moves the
  /// active scalar too: 35 y / 80 kg male, 600 wake minutes at 130 bpm, gives
  /// active 6500 kcal at 150 cm against 6383 at 195 cm, and total 8068 against
  /// 8232. Both are persisted to `day_result` and both are exported to Apple
  /// Health / Health Connect, so a 170 cm stand-in silently writes someone
  /// else's body into the user's health record — larger than the double-count
  /// this pass exists to remove, and against the rule that an absent input
  /// makes the dependent metric absent rather than imputed. Recovering an
  /// active figure with no height would mean not netting the basal minute out,
  /// which is precisely the double-count. So: real height, or no calories.
  ///
  /// The 1 Hz pipeline's early-read `calories` gates on height for the same
  /// reason, so Today does not show a figure the derived day then withdraws.
  @visibleForTesting
  static ({double active, double basal, double total, double walking})?
      wakeDayEnergy(
    List<double> wakeHrPerMin, {
    required Profile profile,
    required double? restingHr,
    int? dayMinutes,
    String? deviceFamily,
    List<double?>? cadenceSpmPerMin,
  }) {
    if (!profile.hasCalorieAnchors) return null;
    // The active gate is a %HRR flex point, so it needs BOTH ends of the
    // reserve. No resting HR, no gate — and no gate means every wake minute
    // bills as active. Abstain, same as an absent ceiling below.
    if (restingHr == null) return null;
    // `dailyEnergy`'s flex gate is a fraction of HRmax, so an absent ceiling is
    // an absent gate — the whole triple abstains rather than bill a day against
    // some other strap's number. See hr_max.dart.
    final hrmax = estimatedMaxHr(profile.ageYears, deviceFamily);
    if (hrmax == null) return null;
    final heightCm = profile.heightCm;
    if (heightCm == null) return null;
    // Off-skin samples are the package's 0 sentinel; billing them would credit
    // lost contact at the resting rate. The cadence series is filtered in the
    // SAME pass: `dailyEnergy` aligns the two by index, so dropping an HR
    // entry without dropping its cadence would price every later cadence
    // against the wrong minute.
    if (cadenceSpmPerMin != null &&
        cadenceSpmPerMin.length != wakeHrPerMin.length) {
      // A caller bug, but a derive pass is not the place to throw: no cadence
      // beats a misaligned one, and the HR half of the figure is still real.
      cadenceSpmPerMin = null;
    }
    final hr = <double>[];
    final cadence = cadenceSpmPerMin == null ? null : <double?>[];
    for (var i = 0; i < wakeHrPerMin.length; i++) {
      if (wakeHrPerMin[i] <= 0) continue;
      hr.add(wakeHrPerMin[i]);
      cadence?.add(cadenceSpmPerMin?[i]);
    }
    if (hr.isEmpty) return null;
    final e = ana.Calories.dailyEnergy(
      hr,
      profile: ana.WorkoutUserProfile(
        weightKg: profile.weightKg!,
        heightCm: heightCm,
        age: profile.ageYears!.toDouble(),
        sex: _workoutSex(profile.sex),
      ),
      hrmax: hrmax,
      restingHr: restingHr,
      dayMinutes: dayMinutes ?? 1440,
      cadenceSpmPerMin: cadence,
    );
    // Anchors that cannot define an active gate are an ABSENT day's energy,
    // not a day billed entirely as active. `dailyEnergy` abstains; so does the
    // day, which is what every other caller of this method already expects.
    if (e == null) return null;
    return (
      active: e.active,
      basal: e.basal,
      total: e.total,
      walking: e.walking,
    );
  }

  static double? _meanWake(List<double> xs) {
    if (xs.isEmpty) return null;
    var s = 0.0;
    for (final x in xs) {
      s += x;
    }
    return s / xs.length;
  }

  /// The whole activity half of a day: wake features, then the real-pedometer
  /// step and movement overrides, applied to [bundle] and [scalars] in the
  /// order production applies them. Returns the wake-features payload with the
  /// measured step count copied back in.
  ///
  /// Exists as one named method rather than three calls inline in
  /// [_computeDayBlocks] so a test can assert on the SCALAR PAIR a persisted
  /// day actually carries. The calorie invariant held in `wakeDayEnergy` and
  /// broke on the way out of it — a second `dailyEnergy` further down the
  /// sequence overwrote `calories_total` — and a test that only exercised the
  /// helper could not see that.
  @visibleForTesting
  static Map<String, dynamic> applyDayActivity({
    required Map<String, dynamic> bundle,
    required Map<String, dynamic> scalars,
    required Substrate daySub,
    required Profile profile,
    required int sleepOnsetSec,
    required int sleepOffsetSec,

    /// Local midnight opening this day, and the start of the NEXT local day —
    /// both from the day LABEL. `_DayBlocksInput.dayEndSec` is NOT this: it is
    /// the data edge (`daySub.lastTs + 1`), which is exactly the span-shaped
    /// denominator `_wearBlock` had to stop using. Passing it here would
    /// reinstate the bug under a different name.
    required int dayStartSec,
    required int dayCalendarEndSec,
    required int dataNowSec,
    double? restingHr,
    double? dynFloorG,
    int liveStepsReal = 0,
    int liveStepsFromStrap = 0,
    int dynHistoryDays = 0,
    List<List<int>> stepSpans = const [],

    /// This day's `sessions` rows (`LocalDb.sessionsInRange`), for the
    /// zero-coverage credit below. Defaults to none — every existing caller
    /// keeps its old behaviour until it is threaded through.
    List<Map<String, dynamic>> sessions = const [],
    /// Step-counter calibration, read by the caller; null = uncalibrated.
    StepCalibrationProfile? counterProfile,
    int counterWearing = Wearing.wrist,
    /// Onset of tonight's sleep when it began before midnight, 0 = none. See
    /// `PreparedDerivationDay.tonightSleepOnsetSec`.
    int tonightSleepOnsetSec = 0,
    /// Prior days' `quiet_hrr`, strictly before this one (see
    /// [_BaselineHistoryCache.valuesBefore]). Fewer than three valid values
    /// and strain abstains.
    List<double> quietHrrHistory = const [],
    DayCalculationState? state,
    ana.CalculationMode mode = ana.CalculationMode.forced,
  }) {
    final wake = _buildWakeDayFeatures(
      daySub,
      profile,
      sleepOnsetSec: sleepOnsetSec,
      sleepOffsetSec: sleepOffsetSec,
      tonightSleepOnsetSec: tonightSleepOnsetSec,
      dayStartSec: dayStartSec,
      dayCalendarEndSec: dayCalendarEndSec,
      dataNowSec: dataNowSec,
      restingHr: restingHr,
      dynFloorG: dynFloorG,
      stepSpans: stepSpans,
      quietHrrHistory: quietHrrHistory,
      state: state,
      mode: mode,
    );
    // ACTIVE ENERGY WORKOUT-GAP CREDIT. `wake['calories']` above is built
    // ENTIRELY from `daySub.hr` — the day's own continuous 1 Hz trace — and
    // never once reads `sessions`. A workout scores its OWN calorie figure
    // through a completely separate pipeline (`computeManualSessionStats` /
    // the live-tick accumulator, reconciled in `reconcileSessionScore`), so a
    // session whose window the band's PPG lost contact for — commonly a
    // wrist-gripping or arm-swinging one, e.g. lifting or a brisk walk, next
    // to a low-motion one like Pilates that keeps contact — can be fully
    // scored on its own summary card while contributing exactly nothing to
    // Active Energy, because that window is a real, total gap in `daySub.hr`.
    //
    // Credited ONLY when a session's window has ZERO real HR samples in
    // `daySub` — never a partial one — which is what makes this safe: a
    // window `daySub.hr` already priced any of is left alone, so this can
    // never double-bill a minute the trace already counted. A day the trace
    // produced no figure for at all is left absent, same as always — this
    // fills a gap in an existing number, it does not fabricate one.
    if (wake['calories'] != null && sessions.isNotEmpty) {
      var credited = 0.0;
      for (final s in sessions) {
        if (s['status'] != 'done') continue;
        if ((s['private'] as num?)?.toInt() == 1) continue;
        final sStart = (s['start_ts'] as num?)?.toInt();
        final sEnd = (s['end_ts'] as num?)?.toInt();
        final sCal = (s['calories'] as num?)?.toDouble();
        if (sStart == null ||
            sEnd == null ||
            sEnd <= sStart ||
            sCal == null ||
            sCal <= 0) {
          continue;
        }
        if (_hasHrCoverage(daySub, sStart, sEnd)) continue;
        credited += sCal;
      }
      if (credited > 0) {
        wake['calories'] = (wake['calories'] as num).toDouble() + credited;
        final total = wake['calories_total'];
        if (total != null) {
          wake['calories_total'] = (total as num).toDouble() + credited;
        }
        // Provenance for the envelope built in `_applyWakeDayFeatures` below —
        // without this, `calories_total`'s `inputs_used`/note would keep
        // claiming an hr_1hz-only figure while the emitted value silently
        // includes session-sourced kcal.
        wake['calories_session_credit'] = credited;
      }
    }
    // A day can't have less strain than a workout inside it. The two are
    // priced on different windows and baselines, and a logged strain-8 run
    // under a strain-3 day reads as a bug. Only a scored day is floored; an
    // abstaining one stays absent.
    wake['strain'] =
        strainFlooredAtSessions((wake['strain'] as num?)?.toDouble(), sessions);
    _applyWakeDayFeatures(bundle, scalars, wake);
    _stepsAndEnergy(
      bundle,
      scalars,
      daySub,
      profile,
      liveStepsReal,
      liveStepsFromStrap,
      dynFloorG,
      dynHistoryDays,
      counterProfile: counterProfile,
      counterWearing: counterWearing,
      state: state,
      mode: mode,
    );
    // `_stepsAndEnergy` just wrote `steps` — REAL pedometer counts from
    // `live_coverage`, band 100 Hz or phone, never an estimate. `wake` was
    // built before that ran and deliberately leaves `steps` null: the
    // early-read path has no gait-capable source of its own and must not invent
    // one. `wake` is what `_persistWakeDayFeatures` stores and what the Today
    // repository reads until the full day result exists, so copy the measured
    // count back in — otherwise Today shows no steps on a day that really was
    // measured. `calories_total` is NOT in this list any more: it is written
    // once, by `_applyWakeDayFeatures`, and is already in `wake`.
    final measuredSteps = scalars['steps'];
    if (measuredSteps != null) wake['steps'] = measuredSteps;
    return wake;
  }

  /// [strain], raised to the highest strain of a finished, non-private
  /// session in [sessions]. Null stays null.
  @visibleForTesting
  static double? strainFlooredAtSessions(
    double? strain,
    List<Map<String, dynamic>> sessions,
  ) {
    if (strain == null) return null;
    var best = strain;
    for (final s in sessions) {
      if (s['status'] != 'done') continue;
      if ((s['private'] as num?)?.toInt() == 1) continue;
      final v = (s['strain'] as num?)?.toDouble();
      if (v != null && v.isFinite && v > best) best = v;
    }
    return best;
  }

  static void _applyWakeDayFeatures(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Map<String, dynamic> wake,
  ) {
    final activeMin = (wake['active_min'] as num?)?.toDouble();
    if (activeMin != null) scMap?['active_min'] = activeMin;
    // STRAIN IS WRITTEN EVEN WHEN NULL — same rule as `steps`. This is the
    // recompute every surface reads (home tile, strain detail, metric_series,
    // the coach), so an abstaining day must ERASE what a previous derive wrote,
    // not leave it standing: days built before v68 carry a strain computed off
    // a daytime "resting" HR, and `if (strain != null)` kept exactly those.
    final strain = (wake['strain'] as num?)?.toDouble();
    scMap?['strain'] = strain;
    // Same rule for the two figures that ride with it: a re-derive that now
    // abstains must erase what the last one wrote. `quiet_hrr` is this day's
    // own quiet level — it feeds LATER days' strain baselines, never this
    // day's — and `trimp_net` is the load earned above it, the per-day input
    // a training-load (CTL/ATL) read wants instead of gross TRIMP.
    scMap?['quiet_hrr'] = (wake['quiet_hrr'] as num?)?.toDouble();
    scMap?['trimp_net'] = (wake['trimp_net'] as num?)?.toDouble();
    final calories = (wake['calories'] as num?)?.toDouble();
    if (calories != null) scMap?['calories'] = calories;
    final steps = (wake['steps'] as num?)?.toDouble();
    if (steps != null) scMap?['steps'] = steps;
    final caloriesTotal = (wake['calories_total'] as num?)?.toDouble();
    if (caloriesTotal != null) scMap?['calories_total'] = caloriesTotal;
    // The TDEE block is published HERE, from the same `wakeDayEnergy` result
    // that produced the two scalars above. `_stepsAndEnergy` used to emit it
    // from a SECOND `ana.Calories.dailyEnergy` call of its own — differently
    // gated, and over the whole 1440-minute day rather than the covered span —
    // so it silently overwrote `calories_total` with a figure that did not
    // belong to the same estimate as `calories`. `total - active` then handed
    // the Health export a basal that was wrong by tens of kcal/day in either
    // direction. One pass, one block.
    //
    // `calories_basal` is the third component of that one pass, and its
    // consumer is the `basal` field just below: publishing the figure the pass
    // actually produced, rather than re-deriving it as `total - active`, is
    // what makes the Health export's subtraction and this block agree by
    // construction instead of by arithmetic luck. It is deliberately NOT copied
    // into `scMap` — `day_result` carries the two scalars the app and the
    // export read, and a third one with no reader is a thing to keep in sync
    // for nothing.
    final caloriesBasal = (wake['calories_basal'] as num?)?.toDouble();
    if (caloriesTotal != null && calories != null && caloriesBasal != null) {
      // Disclosed only when it actually priced something: an input listed on a
      // day it contributed nothing to would claim pedometer coverage the day
      // may not have.
      final walking = (wake['calories_walking'] as num?)?.toDouble() ?? 0.0;
      final sessionCredit =
          (wake['calories_session_credit'] as num?)?.toDouble() ?? 0.0;
      bundle['calories_total'] = <String, dynamic>{
        'value': caloriesTotal.round(),
        'active': calories.round(),
        'basal': caloriesBasal.round(),
        'confidence': 0.5,
        'tier': 'ESTIMATE',
        'inputs_used': [
          'hr_1hz',
          'profile',
          if (walking > 0) 'live_coverage_pedometer',
          if (sessionCredit > 0) 'saved_session_calories',
        ],
        'note': 'total daily energy: Mifflin BMR floor over the covered day + '
            'active Keytel surplus over the wake span (HR-flex)'
            '${walking > 0 ? ' + measured-cadence walking term '
                '(CADENCE-Adults, ${walking.round()} kcal)' : ''}'
            '${sessionCredit > 0 ? ' + workout-gap session calories '
                '(PPG lost the window, ${sessionCredit.round()} kcal)' : ''}',
      };
    }
    // WHY each of the above is absent, per figure. This recompute is the answer
    // every surface reads for the figures it owns, so its reasons win. NOTE
    // `bundle` here is the isolate's PATCH map, not the pure pipeline's bundle
    // — the two are merged at the `bundle.addAll(blocks.bundlePatch)` call
    // site, and that merge is where `trimp` and `zones` (the pipeline's alone;
    // nothing here recomputes them) are carried across.
    bundle['absent_notes'] = <String, String>{
      for (final e in ((wake['absent_notes'] as Map?) ?? const {}).entries)
        e.key.toString(): e.value.toString(),
    };
    bundle['activity'] = wake['activity'];
    bundle['activity_curve'] = wake['activity_curve'];
    bundle['hr_stats'] = wake['hr_stats'];
    bundle['wear'] = wake['wear'];
  }

  /// The personal movement floor, estimated ONCE and then frozen.
  ///
  /// Returns the persisted value if one exists. Otherwise, once enough trailing
  /// `dyn_p90` days have accumulated, commits the median and returns it. Below
  /// that it returns null and the estimator abstains — deliberately, since a
  /// constant fallback is the exact failure this design removes.
  ///
  /// Why frozen: the floor is derived from the same signal it thresholds, so a
  /// continuously-recomputed floor tracks the user and reports a near-constant
  /// number regardless of behaviour (measured: 37 active minutes at 1x, 1.5x,
  /// 2x AND 3x activity, versus 23 -> 254 with a frozen floor).
  ///
  /// ORDER-INDEPENDENCE. The floor is ONE persisted scalar shared by every day,
  /// but `run()` dispatches days NEWEST-FIRST through a concurrent worker pool,
  /// so this read-modify-write is reached by several days at once. Three things
  /// keep the outcome from depending on which worker finishes last:
  ///
  ///   1. `_floorLock` serializes the whole read/decide/write, so two days can
  ///      never both observe "nothing stored" and both commit.
  ///   2. `daysSinceFrozen` is clamped at 0 (see [mfp.daysSinceFrozen]), so a
  ///      backfill day never reads as a stale floor and never triggers a
  ///      re-freeze just for being old.
  ///   3. `mayCommitFloorOn` stops an older day overwriting a newer freeze.
  ///
  /// Without these, a `kAlgoVersion` bump — which this very change forces —
  /// would re-derive the whole retained window and let sweep order decide every
  /// day's `active_min`. That is precisely what `_BaselineHistoryCache`'s own
  /// contract forbids for baselines.
  static Future<double?> _frozenMovementFloor(
    _BaselineHistoryCache history,
    String dayId,
  ) =>
      _floorLock.run(() => _resolveMovementFloor(history, dayId));

  /// Serializes the shared-floor read-modify-write across concurrent day
  /// workers. See [_frozenMovementFloor].
  static final _AsyncLock _floorLock = _AsyncLock();

  /// Serializes [updateStepCalibration]'s bank-then-refit across day workers.
  static final _AsyncLock _stepCalibrationLock = _AsyncLock();

  static Future<double?> _resolveMovementFloor(
    _BaselineHistoryCache history,
    String dayId,
  ) async {
    final stored = await LocalDb.getMovementFloor();
    final hist = history.valuesBefore('dyn_p90', dayId);

    if (stored != null) {
      // Re-freeze only on a real change of scale, never on elapsed time alone.
      //
      // NOTE on the unwired signals: `shouldRefreezeFloor` also accepts
      // `deviceChanged` and `wristChanged`, and edge has no reliable source for
      // either yet (no persisted device identity, no wrist-selection history),
      // so they are deliberately NOT passed rather than passed as a fabricated
      // `false` that reads like a checked condition. `wearGapDays` IS
      // derivable — a run of days with no `dyn_p90` row means the band was not
      // worn — so it is computed and passed.
      final refreeze = ana.shouldRefreezeFloor(
        daysSinceFrozen: mfp.daysSinceFrozen(
          frozenOn: stored.frozenOn,
          dayId: dayId,
        ),
        wearGapDays: mfp.wearGapDays(
          have: history.datesFor('dyn_p90'),
          dayId: dayId,
        ),
      );
      if (!refreeze) return stored.floorG;

      // A re-freeze that CANNOT be satisfied must not destroy what we have.
      // Falling through to enrollment with thin history would return null and
      // make `active_min` vanish for the day — and that is reachable exactly
      // when re-freezing matters most (an old floor on a user whose recent
      // `dyn_p90` history was pruned or is sparse). Keep serving the existing
      // floor until a replacement can actually be computed.
      if (hist.length < ana.enrollmentDaysForFrozenFloor) return stored.floorG;

      // REACHABLE, and this is the case it exists for: an OLD backfill day that
      // trips the re-freeze rule (a 30-day wear gap before it is the common
      // one) and has enough prior history to recompute. Without this it would
      // overwrite the freeze a NEWER day just established, and since the sweep
      // runs newest-first and concurrently, sweep order would decide the floor.
      // A backfill day may CONSUME the shared floor; it may never move it.
      if (!mfp.mayCommitFloorOn(frozenOn: stored.frozenOn, dayId: dayId)) {
        return stored.floorG;
      }
    } else if (hist.length < ana.enrollmentDaysForFrozenFloor) {
      // Still enrolling, and nothing stored to fall back on. Return null so the
      // metric abstains and says so, rather than shipping a threshold we have
      // already proven will be re-derived.
      return null;
    }

    final floor = ana.personalDynFloorFromDailySummaries(hist);
    if (floor == null) return stored?.floorG;
    await LocalDb.putMovementFloor(
      floorG: floor,
      frozenOn: dayId,
      days: hist.length,
    );
    if (kDebugMode) {
      debugPrint('[derive] movement floor FROZEN at '
          '${floor.toStringAsFixed(4)} g from ${hist.length} days ($dayId)');
    }
    return floor;
  }

  /// Write the day's step count. REAL PEDOMETER MEASUREMENTS ONLY.
  ///
  /// The 1 Hz substrate contributes NOTHING here and must never do so again.
  /// The removed estimate multiplied 1 Hz "active minutes" by a walking cadence
  /// band; on a real user day it reported 2,645 steps against a true count
  /// under 400. Both halves of that conversion are invalid at 1 Hz:
  ///   * cadence is not identifiable (gait 1.4-2.3 Hz is sub-Nyquist; 80/100/
  ///     140/160 spm all alias to the same 0.333 Hz), and
  ///   * the minutes counted were never specifically ambulation — at the wrist,
  ///     arm work out-accelerates walking (stirring ~104 mg, chopping ~139 mg
  ///     vs walking ~66 mg ENMO), which is why wrist devices are documented
  ///     emitting 22-27 false steps/min during dishes and driving (O'Connell
  ///     2017) while missing slow walking at sensitivity 0.05.
  /// Two errors of OPPOSITE sign: no gain constant fixes both.
  ///
  /// So `steps` is absent unless something that can actually see gait measured
  /// it: the Tier A 100 Hz pedometer, or the phone's own pedometer (both land
  /// in `live_coverage`). No real source -> no number.
  ///
  /// Called BEFORE the movement-substrate guards, because it depends on none of
  /// them — see the call site.
  ///
  /// [bandSteps] is the gen5 strap's OWN pedometer total for the day (see
  /// [hardwareStepsFromCounter]) — a genuine on-wrist gait counter, not a 1 Hz
  /// inference, so it outranks the phone. Null on every gen4 day, and on a gen5
  /// day whose records predate schema v34; that is the absent case, not zero.
  ///
  /// [profile] scales the counter total (null/uncalibrated = raw); [wearing]
  /// is the placement it was learned for, 0 when refused for this day.
  static void _writeSteps(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    int liveStepsReal, {
    int liveStepsFromStrap = 0,
    CounterDeltas? counter,
    StepCalibrationProfile? profile,
    int wearing = Wearing.wrist,
    List<({int startTs, int endTs, int steps})>? bandSpans,
  }) {
    // THE SOURCE LADDER, and where each rung is actually decided.
    //
    // Rungs 1 (band 100 Hz) and 3 (phone) are WINDOWED and were already settled
    // before this ran: `LocalDb.resolvedStepsForDay` walked the day's spans and
    // gave each one to the best source that covered it, so `liveStepsReal` is
    // already a sum of resolved spans and `liveStepsFromStrap` is the band's
    // share of it. Nothing here re-decides that.
    //
    // Rung 2, the gen5 ON-CHIP COUNTER, cannot join that sum honestly. It is a
    // cumulative u16 with no midnight reset (`hardwareStepsFromCounter`
    // differences it across the day's records). Its deltas do carry times, one
    // per record, so the day screen gets hourly `spans` off them; but adding
    // it to the windowed spans would double-count every walk the other two
    // already counted. So it stays a
    // WHOLE-DAY FALLBACK — used only when no span source covered the day at
    // all. That inversion is deliberate: whole-day precedence for this counter
    // is exactly the bug being fixed (622 steps published over the phone's
    // 18,856 on a day the strap synced for part of).
    final strap = liveStepsFromStrap.clamp(0, liveStepsReal);
    final phone = liveStepsReal - strap;
    final rawBand = counter?.total;
    final calibratedBand =
        rawBand == null ? null : applyStepCalibration(rawBand, profile);
    final useBand =
        liveStepsReal <= 0 && calibratedBand != null && calibratedBand > 0;
    final steps = useBand ? calibratedBand : liveStepsReal;
    final calibrated = useBand && profile != null && profile.isCalibrated;
    final haveRealSteps = steps > 0;
    if (haveRealSteps) {
      scMap?['steps'] = steps.toDouble();
    } else {
      scMap?.remove('steps');
    }
    bundle['steps'] = <String, dynamic>{
      'value': haveRealSteps ? steps : null,
      'real_measured': liveStepsReal,
      // What the strap's own pedometer counted, independent of which source
      // won. Null (never 0) when this generation has no counter at all. Raw
      // ticks; `counter_calibration` carries the factor applied to `value`.
      'band_measured': rawBand,
      if (counter != null && wearing != 0)
        'counter_wearing': wearingName(wearing),
      if (calibrated)
        'counter_calibration': <String, dynamic>{
          'factor': profile.factor,
          'n_days': profile.nDays,
        },
      if (counter != null)
        'counter_coverage': <String, dynamic>{
          'samples': counter.sampleCount,
          'gap_seconds': counter.gapSeconds,
          'dropped_boundaries': counter.droppedBoundaries,
        },
      // When the on-chip counter is the day's answer, WHEN it counted: hourly
      // spans off the counter's own per-record times, scaled by the same
      // factor as `value` and summing to it exactly.
      if (useBand && bandSpans != null)
        'spans': _scaleSpans(bandSpans, rawBand!, calibratedBand),
      // WHICH SENSOR COUNTED WHAT, so a screen can say so instead of implying
      // the phone's count came off the wrist or the other way round. Only the
      // keys that contributed are present — a zero here would read as "that
      // sensor was there and counted nothing", which is a different claim.
      'by_source': haveRealSteps
          ? <String, int>{
              // What the chip counted, not the scaled value: the factor is
              // in `counter_calibration`.
              if (useBand)
                'strap_counter': rawBand!
              else ...{
                if (strap > 0) 'strap': strap,
                if (phone > 0) 'phone': phone,
              },
            }
          : const <String, int>{},
      'source': !haveRealSteps
          ? null
          : useBand
              ? 'strap_counter'
              : (strap > 0 && phone > 0)
                  ? 'mixed'
                  : (strap > 0 ? 'strap' : 'phone'),
      'confidence': haveRealSteps
          ? (useBand ? stepCounterConfidence(profile) : 0.9)
          : 0.0,
      // NO TIER ON AN ABSENT METRIC. `ESTIMATE` here was actively wrong in two
      // ways: this code path never estimates anything (that is the whole point
      // of the change), and `Metric.parse` turns tier == ESTIMATE into
      // `beta: true`, which paints the estimate/beta badge onto a card that has
      // no number on it at all. `null` parses to `MetricTier.unknown`, which is
      // what "we did not measure this" actually is. `ABSENT` is deliberately
      // NOT invented: `Tier.all` in analytics is a closed set of four published
      // grades and the edge must not widen it from here.
      'tier': haveRealSteps ? 'HIGH' : null,
      // Likewise, nothing was used when nothing was measured.
      // NAMES THE SENSOR, not the table it came out of. `live_coverage_pedometer`
      // was the storage location and covered both the wrist and the pocket,
      // which is the one distinction the ladder exists to preserve. The UI
      // reads these to label the card.
      'inputs_used': !haveRealSteps
          ? const <String>[]
          : useBand
              ? const ['band_step_counter']
              : <String>[
                  if (strap > 0) 'band_pedometer_100hz',
                  if (phone > 0) 'phone_pedometer',
                ],
      'note': haveRealSteps
          ? (useBand
              ? 'Steps from the strap\'s on-chip pedometer, summed from its cumulative counter. '
                'Intervals where the counter wrapped or reset add no steps.'
                '${calibrated ? ' Scaled by ${profile.factor.toStringAsFixed(2)} '
                    'from ${profile.nDays} days your phone counted alongside '
                    'it.' : ''}'
              : (strap > 0 && phone > 0)
                  ? 'Counted over measured windows only. In each window the better sensor '
                    'that was recording supplies the count: the strap while it streamed, '
                    'your phone the rest of the time. Overlaps count once. Time that no '
                    'sensor covered is left out and is not estimated.'
                  : 'Pedometer count over measured windows only. Time outside those windows adds no steps.')
          : 'No step count: no sensor that can resolve gait recorded this day. '
            'A 1 Hz wrist stream cannot count steps, so the app shows no number.',
    };
  }

  /// [spans] (raw counter ticks summing to [raw]) as bundle maps rescaled to
  /// sum to exactly [target]: cumulative rounding, so no step is lost or added.
  static List<Map<String, int>> _scaleSpans(
      List<({int startTs, int endTs, int steps})> spans, int raw, int target) {
    var cum = 0;
    var placed = 0;
    return [
      for (final s in spans)
        () {
          cum += s.steps;
          final upTo = raw <= 0 ? 0 : (cum * target / raw).round();
          final n = upTo - placed;
          placed = upTo;
          return {'start_ts': s.startTs, 'end_ts': s.endTs, 'steps': n};
        }(),
    ];
  }

  /// STEPS (real pedometer counts ONLY) + movement minutes + total daily energy
  /// (TDEE), written into the bundle's `steps`/`movement` blocks + `scalars`.
  ///
  /// Steps = [liveStepsReal] and nothing else — the pedometer counts banked in
  /// `live_coverage` by a source that can actually resolve gait (the band's
  /// 100 Hz AN-2554 stream, or the phone's own pedometer). Time outside those
  /// windows is NOT counted and NOT estimated: with no real count the day has
  /// no step number at all. See the long note at the call site for why the old
  /// 1 Hz estimate was removed rather than recalibrated.
  ///
  /// Movement minutes are a separate, explicitly non-locomotion activity index
  /// computed over the whole day. Best-effort. Calories are NOT computed here —
  /// `_applyWakeDayFeatures` owns them, from one `wakeDayEnergy` pass.
  static void _stepsAndEnergy(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate daySub,
    Profile profile,
    int liveStepsReal,
    int liveStepsFromStrap,
    double? dynFloorG,
    int dynHistoryDays, {
    StepCalibrationProfile? counterProfile,
    int counterWearing = Wearing.wrist,
    DayCalculationState? state,
    ana.CalculationMode mode = ana.CalculationMode.forced,
  }) {
    try {
      // STEPS FIRST — they depend on NOTHING from the band substrate.
      //
      // `liveStepsReal` comes from `live_coverage`, i.e. the phone pedometer or
      // a live 100 Hz session. Both of the guards below protect the 1 Hz
      // MOVEMENT computation, and if the step assignment sat after them a day
      // with real measured phone steps but a thin band substrate (a day the
      // band barely synced, or a fresh install) would silently report no steps
      // at all — discarding a real measurement because an unrelated signal was
      // missing. Assign steps before anything can return early.
      // The strap's own pedometer, when this strap has one (gen5). Read off
      // `daySub` — already sliced to this calendar day — so the first record's
      // delta against yesterday's last is not carried across the boundary.
      final counter = counterDeltasFromSubstrate(
        daySub,
        cumulativeCounterModulus:
            ana.calibrationFor(_stepCounterModulus, daySub.deviceFamily),
      );
      _writeSteps(
        bundle,
        scMap,
        liveStepsReal,
        liveStepsFromStrap: liveStepsFromStrap,
        counter: counter,
        profile: counterProfile,
        wearing: counterWearing,
        bandSpans: hardwareStepSpansFromCounter(
          daySub,
          cumulativeCounterModulus:
              ana.calibrationFor(_stepCounterModulus, daySub.deviceFamily),
        ),
      );

      if (daySub.length < 60) return;
      final motion = _motionMinutes(daySub, state: state, mode: mode);
      if (motion.isEmpty) return;

      // This day's own contribution to the personal floor, persisted to
      // metric_series so tomorrow's derive can anchor on it. Null for a day too
      // thin to summarise — we store nothing rather than a fabricated level.
      final dynSummary = ana.dailyDynSummary(motion);
      if (dynSummary != null) scMap?['dyn_p90'] = dynSummary;

      // MOVEMENT MINUTES run over the WHOLE day — no coverage exclusion.
      //
      // Minutes covered by a pedometer window used to be dropped here, because
      // steps were "real count over covered time + 1 Hz estimate over the rest"
      // and including both would double-count. That hybrid is gone: steps are
      // real-measured only and movement minutes are a separate quantity in a
      // different unit, so there is nothing to double-count. Excluding covered
      // minutes now would just silently under-report movement for exactly the
      // periods we know the user was active.
      final est = ana.dailyActiveMinutes(
          motion,
          personalDynFloorG: dynFloorG,
          // DAYS, and the parameter now says so. This used to be
          // `pooledMinutesAvailable`, a MINUTE count compared against a
          // 2000-minute floor, while every caller passed a day count — the
          // cold-start note read "have=3, need=2000" for a user three days in.
          // Analytics renamed it and now counts it against the 5-day floor it
          // was always describing.
          historyDaysAvailable: dynHistoryDays,
          // A CALENDAR DAY, as `enmoSeries` is given below. Without it the
          // coverage denominator is the worn SPAN, which excludes the unworn
          // ends: a day worn 4 h out of 24 published coverage 1.0.
          expectedMinutes: 1440,
      );
      final v = est.present ? est.value : null;

      // Movement minutes stay, as an explicitly non-locomotion activity index.
      //
      // IT DOES NOT WRITE `active_min`. That key is `_activeMinutes` — minutes
      // over the WAKE span where >20% of seconds showed a >5° z-angle change —
      // and this is ENMO bouts (≥3 min) over the FULL calendar day against a
      // personal g floor. Two algorithms, two windows, one key: `dailyActiveMinutes`
      // abstains until the floor freezes (~day 5), so the day it starts
      // answering, the user's 'active' trend stepped to a different quantity
      // with no change in behaviour — and stepped again on every re-freeze.
      // This figure is published under its own names, `movement` below and
      // `activity.movement_min`, and `active_min` has exactly one producer.
      bundle['movement'] = <String, dynamic>{
        'active_min': v?.activeMinutes,
        'bout_count': v?.boutCount,
        'dyn_floor_g': v?.dynFloorG,
        'coverage': v?.coverage,
        'confidence': est.present ? est.confidence : 0.0,
        'tier': 'ESTIMATE',
        // HR is NOT an input any more — the resting-HR gate was deleted in v56
        // after it changed active minutes by exactly zero on every day tested.
        'inputs_used': const ['dyn_amp_1hz', 'personal_dyn_floor'],
        'note': v == null
            ? (est.note ?? 'need_baseline')
            : 'Minutes of sustained wrist movement. This is activity volume, and the app does not convert it to steps.',
      };
      // ENERGY IS NOT COMPUTED HERE. `_applyWakeDayFeatures` has already
      // published `calories`, `calories_total` and the TDEE block from the
      // single `wakeDayEnergy` pass, and this method must not touch any of
      // them. It used to run a second, differently-gated `dailyEnergy` of its
      // own and overwrite `calories_total` with it, which broke the one thing
      // the pair is supposed to guarantee: that `calories_total - calories` is
      // the day's basal. See the note in `_applyWakeDayFeatures`.
    } catch (e) {
      if (kDebugMode) debugPrint('[derive] steps/energy skipped: $e');
    }
  }

  Future<void> _persistWakeDayFeatures({
    required String dayId,
    required Map<String, dynamic> wake,
  }) async {
    final payload = <String, dynamic>{'day_id': dayId, ...wake};
    await LocalDb.putWakeDayFeatures(
      dayId: dayId,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(payload),
    );
  }

  static Map<String, dynamic> _buildWakeDayFeatures(
    Substrate daySub,
    Profile profile, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required int dayStartSec,
    required int dayCalendarEndSec,
    required int dataNowSec,
    double? restingHr,
    double? dynFloorG,
    List<List<int>> stepSpans = const [],
    int tonightSleepOnsetSec = 0,
    List<double> quietHrrHistory = const [],
    DayCalculationState? state,
    ana.CalculationMode mode = ana.CalculationMode.forced,
  }) {
    // With a state these come from running per-second summaries of the day,
    // appended each pass; each is bit-identical to the batch reader beside it.
    final motionSummary = state?.motionSummary(
      daySub.tsSec,
      daySub.ax,
      daySub.ay,
      daySub.az,
      sleepOnsetSec: sleepOnsetSec,
      sleepOffsetSec: sleepOffsetSec,
      mode: mode,
    );
    final hrSummary = state?.hrSummary(
      'activity',
      daySub.tsSec,
      daySub.hr,
      sleepOnsetSec: sleepOnsetSec,
      sleepOffsetSec: sleepOffsetSec,
      age: profile.ageYears?.round(),
      mode: mode,
    );
    final activeMin = motionSummary != null
        ? motionSummary.activeMinutes()
        : _activeMinutes(daySub, sleepOnsetSec, sleepOffsetSec);
    final wear = _wearBlock(
      daySub,
      dayStartSec: dayStartSec,
      dayCalendarEndSec: dayCalendarEndSec,
      dataNowSec: dataNowSec,
      runs: motionSummary?.wearRuns(),
    );
    // Tonight's sleep begun before midnight leaves the waking series (upstream
    // v106). The streamed summary knows no such cut, so it serves only a day
    // without one, where the two are the same series. Nor does it know
    // upstream's spread rule (a reading every few minutes stands for the
    // minutes up to the next), so a day whose family stores HR that sparsely
    // reads the batch too.
    final spreadsReadings =
        (ana.calibrationFor(kHrCadenceSec, daySub.deviceFamily) ?? 60) ~/ 60 >
            1;
    final wakeSeries = tonightSleepOnsetSec > 0 || spreadsReadings
        ? _perMinuteMeanWake(daySub, sleepOnsetSec, sleepOffsetSec,
            tonightSleepOnsetSec: tonightSleepOnsetSec)
        : hrSummary?.wakeMinutes() ??
            _perMinuteMeanWake(daySub, sleepOnsetSec, sleepOffsetSec);
    final perMin = wakeSeries.hr;
    // The day's MEASURED walking cadence, minute-aligned to the same wake
    // buckets — from the resolved `live_coverage` spans, so band/phone overlap
    // is already settled and a step is never priced twice. Null minutes are
    // exactly the minutes nobody's pedometer covered.
    final wakeCadence = stepSpans.isEmpty
        ? null
        : cadenceSpmForMinutes(wakeSeries.keys, stepSpans);
    final motion = _motionMinutes(daySub, state: state, mode: mode);
    final dayHrValid = <double>[
      for (final h in daySub.hr)
        if (h > 0) h.toDouble(),
    ];
    // NEVER IMPUTE A PROFILE. These used to default to age 30 / 70 kg / sex 'm'
    // / RHR 60 "so new users still get Strain" — and the results were then
    // persisted as REAL scalars (strain, calories, calories_total, steps) into
    // day_result AND metric_series for someone who never entered a profile.
    // That is a fabricated number wearing a real number's clothes, and it
    // contradicts the never-impute contract the rest of this layer (and
    // `Profile`'s own doc, and the pure `onehz_pipeline` which already gates on
    // exactly these fields) enforces. A missing input now makes the DEPENDENT
    // metric absent — the UI already renders "—" correctly.
    // age/weight are read by `wakeDayEnergy` straight off the profile now, so
    // they are no longer unpacked here — TRIMP only needs the sex constant.
    final sex = profile.sex?.toLowerCase();
    // ONE definition (hr_max.dart): null when age is unknown OR when we cannot
    // say which strap measured this day.
    final hrMax = estimatedMaxHr(profile.ageYears, daySub.deviceFamily);
    final rhrForTrimp = restingHr ?? profile.restingHrManual?.toDouble();
    // THIS user's quiet-waking level, from PRIOR days only — the same list the
    // pure pipeline got, through the same analytics call, so both halves price
    // the day identically.
    final quiet = ana.personalQuietWakingHrr(quietHrrHistory);
    // TODAY's own quiet level — persisted for LATER days' baselines only. It
    // never scores today (that would subtract today's own living from itself).
    // Below `quietHrrTraitMinMinutes` wake minutes the day measured that
    // window, not ordinary living, and contributes nothing.
    final quietToday = (rhrForTrimp == null || hrMax == null)
        ? null
        : ana.dailyQuietWakingHrr(perMin,
            restingHr: rhrForTrimp,
            maxHr: hrMax,
            minMinutes: ana.quietHrrTraitMinMinutes);
    final minuteMetrics = state?.minutes(
      wakeSeries.keys,
      perMin,
      cadence: wakeCadence,
      restingHr: rhrForTrimp,
      maxHr: hrMax,
      sex: _workoutSex(sex) == 'female' ? ana.Sex.female : ana.Sex.male,
      profile: !profile.hasCalorieAnchors || profile.heightCm == null
          ? null
          : ana.WorkoutUserProfile(
              weightKg: profile.weightKg!,
              heightCm: profile.heightCm!,
              age: profile.ageYears!.toDouble(),
              sex: _workoutSex(sex),
            ),
      dayMinutes: motion.length,
      mode: mode,
    );
    double? strain;
    ana.NetTrimp? net;
    // Why each absent activity figure is absent, in the order the gates below
    // apply. Absence is never a bare nothing here: the day carries its own
    // reason PER FIGURE so every caller can say what is missing instead of
    // showing a dash — or, worse, guessing (the Strain screen used to blame a
    // missing resting HR on a day that had one, because the only reason written
    // down was attached to a metric it does not read).
    //
    // Same order and same vocabulary as `deriveDayBundle`'s pure half, which
    // gates on exactly these inputs; the two must not disagree about WHY.
    final ceilingAbsent = hrMax != null
        ? null
        : profile.ageYears == null
        ? needInputNote('age')
        // We know the age; we do not know what measured the HR, so we
        // have no ceiling to band it against.
        : ana.unknownFamilyNote(daySub.deviceFamily);
    String? strainAbsent = perMin.isEmpty
        ? needInputNote('wake_hr')
        : hrMax == null
        ? ceilingAbsent
        : dayHrValid.isEmpty
        ? needInputNote('hr_samples')
        : rhrForTrimp == null
        ? needInputNote('resting_hr')
        : sex == null
        ? needInputNote('sex')
        : !quiet.present
        ? (quiet.note ?? kUnknownAbsenceNote)
        : null;
    // `wakeDayEnergy`'s own gates, named. It returns a bare null, so the reason
    // has to be reconstructed from the same inputs it reads — in its order.
    final caloriesAbsent = perMin.isEmpty
        ? needInputNote('wake_hr')
        // The whole energy pass is gated on having motion minutes to pro-rate
        // the basal floor over; a day with no accel never reaches it.
        : motion.isEmpty
        ? needInputNote('accel_1hz')
        : profile.ageYears == null
        ? needInputNote('age')
        : profile.weightKg == null
        ? needInputNote('weight_kg')
        : sex == null
        ? needInputNote('sex')
        : hrMax == null
        ? ceilingAbsent
        // Keytel does not read height; `dailyEnergy`'s ACTIVE
        // term nets out a Mifflin basal minute, which does.
        : profile.heightCm == null
        ? needInputNote('height_cm')
                        : null;
    double? calories;
    double? steps; // stays null here — real counts only, see below
    double? movementMin;
    double? caloriesTotal;
    double? caloriesWalking;
    double? caloriesBasal;
    if (perMin.isNotEmpty && hrMax != null) {
      // TRIMP needs a resting HR that is actually RESTING — a NOCTURNAL reading
      // (`scalars.rhr_nocturnal`, sleep-window only) or one the user entered —
      // and a real sex constant. Both are in the Banister formula itself.
      // `restingHr` used to arrive as `scalars.rhr`, which falls back to
      // daytime HR when no sleep was detected: ~20 bpm high on the days it
      // fired, which shrinks the HR reserve and manufactures strain out of
      // sitting still. No resting HR of either kind now means NO STRAIN.
      if (dayHrValid.isNotEmpty &&
          rhrForTrimp != null &&
          sex != null &&
          quiet.present) {
        // Same sex normalisation the calorie path uses. This read `sex == 'f'`
        // alone, so a profile stored as 'female' (which the profile screen can
        // write) got female calorie coefficients and MALE TRIMP off the same
        // field. Banister publishes only two constants, so `nonbinary` has
        // nowhere else to go here.
        final sexEnum =
            _workoutSex(sex) == 'female' ? ana.Sex.female : ana.Sex.male;
        // Banister TRIMP ABOVE this user's quiet level over `perMin`, the wake
        // window. Exercise minutes (≥ 40 % HRR) are never offset by quiet ones,
        // so a quiet afternoon cannot cancel a morning run.
        net = ana.netTrimpAboveQuiet(
          perMin,
          restingHr: rhrForTrimp,
          maxHr: hrMax,
          quietHrr: quiet.value!.hrr,
          sex: sexEnum,
        );
        // The same map `strainScoreFromSeries` applies to the same NetTrimp —
        // one pass, and the persisted `trimp_net` and `strain` cannot come
        // from two different accumulations. (The calibrating confidence lives
        // on the pipeline's envelope; this half writes a bare scalar.)
        if (net != null) strain = ana.strainFromNetTrimp(net.net);
        // Every named input was there and the scorer still abstained. We do not
        // know why; saying so is the honest floor, and it is what the rule
        // "never a guessed cause" leaves when there is no cause to name.
        strainAbsent ??= strain == null ? kUnknownAbsenceNote : null;
      }
      // NO ZONES HERE. The day's `zones` are the pure pipeline's, binned on
      // the same `trainingZones` set as `zone_timeline`/`zone_source` beside
      // them. Recomputing them here off `estimatedMaxHr` alone drew
      // age-estimate bars under a footnote naming the measured ceiling.
      // Calories are NOT computed here any more. Active and total both come
      // from the single `wakeDayEnergy` pass below, off this same wake series —
      // scoring active separately here, without the basal netting, is exactly
      // how the two figures drifted apart.
    }
    if (motion.isNotEmpty) {
      // STEPS ARE NOT COMPUTED HERE. This is the EARLY-READ path (what Today
      // shows before the full day result exists), and there is no gait-capable
      // source available to it — the real pedometer counts live in
      // `live_coverage` and are summed by `_stepsAndEnergy`, which overwrites
      // this artifact moments later via the copy-back below.
      //
      // It used to seed `steps` from the 1 Hz estimate so Today had something
      // to show immediately. That is exactly the fabrication being removed:
      // "something to show" is not a reason to invent a measurement. `steps`
      // stays null here and Today renders no step figure until a real count
      // exists.
      //
      // Movement minutes ARE computable from 1 Hz and are emitted below.
      final movementMetric = ana.dailyActiveMinutes(
        motion,
        personalDynFloorG: dynFloorG,
        // Same calendar-day denominator as the other call site; `motion` is
        // built from the whole day substrate here too.
        expectedMinutes: 1440,
      );
      if (movementMetric.present && movementMetric.value != null) {
        movementMin = movementMetric.value!.activeMinutes.toDouble();
      }
      // Mifflin BMR floor + Keytel active surplus, in ONE pass, so `calories`
      // and `calories_total` are two components of the same estimate rather
      // than two separate ones.
      //
      // ACTIVE reads the WAKE series and TOTAL's basal floor reads the whole
      // covered day. Feeding the whole-day series to the active term bills
      // sleep as exercise: `dailyEnergy`'s flex gate is 0.50*HRmax, i.e. only
      // 79.5 bpm at age 70, so an older sleeper spends the night above it.
      // `dayMinutes` pro-rates the basal floor over the span actually covered,
      // so a partial day is not billed a full 24 h BMR.
      final energy =
          mode == ana.CalculationMode.periodicAwake &&
              minuteMetrics != null &&
              perMin.isNotEmpty &&
              profile.hasCalorieAnchors &&
              profile.heightCm != null
          ? minuteMetrics.energy
          : wakeDayEnergy(
              perMin,
              profile: profile,
              // The same anchor the TRIMP above is scored against — a nocturnal RHR
              // or the one the user entered, never a daytime fallback.
              restingHr: rhrForTrimp,
              dayMinutes: motion.length,
              deviceFamily: daySub.deviceFamily,
              cadenceSpmPerMin: wakeCadence,
            );
      if (energy != null) {
        calories = energy.active;
        caloriesTotal = energy.total;
        caloriesBasal = energy.basal;
        caloriesWalking = energy.walking;
      }
    }
    // Same peak, same smoothing as the pipeline's copy and as every workout
    // producer — see `hr_max.dart` and the note beside the pipeline's `hrStats`.
    // A bare max over raw 1 Hz let one PPG transient be the day's "Peak HR"
    // (#127).
    final dayHrInt = [for (final h in dayHrValid) h.round()];
    final age = profile.ageYears?.round();
    final hrStats = hrSummary != null
        ? hrSummary.hrStats()
        : dayHrValid.isEmpty
        ? null
        : {
            'max':
                smoothedMaxHr(dayHrInt, age: age) ??
                dayHrValid.reduce(math.max).round(),
            'min':
                smoothedMinHr(dayHrInt, age: age) ??
                dayHrValid.reduce(math.min).round(),
            'avg': _meanWake(dayHrValid)?.round(),
          };
    return {
      'active_min': activeMin,
      'movement_min': movementMin,
      'strain': strain,
      'quiet_hrr': quietToday,
      'trimp_net': net?.net,
      // Machine-readable reason `strain` is null (see `strainAbsent`). Null
      // when a strain WAS produced.
      'strain_absent': strain == null ? strainAbsent : null,
      // …and the same, per figure, for the rest of the activity family. A key
      // is present ONLY when that figure is absent. `_applyWakeDayFeatures`
      // merges this onto the bundle's `absent_notes`, which is what the serve
      // seam attaches to the value it hands a screen — see the note there.
      'absent_notes': <String, String>{
        if (strain == null) 'strain': strainAbsent ?? kUnknownAbsenceNote,
        if (hrMax == null && ceilingAbsent != null)
          'max_hr_used': ceilingAbsent,
        if (calories == null) 'calories': caloriesAbsent ?? kUnknownAbsenceNote,
        if (caloriesTotal == null)
          'calories_total': caloriesAbsent ?? kUnknownAbsenceNote,
      },
      'calories': calories,
      'steps': steps,
      'calories_total': caloriesTotal,
      // Carried alongside so the TDEE block can be published from the same pass
      // instead of being re-derived (or, as it once was, recomputed by a second
      // caller with different gating). Not a user-facing scalar: the Health
      // export derives basal as `calories_total - calories`, and this is here to
      // make sure that subtraction and this figure are the same number.
      'calories_basal': caloriesBasal,
      // How much of `calories` came from the measured-cadence walking term
      // rather than HR (0 when no pedometer coverage priced anything). Carried
      // for the TDEE block's disclosure — a figure whose provenance changed
      // must say so in `inputs_used`.
      'calories_walking': caloriesWalking,
      'wear_min': (wear['worn_min'] as num?)?.toDouble(),
      'activity': {
        'value': activeMin,
        'active_min': activeMin,
        'movement_min': movementMin,
        'confidence': 0.6,
        'tier': 'ESTIMATE',
        'inputs_used': const ['accel_1hz'],
        'note':
            'Minutes of wrist movement over wake (1 Hz). This is activity volume. The app never converts it to steps, '
            'because at the wrist arm work registers as strongly as walking. '
            'Step counts come only from the 100 Hz stream or the phone pedometer.',
      },
      'activity_curve':
          motionSummary?.activityCurve() ?? _activityCurve(daySub),
      'hr_stats': hrStats,
      'wear': wear,
    };
  }

  /// Active minutes over the WAKE span — a coarse 1 Hz movement proxy.
  ///
  /// NULL, not 0, when nothing was countable. A gen5 day (or a gen4
  /// R10-historical one) decodes 1 Hz records with no usable accel, so every
  /// second is skipped below and the loop falls out with `active == 0` — which
  /// published "0 active minutes" as a measurement for a fully-worn band.
  static int? _activeMinutes(
      Substrate s, int sleepOnsetSec, int sleepOffsetSec) {
    final n = s.length;
    if (n < 60) return null;
    final ang = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      ang[i] = ana.zAngle(s.ax[i], s.ay[i], s.az[i]);
    }
    const moveDeg = 5.0;
    const activeFrac = 0.20;
    final moveSec = <int, int>{};
    final totSec = <int, int>{};
    for (var i = 1; i < n; i++) {
      // A second with no gravity vector contributes to NEITHER count: it has a
      // z-angle of exactly 0.0°, so counting it as denominator would read as
      // stillness and the fraction below would be diluted by missing data.
      if (!s.accelPresentAt(i) || !s.accelPresentAt(i - 1)) continue;
      final t = s.tsSec[i];
      if (sleepOffsetSec > sleepOnsetSec &&
          t >= sleepOnsetSec &&
          t < sleepOffsetSec) {
        continue;
      }
      final m = t ~/ 60;
      totSec[m] = (totSec[m] ?? 0) + 1;
      if ((ang[i] - ang[i - 1]).abs() > moveDeg) {
        moveSec[m] = (moveSec[m] ?? 0) + 1;
      }
    }
    if (totSec.isEmpty) return null;
    var active = 0;
    totSec.forEach((m, tot) {
      if (tot > 0 && (moveSec[m] ?? 0) / tot >= activeFrac) active++;
    });
    return active;
  }

  /// The last motion result per day substrate: both readers in one activity
  /// pass ask for the same day, and the second must not redo the first.
  static final _motionBySub = Expando<
      ({DayCalculationState? state, ana.CalculationMode mode,
        List<ana.MotionMinute> minutes})>();

  static List<ana.MotionMinute> _motionMinutes(
    Substrate s, {
    DayCalculationState? state,
    ana.CalculationMode mode = ana.CalculationMode.forced,
  }) {
    final last = _motionBySub[s];
    if (last != null && identical(last.state, state) && last.mode == mode) {
      return last.minutes;
    }
    // 1440 = a calendar day. Both callers pass the day substrate, and without
    // it `EnmoResult.coverage` divides by the SPAN of minutes that had a
    // sample — so a day worn 4 h out of 24 reported coverage 1.0. Only
    // `.minutes` is read here today; passing it keeps the result honest if
    // coverage is ever surfaced.
    // With a state the minutes come from its folded per-minute buckets, which
    // add only the seconds it has not seen (no copy of the day); a valid second
    // there is the same one: HR locked AND a real gravity vector, either
    // missing making it unusable for ENMO, not a still one.
    final minutes = List<ana.MotionMinute>.unmodifiable(
      state == null
          ? ana.enmoSeries(<ana.AccelSample>[
              for (var i = 0; i < s.length; i++)
                ana.AccelSample(
                  s.tsSec[i] * 1000.0,
                  s.ax[i],
                  s.ay[i],
                  s.az[i],
                  valid: s.hr[i] > 0 && s.accelPresentAt(i),
                ),
            ], expectedMinutes: 1440).minutes
          : state.dynMinutes(s.tsSec, s.hr, s.ax, s.ay, s.az, mode),
    );
    _motionBySub[s] = (state: state, mode: mode, minutes: minutes);
    return minutes;
  }

  /// See `workoutSex` in profile.dart — the one definition, shared with the
  /// pure pipeline, the live tick and manually logged sessions.
  static String _workoutSex(String? sex) => workoutSex(sex);

  // NOTE: `advanced_sleep` (`{present:false}`) is a constant stub emitted
  // inside [_computeDayBlocks] (the offloaded second half). If a real
  // AdvancedSleepStager pass is ever re-homed, put it back there so it stays
  // OFF the calling isolate. `detected_workouts` used to be listed here too and
  // is gone — see the note at its old site in [_computeDayBlocks].

  /// Per-5-min movement-level curve over the whole day ([{t, v}], v = fraction
  /// of seconds in the bucket with a ≥5° wrist-orientation change, 0..1). The
  /// honest 1 Hz movement signal (same basis as active-minutes) for the "Your
  /// day" Movement view. Sleep is NOT excluded — the curve naturally dips there.
  static List<Map<String, dynamic>> _activityCurve(Substrate s) {
    final n = s.length;
    if (n < 60) return const [];
    final ang = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      ang[i] = ana.zAngle(s.ax[i], s.ay[i], s.az[i]);
    }
    const bucketSec = 300; // 5 min
    final move = <int, int>{}, tot = <int, int>{};
    for (var i = 1; i < n; i++) {
      // Absent accel is not stillness — see _activeMinutes.
      if (!s.accelPresentAt(i) || !s.accelPresentAt(i - 1)) continue;
      final b = s.tsSec[i] ~/ bucketSec;
      tot[b] = (tot[b] ?? 0) + 1;
      if ((ang[i] - ang[i - 1]).abs() > 5.0) move[b] = (move[b] ?? 0) + 1;
    }
    final out = <Map<String, dynamic>>[];
    final keys = tot.keys.toList()..sort();
    for (final b in keys) {
      out.add({
        't': b * bucketSec,
        'v': double.parse(((move[b] ?? 0) / tot[b]!).toStringAsFixed(3)),
      });
    }
    return out;
  }

  /// On/off-wrist segments over the day from RECORD PRESENCE — the runs,
  /// first/last on, longest off gap, worn minutes + time-coverage.
  ///
  /// Wear is whether a 1 Hz record EXISTS, not whether HR locked. The band logs
  /// to flash only while on-wrist (off-wrist it stops and emits WRIST_OFF), so a
  /// record means worn. The old `hr>0` rule misread normal daytime PPG drop-out
  /// (HR only locks on a still wrist with good optical contact — mostly SLEEP)
  /// as off-wrist, collapsing a 24 h-worn day to ~the sleep window (~7-8 h). Off
  /// periods are now GAPS in the record stream longer than [offGapSec].
  ///
  /// CAVEAT: this assumes the band does NOT keep logging while off-wrist. If a
  /// future firmware streams off-wrist records, add a skin-temp/motion on-body
  /// gate here (the substrate carries accel + skinTemp).
  ///
  /// THE DENOMINATOR IS THE DAY, NOT THE DATA. `coverage_pct` used to divide
  /// worn seconds by `last sample - first sample`, so a band worn 9-11am and
  /// nowhere else reported 100% — and `day_strain` renders that number as the
  /// sentence "The band saw N% of this day", which was then false. The span
  /// between the first and last record cannot answer a question about the day;
  /// only the day can.
  ///
  /// WHICH day, for a day still in progress: the ELAPSED part of it, not all 24
  /// hours. A day that is 40% over must not read as 60% missing — that would
  /// make every morning open on "the band saw 30% of this day" and re-teach the
  /// user to ignore the one number that is supposed to mean something. So the
  /// window is [dayStartSec, min(dataNowSec, dayCalendarEndSec)): for a finished
  /// past day that is the whole local day (23 h / 25 h on the two DST days,
  /// because both bounds come from the day LABEL, never from `+86400`), and for
  /// today it is midnight-to-now.
  ///
  /// [dataNowSec] is the DATA edge, not the wall clock, for the same reason
  /// finalization is: a day whose sync stopped at 14:00 has not been observed
  /// since, and charging the phone against wall-clock time would invent hours of
  /// "not worn" out of hours we simply have not received yet.
  ///
  /// The segments follow the same window. They used to start at the first
  /// record and stop at the last, so the hole from midnight to the first record
  /// was invisible — which would now contradict the coverage number sitting
  /// beside it. Leading and trailing holes are emitted as off-segments, so
  /// `sum(on segments) / observable == coverage_pct` exactly.
  static Map<String, dynamic> _wearBlock(
    Substrate s, {
    required int dayStartSec,
    required int dayCalendarEndSec,
    required int dataNowSec,
    List<List<int>>? runs,
  }) {
    final observableEnd = math.min(
      math.max(dataNowSec, dayStartSec),
      math.max(dayCalendarEndSec, dayStartSec),
    );
    final observableSec = observableEnd - dayStartSec;
    final n = s.length;
    if (n == 0) {
      return {
        'segments': const [],
        'first_on': null,
        'last_on': null,
        'longest_off_min': 0,
        'worn_min': 0,
        // Zero here is a measurement — the day was derived and held no record.
        // Null only when there is no day to divide by at all (an unparseable
        // label), where a percentage would be division by nothing.
        'coverage_pct': observableSec > 0 ? 0 : null,
      };
    }
    const offGapSec = 120; // a >2-min hole in the 1 Hz stream = off / not worn
    final firstOn = s.tsSec.first;
    final lastOn = s.tsSec.last + 1;

    // On-runs first: contiguous stretches of record presence. The off-segments
    // are then everything else inside the observable window, which is what puts
    // the leading/trailing holes on the list.
    // [runs], when given, are these same runs kept up to date by
    // `DayMotionSummary` as seconds are appended.
    if (runs == null) {
      runs = <List<int>>[];
      var runStart = s.tsSec.first;
      var prev = s.tsSec.first;
      for (var i = 1; i < n; i++) {
        final ts = s.tsSec[i];
        if (ts - prev > offGapSec) {
          runs.add([runStart, prev + 1]);
          runStart = ts;
        }
        prev = ts;
      }
      runs.add([runStart, prev + 1]);
    }

    final segments = <Map<String, dynamic>>[];
    var longestOff = 0, wornSec = 0;
    void addOff(int start, int end) {
      if (end <= start) return;
      segments.add({
        'on': false,
        'start': start,
        'end': end,
        'len_min': ((end - start) / 60).round(),
      });
      if (end - start > longestOff) longestOff = end - start;
    }

    var cursor = dayStartSec;
    for (final r in runs) {
      addOff(cursor, r[0]);
      segments.add({
        'on': true,
        'start': r[0],
        'end': r[1],
        'len_min': ((r[1] - r[0]) / 60).round(),
      });
      wornSec += r[1] - r[0];
      cursor = r[1];
    }
    addOff(cursor, observableEnd);

    return {
      'segments': segments,
      'first_on': firstOn,
      'last_on': lastOn,
      'longest_off_min': (longestOff / 60).round(),
      'worn_min': (wornSec / 60).round(),
      // Clamped only against a substrate that reaches outside its own day —
      // production slices `daySub` to the day, so this is a guard, not a
      // correction, and it must never be the thing that makes the number look
      // sane.
      'coverage_pct': observableSec > 0
          ? (100 * wornSec / observableSec).round().clamp(0, 100).toInt()
          : null,
    };
  }

  /// Waking ultradian HRV: RMSSD over 5-min buckets of the DAY's RR that falls
  /// OUTSIDE the sleep window (the daytime autonomic rhythm). Timeline + mean.
  /// All-day rolling-RMSSD curve over the 24/7 RR (epoch-stamped {t,v}), for the
  /// Timeline graph. 5-min sliding window, emitted ~each minute. Inline artifact
  /// gate (plausible RR 300–2000 ms) — daytime RR is noisier/motion-confounded,
  /// so this is a context line, not the nocturnal recovery RMSSD.
  /// Test seam: counts window evaluations, for the same reason as
  /// [debugRespAttempts] — the fix is about how often the O(window) sum runs.
  @visibleForTesting
  static int debugHrvAttempts = 0;

  @visibleForTesting
  static List<Map<String, num>> dayHrvCurve(
    Substrate s, {
    DayCalculationState? state,
    ana.CalculationMode mode = ana.CalculationMode.forced,
  }) {
    final ts = <double>[], rr = <double>[];
    for (var i = 0; i < s.rrMs.length; i++) {
      final v = s.rrMs[i];
      if (v >= 300 && v <= 2000) {
        ts.add(s.rrTsMs[i]);
        rr.add(v);
      }
    }
    if (rr.length < 10) {
      return state == null
          ? const []
          : state.evaluate(
              'hrv_day_empty',
              [ts, rr],
              () => <Map<String, num>>[],
              mode,
            );
    }
    const winMs = 300000.0; // 5 min
    final out = <Map<String, num>>[];
    var lo = 0;
    var lastEmit = -1e18;
    for (var i = 0; i < rr.length; i++) {
      while (ts[i] - ts[lo] > winMs) {
        lo++;
      }
      // Cadence gate FIRST: the sum-of-squared-differences below is O(window),
      // and running it for every beat only to discard the result on the 60 s
      // check was the whole window's work wasted per sample.
      if (i - lo >= 10 && ts[i] - lastEmit > 60000) {
        double? calculate() {
          debugHrvAttempts++;
          var ssd = 0.0;
          var nd = 0;
          for (var k = lo + 1; k <= i; k++) {
            final d = rr[k] - rr[k - 1];
            if (d.abs() > 0.20 * rr[k - 1] || d.abs() > 200) continue;
            ssd += d * d;
            nd++;
          }
          if (nd < 8) return null;
          final rmssd = math.sqrt(ssd / nd);
          return rmssd <= 220 ? double.parse(rmssd.toStringAsFixed(1)) : null;
        }

        final value = state == null
            ? calculate()
            : state.evaluate(
                'hrv_day_${ts[i]}',
                [winMs, ts.sublist(lo, i + 1), rr.sublist(lo, i + 1)],
                calculate,
                mode,
              );
        // Scan cadence and eligibility on every call, including absent windows.
        lastEmit = ts[i];
        if (value != null) out.add({'t': (ts[i] / 1000).round(), 'v': value});
      }
    }
    return out;
  }

  /// The day's RESTING breathing-rate floor (epoch {t,v} br/min) via rolling
  /// RSA on the 24/7 RR. 3-min window emitted ~every 5 min; absent windows (too
  /// few/too noisy beats) are skipped — never fabricated.
  ///
  /// RESP-05 — every window is MOTION-GATED before the estimator runs (see
  /// [_respQuietFraction]). This is not "your breathing rate today" and it is
  /// never a value during activity: RSA amplitude collapses under motion, so a
  /// moving window cannot resolve a breathing rate at all. **Most days produce
  /// nothing, and that is the correct output.**
  ///
  /// Test seam: replaces the RSA estimator, so the ABSENT branch — the one that
  /// used to strand the cadence cursor and re-run a triple Lomb-Scargle per beat
  /// — can be exercised deterministically. It needs a seam because no synthetic
  /// RR reliably makes the real estimator abstain: the behaviour comes from real
  /// movement-confounded daytime data, which is exactly what is hard to fake.
  @visibleForTesting
  static double? Function(List<double> nn, List<double> nnt)?
      debugRespEstimator;

  /// Test seam: counts estimator ATTEMPTS. The cost fix is about how often the
  /// estimator runs, not about what it returns, so the attempt count is the only
  /// thing that actually distinguishes the fixed code from the broken code.
  @visibleForTesting
  static int debugRespAttempts = 0;

  /// Fraction of a candidate resp window's seconds that must be PRESENT AND
  /// STILL before the estimator is allowed to run (RESP-05).
  ///
  /// RSA amplitude collapses under motion and the tachogram's Nyquist falls
  /// with heart rate, so a window with movement in it physically cannot resolve
  /// a normal breathing rate — the estimator does not fail loudly there, it
  /// returns a confident wrong number or abstains at random. 0.9 of 180 s is
  /// 162 still seconds: it tolerates the odd re-orientation and rejects
  /// anything that is a walk. It also subsumes coverage — a second with no
  /// gravity vector cannot be counted still (absence is not stillness), so a
  /// half-observed window fails the same test.
  static const double _respQuietFraction = 0.9;

  /// Test seam: counts windows REJECTED by the stillness gate above.
  @visibleForTesting
  static int debugRespGateRejects = 0;

  @visibleForTesting
  static List<Map<String, num>> dayRespCurve(
    Substrate s, {
    DayCalculationState? state,
    ana.CalculationMode mode = ana.CalculationMode.forced,
  }) {
    // RESP-05 — the gate is per-FAMILY, and an unknown strap gets no cut rather
    // than gen4's (device.dart contract). Refusing the whole curve is the
    // correct output for every pre-schema-41 day and every import: we cannot
    // say those seconds were still, and an ungated daytime RSA number is the
    // thing this item exists to stop publishing.
    final cut = ana.calibrationFor(_quietEnmoCutG, s.deviceFamily);
    if (cut == null) {
      return state == null || debugRespEstimator != null
          ? const []
          : state.evaluate(
              'resp_day_no_family',
              [s.deviceFamily],
              () => <Map<String, num>>[],
              mode,
            );
    }
    // Running count of still seconds, over substrate index. Prefix-summed so a
    // window's stillness is two array reads instead of a rescan.
    final quietPrefix = List<int>.filled(s.length + 1, 0);
    for (var i = 0; i < s.length; i++) {
      var q = 0;
      if (s.accelPresentAt(i)) {
        final mag = math.sqrt(
          s.ax[i] * s.ax[i] + s.ay[i] * s.ay[i] + s.az[i] * s.az[i],
        );
        if ((mag - 1.0).abs() <= cut) q = 1;
      }
      quietPrefix[i + 1] = quietPrefix[i] + q;
    }

    final ts = <double>[], rr = <double>[];
    for (var i = 0; i < s.rrMs.length; i++) {
      final v = s.rrMs[i];
      if (v >= 300 && v <= 2000) {
        ts.add(s.rrTsMs[i]);
        rr.add(v);
      }
    }
    if (rr.length < 60) {
      return state == null || debugRespEstimator != null
          ? const []
          : state.evaluate(
              'resp_day_empty',
              [ts, rr, cut, s.deviceFamily],
              () => <Map<String, num>>[],
              mode,
            );
    }
    const winMs = 180000.0; // 3 min
    final out = <Map<String, num>>[];
    var lo = 0;
    var lastEmit = -1e18;
    // Cursors into s.tsSec for the window bounds. Both `ts[lo]` and `ts[i]` are
    // non-decreasing across the loop, so these only ever move forward.
    var qLo = 0, qHi = 0;
    for (var i = 0; i < rr.length; i++) {
      while (ts[i] - ts[lo] > winMs) {
        lo++;
      }
      if (i - lo >= 30 && ts[i] - lastEmit > 300000) {
        // 5-min cadence
        // STILLNESS GATE, BEFORE the estimator. Rejecting here is also where
        // the perf win lives: the triple Lomb-Scargle never runs on a window
        // that could not have produced a resting rate anyway.
        final loSec = (ts[lo] / 1000).floor();
        final hiSec = (ts[i] / 1000).ceil();
        while (qLo < s.length && s.tsSec[qLo] < loSec) {
          qLo++;
        }
        if (qHi < qLo) qHi = qLo;
        while (qHi < s.length && s.tsSec[qHi] < hiSec) {
          qHi++;
        }
        final spanSec = hiSec - loSec;
        final stillSec = quietPrefix[qHi] - quietPrefix[qLo];
        final nn = rr.sublist(lo, i + 1);
        final t0 = ts[lo];
        final nnt = [for (var k = lo; k <= i; k++) ts[k] - t0];
        final seam = debugRespEstimator;
        double? calculate() {
          if (spanSec <= 0 || stillSec < _respQuietFraction * spanSec) {
            debugRespGateRejects++;
            return null;
          }
          debugRespAttempts++;
          if (seam != null) return seam(nn, nnt);
          final est = ana.rsaRespRate(nn, nnt, artifactFraction: 0.15);
          return est.present ? est.value!.brpm : null;
        }

        // An injected estimator can carry mutable state. Never reuse its output.
        final brpm = state == null || seam != null
            ? calculate()
            : state.evaluate(
                'resp_day_${ts[i]}',
                [
                  nn,
                  ts.sublist(lo, i + 1),
                  winMs,
                  s.deviceFamily,
                  cut,
                  _respQuietFraction,
                  spanSec,
                  s.tsSec.sublist(qLo, qHi),
                  s.ax.sublist(qLo, qHi),
                  s.ay.sublist(qLo, qHi),
                  s.az.sublist(qLo, qHi),
                ],
                calculate,
                mode,
              );
        // Advance the cadence cursor on every ATTEMPT, not just on a successful
        // estimate. Daytime RSA is movement-confounded (see above), so absent is
        // the common case — and while lastEmit sat inside the success branch a
        // confounded stretch re-ran the triple Lomb-Scargle once per BEAT
        // instead of once per 5 min. That is what blew the day-blocks budget.
        lastEmit = ts[i];
        if (brpm != null) {
          out.add({
            't': (ts[i] / 1000).round(),
            'v': double.parse(brpm.toStringAsFixed(1)),
          });
        }
      }
    }
    return out;
  }

  /// All-day RELATIVE skin-temperature trend (epoch {t,v}). Per-5-min mean ADC
  /// expressed as a delta from the day's median — RELATIVE only, no absolute °C
  /// (the band has no calibrated temperature). A slow context line.
  static List<Map<String, num>> _daySkinTempCurve(Substrate s) {
    final bins = <int, List<double>>{};
    for (var i = 0; i < s.skinTemp.length && i < s.tsSec.length; i++) {
      final v = s.skinTemp[i];
      if (v > 0) (bins[s.tsSec[i] ~/ 300] ??= []).add(v.toDouble());
    }
    if (bins.length < 3) return const [];
    final keys = bins.keys.toList()..sort();
    final means = {
      for (final k in keys)
        k: bins[k]!.reduce((a, b) => a + b) / bins[k]!.length,
    };
    final sorted = means.values.toList()..sort();
    final med = sorted[sorted.length ~/ 2];
    return [
      for (final k in keys)
        {'t': k * 300, 'v': double.parse((means[k]! - med).toStringAsFixed(1))},
    ];
  }

  /// Quiet-second ENMO cut (g), per sensor package.
  ///
  /// ENMO here is `||a|| − 1 g` — the same amplitude index `restlessness_map`
  /// and `enmoSeries` use. A sedentary/still wrist sits at ~0.01-0.02 g and
  /// walking at ~0.066 g, so 0.02 g separates sitting from moving without
  /// pretending to separate postures. Listed per family because the cut is only
  /// meaningful against that family's accel scale; an unknown strap gets no cut
  /// and the whole block refuses.
  /// On-chip step counters whose BEHAVIOUR we have established, by the family
  /// stamped on the row: the modulus it wraps at, and — the part that actually
  /// matters — that it is cumulative and does NOT reset at midnight. Both are
  /// verified for gen5 (see `Substrate.stepCount`). A stamp that is not a key
  /// here, including no stamp at all, gets no band-step number: summing deltas
  /// off a resetting counter loses the day's whole pre-sync prefix, and it
  /// cannot be told apart from a wrap afterwards. See
  /// [hardwareStepsFromCounter].
  ///
  /// gen4 has no counter and is deliberately absent.
  static const Map<String, int> _stepCounterModulus = {'gen5': 65536};

  /// The wrap of [family]'s step counter, or null when it has none.
  static int? _stepModulusFor(String? family) =>
      ana.calibrationFor(_stepCounterModulus, family);

  static const Map<String, double> _quietEnmoCutG = {
    'gen4': 0.02,
    'gen5': 0.02,
  };

  @visibleForTesting
  static Map<String, dynamic> daytimeHrv(
          Substrate s, int onsetSec, int offsetSec) =>
      _daytimeHrv(s, onsetSec, offsetSec);

  /// Daytime HRV, MOTION-GATED. The gate is the feature, not a refinement: an
  /// RR series filtered only on plausibility lets a bin of walking into the
  /// average as low HRV, and the number then reads as stress when it is
  /// posture. Only beats whose own second was still — a real gravity vector,
  /// ENMO under the family's quiet cut — are paired.
  ///
  /// Absent accel is NOT stillness (see [Substrate.accelPresentAt]), and an
  /// unknown device family has no cut we can stand behind. Both refuse.
  ///
  /// THIS IS ONE RELABEL AWAY FROM A BODY BATTERY, AND IT MUST NOT TAKE THE
  /// STEP. quiet windows described as variability is the honest residue; a
  /// continuous all-day stress score or a depleting battery icon built on this
  /// series is refused, and the pressure to relabel will arrive from outside
  /// the code rather than from anything here. two independent reasons:
  ///   * the signal. wrist PPG beat timing collapses under motion without
  ///     aggressive quality gating — which is why this function gates at all —
  ///     so the waking hours a stress score would describe are exactly the
  ///     hours its input is worst. gen4 has no per-beat quality flag at all.
  ///     CORRECTION, schema 43: gen5's `signalQualityLogVariance` is no longer
  ///     dropped — it is decoded, mapped and written to
  ///     `decoded_onehz.signal_quality_logvar`, and this comment claimed
  ///     otherwise for three schema versions. It is still not READ (it is in
  ///     neither substrate column list), and wiring it would not rescue a
  ///     stress score: it exists on gen5/MG only, so gating on it means the
  ///     same night measured by two straps answers differently — which is the
  ///     one thing a metric that enters a cross-device baseline may never do.
  ///     A gen5-only within-night RANK or WEIGHT is defensible; a percentage,
  ///     a bar, or anything a gen4 user could compare against is not, because
  ///     the scale is the band's own with no units and no calibration.
  ///   * the construct. the systematic evaluation of 14 vendor composite
  ///     scores found NONE with independent peer-reviewed validation. the
  ///     inputs validate; the composite does not, and a depleting battery
  ///     invents a physiological quantity that does not exist — which teaches
  ///     the user to distrust a real body for disagreeing with a made-up one.
  /// so: no score, no 0-100, no battery, no gauge, no "current stress". a
  /// timeline of RMSSD over still minutes, labelled as variability, is the
  /// whole allowed surface.
  static Map<String, dynamic> _daytimeHrv(Substrate s, int onsetSec, int offsetSec,
      {int tonightSleepOnsetSec = 0}) {
    const binSec = 300;
    final cut = ana.calibrationFor(_quietEnmoCutG, s.deviceFamily);
    if (cut == null) {
      return {
        'timeline': const <Map<String, dynamic>>[],
        'mean_rmssd': null,
        'n_buckets': 0,
        'note': ana.unknownFamilyNote(s.deviceFamily),
      };
    }
    // The seconds we can call still. Built once over the day substrate; a
    // second with no gravity vector never lands here, so it can only break a
    // pair, never join one.
    final quiet = <int>{};
    for (var i = 0; i < s.length; i++) {
      if (!s.accelPresentAt(i)) continue;
      final mag = math.sqrt(
          s.ax[i] * s.ax[i] + s.ay[i] * s.ay[i] + s.az[i] * s.az[i]);
      if ((mag - 1.0).abs() <= cut) quiet.add(s.tsSec[i]);
    }
    final bins = <int, List<double>>{};
    double? prev;
    for (var k = 0; k < s.rrMs.length; k++) {
      final tSec = s.rrTsMs[k] ~/ 1000;
      if ((offsetSec > onsetSec && tSec >= onsetSec && tSec < offsetSec) ||
          (tonightSleepOnsetSec > 0 && tSec >= tonightSleepOnsetSec)) {
        prev = null;
        continue; // skip the sleep window (and tonight's, begun before midnight)
      }
      if (!quiet.contains(tSec)) {
        prev = null; // moving, or no accel to say otherwise — break the pair
        continue;
      }
      final v = s.rrMs[k];
      if (v < 300 || v > 2000) {
        prev = null;
        continue;
      }
      if (prev != null) {
        final d = v - prev;
        if (d.abs() <= 200) (bins[tSec ~/ binSec] ??= <double>[]).add(d * d);
      }
      prev = v;
    }
    final timeline = <Map<String, dynamic>>[];
    final means = <double>[];
    final keys = bins.keys.toList()..sort();
    for (final b in keys) {
      final sq = bins[b]!;
      if (sq.length < 5) continue;
      final rmssd = math.sqrt(sq.reduce((a, c) => a + c) / sq.length);
      // `n` is how many quiet beat-pairs this bin is built from — an hour built
      // from three of them is not a reading and the card has to be able to say
      // so (or drop the hour).
      timeline.add({
        't': b * binSec,
        'rmssd': (rmssd * 10).round() / 10.0,
        'n': sq.length,
      });
      means.add(rmssd);
    }
    final mean = means.isEmpty
        ? null
        : means.reduce((a, c) => a + c) / means.length;
    return {
      'timeline': timeline,
      'mean_rmssd': mean == null ? null : (mean * 10).round() / 10.0,
      'n_buckets': timeline.length,
    };
  }

  /// Nocturnal restlessness from sleep-window orientation change: minutes with
  /// movement, number of distinct movement bouts, longest still stretch (min).
  static Map<String, dynamic> _restlessness(Substrate s) {
    final n = s.length;
    if (n < 60) {
      return {
        'restless_min': null,
        'movement_bouts': null,
        'longest_still_min': null,
      };
    }
    const moveDeg = 5.0;
    final byMinMove = <int, int>{}, byMinTot = <int, int>{};
    for (var i = 1; i < n; i++) {
      // Absent accel is not stillness — see _activeMinutes.
      if (!s.accelPresentAt(i) || !s.accelPresentAt(i - 1)) continue;
      final m = s.tsSec[i] ~/ 60;
      byMinTot[m] = (byMinTot[m] ?? 0) + 1;
      final d =
          (ana.zAngle(s.ax[i], s.ay[i], s.az[i]) -
                  ana.zAngle(s.ax[i - 1], s.ay[i - 1], s.az[i - 1]))
              .abs();
      if (d > moveDeg) byMinMove[m] = (byMinMove[m] ?? 0) + 1;
    }
    final keys = byMinTot.keys.toList()..sort();
    // Nothing countable — a night whose records carry no gravity vector clears
    // the `n < 60` gate above and then skips every second, and returning the
    // zeros below claims a perfectly still, unbroken night measured from
    // nothing. Same answer as the thin-data branch: absent.
    if (keys.isEmpty) {
      return {
        'restless_min': null,
        'movement_bouts': null,
        'longest_still_min': null,
      };
    }
    var restless = 0, bouts = 0, longestStill = 0, curStill = 0;
    var prevMoved = false;
    for (final m in keys) {
      final moved = (byMinMove[m] ?? 0) / (byMinTot[m] ?? 1) >= 0.20;
      if (moved) {
        restless++;
        if (!prevMoved) bouts++;
        curStill = 0;
      } else {
        curStill++;
        if (curStill > longestStill) longestStill = curStill;
      }
      prevMoved = moved;
    }
    return {
      'restless_min': restless,
      'movement_bouts': bouts,
      'longest_still_min': longestStill,
    };
  }

  /// Sleep periods: the main sleep plus the naps [_attachNaps] already found.
  ///
  /// This used to run its OWN nap detector — 20-min runs of still, on-wrist
  /// minutes — in parallel with `detectNaps`. Two detectors, two answers, two
  /// screens: `payload.json` shipped a 21-minute period here on the very day
  /// `naps` reported `count: 0`. One source per concern (AGENTS §3.8), so the
  /// naps are now passed in rather than re-derived.
  ///
  /// Every period speaks the SAME contract the Sleep-periods screen reads
  /// (`onset_ts`/`wake_ts`/`duration_min`/`efficiency`/`confidence`), and
  /// `duration_min` is minutes ASLEEP for both the main sleep and naps — they
  /// were previously different units under one label, then summed.
  ///
  /// [naps] is NULL when the nap detector could not judge the day at all (as
  /// opposed to an empty list, which means "judged, and there were none"). An
  /// unjudged day has an unknown NUMBER of periods, not just unknown durations,
  /// so the total is unknown for exactly the same reason a null `duration_min`
  /// makes it unknown — and `nap_min` is already left unwritten in that case.
  /// Publishing `total_asleep_min = mainTstMin` there would state a complete
  /// day total while `naps.value` is null, which is internally inconsistent.
  /// The strap's own CHARGING_ON/OFF spans that fall INSIDE the scored sleep
  /// window — published as a caveat on the night, never as a reason to drop it.
  ///
  /// Why `wear` cannot see this: a battery-pack swap is not a wrist-off event.
  /// The pack clips onto the strap while the strap stays on the wrist, so the
  /// band keeps logging 1 Hz records the whole time and every wear signal we
  /// have — record presence, and the band's own WRIST_ON/OFF, which `wear`
  /// matches to the minute — correctly says "worn". Measured on a real 9-day
  /// export, 2 of 9 nights contained CHARGING_ON + BATTERY_PACK_CONNECTED +
  /// BATTERY_PACK_REMOVED inside the sleep window and were scored, staged and
  /// fed into baselines with nothing attached.
  ///
  /// NO CONFIDENCE PENALTY, deliberately. A confidence number here is a claim
  /// about how well we measured THIS NIGHT'S SLEEP, and the mechanism does not
  /// support that claim: the band is on the wrist, the PPG is against skin, and
  /// beat timing — which is what the stager and every HRV metric actually run
  /// on — has no pathway to degrade because a battery is sitting on the strap.
  /// Multiplying the night's confidence down would be inventing a measured
  /// degradation to express a suspicion, which is the same fabrication as any
  /// other confident wrong number, only pointing the safe way. What the
  /// mechanism DOES support is named in the note and left to the reader:
  ///   * SKIN TEMPERATURE. A charging pack is a heat source bonded to the strap
  ///     and the channel is relative-ADC with no absolute reference, so this
  ///     night's skin temp is not comparable to a night without one. That is a
  ///     per-CHANNEL caveat, and the honest fix is to withhold the night from
  ///     the skin-temp baseline rather than to fuzz the whole night's sleep —
  ///     which is a baseline-layer change, not this one.
  ///   * A MOTION BURST at each end. Clipping and unclipping the pack is a hand
  ///     movement on the instrumented wrist, so the stager will read wake there.
  ///     It is bounded, it is at a known timestamp, and it is real movement, so
  ///     it is reported rather than smoothed away.
  @visibleForTesting
  static Map<String, dynamic> sleepChargingBlock(
    List<List<int>> chargingSpans,
    int onsetSec,
    int offsetSec,
  ) {
    if (offsetSec <= onsetSec) return const {'present': false};
    final spans = <List<int>>[];
    var sec = 0;
    for (final c in chargingSpans) {
      if (c.length < 2) continue;
      final lo = math.max(c[0], onsetSec);
      final hi = math.min(c[1], offsetSec);
      if (hi <= lo) continue;
      spans.add([lo, hi]);
      sec += hi - lo;
    }
    if (spans.isEmpty) return const {'present': false};
    return {
      'present': true,
      'minutes': (sec / 60).round(),
      'spans': spans,
      'note':
          'The strap charged for part of this night. It stayed on your wrist and kept recording, '
          'so heart rate and beat timing are measured as usual. '
          'The charge pack warms the strap, so this night\'s skin temperature does not compare with nights without it. '
          'Clipping the pack on and off registers as wrist movement.',
    };
  }

  static Map<String, dynamic> _sleepPeriods(
    int onsetSec,
    int offsetSec,
    List<Map<String, dynamic>>? naps, {
    int? mainTstMin,
    double? mainEfficiency,
  }) {
    final periods = <Map<String, dynamic>>[];
    // Null-if-any-component-unknown. Summing a null duration as 0 would print a
    // confident total that is short by exactly the part we could not measure —
    // and the hero tile divides it by need, so the "% of need" arc understates
    // too. An unknown component makes the SUM unknown.
    var totalAsleep = 0;
    var totalKnown = true;
    if (offsetSec > onsetSec) {
      periods.add({
        'is_main': true,
        'onset_ts': onsetSec,
        'wake_ts': offsetSec,
        // Null when staging did not produce a TST. The screen renders "—";
        // substituting the in-bed span would silently relabel time in bed as
        // time asleep, which is the same conflation this change removes.
        'duration_min': mainTstMin,
        'in_bed_min': (offsetSec - onsetSec) ~/ 60,
        'efficiency': ?mainEfficiency,
        // No hypnogram here on purpose: it lives in the isolate-1 bundle's
        // `series.hypnogram`, which this isolate does not receive. The read
        // seam attaches it (see `_daySleep`), where the whole bundle is in
        // hand. Passing it from here would only ever have written null.
      });
      if (mainTstMin != null) {
        totalAsleep += mainTstMin;
      } else {
        totalKnown = false;
      }
    }
    if (naps == null) {
      // Not judged. The day may hold any number of unmeasured naps, so no
      // total can be stated — the screen renders "—" rather than a confident
      // figure that silently omits them.
      totalKnown = false;
    } else {
      for (final nap in naps) {
        periods.add(nap);
        final d = (nap['duration_min'] as num?)?.toInt();
        if (d != null) {
          totalAsleep += d;
        } else {
          totalKnown = false;
        }
      }
    }
    return {
      'periods': periods,
      'total_asleep_min': totalKnown ? totalAsleep : null,
    };
  }

  /// Daytime naps via the analytics `detectNaps` — the ONLY nap source.
  ///
  /// Writes the `naps` block (per-nap epoch bounds + TST/TIB + confidence) and
  /// the `nap_min` scalar (total minutes ASLEEP) used by the Sleep Coach and
  /// Timeline, and returns period maps for [_sleepPeriods] so the Sleep-periods
  /// screen lists exactly the same naps the Timeline draws. There used to be a
  /// second, coarser nap notion in `_sleepPeriods` built from 20-min stillness
  /// runs; the two disagreed on real days (`payload.json` shipped a 21-min
  /// period alongside `naps.count: 0`) and fed two different screens.
  ///
  /// ABSENT is not ZERO. When the detector cannot judge the day, `nap_min` is
  /// left UNWRITTEN rather than set to 0 — a written 0 is a claim that there
  /// were no naps, and it would also be picked up as a real value downstream.
  /// Returns NULL for that unjudged case and a (possibly empty) list when the
  /// day really was judged, so [_sleepPeriods] can make the same distinction
  /// instead of reading "no naps returned" as "no naps happened".
  /// The explicit "nap assessment unknown" envelope.
  ///
  /// Every abstention path must publish this, not just the detector's own
  /// `!m.present` branch. `_computeDayBlocks` starts from an EMPTY bundlePatch
  /// and `_attachNaps` is the only writer of `naps`, so a path that returns
  /// without writing leaves the key missing entirely — and "key absent" and
  /// "judged, value null" are then two different encodings of the same fact,
  /// distinguishable only by HOW the abstention happened. A reader that checks
  /// `bundle['naps']?['value'] == null` and one that checks
  /// `bundle.containsKey('naps')` would disagree.
  /// Abstention path that still honours what the USER logged.
  ///
  /// The detector abstains on exactly the days this feature exists for — strap
  /// off for part of the afternoon, a short record, a failure. Returning early
  /// there dropped every logged nap on the floor: no card to see, no minutes
  /// credited, and no way to delete the row the user had just created, while
  /// the edit kept force-re-deriving that day forever.
  ///
  /// A logged nap needs nothing from the detector — it carries its own absolute
  /// bounds — so it is published on its own. The day is still reported as
  /// unjudged when the user logged nothing, because that is what it is.
  static List<Map<String, dynamic>>? _napsWhenUnjudged(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    List<NapEdit> napEdits,
    String note,
  ) {
    final merged = applyNapEdits(const [], napEdits);
    if (merged.isEmpty) {
      _writeUnknownNaps(bundle, note);
      return null;
    }
    bundle['naps'] = <String, dynamic>{
      'value': merged,
      'count': merged.length,
      // No detection confidence, because there was no detection.
      'confidence': null,
      // AUTH is the closed vocabulary's "directly measured / definitional",
      // which is what a self-report is: the user is not estimating that they
      // napped, they are stating it. An invented fifth tier would be a string
      // no reader knows how to rank.
      'tier': ana.Tier.auth,
      'inputs_used': const ['user'],
      'note': '$note. Showing what you logged.',
      'assessment_complete': false,
    };
    scMap?['nap_min'] = napMinutes(merged).toDouble();
    return [
      for (final nap in merged)
        {
          'is_main': false,
          'onset_ts': nap['start'],
          'wake_ts': nap['end'],
          'duration_min': nap['duration_min'],
          'in_bed_min': nap['in_bed_min'],
          'efficiency': null,
          'confidence': null,
          if (nap['source'] != null) 'source': nap['source'],
        },
    ];
  }

  static void _writeUnknownNaps(
    Map<String, dynamic> bundle,
    String note,
  ) {
    bundle['naps'] = <String, dynamic>{
      'value': null,
      'count': null,
      'confidence': 0,
      'tier': 'ESTIMATE',
      'inputs_used': const <String>[],
      'note': note,
      'assessment_complete': false,
    };
  }

  static List<Map<String, dynamic>>? _attachNaps(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate s,
    int onsetSec,
    int offsetSec, {
    int? attributionStartSec,
    int? attributionEndSec,
    List<List<int>> wristOff = const [],
    List<List<int>> charging = const [],
    // Read on the main isolate and carried in, like every other DB-sourced
    // input here — this runs inside the compute worker, which has no database.
    List<NapEdit> napEdits = const [],
    List<Map<String, dynamic>>? candidates,
    // Where the main-sleep exclusion ENDS — the night's UNTRIMMED end when the
    // band cut the auto window short (`sleep.band_offset_trim_sec`), so the
    // lie-in the band rule removed from the night cannot be reclaimed as a
    // nap. Null = [offsetSec].
    int? napExcludeEndSec,
    int tonightSleepOnsetSec = 0,
    int tonightSleepOffsetSec = 0,
    List<List<int>> blanked = const [],
  }) {
    try {
      final n = s.length;
      if (n < 60) {
        return _napsWhenUnjudged(
          bundle,
          scMap,
          napEdits,
          'too little 1 Hz data to assess naps',
        );
      }
      final accel = <ana.AccelSample>[
        for (var i = 0; i < n; i++)
          ana.AccelSample(s.tsSec[i] * 1000.0, s.ax[i], s.ay[i], s.az[i],
              valid: s.accelPresentAt(i)),
      ];
      final hr = [for (final h in s.hr) h.toDouble()];
      // Map the main-sleep epoch-second window to indices into the day arrays.
      ana.SleepWindowSpan? main;
      final excludeEndSec = napExcludeEndSec ?? offsetSec;
      if (excludeEndSec > onsetSec) {
        var lo = -1, hi = -1;
        for (var i = 0; i < n; i++) {
          if (lo < 0 && s.tsSec[i] >= onsetSec) lo = i;
          if (s.tsSec[i] < excludeEndSec) hi = i + 1;
        }
        if (lo >= 0 && hi > lo) main = ana.SleepWindowSpan(lo, hi);
      }
      final m = ana.detectNaps(
        accel,
        hr,
        mainSleep: main,
        wristOff: wristOff,
        exclude: [...charging, ...blanked],
      );

      if (!m.present) {
        return _napsWhenUnjudged(
          bundle,
          scMap,
          napEdits,
          m.note ?? 'naps could not be assessed for this day',
        );
      }

      final t0 = s.tsSec.first;
      // The window opens AT local midnight and is contiguous into it, so a
      // bout [NapWindow.startsAtRecordEdge] flags — already in progress when
      // we started looking — is the tail of something that started
      // YESTERDAY, and yesterday's buffered window (which runs
      // `napBoundaryBufferSec` past its own midnight) saw it whole and
      // emitted it whole.
      //
      // analytics#40 (closing edge#204's workaround): this used to be
      // guessed from `nap.startSec == 0`, which only ever caught the FIRST
      // bout of the window — a bout chained onto it within `napChainGapSec`
      // (a brief arousal right at midnight) has `startSec > 0` but is just as
      // edge-anchored, and the old check let it through uncounted. Analytics
      // now propagates the flag through the whole chain (nap.dart), so
      // testing it directly instead of re-deriving it from the index catches
      // those fragments too.
      //
      // Still gated on contiguity, NOT on the flag alone: if the record only
      // STARTS hours into the day (band off overnight), yesterday's detector
      // broke on that same discontinuity and dropped the bout too, so
      // dropping it here as well would lose a real nap rather than
      // de-duplicate one.
      final leadingEdgeOwnedByYesterday = attributionStartSec != null &&
          t0 <= attributionStartSec + napLeadingEdgeContiguitySec;
      // A nap STARTING at/after the real day boundary is tomorrow's — its own
      // (unbuffered) window finds it independently, so keeping it here too
      // would double-count it.
      final naps = m.value!.where((nap) {
        if (leadingEdgeOwnedByYesterday && nap.startsAtRecordEdge) {
          return false;
        }
        // Tonight's sleep, begun before midnight, is TOMORROW's main sleep.
        // A night that ends inside the buffer (up at 02:00) is not deferred as
        // unfinished, so without this it was booked here as a nap too.
        if (tonightSleepOffsetSec > tonightSleepOnsetSec &&
            t0 + nap.startSec < tonightSleepOffsetSec &&
            t0 + nap.endSec > tonightSleepOnsetSec) {
          return false;
        }
        if (attributionEndSec == null) return true;
        return t0 + nap.startSec < attributionEndSec;
      }).toList();

      // The detector's answer is a PROPOSAL. The user's edits — a nap it
      // missed, or one it invented — are stored separately and replayed over
      // it here on every derivation, so a better detector later still respects
      // "there was no nap here" instead of the edit being baked into a stale
      // detection.
      final detected = <Map<String, dynamic>>[
        for (final nap in naps)
          {
            'start': t0 + nap.startSec,
            'end': t0 + nap.endSec,
            // Minutes ASLEEP. `duration_min` kept as the asleep figure so
            // existing readers do not silently switch to in-bed minutes.
            'duration_min': (nap.tstSec / 60).round(),
            'in_bed_min': (nap.tibSec / 60).round(),
            'efficiency': nap.efficiency,
            'confidence': nap.confidence,
          },
      ];
      candidates?.addAll(detected.where((n) => !napEdits.any((e) =>
        e.overlaps(n['start'] as int, n['end'] as int))));
      final merged = applyNapEdits(const [], napEdits);

      bundle['naps'] = <String, dynamic>{
        'value': merged,
        'count': merged.length,
        'confidence': m.confidence,
        'tier': m.tier,
        'inputs_used': m.inputs_used,
        'note': napEdits.isEmpty ? m.note : '${m.note} (edited)',
        'assessment_complete': true,
      };

      // TST, never TIB. Crediting in-bed minutes against sleep need
      // over-credits every nap by its awake time and always errs toward
      // recommending LESS sleep than the user needs.
      // Rounded, matching the two display paths exactly. Truncating here while
      // the cards round made the credit disagree with the sum of the minutes
      // shown — up to a minute per nap, in a number the user can add up.
      // Summed over the MERGED list, so a logged nap counts toward sleep need
      // and sleep debt exactly as a detected one does.
      scMap?['nap_min'] = napMinutes(merged).toDouble();

      return [
        for (final nap in merged)
          {
            'is_main': false,
            'onset_ts': nap['start'],
            'wake_ts': nap['end'],
            'duration_min': nap['duration_min'],
            'in_bed_min': nap['in_bed_min'],
            'efficiency': nap['efficiency'],
            'confidence': nap['confidence'],
            if (nap['source'] != null) 'source': nap['source'],
          },
      ];
    } catch (e) {
      if (kDebugMode) debugPrint('[derive] naps FAILED/skipped: $e');
      return _napsWhenUnjudged(
        bundle,
        scMap,
        napEdits,
        'nap detection failed for this day',
      );
    }
  }

  /// Runs [_computeDayBlocks] in an explicitly spawned, killable isolate and
  /// enforces [timeout] on the isolate itself — not just on the caller's wait.
  ///
  /// `Isolate.run(...).timeout(...)` (the previous approach) only stops the
  /// CALLER from awaiting the result; the spawned isolate keeps executing to
  /// completion in the background regardless. Under a multi-day backlog with
  /// a bounded worker pool ([_deriveConcurrency]), a slow/hung day's abandoned
  /// isolate can keep burning CPU well after its caller moved on to the next
  /// day — silently exceeding the intended concurrency budget. Spawning the
  /// isolate ourselves gives us a handle to actually `kill()` it on timeout.
  static Future<_DayBlocksOutput> _runDayBlocksCancellable(
    _DayBlocksInput input,
    Duration timeout,
  ) async {
    final port = ReceivePort();
    final dispatchId = WorkerAudit.dispatched(Dispatcher.spawn, 'day blocks');
    final isolate = await Isolate.spawn(
      _dayBlocksIsolateEntry,
      // The third and fourth elements are the test-only audit port (null in
      // production) and this dispatch's id.
      (port.sendPort, input, WorkerAudit.auditPort, dispatchId),
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    final completer = Completer<_DayBlocksOutput>();
    late final StreamSubscription<dynamic> sub;
    sub = port.listen((message) {
      if (completer.isCompleted) return;
      if (message is _DayBlocksOutput) {
        completer.complete(message);
      } else if (message is List) {
        // Either our own caught-exception report (`[error, stack]`) or the
        // `onError` port's uncaught-error format — both are 2-element lists
        // of strings. `onExit` fires with `null`, which we treat as "the
        // isolate ended without ever sending a result" below.
        completer.completeError(
          StateError(
            message.isNotEmpty
                ? 'day-blocks isolate failed: ${message.first}'
                : 'day-blocks isolate failed with no error detail',
          ),
        );
      } else if (message == null) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('day-blocks isolate exited without a result'),
          );
        }
      }
    });
    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          isolate.kill(priority: Isolate.immediate);
          throw TimeoutException(
            'day-blocks computation timed out after $timeout',
          );
        },
      );
    } finally {
      await sub.cancel();
      port.close();
      // No-op if the isolate already exited normally; guarantees a hung or
      // still-running isolate never outlives this call.
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// A fully populated [_DayBlocksInput] for the entry's sendability test
  /// (test/guards/support/entry_samples.dart): every nested kind the production
  /// argument carries — substrates with typed beats, the calculation state,
  /// records in [_DayBlocksInput.ceilingReuse], [NapEdit]s, span lists, saved
  /// session rows and the streamed day figures. Typed `Object` because the
  /// class is library-private.
  @visibleForTesting
  static Object dayBlocksInputForTest({
    required Substrate daySub,
    required String date,
    required int dayStartSec,
  }) =>
      _DayBlocksInput(
        calculationState: DayCalculationState(),
        calculationMode: ana.CalculationMode.forced,
        streamed: const DayTailResult(
          irregular: {'flag': false, 'n': 0},
          hrv: [
            {'t': 1760000600, 'rmssd': 41.5}
          ],
          resp: [
            {'t': 1760000600, 'rate': 14.0}
          ],
          daytime: {'rmssd': 38.0},
          tailRr: [812.0, 798.0],
          tailTs: [1760000598.0, 1760000599.0],
        ),
        ceilingReuse: {
          's1': (json: {'bpm': 181.0, 'n': 3}, bpm: 181.0),
          's2': (json: {'bpm': null}, bpm: null),
        },
        daySub: daySub,
        napSub: daySub,
        sleepSub: Substrate.empty,
        profile: const Profile(ageYears: 35, weightKg: 70, sex: 'm'),
        onsetSec: dayStartSec + 300,
        offsetSec: dayStartSec + 1500,
        rhr: 52.0,
        maxHrUsed: 188,
        liveStepsReal: 1234,
        liveStepsFromStrap: 1200,
        stepSpans: const [
          [1760000000, 1760000060, 80]
        ],
        dynFloorG: 0.02,
        dynHistoryDays: 9,
        savedSessions: [
          {
            'id': 's1',
            'start_ts': dayStartSec + 600,
            'end_ts': dayStartSec + 1200,
            'type': 'run',
            'status': 'done',
            'source': 'manual',
            'private': 0,
            'created_at': dayStartSec,
          }
        ],
        napEdits: const [
          NapEdit(
            kind: NapEditKind.added,
            startSec: 1760000900,
            endSec: 1760001200,
          ),
        ],
        wristOffSpans: const [
          [1760000100, 1760000160]
        ],
        chargingSpans: const [
          [1760000200, 1760000260]
        ],
        blankedSpans: const [
          [1760000300, 1760000360]
        ],
        mainTstMin: 420,
        mainEfficiency: 0.91,
        date: date,
        dayStartSec: dayStartSec,
        dayEndSec: dayStartSec + 86400,
        dataNowSec: dayStartSec + 1800,
      );

  /// A short digest of the fields [dayBlocksInputForTest] populates, for the
  /// round-trip projection (the class is private).
  @visibleForTesting
  static String dayBlocksInputSummaryForTest(Object input) {
    final i = input as _DayBlocksInput;
    return 'date: ${i.date}, ceilingReuse: ${i.ceilingReuse.length} '
        '${i.ceilingReuse['s1']?.bpm}, napEdits: ${i.napEdits.length} '
        '${i.napEdits.first.startSec}, daySub: ${i.daySub.tsSec.length} '
        '${i.daySub.rrMs.length}, streamed: ${i.streamed?.tailRr}, '
        'spans: ${i.stepSpans}/${i.wristOffSpans}, sessions: '
        '${i.savedSessions.map((s) => s['id'])}, rhr: ${i.rhr}';
  }

  /// Runs [input] through the REAL spawn path ([_runDayBlocksCancellable] →
  /// [_dayBlocksIsolateEntry]) and returns the [_DayBlocksOutput].
  @visibleForTesting
  static Future<Object> runDayBlocksForTest(Object input) =>
      _runDayBlocksCancellable(
          input as _DayBlocksInput, const Duration(minutes: 2));

  /// Run [compute] in an explicitly spawned isolate and enforce [timeout] ON THE
  /// ISOLATE — the general-purpose form of [_runDayBlocksCancellable].
  ///
  /// `Isolate.run(...).timeout(...)` only stops the CALLER awaiting; the spawned
  /// isolate keeps burning CPU to completion in the background. With a bounded
  /// per-day worker pool that silently blows the concurrency budget during a
  /// backlog sweep — which is exactly why [_runDayBlocksCancellable] exists, and
  /// it had been applied to only one of the file's isolate sites. Worse, some
  /// sites (the sleep-staging pass) had NO timeout at all, so a hung isolate
  /// wedged the engine with `_running == true` forever.
  ///
  /// Also wires `onError`/`onExit` so an uncaught throw or a silent death
  /// FAILS the future instead of hanging it.
  static Future<({Map<String, dynamic> bundle, DayCalculationState state})>
      _runDayBundleCancellable(Map<String, dynamic> input,
        DayCalculationState? previous, ana.CalculationMode mode, Duration timeout,
        {required String label}) => _runIsolateCancellable(() {
          final state = previous ?? DayCalculationState();
          final bundle = deriveDayBundle(input, state: state, mode: mode);
          return (bundle: bundle, state: state);
        }, timeout, label: label);

  /// The profile as the text the day fingerprints hash: a few dozen settings,
  /// not stored data.
  static String _profileSignature(Profile profile) =>
      jsonEncode(profile.toMap());

  /// The plain inputs every registered entry carries. The staging and audit
  /// entries read none of zone or locale (they re-arm only the analytics
  /// ambient globals); the clock is the one instant they may need.
  static WorkerInputs _workerInputs() => WorkerInputs(
        nowEpochMs: DateTime.now().millisecondsSinceEpoch,
        zoneId: 'UTC',
        localeTag: 'en',
      );

  /// The batch reference of the finalization audit: [auditBatchDay] with no
  /// calculation state, cancellable like every other per-day worker.
  Future<({Map<String, dynamic> bundle, DayCalculationState state})>
      _runAuditBatch(Map<String, dynamic> input, String date) {
    final inputs = _workerInputs();
    return _runIsolateCancellable(
      () => auditBatchDay(
          inputs, AuditBatchInput(input), ana.CalculationMode.forced),
      _perDayTimeout,
      label: 'audit-batch $date',
    ).then((r) => (bundle: r.bundle, state: DayCalculationState()));
  }

  /// The cross-day rollup rebuilt over the stored inputs [raw] (the
  /// `crossday_input` baseline JSON) up to [date], for `crossDayAsOf`
  /// (compute/inputs/canonical.dart). Empty when the inputs are another
  /// algorithm version's, predate review [reviewRevision], or hold under the
  /// rollup's three-day minimum. The rows' `is_today` stamps are the build
  /// day's, so they are restamped for [date].
  static Future<Map<String, dynamic>> rebuildCrossDayAsOf(
    String raw,
    String date,
    int reviewRevision,
  ) =>
      _runIsolateCancellable(
        () {
          final input = jsonDecode(raw);
          if (input is! Map ||
              (input['algo_version'] as num?)?.toInt() != kAlgoVersion ||
              input['review_revision'] != reviewRevision) {
            return const <String, dynamic>{};
          }
          final days = <Map<String, dynamic>>[
            for (final d in (input['days'] as List?) ?? const [])
              if (d is Map &&
                  d['date'] is String &&
                  (d['date'] as String).compareTo(date) <= 0)
                {
                  ...d.cast<String, dynamic>()..remove('is_today'),
                  if (d['date'] == date) 'is_today': true,
                },
          ];
          return days.length < 3
              ? const <String, dynamic>{}
              : buildCrossDayBundle(days, const {});
        },
        _crossDayTimeout,
        label: 'crossday-asof $date',
      );

  static Future<R> _runIsolateCancellable<R>(
    FutureOr<R> Function() compute,
    Duration timeout, {
    required String label,
  }) async {
    final port = ReceivePort();
    // The id first: `wrap` is the closure itself unless a test installed the
    // audit hook, in which case the worker adopts the audit port and this id
    // before running it.
    final dispatchId = WorkerAudit.dispatched(Dispatcher.cancellable, label);
    final (SendPort, FutureOr<Object?> Function()) message =
        (port.sendPort, WorkerAudit.wrap<Object?>(compute, dispatchId));
    final isolate = await Isolate.spawn(
      _cancellableIsolateEntry,
      message,
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    final completer = Completer<R>();
    late final StreamSubscription<dynamic> sub;
    sub = port.listen((msg) {
      if (completer.isCompleted) return;
      if (msg is _IsolateValue) {
        completer.complete(msg.value as R);
      } else if (msg is List) {
        // Our caught-exception report or the `onError` port's uncaught-error
        // format — both 2-element lists of strings.
        completer.completeError(
          StateError(
            msg.isNotEmpty
                ? '$label isolate failed: ${msg.first}'
                : '$label isolate failed with no error detail',
          ),
        );
      } else if (msg == null) {
        // `onExit` — the isolate ended without ever sending a result.
        completer.completeError(
          StateError('$label isolate exited without a result'),
        );
      }
    });
    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          isolate.kill(priority: Isolate.immediate);
          throw TimeoutException('$label timed out after $timeout');
        },
      );
    } finally {
      await sub.cancel();
      port.close();
      // No-op if it already exited; guarantees a hung isolate never outlives
      // this call.
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// `Isolate.spawn` entry point for [_runIsolateCancellable].
  static Future<void> _cancellableIsolateEntry(
    (SendPort, FutureOr<Object?> Function()) args,
  ) async {
    final (sendPort, compute) = args;
    try {
      // `Isolate.exit` hands the result graph to the parent without copying
      // it (the day state alone is a 10-15 MB graph). Nothing after it runs;
      // the parent still receives the `onExit` null, which it ignores once the
      // result is in.
      Isolate.exit(sendPort, _IsolateValue(await compute()));
    } catch (e, st) {
      sendPort.send([e.toString(), st.toString()]);
    }
  }

  /// `Isolate.spawn` entry point for [_runDayBlocksCancellable]. Must be a
  /// static/top-level function taking exactly one (sendable) argument.
  @heavy
  static void _dayBlocksIsolateEntry(
      (SendPort, _DayBlocksInput, SendPort?, int) args) {
    final (sendPort, input, auditPort, dispatchId) = args;
    WorkerAudit.adopt(auditPort, dispatchId);
    WorkerAudit.entered('_dayBlocksIsolateEntry');
    try {
      // Ownership move, not a copy: see [_cancellableIsolateEntry].
      Isolate.exit(sendPort, _computeDayBlocks(input));
    } catch (e, st) {
      sendPort.send([e.toString(), st.toString()]);
    }
  }

  /// The full PURE second half of per-day derivation, run OFF the calling
  /// isolate via a cancellable spawned isolate (see [_runDayBlocksCancellable],
  /// [_derivePreparedDay]). Previously ALL of this ran on whatever isolate
  /// drove the engine — the UI isolate for the foreground light pass fired on
  /// every sync — producing multi-second main-thread hangs (rolling RSA
  /// Lomb-Scargle over the 24 h day, nap re-staging, workout detection, wake
  /// features, steps/energy). DB reads are performed by the caller and passed
  /// in; DB writes + notifications are returned as descriptors for the caller
  /// to apply.
  @heavy
  static _DayBlocksOutput _computeDayBlocks(_DayBlocksInput inp) {
    final daySub = inp.daySub;
    final sleepSub = inp.sleepSub;
    final onset = inp.onsetSec;
    final offset = inp.offsetSec;
    final bundlePatch = <String, dynamic>{};
    final seriesPatch = <String, dynamic>{};
    // Working scalars — everything computed below is written here and merged
    // back by the caller. It used to be seeded with `{'rhr': inp.rhr}` under a
    // comment claiming the pure helpers read it; nothing does (they take
    // `restingHr` as an argument), and the seed then had to be deleted again
    // before returning. `inp.rhr` is the NOCTURNAL resting HR, never the
    // daytime fallback — see `_DayBlocksInput.rhr`.
    final scMap = <String, dynamic>{};

    final wake = applyDayActivity(
      bundle: bundlePatch,
      scalars: scMap,
      daySub: daySub,
      profile: inp.profile,
      sleepOnsetSec: onset,
      sleepOffsetSec: offset,
      dayStartSec: inp.dayStartSec,
      // NOT `inp.dayEndSec` — that is the data edge. See `applyDayActivity`.
      dayCalendarEndSec: localNextMidnightSecForDayLabel(inp.date),
      dataNowSec: inp.dataNowSec,
      restingHr: inp.rhr ?? inp.rhrFallback,
      dynFloorG: inp.dynFloorG,
      liveStepsReal: inp.liveStepsReal,
      liveStepsFromStrap: inp.liveStepsFromStrap,
      counterProfile: inp.counterProfile,
      counterWearing: inp.counterWearing,
      dynHistoryDays: inp.dynHistoryDays,
      stepSpans: inp.stepSpans,
      sessions: inp.savedSessions,
      tonightSleepOnsetSec: inp.tonightSleepOnsetSec,
      quietHrrHistory: inp.quietHrrHistory,
      state: inp.calculationState, mode: inp.calculationMode,
    );

    final streamed = inp.streamed;
    // Tonight's sleep begun before midnight is cut from daytime HRV (upstream
    // v106); the streamed value has no such cut, so it serves only a day
    // without one.
    bundlePatch['daytime_hrv'] = inp.tonightSleepOnsetSec > 0
        ? _daytimeHrv(daySub, onset, offset,
            tonightSleepOnsetSec: inp.tonightSleepOnsetSec)
        : streamed?.daytime ?? _daytimeHrv(daySub, onset, offset);
    seriesPatch['hrv_day'] = streamed?.hrv ??
        dayHrvCurve(daySub, state: inp.calculationState, mode: inp.calculationMode);
    seriesPatch['resp_day'] = streamed?.resp ??
        dayRespCurve(daySub, state: inp.calculationState, mode: inp.calculationMode);
    seriesPatch['skin_temp_day'] = _daySkinTempCurve(daySub);
    bundlePatch['restlessness'] = _restlessness(sleepSub);
    // napSub extends a few hours past this day's calendar end so a nap/
    // secondary-sleep block spanning midnight isn't bisected — but a run that
    // actually STARTS in that borrowed buffer belongs to tomorrow (which sees
    // it in its own regular window), so both helpers drop anything starting
    // at/after dayEndSec to avoid double-counting.
    // Naps FIRST — `_sleepPeriods` lists exactly these, so the Timeline bands
    // and the Sleep-periods cards can never disagree again.
    final napSuggestions = <Map<String, dynamic>>[];
    final napPeriods = _attachNaps(
      bundlePatch,
      scMap,
      inp.napSub,
      onset,
      offset,
      attributionStartSec: inp.dayStartSec,
      attributionEndSec: inp.dayEndSec,
      wristOff: inp.wristOffSpans,
      charging: inp.chargingSpans,
      blanked: inp.blankedSpans,
      napEdits: inp.napEdits,
      candidates: napSuggestions,
      napExcludeEndSec: inp.napExcludeEndSec ?? offset,
      tonightSleepOnsetSec: inp.tonightSleepOnsetSec,
      tonightSleepOffsetSec: inp.tonightSleepOffsetSec,
    );
    bundlePatch['sleep_periods'] = _sleepPeriods(
      onset,
      offset,
      napPeriods,
      mainTstMin: inp.mainTstMin,
      mainEfficiency: inp.mainEfficiency,
    );
    bundlePatch['sleep_charging'] = sleepChargingBlock(
      inp.chargingSpans,
      onset,
      offset,
    );
    // `activity_curve` is already in bundlePatch from `applyDayActivity` (the
    // incremental summary's curve, or `_activityCurve` when it has no state).
    // `detected_workouts` is NOT written. It was a permanently-empty stub kept
    // for a WorkoutDetector pass that was going to be re-homed here; analytics
    // has since deleted `workout_detect.dart`, so there is no pass to re-home
    // and no reason to write an empty list every day. The repository's reader
    // already skips a missing key, and auto-detected bouts reach the UI through
    // `workout_suggestions` below.

    final wc = _computeWorkouts(
      s: daySub,
      maxHr: inp.maxHrUsed,
      rhrScalar: inp.rhr,
      saved: inp.savedSessions,
      date: inp.date,
      dayEndSec: inp.dayEndSec,
      dataNowSec: inp.dataNowSec,
    );
    bundlePatch['workout_suggestions'] = wc.boutJson;
    if (wc.hrrBpm != null) scMap['hrr_bpm'] = wc.hrrBpm;
    if (wc.hrrTauS != null) scMap['hrr_tau_s'] = wc.hrrTauS;
    final ceilingComputed =
        <String, ({Map<String, dynamic> json, double? bpm})>{};
    final ceiling = _dayHrCeiling(
      daySub,
      inp.savedSessions,
      reuse: inp.ceilingReuse,
      computed: ceilingComputed,
    );
    bundlePatch['hr_ceiling'] = ceiling;
    // TS-03 — the day's observed ceiling as a SCALAR too, so the app-wide
    // "highest we've seen" is a max over `metric_series` (one small query the
    // baseline cache already loads) instead of a scan of every stored bundle.
    // The envelope above keeps the date/session/hold the copy needs; this is
    // just the number, and only when the day actually held one.
    // `Metric.toJson` writes the STRING '—' for an absent value, not null, so
    // this must type-test rather than cast.
    final ceilingValue = ceiling['value'];
    if (ceilingValue is Map && ceilingValue['bpm'] is num) {
      scMap['hr_ceiling_bpm'] = (ceilingValue['bpm'] as num).toDouble();
    }

    _attachWristOrientation(bundlePatch, daySub, onset, offset);
    bundlePatch['advanced_sleep'] = const {'present': false};

    // Feature 6: Restlessness Map (5-min ENMO heatmap of the sleep window).
    if (sleepSub.length > 0) {
      const bucketSec = 300; // 5 min
      final moveSum = <int, double>{};
      final moveCount = <int, int>{};
      for (var i = 0; i < sleepSub.length; i++) {
        // Absent accel would score ENMO |0 - 1| = 1.0 — maximal restlessness
        // from no data. Skip it; a bucket with no present second is omitted.
        if (!sleepSub.accelPresentAt(i)) continue;
        final b = sleepSub.tsSec[i] ~/ bucketSec;
        final ax = sleepSub.ax[i];
        final ay = sleepSub.ay[i];
        final az = sleepSub.az[i];
        final mag = math.sqrt(ax * ax + ay * ay + az * az);
        final enmo = (mag - 1.0).abs();
        moveSum[b] = (moveSum[b] ?? 0.0) + enmo;
        moveCount[b] = (moveCount[b] ?? 0) + 1;
      }
      final out = <Map<String, dynamic>>[];
      final keys = moveSum.keys.toList()..sort();
      for (final b in keys) {
        final avgEnmo = moveSum[b]! / moveCount[b]!;
        final density = math.min(1.0, avgEnmo * 10.0);
        out.add({
          't': b * bucketSec,
          'density': double.parse(density.toStringAsFixed(3)),
        });
      }
      bundlePatch['restlessness_map'] = out;
    }

    // Feature 2 (fit-quality diagnostic) is GONE, not disabled. It scored band
    // tightness from `skinContact`, and there is no contact-quality field to
    // score: the byte is the sign+exponent half of a float32, which is why its
    // only observed values are {0, 63-70, 194-198}. On the decoded path it was
    // additionally a hardcoded 0 (`decoded_onehz` has no such column), so the
    // gate could never fire. A diagnostic built on a non-measurement is worse
    // than no diagnostic.

    return _DayBlocksOutput(
      calculationState: inp.calculationState,
      ceilingComputed: ceilingComputed,
      bundlePatch: bundlePatch,
      seriesPatch: seriesPatch,
      scalarPatch: scMap,
      wake: wake,
      // Off the same inputs `applyDayActivity` priced the day from, here in the
      // isolate with them: the minutes sum to the stored active figure.
      kcalMinutes: kcalMinutesForDayHeavy(
        daySub: daySub,
        profile: inp.profile,
        nocturnalRhr: inp.rhr,
        sleepOnsetSec: onset,
        sleepOffsetSec: offset,
        stepSpans: inp.stepSpans,
        state: inp.calculationState,
        mode: inp.calculationMode,
      ),
      suggestionsToPersist: wc.suggestionsToPersist,
      napSuggestions: napSuggestions,
      sessionHrrWrites: wc.sessionHrrWrites,
    );
  }

  /// PURE compute half of workout SUGGESTIONS (`autoDetectWorkouts`) + HRR.
  ///
  /// Runs inside the day-blocks isolate: one detector pass over the day's 1 Hz HR
  /// (+ gravity motion) yields the detected bouts (excluding any already-saved
  /// manual/live session, passed in via [saved] which the caller read from the DB
  /// on the DB-owning isolate) and each bout's HR-tail HRR-60s drop. Returns the
  /// bout JSON, the mean `hrr_bpm`, the retrospective per-session HRR writes, the
  /// recent-day suggestions to persist, and the freshly-ended notif candidate —
  /// the DB writes + notification are performed by the caller on the main isolate.
  static _WorkoutCompute _computeWorkouts({
    required Substrate s,
    required int? maxHr,
    required double? rhrScalar,
    required List<Map<String, dynamic>> saved,
    required String date,
    required int dayEndSec,
    required int dataNowSec,
  }) {
    try {
      final n = s.length;
      if (n < 60) return const _WorkoutCompute.empty();
      final hrTs = <int>[];
      final hrBpm = <int>[];
      for (var i = 0; i < n; i++) {
        if (s.hr[i] > 0) {
          hrTs.add(s.tsSec[i]);
          hrBpm.add(s.hr[i]);
        }
      }
      if (hrBpm.length < 60) return const _WorkoutCompute.empty();
      // Feed the detector only the seconds that carry a real gravity vector.
      // Absent accel reads as a motionless wrist, which is exactly the shape
      // that suppresses a workout candidate — a missed workout, silently.
      final mTs = <int>[], mAx = <double>[], mAy = <double>[], mAz = <double>[];
      for (var i = 0; i < n; i++) {
        if (!s.accelPresentAt(i)) continue;
        mTs.add(s.tsSec[i]);
        mAx.add(s.ax[i]);
        mAy.add(s.ay[i]);
        mAz.add(s.az[i]);
      }
      final motion = ana.AutoWorkoutDetector.motionPoints(mTs, mAx, mAy, mAz);
      // Exclude windows the user has already logged (manual/live wins).
      // A still-running session (status='live') has a null end_ts — treat it
      // as open through "now" rather than dropping it, or its own live
      // minutes get mistaken for an undiscovered bout.
      final savedSpans = <ana.SavedWorkoutSpan>[
        for (final r in saved)
          if (r['start_ts'] is int)
            ana.SavedWorkoutSpan(
              r['start_ts'] as int,
              r['end_ts'] is int ? r['end_ts'] as int : dataNowSec,
            ),
      ];
      final rhr = rhrScalar?.round();
      // Auto-detection needs a real resting-HR baseline. Without one the detector
      // can't compute a trustworthy %HRR floor and ordinary daytime HR reads as a
      // workout. If we don't have a nightly RHR for this day yet, skip detection
      // entirely (HRR for already-saved sessions below still runs).
      final bouts = rhr == null
          ? const <ana.DetectedWorkout>[]
          : (ana.autoDetectWorkouts(
                hrTs: hrTs,
                hrBpm: hrBpm,
                restingBpm: rhr,
                maxBpm: maxHr,
                motion: motion,
                savedSpans: savedSpans,
              ).value ??
              const <ana.DetectedWorkout>[]);

      // HRR per bout from the per-second HR tail bracketing each bout end.
      final drops = <double>[];
      final taus = <double>[];
      final boutJson = <Map<String, dynamic>>[];
      for (final b in bouts) {
        final r = _hrrForBout(s, b.endSec);
        final m = r.hrrBpm;
        if (m != null) drops.add(m);
        if (r.tauSec != null) taus.add(r.tauSec!);
        boutJson.add({
          'start': b.startSec,
          'end': b.endSec,
          'avg_bpm': b.avgBpm,
          'peak_bpm': b.peakBpm,
          'duration_min': b.durationMin,
          'sport': b.sport,
          if (m != null) 'hrr_bpm': double.parse(m.toStringAsFixed(1)),
          if (r.tauSec != null) 'hrr_tau_s': r.tauSec!.round(),
        });
      }
      // Also fill HRR for already-saved sessions (manual/live) retrospectively
      // from the substrate around each session's end — so the workout detail
      // screen shows HRR without buffering 60 s after a live stop.
      final sessionHrr = <(String, double)>[];
      for (final r in saved) {
        final id = r['id'];
        final endTs = r['end_ts'];
        if (id is! String || endTs is! int) continue;
        final rec = _hrrForBout(s, endTs);
        final m = rec.hrrBpm;
        if (rec.tauSec != null) taus.add(rec.tauSec!);
        if (m != null) {
          drops.add(m);
          sessionHrr.add((id, double.parse(m.toStringAsFixed(1))));
        }
      }
      final hrrBpm = drops.isEmpty
          ? null
          : double.parse(
              (drops.reduce((a, c) => a + c) / drops.length).toStringAsFixed(1));
      // Mean tau over the bouts that SURVIVED the residual gate — deliberately
      // a different denominator from `hrrBpm`'s, because the gate abstains
      // often and pretending otherwise would average a fit never made.
      final hrrTauS = taus.isEmpty
          ? null
          : double.parse(
              (taus.reduce((a, c) => a + c) / taus.length).toStringAsFixed(1));

      // The DB-owning layer applies the activation cutoff and alert policy.
      final toPersist = <Map<String, dynamic>>[];
      // ONE definition of the row id. The notification checks the table by it
      // and opens the screen on it, so a second copy of the format here would
      // drift into a prompt that silently never fires again.
      String sugId(int startSec) => '$date:$startSec';
      if (bouts.isNotEmpty) {
        for (final b in bouts) {
          toPersist.add({
            'id': sugId(b.startSec),
            'date': date,
            'start_ts': b.startSec,
            'end_ts': b.endSec,
            'avg_bpm': b.avgBpm,
            'peak_bpm': b.peakBpm,
            'duration_min': b.durationMin,
            'sport': b.sport,
            'dismissed': 0,
          });
        }

      }
      return _WorkoutCompute(
        boutJson: boutJson,
        hrrBpm: hrrBpm,
        hrrTauS: hrrTauS,
        sessionHrrWrites: sessionHrr,
        suggestionsToPersist: toPersist,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[derive] auto-workout/HRR FAILED/skipped: $e');
      return const _WorkoutCompute.empty();
    }
  }

  /// TS-03 — the day's OBSERVED heart-rate ceiling: the highest bpm any of this
  /// day's SAVED sessions held for ≥15 continuous seconds with corroborating
  /// motion, tagged with the session it came from.
  ///
  /// NOT a physiological HRmax and not a substitute for one. Whoever renders it
  /// says "highest we've seen: 184, on 3 Aug" with the date and the session,
  /// never "your max HR is 184", and never invites a max-effort test. The
  /// app-wide ceiling is the max over days of the PRESENT values — a one-line
  /// reduce for the reader, deliberately not a second function here, so the
  /// hold+motion guard cannot be bypassed by reducing over un-guarded numbers.
  ///
  /// Absent is the common case and it is correct: most sessions do not test
  /// your ceiling. So is an unknown device family — the motion gate is a
  /// property of the sensor package and gen4's floor is not a default (see
  /// `observed_max_hr.dart`).
  ///
  /// Sessions are scored ONE AT A TIME, never as a concatenated day: a hold
  /// must be continuous inside one session, and stitching two sessions would
  /// invent a hold across the gap between them.
  @visibleForTesting
  static Map<String, dynamic> dayHrCeiling(
    Substrate s,
    List<Map<String, dynamic>> saved, {
    Map<String, ({Map<String, dynamic> json, double? bpm})> reuse = const {},
    Map<String, ({Map<String, dynamic> json, double? bpm})>? computed,
  }) => _dayHrCeiling(s, saved, reuse: reuse, computed: computed);

  /// [reuse] holds the already-validated result of a finished session, by id:
  /// that session is not scanned. [computed], when given, receives the result of
  /// every finished (not `live`) session that WAS scanned, for the caller's
  /// cache. A result is the `Metric.toJson` map plus the unrounded bpm the max
  /// is taken over, so reuse picks the same session a full scan would.
  static Map<String, dynamic> _dayHrCeiling(
    Substrate s,
    List<Map<String, dynamic>> saved, {
    Map<String, ({Map<String, dynamic> json, double? bpm})> reuse = const {},
    Map<String, ({Map<String, dynamic> json, double? bpm})>? computed,
  }) {
    Map<String, dynamic>? bestJson;
    double? bestBpm;
    String? bestId;
    String? bestType;
    Map<String, dynamic>? lastAbsentJson;
    for (final row in saved) {
      final start = (row['start_ts'] as num?)?.toInt();
      final end = (row['end_ts'] as num?)?.toInt();
      if (start == null || end == null || end <= start) continue;
      final id = row['id']?.toString();
      final cached = id == null ? null : reuse[id];
      if (cached != null) {
        final bpm = cached.bpm;
        if (bpm == null) {
          lastAbsentJson = cached.json;
        } else if (bestBpm == null || bpm > bestBpm) {
          bestJson = cached.json;
          bestBpm = bpm;
          bestId = id;
          bestType = row['type']?.toString();
        }
        continue;
      }
      final hr = <ana.HrSample>[];
      final accel = <ana.AccelSample>[];
      for (var i = 0; i < s.length; i++) {
        final t = s.tsSec[i];
        if (t < start) continue;
        if (t > end) break;
        final tsMs = t * 1000.0;
        hr.add(ana.HrSample(tsMs, s.hr[i].toDouble()));
        accel.add(ana.AccelSample(tsMs, s.ax[i], s.ay[i], s.az[i],
            valid: s.accelPresentAt(i)));
      }
      if (hr.isEmpty) continue;
      final m = ana.sessionHrCeiling(hr, accel, deviceFamily: s.deviceFamily);
      final json = m.toJson((v) => v.toJson());
      if (computed != null && id != null && row['status'] != 'live') {
        computed[id] = (json: json, bpm: m.present ? m.value!.bpm : null);
      }
      if (!m.present) {
        lastAbsentJson = json;
        continue;
      }
      if (bestBpm == null || m.value!.bpm > bestBpm) {
        bestJson = json;
        bestBpm = m.value!.bpm;
        bestId = id;
        bestType = row['type']?.toString();
      }
    }
    final json = bestJson ??
        lastAbsentJson ??
        const ana.Metric<ana.HrCeiling>.absent(
          tier: ana.Tier.high,
          inputs_used: ['hr_1hz', 'accel_1hz', 'device_family'],
          note: 'no saved session on this day to observe a ceiling in',
        ).toJson((v) => v.toJson());
    return {
      ...json,
      'session_id': ?bestId,
      'session_type': ?bestType,
    };
  }

  /// HRR-60s + the recovery time constant for a bout ending at [endSec]: build
  /// the per-second HR tail around the end index, delegate the drop to
  /// [ana.hrRecovery] and fit tau over the same tail. Either half may be null.
  static ({double? hrrBpm, double? tauSec}) _hrrForBout(
      Substrate s, int endSec) {
    const none = (hrrBpm: null, tauSec: null);
    final n = s.length;
    if (n == 0) return none;
    // Find the index nearest the bout end.
    var endIdx = -1;
    for (var i = 0; i < n; i++) {
      if (s.tsSec[i] >= endSec) {
        endIdx = i;
        break;
      }
    }
    if (endIdx < 0) endIdx = n - 1;
    // A hole across the bout end (strap back on, sync gap) makes the first
    // sample after it a moment the band only started recording again: its HR
    // is not the exercise peak and the drop from it is not a recovery.
    // hrRecovery's own 30 s gap tolerance, measured from the bout end.
    if (s.tsSec[endIdx] - endSec > 30) return none;
    // SLICE BY TIME, not by array position. The substrate is one row per
    // DECODED RECORD, not a dense 1 Hz grid, so `endIdx ± 30/75` used to cut a
    // window whose real duration depended on how gappy the tail was: on a sparse
    // day it stopped well short of +60 s (no recovery sample — HRR silently
    // absent), on a dense one it reached far past it. The comment below already
    // said this about `hrRecovery`'s own +60 s; the slice feeding it never
    // followed. ±30/+75 SECONDS around the bout end, so the 60-second sample is
    // always inside the window when the data exists at all.
    // +180 s, not +75: HRR-60 only ever needed to reach the 60-second sample,
    // but tau is fitted over the whole decay and a 75-second tail is one time
    // constant of curve. Widening does NOT move `hrr_bpm` — `hrRecovery` locates
    // its recovery point on the CLOCK and stops at the first sample past +60 s.
    const preSec = 30, postSec = 180;
    var lo = endIdx;
    while (lo > 0 && s.tsSec[lo - 1] >= endSec - preSec) {
      lo--;
    }
    var hi = endIdx;
    while (hi + 1 < n && s.tsSec[hi + 1] <= endSec + postSec) {
      hi++;
    }
    final tail = <int>[for (var i = lo; i <= hi; i++) s.hr[i]];
    // `hrRecovery` reads "+60 s" off `tsSec`, not off the array index — on a
    // gappy tail the recovery sample would otherwise be many minutes
    // post-exercise and the drop is overstated, read by the user as a fitness
    // marker.
    final tailTs = <int>[for (var i = lo; i <= hi; i++) s.tsSec[i]];
    final m = ana.hrRecovery(
      tail,
      endIndex: endIdx - lo,
      recoverySec: 60,
      tsSec: tailTs,
    );
    return (
      hrrBpm: m.present ? m.value!.dropBpm : null,
      tauSec: _recoveryTau(tail, tailTs, endIdx - lo),
    );
  }

  /// Recovery time constant (s) from a monoexponential fit of the post-exercise
  /// HR decay: `hr(t) = C + A*exp(-t/tau)` over 0…180 s after the bout end.
  ///
  /// Grid-search tau; A and C fall out of a linear least squares once tau is
  /// fixed, so there is no optimiser here and no starting point to get wrong.
  ///
  /// PUBLISHED ALONGSIDE HRR-60, NEVER INSTEAD OF IT. tau is not
  /// intensity-invariant — HR recovery is biphasic and the fast-phase constant
  /// is itself intensity-dependent, so one exponential over 0-180 s conflates
  /// the two phases. The gate below abstains rather than fit a shape that is not
  /// there: it needs a clean stop (enough samples, a real fall, no long hole)
  /// and a residual small against the decay it claims to describe.
  @visibleForTesting
  static double? recoveryTau(List<int> hr, List<int> tsSec, int endIdx) =>
      _recoveryTau(hr, tsSec, endIdx);

  static double? _recoveryTau(List<int> hr, List<int> tsSec, int endIdx) {
    if (endIdx < 0 || endIdx >= hr.length) return null;
    final t = <double>[], y = <double>[];
    final t0 = tsSec[endIdx];
    var lastTs = t0;
    for (var i = endIdx; i < hr.length; i++) {
      if (tsSec[i] - lastTs > 30) break; // hole — the tail stops here
      lastTs = tsSec[i];
      if (hr[i] < kHrFloorBpm) continue;
      t.add((tsSec[i] - t0).toDouble());
      y.add(hr[i].toDouble());
    }
    // Need most of the 180 s and a real fall to fit at all.
    if (t.length < 60 || t.last < 120) return null;
    final peak = y.reduce(math.max);
    final floor = y.reduce(math.min);
    if (peak - floor < 15) return null; // no fall — not a recovery

    double? bestTau;
    var bestSse = double.infinity;
    for (var tau = 15.0; tau <= 240.0; tau += 2.5) {
      // Linear LS of y ~ C + A*x where x = exp(-t/tau).
      var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
      final n = t.length;
      for (var i = 0; i < n; i++) {
        final x = math.exp(-t[i] / tau);
        sx += x;
        sy += y[i];
        sxx += x * x;
        sxy += x * y[i];
      }
      final den = n * sxx - sx * sx;
      if (den.abs() < 1e-9) continue;
      final a = (n * sxy - sx * sy) / den;
      final c = (sy - a * sx) / n;
      if (a <= 0) continue; // rising, not decaying
      var sse = 0.0;
      for (var i = 0; i < n; i++) {
        final r = y[i] - (c + a * math.exp(-t[i] / tau));
        sse += r * r;
      }
      if (sse < bestSse) {
        bestSse = sse;
        bestTau = tau;
      }
    }
    if (bestTau == null) return null;
    // Residual gate. An RMSE over 3 bpm means the tail is not the single decay
    // we just claimed it was — abstain rather than loosen it.
    final rmse = math.sqrt(bestSse / t.length);
    if (rmse > 3.0) return null;
    // A tau pinned to either end of the grid is the search running out of room,
    // not a measurement.
    if (bestTau <= 15.0 || bestTau >= 240.0) return null;
    return bestTau;
  }

  /// Low-confidence WRIST ORIENTATION during the sleep window (`positionSeries`).
  /// Explicitly a WRIST measure (body-position PROXY), never claimed as the
  /// sleeper's supine/side/prone body position. Emits a dominant-orientation
  /// summary + per-position minutes + an orientation-change count. Best-effort.
  static void _attachWristOrientation(
    Map<String, dynamic> bundle,
    Substrate s,
    int onsetSec,
    int offsetSec,
  ) {
    try {
      if (offsetSec <= onsetSec) return;
      final epoch = <ana.AccelSample>[
        for (var i = 0; i < s.length; i++)
          if (s.tsSec[i] >= onsetSec && s.tsSec[i] < offsetSec)
            ana.AccelSample(s.tsSec[i] * 1000.0, s.ax[i], s.ay[i], s.az[i],
                valid: s.accelPresentAt(i))
      ];
      if (epoch.length < 60) return;
      final tilts = ana.positionSeries(epoch, epochSec: 30);
      if (tilts.isEmpty) return;
      // Per-position minutes (each epoch ≈ 30 s) + orientation-change count.
      final mins = <String, double>{};
      var changes = 0;
      String? prev;
      for (final t in tilts) {
        mins[t.position] = (mins[t.position] ?? 0) + 0.5; // 30 s
        if (prev != null && prev != t.position) changes++;
        prev = t.position;
      }
      String dominant = 'unknown';
      var best = -1.0;
      mins.forEach((k, v) {
        if (v > best) {
          best = v;
          dominant = k;
        }
      });
      bundle['wrist_orientation'] = <String, dynamic>{
        'dominant': dominant,
        'minutes': mins,
        'changes': changes,
        'epochs': tilts.length,
        'confidence': 'low',
        'tier': ana.Tier.relative,
        'note': 'Wrist orientation during sleep, from gravity tilt. '
                'It cannot tell supine, side or prone position, '
                'because the wrist moves independently of the torso.',
      };
    } catch (e) {
      if (kDebugMode) debugPrint('[derive] wrist-orientation FAILED/skipped: $e');
    }
  }

  // static: pure day-label arithmetic, and `rawPruneCutoffSec` /
  // `rescanDayIds` need them.
  static int _localDayLabelToSec(String day) {
    final d = DateTime.tryParse(day);
    if (d == null) return 0;
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;
  }

  // was `_localDayLabelToSec(day) + 86400` at every call site - assumes every
  // local day is exactly 24h, which is wrong on the two DST-transition days a
  // year (23h/25h). DateTime normalizes the day+1 overflow itself and
  // .millisecondsSinceEpoch already respects local DST rules, so just asking
  // for the START of the NEXT day gets this right without hardcoding a
  // day length.
  static int _localNextDayLabelToSec(String day) {
    final d = DateTime.tryParse(day);
    if (d == null) return 0;
    return DateTime(d.year, d.month, d.day + 1).millisecondsSinceEpoch ~/ 1000;
  }

  String _skipReasonForError(Object error) {
    final msg = error.toString();
    if (msg.contains('day_prepare_budget_exceeded')) {
      return 'day_prepare_budget_exceeded';
    }
    if (msg.contains('TimeoutException')) {
      return 'timeout';
    }
    return 'error';
  }

  /// The substrate range to LOAD so [calendarDays] can actually run its
  /// documented nocturnal search for [dayId].
  ///
  /// `calendarDays` searches from the previous local NOON
  /// (`dayStart − kNocturnalSearchLookbackSec`), and its comment records that
  /// widening from the old prev-18:00 window as deliberate — "the old
  /// prev-18:00 → noon window missed late wakes and forced the detector to act
  /// like there was only one candidate sleep". But this loader only fetched
  /// `dayStart − 6 h` (= 18:00), and `searchStart = math.max(dataStart, …)`
  /// clipped the search right back to the slice start, so the widening was a
  /// no-op and any sleep onset before 18:00 was truncated. Load the whole
  /// window the day model asks for, from the one shared constant.
  (int, int) _targetDayWindow(String dayId, {int? overrideOnsetSec, int? overrideOffsetSec}) {
    final startSec = _localDayLabelToSec(dayId);
    final endSec = _localNextDayLabelToSec(dayId);
    final normalStart = math.max(0, startSec - kNocturnalSearchLookbackSec);
    final normalEnd = endSec - 1;
    if (overrideOnsetSec == null || overrideOffsetSec == null || overrideOffsetSec <= overrideOnsetSec) {
      return (normalStart, normalEnd);
    }
    const margin = 3 * 3600;
    return (math.max(0, math.min(normalStart, overrideOnsetSec - margin)),
      math.max(normalEnd, overrideOffsetSec + margin));
  }

  /// Test seam for [_targetDayWindow] — the bug was that this loader and
  /// [calendarDays]' search window silently disagreed, so the agreement is
  /// pinned directly.
  @visibleForTesting
  (int, int) debugTargetDayWindow(String dayId,
      {int? overrideOnsetSec, int? overrideOffsetSec}) => _targetDayWindow(dayId,
        overrideOnsetSec: overrideOnsetSec, overrideOffsetSec: overrideOffsetSec);

  /// Test seam for [_sleepPeriods] — "an unjudged day publishes no total" is a
  /// one-line invariant guarding a user-visible number, so it is pinned
  /// directly rather than through a full derive pass.
  @visibleForTesting
  static Map<String, dynamic> debugSleepPeriods(
    int onsetSec,
    int offsetSec,
    List<Map<String, dynamic>>? naps, {
    int? mainTstMin,
    double? mainEfficiency,
  }) =>
      _sleepPeriods(
        onsetSec,
        offsetSec,
        naps,
        mainTstMin: mainTstMin,
        mainEfficiency: mainEfficiency,
      );
  @visibleForTesting
  static ({double? hrrBpm, double? tauSec}) debugHrrForBout(
          Substrate s, int endSec) =>
      _hrrForBout(s, endSec);

  /// Test seam for [_attachNaps] — the day-boundary attribution rules (drop
  /// tomorrow's leading nap, drop yesterday's trailing one) decide which day a
  /// nap's minutes are credited to, and are cheap to state directly.
  @visibleForTesting
  static List<Map<String, dynamic>>? debugAttachNaps(
    Map<String, dynamic> bundle,
    Map<String, dynamic>? scMap,
    Substrate s,
    int onsetSec,
    int offsetSec, {
    int? attributionStartSec,
    int? attributionEndSec,
    List<List<int>> wristOff = const [],
    List<List<int>> charging = const [],
    List<NapEdit> napEdits = const [],
    List<Map<String, dynamic>>? candidates,
    int? napExcludeEndSec,
    int tonightSleepOnsetSec = 0,
    int tonightSleepOffsetSec = 0,
    List<List<int>> blanked = const [],
  }) =>
      _attachNaps(
        bundle,
        scMap,
        s,
        onsetSec,
        offsetSec,
        attributionStartSec: attributionStartSec,
        attributionEndSec: attributionEndSec,
        wristOff: wristOff,
        charging: charging,
        blanked: blanked,
        napEdits: napEdits,
        candidates: candidates,
        napExcludeEndSec: napExcludeEndSec,
        tonightSleepOnsetSec: tonightSleepOnsetSec,
        tonightSleepOffsetSec: tonightSleepOffsetSec,
      );

  void _log(String m) {
    if (kDebugMode) debugPrint('[derive] $m');
    log?.call('[derive] $m');
  }

  /// The audit's own lines keep their `[audit]` prefix unwrapped so the log
  /// export can be grepped for them.
  void _auditLog(String m) {
    if (kDebugMode) debugPrint(m);
    log?.call(m);
  }
}
