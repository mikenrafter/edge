# Calculation timing and "As of" (8AG-perf P1 / P1b)

## What P1 measures

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

## P2 scheduling

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
