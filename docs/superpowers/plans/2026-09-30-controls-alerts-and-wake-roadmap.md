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
