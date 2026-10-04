# Controls, alerts, sources, gestures, and wake implementation roadmap

Date: 2026-09-30  
Design: `docs/superpowers/specs/2026-09-30-controls-alerts-and-wake-design.md`

This is an execution plan, not one large refactor. Each phase must leave the app
shippable, preserve the history-sync invariants, and include tests for absent
data and failure paths.

## Phase 0 — Safety, capability inventory, and reproducible tooling

### Scope

1. Keep `main` based on current upstream unless an explicitly experimental
   branch is selected. Record the reviewed commit in implementation notes.
2. Use the Nix shell pinned to the same Flutter version as CI: Flutter 3.41.6,
   Dart from that SDK, JDK 17, Android platforms 34–36, build-tools 35.0.0,
   NDK 28.2.13676358, and CMake 3.22.1.
3. Run the sibling-pin guard before dependency resolution. Never commit a lock
   file rewritten to local path dependencies.
4. Inventory capabilities by band generation: native RTC alarm, alarm
   confirmation/readback, live haptic, firmware double tap, high-rate IMU,
   worn state, and safe background wake behavior.
5. Add `FOOTGUN(...)` classifications and generate/maintain a test inventory of
   all risky opcode definitions and call sites.

### Likely files

- `flake.nix`, `flake.lock`, `Makefile`, `scripts/emulator-install.sh`
- `lib/ble/ble_engine.dart`, `lib/ble/adapters/gatt_link.dart`
- protocol capability adapters and their tests
- `docs/` capability matrix

### Gates

- `nix develop --command edge-fhs flutter --version` reports 3.41.6.
- Only the SDK's platform-tools provides `adb`.
- `make check` matches CI's serial test execution.
- Linux validates Flutter/Android/Linux. iOS and watch/widget targets have a
  separate macOS/Xcode gate; Nix on Linux cannot replace it.
- Existing ACK-order, dangerous-opcode, and generation-wiring tests pass.

## Phase 1 — Sync controls and honest manual sleep

### Scope

1. Add a persistent **Sync now** control and shared `SyncPresentationState` to
   Home/status and primary band detail.
2. Make pull-to-refresh call sync when connected and expose the same state. An
   offline refresh may reload local data but says it did not contact the band.
3. Add **Recalculate this night** to Sleep, including the no-night/empty state.
4. Keep **Rebuild all history** in Advanced with cost warning and confirmation.
5. Replace silent sleep-override returns/catches with typed results and visible
   errors. Coalesce concurrent reanalysis rather than dropping the request.
6. Load the union of automatic and asserted sleep ranges. Persist a valid
   boundary even when metrics abstain.
7. Add the explicit “This night only” / “Use this schedule going forward”
   choice and `ExpectedSleepSchedule` used by future collection/wake planning.

### Likely seams

- `lib/state/app_state.dart`: `syncNow`, sleep override orchestration, typed
  operation state
- `lib/ui2/screens/home_screen.dart`
- primary band detail under `lib/ui2/`
- `lib/ui2/screens/sleep_detail.dart`
- `lib/compute/derivation_engine.dart`
- `lib/data/db.dart` and a small schedule model/repository seam

### Tests

- Sync state transitions: offline, connect, drain, derive, success, timeout,
  disconnect, retry, and repeated tap.
- Every busy latch resets in `finally` and give-up paths.
- Atypical cross-midnight and daytime sleep overrides persist.
- Manual-to-manual edit succeeds without relying on a source-label change.
- Missing samples preserve boundaries and return absent metrics.
- Future schedule changes pre-arm the correct local-time window across DST;
  one-night corrections do not alter it.

### Exit criteria

No refresh affordance is merely a local reload without saying so. A user can
set an unusual sleep interval, retain it, understand missing metrics, and make
the interval a future expectation when desired.

## Phase 2 — Typed alert rules and one delivery path

### Scope

1. Introduce `AlertRule`, destination bit set, execution mode, explicit
   fallback, stale deadline, replay policy, and channel policy.
2. Add a capability registry that supplies the UI label and enabled state for
   each destination/execution combination.
3. Add a single `AlertDispatcher` for phone emission and band haptics.
   `NotificationCenter.emit` remains its only phone-notification emitter.
4. Migrate notification booleans, HR-zone haptics, reminders, and alarm-facing
   delivery settings through versioned, idempotent preference/schema adapters.
5. Enforce no implicit phone fallback, no stale reconnect buzz, per-action
   historical replay, and atomic dedupe.

### Migration defaults

- Preserve whether each existing preference is enabled.
- Preserve its currently observable destination where that can be determined.
- Do not enable a new destination during migration.
- Band-only remains band-only; it does not acquire phone fallback.
- Mark moment defaults replay on after the user selects it. Other actions
  default live-only.

### Tests

- All four destination combinations round-trip.
- Unsupported targets are rejected by policy, not silently changed.
- Delayed live-only alerts expire before reconnect.
- Concurrent dispatch cannot double-fire.
- No call site reaches `NotificationService.presentEvent` directly.
- No band-buzz call site bypasses `AlertDispatcher`, except named alarm
  transport primitives below the policy layer.

### Exit criteria

Every user-facing alert can state destination, execution dependency, fallback,
staleness, and replay behavior from one model.

## Phase 3 — Stable alert UI and native Android relay

### Scope

1. Rebuild Alerts as stable groups/accordions: Alarms & Wake, Health, Activity,
   Reminders, Device, and Android Relay.
2. Use one destination picker for Off, Phone, Band, and Both, followed by the
   capability label (“works without phone” or “phone must be connected”).
3. Keep disabled sections in place when their presence teaches the model. Omit
   platform-irrelevant sections entirely.
4. Replace `notification_listener_service` with an app-owned Android listener
   bridge exposing category, package, stable-key hash, post/remove time,
   interruption match, current filter, ringer mode, ongoing/group flags,
   channel importance, and readable haptic metadata.
5. Implement separate App notifications, Alarms & timers, and Calls channels.
6. Add per-app choices only to App notifications. DND, Vibrate, Silent,
   only-when-worn, and quiet-hours policies live once per channel.
7. Alarm/timer haptic matching is opt-in. Use Android's pattern when readable;
   otherwise use the user's alarm fallback pattern and disclose the fallback.
8. Calls are opt-in, respect DND by default, and have an explicit override.

### Android policy matrix

For every relay channel, test:

- DND off/on × respect/override.
- Ringer normal/vibrate/silent × channel choice.
- Band connected/disconnected × fallback choice.
- Worn/not worn/unknown.
- New post/update/removal with the same stable key.
- Alarm, timer, system call, and a VoIP app that correctly uses call category.

### Privacy and lifecycle tests

- Dart never receives title or message body.
- Listener reconnection restores policy without replaying stale entries.
- Service destruction and permission revocation clear latches.
- Android screen contains no iOS-only explanatory copy.

### Exit criteria

Users can predict exactly when phone and band will alert. Alarm/timer and call
relay behavior follows the selected channel policy without altering system DND.

## Phase 4 — Source catalog, identity, priority, and resolved-data view

### Proof to retain

Retain a two-device SQLite fixture and its resolved intervals before and after
reordering. Capture the source catalog and resolved rows in light/dark mode at
1×/2× text scale using headless Flutter widget tests. Record the selected
source IDs and unchanged historical rows in machine-readable test output.

### Scope

1. Add a full Source Catalog before the resolved/fused detail screen.
2. Model source identity, capabilities, collection behavior, permissions,
   coverage, last seen, limitations, and current uses.
3. Show priority controls even without present contention. Reorder by signal,
   not one global list where sources provide different kinds of data.
4. Add resolved-data rows with winner, alternatives, agreement, reason, and
   overlap/gap timeline.
5. Explain the prospective consequence before saving a priority change.
6. Apply changes to current/future computation by default. Keep historical
   rebuild as a distinct Advanced action.

### Tests

- Stable identity distinguishes two devices of the same model without exposing
  a full identifier.
- Partial overlap selects the right owner per interval.
- Missing/thin source data abstains instead of manufacturing continuity.
- Reordering changes current/future resolution only.
- Explicit historical rebuild uses the new priority and remains idempotent.
- No read seam performs analytics computation.

### Exit criteria

A user can tell what every source contributes, which source won each contested
signal, why it won, and what changing order will affect.

## Phase 5 — Timestamp-correct gestures and multi-action mappings

### Proof to retain

Replay delayed, duplicate, fractional-time, and out-of-order events through the
production event dispatcher in headless tests. Retain input frames, expected
stored timestamps, and action outcomes. Physical tap classification needs
labeled real-band recordings and measured error rates; widget captures cannot
establish classifier accuracy or battery cost.

### 5A: ship the reliable capability

1. Replace the positional `EventSink` callback with an event value object that
   includes `eventId`, `tsEpoch`, `tsSubsec`, receive time, and raw diagnostics.
2. Preserve full source time through DB persistence and action dispatch.
3. Make double-tap actions a set/bit mask with deterministic ordering and
   isolated failures.
4. Use event time for Mark moment. Store receipt time separately.
5. Expose historical replay per action, with Mark moment on by default once
   selected.

Tests cover delayed delivery, out-of-order receipt, duplicate event IDs,
fractional timestamp conversion, one action failing while others run, and local
day assignment near midnight/DST.

### 5B: physical one-through-four tap capability spike

1. Capture labeled 100 Hz IMU windows across supported band generations and
   wear positions without persisting live streams in production.
2. Implement the classifier and confidence/abstention contract in Analytics.
3. Measure false positives during normal motion, classification latency, radio
   duty cycle, battery impact, disconnect frequency, and background survival on
   Android and iOS.
4. Decide separately for ambient mode and already-live workout/session mode.
5. Only after the gate passes, expose rows for one, two, three, and four taps.
   Unsupported modes show the true limitation; they do not map repeated
   firmware double taps under misleading names.

### Exit criteria

Firmware double tap is timestamp-correct and supports multiple actions. Physical
tap-count mappings ship only on a measured, capability-gated path.

## Phase 6 — Split Smart Wake into Natural Wake and Gradual Wake

### Proof to retain

Replay held-out nights through the causal Analytics API, retain evidence age
and each decision trace, and test all windows and failure paths without an
emulator. Capture the four UI configurations and DST schedule cases. Confirm
native alarm firing on each claimed generation with real hardware. Retain
separate Android and macOS/iOS background-execution results.

### 6A: analytics prerequisite

In `OpenStrap/analytics`, define and validate a causal stage API:

```text
observe(sampleWindow, priorState) ->
  stage: wake | nrem | rem | absent
  confidence
  evidenceAge
  nextState
  abstentionReason
```

It must use only past/current evidence, tolerate incremental replacement, and
remain deterministic under replay. Validate against held-out recorded nights
and report false-trigger/late-trigger behavior. Do not market it as clinical
polysomnography.

### 6B: Edge orchestration and storage

1. Replace `smart_window_minutes` conceptually with independent
   `natural_window_minutes` (0–120, 15-minute steps) and
   `gradual_window_minutes` plus gradual pattern/cadence.
2. Preserve existing alarm settings during additive/idempotent migration. Do
   not silently enable Gradual Wake. Existing Smart Wake users see an upgrade
   explanation before the new estimated-REM behavior becomes active.
3. Start high-frequency collection and isolated processing early enough to
   establish stage history before `T-N`; the present 90-minute lease is not
   automatically sufficient for a 120-minute window plus warm-up.
4. Apply Natural Wake only to the configured main sleep. Naps are ineligible.
5. Run Natural and Gradual schedules independently as defined in the design.
6. Keep the fixed native band alarm at `T` in every configuration.
7. Record the decision trace: samples current/stale, stage/confidence,
   suppression reason, haptic request/result, and fallback arm confirmation.

### Tests

- Four configurations: neither, Natural, Gradual, both.
- Every Natural window from 15 through 120 minutes.
- No REM candidate, low confidence, missing HR/accel, off-wrist, disconnect,
  late background execution, app death, and phone reboot.
- Main sleep versus nap.
- DST spring/fall and travel/time-zone changes using local alarm schedule and
  absolute sample timestamps.
- Early haptic never disarms `T`; only explicit acknowledgement may request it.
- Failed cancellation leaves the native fallback armed.
- Heavy inference does not execute on the UI isolate.

### Exit criteria

The UI shows separate Natural and Gradual controls and an exact timeline. Live
estimated REM is available before the decision window or Natural Wake honestly
abstains. The native must-be-up-by alarm remains the safety net.

## Phase 7 — Hardening, rollout, and removal of legacy paths

### Proof to retain

Archive analyzer output, serial Flutter JSON test events, native JVM test
reports, widget PNGs, and a manifest containing tool versions and source
hashes. List skipped checks with their missing fixture/platform requirement.
Repeat the same capture after copy changes. Release evidence must identify
which hardware and OS combinations were actually exercised.

### Scope

1. Feature-flag the alert dispatcher, native Android relay, source resolver UI,
   physical tap classifier, and Natural Wake separately.
2. Test gen4, gen5, and MG/capability variants; Android supported API levels;
   and iOS behavior where applicable.
3. Add failure injection for BLE disconnect, write timeout, duplicate event,
   clock skew, corrupt frame, DB failure, background kill, permission loss, and
   process restart.
4. Confirm all new latches use `try/finally` and every operation has a timeout
   and give-up state.
5. Audit day labels, DST arithmetic, absent inputs, repeated derivation,
   notification dedupe, direct emit/buzz bypasses, and isolate boundaries.
6. Remove old preference/UI/dispatch paths only after migrated-state and rollback
   tests pass.
7. Run accessibility, localization, text scaling, dark/light, and stable-layout
   golden tests for the affected screens.

### Release gates

- Full `flutter analyze` and serial `flutter test` on Flutter 3.41.6.
- Android emulator plus real-device relay matrix.
- Real-band tests for every claimed native capability and generation.
- macOS CI/manual pass for iOS, WidgetKit/watch, and background behavior.
- No change to ACK ordering, raw retention, dangerous-write blocking, or
  generation decode wiring.
- Any analytics output change has a justified `kAlgoVersion` bump and verified
  sibling pin.
- Rollout telemetry is opt-in and contains no notification content or health
  samples.

## Explicit non-goals

- No generic cross-source metric fusion copied from Noop.
- No claim that firmware provides single/triple/quadruple taps until protocol
  evidence exists.
- No continuous live-stream persistence.
- No phone fallback that the user did not select.
- No replay of stale time-sensitive haptics.
- No Natural Wake for naps.
- No removal of the fixed native must-be-up-by alarm.
- No raw-command, reboot, force-trim, firmware-load, or unsafe debug UI.

---

## Phase 8 — UX addenda (2026-10-02)

Added after phase 5A shipped. These run **before** 5B/6/7 because the user is
testing the app live on a band. Each workstream follows the same rules as the
phases above: shippable on its own, absent data shows "—", no new direct band
buzz outside `AlertDispatcher`, live streams stay RAM-only.

Proof for every workstream: red tests first, then green; headless proof PNGs
under `test/proof` (light/dark, 1×/2× text) with committed baselines; emulator
screenshots of the same screens via `make install-emulator` + `adb exec-out
screencap`, saved under `screenshots/phase8/`.

### 8A — Flatter navigation

Today Band notifications sits four pushes deep (Profile → Settings →
Notifications → Band notifications) and Gestures three. Target: **every
setting is at most two pushes from Profile home**, and the most-used controls
are one push away.

1. Settings (`MoreSettings`) shows every group as a `SettingsAccordion`,
   expanded by default.
2. Band notifications, Gestures and Alarm get direct rows in Settings' "The
   band" group. Notifications keeps its row; its band-relay row stays as a
   second entry, not the only one.
3. Profile home gets a **Live devices** row (8B) in Quick access.
4. Write `docs/navigation-depth.md`: one row per settings screen with its
   push path before and after.

Test: a widget test pumps Profile home and walks each listed destination by
tapping rows; asserts depth ≤ 2 for every settings screen in the table.

### 8B — Live devices screen

A screen listing every connected device (the band plus any paired BLE sensor)
with a graph of the **last 30 s** of data each one streamed.

- One card per connected device: name, kind, connection state, battery if known.
- **Every data stream of every device gets its own graph** — HR, RR
  intervals, IMU axes (accel x/y/z, gyro x/y/z), skin temp, SpO2/PPG,
  battery, and any paired sensor's streams. A new stream kind shows up as a
  new graph without a UI change: graphs are built from whatever stream keys
  the device reported. X axis is the last 30 s of wall time.
- Buffer: a 30 s ring buffer in memory, fed from the existing live callbacks.
  Never persisted (invariant 14). Samples older than 30 s drop off.
- A signal with no samples in the window shows "No data in the last 30 s",
  never a flat line at zero. A disconnected device shows its last-seen time
  and no chart.
- The chart is scrubbable (8F).

Tests: ring buffer eviction at exactly 30 s; out-of-order sample drop;
no-sample state; disconnected state; source guard that the buffer has no DB
writer.

### 8C — Sections for every settings list

Every settings screen that shows a list of configurable settings is split into
named `SettingsAccordion` sections, **expanded by default**, like Band
notifications. Covers at least: Settings, Notifications, Band notifications
(its three channel accordions become expanded), Alarm, Gestures, Automation,
Data, Device detail, Edit profile. Section headers never move when a setting
inside another section changes.

Test: each of those views, pumped headless, has ≥ 1 `SettingsAccordion` and
every accordion starts expanded.

### 8D — Per-notification buzz sequences

Every notification type (each `AlertRule` with a band destination, and each
per-app relay entry) can choose its own buzz sequence.

Encoding: `BuzzSequence` = list of onset offsets in ms from the first buzz,
e.g. `[0, 500, 1000]`. 1–8 buzzes, offsets strictly increasing, each gap
150–2000 ms. Stored as JSON on the rule / per-app relay entry; absent means
the default below. Additive, idempotent migration.

Defaults: rule types in their stable registry order take
`(count, gap)` from `[1,2,3] × [500,1000,1500] ms`, count-major
(1×500, 2×500, 3×500, 1×1000, …), wrapping after nine. Per-app relay entries
default to the App notifications channel's sequence.

Recorder: a "Tap your pattern" button. The first tap starts recording and
buzzes the phone; each tap appends its offset. **2 s without a tap ends the
recording.** More than 8 taps ends it at 8. Then it plays back on the band if
connected (labelled "phone must be connected"), with Save / Record again.

Playback: one `AlertDispatcher` delivery plays the whole sequence; each step is
the existing single buzz (gen5 plays its fixed waveform per step). The band
transport reports success only if every step was written; a disconnect mid-
sequence stops further steps.

Tests: JSON round-trip and rejection of bad sequences; default assignment
order; recorder ends after 2 s idle and at 8 taps (fake clock); playback
schedules steps at the right offsets and stops on disconnect; dispatcher still
claims once per (rule, event, target).

### 8E — Sleep window without data

The user can always set a sleep window — from Settings (expected schedule)
and from any night on the Sleep screen, including nights with no recording.

- Saving never depends on samples existing. The window persists and shows as
  "You set this window".
- Where the samples do not cover the window, every sleep metric for that
  night is blank ("—"), not zero.
- Any calculation that depends on sleep (sleep baselines and averages, sleep
  debt, consistency, readiness's sleep input, trends) treats that night as
  **not recorded for that metric**: it is skipped, not counted as 0 h, and it
  does not shorten or reset a streak by itself.
- If this changes derived output, bump `kAlgoVersion` with a changelog entry.

Tests: set window on a no-data night → persisted, metrics null; 7-night
average over 6 real + 1 blank night equals the 6-night average; readiness
sleep input abstains for that night; repeated derivation keeps the same
result (idempotent).

### 8F — Every graph is scrubbable

One shared `ChartScrub` widget (built on `Scrubber`) wraps every chart in
`lib/ui2` outside the gallery: tap or drag places a vertical cursor line that
tracks the finger and a readout pill with the value and time at that point,
like the hypnogram. Scatter and grid charts (Poincaré, heat map, month grid)
select the nearest point/cell instead of drawing a line. A position with no
data reads "No data here", never an interpolated value.

Test: a source guard that every `painter: <ChartPainter>(` site in
`lib/ui2/{screens,activity}` and `live_hr.dart` sits under `ChartScrub` or
`Scrubber`; widget tests for the cursor/readout on a line chart, a bar chart
and a gap in the data.

### 8G — Day breakdown: collapse repeated taps

In the day timeline, a run of consecutive identical band events (double taps
first) with nothing else between them collapses into one row:
"You double-tapped the band · 5 times", which expands to the individual times.
A single tap stays a plain row.

Test: the pure grouping function on runs, interleaved events and singles; a
widget test for expand/collapse.

### 8H — Tap acknowledgement buzz

When the band reports a **live** double tap and at least one action ran, buzz
the band once so the user knows it was received. Late taps (`!isLive`,
drained from flash or held back), duplicates and taps where every action was
skipped get no buzz. The ack goes through `AlertDispatcher` as a band-only,
live-only rule with a short stale deadline, so a reconnect never replays it.

Tests: live tap → one ack; stale tap → none; duplicate → none; all actions
failed → none; ack is claimed once per tap identity.

### 8I — Device lab (5B exploration)

A "Device lab" screen under Device detail for exploring extended gestures on
the real band:

- A live log of band events: event id, event time, receipt time, delay, live
  or late, and which actions ran.
- A switch: **"Toggle ECG recording on double tap"**. When on, a live double
  tap starts an ECG capture and the band buzzes; the user then touches the
  sensor. The log records tap → capture-start delay and the capture result so
  the user can judge whether the sequence works.
- ECG needs a WHOOP MG. On any other band the switch is shown disabled with
  "This band has no ECG sensor". No continuous ECG.
- The switch is off by default and stored with the gesture settings.

Tests: switch disabled on non-MG; live tap with switch on starts exactly one
capture; late tap starts none; switch off starts none; log entries carry both
timestamps.

### 8J — Alarm screen as sections

Alarm & wake becomes `SettingsAccordion` sections, expanded by default:
Alarm (time, days, on/off), Wake (Natural Wake, Gradual Wake — phase 6),
Haptics (pattern, strength, buzz sequence from 8D), and Status (armed state,
last confirmation, band capability). Each section's detail lines are always
visible: a collapsed section still shows a one-line summary under its header,
and an expanded one shows every row, disabled where not applicable (8K).

### 8K — Disable and dim, never reveal

Anywhere in the app a setting row appears only when another setting is on
(hidden → visible), it is instead **always shown, disabled and dimmed** while
it does not apply, with a short reason when the reason is not obvious. This
covers alarms and notifications and every other screen. Platform-irrelevant
rows (iOS-only on Android) are still omitted, per phase 3.

Tests: a source guard that flags `if (<setting>) <Row>(` style conditional
rows in settings views (allow-list documented for platform gates and
permission cards), plus widget tests on Alarm, Notifications, Band
notifications and Gestures that a dependent row is present and disabled when
its parent is off.

### 8I note — what the extended gestures say

The Device lab and the Gestures screen both state plainly that ECG on double
tap needs a WHOOP MG, that WHOOP 4.0 has no ECG sensor, and that the 3–5
tap rows are a draft to try in the Device lab first. (5B's IMU tap
classifier was dropped in favour of 8L, so nothing waits on a measurement.)

### 8L — Draft 3–5 tap gestures (ECG contact counting, WHOOP MG only)

Firmware gives a double tap and nothing else, so taps 3–5 are counted as
**touches on the ECG sensor** after the double tap. Tap 1 is not offered.
This is a draft behind the Device lab and the Gestures screen, MG-only; on
WHOOP 4.0 the rows are shown disabled with "This band has no ECG sensor".

Terms (all times measured on ECG sample time, not phone receipt time):

- **contact**: ECG lead-on / nonzero signal. **Engage** = 200 ms of
  continuous contact. **Release** = 200 ms of continuous no-contact; contact
  that returns inside those 200 ms is the same touch.
- **max** = the highest tap count the user has mapped (2–5).

Sequence after a live firmware double tap (count = 2):

1. Start the ECG stream at once, and acknowledge with two buzzes.
2. If max = 2: done, run the 2-tap actions. No wait.
3. Otherwise open a 300 ms window from the end of the acknowledgement.
   No contact starts in it → confirm with one buzz, run 2-tap actions.
4. Contact starts in the window and becomes an engage → count = 3, one buzz.
   If count = max → run at once, no further wait.
5. The touch may last any time. On release, the user has a further 200 ms
   (200–400 ms after contact ended) to start the next touch. An engage that
   started in that window → count + 1, one buzz; at max, run at once.
6. No touch starts by 400 ms after contact ended → confirm with one buzz and
   run the actions for the current count.
7. Stop the ECG stream when the gesture ends. Nothing is persisted
   (invariant 14). A link drop or stream stall abandons the gesture with no
   action.

Examples (max = 5):
`2`: taptap · buzz buzz · 300 ms · buzz.
`3`: taptap · buzz buzz · touch < 300 ms · buzz · release · > 400 ms · buzz.
`4`: … release · touch 200–400 ms · buzz · release · > 400 ms · buzz.
`5`: … release · touch 200–400 ms · buzz (max, runs at once).

Adjustable windows (Device lab and Gestures screen, stored with gesture
settings). Each moves from its default −100 ms to +800 ms in 50 ms steps:

| setting | default | range | meaning |
|---|---|---|---|
| start threshold | 300 ms | 200–1100 | window after the ack for the first touch |
| gap threshold | 200 ms | 100–1000 | contact/no-contact must hold this long to count as engage or release |
| confirmation threshold | 200 ms | 100–1000 | extra window after a release for the next touch; no touch by gap + confirmation → final |

The tests above use the defaults; add tests that a changed threshold moves
each boundary and that out-of-range or off-step values are rejected.

Device lab: while its own **"Toggle ECG recording on double tap"** switch is
on, every normal gesture action is suspended; the lab runs this counter and
logs each step (contact edges, window outcomes, buzz send times, final
count) so the user can judge whether it works. Gestures screen: rows for
2, 3, 4 and 5 taps, the 3–5 rows marked draft.

Code: a pure `EcgTapCounter` state machine (inputs: ack done, contact
samples with sample time, clock ticks; outputs: buzz requests, final count,
abandon) in `lib/gestures/`, so the timing is testable without a band.
Buzzes go through `AlertDispatcher` as live-only band alerts.

Tests: each example above; max = 2/3/4/5; a contact blip < 200 ms neither
engages nor releases; re-engage at 199 ms vs 201 ms vs 401 ms after release;
link drop mid-gesture → no action; late (non-live) double tap never starts
the counter; lab switch on suspends normal actions.

### 8M — One sync control with real status

Home shows two sync controls today: the new `HomeSyncControl` ("Sync now"
plus a spinner) and the older status card's "Sync the band" button, which
reads a different busy flag (`syncingNow`). Merge them into one control
backed by `SyncCoordinator`, and replace the bare spinner with a status
panel:

- A step list: Connect → Download → Calculate → Done, each step showing
  its state (waiting, running, done, failed, skipped) and how long it took.
- Download: records received so far, chunks, and the "synced through"
  timestamp advancing as the drain commits, plus the backlog estimate when
  the band reports one. No made-up percentage when the total is unknown.
- Calculate: "day i of n" from the derivation engine's `onDayDone`, the
  day being worked on, and "waiting for another calculation to finish" when
  `_waitForDerivation` is blocking.
- Total elapsed time, the reason for a failure in plain words, and Retry.
- Each sync logs per-step durations (`[sync-timing]`) so a slow phase can be
  found in device logs.

Tests: coordinator publishes each step with timings; download counts
advance; derive progress maps onDayDone; waiting state shows; only one sync
control on Home; failure shows reason and Retry; latches reset in finally.

### 8N — Gesture ECG is never mistaken for a reading

Starting ECG for a tap gesture turns on the band's raw recording, so raw R16
packets from the gesture later arrive through ordinary history sync into
`ecg_raw_packet`. That is fine, and no sync is forced at gesture time. The
receiving side must label them:

- Each gesture session stores only its interval (device id, strap start/end
  seconds, final count or abandoned). No samples (invariant 14).
- When raw packets land, any packet inside a gesture interval is tagged as
  gesture contact (for example `ecg_raw_packet.origin = 'gesture'`, an
  additive, idempotent column), never linked to an `ecg_reading`.
- Every ECG consumer (readings list, reading detail, exports, Health export,
  coach views, any future raw-ECG analysis) ignores gesture-tagged packets.
- A packet that arrives before its gesture interval is known (a sync racing
  the session end) is re-tagged when the interval is written.

Tests: packets inside, at the edges of, and outside a gesture interval;
out-of-order arrival; a real reading next to a gesture keeps its own
packets; the migration is idempotent.

### 8O — Alarm edits are a draft; one band write per save

Today every row on the alarm screen calls `setScheduleDay`, which saves and
re-arms the band at once, so editing seven days (switch + time) can write
the band up to 14 times.

- The alarm screen edits an in-memory **draft** of the whole schedule,
  including Natural and Gradual settings. Nothing is saved or sent while
  editing.
- **Save** and **Cancel** sit at the top of the page. Cancel restores the
  last saved schedule. Save writes the whole draft to the DB in one
  transaction, then works out the next occurrence and writes the band **at
  most once** (one `SET_ALARM`, skipped when the band already holds that
  time; one `disable` when nothing is enabled), and waits for confirmation.
  The header then shows "Saved and sent to the band", "Saved — the band
  updates when it next connects", or the failure and a Retry.
- **Leaving** with unsaved changes (back button, system back, tab switch)
  opens a dialog: Save / Discard / Keep editing. Leaving while a save is
  still being sent to the band asks whether to wait or leave (the band then
  updates on the next connect).
- **Natural Wake and Gradual Wake are never written to the band.** They are
  phone-orchestrated: the phone sends a live haptic at the moment it decides
  to. Only the fixed must-be-up-by alarm at T is stored on the band.
- Outside the screen, band writes happen only when the stored occurrence
  must roll forward (after it passes, or on connect when the band holds a
  different time), deduped against the last confirmed arm.

Tests: editing all seven days then Save → exactly one band arm write;
Save with no effective change → zero writes; Cancel → zero writes and the
saved schedule restored; Natural/Gradual edits never call `setAlarm`;
leaving with a dirty draft shows the dialog and each choice does what it
says; offline save persists and reports the pending band update.

### 8P — Buzzes count when written; ECG taps wait for a steady stream (2026-10-02)

User report from a WHOOP MG: buzz previews said the band did not play them and
ECG tap sessions never counted. Cause: a buzz counted only on a correlated
SUCCESS reply that the band does not send for haptic writes.

- A buzz is delivered when its GATT write lands. The band's reply, if any, is
  logged, never required. Held presses: MG plays a hold of 500 ms or more as a
  repeated waveform; WHOOP 4.0 plays it as one short pulse.
- Delivery is complete / rejected / partial / unknown. Only "rejected" (nothing
  could have reached the band) releases the dispatcher's claim, so a stalled
  write can never turn into a second buzz.
- ECG taps: the two-pulse acknowledgement waits until packets are contiguous on
  the sample clock and advance with the wall clock (up to 20 s). The touch
  window opens at the acknowledgement mapped through the least-delayed recent
  packet. A sample gap never counts as contact or release.
- A start that completes after its session gave up stops only the stream it
  started. The stream stops before the gesture interval is written (8N).

### 8Q — Repeated double taps (every band)

A slower multi-tap that needs no ECG: each further live double tap inside the
pause (default 2500 ms, 1000–5000 in 250 ms steps) adds one and buzzes once.
Grouped by band time when the strap clock is believable. Every member tap is
claimed once. "Count extra taps with": ECG sensor touches (WHOOP MG only;
dimmed elsewhere) or More double taps. Both share one mapping store.

### 8R — Device lab log

Each line carries wall time (ms), time since the tap and since the previous
line, plus a session summary. Every ECG packet is logged with its continuity
and lag. "Copy all logs" sits at the bottom. RAM only.

### 8S — A corrected night is blank

"Not sleep" or a window the user sets leaves that night with no sleep numbers,
and it is excluded from every score and baseline from then on (readiness,
sleep need, trends, the sleep profile). The window itself stays shown. One
"Recalculate this night" control, inside the window card. kAlgoVersion 100.

### 8T — Chart values under the key

Scrubbed values sit in a row under the chart, in the key's columns, instead of
a tooltip. The heart-rate day chart's key: Movement (% of time moving), Heart
rate (bpm), Not recorded. "Not recorded" appears only when the window has gaps.
Live charts size their slots to each stream's rate.

### 8U — ECG taps: one clock, the count as the first buzz

From the 2026-10-02 lab log (WHOOP MG, start 500 / gap 200 / confirm 1000):
3 taps came only with a finger already on the sensor, and 4 almost never.

- A packet's strap time is its NEWEST sample. Read as the first, packets
  arrived ~0.8 s before their last sample existed and the short first packet
  looked like a 510 ms hole. Samples now run back from the packet time.
- One clock. The first window opens on the sample clock 2.5 s after the
  stream's first sample (the sensor reads 0 until then, even with a finger on
  it), not at a phone write time mapped across. Phone time only detects a
  stalled stream and paces buzzes.
- No acknowledgement buzz. The first window decides the first buzz: a finger
  there (already on counts) buzzes three times for 3; nothing by the deadline
  buzzes twice and ends at 2. Later taps buzz once; a count made final by a
  window running out gets one confirming buzz. A count final the moment it is
  buzzed (2, or the max) gets none extra.
- Buzzes are paced: none is asked for within 1.2 s of the last one finishing
  its write. In the log, a tap-3 buzz asked for 0.2–0.65 s after the
  acknowledgement never played; one asked for 1.06 s after did. Pulses inside
  one buzz stay 300 ms apart (the wearer feels both).
- "Extra sensitive subsequent tap detection" (Touch windows, off by default).
  Off: within one packet, first to last reading with signal is one touch (a
  zero crossing cannot break it; a lift inside one second is not a tap). On:
  every reading counts on its own.
- Deferred: opening the window on the band's own haptic-done event, and timing
  the next tap's window from the buzz instead of the release.

### 8V — Measure the band, then decide

The 18:17 lab run: four taps still failed in both contact modes. The log shows
why, and how much is the band's own behaviour:

- A returning finger shows on the ECG 1.96–2.16 s after the lift, at a fixed
  point of the packet cycle. The window after a lift now adds 1.5 s
  (`sensorReacquire`); replayed, the 18:19:10 session counts its fourth tap.
- Every three-pulse buzz lost its third pulse (no reply): the band takes two
  commands in a row and drops the rest while busy. Buzzes go out as pairs, the
  rest after 1.8 s.
- The ECG reading's own rules (give up after three lifts; RESTART when the S2
  state drops) no longer apply to a gesture.
- Device lab: every packet line shows the band's presence bit and S2 state; 3 s
  of stream after the count; each start stage timed; raw packets kept and
  copied for replay. Hardware probes: buzz spacing (asks what you felt) and a
  cued ECG touch script, both bounded and stoppable.
- Off the band: `replayTrace` over copied logs, and a virtual MG fitted to the
  logs. `docs/hardware/whoop-mg-haptics-and-ecg.md` keeps the evidence and the
  open questions.

### 8W — One command is one bzz-bzz; probe the patterns

The 20:40 lab log, with the band's events and the wearer's counts, corrects 8V:

- A buzz command plays as one "bzz-bzz". A command written while the band plays
  (until its event 100, 1.1-1.5 s) is answered "pending" and not played, and the
  band ignores the next one for about 1 s. 8V's bursts of two pulses were one
  played command and one swallowed one. A count of 2 or 3 is now 2 or 3 commands,
  each 1.8 s after the previous write (`maxPulsesPerBurst` 1).
- A touch shows on the ECG ~1.9 s after the finger lands, whatever the lift
  before it lasted, on a 100 ms grid; 300 ms taps never show; the presence bit is
  useless. This replaces 8V's "hold after a lift" fit. The window code is not
  re-tuned here (open question in the hardware doc).
- New in the Device lab (MG only): a pattern probe of 32 tests (4 waveforms x 4
  ways of sending x counts 2 and 3: separate commands paced or event-paced, one
  command with a loop count, one command listing the waveform several times).
  Bounded: at most 56 commands, 3 s rest after each test, Stop at once. It asks
  how many buzzes and how many groups you felt. It is meant to find out what the
  loop bytes and effect 152 do, and whether one command can count.
- The virtual band now swallows and ignores commands as the log shows, and shows
  touches after the ~1.9 s latency.
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md` (L3, superseded findings,
  open questions); `test/phase8/CONTRACTS.md` (8W).

### 8X — Block contact, quick start, ECG failure

- Contact is a moving signal in 50 ms blocks (a run of at least 100 ms, edges of a
  packet excepted), not "sample is not zero": a flat constant is no contact.
  Docs note a saturated trace would read as no contact.
- Two new Device lab switches, both on by default. Tolerant startup off decides a
  plain double tap from the first 49-sample packet when it shows no finger (about
  2 s sooner). Fall back to the double-tap action off retries the ECG once
  (before the touch window opened) instead of running the double-tap action.
- Whenever the ECG fails the band gives one long buzz, in every mode. With the
  fallback on and no touch counted, a failed ECG (a failed start included) ends
  as a plain double tap; a failure after tap 3 is abandoned.
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md` (Contact rule);
  `test/phase8/CONTRACTS.md` (8X).

### 8Y — The pattern probe becomes a transcriber

The 22:27 lab log (L4) showed the coarse "how many buzzes" answers cannot tell
what the band plays. The wearer now writes the rhythm down like morse.

- The Pattern probe button opens a screen. Play sends the test on screen, as often
  as wanted. The wearer taps buttons of length 1-4; entries alternate buzz, gap,
  buzz, gap (the first is a buzz) and the buttons read "Buzz 1-4" (solid bars) or
  "Gap 1-4" (hollow bars) for the entry they write. The entries are a wheel to scroll
  back and forward and edit; up to two renditions (A, B) per test; previous / next
  test; the 1-4 footer stays on screen. Leaving writes every transcription into the
  lab log.
- Plays are bounded and polite: at most 160 commands per session, each play waits
  for the band to finish the last one (live event 100 or 4 s). Only live band events
  count; the log showed old 60/100 events delivered late in bursts and event-paced
  commands released on them.
- 8 new gap tests (two separate commands, the second 0 / 300 / 700 / 1200 ms after the
  first one's event 100) and a measured `silences:` / `buzzes:` per play, so felt gap
  lengths can be fitted to real milliseconds. Goal: an encoder from a tapped rhythm
  to a band command.
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md` (L4 findings, the transcriber,
  open questions); `test/phase8/CONTRACTS.md` (8Y).

### 8Z — Notes and rests, tempo, metronome, replay march

The wearer wanted to write repeats and longer silences, and to hear the tempo.

- Entries are notes or rests of length 1-4, typed by a Note/Rest toggle that flips
  after every tap and can be overridden (two notes or two rests in a row are allowed).
  One unit is an eighth. Buttons and rows show the music symbol above one coloured
  dash per unit; rests are the same colours at a third of the saturation.
- A metronome dot next to Play steps once per unit through four colours with an
  outline between (8 steps to a 4/4 bar). "Dynamic tempo" (on by default) fits ms per
  unit from the measured plays; otherwise 250 ms.
- Replays march a playhead through the recorded entries at that pace, starting at the
  first write plus the measured Bluetooth lead; the wheel follows and returns to the
  cursor. A tap or scroll cancels it; the first listen (empty rendition) does not march.
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md` (units and tempo fit);
  `test/phase8/CONTRACTS.md` (8Z).

### 8AA — 16th notes and dynamics

The wearer wanted 16th notes and the dynamics ff, mf, mp and pp.

- The unit becomes a sixteenth (125 ms by default; a 4/4 bar is 16 steps). A fifth
  length button writes a 16th, beside eighth, quarter, dotted quarter and half
  (lengths 1, 2, 4, 6, 8 sixteenths). Dashes are one per sixteenth, coloured by the
  beat they fall in.
- Every note carries a dynamic from a sticky selector (default mf) above the length
  buttons; picking one with the cursor on a note changes that note. Rests have none.
  The log codes read "N4mf R2 N1ff".
- The metronome has 16 steps: the beat colour on each quarter, the same colour faint
  on each "and", dark between.
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md` (the 16th unit and the codes);
  `test/phase8/CONTRACTS.md` (8AA).

### 8AB — dotted notes, count-in, end screen, rolling limit

The wearer wanted dotted notes, a metronome that leads into Play, an end screen with
the log copy, and to know why buzzes stopped coming around test 22 (the probe's own
160-commands-per-session cap refused every play from test 20 on, silently).

- A Dot button next to the 16th, eighth, quarter and half buttons makes the next entry
  3/2 as long (3, 6 or 12 sixteenths: dotted eighth, quarter, half). The 16th is
  disabled while the dot is on.
- The metronome is off until Play, then counts in one measure, the band is asked one
  lead before the downbeat, the march starts on the downbeat, and the metronome stops
  one padding measure (to the bar line) after the play and march are done.
- Finish or back opens an end screen after the session closes: counts, tempo, lead,
  "Copy all logs" (same text as the Device lab) and Done.
- The per-session cap becomes 30 commands in any 2 minutes, kept across reopen. A
  refused play says why under Play ("Band resting, ready in N s", "Not connected",
  "Still playing"). A display of commands left and time to the next free one is blurred
  until tapped, and red under 5 left.
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md` (probes section);
  `test/phase8/CONTRACTS.md` (8AB).

### 8AC — device vocabulary, notes to commands, global band queue

The wearer wanted f and p dynamics, unstable probe rounds, the L6 results as a device
haptic profile, tapped rhythms turned into notes and then into real band commands, an
"extended haptics opset" toggle, and one queue so alerts and the lab cannot overlap or
overdrive the band.

- Dynamics ff, f, mf, mp, p, pp (codes `N4f`, `N2p`); an Unstable toggle that makes
  renditions A and B the shortest and longest; a trailing `R1 R2 R4` in an old log also
  means unstable.
- `lib/haptics/`: a profile of the WHOOP 5.0 MG (phrases and gaps from L6), a reader for the
  heard lines, the notes-to-commands compiler (cost, command penalty, 10 s cap), taps to
  notes, and the player. A saved rule stores its notes, the profile id and version and the
  baked plan; delivery plays the baked commands.
- The buzz editor shows what the band will play ("Plays as written." or what it plays
  instead) and has the "Extended haptics opset" switch, off by default.
- One band queue: FIFO, one job at a time, a start only when the ledger allows (30 commands
  per 2 minutes, shared with the pattern probe), a job that cannot start in time is
  rejected. Every band haptic path goes through it.
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md` (vocabulary, taps to commands);
  `test/phase8/CONTRACTS.md` (8AC).

### 8AD — Haptics hub, named patterns, notes editor, allow long sequences

The wearer wanted to name and reuse buzz patterns, write them as notes on the phone, lift
the 10 s cap on purpose, tap a baseline in the lab, and fold more logs into the vocabulary.

- A named pattern store (`haptic_patterns_v1`). Alerts and relay channels hold a snapshot
  of the pattern they picked, with its `patternId`; editing or deleting a pattern rewrites
  every snapshot in the alert rules and in the relay's channel and per-app sequences.
- Settings > The band > Haptics: Patterns (preview, edit notes, re-record, rename, delete),
  Safety (allow long sequences, the 30 per 2 minutes read-out, the queue), Test (buzz the
  band) and, in developer mode, Calibration (Device lab).
- The Buzz pattern rows in Notifications and Band notifications open a picker first:
  Default, the stored patterns, Record new (which can also save to the store) and Write
  notes (MG only).
- An advanced notes editor (the probe's entry model, one rendition, plays what is on the
  page). "Allow long sequences" lifts the 10 s cap everywhere, behind a confirmation.
- The probe can take a tapped baseline; a profile builder merges many heard logs and prints
  the diff against the table in code.
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md` ("Patterns and safety");
  `docs/navigation-depth.md`; `test/phase8/CONTRACTS.md` (8AD).

### 8AE — Settings by task, Developer area, quiet-hours override

The wearer found Settings long and its doors scattered: some rows were on Profile, the lab was
on the band page, and one feature had three names.

- Settings is grouped by task: Band, Alerts, You & preferences, Data & privacy, Connections,
  About, and Developer (dev mode). Profile keeps My devices and Settings; Live devices, Edit
  profile, AI coach, Language and Storage moved into Settings. Each has one door.
- Device lab moved out of the band's Tools to Settings > Developer (dev mode). Gestures lost
  the two tuning controls the lab already has.
- "Band notifications" is "App notifications on the band", with one entrance. "Band alerts" is
  "Band battery". The Alarm screen's Haptics group is gone; Wake says the alarm uses the
  band's own buzz.
- Each relay channel follows the quiet hours set in Alerts unless "Override quiet hours" is
  on, then its own Starts and Ends apply. Existing windows migrate to override on.
- Docs: `docs/navigation-depth.md`; `test/phase8/CONTRACTS.md` (8AE).

### 8AF — Health by question: Last night, Today, Trends, Labs

Health had five sub-tabs (Overview, Explore, Trends, Vitals, Labs) that mixed time scopes: one
night, the day so far and a month on the same page, and the fifth chip was clipped on a
phone. It is four sub-tabs now, one time scope each.

- **Last night**: one night, named by its date when it is not last night. Rows: Readiness,
  Sleep (opens that night), HRV, Resting heart rate, Respiratory rate, Overnight stress and
  Skin temperature ("vs your usual", with the SD unit explained). No sparklines or trend
  arrows. Then Observations, Daytime sleep, and the Heart Screener card (WHOOP MG only,
  through `Capabilities`) at the bottom. The illness card is one widget used by Home and Health.
- **Today**: Strain, Steps, Active minutes, Calories, Heart rate range and Wear time. Every
  row opens its detail.
- **Trends**: Body clock and Consistency, the three measures that compare against your own
  average (resting heart rate, HRV, sleep), then every other measure with a history in a list
  by family. Readiness and Stress are in the list now. A family with no history folds into one
  card, Breathing says why there is no SpO2, and each row opens its detail on 30 days
  (`MetricDetail.initialRange`).
- **Labs** is unchanged and no longer clipped.
- A sub-tab index remembered from the old order maps through `HealthScreen.tabFromLegacy`.
  Deep links and notifications land on Last night.
- Docs: `docs/navigation-depth.md` (Health); `test/phase8/CONTRACTS.md` (8AF). Tests:
  `test/health/`.

### 8AF.5 — Any-loudness notes, rhythm or dynamics, and an editor that follows the band

Three additions to the advanced notes editor, found while testing 8AE.5 and 8AF on the band.

- **`*`**: a seventh dynamics button. A note written `N2*` can play at any loudness; the
  compiler picks whatever serves the length best. The probe still offers six, and a probe log
  never records "any".
- **Prioritize rhythm / Prioritize dynamics**: when the band cannot play a pattern exactly,
  rhythm (the default) keeps the timing and dynamics keeps the loudness. It is saved with the
  pattern and used when delivery has to compile. Under the plan the editor names the notes that
  change ("Plays N4ff where you wrote N4mf").
- **Follow the playback**: the editor marches a playhead through the notes while the band plays,
  re-anchored on each command's start (the band's event 60, else the write time plus 300 ms). A
  preview the band has not started shows no playhead.
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md`; `test/phase8/CONTRACTS.md` (8AF.5).

### 8AF.6 — Built-in patterns, gesture cues, wake on the vocabulary, one home for the HR zone alert

Found testing 8AF.5 on the band: gesture responses were all double buzzes, and the band's measured
vocabulary was used only by patterns the wearer wrote.

- **Built-in patterns**: three gesture cues (start, follow-up, confirm) and one default per
  non-alarm alert rule are real patterns under "Built in", below "Your patterns" and a divider.
  The wearer can preview, edit, re-record and reset them; not rename or delete them. "Default"
  in a picker now means the rule's built-in, and it can be played from the picker.
- **Fastest selection, gesture cues only**: the start cue is the pair, each further pulse is the
  fastest single (`buzz14`) at the fastest gap (0 ms), the confirm is `buzz47`, all one band
  job. The alert defaults are today's rhythms, unchanged. A 4.0 keeps plain pulses at the old
  pacing (one per call, a quiet gap apart).
- **No extended mode**: the whole vocabulary is the only mode; unstable choices cost a little
  and are taken only when they fit better. Tap takes are `*` notes with rhythm priority, and
  "Edit as notes" opens the advanced editor on them.
- **Wake on the vocabulary**: gradual steps are `buzz14` (steady) or `click1` up to `buzz47x3`
  (ramp); Natural and Smart wake are three `buzz47x3`. Fixed in code, not configurable.
  RUN_ALARM stays for a 4.0 and when the plan cannot be written.
- **HR zone alert is an alert**: destinations, buzz pattern, target zone and a "Zone view"
  button, all in Alerts; the old Settings > Band rows are gone and the old on/off pref is
  migrated once (on becomes Band).
- Docs: `docs/hardware/whoop-mg-haptics-and-ecg.md`; `test/phase8/CONTRACTS.md` (8AF.6).

### Order

8G, 8H, 8D (dispatcher work) → 8E (analytics-facing) → 8F, 8C, 8K, 8J, 8A,
8B, 8I, 8L (UI). Then resume 5B → 6 → 7 where the remaining work does not need hardware
or the analytics repo; record what was blocked.
