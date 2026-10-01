# Phase 4 red-phase contracts: sources

Tests live in `test/sources/`. They compile today. `sourcesContract()` /
`sourcesAsync()` (in `support/sources_support.dart`) catch only a missing
dynamically invoked member and fail naming it; they never supply policy. Every
owner, reason, agreement, suffix and consequence string comes from production
objects. Run: `nix develop --command edge-fhs flutter test test/sources`.

Reuse, do not duplicate: `HealthSource`, `SourceTier`, `declaredSignals`,
`signalWinners`, `bandLabelFor`, `LocalDb.signalPriority*`,
`LocalDb.coverageIntervals`, `resolveOwnership`, `priorityKey`,
`DerivationEngine.runDays`. `lib/sources/source_catalog.dart` must call
`signalWinners(` (source guard). Moving `HealthSource`/`signalWinners` into
`lib/sources/` with a re-export from `devices.dart` is fine; defining a second
`HealthSource` is not.

## Entry seams (all dynamic)

| Seam | Returns |
|---|---|
| `AppState.debugSourceService({required List<HealthSource> sources, DateTime Function()? now})` | production `SourceService` (reads `device`, `device_coverage`, `signal_priority`, `decoded_onehz` via `LocalDb`; no compute) |
| `AppState.debugSourceViews()` | production `SourceViews`: thin factory returning the real pure widgets |
| `DerivationEngine.rebuildHistoryWithPriority(Profile, {required Set<String> days})` | `Future<Map>` with `days` (List of rebuilt day ids) and `priorityKey` (String, the `priorityKey()` encoding in force) |

`now` is the clock for "current vs future vs history". Default in tests is
2026-09-30 12:00 local.

## SourceService

- `Future<List<SourceCard>> cards()` for the `sources` given at construction.
- `Future<List<ResolvedInterval>> resolve({required InputSignal signal, required int from, required int to})`
  epoch seconds, `to` exclusive. Intervals TILE `[from, to)`: first starts at
  `from`, last ends at `to`, no hole, no overlap.
- `Future<List<Map>> prioritySignals()`: one map per signal declared by at
  least one source, contended or not: `{signal: String name, order: List<String>
  deviceIds, contended: bool}`. `order` lists only devices that declare that
  signal; a stored order wins, otherwise the existing default. Never a single
  global list.
- `Future<void> savePriority(InputSignal signal, List<String> order)` rewrites
  only that signal's `signal_priority` rows (current and future computation).
  It never touches `day_result`, `metric_series`, `metric_series_version`, and
  never starts a derive.

All result objects expose `toJson()` returning the maps below; the tests read
only those.

### SourceCard JSON

Keys (all present, absent value is `null`, or `[]` for lists, never a
placeholder string such as `''`, `"null"`, `unknown`, `N/A`):

- `deviceId` String? (`''` primary band, minted id for sensors, `null` phone)
- `name` human name (`HealthSource.name`)
- `displayLabel` `name` or `name · identitySuffix` when a suffix exists
- `type` `band` | `sensor` | `phone`
- `model` from `bandLabelFor(adapter id)`; `null` when unknown
- `platformIdSuffix` last 4 or fewer alphanumerics of `device.remote_id`;
  `null` without a device row. The full remote id appears nowhere in the JSON
  or label
- `identitySuffix` a 4 to 6 character tail of the stable minted device id,
  extended only as far as needed to stay distinct among the given sources;
  independent of source order; `null` for the phone and for the primary band
  without a device row
- `signals` sorted `InputSignal.name`s from `declaredSignals(family)`
- `supplies` human lowercase labels for non-InputSignal supply; the phone
  contains `steps`
- `collection` `continuous` | `sampled` | `user-started` | `imported` |
  `derived`. Pinned: primary WHOOP band `continuous`, paired `ble_hrs` strap
  `user-started`
- `coverage` `null` or `{signalName: {start, end}}` (earliest start, latest end
  from `device_coverage`)
- `lastSeen` epoch seconds or `null`: latest of `device.last_seen` and
  `HealthSource.lastData`
- `permissions` list of tokens; BLE sources contain `bluetooth`, the phone does not
- `limitations` list of sentences; contains one mentioning `experimental`
  exactly when `HealthSource.experimental`
- `uses` list of `{signal, reasonCode, reason}` for signals this source is the
  current winner of. Reason codes: `onlySource` (one declaring device),
  `userPriority` (stored order non-empty), `defaultPrimary` (nothing stored,
  primary owns)

### ResolvedInterval JSON

`{signal, start, end, kind, winner, alternatives, agreement, reasonCode, reason, values}`

- `kind` `single` | `overlap` | `gap`
- `winner` device id or `null` (gap). A gap is never filled from a neighbour,
  even when one device covers both sides (the engine's single-device identity
  short-circuit must NOT be reused for the view)
- `alternatives` device ids that covered the interval and did not win
  (including a covering device excluded because no order is stored)
- `agreement` `single` (one source) | `agree` | `disagree` | `none` (gap, or
  overlap with no retained values to compare). Agreement never changes the winner
- `values` `{deviceId: mean}` of retained `decoded_onehz` hr over the interval;
  empty when pruned. Fixtures use 60 vs 61 bpm (agree) and 60 vs 85 (disagree)
- `reasonCode` `onlySource` | `userPriority` | `defaultPrimary` | `noCoverage` |
  `thinData`; `reason` non-empty deterministic text (same inputs, same JSON)
- Thin data: a covered stretch shorter than
  `kOwnershipHysteresisBuckets * kOwnershipBucketSeconds` (180 s) is
  `kind: gap`, `winner: null`, `reasonCode: thinData`. A thin stretch from a
  higher-ranked device does not beat a lower-ranked device with enough
- Contested intervals follow `resolveOwnership` (hysteresis included), so the
  view agrees with the engine. Tests sample well inside intervals and do not pin
  hysteresis boundaries

### Current/future vs history

Resolution of an interval before `now` that a derived day already covers uses
the order that day was derived under; later or undervived intervals use the
current stored order. How history is remembered (day stamp parse, epoch log) is
the implementer's choice; observable rules:

1. After `savePriority`, historical intervals are byte-identical and all
   persisted `day_result`/`metric_series`/`metric_series_version` rows are
   unchanged; future intervals follow the new order.
2. After `rebuildHistoryWithPriority`, the rebuilt day's stored bundle,
   `priority_hash` stamp, and `resolve()` all reflect the new order.
3. A second rebuild leaves rows identical (ignoring `computed_at`): one row per
   `(day_id, kAlgoVersion)`, same `metric_series`, no duplicate-day append.
   `rebuildHistoryWithPriority` forces re-derivation of finalized days;
   `savePriority` never does.

The reorder test writes `build/sources/priority_reorder_resolved_intervals.json`
(`EDGE_PROOF_DIR` overrides the directory): selected source ids before and
after, resolved intervals, and `historicalRowsUnchanged`. Deterministic: no
wall-clock values.

## SourceViews (pure widgets, no AppState inside)

Inputs are the JSON shapes above.

- `catalog({required List<Map> cards})`: one card per source showing
  `displayLabel`, type/model, signals, collection behavior (case-insensitive
  token), permissions, limitations, and every `uses[].reason` verbatim.
  Absent values render `—`; never `null`/`unknown`. No remote id, no full
  minted id.
- `resolvedData({required List<Map> rows, required Map<String,String> names})`
  `rows` are ResolvedInterval maps (any mix of signals); `names` maps deviceId
  to display label.
  - Row key `ValueKey('resolved-row:<signal>:<start>')` containing winner
    label, alternative labels, an agreement label (`agree`, `disagree`,
    `single`, and for `none` `no comparison`/`nothing to compare`/`—`), and the
    `reason` verbatim. Gap winner renders `—`.
  - Per signal `ValueKey('resolved-timeline:<signal>')` containing one segment
    per interval keyed `ValueKey('segment:<kind>')`.
- `priorityEditor({required List<Map> signals, required void Function(String signal, List<String> order) onSave, required VoidCallback onRebuild})`
  signal maps `{signal, order, labels: {deviceId: label}}`.
  - Section `ValueKey('priority:<signal>')` for every map, contended or not.
  - Move controls `ValueKey('priority-up:<signal>:<deviceId>')` (and `-down:`).
  - After a pending change, `ValueKey('priority-consequence:<signal>')` appears
    BEFORE saving; its text contains the prospective winner's label, the word
    `future` (current and future computation) and the word `history` (past days
    unchanged unless rebuilt). Per signal only.
  - `ValueKey('priority-save:<signal>')`: no-op without a change; otherwise
    calls `onSave(signal, newOrder)` once and never `onRebuild`.
  - A separate action labelled exactly `Rebuild history with this priority`.
    Tapping it shows `ValueKey('rebuild-cost')`; `onRebuild` runs only after
    `ValueKey('rebuild-confirm')`.

## Source guard (integration, not runtime proof)

`read_seam_guard_test.dart` checks that these files exist and that nothing under
`lib/sources/` or `lib/ui2/sources/` imports `compute/`, `openstrap_analytics`,
`derivation_engine`, `onehz_pipeline`, `crossday_pipeline` or `substrate.dart`:

- `lib/sources/source_catalog.dart` (must call `signalWinners(`)
- `lib/sources/resolved_data.dart`
- `lib/ui2/sources/source_catalog_view.dart`
- `lib/ui2/sources/resolved_data_view.dart`
- `lib/ui2/sources/source_priority_view.dart`

The rebuild lives in `DerivationEngine`, outside those directories, by design.

## Proof views

`proof_views_test.dart` renders `catalog` and `resolvedData` at 390 px width in
light/dark at 1x/2x text scale against `test/sources/goldens/<name>.png`
(`source_catalog_*`, `resolved_data_*`). Goldens are generated in the green
phase (`--update-goldens`); not in `test/proof/`.
