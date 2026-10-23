import '../../l10n/date_text.dart';
// HOME — decision-oriented. "What matters today?"
//
// Three rings that decide the day — what the night gave back, what the day has
// cost, what the night was made of — three signals worth a glance under them,
// and the small set of things the app can honestly say are worth doing. The
// hard part is not the circles: readiness exists on 71 % of days and needs
// four prior nights before it exists at all, so what a ring does with nothing
// in it is the design. See [RingTrio]. No insight feed and no general
// health-observation card: those are OBSERVATION, and observation lives on
// Health. A home screen that also observes is a dashboard, and a dashboard is
// what this rebuild is replacing.
//
// ONE NAMED EXCEPTION, and it is deliberately not a crack in that rule: the
// illness watch ([_bodyWatch]). It is not a feed and it cannot grow into one —
// exactly one detector may render here, it renders only when its own state is
// amber or red, and it is silent on every ordinary day. The reason it earns
// Home is timing rather than importance: the watch is at its most useful when
// it first goes amber, and amber has no notification, so before this the
// earliest signal the app produces could only be found by opening Health and
// scrolling. A signal that arrives too late to act on is not worth computing.
// If a second observation ever wants this slot, the answer is no — build the
// feed on Health where the others already live.
//
// This file also carries the plumbing every screen in this folder shares —
// navigation, the repo handle, and the three ways a value arrives from the
// data layer. They live here rather than in a fourth file because there are
// only three of them and they are read together.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show TextDirection;

import 'package:clock/clock.dart' as pc;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import '../../models/chart_point.dart';
import '../older_version.dart';

export '../../models/chart_point.dart' show ChartPoint;

import '../../ai/briefing.dart'
    show Briefing, BriefingPeriod, BriefingStore, currentBriefingPeriod, resolveBriefingToShow;
import '../../compute/derive_perf.dart' show RenderLatency;
import '../../compute/findings.dart'
    show
        isRecentFindingDate,
        kReadinessEasyBelow,
        kReadinessGoodFrom,
        kReadinessRestBelow;
import '../../data/day_label.dart' show todayLabel, calendarDaysBetween, dayLabelBefore;
import '../../compute/onehz_pipeline.dart'
    show readinessInputShortfallNote, readinessUnstableBaselineNote;
import '../../data/db.dart' show DbRebuild;
import '../../data/journal_fields.dart' show formatMinuteOfDay;
import '../../data/local_repository.dart';
import '../../data/read_paused.dart';
import '../../sync/import_focus.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/presentation_text.dart';
import '../../l10n/display_text.dart';
import '../../l10n/decimal_text.dart';
import '../../state/locale_controller.dart';
import 'package:intl/intl.dart';
import 'package:openstrap_analytics/onehz.dart'
    show quietHrrMinDays, readinessCompositeMinBaseline;
import '../../models/metric.dart';
import '../../models/payloads.dart' show todayHeadlineOf;
import '../../notify/notification_prefs.dart' show NotificationPrefs;
import '../../gestures/gesture_failures.dart';
import '../../state/app_state.dart';
import '../../state/clock_format.dart' show formatClockOf;
import '../../state/prefs.dart';
import '../../state/recalc_state.dart';
import '../../state/units_controller.dart';
import '../../theme/theme_switcher.dart' show themedRoute;
import '../activity/day_strain.dart' show DayStrainDetail;
import '../profile/alarm.dart'
    show AlarmArmState, alarmArmOf, alarmGlanceCard;
import '../profile/devices.dart' show formatDayTime;
import '../profile/profile.dart' show ProfileAvatar;
import '../profile/settings.dart' show MoreSettings;
import '../profile/wearable_numbers.dart'
    show WearableCells, kHomeWearableRows, wearableName;
import '../ui2.dart';
import 'ai_briefing.dart' show AiBriefingScreen;
import 'coach.dart';
import 'detected_activities.dart';
import 'day_timeline.dart' show DayTimelineScreen;
import 'moment_follow_up.dart' show momentFollowUpCard;
import 'metric_detail.dart';
import 'natural_wake_card.dart';
import 'snooze_card.dart';
import 'readiness_detail.dart';
import 'sleep_detail.dart';

// ═══════════════════ shared plumbing ═══════════════════

/// Page padding. The bottom inset clears the shell's floating nav.
const pad = kTabRootPad;

/// Push a detail screen. Every drill-down in ui2 goes through here.
///
/// This was a raw `PageRouteBuilder` with its own fade+slide, which silently
/// killed the iOS edge-swipe-back on all ~20 screens it pushes — a
/// PageRouteBuilder has no interactive back-gesture machinery. The app's own
/// transition is registered in the theme instead (see page_transitions.dart),
/// so a plain route gets the fade-through on Android and the Cupertino slide
/// WITH swipe-back on iOS. [themedRoute] also keeps the pushed screen
/// re-colouring on an appearance change and names the route for Crashlytics.
void go(BuildContext c, Widget w) => Navigator.of(c)
    .push(themedRoute((_) => w, name: w.runtimeType.toString()));

/// The repo, or null when there is no AppState above us — which is the case in
/// every golden. A screen with no repo renders its absent states, which is
/// exactly what we want a golden to capture.
LocalRepository? repoOf(BuildContext c) {
  try {
    return c.read<AppState>().repo;
  } catch (_) {
    return null;
  }
}

/// Asks the background warmer for an artifact (`beats|<day>`, `circadian`):
/// what a screen with nothing stored does instead of computing in its build
/// path. The returned future completes when the warm has finished or been
/// dropped, and the revision has moved if it stored something. Null in a golden
/// (no AppState to ask).
Future<void> Function(String key)? warmRequesterOf(BuildContext c) {
  try {
    return c.read<AppState>().requestWarm;
  } catch (_) {
    return null;
  }
}

/// The user's unit system, or null in a golden. A screen that cannot reach it
/// renders what the store holds, which is metric.
UnitsController? unitsOf(BuildContext c) {
  try {
    return c.watch<UnitsController>();
  } catch (_) {
    return null;
  }
}

/// "72.4 kg" → `('72.4', 'kg')`. [UnitsController] owns every conversion and
/// hands back one string; this only puts the two halves in the two slots a
/// row has. Never convert in a screen.
(String, String) splitUnit(String s) {
  final i = s.lastIndexOf(' ');
  return i < 0 ? (s, '') : (s.substring(0, i), s.substring(i + 1));
}

/// The band-sync trigger, or null when there is no AppState above us. Every
/// "Sync the band" CTA in this folder goes through here — a call to action
/// with no action behind it is worse than no call to action.
VoidCallback? syncOf(BuildContext c) {
  try {
    final app = c.read<AppState>();
    return app.syncNow;
  } catch (_) {
    return null;
  }
}

/// The failed-gesture store, or null in a golden. The card
/// (gesture_failure_card.dart) listens to it itself, so Home only needs to reach it.
GestureFailureStore? gestureFailuresOf(BuildContext c) {
  try {
    return c.read<AppState>().gestureFailures;
  } catch (_) {
    return null;
  }
}

/// Whether the database had to be rebuilt to start this launch, or null in a
/// golden. Same shape as [repoOf] and [syncOf].
DbRebuild? dbRebuildOf(BuildContext c) {
  try {
    return c.read<AppState>().dbRebuild;
  } catch (_) {
    return null;
  }
}

/// The armed alarm and its state, or null when there is no AppState above us
/// (every golden). Read-only: Home never arms or re-arms anything.
(DateTime?, AlarmArmState)? alarmArmOfContext(BuildContext c) {
  try {
    return c.select<AppState, (DateTime?, AlarmArmState)>(alarmArmOf);
  } catch (_) {
    return null;
  }
}

/// Whether a live workout is open, or false in a golden. `select`, not
/// `watch`: AppState ticks at ~1 Hz while a session is live, and this screen
/// only cares about the bool flipping. The bare-day card branches on it — see
/// [workoutHoldCard].
bool workoutLiveOf(BuildContext c) {
  try {
    return c.select<AppState, bool>((a) => a.activeWorkout != null);
  } catch (_) {
    return false;
  }
}

/// Whether cycle tracking is on, or false in a golden. `select` for the same
/// reason as its neighbours.
bool cycleTrackingOf(BuildContext c) {
  try {
    return c.select<AppState, bool>((a) => a.cycleTrackingEnabled);
  } catch (_) {
    return false;
  }
}

/// Whether a derive job is running or about to (the backlog just landed and
/// today's numbers are being worked out), or false in a golden.
/// How far the data we hold actually reaches — the band's OWN clock on the
/// newest record BANKED, not when the BLE frame arrived and not when the app
/// last talked to the strap. Null in a golden and before any record exists.
///
/// `select`, like its neighbours: this rebuilds when the data edge moves, not
/// on AppState's ~1 Hz heartbeat.
DateTime? lastDataAtOf(BuildContext c) {
  try {
    return c.select<AppState, DateTime?>((a) => a.lastRecordAt);
  } catch (_) {
    return null;
  }
}

/// "Synced through 11:06" — the one line that answers "how far are we?".
///
/// It reads the BAND's clock, so it says how far the DATA reaches. That is a
/// different number from "last contact" and only this one is the question a
/// sync status has to answer: a connection that transfers nothing is not
/// progress, and a status built on contact time would report it as progress.
///
/// [todayId] is the `YYYY-MM-DD` the screen is ALREADY showing, not
/// `DateTime.now()`. A clock read during `build` decides "is this today?" once
/// and then goes stale — sitting on Home across midnight with no new record,
/// last night's 23:50 would keep rendering as a bare "23:50" and read as
/// tonight. Keying off the rendered day cannot contradict the date line
/// directly above it, whatever the hour. Null (no day on screen yet) ⇒ always
/// dated, which is the honest answer when we do not know what "today" is.
///
/// Bare clock time for the day on screen, the full "Fri 4 Sep, 07:12"
/// otherwise — a lone "07:12" against a strap not worn since Friday is the
/// most misleading thing this line could say.
String syncedThroughLabel(DateTime? at, String? todayId,
    [AppLocalizations? l]) {
  final when = _throughWhen(at, todayId, l);
  if (when == null) return l?.homeSyncedNever ?? 'No band data yet';
  return l?.homeSyncedThrough(when) ?? 'Synced through $when';
}

/// "Through 11:06": the same fact in less width, for a header line that has
/// other things to carry. Only the lead word goes; the time never does.
String syncedThroughShortLabel(DateTime? at, String? todayId,
    [AppLocalizations? l]) {
  final when = _throughWhen(at, todayId, l);
  if (when == null) return l?.homeSyncedNever ?? 'No band data yet';
  return 'Through $when';
}

/// The time part of [syncedThroughLabel]; null when no record exists.
String? _throughWhen(DateTime? at, String? todayId, AppLocalizations? l) {
  if (at == null) return null;
  final today = todayId == null ? null : DateTime.tryParse(todayId);
  final isToday = today != null &&
      at.year == today.year &&
      at.month == today.month &&
      at.day == today.day;
  // The user's 12/24-hour choice, the same clock every other time uses.
  return isToday ? formatClockOf(at) : formatDayTime(at, l);
}

/// The band's battery, straight off the same [DeviceState] devices.dart
/// already reads (`app.device.batteryPct`/`.charging`) — never a second poll.
/// Null when unpaired or the strap hasn't reported a level yet, which this
/// deliberately renders as nothing rather than a placeholder.
(double, bool)? deviceBatteryOf(BuildContext c) {
  try {
    return c.select<AppState, (double, bool)?>((a) {
      final pct = a.device.batteryPct;
      final charging = a.device.charging;
      // Both or neither — a known level with an unknown charging state must
      // not fall back to `false`, which would draw a plain (or worse, red)
      // icon over a charging state we simply haven't heard yet.
      return (pct == null || charging == null) ? null : (pct, charging);
    });
  } catch (_) {
    return null;
  }
}

/// Draining, not charging, at or under the same default the low-battery
/// notification uses ([NotificationPrefs.batteryPctDefault]) — this reads the
/// shared constant rather than the user's live pref, since a color hint on
/// Home is not worth an async prefs read on every build.
bool lowBattery(double pct, bool charging) =>
    // Strict `<`, matching device_alerts.dart's own `fireLow` comparison —
    // the color hint should agree with the alert at the boundary, not just
    // near it.
    !charging && pct < NotificationPrefs.batteryPctDefault;

/// Whether the band link is up, read off the same [DeviceState] the rest of
/// the app uses. Null when there is no AppState above (a golden).
bool? deviceConnectedOf(BuildContext c) {
  try {
    return c.select<AppState, bool>((a) => a.isConnected);
  } catch (_) {
    return null;
  }
}

/// "59% · Connected" with a battery glyph, under the sync line. Connection is
/// said here and only here; the sync line above carries data recency and time.
/// Mirrors devices.dart's `SourceRow` battery chip (same icon swap, same 13px
/// size). The reading is the strap's last report, so it is shown only while
/// connected; with no level yet (or no link) it is the connection alone, never
/// a placeholder. Null with no AppState above.
/// The Natural Wake "I'm up" card; null with no AppState above (a golden).
Widget? _naturalWakeCard(BuildContext c) {
  try {
    return NaturalWakeBuzzingCard(wake: c.read<AppState>().wake);
  } on ProviderNotFoundException {
    return null;
  }
}

Widget? connectionLine(BuildContext c, [AppLocalizations? l]) {
  final connected = deviceConnectedOf(c);
  if (connected == null) return null;
  final battery = connected ? deviceBatteryOf(c) : null;
  final p = P.of(c);
  final color = battery != null && lowBattery(battery.$1, battery.$2)
      ? p.on(C.red)
      : p.ink3;
  final state = connected
      ? (l?.devicesConnected ?? 'Connected')
      : (l?.devicesNotConnected ?? 'Not connected');
  return Row(mainAxisSize: MainAxisSize.min, children: [
    if (battery != null) ...[
      Icon(battery.$2 ? LucideIcons.batteryCharging : LucideIcons.battery,
          size: 13, color: color),
      const SizedBox(width: 3),
    ],
    Flexible(
      child: Text(
        battery == null ? state : '${battery.$1.round()}% · $state',
        style: F.cap.copyWith(color: color),
      ),
    ),
  ]);
}

/// The rows under the sync row (the app-wide [StatusLine] with Home's sync
/// actions): just the connection line. The avatar is in the title row.
List<Widget> homeHeaderRows(BuildContext c, {AppLocalizations? l}) {
  return [
    // The connection and battery live on AppState.device, independent of
    // HomeData — a load failure or first run must not hide them too. A
    // start-aligned Column, so the line keeps its identity when the day lands.
    if (connectionLine(c, l) case final conn?) ...[
      const SizedBox(height: 2),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [conn]),
    ],
  ];
}

/// The profile button in the title row. While a sync runs it gives way to a
/// spinner: same slot, same 40 pt size, same on-colour, so the title row never
/// changes shape and the sync row is left to the status text. Present in every
/// Home state, including before the first read lands.
Widget _homeAvatar(BuildContext c, AppLocalizations? l) {
  final p = P.of(c);
  return syncBusyOf(c)
      ? Pressable(
          semanticLabel:
              '${l?.homeProfileSettings ?? 'Profile and settings'}, syncing',
          onTap: () => go(c, const MoreSettings()),
          child: Container(
            width: 40,
            height: 40,
            decoration:
                BoxDecoration(shape: BoxShape.circle, color: p.fill(C.domHome)),
            child: Center(child: syncBusyMark(p.inkOnFill)),
          ),
        )
      : const ProfileAvatar(accent: C.domHome);
}

/// Whether a sync is running, from the same presentation state the sync line
/// reads. False with no AppState above (a golden).
bool syncBusyOf(BuildContext c) {
  try {
    return c.select<AppState, bool>((a) => a.syncPresentation.busy);
  } catch (_) {
    return false;
  }
}

/// The next armed alarm, or null with none held (or in a golden). May be an
/// instant already past — the sleep ring ignores those.
DateTime? nextAlarmOf(BuildContext c) {
  try {
    final e = c.select<AppState, int?>((a) => a.alarmEpoch);
    return e == null ? null : DateTime.fromMillisecondsSinceEpoch(e * 1000);
  } catch (_) {
    return null;
  }
}

/// The saved expected sleep schedule, or null with none saved (or in a golden).
ExpectedSleepSchedule? sleepScheduleOf(BuildContext c) {
  try {
    return c.select<AppState, ExpectedSleepSchedule?>(
        (a) => a.sleepOperations.schedule);
  } catch (_) {
    return null;
  }
}

bool derivingOf(BuildContext c) {
  try {
    return c.select<AppState, bool>((a) => a.deriving || a.derivePending);
  } catch (_) {
    return false;
  }
}

/// Read a metric envelope. `_scalarMetric` writes the literal string `'—'` for
/// an absent value, so this must never be replaced by `map['value'] as num`.
Metric metricOf(Object? raw) => Metric.parse(raw);

/// WHICH SENSOR counted the steps, in the two words a card has room for — or
/// null when nothing counted (and on days derived before the ladder existed,
/// whose envelopes name no sensor).
///
/// Read off `inputs_used`, which names the sensor rather than the table the
/// count was stored in. The strap's 100 Hz pedometer and its on-chip counter
/// are BOTH "Strap" here: they are genuinely different measurements, but that
/// difference is a density-3 fact and it is spelled out on Nerd stats. What
/// this must never blur is strap versus phone — a card that lets the phone's
/// count read as the wrist's, or the other way round, defeats the whole point
/// of resolving the day per window.
String? stepSensorLabel(Metric m, [AppLocalizations? l]) {
  final used = m.inputsUsed;
  final strap = used.contains('band_pedometer_100hz') ||
      used.contains('band_step_counter');
  final phone = used.contains('phone_pedometer');
  if (strap && phone) return l?.homeStepSensorStrapPhone ?? 'Strap + phone';
  if (strap) return l?.homeStepSensorStrap ?? 'Strap';
  if (phone) return l?.homeStepSensorPhone ?? 'Phone';
  return null;
}

/// The inner object of an envelope whose `value` is a MAP, not a number —
/// every cross-day metric is one of these (`regularity.value.sri`,
/// `sleep_coach.need.value.need_sec`). `Metric.parse` reads those as absent,
/// because a map is not a num, so the object has to come out by hand.
Map<String, dynamic>? envValue(Object? raw) {
  if (raw is! Map) return null;
  final v = raw['value'];
  return v is Map ? v.cast<String, dynamic>() : null;
}

/// The night the overnight block in a `getToday()` result actually came from,
/// when that is NOT today's — otherwise null.
///
/// `getToday` holds the last scored night over until today's settles, which is
/// every morning before the first sync and the whole of any gap after one.
/// Readiness, sleep, resting HR, HRV and skin temperature then all describe
/// that night while steps and active energy describe today.
///
/// WHAT THIS IS STILL FOR, now that no screen prints its numbers as today's
/// (see [overnightMetric]): naming WHICH NIGHT, and opening it. A screen that
/// is explicitly about a dated night — Sleep, with a day stepper over it —
/// wants this, because the night it should open is the last one that scored,
/// not a calendar day with no sleep in it. Every screen resolves that night
/// HERE so Home, Readiness, Sleep and Health cannot each answer "which night?"
/// differently.
String? heldOverNightOf(Map<String, dynamic> today) {
  final st = today['status'];
  if (st is! Map) return null;
  return st['showing_prior_overnight'] == true
      ? st['overnight_day']?.toString()
      : null;
}

/// Why today has no overnight figures, or null when it has its own.
///
/// Two absences that are not interchangeable, both read straight off
/// `status.overnight_state`:
///
///   * `building` — today's records HAVE reached the app and the night has not
///     finished being worked out. It resolves on its own and there is nothing
///     to ask anyone to do.
///   * anything else — nothing from last night has arrived. Syncing is the
///     thing that changes it.
///
/// Prose, not a `key:arg` token, so `whyFromNote` passes it through as the
/// sentence it already is.
String? staleOvernightNote(Map<String, dynamic> today, [AppLocalizations? l]) {
  if (heldOverNightOf(today) == null) return null;
  final st = today['status'];
  return (st is Map ? st['overnight_state']?.toString() : null) == 'building'
      ? l?.homeOvernightBuilding ?? 'Last night is still being worked out.'
      : l?.homeOvernightNothingYet ??
          'Nothing from last night has reached the app yet.';
}

/// An overnight envelope, REFUSED when the night behind it is not today's.
///
/// This reverses a decision that was made deliberately and was wrong on a
/// phone. `getToday` serves the last scored night whenever today's has not
/// settled, and the old argument for printing it was that the number is real
/// and the most recent one there is, so naming its night is enough. It is not:
/// a figure in the today slot is read as today's before anything under it is,
/// so a morning the strap was never worn showed last week's sleep as this
/// morning's, and the caption saying otherwise sat below three rings nobody
/// reads past. A stale number is a worse answer than an honest gap.
///
/// So the numbers stop here and the reason travels in their place. The night
/// itself is not lost — [heldOverNightOf] still names it, and the screens that
/// are ABOUT a dated night still open it.
Metric overnightMetric(Map<String, dynamic> today, Object? raw,
    [AppLocalizations? l]) {
  final why = staleOvernightNote(today, l);
  return why == null ? metricOf(raw) : Metric(note: why);
}

/// A scalar lifted out of an object-valued envelope, wearing that envelope's
/// honesty (tier, confidence, note) so `StatusCard.forMetric` still works on
/// it.
Metric envMetric(Object? raw, num? scalar, {String? unit}) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  final env = Metric.parse({...m, 'value': scalar});
  return scalar == null && env.note == null
      ? Metric(unit: unit, note: m['note']?.toString())
      : Metric(
          value: scalar,
          unit: unit ?? env.unit,
          confidence: env.confidence,
          tier: env.tier,
          inputsUsed: env.inputsUsed,
          note: env.note,
        );
}

/// A `[{t, v}]` point list from `getChart`, timestamps INTACT.
///
/// [seriesOf] drops `t`, and everything downstream then labelled its x axis off
/// the ARRAY INDEX — `'Today'`, `'N days ago'`, weekday letters. `metric_series`
/// stores one row per DERIVED day, not one per calendar day, so after a sync gap
/// the newest stored point is days old and was still being called "Today".
/// Anything that draws a dated axis reads this.
///
/// A point keeps its `from_older_version` (and `older_version_reason`, when the
/// payload has one): the flag is read off the same map as the value.
List<ChartPoint> pointsOf(Object? chart) {
  final pts = chart is Map ? chart['points'] : null;
  if (pts is! List) return const [];
  return [
    for (final e in pts)
      if (e is Map && e['v'] is num && e['t'] is num)
        ChartPoint(
          t: (e['t'] as num).round(),
          v: (e['v'] as num).toDouble(),
          olderVersion: e['from_older_version'] is num
              ? (e['from_older_version'] as num).toInt()
              : null,
          olderReason: e['older_version_reason']?.toString(),
        ),
  ];
}

/// The bare values of a point list, for statistics — a mean, a last reading,
/// an [AxisSpec]. NEVER for a painter: a compacted list is the bug, because it
/// lets 22 stored days masquerade as 30 continuous ones.
List<double> valuesOf(List<ChartPoint> pts) => [for (final p in pts) p.v];

/// [pts] laid out DENSE: one slot per calendar day, [days] slots long, ending
/// today. A day `metric_series` has no row for is `null`, which the painter
/// draws as a break rather than joining across.
///
/// This is the shape every chart in this app takes. `metric_series` gets a row
/// only on a day that derives, so the stored list is already compacted: after a
/// four-day sync gap the newest point sat at the right-hand edge under the
/// label "Today", and the line ran straight through the missing week as though
/// it had been measured.
List<double?> denseDays(List<ChartPoint> pts, int days) =>
    [for (final p in denseChartPoints(pts, days)) p?.v];

/// The point behind each [denseDays] slot, flag included: a slot's value and
/// its provenance are one object, so they cannot be read from different days.
List<ChartPoint?> denseChartPoints(List<ChartPoint> pts, int days) {
  final out = List<ChartPoint?>.filled(days, null);
  for (final p in pts) {
    final behind = daysBehind(p.t);
    if (behind == null || behind < 0 || behind >= days) continue;
    out[days - 1 - behind] = p;
  }
  return out;
}

/// Per-slot older version, the same slots as [denseDays]; null where the slot
/// is a current value or a gap.
List<int?> denseOlderVersions(List<ChartPoint> pts, int days) =>
    [for (final p in denseChartPoints(pts, days)) p?.olderVersion];

/// A `[{t, v}]` point list from `getChart` as a plain series.
///
/// Values only — the caller cannot tell WHEN any of them was recorded. Use
/// [pointsOf] for anything that labels, spans or dates the series; this is for
/// sparklines, which claim nothing about time.
List<double> seriesOf(Object? chart) => valuesOf(pointsOf(chart));

/// An x-axis label for a stored point: [todayWord] when the point really is
/// today's, otherwise "N days ago" counted from the point's OWN date.
///
/// The same vocabulary the axes already spoke. What changed is where N comes
/// from: it used to be the point's position in the array, and `metric_series`
/// holds one row per DERIVED day, so a thirty-point series can span two months
/// and both its edges were labelled as though it spanned thirty days.
String axisDay(int? epochSec,
    {String todayWord = 'Today', String unitWord = 'days'}) {
  final behind = daysBehind(epochSec);
  if (behind == null) return '';
  if (behind <= 0) return todayWord;
  // "1 days ago" read as a typo on the card that says "as of ...". The words
  // passed in are English plurals ("days", "nights"), so one drops the s.
  final unit = behind == 1 && unitWord.endsWith('s')
      ? unitWord.substring(0, unitWord.length - 1)
      : unitWord;
  return '$behind $unit ago';
}

/// Whole calendar days between a stored point and today, or null when there is
/// no point. Anything above zero means the number drawn is not today's, and a
/// card that presents it as today's has to say so.
int? daysBehind(int? epochSec) {
  if (epochSec == null) return null;
  return calendarDaysBetween(
      DateTime.fromMillisecondsSinceEpoch(epochSec * 1000), pc.clock.now());
}

/// The withheld-rollup reason inside a `getInsights()` result, or null when the
/// result is real (or simply empty).
Map<String, dynamic>? staleReasonOf(Map<String, dynamic> insights) =>
    insights['stale'] is Map
        ? (insights['stale'] as Map).cast<String, dynamic>()
        : null;

/// The cross-day rollup was WITHHELD: `getInsights` returned the reason it
/// refused instead of the numbers (`LocalRepositoryImpl.crossDayStaleReason`).
///
/// Every screen that reads the rollup renders this rather than quietly showing
/// nothing — "you have no drivers yet" and "we have drivers we will not stand
/// behind" are different states, and the cold-start copy is a wrong answer to
/// the second one.
/// The database could not be opened on this launch and was rebuilt.
///
/// This is the loudest thing this screen can say, and it should be: the old
/// file is parked on disk and only what `salvaged` lists came back. A rebuild
/// the user never hears about is indistinguishable from their data quietly
/// vanishing — which is the one thing a local-first app must never do.
///
/// The counts are stated per table rather than summed. "1,204 rows recovered"
/// reads as reassurance; "nutrition 0" is the sentence that actually tells
/// someone their food log is gone.
StatusCard? dbRebuiltCard(DbRebuild? r, [AppLocalizations? l]) {
  if (r == null) return null;
  final saved = r.salvaged.entries.where((e) => e.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final lost = r.salvaged.entries.where((e) => e.value == 0).toList();
  final savedList = saved.map((e) => '${e.key} ${thousands(e.value)}').join(' · ');
  final lostList = lost.map((e) => e.key).join(' · ');
  return StatusCard(
    l?.homeDbRebuiltTitle ?? 'Your database was rebuilt',
    '${r.cause}\n\n'
        '${saved.isEmpty ? (l?.homeDbRebuiltNothingRecovered ?? 'Nothing could be read back.') : (l?.homeDbRebuiltRecovered(savedList) ?? 'Recovered: $savedList.')}'
        '${lost.isEmpty ? '' : ' ${l?.homeDbRebuiltEmpty(lostList) ?? 'Empty: $lostList.'}'}'
        '\n\n${l?.homeDbRebuiltKept(r.quarantinePath) ?? 'The original file is kept at ${r.quarantinePath} — nothing was deleted.'}',
    icon: LucideIcons.databaseBackup,
  );
}

/// The bare day during a live workout — missing COMPUTE, not data. A live
/// session holds derivation (`DeriveScheduler.setWorkoutActive`), so nothing
/// lands in `day_result` until it ends: the band keeps recording, the sync
/// keeps landing records, and "Sync the band" is a false answer — the sync
/// completes and changes nothing on this screen. The true remedy is finishing
/// the session, and its bar is pinned right below this card, so the card
/// points there rather than duplicating the door.
StatusCard workoutHoldCard([AppLocalizations? l]) => StatusCard(
      l?.homeWorkoutHoldTitle ?? 'A workout is still running',
      l?.homeWorkoutHoldBody ??
          'Today fills in when you finish the workout.',
      icon: LucideIcons.timer,
    );

StatusCard? staleInsightsCard(
    Map<String, dynamic>? reason, VoidCallback? onSync, [AppLocalizations? l]) {
  final s = reason;
  if (s == null) return null;
  final built = s['built_for_day']?.toString();
  return StatusCard(
    l?.homeInsightsRebuildingTitle ?? 'Updating your trends',
    switch (s['kind']) {
      'algo_version' => l?.homeInsightsRebuildingAlgoVersion ??
          'Updating after the latest app update.',
      'stale' => built == null || built.isEmpty
          ? (l?.homeInsightsStaleOverWeek ??
              'Your trends were last updated over a week ago. Sync the band to bring them up to date.')
          : (l?.homeInsightsStaleOnDay(prettyDay(built, l)) ??
              'Your trends were last updated on ${prettyDay(built, l)}. Sync the band to bring them up to date.'),
      _ => l?.homeInsightsNoVersionStamp ?? 'Your trends are being updated. This takes a minute after a sync.',
    },
    fix: onSync == null ? '' : (l?.homeSyncBand ?? 'Sync the band'),
    icon: LucideIcons.refreshCw,
    onFix: onSync,
  );
}

// ── formatting ──

String hm(num? minutes) {
  if (minutes == null) return '';
  final m = minutes.round();
  final l = lookupAppLocalizations(
    Locale(LocaleController.displayLanguageCode),
  );
  return m < 60
      ? l.supplementMinutesValue('$m')
      : l.supplementHoursMinutesValue(
          '${m ~/ 60}',
          (m % 60).toString().padLeft(2, '0'),
        );
}

String _compactHm(num? minutes, AppLocalizations? l) {
  if (minutes == null) return '';
  final value = minutes.round();
  return value % 60 == 0
      ? l?.supplementHoursValue('${value ~/ 60}') ?? '${value ~/ 60}h'
      : hm(value);
}

String thousands(num? v) => v == null
    ? ''
    : NumberFormat.decimalPattern(
        LocaleController.displayLanguageCode,
      ).format(v.round());

/// A metric value at the precision its unit actually carries.
///
/// ONE rule, so the same reading is not `71.6` on the detail screen and `72`
/// on the card that links to it. A tenth of a bpm on a nocturnal minimum — or
/// of a millisecond on beat timing recovered from 1 Hz records — is precision
/// the measurement does not have, and a number printing more digits than it
/// knows reads as a more careful measurement than it is. Unitless scores keep
/// a decimal only while they are small enough for one to mean something.
String metricValue(String unit, num? value) {
  if (value == null) return '';
  final v = value.toDouble();
  switch (unit) {
    case 'min':
      return hm(v);
    case 'steps':
    case 'kcal':
      return thousands(v);
    case 'bpm':
    case 'ms':
    case '%':
      return v.round().toString();
    case 'br/min':
    case '°':
      return displayFixed(v, 1);
  }
  if (v.abs() >= 100) return v.round().toString();
  if (v.abs() >= 10) return displayFixed(v, v == v.roundToDouble() ? 0 : 1);
  return displayFixed(v, 1);
}

/// The unit to print BESIDE [metricValue]'s output, which is empty when the
/// format already carries it: `metricValue('min', 443)` is "7h 23m", and a
/// `min` label next to that reads "7h 23m min".
String unitBeside(String unit) => unit == 'min'
    ? ''
    : localizedText(
        lookupAppLocalizations(Locale(LocaleController.displayLanguageCode)),
        unit,
      );

/// Minute-of-day → "10:40 PM".
///
/// ONE clock format in the app. This used to render 24-hour while Wellness
/// rendered the same field 12-hour, so a target bedtime read `22:40` on Home
/// and `10:40 PM` two screens away. Both now go through the journal layer's
/// [formatMinuteOfDay], which follows the user's 12/24-hour choice
/// (`state/clock_format.dart`).
String clock(num? minOfDay) =>
    minOfDay == null ? '' : formatMinuteOfDay(minOfDay.round());

/// Epoch seconds → "11:08 PM" / "23:08" in the device zone.
String clockOfTs(num? ts) {
  if (ts == null) return '';
  return formatClockOf(DateTime.fromMillisecondsSinceEpoch(ts.round() * 1000));
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String monthName(int month, AppLocalizations? l) {
  if (l == null) return _months[month - 1];
  return [
    l.homeMonthJanuary, l.homeMonthFebruary, l.homeMonthMarch,
    l.homeMonthApril, l.homeMonthMay, l.homeMonthJune,
    l.homeMonthJuly, l.homeMonthAugust, l.homeMonthSeptember,
    l.homeMonthOctober, l.homeMonthNovember, l.homeMonthDecember,
  ][month - 1];
}

const _monthsShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Abbreviated month for "Thu 4 Sep" date chips.
String monthShortName(int month, AppLocalizations? l) {
  if (l == null) return _monthsShort[month - 1];
  return [
    l.homeMonthJanuaryShort, l.homeMonthFebruaryShort, l.homeMonthMarchShort,
    l.homeMonthAprilShort, l.homeMonthMayShort, l.homeMonthJuneShort,
    l.homeMonthJulyShort, l.homeMonthAugustShort, l.homeMonthSeptemberShort,
    l.homeMonthOctoberShort, l.homeMonthNovemberShort, l.homeMonthDecemberShort,
  ][month - 1];
}

const _weekdaysShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Abbreviated weekday for `DateTime.weekday` (1 = Monday), e.g. "Thu 4 Sep"
/// date chips. Reuses the `wellness*` short-day keys — they're already
/// translated everywhere and mean the same three letters here.
String weekdayShortName(int weekday, AppLocalizations? l) {
  if (l == null) return _weekdaysShort[weekday - 1];
  return [
    l.wellnessMon, l.wellnessTue, l.wellnessWed,
    l.wellnessThu, l.wellnessFri, l.wellnessSat, l.wellnessSun,
  ][weekday - 1];
}

/// 'YYYY-MM-DD' → "Saturday, 20 May".
String prettyDay(String? dayId, [AppLocalizations? l]) {
  final d = dayId == null ? null : DateTime.tryParse(dayId);
  if (d == null) return '';
  return localizedDate(
    d,
    l?.localeName ?? LocaleController.displayLanguageCode,
    weekday: true,
  );
}

/// The readiness band. `readiness_glassbox` carries no label of its own, so the
/// banding is ours and lives in one place — this one.
///
/// [tier] is that same banding in a form the native surfaces can read.
/// `WidgetService.push` publishes it as `readiness_tier` (and [label] as
/// `readiness_band`) so the widget, the Watch and Siri paint it in their own
/// palettes instead of each keeping a private copy of the cut-offs. They did,
/// and a 65 rendered green on the phone, orange on the widget and yellow on
/// the wrist. -1 = not scored.
///
/// THE CUT-OFFS ARE THE SCORE'S OWN QUANTILES, NOT ROUND NUMBERS (issue #250).
/// `readinessComposite` is `100 / (1 + exp(-z̄))` with no scale parameter, and
/// z̄ is a weight-renormalised mean of per-input robust z's — each ~N(0,1)
/// against that person's OWN baseline. So the score is a percentile of self
/// whose CENTRE IS 50 BY CONSTRUCTION: a night exactly at personal median
/// scores 50, and the old 40/60/80 bands filed that median night under "Take it
/// easy". Roughly a quarter of all nights fell under "Rest today" and 1.7 %
/// could ever reach "Good to go" — it needed every input ~1.4 SD above median
/// at once. A warning that fires on the typical night is not a warning.
///
/// z̄'s own SD is NOT 1: averaging the disclosed weights (.40/.30/.20/.10,
/// renormalised over present inputs) gives σ ≈ 0.55-0.60 if the inputs were
/// independent, ~0.70 at the positive correlation HRV/RHR/RR actually have.
/// σ ≈ 0.65 is the middle of that, and the cut-offs below are its quantiles:
///
///   score = 100 / (1 + exp(-0.65 · Φ⁻¹(p)))
///     p=.05 → 26   p=.20 → 37   p=.75 → 61
///
/// (`kReadinessRestBelow` / `kReadinessEasyBelow` / `kReadinessGoodFrom` in
/// findings.dart, shared with the push and the log), which lands 5 % of nights
/// on "Rest today", 15 % on "Take it easy", 55 % on "Steady" and 25 % on
/// "Good to go". The median night is now the neutral band,
/// which is the whole point. Under the old cut-offs the same distribution read
/// 27 / 47 / 25 / 2.
///
/// σ is the one soft number here — it is a property of how correlated a given
/// person's four inputs are, and it moves with how many of them are present.
/// Re-derive it from a real `metric_series` readiness distribution when there
/// is one long enough to measure; do not nudge the cut-offs by feel.
({String label, Color color, int tier}) readinessBand(num? v,
    [AppLocalizations? l]) {
  if (v == null) {
    return (label: l?.homeReadinessNotScored ?? 'Not scored', color: C.n400, tier: -1);
  }
  if (v >= kReadinessGoodFrom) {
    return (label: l?.homeReadinessGoodToGo ?? 'Good to go', color: C.green, tier: 3);
  }
  if (v >= kReadinessEasyBelow) {
    return (label: l?.homeReadinessSteady ?? 'Steady', color: C.green, tier: 2);
  }
  if (v >= kReadinessRestBelow) {
    return (label: l?.homeReadinessTakeItEasy ?? 'Take it easy', color: C.orange, tier: 1);
  }
  return (label: l?.homeReadinessRestToday ?? 'Rest today', color: C.red, tier: 0);
}

/// Glass-box driver keys are the pipeline's own short names.
const driverLabels = {
  'hrv': 'HRV',
  'rhr': 'Resting heart rate',
  'resp': 'Breathing rate',
  'temp': 'Skin temperature',
};

/// A pipeline key the map does not cover is HUMANISED, never printed raw. The
/// glass-box emits whatever inputs the composite used, so a new one used to
/// surface on Home as `resp_rate_slope`.
String driverLabel(Object? key, [AppLocalizations? l]) {
  final k = key?.toString() ?? '';
  final known = switch (k) {
    'hrv' => l?.homeDriverHrv ?? driverLabels['hrv'],
    'rhr' => l?.homeDriverRhr ?? driverLabels['rhr'],
    'resp' => l?.homeDriverResp ?? driverLabels['resp'],
    'temp' => l?.homeDriverTemp ?? driverLabels['temp'],
    _ => null,
  };
  if (known != null) return known;
  if (k.isEmpty) return '';
  final words = k.replaceAll('_', ' ').trim();
  return words.isEmpty
      ? ''
      : '${words[0].toUpperCase()}${words.substring(1)}';
}

/// The three rings, and what each one does when its metric is not there.
///
/// A ring is a shape that always renders, and this data frequently is not
/// there: readiness exists on 71 % of days and needs four prior nights before
/// it exists at all. So the absent states ARE the design here rather than an
/// error branch bolted onto three pretty circles. Each ring has four:
///
///   * MEASURED — an arc, the number, and what the number is out of.
///   * CALIBRATING — a muted arc at nights-banked over nights-needed, with the
///     count under it. Visibly progress towards a real ring; an arc at zero
///     would read as a bad score, which is the lie this exists to avoid. It is
///     drawn only for a `need_baseline` note, the one absence that IS progress.
///   * MEASURED, UNSCALED — sleep with no computed need behind it. The number
///     is real and the fraction is not known, so the track draws empty and the
///     line under it says there is no target yet. Filling it against the
///     hardcoded 480 would be inventing the user's sleep need.
///   * ABSENT — the track alone, the absence in words where the number goes,
///     and the PIPELINE'S OWN reason on a row under the trio which is also the
///     door into the screen that can say more. Three [StatusCard]s is not a
///     home screen; a ring with nothing in it and no reason is worse than one.
///
/// Every ring opens something: recovery → [ReadinessDetail], strain →
/// [DayStrainDetail], sleep → [SleepDetail].
class RingTrio extends StatelessWidget {
  final HomeData d;

  /// Push the ring's own screen. Null in a gallery, where there is no navigator
  /// worth pushing onto.
  final void Function(HomeRingKind)? onOpen;

  /// The instant the sleep ring measures an unslept night's estimate from.
  /// Injected by tests; production reads `clock.now()`.
  final DateTime? now;
  final DateTime? since;
  /// Non-null while results are held stale (a hold AND newer recordings than
  /// the result covers): the old line's explanation. Draws the arc, makes the
  /// caption tappable.
  final String? holdText;

  /// What the help strip says instead of the default (the gaps' reasons, then
  /// the "Why?" footer, then the recovery update). The screen sets it for the
  /// states only it knows: first week, loading, calculating, failed.
  final RingHelp? help;

  /// Text the strip must have room for in ANY state, so its height does not
  /// change when it swaps (the first-week guidance, which is the longest).
  final String? reserveHelp;

  const RingTrio(
      {super.key,
      required this.d,
      this.onOpen,
      this.now,
      this.since,
      this.holdText,
      this.help,
      this.reserveHelp});

  /// Whether ANY of the three has something to draw. When none do, the screen
  /// owes the user one written absence, not three empty circles.
  static bool has(HomeData d, {DateTime? now}) {
    final at = now ?? pc.clock.now();
    return HomeRingKind.values.any((k) => _ringOf(k, d, null, at).why == null);
  }

  /// Whether the sleep ring can estimate tonight's sleep, and so has something
  /// to draw even when nothing else on the day does.
  static bool hasSleepEstimate(HomeData d, {DateTime? now}) =>
      _ringOf(HomeRingKind.sleep, d, null, now ?? pc.clock.now()).estimated;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final at = now ?? pc.clock.now();
    final rings = [for (final k in HomeRingKind.values) _ringOf(k, d, l, at)];
    final gaps = rings.where((r) => r.why != null).toList();
    final pressing = pressingRings(d, now: at);
    final older = d.strain.fromOlderVersion;
    // THERE IS NO "THESE TWO ARE FROM SATURDAY" LINE ANY MORE, and there is
    // nothing left for one to explain. Recovery and sleep used to be served
    // from the last scored night whenever today's had not settled, and this
    // card carried one sentence naming that night. Read on a phone, the
    // sentence lost: a number inside a ring is today's, and a caption under
    // three rings does not undo it. The loader refuses the older night now
    // ([overnightMetric]), so a ring with no night behind it is a gap row with
    // the reason in it — same place every other absence on this screen goes.

    return Surface(
      elevation: 2,
      child: LayoutBuilder(builder: (c, box) => Column(children: [
        // The "since" line: its own slim right-aligned row above the rings,
        // its height reserved whether or not the time is known.
        _sinceLine(c, l),
        // Rows replace columns by locale, text scale and width only, never by
        // the day's data: an empty card and a loaded one are the same layout.
        if (bigText(c))
          // Past ~1.3× a 100 pt column cannot hold the word "Recovery" on one
          // line and there is nowhere for it to wrap to. The ring keeps its
          // size and the type gets the width instead.
          for (var i = 0; i < rings.length; i++) ...[
            if (i > 0) const SizedBox(height: S.x2),
            _RingRow(rings[i], onTap: _open(rings[i].kind)),
          ]
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < rings.length; i++) ...[
                if (i > 0) const SizedBox(width: S.x3),
                Expanded(
                    child: _RingColumn(rings[i], onTap: _open(rings[i].kind))),
              ],
            ],
          ),
        // THE HELP STRIP: one fixed-height slot under the rings, the same box
        // first launch and loaded. Empty, it says what arrives when (or why a
        // ring is empty); loaded, it is the card's "Why?" footer.
        if (pressing.isNotEmpty || older != null) ...[
          const SizedBox(height: S.x3),
          for (var i = 0; i < pressing.length; i++) ...[
            if (i > 0) const SizedBox(height: S.x2),
            _HomeWhyPanel(kind: pressing[i], data: d, onTap: _open(pressing[i])),
          ],
          if (older != null)
            Padding(padding: EdgeInsets.only(top: pressing.isEmpty ? 0 : S.x2), child: _HomeOlderPanel(version: older, reason: d.strain.olderVersionReason,
                onTap: _open(HomeRingKind.strain)),
            ),
        ] else if (help != null && help!.text.isNotEmpty) ...[
          const SizedBox(height: S.x3),
          _HelpStrip(text: help!.text, onTap: help!.onTap,
              busy: help!.busy, chevron: help!.onTap != null,
              reserve: reserveHelp == null ? const [] : [reserveHelp!]),
        ] else if (gaps.isNotEmpty) ...[
          const SizedBox(height: S.x3),
          _HelpStrip(text: [for (final r in gaps) '${r.label} · ${presentationText(l, r.why ?? '')}'].join('\n'),
              onTap: _open(gaps.first.kind), busy: false, chevron: onOpen != null, reserve: const []),
        ],
      ])),
    );
  }

  /// The "since" line: ITS OWN row above the rings, at least 44 pt tall (S.tap) and
  /// the full card width, reserved whether or not the time is known (so it
  /// appears with no shift). When held, the whole line is the tap target; it is
  /// in the Column's flow, so it overlaps no dial and clips nothing.
  Widget _sinceLine(BuildContext c, AppLocalizations? l) {
    final lineH = math.max(S.tap, _measuredHeight(c, F.over, 'x') + 2 * S.x2);
    final t = since;
    if (t == null) {
      return SizedBox(
          key: const ValueKey('home-since-line'),
          width: double.infinity,
          height: lineH);
    }
    final p = P.of(c);
    final hold = holdText;
    final text = l?.homeSinceTime(DateFormat('HH:mm').format(t)) ??
        'since ${DateFormat('HH:mm').format(t)}';
    final caption = Row(
        key: const ValueKey('home-since'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hold != null) ...[
            SizedBox(
                key: const ValueKey('home-since-progress'),
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: p.ink3)),
            const SizedBox(width: 4),
          ],
          Text(text, style: F.over.copyWith(color: p.ink3)),
        ]);
    final line = SizedBox(
        key: const ValueKey('home-since-line'),
        width: double.infinity,
        height: lineH,
        child: Align(alignment: Alignment.centerRight, child: caption));
    if (hold == null) return line;
    return Pressable(
        semanticLabel: '$text. $hold', onTap: () => _explain(c, hold), child: line);
  }

  void _explain(BuildContext c, String hold) => showDialog<void>(
      context: c,
      builder: (dc) => AlertDialog(
            content: Text(hold),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(dc).pop(),
                  child: Text(MaterialLocalizations.of(dc).okButtonLabel)),
            ],
          ));

  VoidCallback? _open(HomeRingKind k) {
    final f = onOpen;
    return f == null ? null : () => f(k);
  }
}

/// Whether the shown results are held stale, and why: a derive hold AND newer
/// recordings than the result covers (exactly the old "Waiting for ..." line's
/// condition). Selects on the scheduler, so the caller rebuilds on a hold change
/// and on nothing else. Returns the old line's explanation, or null.
String? _holdText(BuildContext c, DateTime? since, DateTime? updatedAt) {
  (StaleHold?, DateTime?) h = (null, null);
  try {
    h = c.select<AppState, (StaleHold?, DateTime?)>((a) {
      final x = a.staleHold;
      return (x, x == null ? null : a.lastRecordAt);
    });
  } on ProviderNotFoundException {
    // No AppState (gallery): nothing is held.
  }
  final newest = h.$2;
  if (h.$1 == null || since == null || newest == null || !newest.isAfter(since)) {
    return null;
  }
  return stalenessText(
      updatedAt: updatedAt ?? since,
      recordingsThrough: since,
      newestRecording: newest,
      hold: h.$1,
      l: AppLocalizations.of(c));
}

class _HomeWhyPanel extends StatelessWidget {
  final HomeRingKind kind;
  final HomeData data;
  final VoidCallback? onTap;
  const _HomeWhyPanel({required this.kind, required this.data, this.onTap});

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final state = _ringOf(kind, data, l, DateTime.now());
    final title = switch (kind) {
      HomeRingKind.recovery => l?.homeWhyRecoveryTitle ?? 'Recovery is low',
      HomeRingKind.sleep => l?.homeWhySleepTitle ?? 'Sleep is short of need',
      HomeRingKind.strain => l?.homeWhyStrainTitle ?? 'Strain is above target',
    };
    final body = switch (kind) {
      HomeRingKind.recovery => _recoveryWhy(data, l),
      HomeRingKind.sleep => _sleepWhy(data, l),
      HomeRingKind.strain => _strainWhy(data, l),
    };
    return _HomeInsetRow(key: ValueKey('home-why:${kind.name}'), onTap: onTap,
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(key: ValueKey('home-why-icon:${kind.name}'), width: 32, height: 32,
          decoration: BoxDecoration(color: p.on(state.color).withValues(alpha: .14), shape: BoxShape.circle),
          child: Icon(state.icon, size: 17, color: p.on(state.color))),
        const SizedBox(width: S.x2),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(title, key: ValueKey('home-why-title:${kind.name}'), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: F.body.copyWith(fontWeight: FontWeight.w600, color: p.ink)),
          const SizedBox(height: 2),
          Text(body, key: ValueKey('home-why-body:${kind.name}'), maxLines: 2, overflow: TextOverflow.ellipsis,
            style: F.cap.copyWith(color: p.ink2)),
        ])),
        const SizedBox(width: S.x1),
        Icon(LucideIcons.chevronRight, size: 17, color: p.ink3),
      ]));
  }
}

/// Evidence or nothing. Built from what BOTH driver shapes carry (label and the
/// sign/size of the weighted `contribution`; the production `detail` is prose):
/// the biggest drags first. A number is added only when a numeric z is really in
/// `detail` (`...=<z>`) for every driver named; otherwise none is invented.
String _recoveryWhy(HomeData d, AppLocalizations? l) {
  final drags = <(String, double, double?)>[];
  for (final e in d.drivers) {
    final c = e['contribution'];
    if (c is! num || c >= 0) continue;
    final detail = '${e['detail']}';
    final z = detail.contains('=') ? double.tryParse(detail.split('=').last) : null;
    drags.add((driverLabel(e['label'], l), c.toDouble(), z));
  }
  drags.sort((a, b) => a.$2.compareTo(b.$2)); // largest drag first
  final top = drags.take(2).toList();
  String f(double? z) => z!.toStringAsFixed(1);
  final numeric = top.isNotEmpty && top.every((x) => x.$3 != null);
  if (top.length == 2) {
    final (a, b) = (top[0], top[1]);
    return numeric
        ? (l?.homeWhyRecoveryDrivers(a.$1, f(a.$3), b.$1, f(b.$3)) ??
            'Biggest drag: ${a.$1} ${f(a.$3)}, ${b.$1} ${f(b.$3)} (spreads from your baseline).')
        : (l?.homeWhyRecoveryPullingTwo(a.$1, b.$1) ??
            'Pulling it down: ${a.$1}, ${b.$1}.');
  }
  if (top.length == 1) {
    final a = top[0];
    return numeric
        ? (l?.homeWhyRecoveryDriver(a.$1, f(a.$3)) ??
            'Biggest drag: ${a.$1} ${f(a.$3)} (spreads from your baseline).')
        : (l?.homeWhyRecoveryPullingOne(a.$1) ?? 'Pulling it down: ${a.$1}.');
  }
  final v = (d.readiness.value ?? 0).round();
  return l?.homeWhyRecoveryPlain(v) ?? 'Recovery $v of 100';
}

String _strainWhy(HomeData d, AppLocalizations? l) {
  String n(num v) => v == v.round() ? '${v.round()}' : v.toStringAsFixed(1);
  final t = d.strainTarget;
  final low = t?['low'], high = t?['high'];
  final range = low is num && high is num ? '${n(low)}–${n(high)}' : n(high as num);
  final s = (d.strain.value ?? 0).toStringAsFixed(1);
  return l?.homeWhyStrainBody(s, range) ??
      'Strain $s, above today’s target of $range.';
}

String _sleepWhy(HomeData d, AppLocalizations? l) {
  final asleep = d.sleepMin.value, need = d.sleepNeedMin.value;
  if (asleep == null || need == null) return l?.homeWhySleepBody ?? 'Your scored sleep was below your need.';
  final gap = (need - asleep).clamp(0, need);
  String hm(num m) => '${m ~/ 60}h ${m.round() % 60}m';
  return l?.homeWhySleepDetail(hm(asleep), hm(gap), hm(need)) ??
      '${hm(asleep)} asleep, ${hm(gap)} under your ${hm(need)} need.';
}

class _HomeOlderPanel extends StatelessWidget {
  final int version;
  final String? reason;
  final VoidCallback? onTap;
  const _HomeOlderPanel({required this.version, this.reason, this.onTap});
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final why = olderVersionReasonText(l, reason);
    final line = why == null ? (l?.homeOlderVersion(version) ?? 'Version $version') : 'Version $version · $why';
    return _HomeInsetRow(key: const ValueKey('home-older-row'), onTap: onTap,
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(key: const ValueKey('home-older-row-icon'), width: 32, height: 32,
          decoration: BoxDecoration(color: p.ink3.withValues(alpha: .16), shape: BoxShape.circle),
          child: Icon(LucideIcons.history, size: 17, color: p.ink2)),
        const SizedBox(width: S.x2),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(l?.homeOlderTitle ?? '* Strain is from an older calculation', style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(line, style: F.cap.copyWith(color: p.ink2), maxLines: 2, overflow: TextOverflow.ellipsis),
        ])),
        Icon(LucideIcons.chevronRight, size: 17, color: p.ink3),
      ]));
  }
}

class _HomeInsetRow extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _HomeInsetRow({super.key, required this.child, this.onTap});
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final panel = Container(padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
      decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd), child: child);
    return onTap == null ? panel : Pressable(onTap: onTap, child: panel);
  }
}

/// "Updated 8:12 · 2 → 28" off a `todayHeadlineOf` `recovery_update`, or null.
String? recoveryUpdatedLine(Object? update, AppLocalizations? l) {
  if (update case {
    'from': final int from,
    'to': final int to,
    'at': final int at,
  }) {
    final time = formatClockOf(DateTime.fromMillisecondsSinceEpoch(at));
    return l?.homeRecoveryUpdated(time, from, to) ??
        'Updated $time · $from → $to';
  }
  return null;
}

/// The short line every screen showing today's recovery puts beside it when
/// it is not simply final: still asleep, finishing up, or changed since shown.
/// Read off one `todayHeadlineOf` result so Home, Readiness and Health agree.
String? recoveryStateLine(Map<String, dynamic> head, AppLocalizations? l) =>
    switch (head['recovery_state']) {
      'night_in_progress' => l?.homeRecoverySleeping ?? 'Sleeping…',
      'provisional' => l?.homeRecoveryFinishingUp ?? 'Finishing up',
      _ => recoveryUpdatedLine(head['recovery_update'], l),
    };

/// Which ring. The three the app can stand behind on a home screen: what the
/// night gave back, what the day has cost, and what the night was made of.
enum HomeRingKind { recovery, strain, sleep }

/// The two most urgent rings with readings the Home card can explain.
List<HomeRingKind> pressingRings(HomeData d, {DateTime? now}) {
  final ranked = <(HomeRingKind, int)>[];
  final recovery = d.readiness.value;
  if (recovery != null && d.readiness.fromOlderVersion == null && d.recoveryState != 'provisional' &&
      d.recoveryState != 'night_in_progress') {
    if (recovery < 26) ranked.add((HomeRingKind.recovery, 3));
    else if (recovery <= 36) ranked.add((HomeRingKind.recovery, 2));
  }
  final sleep = d.sleepMin.value, need = d.sleepNeedMin.value;
  if (sleep != null && d.sleepMin.fromOlderVersion == null && need != null && need > 0 && sleep / need < .85) {
    ranked.add((HomeRingKind.sleep, sleep / need < .70 ? 3 : 2));
  }
  final strain = d.strain.value;
  final high = d.strainTarget?['high'];
  if (strain != null && d.strain.fromOlderVersion == null && high is num && strain > high) {
    ranked.add((HomeRingKind.strain, 1));
  }
  const order = {HomeRingKind.recovery: 0, HomeRingKind.sleep: 1, HomeRingKind.strain: 2};
  ranked.sort((a, b) => b.$2.compareTo(a.$2) != 0
      ? b.$2.compareTo(a.$2)
      : order[a.$1]!.compareTo(order[b.$1]!));
  return [for (final item in ranked.take(2)) item.$1];
}

/// One ring's resolved state — the only place a metric becomes a shape.
class _RingState {
  final HomeRingKind kind;
  final String label, value, sub;
  /// Shorter wordings of [sub], widest first, that keep its meaning (the
  /// estimate marker, the default-target qualifier). The caption tries
  /// [sub], then each of these, and takes the first that fits.
  final List<String> alts;
  final IconData icon;
  final Color color;
  final int? olderVersion;
  final String? olderReason;

  /// What to sweep, 0…1 — null when there is nothing honest to sweep.
  final double? frac;

  /// The arc is calibration progress, not the metric, and is drawn muted.
  final bool calibrating;

  /// Nights banked / nights needed, set only while [calibrating] — the
  /// dashed ring divides itself into exactly [need] beads and fills [have]
  /// of them, rather than approximating that count from [frac].
  final int? have, need;

  /// The absence's reason, as the pipeline gave it. Non-null only when the
  /// ring is [absent].
  final String? why;

  /// The sleep ring's arcs when a night is scored: stage arcs, or one solid
  /// arc. Null for every other ring and state.
  final List<SleepArc>? arcs;

  /// An ESTIMATE of tonight's sleep, not a reading: drawn in the muted ink,
  /// never a stage colour, and never solid.
  final bool estimated;

  const _RingState(
    this.kind,
    this.label,
    this.icon,
    this.color, {
    required this.value,
    this.sub = '',
    this.alts = const [],
    this.frac,
    this.calibrating = false,
    this.have,
    this.need,
    this.why,
    this.provisional = false,
    this.arcs,
    this.estimated = false,
    this.olderVersion,
    this.olderReason,
    this.dash = false,
  });

  /// An absence drawn as a dash in the value slot (the reason is in the help
  /// strip), so the slot is the same height as a number's.
  final bool dash;

  /// A number that may still move (the night is still draining), drawn grey.
  final bool provisional;

  /// A number the ring is actually reporting. Calibration is progress, not a
  /// reading, so it is not one.
  bool get measured => why == null && !calibrating && !estimated;

  /// Whether the value is a number to set in numerals (a reading or an
  /// estimate) rather than an absence in words.
  bool get showsNumber => why == null && !calibrating;

  Color arc(P p) =>
      calibrating || estimated || provisional ? p.ink3 : p.on(color);
  Color ink(P p) => measured && !provisional ? p.on(color) : p.ink3;

  String get spoken => [
        label,
        showsNumber ? value : value.toLowerCase(),
        if (sub.isNotEmpty) sub,
        ?why,
      ].join('. ');
}

_RingState _ringOf(
    HomeRingKind k, HomeData d, AppLocalizations? l, DateTime now) {
  switch (k) {
    case HomeRingKind.recovery:
      final v = d.readiness.value;
      final band = readinessBand(v, l);
      if (d.recoveryState == 'night_in_progress') {
        return _RingState(k, l?.homeRingRecovery ?? 'Recovery',
            LucideIcons.batteryCharging, C.green,
            value: l?.homeRecoverySleeping ?? 'Sleeping…',
            why: l?.homeRecoveryAfterWake ??
                'Recovery is scored after you wake.');
      }
      if (d.recoveryState == 'provisional' && v != null) {
        return _RingState(k, l?.homeRingRecovery ?? 'Recovery',
            LucideIcons.batteryCharging, band.color,
            value: '${v.round()}',
            sub: l?.homeRecoveryFinishingUp ?? 'Finishing up',
            // Recovery is a bounded 0-100 score: out of range is bad data,
            // not overflow, so it never spirals.
            frac: (v / 100).clamp(0.0, 1.0),
            provisional: true);
      }
      return v == null
          ? _gap(k, l?.homeRingRecovery ?? 'Recovery', LucideIcons.batteryCharging,
              C.green, d.readiness, l?.homeReadinessNotScored ?? 'Not scored', l,
              // The same shortfall sentence the Readiness detail screen's
              // banner shows, off the SAME stored diagnostic — _gap's own
              // whyFromNote(m.note) doesn't recognise the need_inputs:
              // convention this composite uses (only need_baseline:), so
              // without this it fell through to the generic "nothing
              // recorded says why" even with a real, known reason on hand.
              // metricName: 'recovery' — this ring is labelled "Recovery",
              // not "Readiness", and the sentence should say what the ring
              // itself says. The second translator covers the z-cap absence
              // shape readinessInputShortfallNote alone doesn't (PR #510).
              fallbackWhy: readinessInputShortfallNote(d.absentDiag,
                      metricName: 'recovery') ??
                  readinessUnstableBaselineNote(
                      d.absentDiag?['note']?.toString(),
                      metricName: 'recovery') ??
                  '')
          : _RingState(k, l?.homeRingRecovery ?? 'Recovery',
              LucideIcons.batteryCharging, band.color,
              value: '${v.round()}', sub: band.label, frac: (v / 100).clamp(0.0, 1.0));
    case HomeRingKind.strain:
      final v = d.strain.value;
      // 0–21 is the scale's own ceiling, not a target invented here.
      return v == null
          ? _gap(k, l?.homeRingStrain ?? MetricLabels.strain, LucideIcons.zap, C.purple,
              d.strain, l?.homeRingNoStrain ?? 'No strain', l, unit: 'days')
          : _RingState(k, l?.homeRingStrain ?? MetricLabels.strain, LucideIcons.zap, C.purple,
              value: v.toStringAsFixed(1), sub: l?.homeStrainOf21 ?? 'of 21',
              // Bounded 0-21 scale: out of range is bad data, not overflow.
              frac: (v / 21).clamp(0.0, 1.0),
              olderVersion: d.strain.fromOlderVersion, olderReason: d.strain.olderVersionReason);
    case HomeRingKind.sleep:
      final label = l?.homeRingSleep ?? 'Sleep';
      // A baseline still filling is progress, not an absence, and is drawn
      // exactly as before: dashed, ahead of any estimate.
      if (d.sleepMin.value == null &&
          baselineCountsFromNote(d.sleepMin.note) != null) {
        return _gap(k, label, LucideIcons.moon, C.blue, d.sleepMin,
            l?.homeRingNoSleep ?? 'No sleep', l);
      }
      final m = sleepRingModel(
        now: now,
        durationMin: d.sleepMin.value,
        stages: d.sleepStages,
        needMin: d.sleepNeedMin.value,
        coachBedtimeMinOfDay: d.bedtime.value,
        schedule: d.sleepSchedule,
        nextAlarm: d.nextAlarm,
        learnedOnsetMin: d.learnedOnsetMin,
        learnedWakeMin: d.learnedWakeMin,
        cycleLenMin: d.cycleLenMin,
      );
      switch (m.phase) {
        case SleepRingPhase.slept:
          final target = hm(m.targetMin);
          return _RingState(k, label, LucideIcons.moon, C.blue,
              value: hm(m.asleepMin),
              // The target is the learned need, or the 8 h default — and the
              // default says so. It is never passed off as this user's need.
              sub: m.targetIsDefault
                  ? (l?.homeSleepPctOfDefault(m.pct!, target) ??
                      '${m.pct}% of $target (default)')
                  : (l?.homeSleepPctOf(m.pct!, target) ??
                      '${m.pct}% of $target'),
              alts: m.targetIsDefault
                  ? [
                      l?.homeSleepPctDefaultCompact(
                              m.pct!, _compactHm(m.targetMin, l)) ??
                          '${m.pct}% of ${_compactHm(m.targetMin, l)} · default target',
                      l?.homeSleepPctDefaultTight(
                              m.pct!, _compactHm(m.targetMin, l)) ??
                          '${m.pct}% of default ${_compactHm(m.targetMin, l)}',
                    ]
                  : [
                      l?.homeSleepPctCompact(
                              m.pct!, _compactHm(m.targetMin, l)) ??
                          '${m.pct}% of ${_compactHm(m.targetMin, l)}',
                    ],
              frac: m.sweep,
              arcs: m.arcs);
        case SleepRingPhase.estimate:
          final est = hm(m.estimateMin);
          return _RingState(k, label, LucideIcons.moon, C.blue,
              value: est,
              // The ring is filled against the target, so the default says
              // so here too — it is never passed off as this user's need.
              sub: m.targetIsDefault
                  ? (l?.homeSleepOnTrackDefault(
                          m.cycles!, est, hm(m.targetMin)) ??
                      'on track for ${m.cycles} '
                          '${m.cycles == 1 ? 'cycle' : 'cycles'}, $est'
                          ' · target ${hm(m.targetMin)} (default)')
                  : (l?.homeSleepOnTrack(m.cycles!, est) ??
                      'on track for ${m.cycles} '
                          '${m.cycles == 1 ? 'cycle' : 'cycles'}, $est'),
              // "~" marks an estimate in every compact form.
              alts: m.targetIsDefault
                  ? [
                      l?.homeSleepEstimateDefaultCompact(
                              m.cycles!, _compactHm(m.estimateMin, l)) ??
                          '~${m.cycles} cycles · ${_compactHm(m.estimateMin, l)} · default target',
                      l?.homeSleepEstimateDefaultTight(
                              m.cycles!, _compactHm(m.estimateMin, l)) ??
                          '~${m.cycles} cycles · ${_compactHm(m.estimateMin, l)} · default goal',
                      // When even the tight wording needs more than three
                      // lines: drop the duration, never the qualifiers.
                      l?.homeSleepEstimateDefaultMin(m.cycles!) ??
                          '~${m.cycles} cycles · default goal',
                    ]
                  : [
                      l?.homeSleepEstimateCompact(
                              m.cycles!, _compactHm(m.estimateMin, l)) ??
                          '~${m.cycles} cycles · ${_compactHm(m.estimateMin, l)}',
                      l?.homeSleepEstimateBare(m.cycles!) ?? '~${m.cycles} cycles',
                    ],
              frac: m.sweep,
              estimated: true);
        case SleepRingPhase.none:
          return _gap(k, label, LucideIcons.moon, C.blue, d.sleepMin,
              l?.homeSleepNoEstimate ?? 'No estimate', l,
              fallbackWhy: l?.homeSleepNoEstimateWhy ??
                  'No sleep scored yet, and no alarm or typical wake time '
                      'to estimate from.');
      }
  }
}

/// The absent half: calibrating when the note says the gate is a baseline
/// still filling, otherwise the absence and its reason.
_RingState _gap(HomeRingKind k, String label, IconData icon, Color color,
    Metric m, String word, AppLocalizations? l,
    {String unit = 'nights', String fallbackWhy = ''}) {
  final counts = baselineCountsFromNote(m.note);
  if (counts != null) {
    return _RingState(k, label, icon, color,
        value: l?.homeCalibrating ?? 'Learning your usual',
        sub: unit == 'days'
            ? (l?.homeCalibratingDays(counts.have, counts.need) ??
                '${counts.have} of ${counts.need} days')
            : (l?.homeCalibratingNights(counts.have, counts.need) ??
                '${counts.have} of ${counts.need} nights'),
        frac: (counts.have / counts.need).clamp(0.0, 1.0),
        calibrating: true,
        have: counts.have,
        need: counts.need);
  }
  return _RingState(k, label, icon, color,
      value: word,
      dash: true,
      // THE PIPELINE'S REASON FIRST. A sentence written here by someone who
      // never saw the day is the fallback, and where there is neither the ring
      // says it does not know rather than guessing a cause.
      why: whyFromNote(m.note, unit: unit) ??
          (fallbackWhy.isNotEmpty
              ? fallbackWhy
              : (l?.homeGapNoReason ?? 'No reading.')));
}

/// The scored night split by stage, in the hypnogram's own colours — or null
/// when the night is one solid arc (stage totals absent) or not a night.
List<RingArc>? _stageArcs(_RingState r, P p) {
  final arcs = r.arcs;
  if (arcs == null || arcs.every((a) => a.kind == SleepArcKind.solid)) {
    return null;
  }
  final cols = Hypnogram.cols(p);
  return [
    for (final a in arcs)
      RingArc(
          cols[switch (a.kind) {
            SleepArcKind.deep => SleepStage.deep,
            SleepArcKind.rem => SleepStage.rem,
            SleepArcKind.light => SleepStage.light,
            _ => SleepStage.awake,
          }]!,
          a.fraction),
  ];
}

/// The dial itself. An empty [frac] draws the track and nothing else — which is
/// exactly what [Ring] already does with a zero sweep.
class _Dial extends StatelessWidget {
  final _RingState r;
  final double stroke, icon;

  const _Dial(this.r, {required this.stroke, required this.icon});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Stack(alignment: Alignment.center, children: [
      CustomPaint(
        size: Size.infinite,
        // Calibrating draws as discrete dashes filling in night by night;
        // a finished (or absent-but-not-calibrating) ring draws the
        // continuous arc, solid only once it is an actual measurement.
        painter: r.calibrating
            // One dash per night the baseline needs, not a fixed count —
            // "6 of 14" draws as 14 divisions with 6 filled.
            ? DashedRing(r.frac ?? 0, r.arc(p), p.track,
                stroke: stroke, segments: r.need ?? 24)
            : _stageArcs(r, p) != null
            ? StageRing(_stageArcs(r, p)!, p.track,
                stroke: stroke, t: animate(c, 1), background: p.card)
            : Ring(r.frac ?? 0, r.arc(p), p.track,
                stroke: stroke,
                t: animate(c, 1),
                solid: r.measured,
                background: p.card),
      ),
      Icon(r.icon, size: icon, color: r.ink(p)),
    ]);
  }
}

/// The default: three across, the number under the ring rather than inside it.
/// Inside is where a duration overflows its own circle at the first
/// accessibility step, and nothing about "7h 45m" gets shorter.
/// What a [RingTrio]'s help strip says, and where it goes when tapped.
class RingHelp {
  final String text;
  final VoidCallback? onTap;

  /// The status of something still being read or calculated: drawn with a
  /// small spinner ([InlineLoading], compact) instead of the info icon.
  final bool busy;
  const RingHelp(this.text, {this.onTap}) : busy = false;
  const RingHelp.busy(this.text)
      : onTap = null,
        busy = true;
}

/// The fixed-height strip under the rings. Its height is the tallest of the
/// texts it may ever hold ([reserve]) at the current width and text scale, and
/// at least two lines, so swapping its text never moves what is under it.
class _HelpStrip extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  final bool chevron;
  final bool busy;
  final List<String> reserve;
  const _HelpStrip(
      {required this.text,
      required this.onTap,
      required this.busy,
      required this.chevron,
      required this.reserve});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final style = F.cap.copyWith(color: p.ink2);
    final scaler = MediaQuery.textScalerOf(c);
    final dir = Directionality.of(c);
    return LayoutBuilder(builder: (c, box) {
      // Icon (15) and its gap, and the chevron slot, are always reserved so
      // the text width is the same with or without the chevron.
      final w = box.maxWidth - 15 - S.x2 - S.x2 - 15;
      double h(String t) {
        final tp = TextPainter(
            text: TextSpan(text: t, style: style),
            textDirection: dir,
            textScaler: scaler)
          ..layout(maxWidth: w);
        final r = tp.height;
        tp.dispose();
        return r;
      }

      final two = h('A\nA');
      final reserved = [two, for (final t in reserve) h(t)].reduce(math.max);
      return Pressable(
        onTap: onTap,
        semanticLabel: text.isEmpty ? null : text,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: reserved),
          child: busy
              ? InlineLoading(status: text, compact: true)
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // No icon for an empty strip: the box stays, nothing is drawn.
                  SizedBox(
                      width: 15,
                      child: text.isEmpty
                          ? null
                          : Icon(LucideIcons.info, size: 15, color: p.ink3)),
                  const SizedBox(width: S.x2),
                  Expanded(child: Text(text, style: style)),
                  const SizedBox(width: S.x2),
                  SizedBox(
                      width: 15,
                      child: chevron
                          ? Icon(LucideIcons.chevronRight,
                              size: 15, color: p.ink3)
                          : null),
                ]),
        ),
      );
    });
  }
}

class _RingColumn extends StatelessWidget {
  final _RingState r;
  final VoidCallback? onTap;

  const _RingColumn(this.r, {this.onTap});

  @override
  Widget build(BuildContext c) => Pressable(
        onTap: onTap,
        semanticLabel: r.spoken,
        child: Column(children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: AspectRatio(
              aspectRatio: 1,
              child: _Dial(r, stroke: 7, icon: 20),
            ),
          ),
          const SizedBox(height: S.x3),
          _RingText(r, align: TextAlign.center),
        ]),
      );
}

/// The accessibility layout: ring left, type in the width it needs.
class _RingRow extends StatelessWidget {
  final _RingState r;
  final VoidCallback? onTap;

  const _RingRow(this.r, {this.onTap});

  @override
  Widget build(BuildContext c) => Pressable(
        onTap: onTap,
        semanticLabel: r.spoken,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x2),
          child: Row(children: [
            SizedBox(
              width: 56,
              height: 56,
              child: _Dial(r, stroke: 5, icon: 15),
            ),
            const SizedBox(width: S.x3),
            Expanded(child: _RingText(r, align: TextAlign.start)),
          ]),
        ),
      );
}

/// Three lines of caption text at the current text scale (prototype C: the
/// columns reserve three, so the tightest wording has room in the worst case).
double _twoLines(BuildContext c) => _measuredHeight(c, F.cap, 'x\nx\nx');

/// Height of [text] in [base] under the ambient default style, scale and bold
/// setting. Measured, not multiplied: the paragraph rounds each line.
double _measuredHeight(BuildContext c, TextStyle base, String text,
    {double maxWidth = double.infinity}) {
  var st = DefaultTextStyle.of(c).style.merge(base);
  if (MediaQuery.boldTextOf(c)) {
    st = st.merge(const TextStyle(fontWeight: FontWeight.bold));
  }
  final tp = TextPainter(
    text: TextSpan(text: text, style: st),
    textDirection: Directionality.of(c),
    textScaler: MediaQuery.textScalerOf(c),
    locale: Localizations.maybeLocaleOf(c),
  )..layout(maxWidth: maxWidth);
  final h = tp.height;
  tp.dispose();
  return h;
}

/// The caption's render settings, resolved once from the context so the text
/// that is MEASURED and the Text that is BUILT can not disagree: the same
/// DefaultTextStyle merge, bold-text setting, locale, scaler and width basis.
class _CaptionSpec {
  final TextStyle style;
  final TextAlign align;
  final int? maxLines;
  final TextScaler scaler;
  final Locale? locale;
  final ui.TextDirection dir;
  final TextWidthBasis basis;
  final TextHeightBehavior? heightBehavior;

  const _CaptionSpec._(this.style, this.align, this.maxLines, this.scaler,
      this.locale, this.dir, this.basis, this.heightBehavior);

  factory _CaptionSpec.of(BuildContext c, Color color, TextAlign align,
      int? maxLines) {
    final d = DefaultTextStyle.of(c);
    var st = d.style.merge(F.cap.copyWith(color: color));
    if (MediaQuery.boldTextOf(c)) {
      st = st.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    return _CaptionSpec._(
        st,
        align,
        maxLines,
        MediaQuery.textScalerOf(c),
        Localizations.maybeLocaleOf(c),
        Directionality.of(c),
        d.textWidthBasis,
        d.textHeightBehavior);
  }

  bool fits(String text, double width) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: align,
      textDirection: dir,
      textScaler: scaler,
      locale: locale,
      maxLines: maxLines,
      textWidthBasis: basis,
      textHeightBehavior: heightBehavior,
    )..layout(maxWidth: width);
    final ok = !tp.didExceedMaxLines;
    tp.dispose();
    return ok;
  }

  double height(String text, double width) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: align,
      textDirection: dir,
      textScaler: scaler,
      locale: locale,
      textWidthBasis: basis,
      textHeightBehavior: heightBehavior,
    )..layout(maxWidth: width);
    final h = tp.height;
    tp.dispose();
    return h;
  }

  Text build(String text, {bool bounded = true}) => Text(text,
      style: style,
      textAlign: align,
      maxLines: bounded ? maxLines : null,
      overflow: TextOverflow.clip);
}

/// The numeral slot's reserved height in a column [width] wide: the longest
/// realistic sleep numeral ("10h 30m" in the locale's own format) laid out at
/// that width with the numeral's real style. A fixed sample, so it is the same
/// empty and loaded.
double _numeralReserve(BuildContext c, double width) => _measuredHeight(
    c,
    F.n24,
    presentationText(
        AppLocalizations.of(c), _compactHm(630, AppLocalizations.of(c))),
    maxWidth: width);

/// The sleep caption's reserved height in a column [width] wide: three lines,
/// or more where the shortest wordings (the ones shown whole when nothing fits
/// three lines) need it. Fixed localized samples, never today's data.
double _sleepCaptionReserve(BuildContext c, double width) {
  final l = AppLocalizations.of(c);
  final dur = _compactHm(630, l);
  final samples = [
    l?.homeSleepEstimateDefaultMin(10) ?? '~10 cycles · default goal',
    l?.homeSleepEstimateBare(10) ?? '~10 cycles',
    l?.homeSleepPctDefaultTight(100, dur) ?? '100% of default $dur',
    l?.homeSleepPctCompact(100, dur) ?? '100% of $dur',
  ];
  var h = _twoLines(c);
  for (final t in samples) {
    h = math.max(
        h, _measuredHeight(c, F.cap, presentationText(l, t), maxWidth: width));
  }
  return h;
}

class _RingText extends StatelessWidget {
  final _RingState r;
  final TextAlign align;

  const _RingText(this.r, {required this.align});

  @override
  Widget build(BuildContext c) => LayoutBuilder(
      builder: (c, box) => _build(c, box.maxWidth));

  Widget _build(BuildContext c, double colWidth) {
    final p = P.of(c);
    final cross = align == TextAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    return Column(crossAxisAlignment: cross, children: [
      Text(r.label.toUpperCase(),
          style: F.over.copyWith(color: p.ink3), textAlign: align),
        const SizedBox(height: S.x1),
        // An absence is a dash in the numeral slot (never a zero, never a
        // number): the slot is the same height as a reading's, so the rings
        // card is the same card first launch and loaded, and the reason is in
        // the help strip under the rings. Words that are not an absence
        // ("Sleeping…", "Learning your usual") keep the sentence weight.
        ConstrainedBox(
          // The sleep numeral ("7h 22m") can wrap in a narrow column at larger
          // text; reserve what the longest sample needs, so the slot never
          // depends on the day's data.
          constraints: BoxConstraints(
              // Both layouts, each at its own text width (the column's, or the
              // row's beside the ring).
              minHeight:
                  r.kind == HomeRingKind.sleep ? _numeralReserve(c, colWidth) : 0),
          child: Wrap(alignment: align == TextAlign.center ? WrapAlignment.center : WrapAlignment.start, crossAxisAlignment: WrapCrossAlignment.center, children: [Text(
          r.dash ? '—' : presentationText(AppLocalizations.of(c), r.value),
          style: r.dash
              ? F.n24.copyWith(color: p.ink3)
              : r.showsNumber
                  ? F.n24.copyWith(color: r.provisional ? p.ink3 : p.ink)
                  : F.body.copyWith(color: p.ink2),
          textAlign: align,
        ), OlderVersionMark(id: 'strain', version: r.olderVersion, reason: r.olderReason, speak: false)])),
        // The caption line is reserved (two lines at the column's width), so
        // it does not move the card when a reading lands.
        const SizedBox(height: 2),
        LayoutBuilder(builder: (c, outer) {
          var reserve = _twoLines(c);
          if (align == TextAlign.center && r.kind == HomeRingKind.sleep) {
            reserve = _sleepCaptionReserve(c, outer.maxWidth);
          }
          if (align != TextAlign.center && r.kind == HomeRingKind.sleep) {
            final l = AppLocalizations.of(c);
            final dur = _compactHm(630, l);
            final sample = presentationText(
                l,
                l?.homeSleepOnTrackDefault(10, dur, dur) ??
                    'on track for 10 cycles, $dur · target $dur (default)');
            final h = _CaptionSpec.of(c, P.of(c).ink3, align, null)
                .height(sample, outer.maxWidth);
            if (h > reserve) reserve = h;
          }
          return ConstrainedBox(
          // Both layouts reserve their caption height, so an empty card and a
          // loaded one are the same height. Columns: two lines. Rows (no line
          // cap): the sleep ring reserves its longest caption (a fixed sample,
          // not today's data) at the row's own width.
          constraints: BoxConstraints(minHeight: reserve),
          child: r.sub.isEmpty
              ? null
              : LayoutBuilder(builder: (c, box) {
                  final l = AppLocalizations.of(c);
                  // The two-line bound is the centred column's; the big-text
                  // row has the width it needs and wraps without a limit.
                  final spec = _CaptionSpec.of(c, p.ink3, align,
                      align == TextAlign.center ? 3 : null);
                  final forms = [
                    presentationText(l, r.sub),
                    for (final a in r.alts) presentationText(l, a),
                  ];
                  // Measure every wording, widest first. The columns are only
                  // used when the worst-case tight wording fits them
                  // (the tightest wording is expected to fit three lines).
                  for (final f in forms) {
                    if (spec.maxLines == null || spec.fits(f, box.maxWidth)) {
                      return spec.build(f);
                    }
                  }
                  // Past even the tightest wording (320 pt at 1.3x in es, de,
                  // ru): show it whole on extra lines — never cut a qualifier.
                  return spec.build(forms.last, bounded: false);
                }),
        );
        }),
      ],
    );
  }
}

// ═══════════════════ the screen ═══════════════════

/// The night's stage totals off a `getDaySleepV2` map, or null when it carries
/// none of them. Individual stages stay null when the pipeline had no figure —
/// the ring splits only when Deep, REM and Light are all there.
SleepStageMin? sleepStagesOf(Map<String, dynamic> night) {
  int? m(String k) => (night[k] as num?)?.round();
  final s = SleepStageMin(
      deep: m('deep_min'),
      rem: m('rem_min'),
      light: m('light_min'),
      awake: m('awake_min'));
  return s.deep == null && s.rem == null && s.light == null && s.awake == null
      ? null
      : s;
}

/// The learned sleep need and the coach bedtime out of `getInsights()`, shared
/// by every loader so a dated view cannot forget them (it did, and drew an
/// empty bar under a night that had a need).
({Metric need, Metric bedtime}) sleepCoachOf(Map<String, dynamic> insights) {
  final coach = insights['sleep_coach'];
  final needEnv = coach is Map ? coach['need'] : null;
  final bedEnv = coach is Map ? coach['bedtime'] : null;
  final needSec = envValue(needEnv)?['need_sec'] as num?;
  return (
    // sleep_coach.need is the COMPUTED need. `sleep.need_min` is a hardcoded
    // 480 and must never be shown as "your sleep need".
    need: envMetric(needEnv, needSec == null ? null : needSec / 60,
        unit: 'min'),
    bedtime: envMetric(
        bedEnv, envValue(bedEnv)?['bedtime_min_of_day'] as num?),
  );
}

class HomeData {
  final String? name;
  final String? dayId;
  final Metric readiness;
  final List<Map<String, dynamic>> drivers;
  final Metric sleepMin, rhr, steps, calories, caloriesTotal;

  /// The day's 0–21 strain, read from the same `getToday` bundle the Workout
  /// tab reads. Nothing on this screen computes it.
  final Metric strain;

  final int stepGoal;
  final Metric sleepNeedMin;
  final Metric bedtime;
  final Map<String, dynamic>? strainTarget;

  /// The scored night's stage totals (`getDaySleepV2`): the sleep ring splits
  /// its arc by these. Null when none were loaded; fields inside are null when
  /// the pipeline had no figure.
  final SleepStageMin? sleepStages;

  /// Settings > expected sleep schedule, when saved.
  final ExpectedSleepSchedule? sleepSchedule;

  /// The next armed alarm (a future instant), when one is set.
  final DateTime? nextAlarm;

  /// Median local clock minute-of-day of the user's recent onsets / wakes.
  final int? learnedOnsetMin, learnedWakeMin;

  /// The user's own sleep-cycle length, minutes. Null until a persisted
  /// per-user value exists, which means the 90 min assumption.
  // TODO(sleep-ring): populate from a persisted per-user cycle length when one exists.
  final int? cycleLenMin;

  /// Non-null when the cross-day rollup was withheld rather than absent — see
  /// [staleInsightsCard]. Drivers, sleep need and bedtime are all empty in that
  /// case, and the screen owes the user the reason.
  final Map<String, dynamic>? insightsStale;

  /// When the rows behind the rings were computed, and which day each belongs
  /// to — what "As of" says while a newer result is being calculated. The
  /// overnight pair (recovery, sleep) is null whenever the night on file is not
  /// today's ([heldOverNight]): those numbers are refused above and a time
  /// must not bring them back. Null with no row at all; never "now".
  final DateTime? overnightAt, activityAt;
  final String? overnightDay, activityDay;

  /// The last night that scored, when that is NOT today's — so the screen can
  /// say WHERE THE DATA STOPS on a day it has nothing of its own.
  ///
  /// It is no longer where readiness, sleep or resting heart rate come from:
  /// [overnightMetric] refuses those at the loader, and this is what is left
  /// of the held-over night once its numbers are gone. Its one job on this
  /// screen is the sentence in the nothing-today card — "the last night this
  /// app scored was Saturday" is a fact about coverage, not a reading dressed
  /// as one.
  final String? heldOverNight;

  /// The illness watch's own state — 'green' / 'amber' / 'red', or null before
  /// it has the 7 nights of baseline it needs. Home renders it only when it is
  /// amber or red; see the exception noted at the top of this file.
  final String? illnessState;

  /// The night the watch is ABOUT, and how far that night sat from this user's
  /// own baseline. `z` belongs to the latest night alone and can be negative
  /// while the run is still up, so the copy says which direction rather than
  /// implying the run reversed.
  final String? illnessDay;
  final double? illnessZ;

  /// The `readiness_absent_diag` block off today's bundle — null unless
  /// [readiness] is absent. Read through [ReadinessData.readAbsentDiag], the same
  /// repository read readiness_detail.dart uses: this card's "not scored"
  /// explanation has to be built from the SAME diagnostic that screen's does,
  /// or the two can disagree.
  final Map<String, dynamic>? absentDiag;

  /// `todayHeadlineOf`'s recovery_state for today (null for a past day):
  /// night_in_progress → no number, provisional → greyed number, final.
  final String? recoveryState;

  /// `{from, to, at}` when today's final recovery changed after it was shown.
  final Map<String, dynamic>? readinessUpdate;

  /// The data was read before the freshness refresh ran (see
  /// [LocalRepository.getTodayStored]); today's figures are absent, not yet
  /// worked out. The screen asks for the refresh after this frame.
  final bool refreshPending;

  /// Detected activities waiting for review, read WITH the day so the
  /// "Detected activities" card is in its landed shape on the first paint
  /// rather than popping in above the rings a moment later. Null when the
  /// read failed or was not made; the card then reads the count itself.
  final int? pendingActivities;

  /// The count read with the day threw. The card shows its failed shape from
  /// the first paint instead of reading again on its own: that second read
  /// fails the same way a frame later and lands the card mid-screen, moving
  /// everything under it.
  final bool pendingActivitiesFailed;

  /// The active wearable's cells for this day, read with the day so its card
  /// starts in its final place instead of landing above the rings after the
  /// first paint. Null: no active wearable, no cells, or the read failed
  /// (nothing is drawn, as before).
  final WearableDay? wearable;

  const HomeData({
    this.name,
    this.dayId,
    this.readiness = Metric.empty,
    this.drivers = const [],
    this.sleepMin = Metric.empty,
    this.rhr = Metric.empty,
    this.steps = Metric.empty,
    this.calories = Metric.empty,
    this.caloriesTotal = Metric.empty,
    this.strain = Metric.empty,
    this.stepGoal = kDefaultStepGoal,
    this.sleepNeedMin = Metric.empty,
    this.bedtime = Metric.empty,
    this.strainTarget,
    this.sleepStages,
    this.sleepSchedule,
    this.nextAlarm,
    this.learnedOnsetMin,
    this.learnedWakeMin,
    this.cycleLenMin,
    this.heldOverNight,
    this.illnessState,
    this.illnessDay,
    this.illnessZ,
    this.insightsStale,
    this.absentDiag,
    this.recoveryState,
    this.readinessUpdate,
    this.overnightAt,
    this.activityAt,
    this.overnightDay,
    this.activityDay,
    this.refreshPending = false,
    this.pendingActivities,
    this.pendingActivitiesFailed = false,
    this.wearable,
  });

  static HomeData fromPublishedOverview(String day, Map<String, dynamic> overview) =>
      HomeData(dayId: day, readiness: metricOf(overview['readiness']),
          rhr: metricOf(overview['resting_hr']));

  /// The overnight-owned figures of a `getToday` payload, through the ONE
  /// mapping both a normal load and an import-time publish use: a night that
  /// is not today's is refused ([overnightMetric]) and a provisional recovery
  /// shows its own number ([todayHeadlineOf]).
  static ({
    Metric sleepMin,
    Metric readiness,
    Metric rhr,
    String? recoveryState,
    Map<String, dynamic>? update,
  }) _overnightOf(Map<String, dynamic> today, AppLocalizations? l) {
    final daily = today['daily'];
    final sleep = today['sleep'];
    Object? d(String k) => daily is Map ? daily[k] : null;
    final head = todayHeadlineOf(today);
    final state = head['recovery_state'] as String?;
    return (
      sleepMin: overnightMetric(today, sleep is Map ? sleep['duration_min'] : null, l),
      readiness: state == 'provisional'
          ? metricOf(d('readiness_provisional'))
          : overnightMetric(today, d('readiness'), l),
      rhr: overnightMetric(today, d('resting_hr'), l),
      recoveryState: state,
      update: (head['recovery_update'] as Map?)?.cast<String, dynamic>(),
    );
  }

  /// Today, from the model the engine published during an import: the same
  /// mapping as [load] for everything the payload carries.
  static HomeData fromPublishedToday(Map<String, dynamic> today,
      [AppLocalizations? l]) {
    final daily = today['daily'];
    Object? d(String k) => daily is Map ? daily[k] : null;
    final o = _overnightOf(today, l);
    final status = today['status'] as Map?;
    return HomeData(
      dayId: status?['today_day']?.toString(),
      heldOverNight: heldOverNightOf(today),
      readiness: o.readiness,
      recoveryState: o.recoveryState,
      readinessUpdate: o.update,
      rhr: o.rhr,
      sleepMin: o.sleepMin,
      strain: metricOf(d('strain')),
      steps: metricOf(d('steps')),
      calories: metricOf(d('calories')),
      caloriesTotal: metricOf(d('calories_total')),
      stepGoal: (today['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal,
    );
  }

  /// The three illness fields, replaced together. Test-facing sugar, and they
  /// travel as a set on purpose — they are read as one envelope, and setting
  /// one without the others describes a state the pipeline cannot produce.
  HomeData copyOrIllness(String? state, String? day, double? z) => _copy(
        illnessState: state,
        illnessDay: day,
        illnessZ: z,
        nextAlarm: nextAlarm,
      );

  /// The same data with the armed alarm and saved schedule replaced — both
  /// live on AppState, not in the repository, so the screen lays them over
  /// what loaded.
  HomeData withSleepInputs(
          {DateTime? alarm, ExpectedSleepSchedule? schedule}) =>
      _copy(
        illnessState: illnessState,
        illnessDay: illnessDay,
        illnessZ: illnessZ,
        nextAlarm: alarm,
        sleepSchedule: schedule,
      );

  HomeData _copy({
    required String? illnessState,
    required String? illnessDay,
    required double? illnessZ,
    required DateTime? nextAlarm,
    ExpectedSleepSchedule? sleepSchedule,
  }) =>
      HomeData(
        name: name,
        dayId: dayId,
        readiness: readiness,
        drivers: drivers,
        sleepMin: sleepMin,
        rhr: rhr,
        steps: steps,
        calories: calories,
        caloriesTotal: caloriesTotal,
        strain: strain,
        stepGoal: stepGoal,
        sleepNeedMin: sleepNeedMin,
        bedtime: bedtime,
        strainTarget: strainTarget,
        sleepStages: sleepStages,
        sleepSchedule: sleepSchedule ?? this.sleepSchedule,
        nextAlarm: nextAlarm,
        learnedOnsetMin: learnedOnsetMin,
        learnedWakeMin: learnedWakeMin,
        cycleLenMin: cycleLenMin,
        heldOverNight: heldOverNight,
        illnessState: illnessState,
        illnessDay: illnessDay,
        illnessZ: illnessZ,
        insightsStale: insightsStale,
        absentDiag: absentDiag,
        recoveryState: recoveryState,
        readinessUpdate: readinessUpdate,
        overnightAt: overnightAt,
        activityAt: activityAt,
        overnightDay: overnightDay,
        activityDay: activityDay,
        refreshPending: refreshPending,
        pendingActivities: pendingActivities,
        pendingActivitiesFailed: pendingActivitiesFailed,
        wearable: wearable,
      );

  /// A day OTHER than today, for the Home day switcher.
  ///
  /// Deliberately thin next to [load]: everything [load] does beyond the six
  /// headline numbers below (frozen-morning-headline pin, the illness watch,
  /// sleep coach need/bedtime, readiness drivers, the stale-rollup notice) is
  /// about the ambiguity of an in-progress "today" — a past day already
  /// settled, so there is nothing there to resolve. Reuses the same
  /// date-parameterized getters the strain/sleep detail screens already read
  /// ([LocalRepository.getDayStrain]/[getDaySleepV2]) plus the one figure
  /// neither carries ([getDayOverview]'s readiness/resting_hr).
  static Future<HomeData> loadForDay(LocalRepository repo, String date,
      [AppLocalizations? l]) async {
    // Started first, awaited last: the first paint waits for the slowest read,
    // not the sum. `_wearableOf` swallows a failed read (null), so leaving it
    // un-awaited on an early throw is safe.
    final wearable = _wearableOf(repo, date);
    final profile = await repo.getProfile();
    final overview = await repo.getDayOverview(date);
    final strain = await repo.getDayStrain(date);
    final sleep = await repo.getDaySleepV2(date);
    final readiness = metricOf(overview['readiness']);
    // Same lookup [load] does for today, for the same reason: the ring's
    // shortfall explanation needs the stored diagnostic, and a day the
    // switcher stepped onto can be absent too, not just today (PR #510).
    final absentDiag = readiness.value != null
        ? null
        : await ReadinessData.readAbsentDiag(repo, date);
    // The learned need, like [load]. A failed read leaves it absent — the ring
    // then shows the labelled default, never an invented need.
    ({Metric need, Metric bedtime})? coach;
    try {
      coach = sleepCoachOf(await repo.getInsights());
    } catch (_) {
      coach = null;
    }
    final pending = await _pendingActivitiesOf(repo);
    return HomeData(
      name: profile['name']?.toString(),
      dayId: date,
      readiness: readiness,
      absentDiag: absentDiag,
      rhr: metricOf(overview['resting_hr']),
      strain: _dayMetric(strain, 'strain'),
      steps: _dayMetric(strain, 'steps'),
      calories: _dayMetric(strain, 'calories'),
      caloriesTotal: _dayMetric(strain, 'calories_total'),
      sleepMin: metricOf(sleep['duration_min']),
      sleepNeedMin: coach?.need ?? Metric.empty,
      sleepStages: sleepStagesOf(sleep),
      stepGoal: (profile['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal,
      pendingActivities: pending.count,
      pendingActivitiesFailed: pending.failed,
      wearable: await wearable,
    );
  }

  /// The active wearable's day for [wearable]; null when the read throws.
  static Future<WearableDay?> _wearableOf(
      LocalRepository repo, String date) async {
    try {
      return await repo.wearableDay(date);
    } catch (_) {
      return null;
    }
  }

  /// The review count for [pendingActivities], or [pendingActivitiesFailed]
  /// when the read throws.
  static Future<({int? count, bool failed})> _pendingActivitiesOf(
      LocalRepository repo) async {
    try {
      return (count: await repo.pendingActivityCount(), failed: false);
    } catch (_) {
      return (count: null, failed: true);
    }
  }

  /// [stored]: read what is persisted and do not wait for the freshness
  /// refresh (first paint); [refreshPending] then says whether one is owed.
  static Future<HomeData> load(LocalRepository repo, [AppLocalizations? l,
      bool stored = false]) async {
    // Started first, awaited last (see loadForDay).
    final wearable = _wearableOf(repo, todayLabel());
    final today = await (stored ? repo.getTodayStored() : repo.getToday());
    final cd = await repo.getInsights();
    final profile = await repo.getProfile();

    final daily = today['daily'];
    Object? d(String k) => daily is Map ? daily[k] : null;

    final gb = cd['readiness_glassbox'];
    final gbDrivers = gb is Map ? gb['drivers'] : null;

    final coach = sleepCoachOf(cd);

    final strain = today['coach'];

    final heldOver = heldOverNightOf(today);

    // Same envelope Health reads. The watch runs on NOCTURNAL RESTING HEART
    // RATE ALONE — it has never been given a temperature series — so nothing
    // here may imply a second signal.
    final illness = today['illness'];
    final status = today['status'] as Map?;

    final over = _overnightOf(today, l);
    final sleepMin = over.sleepMin;

    // Stage totals of TODAY'S OWN night only: a held-over night is refused
    // above, and its stages must not turn up under today's ring.
    SleepStageMin? stages;
    if (sleepMin.value != null) {
      final night = (status?['overnight_day'] ?? status?['today_day'])?.toString();
      if (night != null) {
        try {
          stages = sleepStagesOf(await repo.getDaySleepV2(night));
        } catch (_) {
          stages = null;
        }
      }
    }

    // Typical onset/wake for the unslept estimate. The saved schedule and the
    // armed alarm are AppState's and are laid over this by the screen
    // ([HomeData.withSleepInputs]); a failed read here is simply absent.
    ({int? onsetMin, int? wakeMin}) learned = (onsetMin: null, wakeMin: null);
    try {
      learned = learnedClockMinutes(await repo.sleepWindows(days: 14));
    } catch (_) {}

    // The three that come off the OVERNIGHT block. Gated, so a night that is
    // not today's cannot arrive wearing today's clothes — see
    // [overnightMetric]. Steps, active energy and strain are today's own and
    // are read straight.
    // ONE headline source (todayHeadlineOf): the state Coach and the widgets
    // read too. A provisional night shows its own number, greyed.
    final recoveryState = over.recoveryState;
    final readiness = over.readiness;
    final absentDiag = readiness.value != null
        ? null
        : await ReadinessData.readAbsentDiag(
            repo, (today['status'] as Map?)?['today_day']?.toString());
    final pending = await _pendingActivitiesOf(repo);

    return HomeData(
      name: profile['name']?.toString(),
      dayId: status?['today_day']?.toString(),
      heldOverNight: heldOver,
      illnessState: illness is Map ? illness['state']?.toString() : null,
      illnessDay: illness is Map ? illness['date']?.toString() : null,
      illnessZ: illness is Map ? (illness['z'] as num?)?.toDouble() : null,
      readiness: readiness,
      absentDiag: absentDiag,
      recoveryState: recoveryState,
      readinessUpdate: over.update,
      drivers: [
        for (final e in (gbDrivers is List ? gbDrivers : const []))
          if (e is Map) e.cast<String, dynamic>(),
      ],
      strain: metricOf(d('strain')),
      sleepMin: sleepMin,
      sleepStages: stages,
      learnedOnsetMin: learned.onsetMin,
      learnedWakeMin: learned.wakeMin,
      rhr: over.rhr,
      steps: metricOf(d('steps')),
      calories: metricOf(d('calories')),
      caloriesTotal: metricOf(d('calories_total')),
      stepGoal: (today['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal,
      sleepNeedMin: coach.need,
      bedtime: coach.bedtime,
      strainTarget: strain is Map && strain['strain_target'] is Map
          ? (strain['strain_target'] as Map).cast<String, dynamic>()
          : null,
      insightsStale: staleReasonOf(cd),
      overnightAt:
          heldOver == null ? computedAtOf(status?['overnight_computed_at']) : null,
      overnightDay:
          heldOver == null ? (status?['overnight_day'])?.toString() : null,
      activityAt: computedAtOf(status?['activity_computed_at']),
      activityDay: status?['activity_day']?.toString(),
      refreshPending: status?['refresh_pending'] == true,
      pendingActivities: pending.count,
      pendingActivitiesFailed: pending.failed,
      wearable: await wearable,
    );
  }
}

Metric _dayMetric(Map<String, dynamic> row, String key) {
  final m = metricOf(row[key]);
  final provenance = row['from_older_version'];
  final p = provenance is Map ? provenance[key] : null;
  if (m.value == null || p is! Map || p['version'] is! num) return m;
  return Metric(value: m.value, unit: m.unit, confidence: m.confidence,
      tier: m.tier, label: m.label, inputsUsed: m.inputsUsed, beta: m.beta,
      note: m.note, fromOlderVersion: (p['version'] as num).toInt(),
      olderVersionReason: p['reason']?.toString());
}

/// How long until the next whole minute after [now], in (0, 60 s].
///
/// Taken from the UTC instant, never from local wall-clock fields: a minute
/// boundary is the same instant in every whole-, half- and quarter-hour zone,
/// but `DateTime(y, m, d, h, min + 1)` in the repeated fall-back hour resolves
/// to the FIRST occurrence of that wall time, an hour in the past — a negative
/// delay, a zero-delay Timer, and a setState loop.
@visibleForTesting
Duration nextMinuteTickDelay(DateTime now) {
  const minuteUs = 60 * 1000000;
  final us = now.toUtc().microsecondsSinceEpoch;
  final next = DateTime.fromMicrosecondsSinceEpoch(
      us - us % minuteUs + minuteUs,
      isUtc: true);
  return next.difference(now.toUtc());
}

class HomeScreen extends StatefulWidget {
  /// Injected only by goldens; production always loads.
  final HomeData? data;

  /// Hour of day, injected only by goldens. The greeting reads the clock, so a
  /// golden baked in the evening fails the next morning on nothing but the
  /// word "evening" — a test that breaks by being run at a different time is
  /// noise that trains you to regenerate without looking.
  final int? hour;

  /// Whether a workout is live, injected only by tests/goldens — production
  /// reads it off AppState via [workoutLiveOf].
  final bool? workoutLive;

  /// The wall clock, injected only by tests: the instant the sleep ring
  /// estimates from, and the day the illness watch ages against (a test of
  /// "a day later" needs to move it). Production reads `clock.now()`.
  final DateTime? now;

  const HomeScreen(
      {super.key, this.data, this.hour, this.workoutLive, this.now});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with RevisionReload, WidgetsBindingObserver, PausedReadReload<HomeScreen> {
  HomeData? _d;
  DateTime? _recordingsThrough;
  bool _loading = true;

  /// The day requested by the switcher, or null for "today" — the same
  /// null-means-today convention [_load] and [HomeData.load] already used
  /// before there was a switcher.
  String? _day;

  /// `availableDays()` — newest first — for [DayNav]. Refetched with every
  /// load: cheap, and a switcher stepping onto a day that just finished
  /// deriving must see it show up without a relaunch.
  List<String> _days = const [];

  /// The load THREW. Distinct from "there is nothing yet": a decode or a locked
  /// database is a read problem, and telling a user with three months of
  /// history that their band has never produced data is the wrong answer to it.
  bool _failed = false;
  bool _paused = false;

  /// Fires on each minute boundary so the sleep ring's estimate (wake minus
  /// now) does not freeze at the minute the screen was built.
  Timer? _tick;

  /// Test-facing: how many times the tick fired, and the delay last armed.
  @visibleForTesting
  int debugTickCount = 0;
  @visibleForTesting
  Duration? debugLastTickDelay;

  void _armTick() {
    _tick?.cancel();
    final delay = nextMinuteTickDelay(pc.clock.now());
    debugLastTickDelay = delay;
    _tick = Timer(delay, () {
      if (!mounted) return;
      debugTickCount++;
      setState(() {});
      _armTick();
    });
  }

  /// Nothing to keep fresh while the app is in the background; it catches up
  /// the moment it is back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) setState(() {});
      _armTick();
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    stopWatchingPausedRead();
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    watchPausedRead();
    WidgetsBinding.instance.addObserver(this);
    _armTick();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSince());
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// The "since hh:mm" time. Read on its own, never as part of the main model:
  /// during import focus it is paused (ReadPaused) and that means "unknown"
  /// (the overlay hides), not "today cannot be drawn". Focus end reloads.
  Future<void> _loadSince() async {
    final repo = repoOf(context);
    final day = widget.data?.dayId ?? _day ?? todayLabel();
    if (repo == null || day != todayLabel()) return;
    DateTime? through;
    try {
      through = (await pausedRead(repo.dayRecordingsThrough(day))).value;
    } catch (_) {
      return; // unreadable: leave what is shown
    }
    if (mounted && through != _recordingsThrough) {
      setState(() => _recordingsThrough = through);
    }
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data && widget.data != null) {
      _d = widget.data;
      _loading = false;
      _loadSince();
    }
  }

  /// Today and yesterday, plus the older day already on screen (so the
  /// stepper still has a place to step back from).
  List<String> _focusDays(String? shown) {
    final today = todayLabel();
    return [
      today,
      dayLabelBefore(today, 1)!,
      if (shown != null && shown != today && shown != dayLabelBefore(today, 1))
        shown,
    ];
  }

  @override
  bool get pausedContent => _paused;

  @override
  Future<void> reloadPausedRead() async {
    _loadSince();
    if (!mounted || widget.data != null) return;
    setState(() { _loading = true; _paused = false; });
    await _load();
  }

  /// Focus began under a loaded Home: the list shrinks and an older day's
  /// numbers go at once; today and yesterday re-read from what is published.
  @override
  void focusStarted() {
    if (widget.data != null) return;
    _days = _focusDays(_day);
    _load();
  }

  /// A model was published: today or yesterday on screen (or pending) refresh.
  @override
  void published() {
    final today = todayLabel();
    final shown = _day ?? today;
    if (widget.data == null &&
        (shown == today || shown == dayLabelBefore(today, 1))) {
      _load();
    }
  }

  /// Handed its data (golden, gallery) — the screen just renders what it has.
  @override
  bool get revisionReloads => widget.data == null;

  /// Home used to load once post-frame and never listen, so the "Sync the
  /// band" button it renders could not change what the screen showed: the
  /// offload landed, the derive ran, and Home kept saying "Nothing derived
  /// yet" until the app was relaunched.
  @override
  void reload() {
    if (absorbRevision()) return;
    _latency.revisionBumped();
    _refresh.reset();
    _refreshGaveUp = false;
    trackReload(_load);
  }

  /// Revision -> first commit that consumed it, logged by AppState. Only a
  /// revision-driven load is timed; the first load and the day switcher are
  /// not revisions.
  final RenderLatency _latency = RenderLatency(
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
  );

  void _recordRender() {
    final ms = _latency.committed();
    if (ms == null) return;
    try {
      context.read<AppState>().recordHomeRender(ms);
    } catch (_) {}
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final t = beginRead(#home);
    try {
      final day = _day;
      final l = AppLocalizations.of(context);
      final focus = ImportFocus.active.value;
      final today = todayLabel();
      Object? published(String? dd, String model) {
        if (!focus || dd == null) return null;
        final m = ImportFocus.days.value[dd];
        return m == null ? null : m[model];
      }

      final publishedToday =
          day == null || day == today ? published(today, 'getToday') : null;
      final publishedOverview = published(day, 'getDayOverview');
      final d = publishedToday is Map<String, dynamic>
          ? HomeData.fromPublishedToday(publishedToday, l)
          : publishedOverview is Map<String, dynamic>
              ? HomeData.fromPublishedOverview(day!, publishedOverview)
              : day == null || day == today
                  ? await HomeData.load(repo, l, true)
                  : await HomeData.loadForDay(repo, day, l);
      // During focus only today and yesterday are on offer, in every case.
      final List<String> days = focus
          ? _focusDays(day)
          : await repo.availableDays();
      if (stillNewest(#home, t)) {
        setState(() => (_d = d, _days = days, _loading = false, _failed = false,
            _paused = false));
        _recordRender();
        _loadSince();
        _refresh.afterPaint(repo, d.refreshPending).then((landed) {
          if (!mounted) return;
          if (landed) {
            _load();
          } else if (d.refreshPending) {
            setState(() => _refreshGaveUp = true);
          }
        });
      }
    } on ReadPaused {
      if (stillNewest(#home, t)) {
        // A paused day shows NO numbers: whatever was on screen belonged to
        // another day, or to before the pause.
        setState(() => (_d = null, _loading = false, _failed = false,
            _paused = true, _days = _focusDays(_day)));
      }
    } catch (_) {
      if (stillNewest(#home, t)) {
        setState(() => (_loading = false, _failed = true));
        // Nothing usable was rendered: drop the pending measurement rather
        // than time a later retry from this bump.
        _latency.committed();
      }
    }
  }

  /// The freshness refresh `getToday` used to run before the first paint. The
  /// repository joins overlapping calls into one run, and `_refreshing` keeps
  /// this screen from asking twice; it is cleared in `finally` so a failed
  /// refresh cannot stop the next load from asking again. On landing, read
  /// again: the stored row now names today.
  final _refresh = TodayRefreshLatch();

  /// The refresh was asked and did not land (it failed, or the read after it
  /// is still pending): stop holding the building state and say what is
  /// absent. Cleared by every reload, which asks again.
  bool _refreshGaveUp = false;

  /// Another day. The switcher never strands you off the record — [DayNav]
  /// already restricts the arrows to [_days] — so this just re-loads for it.
  void _goDay(String day) {
    setState(() {
      _day = day;
      _loading = true;
    });
    _load();
  }



  /// Morning / afternoon / evening / night. One split at 18:00 greeted 00:30
  /// and 15:40 alike with "Good morning" beside a sun.
  ({String word, IconData icon, Color color}) _greeting(int h, AppLocalizations? l) {
    if (h < 5) {
      return (word: l?.homeGreetingStillUp ?? 'Still up', icon: LucideIcons.moon, color: C.indigo);
    }
    if (h < 12) {
      return (word: l?.homeGreetingMorning ?? 'Good morning', icon: LucideIcons.sun, color: C.yellow);
    }
    if (h < 18) {
      return (word: l?.homeGreetingAfternoon ?? 'Good afternoon', icon: LucideIcons.sun, color: C.orange);
    }
    return (word: l?.homeGreetingEvening ?? 'Good evening', icon: LucideIcons.moon, color: C.indigo);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final loaded = _d;
    // ONE SCREEN FOR EVERY STATE. No day yet (the first read is out, it failed,
    // or there is no repository) is the loaded screen with nothing in it, not a
    // different screen: the same cards in the same places, drawn empty. Each
    // card is keyed `card:<name>` so a layout check can hold them still.
    final d = loaded ?? const HomeData();
    final g = _greeting(widget.hour ?? DateTime.now().hour, l);

    // Nothing measured at all. It is also where a day of NO WEAR lands, because
    // the overnight block no longer borrows an older night to fill the rings
    // with. Those are two different days and the copy splits them on the one
    // fact that tells them apart: whether this install has ever scored a night.
    final noData = d.readiness.isEmpty &&
        d.sleepMin.isEmpty &&
        d.strain.isEmpty &&
        d.rhr.isEmpty &&
        d.steps.value == null &&
        d.calories.isEmpty;

    // Whether the switcher is showing today or a day stepped back onto —
    // gates the plan/live-workout copy below, which is about what to DO
    // today and reads as a stale instruction on a day already in the past.
    final isToday = _day == null || _day == todayLabel();
    // The alarm is AppState's. Only TODAY's rings estimate toward it.
    final ringData =
        isToday ? d.withSleepInputs(
                alarm: nextAlarmOf(c) ?? d.nextAlarm,
                schedule: sleepScheduleOf(c) ?? d.sleepSchedule)
            : d;
    // A day with no measured data is not bare when tonight's estimate can be
    // made: a saved schedule or an armed alarm is something to show.
    final bare =
        noData && !(isToday && RingTrio.hasSleepEstimate(ringData, now: widget.now));
    // The stored row is another day's and today's refresh is still out: today
    // is being worked out, not empty. "No nights scored yet" here would be a
    // false empty state.
    final building = bare &&
        isToday &&
        widget.data == null &&
        d.refreshPending &&
        !_refreshGaveUp;

    // Until recovery can score for the first time: what arrives when.
    // Also while the readiness note still counts nights: missed nights push
    // the first score past the day-15 the count alone would show.
    final recoveryNightsLeft = needMoreNightsFromNote(d.readiness.note);
    final firstWeeks = isToday &&
        widget.data == null &&
        d.readiness.isEmpty &&
        (_days.length <= readinessCompositeMinBaseline ||
            recoveryNightsLeft != null);

    // The first-week guidance, counts from the analytics gates (never
    // invented). It is the longest thing the help strip says, so it is also
    // what the strip reserves room for in every other state.
    final strainDay = quietHrrMinDays + 1;
    final guidance = recoveryNightsLeft != null
        ? (l?.homeHelpFirstWeekCounting(
                l.homeRecoveryStartsIn(recoveryNightsLeft), strainDay) ??
            'Your first week: wear it to sleep. Recovery starts in '
                '$recoveryNightsLeft ${recoveryNightsLeft == 1 ? 'night' : 'nights'}'
                ', strain from day $strainDay.')
        : (l?.homeHelpFirstWeek(readinessCompositeMinBaseline + 1, strainDay) ??
            'Your first week: wear it to sleep. Recovery from night '
                '${readinessCompositeMinBaseline + 1}, strain from day $strainDay.');

    // WHAT THE HELP STRIP UNDER THE RINGS SAYS. It replaces the cards that
    // used to stand in for the rings (reading, failed, calculating, workout
    // hold, nothing yet, first weeks): the rings are always drawn, and this is
    // their one line of status or guidance. Null leaves the ring's own default
    // (the gaps' reasons, the "Why?" footer, the recovery update).
    RingHelp? help;
    if (_paused) {
      // Nothing is read: a paused day is neither a spinner nor an empty day.
      help = RingHelp(isToday ? pausedTodayText(c) : pausedOlderDaysText(c));
    } else if (loaded == null && _loading) {
      help = RingHelp.busy(l?.loadingHomeToday ?? 'Reading today');
    } else if (loaded == null && _failed) {
      help = RingHelp(
          '${l?.homeLoadFailedTitle ?? 'Today could not be read'} · '
          '${l?.homeTryAgain ?? 'Try again'}', onTap: () {
        setState(() => (_loading = true, _failed = false));
        _load();
      });
    } else if (bare) {
      help = building
          ? RingHelp.busy(derivingOf(c)
              ? (l?.loadingCalculatingToday ?? 'Calculating today')
              : (l?.loadingWaitingToCalculateToday ??
                  'Waiting to calculate today'))
          : !isToday
              ? const RingHelp('No data for this day. Nothing was recorded on this day.')
              : (widget.workoutLive ?? workoutLiveOf(c))
                  ? RingHelp('${l?.homeWorkoutHoldTitle ?? 'A workout is still running'}. '
                      '${l?.homeWorkoutHoldBody ?? 'Today fills in when you finish the workout.'}')
                  : derivingOf(c)
                      ? RingHelp.busy(l?.homeAnalyzingTitle ??
                          'Crunching last night\'s numbers')
                      : firstWeeks
                          ? RingHelp(guidance)
                          : RingHelp(d.heldOverNight == null
                              ? '${l?.homeNothingDerivedTitle ?? 'No nights scored yet'}. '
                                  '${l?.homeNothingDerivedBody ?? 'Wear the band tonight and open the app in the morning.'}'
                              : '${l?.homeNothingTodayTitle ?? 'Nothing recorded for today'}. '
                                  '${l?.homeNothingTodayBody(prettyDay(d.heldOverNight, l)) ?? 'Last scored night: ${prettyDay(d.heldOverNight, l)}.'}');
    } else if (!RingTrio.has(ringData, now: widget.now)) {
      // Some measurement exists but no ring can draw: say why, and the strip
      // is the door to the Readiness screen that can say more.
      final need = needMessageFromNote(d.readiness.note);
      final shortfall = need == null
          ? readinessInputShortfallNote(d.absentDiag) ??
              readinessUnstableBaselineNote(d.absentDiag?['note']?.toString())
          : null;
      help = RingHelp(
          need != null
              ? (l?.homeReadinessNeedBody(need) ??
                  '$need to know what normal looks like for you.')
              : shortfall ??
                  whyFromNote(d.readiness.note) ??
                  (l?.homeReadinessNoReason ?? 'No reading.'),
          onTap: () => go(c, const ReadinessDetail()));
    } else if (firstWeeks && d.drivers.isEmpty) {
      help = RingHelp(guidance);
    }

    // No sync button on this card either: Home's one sync control is the
    // only place Home starts a sync.
    final stale = staleInsightsCard(d.insightsStale, null, l);
    // Above the greeting, not below it: if the app had to rebuild the database
    // to start, that outranks anything else this screen has to say today.
    final rebuilt = dbRebuiltCard(dbRebuildOf(c), l);

    Widget card(String name, Widget child) =>
        KeyedSubtree(key: ValueKey('card:$name'), child: child);

    return _refreshable(tabRootList(padding: pad, children: [
      // ── greeting ──
      //
      // The same header every tab has: the greeting is the title, the profile
      // button is the avatar. Below it, the sync row (the status line every tab
      // has, plus Sync now / Show details), then the connection. Its end is no
      // longer shared with the button.
      //
      // ONE list child: the sync row's 44 pt targets overhang the lines around
      // it (see [HitOverhang]), and a list item only hit-tests inside its own
      // box, so the title and the rows must share a box.
      card(
        'header',
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ScreenTitle(
            d.name == null || d.name!.isEmpty ? g.word : '${g.word}, ${d.name}',
            shortTitle: g.word,
            avatar: _homeAvatar(c, l),
          ),
          // Keep the row control in the same spanning Column as the device
          // rows so its full tap target remains reachable.
          const HeaderRows(),
        ]),
      ),
      const SizedBox(height: S.x5),
      // ── conditional cards, UNDER the header ──
      //
      // They come and go (a rebuilt database, a buzzing alarm, a snooze, a
      // marked moment, an illness watch). The header is the same box in every
      // state, so none of them may sit above it: that moved the title and the
      // first content against every other tab, and left the first card flush
      // against the safe area.
      ?rebuilt,
      // Natural Wake is buzzing and waiting for "I'm up".
      ?_naturalWakeCard(c),
      // A pending main-alarm snooze, with the same "I'm up".
      ?snoozeCardFor(c),
      ?momentFollowUpCard(c),

      // ── the one observation Home is allowed to make ──
      //
      // OUTSIDE the derived / not-derived split, and above the rings: it
      // outranks them, and it does not depend on them — the watch comes off the
      // CROSSDAY rollup, so it can carry a real state on a morning whose own
      // bundle has not derived yet.
      ...?_bodyWatch(c, d, todayLabel(widget.now)),

      // Conditional by design (it appears when there is something to review),
      // so it is outside the first-launch comparison.
      if (loaded == null) ...[
        // Not while the first read is out: the card reads its own count.
        if (!_loading && !ImportFocus.active.value) card('detected', const DetectedActivitiesCard()),
      ] else if (bare && !building)
        if (!ImportFocus.active.value) card('detected', _detectedActivities(d)),
      // The day switcher keeps its slot (arrows dimmed) before there is a
      // second day, so the card is there from the first launch.
      card('daynav',
          DayNav(day: _day ?? d.dayId, days: _days, onDay: _goDay, alwaysShow: true)),
      const SizedBox(height: S.x3),
      // Stepped back through the record: one tap home.
      if (!isToday)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => _goDay(todayLabel()),
            child: Text(l?.homeBackToToday ?? 'Back to today'),
          ),
        ),

      // ── the three rings ──
      //
      // Recovery, strain and sleep, each a door into its own screen, ALWAYS
      // drawn: with nothing to show they are empty rings with a dash, and the
      // strip under them says why and what arrives when. They used to be
      // replaced by a status card, which made first launch a different layout
      // from the loaded one. The pipeline records why readiness came back
      // absent; that diagnostic is one tap away on the Readiness screen.
      card(
        'rings',
        RingTrio(
          d: ringData,
          now: widget.now,
          since: isToday ? _recordingsThrough : null,
          holdText: isToday
              ? _holdText(c, _recordingsThrough,
                  ringData.overnightAt ?? ringData.activityAt)
              : null,
          help: help,
          reserveHelp: guidance,
          onOpen: (k) => go(
              c,
              switch (k) {
                HomeRingKind.recovery => const ReadinessDetail(),
                HomeRingKind.strain => const DayStrainDetail(),
                // The night the ring was drawn from, not last night. Today
                // stays null even after the switcher steps back onto it:
                // today's ring is the held-over night, and only the default
                // pick resolves to that one.
                HomeRingKind.sleep => SleepDetail(day: isToday ? null : _day),
              }),
        ),
      ),
      if (!bare) ...[
        // Right under the rings: a failed gesture comes first, the newest
        // undismissed one, one card at a time.
        if (gestureFailuresOf(c) case final failures?)
          GestureFailureCard(store: failures),
      ],
      const SizedBox(height: S.x3),
      if (!bare && !ImportFocus.active.value) card('detected', _detectedActivities(d)),
      // Community asks: eligible or not, never part of the first-launch layout.
      if (!bare) const CommunityNudge(key: ValueKey('card:nudge')),

      // ── the rollup was withheld, not absent ──
      if (stale != null) ...[const SizedBox(height: S.x3), card('stale', stale)],

      // ── at a glance ──
      // In every state, the alarm first: resting HR, steps and energy are real
      // from night one, and until then each tile is a dash with the line that
      // says what fills it.
      card('glance',
          Section(l?.homeAtAGlance ?? 'At a glance',
              _glance(c, d, isToday: isToday))),

      // ── today's plan: only what the app can actually stand behind ──
      // Skipped on a past day — "3,000 steps left" or "aim for 11.4
      // strain" about a day already over is an instruction, not a fact.
      if (isToday)
        card('plan',
            Section(l?.homeTodaysPlan ?? "Today's plan", _plan(c, p, d))),

      // ── the way into the whole day ──
      //
      // A DOOR, NOT A CARD: it shows no number, previews no shape and makes no
      // observation — it names a place and goes there.
      const SizedBox(height: S.x5),
      card(
        'breakdown',
        detailLinkRow(c, LucideIcons.chartGantt,
            l?.homeBreakdownTitle ?? 'Breakdown of your day',
            l?.homeBreakdownSubtitle ?? 'Hour by hour',
            () => go(c, DayTimelineScreen(day: _day))),
      ),

      // The coach, set up or not, on every ordinary or bare today. Not while
      // today is building: the figures landing above would push it down.
      if (isToday && !building) ...[
        const SizedBox(height: S.x4),
        card('coach', coachChip(c)),
      ],

      // The active wearable's day, cell by cell. LAST, because it exists only
      // on an install with an active wearable and arrives with the day read:
      // anywhere above the rings it would push the rings (drawn from the first
      // paint) down when it landed. At the foot it moves nothing. Nothing on a
      // WHOOP-only install, nor when the screen is handed its data.
      if (widget.data == null)
        card(
          'wearables',
          WearableCells.seeded(kHomeWearableRows,
              date: isToday ? null : _day,
              initialDevice: d.wearable == null
                  ? null
                  : wearableName(d.wearable!.adapterId),
              initialCells: d.wearable?.cells ?? const {}),
        ),
    ]));
  }

  /// "As of <time>" under the rings while a pass is recalculating their day:
  /// recovery and sleep say when the overnight row was computed, strain and
  /// activity when today's was. See [AsOfHold] for why it outlasts the pass by
  /// one reload.
  static Widget _homeAsOf(BuildContext c, HomeData d) {
    Widget label(BuildContext c, DateTime at) => Padding(
        padding: const EdgeInsets.only(top: S.x2), child: AsOfLabel(at: at));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AsOfHold(
        shown: d,
        builder: label,
        suppressStaleHold: d.activityAt == d.overnightAt &&
            d.activityDay == d.overnightDay,
        day: d.overnightDay,
        computedAt: d.overnightAt,
        asOf: (recalc) => asOfFor(
            shownDay: d.overnightDay,
            computedAt: d.overnightAt,
            recalc: recalc),
      ),
      AsOfHold(
        shown: d,
        builder: label,
        day: d.activityDay,
        computedAt: d.activityAt,
        // One line when both rows were computed together.
        asOf: (recalc) => d.activityAt == d.overnightAt &&
                d.activityDay == d.overnightDay
            ? null
            : asOfFor(
                shownDay: d.activityDay,
                computedAt: d.activityAt,
                recalc: recalc),
      ),
    ]);
  }

  /// The illness watch, on Home, at amber as well as red.
  ///
  /// Returns null on every ordinary day — green, or no state at all because the
  /// CUSUM has not got its 7 nights yet. Absence here is silence, not a card
  /// explaining that nothing is wrong: "you are not getting sick" is not an
  /// observation worth a slot, and a watch that renders daily stops being read.
  ///
  /// The tap goes to the resting-heart-rate chart rather than Health's copy of
  /// this card, because the chart is the EVIDENCE — the watch reads that one
  /// series, so the honest answer to "why are you telling me this" is to show
  /// it. Health keeps its own fuller card; this is not a duplicate route to the
  /// same words, it is a shorter road to the number underneath them.
  ///
  /// [today] is the WALL-CLOCK day at build time, not the loaded payload's: a
  /// payload loaded yesterday and rebuilt today with no new sync has aged a
  /// day all the same.
  static List<Widget>? _bodyWatch(BuildContext c, HomeData d, String today) {
    final state = d.illnessState;
    if (state == null || state == 'green') return null;
    // The watch publishes the newest SETTLED night, which after days off the
    // wrist is days old, and the red title carries no date. Same freshness
    // rule as the push: older verdicts live in Observations, not on Home.
    final day = d.illnessDay;
    if (day == null || !isRecentFindingDate(day, today: today)) return null;
    final l = AppLocalizations.of(c);

    final sameNight = day == today;
    final z = d.illnessZ;

    return [
      Observation(
        state == 'red'
            ? (l?.homeIllnessRedTitle ?? 'Recent nights add up to a raised resting heart rate')
            : sameNight
                ? (l?.homeIllnessAmberSameNight ?? 'Last night sat outside your normal range')
                : (l?.homeIllnessAmberOtherNight(prettyDay(d.illnessDay, l)) ??
                    '${prettyDay(d.illnessDay, l)} sat outside your normal range'),
        z == null
            ? (l?.homeIllnessBodyNoZ ??
                'Your resting heart rate has been above your usual over recent nights. A pattern, not a cause.')
            : (z >= 0
                ? (l?.homeIllnessBodyAbove ??
                    'Recent nights put your resting heart rate above your usual. That night was above it too. A pattern, not a cause.')
                : (l?.homeIllnessBodyBelow ??
                    'Recent nights together put your resting heart rate above your usual, though that night alone was below it. A pattern, not a cause.')),
        advice: l?.homeIllnessAdvice ?? 'Worth noting if it continues past a couple of days.',
        onTap: () => go(c, const MetricDetail('resting_hr')),
      ),
      const SizedBox(height: S.x3),
    ];
  }

  /// "Detected activities", handed the count read with the day so it is in
  /// its landed shape on the first paint. Keyed by the count: the card copies
  /// it once, so a new count (a reload after a review) needs a new card.
  static Widget _detectedActivities(HomeData d) => DetectedActivitiesCard(
      key: ValueKey<(int?, bool)>(
          (d.pendingActivities, d.pendingActivitiesFailed)),
      pendingCount: d.pendingActivities,
      loadFailed: d.pendingActivitiesFailed);

  /// Pull to reload. The screen also reloads itself on `insightsRevision`, but
  /// a derive that fails silently, an import, or anything that lands without
  /// bumping it still leaves the user a way to ask.
  // HomeSyncStatus renders AppState's shared SyncPresentationState.
  //
  // "Pull down to sync" (Settings) off means no RefreshIndicator at all, so an
  // overscroll does nothing; the status line's Sync now is the way to sync.
  Widget _refreshable(Widget list) => !Prefs.pullToSyncOn
      ? list
      : RefreshIndicator(onRefresh: () async {
        try { await context.read<AppState>().refreshData(); }
        on ProviderNotFoundException { /* Standalone fixture has local data only. */ }
        if (mounted) await _load();
      }, child: list);

  Widget _glance(BuildContext c, HomeData d, {required bool isToday}) {
    final l = AppLocalizations.of(c);
    final cards = <Widget>[];
    // Every tile reserves two caption lines, so a tile that is a dash today and
    // a reading tomorrow is the same box both ways.
    const lines = 2;

    // The next alarm is not a reading of the day, so only today carries it —
    // "Tomorrow 07:30" under a day already over would be about a different day.
    // First, in every state: "Not set / Set an alarm" is a real answer.
    if (isToday) {
      if (alarmArmOfContext(c) case final (DateTime?, AlarmArmState) a) {
        cards.add(alarmGlanceCard(c, a.$1, a.$2));
      }
    }

    // Resting heart rate comes off the SAME overnight block readiness does, and
    // it cannot be an older night — the loader refuses those — so every tile in
    // this row is today's and none of them needs a date.
    final fillsNight = l?.homeGlanceFillsNight ?? 'Fills after a scored night';
    final fillsMove = l?.homeGlanceFillsMove ?? 'Fills as you move';
    cards.add(d.rhr.isEmpty
        ? SignalCard(LucideIcons.heart, C.red, l?.homeHeartRate ?? 'Heart rate', '—',
            reserveUnit: 'bpm',
            sub: fillsNight,
            subMinLines: lines,
            onTap: () => go(c, const MetricDetail('resting_hr')))
        : SignalCard(LucideIcons.heart, C.red, l?.homeHeartRate ?? 'Heart rate',
            '${d.rhr.value!.round()}',
            unit: 'bpm',
            sub: l?.homeRestingSub ?? 'Resting',
            subMinLines: lines,
            onTap: () => go(c, const MetricDetail('resting_hr'))));
    // Zero steps is a real reading — an unmoved counter — and renders as 0.
    // Only a counter that never reported is a dash.
    cards.add(SignalCard(
      LucideIcons.footprints,
      C.green,
      l?.homeSteps ?? MetricLabels.steps,
      d.steps.value == null ? '—' : thousands(d.steps.value),
      // The sensor rides the line that is already there rather than adding a
      // row: the day is resolved per window now, so "8,412" can be the strap's
      // count, the phone's, or both, and the card has to say which. The split
      // behind a mixed day is on Nerd stats, one tap down.
      sub: d.steps.value == null
          ? fillsMove
          : [
              if (d.stepGoal > 0)
                l?.homeStepsPercentGoal(
                        ((d.steps.value! / d.stepGoal) * 100).clamp(0, 999).round()) ??
                    '${((d.steps.value! / d.stepGoal) * 100).clamp(0, 999).round()}% of goal',
              ?stepSensorLabel(d.steps, l),
            ].join(' · '),
      subMinLines: lines,
      onTap: () => go(c, const MetricDetail('steps')),
      // The ring's 20 pt slot is kept when there is no ring, so the tile is the
      // same height with and without it.
      trailing: d.steps.value == null || d.stepGoal <= 0
          ? const SizedBox(width: 20, height: 20)
          : SizedBox(
              width: 20,
              height: 20,
              child: CustomPaint(
                painter: Ring(d.steps.value! / d.stepGoal, C.green,
                    P.of(c).track,
                    stroke: 3, solid: true, background: P.of(c).card),
              ),
            ),
    ));
    cards.add(d.calories.isEmpty
        ? SignalCard(LucideIcons.flame, C.orange,
            l?.homeActiveEnergy ?? 'Active energy', '—',
            sub: fillsMove,
            subMinLines: lines,
            onTap: () => go(c, const MetricDetail('calories')))
        : SignalCard(LucideIcons.flame, C.orange,
            l?.homeActiveEnergy ?? 'Active energy',
            thousands(d.calories.value),
            unit: 'kcal',
            sub: d.caloriesTotal.value == null
                ? (l?.homeCaloriesEstimated ?? 'Estimated')
                : (l?.homeCaloriesTotal(thousands(d.caloriesTotal.value)) ??
                    '${thousands(d.caloriesTotal.value)} total'),
            subMinLines: lines,
            // Each figure carries its OWN provenance: the active number beside
            // the unit, the total on the caption it is printed in.
            olderId: 'calories',
            olderVersion: d.calories.fromOlderVersion,
            olderReason: d.calories.olderVersionReason,
            olderTotalVersion: d.caloriesTotal.value == null
                ? null
                : d.caloriesTotal.fromOlderVersion,
            olderTotalReason: d.caloriesTotal.olderVersionReason,
            onTap: () => go(c, const MetricDetail('calories'))));

    return Column(children: [
      for (var i = 0; i < cards.length; i += 2) ...[
        if (i > 0) const SizedBox(height: S.x3),
        // IntrinsicHeight, because `stretch` inside a ListView asks for an
        // infinite height. The two cards in a row must match: a short card
        // beside a tall one reads as a layout bug, not as less data. An odd
        // last card takes the whole width rather than half of it with a hole.
        if (i + 1 >= cards.length)
          cards[i]
        else
          IntrinsicHeight(
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: cards[i]),
              const SizedBox(width: S.x3),
              Expanded(child: cards[i + 1]),
            ]),
          ),
      ],
    ]);
  }


  Widget _plan(BuildContext c, P p, HomeData d) {
    final l = AppLocalizations.of(c);
    final rows = <Widget>[];

    // THREE FIXED ROWS, in every state: movement, training, sleep. A row with
    // nothing to say is a dash, so the card is the same card first launch and
    // loaded. (It used to hold only the rows that had something, or a status
    // card when none did.)
    final stepsLeft = d.steps.value == null
        ? null
        : (d.stepGoal - d.steps.value!).round();
    final movement = l?.homeMovement ?? 'Movement';
    if (stepsLeft != null && stepsLeft > 0) {
      rows.add(_row(
          p,
          LucideIcons.footprints,
          C.green,
          l?.homeStepsLeft(thousands(stepsLeft)) ?? '${thousands(stepsLeft)} steps left',
          movement,
          l?.homeGoalSteps(thousands(d.stepGoal)) ?? 'Goal ${thousands(d.stepGoal)}',
          false));
    } else if (stepsLeft != null) {
      rows.add(_row(p, LucideIcons.footprints, C.green,
          l?.homeStepGoalMet ?? 'Step goal met',
          movement, l?.actionDone ?? 'Done', true));
    } else {
      rows.add(_row(p, LucideIcons.footprints, C.green, '—', movement, '', false));
    }

    final target = d.strainTarget;
    if (target != null && target['value'] is num) {
      final aim = target['value'] as num;
      // The strain ring is on this screen now, so a row still saying "aim for
      // 11.4" beside a ring reading 14.2 is a plan the day already overtook.
      // Same shape the step goal above it has always had.
      final met = (d.strain.value ?? -1) >= aim;
      rows.add(_row(
          p,
          LucideIcons.zap,
          C.purple,
          met
              ? (l?.homeStrainTargetMet ?? 'Strain target met')
              : (l?.homeAimForStrain(aim.toStringAsFixed(1)) ??
                  'Aim for ${aim.toStringAsFixed(1)} strain'),
          // Built on a wearable's estimated TRIMP: say so.
          [
            l?.homeTraining ?? 'Training',
            if (target['estimated'] == true) l?.wearableEstimated ?? 'Estimated',
          ].join(' · '),
          met
              ? (l?.actionDone ?? 'Done')
              : '${(target['low'] as num?)?.toStringAsFixed(1) ?? ''}–'
                  '${(target['high'] as num?)?.toStringAsFixed(1) ?? ''}',
          met));
    } else {
      rows.add(_row(p, LucideIcons.zap, C.purple, '—',
          l?.homeTraining ?? 'Training', '', false));
    }

    final need = d.sleepNeedMin.value;
    if (need != null) {
      rows.add(_row(
          p,
          LucideIcons.bedDouble,
          C.blue,
          l?.homeSleepNeedRow(hm(need)) ?? '${hm(need)} of sleep',
          l?.homeTonight ?? 'Tonight',
          d.bedtime.value == null
              ? (l?.homeNeed ?? 'Need')
              : (l?.homeBedTime(clock(d.bedtime.value)) ?? 'Bed ${clock(d.bedtime.value)}'),
          false));
    } else {
      rows.add(_row(p, LucideIcons.bedDouble, C.blue, '—',
          l?.homeTonight ?? 'Tonight', '', false));
    }

    final planBody = Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x2),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(color: p.line, height: 1),
          rows[i],
        ],
      ]),
    );

    return Column(children: [
      planBody,
      const SizedBox(height: S.x3),
      _briefingDoor(c, d),
    ]);
  }

  /// The only quick way into [AiBriefingScreen] used to be the notification
  /// that fires when a briefing is ready — dismiss or miss it, and the
  /// screen was two non-obvious taps deep behind Coach's overflow menu
  /// instead (see EDGE-14). Shown unconditionally, not gated on AI/BYOK
  /// being configured: the screen itself already has a graceful
  /// "no model set up" state with its own way to fix that, so gating here
  /// would just duplicate that door rather than simplify anything.
  /// Re-run on every call rather than cached by the caller: Home is kept
  /// alive by the shell's `IndexedStack` (see revision.dart), so a build can
  /// sit for hours without rerunning. Resolving once at build time and
  /// capturing the result in the row's `onTap` closure would let a stale
  /// morning/evening decision — or a briefing written in the background
  /// after that build — survive across the 17:00 boundary until Home
  /// happens to rebuild for an unrelated reason.
  ({BriefingPeriod period, Briefing? briefing}) _resolveBriefingNow(HomeData d) {
    final period = currentBriefingPeriod(DateTime.now());
    return resolveBriefingToShow(
      period,
      BriefingStore.read(period, day: d.dayId),
      BriefingStore.read(BriefingPeriod.morning, day: d.dayId),
    );
  }

  Widget _briefingDoor(BuildContext c, HomeData d) {
    final l = AppLocalizations.of(c);
    final cached = _resolveBriefingNow(d).briefing;
    return detailLinkRow(
      c,
      LucideIcons.sparkles,
      l?.homeBriefingTitle ?? 'Briefing',
      cached?.oneLiner == 'Nothing stood out tonight.'
          ? uiText(c, cached!.oneLiner)
          : cached == null
              ? (l?.homeBriefingSubtitleEmpty ?? 'Tap to write today\'s summary')
              // An asterisk when the note drew on an older calculation; the
              // footnote on the briefing itself names the version.
              : '${cached.oneLiner}${cached.olderVersions.isEmpty ? '' : '*'}',
      () async {
        // Resolved fresh at tap time via _resolveBriefingNow, not read from
        // the value above — see that method's doc for why.
        //
        // Writing a briefing (BriefingStore.write, in briefing_engine.dart)
        // does not bump AppState.insightsRevision, so RevisionReload's
        // automatic reload never fires for it — awaiting the route and
        // reloading on return is the only way this row picks up a briefing
        // written during the visit instead of showing stale/empty text until
        // some UNRELATED revision bump happens to refresh Home.
        final screen = AiBriefingScreen(period: _resolveBriefingNow(d).period);
        await Navigator.of(c).push(
            themedRoute<void>((_) => screen, name: screen.runtimeType.toString()));
        if (mounted) reload();
      },
    );
  }

  Widget _row(P p, IconData i, Color col, String title, String kind,
          String meta, bool done) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration:
                BoxDecoration(color: p.wash(col), borderRadius: R.rSm),
            child: Icon(i, size: 16, color: p.on(col)),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kind, style: F.over.copyWith(color: p.ink3)),
                  const SizedBox(height: 2),
                  Text(title, style: F.body.copyWith(color: p.ink)),
                ]),
          ),
          const SizedBox(width: S.x2),
          Text(meta,
              textAlign: TextAlign.right,
              style: F.cap.copyWith(
                  color: done ? p.on(C.green) : p.ink3,
                  fontWeight: done ? FontWeight.w600 : FontWeight.w400)),
        ]),
      );
}

/// The coach's one door on Today. It used to be an icon that appeared only
/// once a model was configured, so a new user never learned there was a
/// coach. Not set up, the chip says what it is for and opens the setup.
Widget coachChip(BuildContext c) {
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  final ready = coachReady(c);
  final text = ready
      ? (l?.homeAskCoach ?? 'Ask the coach')
      : (l?.homeCoachSetUpChip ?? 'Set up the coach');
  return Align(
    alignment: Alignment.centerLeft,
    child: Pressable(
      semanticLabel: text,
      onTap: () => go(c, ready ? const CoachScreen() : const CoachSetup()),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
        decoration:
            BoxDecoration(color: p.wash(kCoachAccent), borderRadius: R.rPill),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.sparkles, size: 16, color: p.on(kCoachAccent)),
          const SizedBox(width: S.x2),
          Flexible(
            child: Text(text,
                style: F.cap.copyWith(
                    color: p.on(kCoachAccent), fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    ),
  );
}
