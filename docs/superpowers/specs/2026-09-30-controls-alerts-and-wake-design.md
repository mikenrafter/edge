# Controls, alerts, sources, gestures, and wake design

Date: 2026-09-30  
Status: accepted direction; implementation is phased in the companion plan

## Outcome

Edge should present one coherent control model without pretending the band can
do work it cannot do. A user should be able to answer four questions before
enabling any behavior:

1. What condition causes it?
2. Where will it be delivered: phone, band, both, or nowhere?
3. Does it run on the band by itself, or does it need a connected phone?
4. What happens if the phone, band, data, or timing requirement is unavailable?

The UI should remain spatially stable. Enabling a feature reveals its detail in
an explicit accordion or enables controls in place; it must not make unrelated
sections jump around.

This design covers alerts, sync/recalculation controls, manual sleep windows,
source provenance and priority, gestures, Android notification relay, and the
split between Natural Wake and Gradual Wake.

## Repository boundaries

- `OpenStrap/edge` owns UI, preferences, SQLite storage, BLE orchestration,
  platform bridges, delivery policy, and displaying analytics results.
- `OpenStrap/analytics` owns any causal sleep-stage estimator and any new
  sensor-derived tap classifier. Those are metrics/classification, not UI flow.
- `OpenStrap/protocol` owns new event or frame decoding if a firmware capability
  is discovered. Edge must not grow a second byte decoder.

An analytics output change requires an Edge `kAlgoVersion` bump and changelog
entry. The cited analytics change must be present in the full commit SHA pinned
by `pubspec.yaml` before the bump lands.

## Capability language

Delivery and execution are separate dimensions. “On band” is a destination,
not a reliability promise.

Use these user-facing labels:

| Execution | Label | Meaning |
|---|---|---|
| Band RTC/rule | **On band — works without phone** | The band owns the armed rule and can fire while disconnected. |
| Live phone rule | **On band — phone must be connected** | The phone detects the condition and asks the band to buzz. |
| OS scheduled | **On phone — system scheduled** | The operating system owns the fallback schedule. |
| Derived app event | **On phone — Edge must be running** | Edge needs fresh data and enough execution time. |

The capability text comes from the rule's execution mode and current device
capabilities. It is never handwritten independently in several screens.

Do not show Android screens explanatory noise such as “Phone only on iOS.” A
platform-specific control that cannot work on the current platform should not
be constructed. In a shared destination picker, a temporarily unavailable but
conceptually supported target remains visible and disabled with the reason.

## Alert domain

Alarms, heart-rate zone crossings, reminders, health findings, device state,
relayed app notifications, OS alarm/timer events, and calls are all alert rules.
They share policy and delivery primitives; they do not share condition-specific
configuration.

Conceptual model:

```text
AlertRule
  id
  kind
  enabled
  destinations: Set<phone, band>       # empty is Off
  executionMode: bandNative | phoneLive | osScheduled | phoneDerived
  fallback: none | phoneIfBandUnavailable
  staleAfter
  historicalReplay
  channelPolicyId
  condition                           # typed by kind
  presentation                        # sound/haptic pattern and copy
```

The UI offers Off, Phone, Band, and Phone + Band. Storage uses a set/bit mask,
not a single enum. A connected-band-only rule does not silently fall back to
the phone. Phone fallback is explicit. Time-sensitive events expire rather than
queueing an old buzz for the next reconnect.

Every rule also declares one of these replay policies:

- `liveOnly`: never act on historical data.
- `ask`: offer replay when the user enables the action.
- `historical`: apply to late events within a declared age bound.

Historical replay is opt-in per action. When a user selects Mark moment, replay
is enabled by default because preserving the original moment is the purpose of
that action. Notification and buzz actions default to live-only.

`NotificationCenter.emit` remains the single local-notification emitter. Band
haptics need an equivalent policy seam so reminders, relays, zone alerts, and
wake behavior cannot bypass destinations, staleness, DND, or dedupe.

## Android relay channels

The current third-party notification-listener bridge exposes package, text,
post time, and little else. It cannot correctly implement alarm/call
classification, stable dedupe, channel policy, or DND behavior. Replace it with
an app-owned Android `NotificationListenerService` and a narrow Flutter bridge.
The bridge should pass metadata needed for policy, not notification content.

The Android relay has three channels:

1. **App notifications** — per-app opt-in plus one channel-wide DND/ringer
   policy.
2. **Alarms and timers** — opt-in; map the OS alarm/timer haptic when Android
   exposes it, otherwise use the user's declared alarm fallback pattern and say
   that matching is unavailable.
3. **Incoming calls** — opt-in; a dedicated call pattern and the same explicit
   DND/ringer policy.

Each channel has global controls, not copies under every app:

- Respect Do Not Disturb (default on).
- Allow this channel on the band during DND (explicit override).
- Include the band when the phone is in Vibrate mode.
- Include the band when the phone is Silent (default off).
- Only while worn, when wear state is reliable.
- Quiet hours where meaningful.

Allowing a band buzz during DND changes only Edge's band-delivery decision. It
must never change the phone's global DND setting.

Classification uses Android notification categories and listener ranking:
`CATEGORY_ALARM`, `CATEGORY_CALL`, current interruption filter,
`Ranking.matchesInterruptionFilter()`, ringer mode, and the stable
`StatusBarNotification` key. Removal events close the key's dedupe lifetime.
Apps that misuse categories are handled only after on-device evidence, not by a
broad text heuristic that reads private notification content.

Relevant Android contracts:

- [NotificationListenerService](https://developer.android.com/reference/android/service/notification/NotificationListenerService.html)
- [Notification categories](https://developer.android.com/reference/android/app/Notification.html)
- [AudioManager ringer modes](https://developer.android.com/reference/android/media/AudioManager)
- [StatusBarNotification keys](https://developer.android.com/reference/android/service/notification/StatusBarNotification)

## Sync and recalculation controls

These controls are distinct because they do different work:

- **Sync now** is persistent on Home/status and the primary band detail screen.
  It requests a BLE session and reports connecting, downloading, deriving,
  completed, failed, and last-success state.
- Pull-to-refresh on data screens requests a sync when connected and always
  shows the same sync state. It must not masquerade as a local repository
  reload.
- **Recalculate this night** appears on Sleep and re-runs that night's
  derivation without requiring another band download.
- **Rebuild all history** remains in Advanced. It warns about time, battery,
  heat, and versioned recomputation and requires explicit confirmation.

Repeated taps coalesce into the active operation. Sticky busy flags are cleared
in `finally`, timeout, disconnect, and give-up paths.

## Manual sleep and expected sleep

A user assertion about when they slept is accepted as the session boundary. It
is not rejected merely because the interval is unusual.

Retrospective correction and future expectation are different data:

- `SleepBoundaryOverride` applies to one occurrence and drives a re-derive.
- `ExpectedSleepSchedule` tells future foreground/background orchestration when
  to pre-warm collection, live classification, and Natural Wake.

When the user changes an atypical night's times, the flow offers:

- **This night only** — correct the occurrence without changing expectations.
- **Use this schedule going forward** — update the expected main-sleep window.

This choice avoids silently converting one exceptional night into a habitual
schedule while still satisfying the need for future runs to expect the new
time. Later schedule learning may suggest a change, but never applies one
silently.

The reanalysis loader reads the union of the normal detection search range and
the user-asserted interval, including a bounded margin. The band records history
independently while it is worn, so an unexpected sleep time should usually be
recoverable after sync. If data is genuinely absent because the band was off
wrist, the schedule changed before collection, or records have not arrived,
retain the asserted window and show affected metrics as unavailable. Never
fabricate them and never report that the user's sleep claim is invalid.

Manual-to-manual edits must report success based on the persisted boundaries
and derive result, not on whether `sleep_source` changed labels.

## Source identity, provenance, and priority

Adopt the information architecture of Noop's source screens, not its arbitration
data model or code. Noop is a presentation reference and has a noncommercial
license; Edge implementation must be original.

The Sources area has two layers:

### Source catalog

Each connected source card shows:

- Human name, source type, model, platform ID, and stable identity suffix.
- What it can supply: steps, heart rate, sleep, workouts, location, and so on.
- Collection behavior: continuous, sampled, user-started, imported, or derived.
- Time coverage and last-seen state.
- Permissions and known limitations.
- Which signals currently use it and why.

### “Your data, resolved” detail

For each signal and time interval, show:

- Winning value/source.
- Alternative values/sources.
- Agreement or disagreement.
- The deterministic reason for the choice.
- Gaps, overlap, and the consequence of changing priority.

Users can reorder source priority even when no current contention exists.
Reordering affects current and future computation by default. A separate,
explicit **Rebuild history with this priority** action performs historical
recomputation and explains its cost. The resolver remains signal- and
time-specific; Edge does not adopt a generic metric-fusion model.

## Gestures and event time

### What the hardware currently exposes

The protocol event envelope carries whole seconds plus `tsSubsec` in 1/32768 s
units. Edge's BLE callback currently forwards only whole seconds, and the
gesture action callback drops even that timestamp. Mark moment therefore uses
`DateTime.now()` despite a better source timestamp being available.

That is a current Edge capability gap. Preserve the full hardware event time
through protocol event → BLE event value object → persistence → action
dispatch. Mark moment uses the event time; receipt time is retained separately
for diagnostics.

The known firmware event is specifically **double tap** and its body has no tap
count. The current protocol does not expose distinct one-, three-, or four-tap
events. The UI must not imply otherwise.

### Configurable actions

For the reliable firmware double-tap event, actions become a set/bit mask:

- Mark moment
- Start/stop an activity where safe
- Phone notification
- Band/phone alert action where meaningful
- Future actions registered in the same typed action catalog

Action order is deterministic. Failures are isolated and recorded per action;
one failed action must not suppress Mark moment.

### One through four physical taps

Tap detection is motion/accelerometer behavior, not ECG. Edge can receive
high-rate live IMU frames on supported bands. Classifying a short window of
100 Hz motion is computationally cheap; continuously keeping the stream, BLE
link, and phone process alive is not cheap in radio, battery, or background
reliability.

Therefore one-through-four physical taps begins as a capability experiment:

- Verify which band generations can stream the required IMU data safely.
- Measure battery/radio impact and Android/iOS background survivability.
- Build and validate the classifier in `OpenStrap/analytics` using recorded,
  consented traces.
- Expose mappings only for devices and operating modes that pass the gate.
- Initially limit it to an already-live session if ambient streaming is not
  reliable enough.

Do not reinterpret one through four as “one through four repeated double-tap
events.” That would add latency, conflict with duplicate suppression, and label
a different gesture as though it were a physical tap count.

## Wake model

“Smart Wake” becomes an umbrella section with two independent features.

### Natural Wake

Natural Wake tries to wake the user during **estimated REM** in a configurable
window from 15 minutes through 2 hours before the must-be-up-by time, in
15-minute increments. It applies only to the configured main sleep, never naps.

The current `likelyLightSleep` heuristic is not a sleep-stage estimator. The
retrospective `cardioStager` also cannot simply be rerun every tick: it uses a
night-level baseline and retrospective smoothing. Natural Wake requires a
causal analytics API that uses only information available at the decision time
and returns stage, confidence, evidence age, and an abstention state.

Collection and processing begin before the Natural Wake window so a stage
history and baseline already exist when the first trigger is allowed. Heavy
work stays off the UI isolate. If data is thin, stale, off-wrist, disconnected,
or confidence is insufficient, the classifier abstains.

### Gradual Wake

Gradual Wake preserves the existing escalating-haptic concept. It has its own
independent start/window and pattern controls. Its time is not borrowed from
Natural Wake.

### Combined behavior

Let `T` be must-be-up-by, `N` the Natural Wake window, and `G` the Gradual Wake
window:

| Configuration | Behavior before `T` |
|---|---|
| Neither | No early action. |
| Natural only | Watch for a stable estimated-REM candidate during `[T-N, T)`, then send the configured wake action once. |
| Gradual only | Run the gradual sequence beginning at `T-G`. |
| Natural + Gradual | Both schedules are armed independently. Natural may send the first wake action during `[T-N, T)`; gradual still begins at `T-G` unless the user explicitly acknowledges the overall alarm. |

In all four states, one fixed native band alarm remains armed at `T`. An early
haptic never silently cancels it. Explicit user acknowledgement may request
cancellation of remaining phone-driven steps and the native fallback, but lack
of acknowledgement or failed cancellation leaves `T` intact.

The UI shows the computed timeline and names which parts are band-native and
which require a connected phone. It does not promise Natural Wake when the live
stage capability, permissions, or connectivity requirements are absent.

## Stable screen construction

Use a consistent structure for these settings:

1. Summary row with current state.
2. Toggle/destination control.
3. Fixed-position capability and fallback summary.
4. Accordion for conditions and delivery details.
5. Test action and latest outcome.

Disabled controls remain visible when seeing them explains the model. Entirely
irrelevant platform rows are omitted. Expansion is user-driven; a switch does
not unexpectedly insert multiple sections above the user's finger.

## Footguns

Comments alone are not a safety boundary. Add machine-searchable classifications
at every risky command definition and audited call site:

```text
FOOTGUN(LINK_LOSS)
FOOTGUN(DATA_LOSS)
FOOTGUN(PERSISTENT_CONFIG)
FOOTGUN(FIRMWARE)
```

The metadata must feed tests that prove:

- destructive opcodes are blocked by default on every write path;
- the sole persistent-config escape remains named and audited;
- history ACK occurs only after one transaction commits rows and cursor and
  echoes the exact eight-byte end token;
- UI/demo/debug code cannot directly reach dangerous writes;
- disconnect, timeout, and partial chunks never advance destructive state.

Risky controls never live beside everyday diagnostics without separation and
confirmation. No Noop raw-command, reboot, firmware, or broadcast control is
copied into Edge's ordinary UI.

## Privacy and observability

- The Android relay transports category, package identity, stable key hash,
  timing, policy flags, and haptic metadata only. Titles and message bodies stay
  out of Dart unless a future user-visible feature explicitly needs them.
- Alert decisions record rule ID, source time, receipt time, selected targets,
  delivery outcome, suppression reason, and capability snapshot.
- Never log notification content, health samples, or full device identifiers.
- All analytics and source arbitration remain local-first.

