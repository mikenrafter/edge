# Red-phase contracts

Baseline: 05ca7a7. Tests compile against current imports. `contract()` catches
only a missing dynamically invoked method and fails explicitly. It never supplies
substitute policy. All coordinators/controllers returned by the seams below must
be the same production classes used by AppState and the native relay.

## Phase 1

AppState.debugSyncCoordinator accepts `run(progress)`, `isConnected`,
`reloadLocal`, `timeout`. The returned production coordinator is a ChangeNotifier
with `syncNow()` and `refresh()`, each returning a result with `success`.
`presentation` is the production SyncPresentationState with string `phase`,
`busy`, `lastSuccess`, and `contactedBand`. Phase values are connecting,
downloading, deriving, completed, failed, offline. Coalescing waits for the active
operation; a timeout retires its progress callback and clears busy.

AppState.debugSleepCoordinator accepts `persist(day,onsetSec,offsetSec)`,
`derive(day)` returning a result map, and `saveSchedule(map)`. The returned
production sleep coordinator exposes `setOverride(day,onset,offset,
useSchedule:bool)` returning `success`, `metricsAvailable`, and nullable `error`;
`busy`; and `expectedWindowFor(localWakeDate)` returning a DateTime pair.
The saved schedule map uses `onsetMinute` and `wakeMinute` local wall-clock
minutes. Success describes persistence plus derive completion; null metrics are
successful abstention. Queued manual edits must each reach derive. A result map
with `duration_min:null` means unavailable metrics, not invalid user boundaries.

Extend existing DerivationEngine.debugTargetDayWindow to accept optional
`overrideOnsetSec` / `overrideOffsetSec`. The production candidate loader must
pass the stored override to the same union range implementation. Bounds are
absolute epoch seconds; margin is bounded to at most six hours on either side.
Existing one-argument behavior stays supported.

## Phase 2

NotificationPrefs.alertRule(id) returns the production AlertRule with toJson().
NotificationPrefs.withAlertRule(jsonMap) returns updated preferences. The map
contract uses keys from the accepted design, with destinations mask 0/1/2/3 for
Off/Phone/Band/Both, executionMode, fallback, staleAfterSeconds,
historicalReplay, and channelPolicyId. Legacy health migrated to phone; enabled
water migrated to both because the existing feature already arms both. Migration
must not run again when a legacy flag later differs from the versioned rule.

AppState.debugAlertDispatcher accepts `phone()`/`band()` returning bool,
`isConnected`, `supportedTargets` string set, and `now`. It returns the actual
production AlertDispatcher. `dispatch(ruleMap,eventId:,sourceTime:,historical:)`
returns targets and suppressionReason. Rule maps are converted to typed rules
inside the seam. Suppression values pinned here are bandUnavailable and stale.
Dedupe is per rule/event/target, so a failed band transport can retry without
repeating successful phone presentation. Production phone transport must go
through NotificationCenter.emit and persistent atomic claims.

## Phase 3

NotificationRelay.debugController accepts `policy` map, `buzz(List<int>)` and
`phone()` bool-returning sinks, and `nowMs`. It returns the actual production
relay controller. Native metadata and policy map keys are listed directly in
native_relay_policy_test.dart. Metadata timestamps are absolute milliseconds.
`setChannel(name,enabled:,matchHaptics:,fallbackPattern:,quietStartMinute:,
quietEndMinute:)` updates apps/alarms/calls independently. Apps is the default
configured channel; alarms and calls default off. Event `category=alarm` covers
both alarms and timers; `category=call` applies equally to system and VoIP apps.

`handleMetadata(map)` returns usedFallbackPattern. `listenerDisconnected()`,
`listenerConnected(activeMetadataList)`, `stop(reason)`, `dispose()`, `listening`,
and `busy` provide lifecycle behavior. Unknown wear state abstains when
the relay-wide only-while-worn setting is on. DND suppresses phone fallback too. Key removal ends
the dedupe lifetime. Distinct keys are not collapsed by a package cooldown.

Widget tests use existing pure views. Groups must be visible when disabled;
expansion belongs to explicit accordions. The existing capability summary label
is pinned spatially so enabling a relay cannot move it.

Source guards check integration only: helper range feeds the loader, haptic
producers name the dispatcher, Home/device detail share SyncPresentationState,
and the native listener replaces the content-bearing third-party plugin.
These guards do not claim to prove native runtime behavior. Android real-device
matrix and permission/rebind instrumentation remain release gates.
