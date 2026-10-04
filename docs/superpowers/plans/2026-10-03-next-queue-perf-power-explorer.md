# Plan: next work queue — finish 8AF.6/8AF.7, DOI links, "calculations ready" + power modes, Data Explorer

## Context
The user asked (this turn): do we have calorie-burn graph data; a Data Explorer
in the explore area that overlays several metrics on one time-range graph; a
GPT 6.1 (high) codex review of why calculations are "basically never done" when
opening screens; and a 3-mode setting (Maximum battery / Balanced / Eager) that
reuses what other devs built. Answers they gave: Explorer = daily AND intraday;
time is always the one shared axis, metrics normalised with a real-value scrub
readout; find DOIs for all shown citations (old docs/comments may help; bring
hard ones to the user); intraday calories later via analytics.

Findings (read-only):
- **Calories:** daily `calories`/`calories_total` in metric_series (charted in
  Health › Trends via MetricDetail('calories')); per-workout kcal stored; NO
  intraday kcal (health export spreads the daily total evenly). The pinned
  analytics package already exposes the per-minute pieces (`Calories.activeKcalPerS`,
  `restingKcalPerS`, `mifflinBmrKcalDay`, `activeGateHr`) so an intraday curve
  is cheap later; deferred per the user.
- **Prior art for power:** no phone-battery/charging-aware compute exists and no
  upstream PR/branch for it. What others built: the 2026-08 battery audit tiers
  (commit 29605c4f; `DeriveDebouncer` tiers lib/ble/ble_state.dart:1005,
  `DerivePacing` lib/compute/derive_pacing.dart, 30-min background heavy
  throttle app_state ~6412, `DeriveScheduler` gates lib/compute/derive_scheduler.dart),
  `battery_plus` already a dependency, `_charging()` in
  lib/telemetry/health_uploader.dart:144. The modes build on these.
- **Codex (gpt-6.1-sol, high) root causes** (/tmp/codex_perf_review.md):
  (1) screens compute on open — journal correlations in MetricDetail load,
  weekday effects, Beats RR correction, past-workout rescoring; (2) layered
  delays: BLE debounce 5–15 s fg / 20–45 min bg + scheduler settle 8 s, iOS holds
  jobs while backgrounded; (3) "light" ≈ same per-day cost, automatic runs skip
  `changedOnly`, each pass rebuilds baselines/cross-day from ≤ 90 days;
  (4) results publish only after the whole pass (`insightsRevision` bumps in
  `_afterDrain`), `_bundle` decodes whole payloads per call, hidden tabs reload;
  (5) light intent dropped while a job runs, failures marked complete, workout
  hold up to 6 h. Fingerprint `MAX(rec_ts):COUNT(*)` misses in-place replaces.
  Also flags a `day_result` REPLACE vs immutability mismatch (AGENTS §3.4).

## Order of work (each via rg-implement: red agents → parent red gate → green
phases → full suite + analyze → commit; agents get line ranges, no dart format,
no pgrep wait loops, no leftover flutter_tester)
1. **Finish 8AF.6** (approved; phase 1 green, uncommitted): G2 = gesture cues +
   tap `*` notes/"Edit as notes" + default-rhythm preview; G3 = wake vocabulary +
   HR zone alert + docs (also route the relay default to `alert.relay`).
2. **Merge 8AF.8** (worktree branch c67c4e0d, doi.org links) after 8AF.6.
3. **8AF.7** (approved): no Profile landing screen, remembered accordions,
   phone in My devices, Alarm → Alerts accordion, sync status line, pull-to-sync
   setting.
4. **8AF.9 DOI hunt** (worktree, parallel with 3): for the 12 shown citations,
   mine old docs/comments/git history/analytics repo for exact references; verify
   each DOI resolves at doi.org with matching title/year before adding; hard ones
   reported to the user; table + guard test unchanged in spirit.
5. **8AG-perf, phases P1–P5** (codex design, adapted):
   - P1 Measure + publish early: timing for queue wait/hold reason/prepare/
     compute/persist/first usable render; bump a per-day revision at each day
     commit so Home/Health refresh while history continues; hidden tabs don't
     reload on every revision.
   - P1b (user, 2026-10-03) Show the last calculated data on EVERY screen while
     new data is calculated, labelled "As of <last calculated time>" (date too
     when not today) wherever a screen's numbers come from a calculation that is
     re-running; the label clears when the fresh result lands. Never show
     another day's value as today's (§4.1/§3.7): a stale day keeps its own date.
     Applies to computed-on-open screens too, by caching their last result (P3
     makes those persistent; P1b uses the last in-memory/persisted result).
   - P2 Reliable scheduling: transaction-maintained input revisions (fix the
     fingerprint), structured run outcomes (failure ≠ complete), keep dirty
     intent when data arrives mid-run, `changedOnly` for automatic runs.
   - P3 Move analytics out of readers: journal correlations, weekday effects,
     corrected beats, finished-workout stats, circadian → persisted artifacts on
     worker isolates, keyed by kind + day/range + algo_version + input revisions.
   - P4 Cache-first screens: render the last compatible projection instantly
     with honest staleness ("Updated 08:42; recordings through 08:36", "Paused
     during workout", "Waiting for power"), cache miss enqueues work without
     blocking the shell; bounded memory cache for decoded bundles. Resolve the
     `day_result` immutability mismatch explicitly (provisional snapshots vs one
     finalized publish per day/version) — no metric output change, no algo bump.
   - P5 Power modes (Settings › Data & privacy or Band — "Calculations"):
     Maximum battery (power-saver aware, after-sync + on-demand only, one
     worker), Balanced (default; also warms Home/Health after 30 s idle and
     recent artifacts while plugged in; saver suppresses warming), Eager (ignores
     saver; after 5 continuous minutes on external power computes every
     missing/dirty artifact the inputs support; still respects thermal, memory,
     capture, workout, OS limits). Built on the audit tiers (mode scales
     DeriveDebouncer/DerivePacing/heavy throttle) + `battery_plus` charge stream +
     native isPowerSaveMode / isLowPowerModeEnabled; iOS power-constrained
     BGProcessing request for Eager. Fake-clock tests (4:59 vs 5:00 plugged,
     unplug/replug, saver toggles, mode switch).
   - Codex review (gpt-6.1-sol high) after P5.
6. **8AH Data Explorer**: a new "Explore" place in Health — a 5th sub-tab if
   Last night · Today · Trends · Explore · Labs fits at 360 pt (structural test),
   else an "Explorer" toggle inside Trends. Pick up to 4 metrics from the Trends
   catalogue (daily) or the intraday set (HR, HRV, resp, skin temp, activity +
   sleep/workout bands from `getDayTimeline`/`dayGraph`); one shared time axis;
   each line normalised to its own range (or z vs baseline, toggle) with an
   honest "normalised" label; `ChartScrub`/`ChartKey` readout shows real values
   + units; range presets (day for intraday; 7 d / 30 d / 6 mo / 1 y / custom
   for daily); shared date grid with gaps shown, never interpolated; metric
   colours from MetricSpec; RepaintBoundary (§4.11). Reuses `getChart`,
   `pointsOf`, `LineChart` stacking, `AxisSpec.t()`, `_catalogue`.
7. Intraday calories: analytics side in progress (../analytics branch feat/minute-energy, per-minute energy API, daily outputs unchanged); edge integration after P3 (cached per-day curve artifact) and as an Explorer intraday metric; cadence only ~3 days of raw data.

## Status

### 8AG-perf P1 — measure, publish each day, quiet hidden tabs, "As of" while recalculating (P1b)

- **Measured**: `DerivePerf` records queue wait, hold reasons, and per-day prepare / compute /
  persist; one `[perf] derive` line per pass, `last_pass_perf` on the engine snapshot, a
  "Last calculation" row in Settings > Developer, and Home's bump-to-first-render time.
- **Published early**: each committed day refreshes freshness and bumps `insightsRevision`
  through a 1.5 s coalescer with a trailing flush; hidden shell tabs (`TickerMode`) read once
  when shown instead of on every bump.
- **As of**: `AppState.recalc` (days still in the pass, cross-day flag) and `asOfFor` decide;
  `AsOfLabel` says "As of 08:42" (dated when not today) on Home, Health, Sleep, Readiness,
  metric detail, Wellness, Body clock and Beats while the day on screen is recalculating. The
  time is the shown row's own `computed_at`; no row, no label. Computed-on-open screens (metric
  journal insights, Wellness insights, Beats, past workouts) keep their last result in a
  32-entry `LastResultCache` and show it at once under the label.
- Docs: `docs/perf.md`; `test/phase8/CONTRACTS.md` (8AG P1/P1b). Tests: `test/perf/`.
- Not done here (later phases): persisted artifacts for the computed-on-open screens (P3, P4),
  scheduler reliability (P2), power modes (P5).

## Critical files
lib/compute/{derivation_engine,derive_scheduler,derive_pacing}.dart,
lib/ble/ble_state.dart (DeriveDebouncer), lib/state/app_state.dart (_afterDrain,
scheduler wiring), lib/data/{db,local_repository_impl}.dart, lib/ui2/revision.dart,
lib/ui2/screens/{health_screen,metric_detail,wellness_screen,beats,workout_screen,
circadian_detail}.dart, lib/telemetry/health_uploader.dart (_charging),
ios/Runner/BgSyncScheduler.swift, lib/ui2/charts.dart, lib/ui2/grammar.dart
(ChartScrub/ChartKey), lib/ui2/research_refs.dart.

## Verification
- Each phase: targeted tests red→green, full suite + analyze, commit; perf P1
  adds timing logs to verify on device (time from sync to visible result, first
  render); P5 fake-clock power tests; Explorer structural + scrub readout tests.
- Device: profile APK after 8AF.6/8AF.7 and after P4/P5 (ask before serving).
