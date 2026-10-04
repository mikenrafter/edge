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

`AlarmScreenView` sections, in order: `Alarm`, `Wake`, `Status` (8AE removed the
`Haptics` group; its disabled `Buzz pattern` row is gone and `Wake` carries the caption
`The alarm uses the band's own buzz.`), all expanded. `Wake` contains `Natural Wake` and
`Gradual Wake` (disabled with a reason until phase 6 is fine). `Status` contains the arm-state label (e.g. `Confirmed`). Each section, once collapsed
by a header tap, still shows ≥ 1 non-empty line besides its title (the
`summary`). Disconnected: still three sections, the reason
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
`name == …`, and (8AE) `cfg.overrideQuietHours`: a channel's own Starts and Ends exist
only while it overrides the global quiet hours. Status/permission cards are `StatusCard`,
never matched. 8 sites
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

---

## Buzz delivery, ECG readiness, double-tap counting, lab logs (Oct 2)

- `BleEngine.buzzBand({holdMs})` is delivered when the GATT write lands. The band's
  correlated reply is only logged ("Band replied success in N ms" / "No reply from
  the band within N ms") through `log` and `onBuzzDiagnostic`; it never gates.
  MG hold >= 500 ms uses overallLoop 2; gen4 plays a long hold as one short pulse.
  Tests: `test/ecg_ble_engine_test.dart`, `buzz_delivery_test.dart`.
- ECG sessions request the two-pulse ack only after `EcgStreamReadiness` (SUPERSEDED
  by the review-fix section below: sample-clock continuity, not just "a second
  packet within 1.5 s"). `startTimeout` is 20 s (`no_stream`).
  `ack_failed` only when the ack write itself failed.
- `DoubleTapRepeatSession` (lib/gestures/double_tap_repeat.dart): the method that
  needs no ECG. Slot n = n taps for both methods; labels differ per method.
  `GestureSettings.tapMethodFor(ecgSupported:)`, `repeatTapWindowMs` (1000..5000 in
  250 ms, default 2500), `repeatTapsLab`.
- Device lab lines: `time | tap +N ms | last +N ms | text`; `labLogText` feeds the
  pinned "Copy all logs" button.

## Review fixes: ECG taps, repeated double taps, band buzz (Oct 2, supersede the above where they differ)

Tests: `test/gestures/ecg_tap_counter_gap_test.dart`, `ecg_stream_readiness_test.dart`,
`ecg_sample_clock_test.dart`, `ecg_tap_session_clock_test.dart`,
`ecg_tap_begin_test.dart`, `ecg_tap_session_lifecycle_test.dart`,
`double_tap_repeat_grouping_test.dart`, `double_tap_repeat_claims_test.dart`,
`test/phase8/buzz_delivery_tristate_test.dart`.

- **E, sample gaps (`EcgTapCounter.maxSampleGap`, default 50 ms = 10 ms sample period
  + 40 ms tolerance).** Contact and no-contact only count when OBSERVED. Consecutive
  samples further apart than that are a discontinuity: a pending engage candidate is
  dropped (contact must be seen again for the full gap threshold); a release timer
  restarts at the first sample after the hole and contact that returns after a hole
  is the same touch; a hole that swallows a window deadline abandons the gesture with
  reason `sample_gap` (no confirm buzz, no action: whether a touch started in the
  unseen part cannot be known); a hole that ends before the deadline only costs the
  unseen time. The first sample after `ackDone` is checked against the ack boundary.
  This replaces "contact already present at ack counts after 200 ms" across a 600 ms
  unobserved gap (`ecg_tap_session_test.dart` now continues the clock at 1002.4).
- **F, readiness and the ack boundary.** `EcgStreamReadiness.offer({at, strapTime,
  sampleCount = 100})` is steady when two consecutive packets are contiguous on the
  sample clock (start within 50 ms of the previous end), advance in step with the wall
  clock (within 600 ms) and arrive <= 1.5 s apart. A stale burst (1 s of samples in
  20 ms) and strap-clock jumps (100 -> 1000) are not steady. `EcgSampleClock` maps phone
  time to sample time through the LEAST-delayed of the last 8 packets (min of receipt
  minus newest-sample time). The first touch window opens at the ack-write wall time
  mapped through it (the old "end of last packet + wall since arrival" anchored the
  window behind the true sample clock by however late that packet was). Trace lines:
  each `Packet N:` line ends with `<continuity>, received X ms behind the freshest
  packet so far`; the window line is preceded by `Sample clock: ...` naming how many
  ms later than the receipt-time estimate the boundary is. Stall detection still uses
  time since the last packet RECEIVED.
- **G, late starts.** `EcgTapSession.generation` bumps per gesture. `beginEcgForTap`
  (lib/gestures/ecg_tap_begin.dart) checks the generation after the wrist lookup and
  after `ecg.begin`, never starts for a dead gesture, and stops a capture it started
  for one, only if `EcgController.captureEpoch` still matches (an ECG the user started
  is never stopped). A new `start()` waits (<= `endTimeout`) for the previous
  gesture's stream stop.
- **R, 8N interval.** `_finish`: flags reset -> `onFinished` -> stop the stream (if it
  was up, or the start timed out) -> `recordSession` with `strapEnd = max(last packet
  end, strapNow-after-stop + 1)` (whole-second clock, rounded up). A slow database can
  no longer leave recorded ECG outside the interval or keep the stream running.
- **H, tri-state buzz.** `deliverBuzzSequence` -> `BuzzDelivery {complete, rejected,
  partial, unknown}`; `playBuzzSequence` keeps its `Future<bool>` (true only for
  complete). `AlertDispatcher.dispatch(bandDelivery:)` and the `bandSequenceDelivery`
  ctor param release the claim ONLY for `rejected`; `partial`/`unknown` keep it
  (outcome reason `deliveryUnconfirmed`). `BleEngine.buzzBand({maxQueueWait =
  buzzQueueDeadline (5 s)})` drops a write still queued after its deadline.
  AppState (`_ecgTapBuzz`, preview, `_dispatchBandAlert`, default sequence transport)
  and the relay use the tri-state path (`_dispatchBandAlert` source guard now looks for
  `deliverBuzzSequence(`).
- **I, repeat grouping.** `DoubleTapRepeatSession.offer(e)` -> `RepeatOffer {counted,
  ignored, newGroup}` (`add` = `offer == counted`). While the strap clock is
  believable a tap joins only within the window (inclusive) of a member's band time;
  later and further -> the open group is finished and the tap starts the next
  (`newGroup`); earlier than every member by more than the window -> ignored;
  an older tap inside the window is a member (bounded reordering). Receipt time is
  the fallback for implausible clocks. The window timer still runs on the phone clock.
- **J, member claims.** `GestureDispatcher._repeatTap` claims every tap
  (`gesture:<identity>:rep`, plausible clocks) before the session accepts it. A claim
  that fails or is already held skips the tap; counted/ignored members keep their
  claim; a `newGroup` member opens its window with the claim it already holds.

## ECG taps: one clock, count buzz first (Oct 2 lab log; supersedes the ack above)

Tests: `test/phase8/ecg_tap_counter_test.dart`, `test/gestures/ecg_tap_session_test.dart`,
`ecg_tap_session_clock_test.dart`, `ecg_stream_readiness_test.dart`,
`ecg_tap_session_lifecycle_test.dart`, `ecg_gesture_session_record_test.dart`,
`test/phase7/gesture_failure_test.dart`, `device_lab_test.dart`,
`gestures_draft_taps_test.dart`.

- **Packet time.** An R17 packet's strap time is its NEWEST sample; its `n` samples
  cover `[strapTime - n*10 ms, strapTime)`. `EcgStreamReadiness.offer(strapTime:)`
  takes the same meaning (a 49-sample packet then a full one is continuous). The 8N
  interval floors the first packet's first sample and ceils the last packet's time.
  Packet trace lines read `N with contact (samples a–b), strap time X (newest sample)`.
- **No acknowledgement.** `EcgTapCounter.ackDone` is now `open(at)`. `start` emits
  nothing (max 2: `[EcgTapBuzz(pulses: 2), EcgTapDone(2)]`). In the first window an
  engage is tap 3 with `EcgTapBuzz(pulses: 3)`; later engages buzz once. A deadline at
  count 2 → `[EcgTapBuzz(pulses: 2), EcgTapDone(2)]`; at count ≥ 3 → one confirm buzz
  + done. Reaching max: the count buzz only. `ack_failed` no longer exists.
- **One clock.** `EcgTapSession` opens the window once the stream command returned and
  packets are steady, at `max(firstSample + sensorSettle, newest packet end)` on the
  sample clock (`sensorSettle` default 2500 ms). Contact already present at the
  boundary counts. `EcgSampleClock` only feeds the per-packet "behind" figure.
- **Contact within a packet.** `EcgTapThresholds.extraSensitive` (default false; part
  of `==`, `copyWith`, and `summary` as `, extra sensitive`). Off: samples between a
  packet's first and last non-zero sample are contact. On: each sample on its own.
  Persisted as bool `gesture_ecg_extra_sensitive`. `EcgThresholdAdjusters` shows a
  `SwitchRow` `Extra sensitive subsequent tap detection` keyed
  `ValueKey('ecg-threshold:extra-sensitive')`, inert on a non-MG band.
- **Buzz pacing.** Buzzes run in order on one tail. Before each, the session waits
  until `buzzQuietGap` (default 1200 ms) after the previous buzz finished writing
  (kept across gestures; `wait` is injectable). A buzz that cannot be written is
  logged (`Buzz xN could not be written`) and the count stands.

## 8V: the band's own timing, measured and replayable (Oct 2, 18:17 lab log)

Evidence and the fitted model: `docs/hardware/whoop-mg-haptics-and-ecg.md`. Tests:
`test/hardware/*`, `test/gestures/ecg_tap_session_test.dart`,
`ecg_tap_session_clock_test.dart`, `test/ecg_controller_test.dart`.

- **Gesture mode in the ECG controller.** `EcgController.begin(wrist, persist: false,
  trace:)`: an `EcgSendRestart` is NOT sent and an `EcgFail('interruptions')` does
  NOT end the capture (both go to `trace`); every frame is still forwarded. Other
  fails (progress 255) and terminals end it as before. An ordinary reading is
  unchanged. `trace` also gets `ECG start: <stage> (+N ms, M ms in).` for wrist
  saved, guard checked, history sync paused, guard set, prepare answered, start
  answered; `beginEcgForTap` adds `ECG start: wrist looked up (N ms).`
- **Reacquire.** `EcgTapCounter(reacquire:)` (default zero) is added to every window
  after a lift: `[E+gap, E+gap+reacquire+confirm)`. `EcgTapSession.sensorReacquire`
  defaults to 1500 ms.
- **Bursts.** (Superseded by 8W, then by 8AF.6: the default is now 5, one call per count.) `EcgTapSession.maxPulsesPerBurst` (was 2): a count buzz of N pulses is
  `buzz(2)`, then `buzz(1)` …, each a separate call with event id `<id>` then
  `<id>:b<k>`, each after `buzzQuietGap` (now 1800 ms) from the previous write. Log
  lines: `Buzz x3, pulses 1–2 written…`, `Buzz x3, pulse 3 waits N ms…`. A burst that
  could not be written ends that buzz.
- **Packet lines** end with `; band: presence on|off, S2 n, flags 0x.., progress n,
  quality n[, unreadable a+b]`.
- **Post-roll (lab only).** `EcgTapSession(postRoll:)` (AppState: 3 s while
  `ecgOnDoubleTap`): after a COUNTED end the result is reported at once; the stream
  stop waits `postRoll`, logging `After the count, packet N: …` lines (never counted);
  the 8N interval covers them. No post-roll after an abandon.
- **Packets for replay.** `EcgTapSession(onPacket:)` → `DeviceLabLog.addPacket(r, at,
  {tag})` (RAM, max 360, cleared by `clear`). `labLogText(packets:)` ends with
  `ECG packets, oldest first`, a `format:` line and one `labPacketLine` per packet
  (`r17v1 tag=<tag> | recv= sec= sub= flags= s2= progress= quality= unreadable= n=
  b64=`; `b64=0` for all-zero). `DeviceLabView(packets:)` copies them.
  `DeviceLabLog.endSession(result:)` overrides the summary's outcome.
- **Probes.** `lib/gestures/hardware_probes.dart`: `HapticProbe` (trials of single
  buzzes at spacings 200–1600 ms, ≤ `maxCommands` 30, rest 2 s, `askFelt` after each,
  `onBandEvent`, per-command reply via `BleEngine.buzzBand(onReply:)`) and
  `EcgTouchProbe` (stream ≤ `maxStream` 60 s, always stopped in `finally`; cue script;
  `analyzeTouchProbe`, `contactRuns`). `HardwareProbeRunner` (one probe at a time;
  refuses with a `note`; logs a lab session) is `AppState.hardwareProbes`; its buzz is
  a dispatcher delivery (`hardware_probe` rule). `DeviceLabView(probes:)` shows a
  `Hardware probes` section; `HardwareProbePanel` stops a running probe on dispose and
  vibrates the phone on each ECG cue.
- **Replay and the virtual band** (`test/support/ecg_trace.dart`, `virtual_mg.dart`):
  `Trace.parse` reads `r17v1`/`session` lines (a whole copied log parses);
  `replayTrace` runs a real session over them. The 18:17 fixture replays to the band's
  counts with no reacquire, and session 18:19:10 counts tap 4 with it.


## 8W: one command is one bzz-bzz; the pattern probe (Oct 2, 20:40 lab log)

(The pattern probe's question flow, runner and panel below are replaced by the
transcriber in 8Y; the payload, engine and count-buzz parts stand.)

Evidence: `docs/hardware/whoop-mg-haptics-and-ecg.md` (L3). Tests:
`test/hardware/buzz_pattern_test.dart`, `pattern_probe_test.dart`,
`pattern_probe_panel_test.dart`, `virtual_mg_test.dart`, `hardware_probes_test.dart`,
`hardware_probe_panel_test.dart`, `probe_wiring_guard_test.dart`;
`test/gestures/ecg_tap_session_one_command_test.dart` and the other gesture tests;
`test/phase7/audit_guards_test.dart`, `gesture_failure_test.dart`.

- **Count buzzes.** One band command plays as one "bzz-bzz"; a command written while
  the band plays is answered "pending" and not played, and the band then ignores the
  next command for ~1 s. 8AF.6: `EcgTapSession.maxPulsesPerBurst` defaults to 5, so a
  count of N is ONE `buzz(N, id)` call. `AppState._ecgTapBuzz` hands it to
  `GestureCues.response(N)` (`lib/haptics/gesture_cues.dart`): the start cue
  (`gesture.start`, the pair) then N-1 follow-ups (`gesture.followUp`, one fastest
  single) with the fastest gap (0 ms) between them, all ONE band queue job that
  writes each command only after the band's ended event for the one before. The
  action-done ack is `GestureCues.confirm()` (`gesture.confirm`) through
  `ackTap(..., bandDelivery:)`; the fail buzz stays the long buzz. A band with no
  haptic profile (4.0) plays N plain pulses 300 ms apart in one job. The
  one-pulse-per-call pacing (`maxPulsesPerBurst: 1`, 8W: each call at least
  `buzzQuietGap` (1800 ms) after the previous write) stays available and pinned. A
  burst that cannot be written still ends that buzz.
- **Payload.** `AlarmPayloads.gen5MaverickPattern(effects, {loop = 1})` is
  `[0x01, ...effects padded to 8, 0, 0, loop]` (12 bytes); `ArgumentError` unless
  1-8 effects, each 1-255, and loop 1-3. `gen5MaverickBuzz(overallLoop: 1)` equals
  `gen5MaverickPattern([47, 152])`.
- **Engine.** `BleEngine.buzzMaverickPattern({effects, loop, maxQueueWait, onReply})`
  is `buzzBand` for a custom pattern; false and nothing written when not connected,
  not gen5, or the payload is invalid. Probe buzzes still go through
  `AlertDispatcher.dispatch` (`AppState._probePattern`, rule `hardware_probe`).
- **`PatternProbe`** (`lib/gestures/hardware_probes.dart`): 32 `defaultTests` (4
  `BuzzWaveform`s x 4 `BuzzStyle`s x counts 2 and 3, cycling), at most
  `maxCommands` (56) commands per run (the default needs 48; the constructor throws
  above the limit), 3 s rest after each test, settle on the band's event 100 or 3.5 s,
  then `askFelt` -> `PatternAnswer(buzzes, sequences)`. A test where nothing was
  written ends the run; Stop and a lost link end it; flags reset in `finally`.
- **Runner and panel.** `HardwareProbeRunner.runPattern()` (`ProbeKind.pattern`;
  refuses: not connected, another probe running, band not an MG), `patternQuestion`,
  `patternQuestionIndex`, `patternTestCount`, `answerPattern(buzzes, sequences)`;
  lab session `Pattern probe`, settings `32 tests: 4 waveforms × 4 ways of sending ×
  2 counts`. The buzz probe's question asks how many "bzz-bzz" were felt.
  `HardwareProbePanel`: `probe-pattern` button with the safety caption,
  `probe-buzzes-0..6` / `probe-buzzes-skip`, `probe-groups-0..4` /
  `probe-groups-skip`, `probe-pattern-next` (enabled once both rows have a choice),
  `probe-stop`. No golden covers the panel.
- **Virtual band.** `VirtualMgHaptics.command(atMs)` plays when idle, swallows
  ("pending") while playing and goes deaf (no reply) for 1100 ms after a swallow.
  `VirtualMgEcg(touchLatencyMs: 1900)` shows a touch from the first 100 ms grid
  point at or after landing + latency, and not at all if that is past its end.
  The "reacquire hold" parameters are gone.

## 8X: block contact, quick start, ECG failure (Oct 2)

Tests: `test/gestures/ecg_contact_test.dart`, `ecg_tap_session_contact_test.dart`,
`ecg_tap_session_failure_test.dart`, `ecg_tap_session_test.dart`,
`ecg_tap_session_lifecycle_test.dart`, `ecg_tap_session_clock_test.dart`;
`test/phase8/ecg_tap_counter_test.dart`, `gestures_draft_taps_test.dart`,
`device_lab_test.dart`, `ecg_gesture_session_record_test.dart`;
`test/hardware/virtual_mg_test.dart`, `lab_trace_replay_test.dart`,
`probe_wiring_guard_test.dart`; `test/phase7/gesture_failure_test.dart`,
`audit_guards_test.dart`.

- **Contact.** `ecgContactMask(samples, {blockSamples = 5, minRunBlocks = 2})`
  (pure): a 50 ms block is contact when any sample in it differs from the one
  before it (the packet's first sample has no predecessor); flat blocks are no
  contact; a run of fewer than `minRunBlocks` contact blocks is dropped unless it
  touches the packet's first or last block. `EcgTapSession.onFrame` and the
  packet log line use it; extra-sensitive off fills from the first to the last
  mask-contact sample. The touch probe's `contactRuns` keeps the raw non-zero
  rule. `VirtualMgEcg(dcOffset)` adds a constant to every sample.
- **Settings.** `EcgTapThresholds.tolerantStartup` and `fallbackToDoubleTap`, both
  default true, in `==`, `hashCode`, `copyWith`; `summary` appends ", quick start"
  when tolerant startup is off and ", no fallback" when the fallback is off.
  Persisted as `gesture_ecg_tolerant_startup` and `gesture_ecg_fallback` (missing
  is true). Device lab switches `ecg-threshold:tolerant-startup` and
  `ecg-threshold:fallback`.
- **Quick start** (tolerant startup off). If the first packet with samples has no
  contact (mask, before the fill), the count is 2 at once: `EcgTapBuzz(pulses: 2)`
  and `EcgTapDone(2)` from `EcgTapCounter.noFinger(at)` (only while started, not
  finished and awaiting the window). With contact it carries on as with tolerant
  startup.
- **ECG failed** means the gesture would end abandoned: `start_failed`,
  `no_stream`, `stalled`, `link_lost`, `sample_gap`.
  - Failure buzz, every time, any mode: `EcgTapSession.failBuzz(eventId)`, called
    once per failed gesture with `<gesture id>:failed`, queued on the same tail as
    the count buzzes (waits `buzzQuietGap`). `AppState._ecgTapFailBuzz` dispatches
    `kEcgTapRule` with `engine.buzzBand(holdMs: 600)` (one command looped twice,
    a long buzz).
  - Fallback on and no touch counted (count 2): the gesture ends `onFinished(2,
    'fallback: <reason>')`; a failed stream start does not throw. No retry.
  - Fallback off: a failure before the touch window opened stops the stream and
    starts it once more in the same gesture (`active` stays true, one lab session,
    same generation). A second failure, or any failure after the window opened,
    ends abandoned (count null) with the failure buzz. A start that fails twice
    throws as before.
  - A failure after a touch was counted (count 3 or more) is abandoned whatever
    the toggle. The retry counter and the failed-buzz state reset per gesture.

## 8Y: the pattern probe as a transcriber (Oct 2, 22:27 lab log)

Evidence: `docs/hardware/whoop-mg-haptics-and-ecg.md` (L4). Tests:
`test/gestures/pattern_transcript_test.dart`, `test/hardware/pattern_probe_test.dart`,
`pattern_probe_panel_test.dart` (runner and panel), `pattern_probe_page_test.dart`
(page); `test/ui2_tokens_test.dart` (the page is listed with the panel).

- **Model** (`lib/gestures/pattern_transcript.dart`, pure Dart). `PatternTranscript`
  is immutable: `lengths` (each 1-4, `ArgumentError` otherwise), entry i is a buzz
  when i is even and a gap when odd, `maxEntries` 24, `append` / `replaceAt` /
  `removeAt`, `isBuzz`, `code` ("B2 G1 B4"), `prose` ("buzz 2, gap 1, buzz 4").
  `PatternEntrySession(tests)`: `testIndex`, two renditions per test, `activeRendition`
  (reset to A on a test change), `cursor` (0 to length; the length is the empty next
  slot), `plays(test)`; `nextTest` / `previousTest` / `goToTest` (clamped; cursor to
  the end), `selectRendition`, `moveCursor`, `tap` (append at the end slot, else
  replace; cursor + 1), `delete` (the entry at the cursor, or the last entry at the
  end slot), `notePlayed([test])`, `logLines()` (one line per test with a transcript
  or a play: `Pattern probe heard 5/40, <description>: A = …; B = —; played 3×.`).
- **`PatternProbe`** plays on demand: `play(PatternTest)` returns the result or null
  (logged: already playing, not connected, over the budget of `maxCommands` 160 per
  session counted over all plays, stopped, nothing written). A cool-down before every
  play waits for a live event 100 after the previous play's last write, or `settle`
  (4 s) since it. Only live events count: happened no earlier than 500 ms before the
  play started and received within 2 s. The per-play line is `Pattern probe play: n/40,
  …` and ends with `silences: <ms>, …` (live 60 minus the live 100 before it) and
  `buzzes: <ms>, …` (100 minus its 60).
- **Tests.** `defaultTests` is 40: the 32 of 8W, then 8 gap tests, `BuzzStyle.delayed`
  (`count` 2, `PatternTest.delayMs`; the next command goes `delayMs` after the live
  100 of the previous one, 2.5 s if none), effect 14 then 47 alternating with delays
  0, 300, 700, 1200: tests 33-40 are (14,0) (47,0) (14,300) (47,300) (14,700)
  (47,700) (14,1200) (47,1200). Description of a gap test: `<name>, 2 commands, the
  second <d> ms after the first ends`.
- **Runner.** `HardwareProbeRunner.openPattern()` (refusals as before; opens the
  session and a lab session `Pattern probe`, settings `40 tests, transcribed: 4
  waveforms × 4 ways of sending × 2 counts, plus 8 gap tests`; sends nothing),
  `pattern`, `patternPlaying`, `patternTestCount`, `playPattern()` (counts a play only
  when the probe returned a result, against the test that was played), `patternTap`,
  `patternDelete`, `patternMove`, `patternRendition`, `patternTest(delta)` (all
  notify), `closePattern()` (stops the probe, logs `logLines()`, ends the lab session
  with `<k> of 40 tests transcribed, <p> plays`; idempotent). `stop()` closes an open
  pattern probe. The old `runPattern`, `patternQuestion`, `answerPattern` are gone.
- **Page** (`lib/ui2/profile/pattern_probe_page.dart`, `PatternProbePage(runner:)`),
  pushed by the panel's `probe-pattern` button after `openPattern()`. Keys:
  `pattern-prev`, `pattern-next`, `pattern-play` ("Playing…" and disabled while a
  play runs), `pattern-rendition-a` / `-b`, `pattern-wheel` (a `ListWheelScrollView`;
  the centred row is the cursor; only the wearer's scrolling moves the cursor),
  `pattern-len-1` … `pattern-len-4`, `pattern-delete`. The footer is outside the
  scroll. The length buttons read "Buzz n" with solid bars when the cursor entry (or
  the next slot) is a buzz, "Gap n" with hollow bars when it is a gap; the wheel rows
  use the same two looks. Going back closes the probe (`PopScope`; a microtask in
  `dispose` for any other removal, because closing notifies the lab log).
- **Panel.** `probe-pattern` is enabled when `canRunPattern`; its caption says it opens
  a screen and that leaving it ends the probe. No golden covers the panel or page.

## 8Z: notes and rests, tempo, a metronome and a replay march

Builds on 8Y. Tests: `test/gestures/pattern_transcript_test.dart`,
`test/hardware/pattern_probe_test.dart`, `pattern_probe_panel_test.dart`,
`pattern_probe_page_test.dart`; `test/ui2_tokens_test.dart`.

- **Entries are typed.** `PatternEntry({note, length})` (length 1-4, `ArgumentError`
  otherwise): a note (the band buzzed) or a rest. `PatternTranscript.entries` is
  `List<PatternEntry>`; `maxEntries` 32; two notes or two rests may sit together.
  `code` is "N2 R1 N4 R4 R4", `prose` "note 2, rest 1, note 4, rest 4, rest 4".
  The 8Y alternation (even entry buzz, odd gap) is gone.
- **The toggle.** `PatternEntrySession.nextIsNote` starts true. `tap(len)` writes an
  entry of that kind (append at the end slot, else replace; cursor + 1) and then
  flips the toggle. `toggleKind()` flips it by hand for the next entry. Moving the
  cursor, switching rendition or test sets it to the opposite of the entry before
  the cursor (note when there is none). There is no pattern prediction and no
  suggested length.
- **Units and tempo.** One unit is an eighth: length 1 eighth, 2 quarter, 3 dotted
  quarter, 4 half; a 4/4 bar is 8 units. `defaultUnitMs` 250. `noteMeasured(test, ms)`
  stores a test's latest span (first live event 60 to last live event 100, received
  times; `PatternTestResult.spanMs`). `fittedUnitMs()`: per test with a span, span
  over the units of the active-or-A rendition up to and including its last note
  (trailing rests not counted; A and B averaged when both have a note), the median
  over tests, clamped 100-800, null with fewer than 2 tests. `dynamicTempo` defaults
  true; `unitMs` is the fit when dynamic and fitted, else 250. `logLines()` ends
  with `Pattern probe tempo: 1 unit ≈ N ms (fitted from k tests).` or `(fixed).`
- **Lead and march.** `defaultLeadMs` 300; `noteLead(ms)` records the measured lead
  (first live 60 received minus the first command written,
  `PatternTestResult.leadMs`); `leadMs` is the median of all, clamped 0-1500.
  `PatternEntrySession.march(transcript, unitMs, leadMs)` returns, per entry,
  `(index, startMs, endMs)`: entry i starts at leadMs + unitMs × the units before it
  and lasts length × unitMs; empty gives `[]`.
- **Runner.** `patternToggleKind()`, `patternDynamicTempo(bool)` (notify);
  `patternPlays` (bumped when a play starts); `patternPlayWrittenAt` (phone clock,
  when the play's first write landed; null until then, cleared at the next play and on
  close). `playPattern` calls `noteMeasured` and `noteLead` when the play produced
  them.
- **Page.** The footer has the four length buttons (`pattern-len-1` … `4`, "Note n"
  or "Rest n"), then `pattern-kind` (reads "Note" or "Rest") left of `pattern-delete`.
  Each button and wheel row has the music symbol (one widget keyed `pattern-symbol`,
  drawn with a `CustomPaint`, label "eighth|quarter|dotted quarter|half note|rest")
  above one dash per unit (`dash-1` … `dash-n`). The dash colours are the first n of
  `kPatternUnitColours` (blue, green, orange, purple); rests use the same colours at
  a third of the saturation. The metronome dot (`pattern-metronome`, 14 px, label
  "metronome step N of 8") sits left of Play, steps every `unitMs`, shows the four
  colours on steps 1, 3, 5, 7 and an outline between, and restarts at step 1 when a
  play starts. Below the Play row: "1 = N ms" (+ " · fitted") and the Dynamic tempo
  switch (`pattern-dynamic-tempo`).
- **March.** Play on a test whose active rendition has entries starts a playhead
  (`pattern-playhead` on the row; row label "playing entry N, …") from
  `patternPlayWrittenAt` plus the lead, on the `march` plan with the session's
  `unitMs` and `leadMs` at that moment; the wheel follows, the metronome restarts at
  the same instant, and at the end the wheel returns to the cursor. The march never
  changes the cursor or the entries. A tap, toggle, delete, rendition or test switch,
  or a scroll cancels it. An empty active rendition does not march. All timers are
  cancelled on dispose and when the session closes.

## 8AA: 16th notes and dynamics

Builds on 8Z. Tests: `test/gestures/pattern_transcript_test.dart`,
`test/hardware/pattern_probe_page_test.dart`, `pattern_probe_panel_test.dart`;
`test/ui2_tokens_test.dart`.

- **Lengths.** The unit is now a sixteenth. `kPatternLengths = [1, 2, 4, 6, 8]`: 16th,
  eighth, quarter, dotted quarter, half (a 4/4 bar is 16 units). Any other length is an
  `ArgumentError` from `append`, `replaceAt` and `tap`. `defaultUnitMs` 125 (the old
  250 ms eighth); the fit clamp is 50-400; the log line is
  `Pattern probe tempo: 1 sixteenth ≈ N ms (...)`. `march` is unchanged and unit-based.
- **Dynamics.** `enum PatternDynamic { ff, mf, mp, pp }`, loudest to softest.
  `PatternEntry.dynamic` is required for a note and null for a rest (`ArgumentError`
  otherwise) and is part of `==`/`hashCode`. `code` is "N4mf R2 N1ff"; `prose` is
  "quarter note mf, eighth rest, 16th note ff".
- **Sticky selector.** `PatternEntrySession.nextDynamic` starts `mf`; test, rendition
  and cursor changes leave it alone. `tap(len)` writes notes with it (rests none).
  `setDynamic(d)` sets it and, when the cursor is on a note, changes that note too
  (cursor unchanged); on a rest or the empty next slot it only sets the selector.
  Runner: `patternDynamic(d)` (notifies).
- **Page.** Footer, top to bottom: the dynamics row (`pattern-dyn-ff|mf|mp|pp`, bold
  italic names, the chosen one outlined and `selected` in semantics, faded but still
  active while the toggle is on Rest), five equal length buttons (`pattern-len-1|2|4|6|8`,
  keyed by the 16th count, short labels 16th, 8th, 4th, 4th., Half; the symbol's
  semantics say "16th note", "dotted quarter rest" and so on), then Note/Rest and
  Delete. The 16th note has two flags and the 16th rest two hooks. Note rows show their
  dynamic in bold italic. Dash k of a length (one per sixteenth) takes the colour of
  the beat it falls in, `kPatternUnitColours[((k - 1) ~/ 4) % 4]`; rests at a third of
  the saturation. The metronome dot has 16 steps: steps 1, 5, 9, 13 the beat colours
  (A, C, D, E) at full strength, 3, 7, 11, 15 the same colour at a third of the
  saturation, the even steps an outline; label "metronome step N of 16". The tempo
  label reads "1 sixteenth = N ms" (+ " · fitted"). At 360 x 640 the footer is still
  fully visible with 32 entries (header and footer gaps were tightened to fit).

## 8AB: dotted notes, count-in, end screen, rolling limit

Builds on 8AA. Tests: `test/gestures/pattern_transcript_test.dart`,
`test/hardware/pattern_probe_test.dart`, `pattern_probe_page_test.dart`,
`pattern_probe_panel_test.dart`; `test/ui2_tokens_test.dart`.

- **Dotted lengths.** `kPatternLengths = [1, 2, 3, 4, 6, 8, 12]` (16th, eighth, dotted
  eighth, quarter, dotted quarter, half, dotted half). `PatternEntrySession.dotNext` is a
  one-shot: `toggleDot()` flips it; `tap(len)` with it on writes `len * 3 / 2` and
  clears it; only 2, 4 and 8 can be dotted (`tap(1)` or any other with the dot on is an
  `ArgumentError` and changes nothing). Runner: `patternToggleDot()` (notifies). Page:
  four length buttons `pattern-len-1|2|4|8` (16th, eighth, quarter, half) and the Dot
  toggle `pattern-dot` (semantics `selected` while on) in one row of equal width; with
  the dot on the buttons draw and say 3, 6, 12 ("dotted eighth note", 3 dashes and so
  on) and the 16th is disabled. The symbol painter draws the dot after notes and rests
  of length 3, 6 and 12; dashes are thinner for 12.
- **Metronome.** Off until Play: label "metronome idle", an outline. Play starts a
  one-measure count-in (16 steps of `unitMs` fixed at the press, step 1 at once) and
  calls `runner.playPattern()` at the count-in's end minus `leadMs` (at once if past).
  The march starts at the downbeat (count-in end), not at the first write plus the
  lead. The metronome runs until the play has finished and the march has ended (or was
  cancelled), then stops at the first bar line a full measure on (so `now + 1 bar` to
  `now + 2 bars`, on the bar grid from the press). The Play button is disabled while
  counting in and playing ("Count-in…", "Playing…"). A refused play stops everything
  at once. Leaving cancels every timer; the band is not asked after leaving.
- **Refusals (D).** `PatternRefusal { busy, notConnected, resting }`;
  `runner.patternRefusal`, `patternRestRemaining`. `PatternProbe` limits writes to
  `maxCommandsPerWindow = 30` in any `commandWindow = 2 min` and refuses with
  `restUntil`; log line `Pattern probe: resting the band; ready in N s (30 commands per
  2 minutes).` The window lives in the runner (`writeLog`) so it survives closing and
  reopening the screen. `patternPlays` and the play count move only on an accepted
  play. Page: `pattern-refused` under Play ("Band resting, ready in N s" counting down,
  "Band rested, ready to play", "Not connected", "Still playing"), hidden while a new
  count-in runs and gone after the next accepted play. Caption: "Each play waits for
  the band to finish the last one; at most 30 commands in any 2 minutes; leaving this
  screen stops it."
- **End screen (C, C2).** `pattern-finish` (header) and back from the transcriber
  close the session (`closePattern` writes the heard lines and tempo line) and show
  `pattern-end`: "k of 40" tests transcribed, plays, "1 sixteenth ≈ N ms (fitted|fixed)",
  "N ms" Bluetooth lead ("(default)" when unmeasured). `pattern-copy` ("Copy all
  logs") puts `logText()` on the clipboard (called after the close; the page takes
  `logText:`, which `DeviceLab` builds with `labLogText` and also uses for its own
  button) and shows "Copied". `pattern-done` or back from the end screen leaves.
- **Limit display (E).** `runner.patternCommandsLeft` (30 minus the commands in the
  window, never below 0) and `patternNextFreeIn` (null when the window is empty).
  `pattern-limit`, a small pill floating over the wheel's bottom-right corner (it costs no height; 360 x 640 has none to spare), shows "N of 30 left" and "next in m:ss", counting
  down each second; the count is `C.red` under 5. Blurred by default
  (`ImageFiltered`, sigma 5; semantics "limit display, blurred"); a tap toggles
  ("limit display"). The refusal line is never blurred.

## 8AC: dynamics f and p, unstable rounds, device vocabulary, notes to commands, global band queue

Builds on 8AB. Tests: `test/haptics/*` (profile, heard log, compiler, tap notes, player,
`mg_delivery_test.dart`, `band_queue_test.dart`, `buzz_pattern_notes_ui_test.dart`,
`docs_8ac_test.dart`), `test/gestures/pattern_transcript_test.dart`,
`test/hardware/pattern_probe_*`, `test/phase8/buzz_*`.

- **Dynamics.** `PatternDynamic { ff, f, mf, mp, p, pp }` (order is loudness distance);
  codes `N4f`, `N2p`; `PatternEntry.parse` / `PatternTranscript.parseCode` read a code
  back. Unstable probe rounds: `toggleUnstable()` / `patternToggleUnstable()`, page key
  `pattern-unstable`, log line "unstable (A and B are the shortest and longest)".
- **Vocabulary.** `lib/haptics/haptic_profile.dart`: `HapticPhrase`, `HapticGap`,
  `HapticDeviceProfile.whoopMg` (id `whoop-5.0-mg`, version 1, `unitMs` 125),
  `forGeneration('gen5')`, the `phrases` and `gaps` tables (8AF.6 removed `phrasesFor` / `gapsFor(extended:)`; every phrase and gap is considered). The stable input set is
  `kWhoopMgPatternProbeSet` (`whoop-mg-pattern-v1`, 40 tests, never reordered).
  `lib/haptics/heard_log.dart` (`parseHeardLines`) reads the output set; a test checks
  the table against the L6 log.
- **Compiler.** `compile(target, profile, dynamicWeight:, maxCommands:,
  maxRuntimeMs:)` returns a `HapticPlan` (steps with write delays, felt shortest and
  longest, cost, `exact`, `usesUnstable`, `runtimeMs`, summary). Cost: 4 per note/rest
  mismatch, dynamic weight times index distance, `commandPenalty` 2 per command beyond
  the first. Plans over `kMaxHapticRuntime` (10 s) are not produced.
- **Rules.** `BuzzSequence` gains `notes`, `profileId`, `profileVersion` and
  `bakedSteps` (`BakedStep`, JSON key `plan`); each is written only when set, so old JSON
  round-trips unchanged. The editor takes an optional `profile:`, shows the notes and what
  the band will play, and on Save stores notes, profile and the baked plan.
  `settings.dart` (`_pickPattern`) and `band_notifications.dart` (`_pick`) pass
  `HapticDeviceProfile.forGeneration(app.device.generation)`; null on a 4.0.
- **Delivery.** `deliverBandSequence` plays baked steps (profile id matches), else the
  notes compiled, else the taps compiled, else today's per-tap buzz; `bandSequenceTimeout`,
  `bandSequenceCommands`, `bandSequenceSettle` size it. AppState has ONE helper,
  `_deliverBandSequence`, for `alertDispatcher.bandSequence`, `.bandSequenceDelivery`,
  `previewBuzzSequence`, `_dispatchBandAlert` and the notification relay. The pattern
  write is `_bandBuzzPattern` (a `Future<bool> _bandBuzz...` line, so the phase 7 audit
  guard is unchanged). The band's live event 100 (`isLive` only) feeds the wait through
  `BandEndedSignal`.
- **Global band queue.** `lib/haptics/band_queue.dart`: `BandCommandLedger` (30 commands
  per 2 minutes: `record`, `commandsLeft`, `nextFreeIn`, `waitFor`, `writeLog`),
  `BandEndedSignal`, `BandHapticQueue.run(job, commands:, timeout:, startBy:, settle:)`
  (FIFO, one at a time; starts when the previous finished and the ledger allows;
  cannot start by the deadline, 15 s (`kBandQueueWait`) from queueing, gives `rejected`
  with nothing written; the timeout counts from the start; `pending`, `nextFreeIn`; log
  lines "Band queue: waiting for the band (N ahead)", "Band queue: resting, ready in N s").
  AppState owns one queue and one ledger (`bandQueue`, `bandLedger`); every band path
  runs through `_runBandJob`: the dispatcher's default band transport (tap ack, water and
  medication buzzes), the two sequence transports, preview, `_dispatchBandAlert` (rhythm,
  alarm, fixed pattern), `_ecgTapBuzz`, `_ecgTapFailBuzz`, `_userBuzz` (test buzz, pattern
  test, find my strap) and the relay (`deliverSequence`, `runBand`, `sequenceTimeout`).
  `AlertDispatcher.bandQueueWait` adds the wait to a band deadline and `sequenceTimeout`
  sizes a saved rhythm's. The pattern probe runner takes the same ledger (`ledger:`) and
  keeps its own pacing; the buzz probe records one command per buzz. A source test lists
  every `engine.buzz*` site and requires it inside a queue job.
- **Docs.** `docs/hardware/whoop-mg-haptics-and-ecg.md` ("Vocabulary (L6)", "From taps to
  band commands"); the roadmap entry 8AC.

## 8AD: Haptics hub, named pattern store, notes editor, allow long sequences, tap-a-baseline, multi-log vocabulary

Builds on 8AC. Tests: `test/haptics/pattern_store_test.dart`, `allow_long_test.dart`,
`haptic_pattern_editor_test.dart`, `haptics_settings_test.dart`, `vocab_builder_test.dart`,
`test/hardware/pattern_probe_*`.

- **Pattern store.** `lib/haptics/pattern_store.dart`: `SavedHapticPattern {id, name,
  sequence}` (name 1 to 40 characters trimmed, unique without regard to case; ArgumentError
  otherwise) and `HapticPatternStore` (SharedPreferences key `haptic_patterns_v1`, a JSON
  list; `load`, `save` serialized like `NotificationPrefs`; `add`, `rename`,
  `replace(id, sequence)`, `delete`, `list` ordered by name). `BuzzSequence.patternId`
  (JSON only when set; `copyWith(clearPatternId:)`). A rule that picked a stored pattern
  holds a SNAPSHOT of it with `patternId` set; delivery never reads the store.
- **Propagation (one function).** `propagatePattern(id, prefs:, channels:, replacement:)`
  rewrites every snapshot in the three places a sequence is stored: the alert rules
  (`AlertRule.buzzSequence`), `ChannelConfig.buzzSequence` and `ChannelConfig.appSequences`.
  With a replacement they follow it; without one (deleted) they keep their rhythm and lose
  the id. `patternUsageCount` counts the same three places. A new field that holds a
  `BuzzSequence` must be added to both.
- **Allow long sequences.** Pref `haptics_allow_long_sequences` (`Prefs.hapticsAllowLong`,
  `Prefs.allowLongHaptics`, default false). `maxRuntimeFor(allowLong:)` is the 10 s cap, or
  null when allowed; the tap sheet, the notes editor, `planForTaps`/`compile` and
  `_deliverBandSequence` (with `bandSequenceTimeout`, `bandSequenceCommands`,
  `bandSequenceSettle`) all read it. The 8-command plan cap, the band queue and the 30 per 2
  minutes ledger still apply.
- **Notes editor.** `lib/ui2/profile/haptic_pattern_editor.dart`:
  `HapticPatternEditorPage(initial, name, profile, onPlay, onSave, allowLong,
  existingNames)`, with the probe's entry model (the shared widgets now live in
  `pattern_notation.dart`), the 8AC "what the band plays" lines (`haptic_plan_text.dart`),
  `pattern-editor-play`, `pattern-editor-save` (asks a name when `name` is null) and
  `pattern-editor-from-taps` (`tap_take_pad.dart`). `PatternNameDialog` is the one name
  dialog (also the hub's Rename).
- **Haptics hub.** Settings > The band > Haptics (`settings-haptics`, after Gestures) opens
  `HapticsSettings` (loads the store, the alert rules and the relay channels; replace and
  rename call `propagatePattern`, delete calls it without a replacement; the store, the
  rules and `NotificationRelay.setChannel` all persist). `HapticsSettingsView` is the pure
  screen: groups Patterns, Safety, Test and (developer mode only) Calibration. Pattern row
  `haptic-pattern:<id>` shows the name, the notes and "N commands · ~X s", or "Taps"; its
  sheet has Preview, Edit notes (MG only), Re-record, Rename, Delete (names "Used by N
  alerts"). Rows `haptics-new-taps`, `haptics-new-notes` (MG only). Safety: checkbox
  `haptics-allow-long` (confirms only when turned on) and the read-out "N of 30 band
  commands left in the last 2 minutes" and "Queue: N waiting" / "Queue: empty" from
  `bandLedger` / `bandQueue.pending`. Test: `haptics-buzz` is `AppState.buzzBand`, the
  device page's Tools row (a dispatcher delivery in the band queue). Calibration:
  `haptics-device-lab` opens the Device lab.
- **Pickers.** `showPatternPicker` (`pattern_picker.dart`, sheet key `pattern-picker`): Default
  (clears to the registry default), the stored patterns (selected = current `patternId`),
  Record new... (the tap sheet; only there it offers `buzz-save-to-patterns` with a name
  field, off by default) and Write notes... (the editor; MG only; stores and selects).
  Choosing a stored pattern saves its snapshot with `patternId`. Both Notifications
  (`_pickPattern`) and Band notifications (`_pick`, channel and per app) use it, never the
  bare tap sheet. `showBuzzPatternSheet` closes the sheet before it calls `onSave`.
  `ChannelConfig.copyWith(clearBuzzSequence:)` is how Default clears a channel.
- **Probe.** `pattern-tap-baseline` ("Tap what you felt") fills the active rendition from
  a tapped take (`notesFromTaps`, mf); runner `patternSetRendition`; log line "Pattern probe:
  test N rendition A from taps: <code>".
- **Vocabulary from many logs.** `buildProfileFromLogs`, `describeProfileDiff`
  (`lib/haptics/vocab_builder.dart`) and `tool/build_haptic_vocab.dart`; the L6 log alone
  rebuilds `whoopMg`.
- **Docs.** `docs/hardware/whoop-mg-haptics-and-ecg.md` ("Patterns and safety");
  `docs/navigation-depth.md` (Haptics row); the roadmap entry 8AD.

## 8AE: Settings by task, Developer area, Device lab behind dev mode, quiet-hours override

Builds on 8AD. Tests: `test/phase8/settings_regroup_test.dart`,
`settings_device_lab_entry_test.dart`, `settings_naming_test.dart`, `quiet_override_test.dart`,
`nav_depth_test.dart`, `nav_depth_guard_test.dart`.

- **Settings groups** (`MoreSettingsView`), in order: Band (My devices, Alarm, Gestures,
  Haptics, HR zone alert, Target zone), Alerts (Alerts and notifications, App notifications on
  the band on Android), You & preferences (Edit profile, Language, Units, Appearance,
  Expected sleep schedule, Icon, Cycle tracking, Steps), Data & privacy (Storage, Export,
  backup, import, Write to the health store, Contribute my health data, Crash reports,
  Look barcodes up online), Connections (AI coach, Tasker and Shortcuts, Check for
  updates), About, and Developer (dev mode only: Component gallery, Live devices, Device
  lab, Developer mode). Reset all data stays last. Profile Quick access keeps My devices
  and Settings; every other moved row has one door. My devices (Profile and Settings >
  Band) and Expected sleep schedule (Settings and Alarm > Wake, the alarm's input in
  context) are the two deliberate pairs.
- **Device lab** leaves the band's Tools. Its doors are Settings > Developer
  (`MoreSettingsView.onDeviceLab`, dev mode) and Haptics > Calibration (dev mode). The
  `tapClassifiers` flag still gates the tap tools inside. Gestures drops "Pause between double
  taps" and "Touch windows"; the Device lab keeps them.
- **Rename.** The relay's screen title, group header and Settings row are "App notifications
  on the band" (ARB `bandNotifNavTitle`, `bandNotifRelayGroup`); Alerts no longer has an
  Android Relay group, so Settings is the one door. "Band alerts" is "Band battery"
  (`settingsBandAlertsRowTitle`; the sub reads "Turn on Band battery first"). The Alarm
  screen's Haptics group is removed; Wake carries `The alarm uses the band's own buzz.`
- **Quiet-hours override.** `ChannelConfig.overrideQuietHours` (JSON `overrideQuietHours`;
  absent means true when the stored config has both quiet times, so existing windows keep
  working). Off: the channel follows the global quiet hours; its stored times are kept but
  not used. On: its own Starts and Ends decide, and none or only one time means never quiet.
  The relay decision reads the global window from the policy map keys `quietEnabled`,
  `quietStartMin`, `quietEndMin`; a policy without them means no global quiet hours.
  `NotificationRelay._policy` supplies them from a cache of `NotificationPrefs`, loaded in
  `bootstrap` and refreshed from `SettingsRepository.changes` (8AE.5; it replaced
  `NotificationPrefs.onSaved`), which fires after every successful settings update, so no
  screen that saves can leave it stale.
- **UI.** `channel-quiet-override-<channel>` ("Override quiet hours", sub "Follows your quiet
  hours in Alerts" while off). Turning it on seeds 22:00 to 07:00 when the channel has no
  times. Starts and Ends are not drawn while it is off: the one deliberate exception to
  disable-not-hide, because a time with no setting behind it would mislead.
- **Docs.** `docs/navigation-depth.md` (8AD to 8AE table); the roadmap entry 8AE.

## 8AF.5: any-loudness notes, rhythm / dynamics priority, editor follows playback

Tests: `test/haptics/any_dynamic_priority_test.dart` (model, heard log, stored JSON),
`haptic_priority_compile_test.dart` (compiler, `startUnit`, delivery fallback),
`haptic_play_start_test.dart` (start signals), `haptic_pattern_editor_test.dart` (the
8AF.5 groups), plus one guard in `test/hardware/pattern_probe_page_test.dart`.

- **`*`.** `PatternDynamic.any`, code `*`, prose ", any loudness". `PatternDynamic.scale`
  is the six that run ff to pp; use it where the six are meant (the probe's row). `any` has
  no index distance (`distanceTo` is 0), compiles at no loudness cost and counts as written
  for any loudness. `PatternEntry.parse` accepts `N2*`; a rest never takes it. The probe
  page and `HardwareProbeRunner.patternDynamic` do not offer or accept it. 8AF.6: the probe's
  tap baseline writes `*` notes; the page shows `pattern-unrated-hint` and disables
  `pattern-prev` / `pattern-next` while `PatternEntrySession.unratedNotes(test)` is above 0
  (rate a note by moving the cursor onto it and tapping a dynamic); a `*` left in a probe
  line parses (`HeardTest.unrated`) and `buildProfileFromLogs` skips that test. The editor shows `pattern-dyn-any` ("*", semantics
  "Dynamic any loudness") beside the six.
- **Priority.** `HapticPriority { rhythm, dynamics }` (`haptic_priority.dart`, re-exported by
  `haptic_compiler.dart`), `compile(priority:)` default rhythm: cells 4 / loudness 1 against
  cells 1 / loudness 4. `BuzzSequence.priority` is written (`'priority': 'dynamics'`) only
  when not rhythm; old JSON is byte-identical; an unknown value is a `FormatException`. The
  player's notes fallback compiles with it (and weighs loudness for mf-only notes when it is
  dynamics, as the editor did). The editor's toggle is `pattern-editor-priority` with
  `-rhythm` and `-dynamics` options; Play and Save carry it. `hapticChangesLine` names at
  most two changed notes, key `pattern-editor-changes`.
- **Following.** `HapticsService.deliver(s, onStart:)` reports a `HapticPlayStart` per
  compiled command (not per-tap buzzes); `AppState.previewBuzzSequence(s, onStart:)` passes
  it on, still inside one dispatcher delivery. The editor's `onPlay` may be a
  `FollowingPreview` (checked at run time, so plain callbacks still work). A start signal
  anchors the march at that step's `startUnit`; entries up to the next command's start run,
  then the playhead holds (given up after 2 s). `BakedStep` does not carry `startUnit`: the
  editor reads it from the plan it baked.
- **Docs.** `docs/hardware/whoop-mg-haptics-and-ecg.md` (Patterns and safety); the roadmap
  entry 8AF.5.

## 8AF.6: built-in patterns, gesture cues, wake on the vocabulary, the HR zone alert as an alert

Tests: `test/haptics/fastest_selection_test.dart`, `builtin_patterns_test.dart`,
`gesture_cues_test.dart`, `gesture_cues_wiring_test.dart`, `default_preview_test.dart`,
`no_extended_compile_test.dart`, `no_extended_mode_test.dart`, `tap_sheet_notes_test.dart`,
`wake_vocabulary_test.dart`, `wake_vocabulary_wiring_test.dart`, `pattern_store_test.dart`,
`haptics_settings_test.dart`; `test/phase8/zone_alert_test.dart`,
`settings_regroup_test.dart`, `disable_not_hide_test.dart`;
`test/gestures/ecg_tap_session_one_command_test.dart`.

- **Fastest selection.** `HapticDeviceProfile.fastestSingle()` (stable phrase whose shortest
  and longest renditions are one note each; smallest `unitsMax`, then `unitsMin`, then id; MG:
  `buzz14`) and `fastestGap()` (stable gap, smallest `maxUnits`, then lowest delay; MG: 0 ms).
  Both are stable-only and pinned against the table.
- **System patterns.** `SavedHapticPattern.systemKey` / `system` (JSON additive). Keys
  `gesture.start`, `gesture.followUp`, `gesture.confirm`, `alert.<ruleId>` for every
  non-alarm rule in `NotificationPrefs.alertRuleOrder` (no `alarm`, `nativeAlarm`, `wake`,
  `alarmLatchFailed`, `alarmNightCheck`) and `alert.relay` (the relay's default). Ids are
  `sys.<systemKey>`. `lib/haptics/builtin_patterns.dart` builds the defaults; the store seeds
  what is missing on load (idempotent, survives reorder). The store refuses to rename or
  delete one; `resetToDefault(id)` puts the seeded default back. Only the three gesture
  cues use the fastest phrase and gap; each `alert.*` default is today's
  `BuzzSequence.defaultFor(index)` rhythm as `*` notes with rhythm priority. A rule with no
  rhythm of its own resolves to its built-in; a 4.0 keeps the taps.
- **Hub and picker.** "Your patterns" first, then a divider, then "Built in" (rows with a
  lock and a "Built in" tag; sheet: Preview, Edit notes (MG), Re-record, Reset to default; no
  Rename, no Delete). The picker's Default row stays on top, shows the rule's built-in notes
  and plan and has `pattern-picker-default-play` (the normal preview path).
- **Gesture cues.** `GestureCues` (`lib/haptics/gesture_cues.dart`): `response(N)` is the
  start cue and N - 1 follow-ups at the fastest gap as ONE queue job; `confirm()` is
  `gesture.confirm` (`ackTap(..., bandDelivery:)`). A customised built-in is what plays. A
  band with no haptic profile keeps its old pacing: `EcgTapSession.pulsesPerBurst` (read at
  every count buzz) answers 1 while `AppState.haptics.profile` is null, so a count is one
  pulse per call, each at least `buzzQuietGap` after the previous write. The fail buzz stays
  the long buzz.
- **No extended mode.** The `buzz-extended` switch is gone (tap sheet and editor);
  `compile` / `planForTaps` / delivery consider every phrase and gap, each unstable one
  adding 1 to the cost; `usesUnstable` and "timings may vary" stay. `BuzzSequence.extended`
  is not written; old JSON with it parses (ignored); JSON without it is unchanged.
- **Taps in the tap sheet.** Tap-derived notes are `*`, rhythm priority, no loudness weight;
  no priority toggle. After a take on an MG the sheet offers `buzz-edit-notes` ("Edit as
  notes"): the advanced editor on the take's `*` notes with Prioritize rhythm; saving returns
  to the same picker or hub flow as a notes pattern.
- **Wake.** `lib/haptics/wake_haptics.dart`: `gradualPhraseId(pattern, step)` (steady
  `buzz14`; ramp `click1`, `buzz14`, `buzz47`, `buzz47x2`, `buzz47x3`, then the last),
  `kNaturalWakePhraseIds` (3 x `buzz47x3`), `WakeHaptics(haptics)` with
  `gradualStep(pattern, index, perTap:)` and `natural(runAlarm:)`. The plans are code, not
  in the store, and not editable. `AppState._sendWakeHaptic` and `_checkLegacySmartWake`
  go through `_dispatchBandAlert(deliver:)`, which hands the delivery the rule's rhythm and a
  `runAlarm` queue job; RUN_ALARM runs on a band with no profile and when the plan was
  rejected with nothing written (every `engine.runAlarm(` call is still inside a dispatcher
  delivery). A partial or unconfirmed plan is not followed by RUN_ALARM.
  `WakeHapticRequest.gradualPattern` carries the step's pattern. Alarm > Wake adds "Wake
  buzzes use the band's measured vocabulary."
- **HR zone alert.** It is the `zone` alert rule, in Alerts (`NotificationSettingsView`, the
  Activity group): the standard destination picker, the Buzz pattern row
  (`buzz-pattern:zone`, built-in `alert.zone`), a "Target zone" row (`zoneAlertZone`,
  `onCycleZoneAlertZone`, always drawn, dimmed while the alert is off) and `zone-alert-open-zones`
  ("Zone view", `onOpenZones`, else pushes `ZonesDetail`). Settings > Band lost "HR zone
  alert" and "Target zone" (`MoreSettingsView` no longer takes `zoneAlertEnabled`,
  `zoneAlertZone`, `onToggleZoneAlert`, `onCycleZoneAlertZone`; `AppState.zoneAlertEnabled` and
  `setZoneAlertEnabled` are gone). `NotificationPrefs.readFrom` migrates the old
  `workout.zone_alert_enabled` pref once (marker `alerts.zone_pref_migrated`): when it
  disagrees with the rule, on becomes Band and off becomes off; afterwards it never changes
  the rule again. A live session always arms the crossing watch; `_dispatchBandAlert('zone')`
  resolves the rule, so its destinations and pattern decide what happens.
- **Docs.** `docs/hardware/whoop-mg-haptics-and-ecg.md` (Patterns and safety); the roadmap
  entry 8AF.6.

## 8AF.7: Settings is the landing screen, remembered accordions, the phone in Devices, one status line for sync

Tests: `test/phase8/settings_landing_test.dart`, `alarm_in_alerts_test.dart`,
`phone_device_test.dart`, `sync_status_line_test.dart`, `pull_to_sync_test.dart`,
`nav_depth_test.dart`, `nav_depth_guard_test.dart`; `test/settings/accordion_state_test.dart`;
`test/ui2/sync_control_panel_test.dart`, `test/proof/affected_views_test.dart` (sync_*,
`primary_band_sync`), `test/state/capabilities_test.dart` (`phoneSteps`).

- **Landing.** Home's Profile button opens Settings (`openProfile`); there is no Profile
  screen and no Quick access group. Community is Settings' first accordion; Alarm is the first
  row of the Alerts accordion. Every `SettingsAccordion` with an `id` remembers open/closed
  under `accordion_<screen>_<section>` (`accordionPrefKey`) through `SettingsRepository`
  (`appBool` to read, `update` to write); first visit is expanded.
- **The phone is always a device.** `liveSources(app, alwaysListPhone: true)` (My devices
  only; every other caller still lists the phone only while it counts) adds `phoneSource(app)`.
  Off, or on a platform with no step sensor, it carries `HealthSource.disabledReason`
  ("Step counting from this phone is off", or the Capabilities reason) which replaces the state
  line, dims the row (`Opacity`) and keeps it tappable; its tier rung is not filled. Under the
  row, `MyDevicesView` draws a `SwitchRow` "Count steps from this phone" (`switchFirst`, so the
  switch leads), bound to `AppState.togglePhoneSteps`, the same call Settings > You &
  preferences > Steps makes. Both doors read `AppState.phoneStepsEnabled` and rebuild live. The
  platform gate is `Feature.phoneSteps` (available on Android and iOS, disabled with "This
  device cannot count steps" elsewhere); a disabled gate makes the switch inert.
- **One status line for sync.** `SyncControl` is one row: a mark (a spinner while busy), the
  running time left of the sentence while busy, one sentence (`syncStatusLine`, pure), at most
  one action ("Sync now", or "Retry" after a failure; none while a sync runs). Tapping the
  sentence opens the four steps inline when there are any; open/closed is remembered under
  `accordionPrefKey('sync-details')`, collapsed by default. Phases: `idle` ("Synced 12 min ago"
  / "Not synced yet"), `offline` ("Band not connected · synced 3 h ago"), `connecting`,
  `downloading` (band time to go only when the band reported its newest record, else
  "Downloading…" or "Nothing new on the band"), `deriving` ("Calculating · day i of n" only
  when known; while waiting on another calculation the download line, else "Waiting for
  another calculation…"), `completed` ("Synced just now" for a minute, then the idle line;
  partial: "Synced, but some days need another pass"), `failed` ("Sync failed: <reason>", red,
  reason falls back to "Please retry"). `SyncCoordinator.view` shows a settled `offline` as
  `idle` while the band is connected; `AppState.syncPresentation` returns it. "The band is
  sending data now." and `SyncPresentationState.description` are gone. A count or a span is
  drawn only when reported; no phase draws a percentage or an estimate.
- **Pull down to sync.** `Prefs.pullToSync` (`pull_to_sync`, default on, `Prefs.pullToSyncOn`),
  a row in Settings > You & preferences after Appearance. Off: Home's `_refreshable` returns
  the list without a `RefreshIndicator`; the status line's Sync now is the way to sync.
- **Removed l10n keys.** `profileQuickAccessGroup`, `profileSourcesCount`,
  `profileMoreSettingsSub` (nothing referenced them after the landing screen went).
- **Docs.** `docs/navigation-depth.md`; the roadmap entry 8AF.7.

## 8AF: Health by question (Last night, Today, Trends, Labs)

Tests: `test/health/health_h2_tabs_test.dart`, `health_h2_migration_test.dart` (plus the
phase-two files in the same folder). Health's sub-tabs are, in order, 0 Last night, 1 Today,
2 Trends, 3 Labs; `HealthScreen(tab:)` takes that order.

- **Tabs.** `_tabsOf` has four chips (`healthTabLastNight`, `healthTabToday`,
  `healthTabTrends`, `healthTabLabs`). All four fit at 360 pt and 390 pt with no scrolling.
  Production opens on 0, which is where deep links and the `/recap` notification land.
  `HealthScreen.tabFromLegacy(int)` maps an index from the five-tab order: 0 to 0, 1 to 2,
  2 to 2, 3 to 1, 4 to 3, anything else to 0. Nothing is persisted today, so no caller uses it
  yet.
- **Last night** (`_lastNight`). Rows in order Readiness (ReadinessDetail), Sleep
  (`SleepDetail(day: <the night>)`, no scrubbing), HRV, Resting heart rate, Respiratory rate,
  Overnight stress, Skin temperature (each `MetricDetail`, opened on Today). Skin temperature's
  sub-label is "vs your usual" and a caption under the rows explains that SD is a standard
  deviation. No `MetricRow.series`, no `TrendCard`, no `ChartFrame`. A "Night of <date>" line
  names the night when `getToday` held an earlier one over. An absent row is a `StatusCard`
  carrying the measured wear gap when there is one. Observations (illness card from
  `illness_observation.dart`, or the newest finding) come next, then the Daytime sleep row
  (NapsScreen), then `EcgEntryCard` when `Capabilities` has `Feature.ecgEntry`.
- **Today** (`_today`). Strain (DayStrainDetail), Steps (DayStepsDetail), Active minutes,
  Calories, Heart rate (low to high), Wear time. Strain, steps, active minutes and calories
  come from `today['daily']`; the heart rate range and wear come from `VitalsData`, so they
  are labelled with the day's date when that day is not today. There is no day stepper.
  The heart rate row opens `MetricDetail('resting_hr')`, which has the live reading and
  opens on Today.
- **Trends** (`_trends`). Body clock and Consistency first (the Body clock card has no
  "Explore" action). Then a `TrendCard` for resting heart rate, HRV and sleep when a series is
  stored for it, then the catalogue by family, led by a Recovery family (Readiness, Stress).
  A measure is a card or a row or part of its family's folded card, never two of those. A
  family with no history folds into one `StatusCard`; Breathing carries one line saying why
  there is no SpO2. Every card and row opens `MetricDetail(key, initialRange: 30)`.
- **MetricDetail.** `initialRange` is in days (1, 7, 30, 182, 365); null opens on Today.
  A window the install has too few days for falls back to the widest it has. The suppressed
  skin temperature spec says "No trend yet" and no longer points at Vitals.
- **Illness card.** `illnessObservation()` in `lib/ui2/screens/illness_observation.dart`
  builds it for both Home and Health from the `healthIllness*` strings; Home adds its tap to
  the resting heart rate chart. The `homeIllness*` strings are no longer read.
- **Removed.** The Explore and Vitals tabs, the HRV deep-dive card and its preview chart on
  Vitals, the "N of M measures" card, and the stale comments named in the test.
- **Docs.** `docs/navigation-depth.md` (Health); the roadmap entry 8AF.
