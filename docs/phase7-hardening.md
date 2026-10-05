# Phase 7 hardening: flags, failure injection, latch audit

Scope: the code the controls, alerts and wake roadmap added. This is the code
part of phase 7 only. Anything that needs a band, a phone or a Mac is listed at
the end under "Blocked".

Tests for everything below live in `test/phase7/` (144 tests). Run with
`flutter test --concurrency=2 test/phase7`. With `test/controls`, `test/gestures`,
`test/wake`, `test/alarm` and `test/phase8`, 1,206 tests pass. The full suite
was not run here.

## 1. Rollout flags

One tiny mechanism, `lib/state/feature_flags.dart`. No flag mechanism existed.

- Local only. A compile-time default (`--dart-define=OS_FF_<NAME>=false`) that a
  `SharedPreferences` value (`ff.<id>`) can override. No network, no remote
  config, no telemetry.
- Every flag defaults to ON, so behaviour today is unchanged.
- `FeatureFlags.load()` runs at launch (`main.dart`). Headless entries
  (`NotificationCenter.emit`, `background_sync`) call `ensureLoaded()` because
  they have no launch hook.
- A stored value of the wrong type, or storage that cannot be read, leaves the
  default.

| Flag (`ff.<id>`) | OFF does this | Where it bites |
|---|---|---|
| `alert_dispatcher` | `NotificationCenter.emit` delivers to the phone only, as it did before typed destinations. A rule that is disabled or does not select the phone stays silent, so turning the flag off never adds a phone alert. Fire-once still holds. Band haptics are not affected: every band buzz still goes through `AlertDispatcher`. | `notification_center.dart` |
| `native_relay` | `NotificationRelay.supported` is false: no listener armed, Android Relay UI hidden, the platform is told once to stop sending metadata. | `notification_relay.dart` |
| `source_resolver_ui` | No Source catalog or resolved-data entry. The priority editor shows only when two devices contend, as before the resolver UI. | `ui2/profile/devices.dart` (`showSourceCatalogEntry`, `showSignalPriorityEntry`) |
| `tap_classifiers` | A double tap is only a double tap. No ECG touch counting, no repeated-double-tap window, no lab modes; the mapped 2-tap actions run at once. The 3-5 tap rows, the extra-tap sections and the Device lab entry are hidden. | `gesture_dispatcher.dart`, `ui2/profile/gestures.dart`, `devices.dart` |
| `natural_wake` | Natural Wake is hidden and gets no window. The legacy Smart Wake heuristic and its collection window run, exactly as while an upgrade explanation is pending (`gateNaturalWake`). Gradual Wake and the native alarm at T are untouched. | `wake_controller.dart`, `wake_settings.dart`, `app_state.dart`, `background_sync.dart`, `ui2/profile/alarm.dart` |

Tests: `test/feature_flags_test.dart` (each flag ON and OFF, 27 tests).
There is no settings UI for the flags. They are set by a build define or by
writing the preference; a UI switch is a product decision.

## 2. Failure injection

Existing fakes were reused (`test/support/wake_fakes.dart`, the
`EcgTapSession` rig pattern, `MemoryAlertDeliveryLedger`). New fakes are small
test-local classes: a ledger, a wake state store and a trace store that can throw
or hang.

| Surface | Disconnect | Write timeout | Duplicate | Clock skew | Corrupt frame | DB failure | Restart | Permission loss |
|---|---|---|---|---|---|---|---|---|
| AlertDispatcher / buzz player | yes | yes | yes | yes | n/a | yes | yes | yes |
| Gesture sessions and dispatcher | yes | yes | yes | yes | yes | yes | yes | yes |
| Wake orchestrator | yes | yes | yes | yes | yes | yes | yes | yes |
| Alarm draft Save | yes | yes | yes | n/a (no clock) | n/a | yes | yes | yes (band refuses) |
| Native relay | yes | yes | yes | yes | n/a (metadata only) | n/a (no DB) | yes | yes |
| Sync presentation, derive scheduler | n/a | yes | n/a | n/a | n/a | yes | n/a | n/a |

Files: `dispatcher_failure_test.dart`, `gesture_failure_test.dart`,
`wake_failure_test.dart`, `alarm_draft_failure_test.dart`,
`relay_failure_test.dart`, `sync_latches_test.dart`,
`sleep_blank_inputs_test.dart`.

### Bugs found and fixed

Each has a test that failed before the fix (or, for new API such as a timeout
parameter, a test that could not have passed without it).

1. **AlertDispatcher: a throwing `ledger.release` escaped `dispatch`.** The
   exception came out of a `finally`, skipped the remaining targets and could
   reach `NotificationCenter.emit`. Release failures are now swallowed. The claim
   stays consumed, so the worst case is a lost alert, never a second buzz.
2. **`playBuzzSequence`: a step that never answered let the rest of the rhythm
   play late.** After the dispatcher gave up, a stuck write finishing later
   started steps 2 to 8. Each step now has a 5 s timeout and a timeout ends the
   rhythm.
3. **`EcgTapSession` had no timeout on the stream-start write.** A start that
   never answered left `_active` set, so every later double tap was ignored until
   the app restarted (an AGENTS section 4.3 latch). Now bounded (15 s); a late
   stream is stopped.
4. **`EcgTapSession`: a stuck database write kept the ECG stream running.** The
   interval is written before the stream is stopped. The write is now bounded
   (5 s), as is the stop.
5. **`EcgTapSession`: one stuck buzz blocked the next gesture's acknowledgement.**
   The buzz queue was shared across sessions. Each buzz is now bounded (15 s); an
   acknowledgement that never answers abandons the gesture (`ack_failed`).
6. **`GestureDispatcher`: an action that never answered stopped the others.** Each
   action now has a 10 s limit and becomes a failed outcome. Its claim is kept,
   because the action may have run, so a re-sent tap cannot run it twice.
7. **`WakeOrchestrator`: a failed state save or load could send the early haptic
   twice.** The fired flag lived only in the store. The orchestrator now keeps
   the last state in memory and prefers it when the store failed. Unserialisable
   stager state no longer takes the fired flag with it. After a process restart
   the dispatcher's durable ledger (stable event ids) is still the guard.
8. **Alarm Save: nothing was bounded.** A hung database or band left Save busy
   forever. Persist (10 s), arm (20 s), confirmation (5 s + 2 s) and the whole
   send (45 s) are bounded; each ends in a failure the header shows, with Retry.
9. **Relay: a process restart could re-buzz a notification still on screen.**
   The delivery id carried a per-process counter, so the durable ledger never
   matched it. The id is now stable per post (channel, key, post time, removals
   seen).
10. **Relay: bridge calls had no timeout, and a timeout looked like a
    revocation.** All calls are bounded (5 s). A timeout keeps the last known
    grant. Disarming clears the controller's latches without waiting for the
    platform. A resync that finishes after a revocation can no longer re-open the
    listener.
11. **Three direct band buzzes bypassed `AlertDispatcher`**: the alarm test buzz,
    the pattern test buzz and find-my-strap. All now go through
    `AppState._userBuzz`.
12. **`DeriveScheduler`: a database error or a failed derive became an uncaught
    async error** (the scheduler's calls are unawaited). They are now logged, the
    job is marked failed, and the pending flags keep their last value.
13. **`SyncCoordinator`: a throwing log sink skipped `completer.complete`**, so
    `syncNow()` callers awaited forever. The sink call is guarded.
14. **ECG tap `onFinished` released the dispatcher's count wait after writing the
    lab log.** A throw from the log would have left that tap's action chain
    waiting. The wait is released first.

Not a violation, but changed for consistency: the headless stale-sync notice
built its day label with `toIso8601String().substring(0, 10)` on a local time.
It now uses `dayLabelOf`.

### Residual risks (not fixed)

- Typed `SharedPreferences` getters throw on a value of the wrong type
  (`GestureSettings.bootstrap`, `NotificationPrefs`). Only a foreign writer can
  produce one, and it is the app-wide pattern. Left alone.
- 8N: if the gesture interval write fails (database down), that gesture's raw
  packets stay untagged. They are still not linked to any reading, but a raw-ECG
  consumer that lists unlinked packets would see them. A down database also stops
  sync, so this is a narrow case.
- The derive pass itself (`DeriveScheduler.run`) is not time-bounded. A real
  backfill can take minutes, and a timeout would corrupt it. The sync
  coordinator's 65 minute ceiling stops waiting; the scheduler clears `_running`
  when the pass ends.
- A relay entry with no post time falls back to receipt time for its id. The
  Android bridge always sends one.

## 3. Latch and timeout audit (AGENTS section 4.3)

Every flag below is cleared on success, on error, on timeout and on give-up.
"Test" names one test that pins it.

| File | Flag / latch | Cleared where | Test |
|---|---|---|---|
| `gestures/ecg_tap_session.dart` | `_active`, `_streamUp`, `_asked`, `_acked`, counter, readiness, tap | `_finish` (resets in `finally`) on done, abandon, `start_failed`, `link_lost`, `no_stream`, `ack_failed`; `start` bounded by `beginTimeout` | gesture_failure: a stream-start write that never answers fails the start, clears the latch |
| `gestures/ecg_tap_session.dart` | `_buzzTail` (buzz queue) | each buzz bounded by `buzzTimeout`, errors swallowed | gesture_failure: a stuck buzz of one gesture does not queue the next |
| `gestures/double_tap_repeat.dart` | `_done`, `_timer`, `_count`, `_seen` | `_finish` (`try/finally`), also `dispose` | double_tap_repeat_test: a throw from onFinished still resets the latch; gesture_failure: a buzz that never answers cannot hold the window open |
| `gestures/gesture_dispatcher.dart` | claim rows, `_lastAccepted` debounce | released on a failed action; kept on a timed-out one (it may have run); debounce entry removed on failure | gesture_failure: an action that never answers is a failed outcome; gesture_dispatcher_test: a failed action releases its claim |
| `state/app_state.dart` | `_tapCount` completer | completed first in `onFinished`; nulled when the start throws | audit_guards: the ECG tap session releases the dispatcher's count wait before it writes the lab log |
| `gestures/lab_log.dart` | `_open` | `endSession` (called from every session `onFinished`); buffers are capped | lab_log_test |
| `wake/wake_orchestrator.dart` | `_ticking` | `finally` in `tick` | wake_orchestrator_test: a second concurrent tick is coalesced, and the latch clears after an error; wake_failure: overlapping ticks |
| `wake/wake_orchestrator.dart` | `_memAhead`, in-memory run state | reset by the next successful save | wake_failure: state that cannot be saved still never sends the early haptic twice |
| `wake/wake_orchestrator.dart` | run flags `naturalFired`, `gradualNext`, `acknowledged`, `closed` | persisted BEFORE the haptic is sent; never cleared within a night; a new wake epoch discards them | wake_orchestrator_test: a new wake epoch discards the previous night; wake_failure: process kill after the fired flag was saved |
| `state/alarm_draft.dart` | `_sending`, `_inFlight` | `finally` in `save`; `sendTimeout` | alarm_draft_test: a send that throws is reported as a failure; alarm_draft_failure: a whole send that outlives its ceiling clears the sending latch |
| `notify/notification_relay.dart` (`RelayController`) | `_inFlight`, `_live`, `_listening` | `finally` in `handleMetadata`; `stop` on destroy, revocation, disarm; `listenerDisconnected` | native_relay_policy_test: destroyed / permissionRevoked clear listener state; relay_failure: revoking Notification access mid-session |
| `notify/notification_relay.dart` (`NotificationRelay`) | `_granted`, `_healTimer`, `_resyncGen` | `refreshPermission`; `_resync` cancels the timer when not active; `dispose` | relay_failure: disarming while the bridge is silent still clears the controller's latches |
| `notify/alert_dispatcher.dart` | per-target ledger claim | released in `finally` when the write did not succeed; deliberately kept on a timeout | dispatcher_failure: a band write that never answers gives up, keeps its claim |
| `notify/buzz_sequence.dart` | recorder `_pressed`, `_timer`, `_result` | `reset`, `dispose`; the player holds no state | buzz_sequence_test; dispatcher_failure: a step whose write never answers stops the rhythm |
| `compute/derive_scheduler.dart` | `_running`, `_refreshing`, `_manualHolds` | `finally` in `_drain`, `_refreshSnapshot`, `endManualSync`; callers end the hold in `finally` | sync_latches: a derive that throws; sync_perf_wiring_test: the scheduler hold is taken before the download and ended in finally |
| `state/control_operations.dart` (`SyncCoordinator`) | `_active`, `_retiredRun`, `_heldBack` | `finally` in `syncNow`; timeout cancels the token | sync_outcomes_test; sync_latches: a timing log that throws cannot leave syncNow() awaiting forever |
| `state/feature_flags.dart` | `_loaded` | set at the start of `load`, so a failed read is not retried in a loop | feature_flags_test: a wrong-typed stored override |

### Awaits on BLE or the platform, and their limits

| Await | Limit |
|---|---|
| ECG stream start / stop | 15 s / 5 s |
| Gesture interval write (before stopping the stream) | 5 s |
| Tap-gesture buzz | 15 s (and the dispatcher's own 10 s) |
| Gesture action (native or in-app) | 10 s |
| Dispatcher transport (phone, band) | 10 s; a recorded rhythm gets its play time plus 2 s per step |
| One buzz-sequence step | 5 s |
| Relay bridge calls | 5 s |
| Wake env calls (samples, haptic, alarm status, arm, cancel, stores) | 30 s each; the stage observer 60 s |
| Alarm Save | persist 10 s, arm 20 s, confirmation 7 s, whole send 45 s |
| Manual sync | 65 min overall (a full backfill is legitimately long) |
| Derive pass | none, by design (see residual risks) |

Local storage (SQLite, SharedPreferences) is not given a blanket timeout. It is
bounded only where a stuck write could hold a stream or a latch: the gesture
interval write, the alarm persist, and the wake stores.

## 4. Other audits

| Area | Result |
|---|---|
| Day labels | One style fix (`background_sync.dart`). A guard now fails on any `toUtc()...substring(0, 10)` or `toIso8601String().substring(0, 10)` in `lib/`, string interpolations included. |
| DST / 86400 s | No `86400`, `Duration(days:)` or 24 h arithmetic in any of the 22 files the roadmap added (guard per file). Wake windows are elapsed minutes before an absolute T; the water timer and `natural_wake` build local calendar times with `DateTime(y, m, d + n)`. |
| Absent inputs | `blankNightInBundle` handles empty and odd-typed stored results, never invents a value, and is idempotent. `wake_trace_text` says nothing for no trace. `LiveStreamBuffer` returns no samples rather than a line at zero. |
| Repeated derivation | Sleep blanking idempotent (existing 8E tests plus `sleep_blank_inputs_test`). Wake run state is keyed to the wake epoch. |
| Notification dedupe | `presentEvent` is called only from `NotificationCenter`. The one other direct `NotificationService` post is the OS-scheduled two-hour stillness slot, gated on its `movement` rule (guarded by a test). |
| Band buzz bypass | Three found and fixed (item 11). A guard now requires every `engine.buzz*`/`runAlarm` call to sit inside a dispatcher delivery or a constructor that hands it to one, and forbids them in any other file. |
| Isolate boundaries | The causal stager runs only in `Isolate.run`. No `Isolate.run` closure in the new code reads a flag. Flags are read on the isolate that acts on them. |
| Invariant 14 | `LiveStreamBuffer` imports no storage (guard). |
| Untouched | ACK ordering, raw retention, dangerous-write blocking and decode wiring. No schema change. No `kAlgoVersion` bump: no analytics output changed. |

## 5. Legacy paths: removed or kept

Nothing was removed. Removal needs a migrated-state test and a rollback test,
and every candidate is either a rollback path or now the fallback for a flag.

| Path | Decision | Why |
|---|---|---|
| Legacy notification booleans (the `legacyRule` source) | Kept | Written alongside the typed rules so an older build still reads them (rollback). Migration is covered by `alert_rule_migration_test`. |
| Phone-only `_emitPhone` delivery | Kept | It is the `alert_dispatcher` OFF path. |
| Legacy Smart Wake heuristic, `smart_wake.dart`, `smart_window_minutes` | Kept | It is the `natural_wake` OFF path and still serves users whose upgrade explanation is pending. |
| `AppState.setScheduleDay` (save and arm at once) | Kept | Programmatic callers (the Siri shortcut) still use it; the alarm screen does not. |
| Single-action key `gesture_double_tap` | Kept | Read once when the mask key is absent, and by the `gesture` rule migration. |
| `notification_listener_service` plugin | Already gone | Replaced by the app-owned listener before this phase. |

## 6. Blocked without hardware or macOS

Nothing below can be shown from a Linux box with no band.

- Real WHOOP 4.0 (gen4), 5.0 (gen5) and MG bands: the native alarm firing, the
  event 56/57/58 confirmations, the buzz waveform per generation, the firmware
  double tap, ECG touch counting, and the causal stager against real nights. The
  capability matrix is tested against fakes only.
- The Android API-level matrix on devices or emulators: the Notification-access
  grant flow, listener rebinding after the OS unbinds it, DND and ringer
  behaviour per OS version, foreground-service limits, and the `WorkManager`
  headless path.
- A real-device relay run: alarms, timers, system calls and a VoIP app that
  posts with the call category.
- iOS, WidgetKit and the watch: CoreBluetooth restoration, `BGTaskScheduler`
  background wake, the CPU watchdog behaviour, the App-Group snapshot. Needs
  macOS and Xcode.
- Background behaviour under real OS schedulers (Doze, App Standby, iOS
  suspension): how late a keep-alive tick really arrives, which the wake and
  gesture timeouts are sized against.
- Battery and radio cost of the ECG-touch and repeated-double-tap counters, and
  their false-positive rate on a wrist.
- Release evidence: serial `flutter test` JSON events for the whole suite, native
  JVM test reports, a source-hash manifest, and the golden captures. Only the
  targeted directories were run here, to save memory.
