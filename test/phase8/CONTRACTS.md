# Phase 8 contracts (red tests)

Baseline: `2fe283a`. Spec: "Phase 8 — UX addenda" at the end of
`docs/superpowers/plans/2026-09-30-controls-alerts-and-wake-roadmap.md`
(8A–8L plus the 8I note). Each workstream has its own test file so a missing
symbol in one does not hide another. Files marked *compile-safe* build today
and fail on behaviour; the rest fail to compile until the symbols below exist.

Shared helpers: `support/dart_source.dart` (comment/string-blanking lexer used
by every source guard: `codeOnly`, `closingOf`, `enclosedByCall`, `bodyOf`)
and `support/sections.dart` (`pumpTall`, `section(title)`,
`expectAllSectionsExpanded`, `isDimmed`).

**"Disabled and dimmed" (8K, used everywhere):** the row is present, a tap on it
does nothing, and an `Opacity` (or `AnimatedOpacity`) with opacity < 1 sits at
or above the row's title `Text`. Give `SetRow` and `SwitchRow` an
`enabled` parameter (default `true`) that does both; a disabled `SwitchRow`'s
`Switch.onChanged` is `null`.

Existing tests that 8C/8K/8L intentionally supersede (update them in the same
commit as the change):
- `test/gestures/band_gestures_view_test.dart` "is absent while Mark moment is
  not selected" → the replay row is present and disabled (8K).
- same file, "Phase 5B stays out of this screen" text regex → 8L adds the rows
  `3 taps`/`4 taps`/`5 taps`; keep forbidding one/single/1 tap. The `tapCount`
  identifier ban stays; nothing below uses it.
- `test/proof/goldens/*` and `test/ui2_onboarding_profile_golden_test.dart`
  baselines for Settings, Notifications, Band notifications, Alarm, Gestures,
  Device detail and the empty Sleep screen change (sections expanded, rows
  present, new labels). Regenerate after review.

---

## 8G — collapse repeated band events (`tap_groups_test.dart`)

`lib/ui2/screens/day_timeline.dart`:
- `Moment` gains `final int? eventId` (optional const-constructor param,
  default `null`). `dayMoments` sets it on band-event moments only.
- `class MomentGroup { const MomentGroup(this.moments); final List<Moment> moments; int get count; Moment get first; }`
- `List<MomentGroup> groupRepeatedEvents(List<Moment> sorted)` — pure. Merges
  only consecutive moments with the same non-null `eventId`. Order preserved,
  every moment appears exactly once, empty in → empty out.
- `timelineBody` renders groups: `count > 1` → one row titled exactly
  `'${first.title} · $count times'`; tapping it expands to the individual
  times (each `clockOfTs(at)` shown), tapping again collapses. Collapsed shows
  none of the individual rows. `count == 1` → the plain `MomentRow`.

## 8H — tap acknowledgement (`tap_ack_test.dart`)

New `lib/gestures/tap_ack.dart`:
- `bool shouldAckTap(StrapEvent e, List<GestureOutcome> outcomes)` — true iff
  `e.eventId == 14 && e.isLive && outcomes.any((o) => o.status == GestureStatus.ran)`.
- `const AlertRule kGestureAckRule` — `id: 'gesture_ack'`, `kind: 'gesture'`,
  `destinations: AlertRule.band`, `executionMode: phoneLive`,
  `historicalReplay: liveOnly`, `fallback: none`,
  `0 < staleAfter <= kLiveEventWindow` (6 s), `channelPolicyId: 'gesture'`.
- `Future<bool> ackTap(AlertDispatcher d, StrapEvent e, List<GestureOutcome> outcomes)`
  — returns false without dispatching unless `shouldAckTap`. Otherwise
  `d.dispatch(kGestureAckRule, eventId: id, sourceTime: e.effectiveTime, historical: false)`
  using the dispatcher's DEFAULT band transport (no transport argument), and
  returns `outcome.targets.contains('band')`. `id` = `e.identity` when
  `e.plausible`, else `'${e.identity}:${e.receivedAt.microsecondsSinceEpoch}'`
  (an unset RTC must not swallow every later ack).
- AppState: `_onLiveEvent` calls `ackTap(alertDispatcher, e, outcomes)` with the
  dispatcher outcomes; no `engine.buzz` / `buzzPattern(` inside
  `_onLiveEvent`. `lib/sync/background_sync.dart` never calls `ackTap(`.

## 8D — buzz sequences

### Model (`buzz_sequence_test.dart`) — new `lib/notify/buzz_sequence.dart`
- `class BuzzSequence` — `BuzzSequence(List<int> offsetsMs)` throws
  `ArgumentError` unless: 1–8 entries, first is 0, strictly increasing, every
  gap in [150, 2000] ms. `List<int> get offsetsMs` (unmodifiable),
  `int get length`, value `==`/`hashCode`.
  `static const maxBuzzes = 8, minGapMs = 150, maxGapMs = 2000`.
- `List<int> toJson()`; `factory BuzzSequence.fromJson(Object? json)` throws
  `FormatException` for non-list, non-int (incl. doubles), empty or invalid.
- `static BuzzSequence defaultFor(int index)` — `ArgumentError` if negative;
  `i = index % 9; count = i % 3 + 1; gap = [500, 1000, 1500][i ~/ 3];`
  offsets `[for k < count: k * gap]`.
- `class BuzzRecorder({VoidCallback? onStart, void Function(BuzzSequence)? onDone})`
  — reads `clock.now()` (package:clock) and uses `Timer`, so fake_async and
  `testWidgets` drive it. `void tap()`, `bool get recording`,
  `BuzzSequence? get result`, `void reset()`, `void dispose()`. First tap starts
  recording (offset 0) and calls `onStart` once. A tap < 150 ms after the
  previous accepted tap is ignored. Ends 2 s after the last accepted tap, or
  immediately at the 8th tap; later taps are ignored; `onDone` fires once.
- `Future<bool> playBuzzSequence(BuzzSequence s, {required Future<bool> Function() buzz, required bool Function() isConnected})`
  — step i starts at `offsetsMs[i]` after the call (absolute from the start,
  not after each write). Before each step checks `isConnected()`; a false,
  a `buzz()` returning false or throwing stops further steps and returns
  false. Never throws. True only if every step was written.
- One `AlertDispatcher.dispatch` with `bandTransport: () => playBuzzSequence(...)`
  plays the whole sequence; a re-dispatch of the same `(rule, eventId, target)`
  plays nothing (existing claim).

### Storage (`buzz_sequence_storage_test.dart`)
- `AlertRule` gains `final BuzzSequence? buzzSequence` (default null),
  `copyWith(buzzSequence:)`, preserved by unrelated `copyWith`. `toJson` writes
  `'buzzSequence': [..]` only when non-null; `fromJson` reads it (absent →
  null, invalid → `FormatException`). Same `schemaVersion`; additive.
- `NotificationPrefs.alertRuleOrder` — `static const List<String>`, starts with
  the frozen 21 ids (health, recovery, reminders, device, water, autoDetect,
  movement, meds, checkIn, stepGoal, windDown, alarmLatchFailed,
  alarmNightCheck, alarm, nativeAlarm, zone, wake, breath, tasker, relay,
  gesture); append only. `effectiveAlertRules` iterates in that order.
- `BuzzSequence NotificationPrefs.buzzSequenceFor(String ruleId)` —
  `alertRule(id).buzzSequence ?? BuzzSequence.defaultFor(alertRuleOrder.indexOf(id))`
  (unknown id → `defaultFor(0)`).
- `ChannelConfig` gains `BuzzSequence? buzzSequence` and
  `Map<String, BuzzSequence> appSequences` (default `const {}`), both in
  `copyWith`, `toJson` (`'buzzSequence'`, `'appSequences': {pkg: [..]}`) and
  `fromJson` (missing → null / empty).
  `BuzzSequence get effectiveSequence` = `buzzSequence ?? BuzzSequence.defaultFor(NotificationPrefs.alertRuleOrder.indexOf('relay'))`;
  `BuzzSequence sequenceForApp(String pkg)` = `appSequences[pkg] ?? effectiveSequence`.
- `RelayController` gains optional `Future<bool> Function(BuzzSequence)? playSequence`;
  `NotificationRelay.debugController` forwards an optional `playSequence:`.
  When set and `matchHaptics` is off, the band transport is
  `playSequence(cfg.sequenceForApp(pkg))` for apps (channel `effectiveSequence`
  for alarms/calls) and the List<int> `buzz` is not called. Production wires it
  to `playBuzzSequence` (source guard: notification_relay.dart contains
  `playBuzzSequence(`).
- AppState `_dispatchBandAlert`: band transport plays
  `prefs.buzzSequenceFor(ruleId)` through `playBuzzSequence(` (alarm and
  explicit `pattern` paths unchanged).

### UI (`buzz_pattern_ui_test.dart`)
- `NotificationSettingsView` gains `void Function(String ruleId)? onBuzzPattern`.
  Every alert row whose rule can reach the band
  (`destinationSupportReason(rule,'band') == null`) shows a control with key
  `ValueKey('buzz-pattern:<ruleId>')` containing the text `Buzz pattern`.
  Enabled iff the band destination is selected; otherwise disabled (8K).
- `BandNotificationsView` gains `void Function(String pkg)? onAppBuzzPattern`
  and `void Function(String channel)? onChannelBuzzPattern`; keys
  `ValueKey('buzz-pattern:channel:apps')` and `ValueKey('buzz-pattern:app:<pkg>')`.
- New `lib/ui2/profile/buzz_pattern.dart`:
  `BuzzPatternSheet({BuzzSequence? initial, bool bandConnected = false, Future<bool> Function(BuzzSequence)? onPlay, ValueChanged<BuzzSequence>? onSave, VoidCallback? onPhoneBuzz})`.
  Shows a `Tap your pattern` button driving a `BuzzRecorder`; text containing
  "phone must be connected" (any case) next to the band playback. When the
  recording ends it calls `onPlay(seq)` once if `bandConnected`, then shows
  `Save` (→ `onSave(seq)`) and `Record again` (clears the take).

## 8E — sleep window without data

`sleep_window_blank_test.dart` (*compile-safe*):
- `buildCrossDayBundle`: a day with `onset_sec`/`wake_sec` but `tst_min == null`
  is NOT RECORDED. It contributes nothing to `sleep_debt`, `social_jetlag`,
  `chronotype` or `sleep_coach` (no mid-sleep from the bare window, no wake
  time, no efficiency). Today the window's mid-sleep is counted, which breaks
  chronotype pairing ("8 vs 7") and moves social jetlag and bedtime.
- `sleep_coach.performance` is absent (`value == '—'`) when the LAST day is a
  blank night; it must not reach back to an earlier night (`_lastNum`).
- Changing these outputs needs a `kAlgoVersion` bump with a changelog entry.
- DB: a window set twice on a no-data night persists, metrics null, identical
  result (already true; pinned).
- Sleep screen: a night with no recording shows a `Set the times myself`
  button (today: `Set sleep times`). An asserted window with no data shows
  `You set this window` and no `0h 0m` / `0%`.

`sleep_schedule_settings_test.dart`: `MoreSettingsView` gains
`ExpectedSleepSchedule? expectedSleepSchedule` and
`VoidCallback? onEditSleepSchedule`; a row `Expected sleep schedule`, value
`Not set` when null, otherwise both local times (`23:00`, `07:00`). Always
present (no data needed).

## 8F — ChartScrub

`chart_scrub_test.dart`, `chart_key_readout_test.dart` — in
`lib/ui2/grammar.dart` (so `ui2.dart` exports it):
```dart
enum ChartScrubMode { line, nearest }
class ChartKey {            // one series: label (units in it), colour, value
  const ChartKey(String label, Color color, String? Function(double at) value,
      {double? latest = 1.0, bool Function(double at)? active,
       String? Function()? atRest});
  factory ChartKey.slots(label, color, List<double?> d,
      String Function(int i, double v) say, {bool bars = false});
  factory ChartKey.fixed(label, color, String? value, {active});
}
class ChartScrub extends StatefulWidget {
  const ChartScrub({super.key, required this.label, required this.keys,
      required this.child, this.time, this.gaps = false,
      this.mode = ChartScrubMode.line, this.step = .05});
  static const cursorKey = ValueKey('chart-scrub-cursor');
  static const noData = 'No data here';          // spoken only
  static int slotAt(int length, double at, {bool bars = false});
}
bool hasChartGaps(Iterable<List<double?>> series, {bool trailing = false});
class ChartKeyReadout extends StatelessWidget { ... }
```
Built on `Scrubber` (one `Scrubber` descendant; its `describe` says the time and
`label value` for each series that has one, else `No data here`). Nothing is
drawn before a touch. Tap/drag: in `line` mode a cursor (key `cursorKey`)
centred on the finger x (±2 px); `nearest` mode: no cursor. THERE IS NO TOOLTIP.
The values go to a `ChartKeyReadout` row under the chart: the time first
(`Latest` at rest, `Selected` while scrubbed), then a cell per series
(`chart-key-cell:<label>` holding a `chart-key-swatch:<label>` and the value
`chart-key-value:<label>`). The value sits under the swatch, in the legend
entry's own column. Inside a `ChartFrame` the row IS the frame's key (legend
entries match series by label; extra series are appended); bare, `ChartScrub`
draws its own row under the chart. At rest the row shows the latest point; with
no data every value is `—`; an absent value is `—`, never 0. The row's height
does not change with what it says. A `Not recorded` cell is appended only when
`gaps` is true (callers pass `hasChartGaps(series)`).

`chart_scrub_guard_test.dart` (*compile-safe*): in
`lib/ui2/{screens,activity}/**/*.dart`, `lib/ui2/live_hr.dart` (and
`lib/ui2/profile/live_devices.dart` once it exists) every
`painter: (LineChart|Bars|Hypnogram|ZoneBar|Actogram|HeatMap|Spectrum|Poincare|NightStack|DayLanes)(`
must be lexically inside the argument list of a `ChartScrub(` or `Scrubber(`
call in the same file (comments/strings ignored). A helper that builds the
painter must contain the wrapper itself. 47 sites fail today.

## 8C — sections everywhere

`settings_accordion_test.dart`: `SettingsAccordion(String title, {Key? key, required List<Widget> children, String? summary, bool initiallyExpanded = true})`
— expanded by DEFAULT; when collapsed shows `summary` under the header as one
line (`maxLines: 1`, `TextOverflow.ellipsis`); the header never moves when
toggled.

`settings_sections_test.dart` (*compile-safe*): each of `MoreSettingsView()`,
`NotificationSettingsView(relaySupported: true)`,
`BandNotificationsView(enabled: true, granted: true)`,
`AlarmScreenView(connected: true, schedule: …)`, `BandGesturesView(...)`,
`DeviceDetailView(band)`, `EditProfileView(onSave: …)` has ≥ 1
`SettingsAccordion` and every accordion's first child is built without a tap.
Settings has a `The band` section; Band notifications' three channel sections
are open (three `Buzz during Do Not Disturb` rows). Notifications' `Device`
header does not move when water is switched on.

`settings_sections_new_views_test.dart`: new pure views
`DataScreenView()` (`lib/ui2/profile/data.dart`) and
`AutomationSettingsView()` (`lib/ui2/profile/settings.dart`), all params
optional, no Provider needed; same section rule. `DataScreen` /
`AutomationSettings` become thin wrappers.

## 8J — Alarm sections (`alarm_sections_test.dart`, *compile-safe*)

`AlarmScreenView` sections, in order: `Alarm`, `Wake`, `Haptics`, `Status`,
all expanded. `Wake` contains `Natural Wake` and `Gradual Wake` (disabled with
a reason until phase 6 is fine). `Haptics` contains `Buzz pattern`. `Status`
contains the arm-state label (e.g. `Confirmed`). Each section, once collapsed
by a header tap, still shows ≥ 1 non-empty line besides its title (the
`summary`). Disconnected: still four sections, the reason
`The band is not connected` once, one `Wake time` row per day (7), all dimmed.
Connected: a day that is off keeps its `Wake time` row, dimmed.

## 8K — disable, never reveal (`disable_not_hide_test.dart`, *compile-safe*)

Widget checks (present + dimmed + inert): Alarm `Wake time` on an off day
(no `TimePickerDialog`); Notifications `Remind me every` (water off) and
`Alert me at` (band alerts off), `onChanged` not called, and not dimmed when
the parent is on; Band notifications with relay off: `Apps that can buzz` and
each app row (tap does not call `onApp`), apps channel `Starts`/`Ends` with
quiet hours off, alarms channel `Fallback rhythm` with matching off; Gestures
replay switch with Mark moment off (`Switch.onChanged == null`); Settings
`Target zone` with zone alert off.

Source guard over `lib/ui2/profile/{settings,band_notifications,alarm,gestures,data}.dart`:
a collection-`if` whose body is a row (`SetRow`, `SetRow.brand`, `SwitchRow`,
`_AlertRow`, `_AppRow`, `row(`), a `...[` list with such a direct child, or a
`..._xxxRows(` spread, is flagged unless every `&&`/`||` term of the condition
(after stripping `!` and parens) matches the allow-list:
`Platform.isX`, `defaultTargetPlatform…`, `android|ios|isAndroid|isIOS`,
`…supported`/`…Supported`, `x.supportsY`, `appIcon != null`,
`showHealthShare|showUpdateChecks|devMode|loaded`, `version.isNotEmpty`,
`name == …`. Status/permission cards are `StatusCard`, never matched. 8 sites
fail today: settings.dart (zone alert, water, device), band_notifications.dart
(matchHaptics, quiet hours, `enabled && granted`), alarm.dart (`day.enabled`),
gestures.dart (`chosen.contains(a)`).

## 8A — navigation depth

`nav_depth_test.dart`: `ProfileHomeView` gains `VoidCallback? onLiveDevices`
and a Quick-access row `Live devices`. `MoreSettingsView` gains
`bool relaySupported = false`, `VoidCallback? onBandNotifications`,
`VoidCallback? onGestures`; the `The band` section has rows `Alarm`,
`Band notifications` (only when `relaySupported`) and `Gestures`. Walks from
Profile: Live devices depth 1; Band notifications / Gestures / Alarm depth 2;
Notifications, Data, Automation, Expected sleep schedule ≤ 2.

`nav_depth_guard_test.dart` (*compile-safe*):
- `docs/navigation-depth.md` exists with one markdown table whose header has
  `Screen`, `Before`, `After`; paths written `Profile → A → B` (U+2192); every
  `After` starts with `Profile` and has ≤ 2 arrows; `Before` never shallower.
  Rows required: Settings, Notifications, Band notifications, Gestures, Alarm,
  Automation, Data, Device detail, Edit profile, Live devices. (Device lab is a
  tool, not a settings screen: leave it out or keep it ≤ 2.)
- `_MoreSettingsState` passes `onBandNotifications:` → `BandNotifications()`,
  `onGestures:` → `BandGestures()`, `relaySupported:`, `onEditSleepSchedule:`,
  `expectedSleepSchedule:`. `_ProfileHomeState` passes `onLiveDevices:` →
  `LiveDevices()`. `_DeviceDetailState` passes `onDeviceLab:` → `DeviceLab(`.

## 8B — Live devices (`live_devices_test.dart`)

New `lib/state/live_stream_buffer.dart` (imports nothing from db/sqflite/
shared_preferences/path_provider/dart:io; no `LocalDb`):
```dart
class LiveSample { const LiveSample(this.at, this.value); final DateTime at; final double value; }
class LiveStreamBuffer {
  LiveStreamBuffer({this.window = const Duration(seconds: 30)});
  final Duration window;
  bool add(String deviceId, String streamKey, DateTime at, double value); // false = dropped (older than the stream's last sample)
  List<LiveSample> samples(String deviceId, String streamKey, {required DateTime now}); // now - at < window
  List<LiveSample> retained(String deviceId, String streamKey); // what is held
  List<String> streamKeys(String deviceId); // first-seen order; keys stay after their samples age out
  Iterable<String> get deviceIds;
  void clear();
}
```
Eviction: visible at 29 999 ms, gone at exactly 30 000 ms; `add` evicts
samples with `newest - at >= window` from that stream. Out-of-order is per
(device, stream). AppState constructs one (`LiveStreamBuffer(`) exposed as
`liveStreams`, fed from the live callbacks; never persisted.

New `lib/ui2/profile/live_devices.dart`:
`class LiveDevice { const LiveDevice({required String id, required String name, required String kind, required bool connected, double? batteryPct, DateTime? lastSeen}); }`,
`LiveDevicesView({required List<LiveDevice> devices, required LiveStreamBuffer buffer, required DateTime now})`,
`LiveStreamChart` (one per stream with in-window data on a CONNECTED device,
each containing one `ChartScrub`), `String liveStreamLabel(String key)` (known
keys → human label ≠ key; unknown → the key), and the route wrapper
`class LiveDevices` reading AppState. Card shows name, kind, battery
`78%`. Empty stream → `No data in the last 30 s` (no chart). Disconnected →
text containing `Last seen`, no charts, no empty-stream lines. No devices →
text containing `No device`.

## 8I — Device lab

`ecg_double_tap_test.dart`:
- `GestureSettings`: `bool get ecgOnDoubleTap` (default false),
  `Future<void> setEcgOnDoubleTap(bool)` (notifies), persisted as
  SharedPreferences bool `gesture_ecg_on_double_tap`, read in `bootstrap`.
- `GestureDispatcher` gains `bool Function()? ecgSupported` and
  `Future<void> Function(StrapEvent)? onEcgTap`. For event 14, when
  `settings.ecgOnDoubleTap && e.isLive && ecgSupported?.call() == true`, call
  `onEcgTap(e)` once per occurrence: claim key `gesture:${e.identity}:ecg`
  (receipt debounce for implausible clocks, as for actions); a throw releases
  the claim. Works with no actions mapped. None for late taps, switch off,
  non-MG, other ids.
- 8L: while `ecgOnDoubleTap` is on, normal double-tap actions are suspended:
  handlers not called, no `ran` outcome. Off → actions run as before.

`device_lab_test.dart` — new `lib/ui2/profile/device_lab.dart`:
- `class DeviceLabEntry { const DeviceLabEntry({required int eventId, required DateTime eventTime, required DateTime receivedAt, required bool live, List<String> actions = const []}); factory DeviceLabEntry.fromEvent(StrapEvent e, {List<GestureOutcome> outcomes = const []}); Duration get delay; String get delayLabel; }`
  — `eventTime = e.effectiveTime`, `receivedAt = e.receivedAt`,
  `live = e.isLive`, `actions` = ids of `ran` outcomes, `delay = receivedAt - eventTime`,
  `delayLabel` = seconds with one decimal + `' s'` (`'1.2 s'`).
- `String labClock(DateTime t)` — local `HH:mm:ss.SSS`.
- `DeviceLabView({required bool ecgSupported, bool ecgOnDoubleTap = false, ValueChanged<bool>? onEcgOnDoubleTap, List<DeviceLabEntry> entries = const []})`
  — a row with exactly `Toggle ECG recording on double tap` and a `Switch`;
  non-MG: switch disabled (`onChanged == null`) + text
  `This band has no ECG sensor`. Log rows show `labClock` of both times,
  `delayLabel`, and `Live`/`Late`. Also a `DeviceLab` route wrapper.
- `DeviceDetailView` gains `VoidCallback? onDeviceLab`; band → row `Device lab`.
- 8I note copy (DeviceLabView and, in `gestures_copy_test.dart` *compile-safe*,
  BandGesturesView): text containing `WHOOP MG`, `WHOOP 4.0 has no ECG sensor`,
  and a line matching `/3–5 tap rows are a draft/i` (the earlier "not available
  until measured" line described the dropped IMU classifier). Never names a single tap
  (`one tap|single tap|1 tap`).

## 8L — draft 3–5 taps

`ecg_tap_counter_test.dart` — new `lib/gestures/ecg_tap_counter.dart`, pure
(no Flutter, no clock, no DB). All `at` values are ECG SAMPLE time as
`Duration` on the stream clock.
```dart
class EcgTapThresholds {
  EcgTapThresholds({int startMs = 300, int gapMs = 200, int confirmMs = 200});
  static const stepMs = 50;
  static const startRange = (200, 1100), gapRange = (100, 1000), confirmRange = (100, 1000);
  final int startMs, gapMs, confirmMs;
  Duration get start, gap, confirm;
  EcgTapThresholds copyWith({int? startMs, int? gapMs, int? confirmMs});
  // value ==, hashCode
}

sealed class EcgTapOutput { const EcgTapOutput(this.at); final Duration at; }
final class EcgTapBuzz extends EcgTapOutput { const EcgTapBuzz(super.at, {this.pulses = 1}); final int pulses; }
final class EcgTapDone extends EcgTapOutput { const EcgTapDone(super.at, this.count); final int count; }
final class EcgTapAbandoned extends EcgTapOutput { const EcgTapAbandoned(super.at, this.reason); final String reason; }

class EcgTapCounter {
  EcgTapCounter({required int max, EcgTapThresholds? thresholds,
      Duration stallAfter = const Duration(milliseconds: 500)}); // max 2..5 else ArgumentError
  int get max; EcgTapThresholds get thresholds; Duration get stallAfter;
  int get count; bool get started; bool get finished;
  List<EcgTapOutput> start(StrapEvent tap, {required Duration at});
  List<EcgTapOutput> ackDone(Duration at);
  List<EcgTapOutput> sample(Duration at, {required bool contact});
  List<EcgTapOutput> tick(Duration at);
  List<EcgTapOutput> linkLost(Duration at);
}
```
**Thresholds are REJECTED, never clamped:** the constructor and `copyWith`
throw `ArgumentError` for a value outside its range or not a multiple of
50 ms. `thresholds == null` means `EcgTapThresholds()`.

Rules (every input after `finished`, or before a successful `start`, returns
`[]`). `S`, `G`, `C` = start, gap, confirm thresholds (defaults 300/200/200):
- `start`: non-live tap → `[]`, `started` false. Live → `count = 2`,
  `[EcgTapBuzz(at, pulses: 2)]`; if `max == 2` also `EcgTapDone(at, 2)`.
- Samples before `ackDone` are ignored. `ackDone(T)` opens the first window
  `[T, T+S)`.
- Contact start = first `contact: true` sample after no contact; contact end =
  first `contact: false` sample after contact. Engage = contact continuous
  for ≥ G (any no-contact sample before that discards the candidate).
  Release = no contact for ≥ G; contact back sooner is the same touch.
- A touch counts only if it STARTS before the open window's deadline
  (exclusive) and then engages: `count++`, one `EcgTapBuzz(engageAt)`; at
  `count == max` also `EcgTapDone(engageAt, count)` with no further buzz.
  While a candidate that started in time is still pending at the deadline,
  wait for it. One buzz per added tap (no multi-pulse count buzzes).
- After an engaged touch ends at E, the next window is `[E+G, E+G+C)`.
- A deadline reached by a SAMPLE with no pending candidate →
  `EcgTapBuzz(at)` + `EcgTapDone(at, count)`. Deadlines are checked before the
  sample's own contact state.
- `tick(now)`: only stall detection — `now - lastSampleAt >= stallAfter`
  (last sample, or `ackDone` time before any sample) → `EcgTapAbandoned`.
  Ticks never confirm a count. `linkLost` → `EcgTapAbandoned`.

`gestures_draft_taps_test.dart`:
- `GestureSettings.actionsForTaps(int n)` (2..5, else `ArgumentError`; `n == 2`
  is `doubleTapActions`), `Future<void> setActionsForTaps(int n, Set<DeviceAction>)`
  persisted as bitmask int `gesture_tap_actions_<n>` for 3..5, and
  `int get maxMappedTaps` (highest n with actions, 2 when none of 3..5).
- `GestureSettings.ecgTapThresholds` (default `EcgTapThresholds()`),
  `Future<void> setEcgTapThresholds(EcgTapThresholds)` (notifies), persisted
  as ints `gesture_ecg_start_ms`, `gesture_ecg_gap_ms`,
  `gesture_ecg_confirm_ms`. On load, an invalid stored field falls back to
  that field's default; the others keep their stored values.
- `BandGesturesView` gains `bool ecgSupported = false`; rows titled exactly
  `2 taps`, `3 taps`, `4 taps`, `5 taps` (no `1 tap`); 3–5 carry a `Draft`
  label (exactly three texts containing `Draft`); non-MG: 3–5 dimmed and the
  text `This band has no ECG sensor`; `2 taps` never dimmed.

`device_lab_test.dart` (8L part): `DeviceLabView` gains
`EcgTapThresholds? thresholds` and `ValueChanged<EcgTapThresholds>? onThresholds`.
Three adjusters labelled `Start threshold`, `Gap threshold`,
`Confirmation threshold`, values shown as `<n> ms`, step buttons keyed
`ValueKey('ecg-threshold:<start|gap|confirm>:<+|->')` moving 50 ms; a button
at its range edge does nothing; all inert on a non-MG band. The gap
adjuster's caption says it sets both the touch and the let-go time (text
matching `/touch.*let go|let go.*touch/i`).

## Proof views (`test/proof/phase8_views_test.dart`)

Same harness as `affected_views_test.dart` (imports its `loadFonts`). Cases ×
light/dark × 1x/2x, goldens `test/proof/goldens/phase8_<case>_<b>_<s>x.png`:
`live_devices`, `device_lab_mg`, `device_lab_no_ecg`, `buzz_pattern`,
`collapsed_taps`, `gestures_draft_taps_no_ecg`, `chart_scrub_readout` (taps
25 % across before capture). No baselines are committed; generate with
`--update-goldens` after implementation, review, then commit.
