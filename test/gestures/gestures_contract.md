# Phase 5A contract: timestamp-correct double-tap gestures

Companion to the red tests in `test/gestures/`. Names, signatures and thresholds
below are what the tests import and assert. Plan section: "Phase 5 / 5A" in
`docs/superpowers/plans/2026-09-30-controls-alerts-and-wake-roadmap.md`.
5B (physical one-through-four tap classifier) is out of scope: no UI rows, no
`tapCount` symbol, no tests beyond one guard in `band_gestures_view_test.dart`.

## 0. One deliberate deviation from the brief: `StrapEvent`, not `BandEvent`

`BandEvent` already exists: `sealed class BandEvent` in
`lib/ble/adapters/adapter.dart` (the adapter event stream; `host.dart` switches
over it). A second public `BandEvent` would collide wherever both are imported
(`ble_engine.dart` already imports `adapters/_registry.dart`). The new value
object is therefore:

- class `StrapEvent`
- file `lib/gestures/strap_event.dart`

The test file is still called `band_event_test.dart`, as asked.

## 1. `lib/gestures/strap_event.dart` (new)

```dart
const int kSubsecUnitsPerSecond = 32768;
const int kMinPlausibleStrapEpoch = 1577836800;            // 2020-01-01T00:00:00Z
const Duration kMaxStrapFutureSkew = Duration(seconds: 60);
const Duration kLiveEventWindow = Duration(seconds: 6);

enum EventTimeSource { strap, receipt }

class StrapEvent {
  const StrapEvent({
    required int eventId, required int tsEpoch, int tsSubsec = 0,
    required DateTime receivedAt, required String hex, required String deviceId,
    String name = '', Map<String, dynamic> decoded = const {},
  });                                  // no asserts: corrupt subsec must construct
  factory StrapEvent.fromEventInfo(proto.EventInfo i,
      {required DateTime receivedAt, required String hex, required String deviceId});
  static StrapEvent? tryParseHex(String hex,
      {required DateTime receivedAt, required String deviceId,
       proto.BandProfile profile});    // null for non-event / garbage / empty; never throws
  StrapEvent copyWith({String? deviceId});

  DateTime get strapTime;       // UTC, microsecond precision
  String get identity;          // '$deviceId:$eventId:$tsEpoch:$tsSubsec'
  bool get plausible;
  Duration? get age;            // receivedAt - strapTime; null when !plausible
  bool get isLive;              // !plausible || age <= kLiveEventWindow
  EventTimeSource get timeSource;  // plausible ? strap : receipt
  DateTime get effectiveTime;      // plausible ? strapTime : receivedAt.toUtc()
}
```

- `strapTime` = `tsEpoch` seconds + `(tsSubsec * 1000000) ~/ 32768` microseconds
  (floor; never carries into the next second; 1/32768 s = 30.517578125 us).
  Pinned: subsec 1 -> 30 us, 3 -> 91, 16384 -> 500000, 32767 -> 999969.
- `identity` excludes `receivedAt` and `hex`. Exact format is pinned: it is
  persisted inside claim keys.
- `plausible` is true iff ALL hold:
  1. `tsEpoch >= kMinPlausibleStrapEpoch` (unset RTC reads ~0 or tiny);
  2. `0 <= tsSubsec < 32768`;
  3. `strapTime <= receivedAt + kMaxStrapFutureSkew` (60 s inclusive; 60 s + 1 us
     is implausible).
  There is NO upper bound on age: a 3-day or 40-day-old tap has a real clock.
- `isLive`: age exactly 6.000 s is live, 6 s + 1 us is not. A plausible clock
  up to 60 s ahead (negative age) is live. An implausible clock is live (as
  today) and reports `timeSource == receipt`.
- `BleEngine` has no device id; it stamps `deviceId: LocalDb.kPrimaryDeviceId`
  (what AppState and the headless drain pass today). Sinks may `copyWith`.

## 2. `lib/ble/ble_engine.dart`

- `typedef EventSink = void Function(StrapEvent event);`
- New optional ctor param `DateTime Function()? clock` (default `DateTime.now`),
  read once per event frame for `receivedAt`.
- Emission site (~4918) becomes
  `onEvent?.call(StrapEvent.fromEventInfo(e, receivedAt: clock(), hex: _innerHex(frame.inner), deviceId: LocalDb.kPrimaryDeviceId))`.
  `EventInfo.tsSubsec` already exists in the pinned protocol; no protocol change.
- Driven headlessly by `engine_event_sink_test.dart` through the existing
  `debugInstallFakeLink` + `debugProcessImmediateFrame`. No new seam needed.

## 3. Persistence: schema 54 -> 55

- `LocalDb.schemaVersion = 55`; ladder rung `if (oldV < 55)` ->
  `_addColumnIfMissing(db, 'events', 'ts_subsec', 'INTEGER NOT NULL DEFAULT 0')`.
- `_createEvents` (called from `onCreate` and from `_repairOpenSchema` on every
  open) declares the column for fresh installs AND calls `_addColumnIfMissing`
  so a same-version build self-heals. Both paths are tested.
- `LocalDb.insertEvent(int id, int ts, String hex, {required String deviceId, int? tsSubsec, DateTime? receivedAt})`
  keeps its positional shape (four existing tests call it). `ts_subsec` =
  `tsSubsec ?? parsed-from-hex ?? 0`; `captured_at` = `(receivedAt ?? now)` ms.
  PK stays `(device_id, hex)` with `ConflictAlgorithm.ignore`: a re-insert adds
  no row and keeps the FIRST receipt time.
- `static Future<void> LocalDb.insertStrapEvent(StrapEvent e)` -> `insertEvent`
  with the event's subsec and receivedAt. Use it in `AppState._onLiveEvent` and
  `background_sync.dart`.
- `static Future<List<StrapEvent>> LocalDb.strapEvents({String? deviceId, int? eventId, int? sinceTsEpoch, int limit = 1000})`
  ordered `ts ASC, ts_subsec ASC`; rows rebuild a `StrapEvent` with
  `receivedAt` from `captured_at` (UTC), so strap time and receipt time come
  back separately.
- Additive, idempotent, cheap (invariant 11). No `kAlgoVersion` bump (nothing
  derived moves).

## 4. `DeviceAction` and `GestureSettings`

`DeviceAction.supportsHistoricalReplay` -> true only for `markMoment`.
Enum order is persisted: bit i of the mask = `DeviceAction.values[i]`. The test
freezes every position (none 0, mediaPlayPause 1, ... markMoment 8,
workoutToggle 9, logWater 10, broadcastToTasker 11).

```dart
class GestureSettings extends ChangeNotifier {
  static int maskOf(Iterable<DeviceAction>);        // none never sets a bit
  static Set<DeviceAction> actionsOfMask(int);      // enum order; ignores unknown bits and bit 0
  Set<DeviceAction> get doubleTapActions;           // unmodifiable, enum order
  Set<DeviceAction> get replayActions;              // selected && replayHistorical
  Set<DeviceAction> supported;                      // unchanged
  bool get hasActiveMapping;                        // doubleTapActions.isNotEmpty
  Future<void> bootstrap();
  Future<void> setDoubleTapActions(Set<DeviceAction>);   // drops `none`; no-op if equal
  Future<void> toggleDoubleTapAction(DeviceAction, bool);
  bool replayHistorical(DeviceAction);
  Future<void> setReplayHistorical(DeviceAction, bool);  // no-op if !supportsHistoricalReplay
}
```

- Keys: `gesture_double_tap_actions` (int mask, new), `gesture_replay_<action.id>`
  (bool, explicit user choice only).
- Remove `doubleTap` and `setDoubleTap` (tests do not reference them).
- Bootstrap: new key if present, else the legacy `gesture_double_tap` string id
  becomes a one-bit set (`none`/unknown -> empty) and the new key is written.
  **The legacy key is NOT deleted**: `lib/notify/notification_prefs.dart` (~260)
  still reads it for the one-time `gesture` alert-rule migration. Unsupported
  actions are dropped on bootstrap and the mask rewritten.
- `replayHistorical(a)` = `a.supportsHistoricalReplay && (explicit ?? selected)`.
  So default true for Mark moment once selected, false before; an explicit
  choice survives deselect/reselect; a stored `true` for a non-replayable action
  is ignored.
- Mutating setters do not validate against `supported` (tests construct without
  bootstrap); only `bootstrap` prunes.
- Listeners are notified once per real change, never on a no-op.

## 5. `lib/gestures/gesture_dispatcher.dart`

```dart
enum GestureStatus { ran, skippedStale, skippedDuplicate, failed }
class GestureOutcome {
  final DeviceAction action; final GestureStatus status;
  final EventTimeSource timeSource;   // of the EVENT, same on every outcome
  final Object? error;                // non-null iff failed
}

GestureDispatcher({
  required GestureSettings settings,
  void Function(String)? log,
  Future<void> Function(StrapEvent)? onMarkMoment,
  Future<void> Function(StrapEvent)? onWorkoutToggle,
  Future<void> Function(StrapEvent)? onLogWater,
  Future<bool> Function(String actionId)? performNative,   // default DeviceActions.perform
  Future<bool> Function(String key)? claim,                // default LocalDb.claimNotifFired
  Future<void> Function(String key)? release,              // default LocalDb.releaseNotifFired
});
Future<List<GestureOutcome>> handle(StrapEvent e);
```

`onEvent(int,int,String)` is deleted, along with `_debounceMs`,
`_plausibleAgeCapSec` and every `DateTime.now()` (recency uses
`event.receivedAt`; a source guard checks this).

Per call to `handle`:
1. `eventId != 14` -> `[]`; nothing claimed. No selected action -> `[]`.
2. For each selected action in enum order, sequentially awaited:
   a. **Stale check first.** If `!e.isLive` and not
      (`a.supportsHistoricalReplay && settings.replayHistorical(a)`) ->
      `skippedStale`; no claim taken (so enabling replay later still works).
   b. **Plausible clock:** atomically `claim('gesture:${e.identity}:${a.id}')`;
      `false` -> `skippedDuplicate`. A claim that throws -> `failed`, handler
      not run (fail closed), other actions continue.
   c. **Implausible clock:** no persistent claim (every tap from an unset RTC
      shares identity `dev:14:0:0`, so a persistent claim would lock the feature
      out forever). Instead an in-memory debounce on RECEIPT time per
      (identity, action): a tap whose `receivedAt` is `< 2 s` after the last
      ACCEPTED tap is `skippedDuplicate`; exactly 2.000 s runs. A duplicate does
      not extend the window.
   d. Run: in-app via its handler (missing handler -> `failed`, StateError);
      native via `performNative(a.id)` (`false` or throw -> `failed`). Handlers
      may throw synchronously or asynchronously; both are caught. Nothing may
      escape as an unhandled async error. Failures are logged with the action id.
   e. A `failed` action releases its claim (or its debounce entry); a sibling
      that succeeded keeps its own.
3. Out-of-order arrival and "two taps in the same second" need no state: the
   claim is keyed by each event's own identity. Same instant on two bands = two
   occurrences.

Claim growth: `notif_fired` keys without a leading date are never pruned.
Gesture keys are one row per tap per action; the green phase may add a
`fired_at`-based prune for `gesture:` keys (not tested).

## 6. `lib/gestures/moment_stamp.dart` (new, pure)

```dart
class MomentStamp {
  final String date;   // 'YYYY-MM-DD', local, via dayLabelOf
  final String hhmm;   // 'HH:mm' local, zero-padded
  final EventTimeSource timeSource;
  String get tag;      // 'moment $hhmm'
}
MomentStamp momentStampFor(StrapEvent e);   // e.effectiveTime.toLocal()
List<String> withMomentTag(List<String> tags, MomentStamp s);  // copy; appends once
```

- Plausible clock: strap time, converted to local. Implausible: `receivedAt`,
  converted to local, `timeSource == receipt`. Receipt time is never substituted
  for a plausible strap clock.
- Day label via `dayLabelOf` only (invariant 7); no 86400 arithmetic.
- `AppState._markMomentFromGesture(StrapEvent e)` calls both helpers and must not
  contain `DateTime.now()` (source guard in `engine_event_sink_test.dart`).
- Two distinct taps in the same minute produce the same tag text and collapse to
  one tag; that is accepted (minute resolution). Occurrence dedupe is the
  dispatcher's job.
- Not covered (out of scope): `_markMomentFromGesture` does a journal
  read-modify-write; two overlapping taps can lose an update, and a failed
  journal read posts only the moment tag. Worth serializing in the green phase.

## 7. UI: `lib/ui2/profile/gestures.dart`

```dart
BandGesturesView({
  Key? key,
  required Set<DeviceAction> chosen,
  required Set<DeviceAction> supported,
  void Function(DeviceAction, bool)? onToggle,
  Set<DeviceAction> replay = const {},
  void Function(DeviceAction, bool)? onReplay,
})
```

- One `SwitchRow` (from `profile.dart`) per offered action: in-app actions first
  then native, each in enum order, filtered by `supported`. No radio, no `none`
  row ("Do nothing" must not appear). Copy contains `every action off` to say the
  empty set is the off state. The old "The app ignores that tap" sentence must go
  (a stale tap can now be replayed for Mark moment).
- A `SwitchRow` titled exactly `Also run for taps replayed from history`, directly
  after the Mark moment row, only while `markMoment` is in `chosen`; value =
  `replay.contains(markMoment)`; `onReplay(markMoment, v)`. Never for another
  action.
- Native-unreachable note ("could not ask the system") is kept.
- Texts are asserted against the English fallbacks (the tests mount no
  localization delegate). Update `lib/l10n/app_en.arb` (`gesturesSectionBody`,
  the new replay label) and the other locales, and the `BandGestures` wrapper:
  `chosen: g.doubleTapActions`, `onToggle: g.toggleDoubleTapAction`,
  `replay: g.replayActions`, `onReplay: g.setReplayHistorical`.
- No text may match `/one tap|three tap|four tap|single tap|triple tap|1 tap|3 tap|4 tap/i`,
  and no `tapCount` in `lib/gestures/**` or `lib/ui2/profile/gestures.dart`.

## 8. Existing code and tests the green phases must touch

Compile-breaking (the red tests do not edit these):

| file | change |
|---|---|
| `test/band_gestures_test.dart` | The ONLY existing test that stops compiling. Uses `onPick`, `chosen: DeviceAction`, `GestureSettings()..doubleTap`, `Future<void> Function()` handlers, `.onEvent(14, ts, '')`, and asserts a "Do nothing" row and a 2 s debounce. Rewrite to the new API (the picker-renders cases move to `test/gestures/band_gestures_view_test.dart`; delete the superseded debounce case). |
| `lib/state/app_state.dart` | two `onEvent: (id, ts, hex) => _onLiveEvent(...)` closures (~1475, ~1616) -> `onEvent: _onLiveEvent`; `_onLiveEvent(StrapEvent)`; `_gestureDispatcher.handle(e)` (unawaited is fine, it never throws); handlers take `StrapEvent`; `_markMomentFromGesture(StrapEvent)` |
| `lib/sync/background_sync.dart` | ~143 `onEvent: (e) async { ... LocalDb.insertStrapEvent(e); handleHeadlessAlarmEvent(e.eventId) }`; keep the `ResetGate.active` guard (`reset_quiesces_ingest_test` slices that closure) |
| `lib/ui2/profile/gestures.dart` | view + `BandGestures` wrapper |
| `lib/ble/ble_engine.dart` | typedef + emission + `clock` param |

Not broken, but verify: `test/controls/alert_rule_migration_test.dart` and
`lib/notify/notification_prefs.dart` (legacy `gesture_double_tap` key must stay);
`test/ui2_tokens_test.dart` (names only); the four callers of the positional
`LocalDb.insertEvent` in `test/` keep compiling by design; l10n completeness
checks; `docs/copy-review/` corpus mentions the old gesture copy (regenerate only
if the copy-review script is part of the release flow).

## 9. Test inventory (159 tests)

| file | tests | covers |
|---|---|---|
| `band_event_test.dart` | 28 | strapTime conversion, identity, plausibility thresholds, age/isLive/timeSource, wire parsing |
| `event_persistence_test.dart` | 13 | `ts_subsec` stored, receipt separate, no duplicates, reader, 54->55, idempotent reopen, self-heal |
| `gesture_settings_test.dart` | 28 | mask round-trip and frozen bit order, persistence, enum-order determinism, legacy migration, bootstrap pruning, replay defaults and explicit choice |
| `gesture_dispatcher_test.dart` | 40 | order, awaited sequencing, failure isolation (sync/async/native/no-handler/claim), duplicates incl. restart and concurrency, out-of-order, recency edges, fractional subsec, replay on/off, implausible clock, outcomes, real-DB claim wiring |
| `mark_moment_time_test.dart` | 20 | event vs receipt time, midnight, every 2026 midnight, DST windows (zone-independent), implausible clock, tag idempotence |
| `band_gestures_view_test.dart` | 17 | multi-select switches, no `none` row, replay row rules, 5B guard, 2x text, both themes |
| `engine_event_sink_test.dart` | 13 | engine hands a `StrapEvent` (subsec, receive time, device), source guards on wiring |

Run:

```
nix develop --command edge-fhs flutter test --reporter failures-only test/gestures
nix develop --command edge-fhs flutter analyze
```

Also run `mark_moment_time_test`, `gesture_dispatcher_test` and `band_event_test`
under `TZ=America/New_York`, `Europe/London`, `Australia/Lord_Howe`,
`Asia/Kolkata`, `Pacific/Auckland` (TZ propagates through `nix develop`). A
throwaway implementation of this contract in a scratch copy of the repo passed
all 159 tests, and the three time-sensitive files under all five zones, so every
assertion is satisfiable. That copy is deleted; nothing was added under `lib/`
or `android/`.

Suggested green order, each unblocks one file: (1) `strap_event.dart` +
`moment_stamp.dart` -> `band_event_test`, `mark_moment_time_test`;
(2) `DeviceAction` + `GestureSettings` -> `gesture_settings_test`;
(3) schema 55 + `insertStrapEvent`/`strapEvents` -> `event_persistence_test`;
(4) dispatcher -> `gesture_dispatcher_test`; (5) engine + AppState + headless
wiring -> `engine_event_sink_test`; (6) view + l10n -> `band_gestures_view_test`,
then rewrite `test/band_gestures_test.dart`.
