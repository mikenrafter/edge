# Calculation timing and "As of"

## What the timing measures

Each derive pass records, in `lib/compute/derive_perf.dart`:

- **Queue wait**: from the scheduler enqueuing the job to the pass starting, and
  the reasons it was held while queued (`offload`, `manual_sync_hold`, `workout`,
  `background`, `settle`).
- **Per day**: prepare (substrate and staging), compute, and persist
  (`putDayResult`) milliseconds. The summary carries the total and the largest
  single day of each.
- **Pass**: total milliseconds, from start to end.
- **First usable render**: the time from an `insightsRevision` bump to the first
  Home commit that read it (`AppState.lastHomeRenderMs`).

Nothing here changes a metric, so `kAlgoVersion` is untouched.

## Where to read it

- Settings > Developer (dev mode on) > "Last calculation": for example
  "Waited 12 s (settle), 3 days, 41 s total". A value is shown only when it was
  measured; otherwise "—".
- The log, one line per pass: `[perf] derive wait=… holds=… days=… prepare=…
  compute=… persist=… pass=…`, and one per Home render: `[perf] home render N ms`.
- `DerivationEngine.snapshot()['last_pass_perf']` holds the same summary as a map.

## Publishing each day

`AppState._afterDrain` publishes every committed day (`refreshComputeFreshness`,
then `bumpInsights`) through `RevisionCoalescer`: at most one publish per 1.5 s,
with a trailing publish so the last day always lands. The end-of-pass bump stays.
Screens under the shell's hidden tabs do not re-read on every publish; they mark
themselves dirty and read once when shown (`TickerMode`, in `RevisionReload`).

## How "As of" works

While a pass runs, `AppState.recalc` (a `ValueListenable<RecalcState>`, separate
from `notifyListeners`) holds the days not finished yet, and whether the
cross-day step is running. It is cleared in `finally`, so a failed or cancelled
pass cannot leave a label up.

A screen shows `AsOfLabel` when `asOfFor(shownDay, computedAt, recalc)` returns a
time: the day on screen is in the running pass and its row has a computed time.
The time is the row's own `computed_at` (epoch ms, read from the row actually
served), never "now" and never another day's. No `computed_at` means no label and
the screen keeps its existing building or empty state. A day keeps its own date:
the label adds "30 Sep," when the row is not from today.

`AsOfHold` keeps the label up from the moment the day leaves the pass until the
screen's reload replaces the old row, so a row that is about to be replaced is
never passed off as fresh.

Reader shapes carrying `computed_at`: `getDaySleepV2`, `getDayHrv`,
`getDayStress`, `getChart` (the newest day's `day_result` time) and `getInsights`
(the cross-day rollup's write time); Home reads `status.overnight_computed_at`
and `status.activity_computed_at`.

Screens that compute on open (MetricDetail journal insights, Wellness insights and
weekday effects, Beats corrected RR, a past workout) keep their last good result
in `LastResultCache` (32 entries, least recently used out first, process
lifetime). A re-open shows it at once with `AsOfLabel(cachedAt)`, recomputes in
the background, and swaps in the fresh result, which clears the label. An error
is never cached.

## Scheduling

How a day is judged "changed". `input_rev(bucket, rev)` counts writes per 15-minute
bucket of `rec_ts / 900`. SQLite triggers on `decoded_onehz` and `decoded_rr` (insert,
update, delete) bump it, so every write path is covered, including in-place replaces
and RR-only changes. A day's fingerprint is `MAX(rec_ts):COUNT(*):REVSUM`, REVSUM being
the sum of `rev` over the buckets the local day spans, taken from `localDayStartSec` /
`localDayEndSec` (DST-safe). The engine folds in the profile and the previous day's
fingerprint (`deriveFingerprint`). The first pass after the upgrade sees every day as
changed once; no output changes.

What a pass reports. `DerivationEngine.run` still returns the day count, and records
`lastOutcome` (`DeriveOutcome`, also `snapshot()['last_outcome']`):

- a pass-level error: `failed`, with the error;
- a call refused because another pass holds the engine: `failed`, error `busy`;
- a day skipped for a transient reason (timeout, error): `transientFailures` + 1;
- a structural skip (budget exceeded, no bounded window): not a failure, its fingerprint
  is recorded on purpose.

`complete` means no failure and no transient skip. A transiently failed day records no
fingerprint and keeps no complete `day_result`, so it stays prune-pending (AGENTS.md
3.9) and the next `changedOnly` pass takes it again.

What the scheduler does with it. The callback returns a `DeriveOutcome`. Complete: the
job is deleted. Anything else, or a throw: the job goes back to `queued` with
`next_run_at = now + 30 s * 2^(attempts - 1)` (capped at 15 minutes), the error as its
reason, attempts kept. After 5 attempts it is parked as `failed` and stays in
`compute_jobs`. The scheduler arms a timer for the earliest not-yet-due retry; a job
still backing off is not counted in `pendingLight` / `pendingHeavy`.

Enqueue. `enqueueDeriveJob` dedupes against QUEUED jobs only: a light request is
absorbed by a queued light or heavy, a heavy by a queued heavy (and drops queued
lights). A running job never absorbs a request, so data stored mid-run gets one
follow-up pass, and at most one per type waits in the queue. A job that is waiting out
a retry backoff is a queued job, so it absorbs requests too.

Automatic passes. The scheduler's light pass runs with `changedOnly: true` and skips
days whose fingerprint has not moved; heavy keeps `changedOnly: false`. A light pass
that finds nothing to do stops before the post-derive work, as a manual sync does. Edits
that are not decoded input (sleep override, nap edit, phone steps) recompute through
`_reanalyzeForOverride` (`force: true`), which `changedOnly` never skips.

## Artifacts

A slow screen read is an artifact: its result is stored in `last_result` under a key,
together with `input_sig`, the signature of the inputs it was computed from (schema 60,
nullable, NULL for every older row). A stored row whose signature equals the current one is
fresh: the screen shows it with no recompute and no "As of" label. A stale or missing
signature behaves as described under How "As of" works: show the stored result under "As of", recompute once, store
the new result under the signature that was read first.

Keys and what moves their signature (`LocalRepositoryImpl.artifactSignature`, a few indexed
reads, never a payload decode; it always starts with `kAlgoVersion|`; null when nothing can
be keyed):

- `journal_insights|90d`: day results and journal rows in the window, and the window start.
- `weekday_effect`: the day results.
- `circadian`: today's label and the cross-day baseline's `updated_at`.
- `beats|<night day>`: the decoded fingerprint of the night's day and the evening before,
  and the day's `day_result.computed_at` (the sleep window).
- `workout|<id>`: the session's revision, the decoded fingerprint of every day the window
  (plus ~205 s of recovery) touches, and a stamp of the profile.
- `kcal_minutes|<day>`: the day's decoded fingerprint and the calorie anchors of the
  profile. Null when the day has no decoded raw.

`computeArtifact(key)` is the producer: the same map the matching reader returns, with the
heavy part (RR correction, rank statistics, permutation test, substrate load) off the UI
isolate. Screens and the warmer both go through it and `LastResultCache.loadArtifact`, so a
warmed row and an on-open row are one thing.

The warmer (`lib/state/artifact_warmer.dart`) runs after a derive pass that computed days,
never after one that computed none. It walks the candidate keys one at a time (the five
readers, the newest night, the workouts that start on a changed day, and the calorie curves
below), skips every key whose stored signature is current, stores the rest, and logs and
skips a failure. It holds while a workout, breathing session or ECG capture is live or the
derive scheduler holds: the rest of the pass is dropped, not queued. Dispose cancels it.

### Intraday calories (`kcal_minutes|<day>`)

`Calories.minuteEnergy` is `dailyEnergy`'s computation, one record per minute. Edge now
persists it per day. The payload:

    {v: 1, basal_kcal_per_min, covered_minutes,
     minutes: [{t, total, active, basal, source}]}

`t` is the epoch second of the minute, ascending, one record per minute from the day's first
to its last wake minute. `source` is `hr`, `cadence` or `rest`. A minute nobody measured (a
gap in the data, or inside the sleep window) has every figure null: gaps stay gaps and are
never interpolated. `basal_kcal_per_min * 1440` is the day's basal and `total = basal +
active` on a covered minute.

The minutes are built from the inputs the day's calorie pass uses (`lib/compute/
kcal_minutes.dart`): the per-minute mean of the seconds with HR above zero, minus the sleep
window; `estimatedMaxHr(age, family)`; the nocturnal resting HR or the one the user entered;
the credited step spans for cadence. A gap minute is passed with HR 0 and its cadence
masked, because `dailyEnergy` never sees it. So the sum of `active` is the day's stored
`calories` (without the workout-gap credit, which has no minute). No calorie anchors, no
height, no resting HR, no wake HR or no motion minutes: no series, and no row.

Where it is built. For a day derived from here on, inside the offloaded second half of the
derive (`_computeDayBlocks`, in the isolate), and stored after the day's own row commits,
under the signature of the fingerprint read before the substrate was. A failure is logged
and never fails the derive. A re-derive replaces the row; a day whose raw exists but whose
curve is now null (say the height was removed) loses its row, so a curve never outlives the
figure it explains. For a recent day derived before artifact signatures were stored, the warmer builds it from the
substrate (`DerivationEngine.kcalMinutesForStoredDay`: the stored day's sleep window and
resting HR, the same loader, `Isolate.run`) while raw lives, about `rawRetentionDays`. A day
past retention has no raw, no signature and no curve.

Reader: `LocalRepository.getDayCalorieCurve(day)` returns `{minutes: [{t, total, active,
basal}], basal_kcal_per_min, covered_minutes, computed_at}` or null. It reads the row. No UI
uses it yet (the Explorer will). `kAlgoVersion` is not bumped: no existing output changed.
