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

import 'package:clock/clock.dart' as pc;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ai/briefing.dart'
    show Briefing, BriefingPeriod, BriefingStore, currentBriefingPeriod, resolveBriefingToShow;
import '../../compute/derive_perf.dart' show RenderLatency;
import '../../compute/findings.dart'
    show
        isRecentFindingDate,
        kReadinessEasyBelow,
        kReadinessGoodFrom,
        kReadinessRestBelow;
import '../../data/day_label.dart' show todayLabel, calendarDaysBetween;
import '../../compute/onehz_pipeline.dart'
    show readinessInputShortfallNote, readinessUnstableBaselineNote;
import '../../data/db.dart' show DbRebuild;
import '../../data/journal_fields.dart' show formatMinuteOfDay;
import '../../data/local_repository.dart';
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
    show AlarmArmState, alarmArmOf, alarmDoor, alarmGlanceCard;
import '../profile/devices.dart' show formatDayTime;
import '../profile/profile.dart' show ProfileAvatar;
import '../profile/settings.dart' show MoreSettings;
import '../profile/wearable_numbers.dart'
    show WearableCells, kHomeWearableRows;
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
const pad = EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x16 + S.x8);

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

/// The status line as Home renders it, so the loading / failed / bare paths
/// show it too. It answers "how far are we?", and the moment that question is
/// loudest is the one where there is no day to show.
Widget syncedThroughLine(BuildContext c, String? todayId,
    [AppLocalizations? l]) {
  final at = lastDataAtOf(c);
  return HomeSyncStatus(
    through: syncedThroughLabel(at, todayId, l),
    throughShort: syncedThroughShortLabel(at, todayId, l),
  );
}

/// Rows 1 and 2 of the greeting header. Row 1 is the sync row
/// ([HomeSyncStatus], with [end], the settings button, at its right end): the
/// date when idle, replaced by the progress status or the problem while one
/// shows. Row 2 is always "Synced through 15:33", plain text, inset on the
/// right so it never runs under the button's overhang.
List<Widget> homeHeaderRows(
  BuildContext c, {
  required String? todayId,
  required String date,
  required Widget end,
  required double endInset,
  AppLocalizations? l,
}) {
  return [
    HomeSyncStatus(through: date, throughShort: date, end: end),
    Padding(
      padding: EdgeInsets.only(right: endInset),
      child: _HeldSyncedThrough(
        at: lastDataAtOf(c),
        busy: syncBusyOf(c),
        todayId: todayId,
        l: l,
      ),
    ),
  ];
}

/// "Synced through …" that holds its last value while a sync runs: records
/// land in batches mid-sync, and the line only moves once the sync is done.
class _HeldSyncedThrough extends StatefulWidget {
  const _HeldSyncedThrough(
      {required this.at, required this.busy, required this.todayId, this.l});

  final DateTime? at;
  final bool busy;
  final String? todayId;
  final AppLocalizations? l;

  @override
  State<_HeldSyncedThrough> createState() => _HeldSyncedThroughState();
}

class _HeldSyncedThroughState extends State<_HeldSyncedThrough> {
  late DateTime? _shown = widget.at;

  @override
  Widget build(BuildContext c) {
    if (!widget.busy) _shown = widget.at;
    return Text(syncedThroughLabel(_shown, widget.todayId, widget.l),
        style: F.cap.copyWith(color: P.of(c).ink3),
        maxLines: 1,
        overflow: TextOverflow.ellipsis);
  }
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

/// One stored chart point: `t` is the epoch SECONDS `getChart` stamps on it
/// (local noon of the day the value was derived on), `v` the value.
typedef ChartPoint = ({int t, double v});

/// A `[{t, v}]` point list from `getChart`, timestamps INTACT.
///
/// [seriesOf] drops `t`, and everything downstream then labelled its x axis off
/// the ARRAY INDEX — `'Today'`, `'N days ago'`, weekday letters. `metric_series`
/// stores one row per DERIVED day, not one per calendar day, so after a sync gap
/// the newest stored point is days old and was still being called "Today".
/// Anything that draws a dated axis reads this.
List<ChartPoint> pointsOf(Object? chart) {
  final pts = chart is Map ? chart['points'] : null;
  if (pts is! List) return const [];
  return [
    for (final e in pts)
      if (e is Map && e['v'] is num && e['t'] is num)
        (t: (e['t'] as num).round(), v: (e['v'] as num).toDouble()),
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
List<double?> denseDays(List<ChartPoint> pts, int days) {
  final out = List<double?>.filled(days, null);
  for (final p in pts) {
    final behind = daysBehind(p.t);
    if (behind == null || behind < 0 || behind >= days) continue;
    out[days - 1 - behind] = p.v;
  }
  return out;
}

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
    l?.homeDbRebuiltTitle ?? 'Your database was rebuilt to start the app',
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
          'Today is paused while a workout runs. The band keeps recording; finish the workout from the bar below and today fills in.',
      icon: LucideIcons.timer,
    );

StatusCard? staleInsightsCard(
    Map<String, dynamic>? reason, VoidCallback? onSync, [AppLocalizations? l]) {
  final s = reason;
  if (s == null) return null;
  final built = s['built_for_day']?.toString();
  return StatusCard(
    l?.homeInsightsRebuildingTitle ?? 'Your cross-day insights are being rebuilt',
    switch (s['kind']) {
      'algo_version' => l?.homeInsightsRebuildingAlgoVersion ??
          'How these are computed changed with the last update.',
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

  const RingTrio({super.key, required this.d, this.onOpen, this.now});

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
      child: Column(children: [
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
        for (final r in gaps) ...[
          const SizedBox(height: S.x2),
          Divider(color: p.line, height: 1),
          _GapRow(r, onTap: _open(r.kind)),
        ],
        if (recoveryUpdatedLine(d.readinessUpdate, l) case final note?) ...[
          const SizedBox(height: S.x2),
          Text(note, style: F.cap.copyWith(color: p.ink3)),
        ],
        if (d.readiness.value != null && d.drivers.isNotEmpty) ...[
          const SizedBox(height: S.x3),
          Divider(color: p.line, height: 1),
          const SizedBox(height: S.x3),
          Pressable(
            onTap: _open(HomeRingKind.recovery),
            // Top-aligned: at an accessibility size the driver list is three
            // lines and "Why?" was centred against the middle of them.
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l?.homeWhyLabel ?? 'Why?', style: F.cap.copyWith(color: p.ink3)),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(
                  d.drivers
                      .take(3)
                      .map((e) => driverLabel(e['label'], l))
                      .join(' · '),
                  style: F.cap.copyWith(color: p.ink2),
                ),
              ),
              Icon(LucideIcons.chevronRight, size: 15, color: p.ink3),
            ]),
            ),
          ],
        ],
      ),
    );
  }

  VoidCallback? _open(HomeRingKind k) {
    final f = onOpen;
    return f == null ? null : () => f(k);
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

/// One ring's resolved state — the only place a metric becomes a shape.
class _RingState {
  final HomeRingKind kind;
  final String label, value, sub;
  final IconData icon;
  final Color color;

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
    this.frac,
    this.calibrating = false,
    this.have,
    this.need,
    this.why,
    this.provisional = false,
    this.arcs,
    this.estimated = false,
  });

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
            frac: v / 100,
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
              value: '${v.round()}', sub: band.label, frac: v / 100);
    case HomeRingKind.strain:
      final v = d.strain.value;
      // 0–21 is the scale's own ceiling, not a target invented here.
      return v == null
          ? _gap(k, l?.homeRingStrain ?? MetricLabels.strain, LucideIcons.zap, C.purple,
              d.strain, l?.homeRingNoStrain ?? 'No strain', l, unit: 'days')
          : _RingState(k, l?.homeRingStrain ?? MetricLabels.strain, LucideIcons.zap, C.purple,
              value: v.toStringAsFixed(1), sub: l?.homeStrainOf21 ?? 'of 21', frac: v / 21);
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
      // THE PIPELINE'S REASON FIRST. A sentence written here by someone who
      // never saw the day is the fallback, and where there is neither the ring
      // says it does not know rather than guessing a cause.
      why: whyFromNote(m.note, unit: unit) ??
          (fallbackWhy.isNotEmpty
              ? fallbackWhy
              : (l?.homeGapNoReason ?? 'Nothing recorded says why this is missing.')));
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
                stroke: stroke, t: animate(c, 1))
            : Ring(r.frac ?? 0, r.arc(p), p.track,
                stroke: stroke, t: animate(c, 1), solid: r.measured),
      ),
      Icon(r.icon, size: icon, color: r.ink(p)),
    ]);
  }
}

/// The default: three across, the number under the ring rather than inside it.
/// Inside is where a duration overflows its own circle at the first
/// accessibility step, and nothing about "7h 45m" gets shorter.
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

class _RingText extends StatelessWidget {
  final _RingState r;
  final TextAlign align;

  const _RingText(this.r, {required this.align});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final cross = align == TextAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    return Column(crossAxisAlignment: cross, children: [
      Text(r.label.toUpperCase(),
          style: F.over.copyWith(color: p.ink3), textAlign: align),
        const SizedBox(height: S.x1),
        // Absent reads as words, never as a dash and never as a zero — so it
        // takes the sentence weight rather than the numeral one. An estimate
        // is a number too, set in numerals.
        Text(
          presentationText(AppLocalizations.of(c), r.value),
          style: r.showsNumber
              ? F.n24.copyWith(color: r.provisional ? p.ink3 : p.ink)
              : F.body.copyWith(color: p.ink2),
          textAlign: align,
        ),
        if (r.sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            presentationText(AppLocalizations.of(c), r.sub),
            style: F.cap.copyWith(color: p.ink3),
            textAlign: align,
          ),
        ],
      ],
    );
  }
}

/// WHY a ring is empty, on the row that also opens the screen which can say
/// more about it. The three parts of a [StatusCard] — what is missing, why,
/// what to do about it — at the size a home screen can afford to spend on an
/// absence.
class _GapRow extends StatelessWidget {
  final _RingState r;
  final VoidCallback? onTap;

  const _GapRow(this.r, {this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(r.icon, size: 15, color: p.ink3),
            const SizedBox(width: S.x2),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                TextSpan(
                    text: '${r.label} · ',
                    style: F.cap.copyWith(
                        color: p.ink2, fontWeight: FontWeight.w600)),
                    TextSpan(
                      text: presentationText(
                        AppLocalizations.of(c),
                        r.why ?? '',
                      ),
                      style: F.cap.copyWith(color: p.ink3),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: S.x2),
            Icon(LucideIcons.chevronRight, size: 15, color: p.ink3),
          ],
        ),
      ),
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
  });

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
      strain: metricOf(strain['strain']),
      steps: metricOf(strain['steps']),
      calories: metricOf(strain['calories']),
      caloriesTotal: metricOf(strain['calories_total']),
      sleepMin: metricOf(sleep['duration_min']),
      sleepNeedMin: coach?.need ?? Metric.empty,
      sleepStages: sleepStagesOf(sleep),
      stepGoal: (profile['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal,
      pendingActivities: pending.count,
      pendingActivitiesFailed: pending.failed,
    );
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
    final today = await (stored ? repo.getTodayStored() : repo.getToday());
    final cd = await repo.getInsights();
    final profile = await repo.getProfile();

    final daily = today['daily'];
    final sleep = today['sleep'];
    Object? d(String k) => daily is Map ? daily[k] : null;
    Object? s(String k) => sleep is Map ? sleep[k] : null;

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

    final sleepMin = overnightMetric(today, s('duration_min'), l);

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
    final head = todayHeadlineOf(today);
    final recoveryState = head['recovery_state'] as String?;
    final readiness = recoveryState == 'provisional'
        ? metricOf(d('readiness_provisional'))
        : overnightMetric(today, d('readiness'), l);
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
      readinessUpdate: (head['recovery_update'] as Map?)?.cast<String, dynamic>(),
      drivers: [
        for (final e in (gbDrivers is List ? gbDrivers : const []))
          if (e is Map) e.cast<String, dynamic>(),
      ],
      strain: metricOf(d('strain')),
      sleepMin: sleepMin,
      sleepStages: stages,
      learnedOnsetMin: learned.onsetMin,
      learnedWakeMin: learned.wakeMin,
      rhr: overnightMetric(today, d('resting_hr'), l),
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
    );
  }
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
    with RevisionReload, WidgetsBindingObserver {
  HomeData? _d;
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
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _armTick();
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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
    _latency.revisionBumped();
    _refresh.reset();
    _refreshGaveUp = false;
    _load();
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
      final d = day == null || day == todayLabel()
          ? await HomeData.load(repo, l, true)
          : await HomeData.loadForDay(repo, day, l);
      final days = await repo.availableDays();
      if (stillNewest(#home, t)) {
        setState(() => (_d = d, _days = days, _loading = false, _failed = false));
        _recordRender();
        _refresh.afterPaint(repo, d.refreshPending).then((landed) {
          if (!mounted) return;
          if (landed) {
            _load();
          } else if (d.refreshPending) {
            setState(() => _refreshGaveUp = true);
          }
        });
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

  /// The "nothing derived yet" card, upgraded with the one thing it used to
  /// withhold: whether anything is actually happening right now. This is the
  /// LAST mile only — the backlog landed, but this screen is still bare because
  /// the heavy derive it depends on has not finished. Without it the card would
  /// flash back to a bare "Nothing derived yet" for the minute or so a full
  /// sleep-stage + spectra pass takes.
  ///
  /// It does NOT say "syncing" or "connecting" any more, and it has no sync
  /// button: the sync status line in the greeting header ([HomeSyncStatus])
  /// owns all of that, from the one SyncCoordinator state. This card used to read a second busy flag
  /// (`syncingNow`) plus a 20 s tap latch of its own, which is how Home showed
  /// two sync controls that disagreed about whether a sync was running.
  ///
  /// Valid whether or not [HomeData] itself has loaded yet, which is why it does
  /// not take one. Returns null when no derive is in flight, so the caller falls
  /// through to its own "nothing yet" copy.
  Widget? _phaseStatusCard(BuildContext c, AppLocalizations? l) {
    if (!derivingOf(c)) return null;
    return StatusCard(
      l?.homeAnalyzingTitle ?? 'Crunching last night\'s numbers',
      l?.homeAnalyzingBody ?? 'The data is in — sleep, recovery and strain '
          'are next.',
      leading: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: P.of(c).ink3),
      ),
    );
  }

  Widget _bareStatusCard(BuildContext c, HomeData d, AppLocalizations? l,
      {required bool pastDay}) {
    // A PAST day with nothing on it is a settled fact, not a sync problem —
    // "Sync the band" and the derive-phase cards below are both about THIS
    // install's live pipeline catching up, which has nothing to do with a day
    // the switcher stepped back onto.
    if (pastDay) {
      return const StatusCard(
        'No data for this day',
        'Nothing was recorded on this day.',
        fix: '',
        icon: LucideIcons.calendarOff,
      );
    }
    final phase = _phaseStatusCard(c, l);
    if (phase != null) return phase;

    return StatusCard(
      d.heldOverNight == null
          ? (l?.homeNothingDerivedTitle ?? 'No nights scored yet')
          : (l?.homeNothingTodayTitle ?? 'Nothing recorded for today'),
      d.heldOverNight == null
          ? (l?.homeNothingDerivedBody ?? 'Wear the band tonight and open the app in the morning.')
          : (l?.homeNothingTodayBody(prettyDay(d.heldOverNight, l)) ??
              'The last night this app scored was '
                  '${prettyDay(d.heldOverNight, l)}. Nothing has reached it since.'),
      // No button: Home's sync status line (greeting header) owns Sync now.
      icon: LucideIcons.watch,
    );
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
    final d = _d;
    final g = _greeting(widget.hour ?? DateTime.now().hour, l);

    if (d == null) {
      return _refreshable(ListView(padding: pad, children: [
        const SizedBox(height: S.x4),
        ?_naturalWakeCard(c),
        ?snoozeCardFor(c),
        ?momentFollowUpCard(c),
        // No day on screen ⇒ no `todayId`, so this renders the dated form.
        // Shown here TOO: a first run, a failed read and a sync in flight are
        // exactly when "how far are we?" is worth answering, and the header
        // this line normally sits under does not exist on this path. It is
        // also where Sync now lives, so a failed load can still be retried.
        syncedThroughLine(c, null, l),
        // The connection and battery live on AppState.device, independent of
        // HomeData — a load failure or first run must not hide them too.
        // A start-aligned Column, the wrapper the loaded header gives it, not
        // an Align: same box on screen, and the line keeps its identity when
        // the day lands instead of reading as a new line while another one
        // further down takes over its slot.
        if (connectionLine(c, l) case final conn?) ...[
          const SizedBox(height: 2),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [conn]),
        ],
        const SizedBox(height: S.x3),
        // Not while the first read is out: the card reads its own count, and
        // landing above the loading row would push it down. The loaded paths
        // below hand it the count read with the day.
        if (!_loading) const DetectedActivitiesCard(),
        if (_loading)
          const InlineLoading()
        else if (_failed)
          StatusCard(
            l?.homeLoadFailedTitle ?? 'Today could not be read',
            l?.homeLoadFailedBody ??
                'The stored day failed to load. Nothing was deleted — this is a '
                'read that went wrong, not missing data.',
            fix: l?.homeTryAgain ?? 'Try again',
            icon: LucideIcons.databaseZap,
            onFix: () {
              setState(() => (_loading = true, _failed = false));
              _load();
            },
          )
        else
          Builder(builder: (c) {
            final phase = _phaseStatusCard(c, l);
            if (phase != null) return phase;
            return StatusCard(
              l?.homeNothingDerivedTitle ?? 'No nights scored yet',
              l?.homeNothingDerivedBody ?? 'Wear the band tonight and open the app in the morning.',
              // No button: Home's sync status line owns Sync now.
              icon: LucideIcons.watch,
            );
          }),
        if (!_loading && !_failed && widget.data == null) ...[
          const SizedBox(height: S.x3),
          firstWeekCard(c, days: _days.length, strainScored: false),
        ],
        // The alarm lives on AppState too, so a load failure must not hide it.
        if (_day == null || _day == todayLabel())
          if (alarmArmOfContext(c) case final (DateTime?, AlarmArmState) a) ...[
            const SizedBox(height: S.x3),
            alarmDoor(c, a.$1, a.$2),
          ],
      ]));
    }

    // Nothing measured at all. It used to be reachable ONLY by a load throwing
    // — a real first-run user got four stacked absence cards instead of the one
    // card written for this state.
    //
    // It is now also where a day of NO WEAR lands, because the overnight block
    // no longer borrows an older night to fill the rings with. Those are two
    // different days and the copy below splits them on the one fact that tells
    // them apart: whether this install has ever scored a night. "No band
    // recordings processed yet" said to someone with three months of history is
    // the first-run answer to a gap, and it is wrong.
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
    // false empty state, and the cards it brings would leave when the figures
    // land and move everything under them.
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

    // No sync button on this card either: Home's one sync control is the
    // only place Home starts a sync.
    final stale = staleInsightsCard(d.insightsStale, null, l);
    // Above the greeting, not below it: if the app had to rebuild the database
    // to start, that outranks anything else this screen has to say today.
    final rebuilt = dbRebuiltCard(dbRebuildOf(c), l);

    // The width the button takes at row 1's right end (a Pressable is S.tap
    // wide), and the text above and below stops short of it. One button: the
    // coach moved to its own chip at the foot of the screen.
    final endInset = S.tap + HomeSyncStatus.endGap;

    return _refreshable(ListView(padding: pad, children: [
      ?rebuilt,
      // Natural Wake is buzzing and waiting for "I'm up": above everything.
      ?_naturalWakeCard(c),
      // A pending main-alarm snooze, with the same "I'm up".
      ?snoozeCardFor(c),
      ?momentFollowUpCard(c),

      // ── the one observation Home is allowed to make ──
      //
      // OUTSIDE the derived / not-derived split, and above the rings, for two
      // separate reasons. It outranks them: when this fires it is what matters
      // today, which is the question this screen answers, and under them it
      // would read as a footnote to three numbers. And it does not depend on
      // them — the watch comes off the CROSSDAY rollup, so it can carry a real
      // state on a morning whose own bundle has not derived yet, which is
      // exactly the morning you would most want to be told.
      ...?_bodyWatch(c, d, todayLabel(widget.now)),
      // ── greeting ──
      Padding(
        padding: const EdgeInsets.only(top: S.x3, bottom: S.x5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // The greeting stops short of the buttons: they are centred on row 1,
          // so their top overlaps the greeting's lower edge.
          Padding(
            padding: EdgeInsets.only(right: endInset),
            child: Row(children: [
              Flexible(
                child: Text(
                  d.name == null || d.name!.isEmpty
                      ? g.word
                      : '${g.word}, ${d.name}',
                  style: F.t2.copyWith(color: p.ink),
                ),
              ),
              const SizedBox(width: S.x2),
              Icon(g.icon, size: 17, color: p.on(g.color)),
            ]),
          ),
          const SizedBox(height: 2),
          // The first row under the greeting is the sync row, and its centre
          // is the buttons' centre: the date when idle, the status or problem
          // while one shows. How far the band's data reaches is always said, on
          // the row below — "am I looking at today, or at last night?" used to
          // be answerable only by opening Profile > Devices. Time since the
          // last sync and Sync now are right-aligned on the sync row, just left
          // of the avatar. The row is a direct child of this Column: its tap
          // targets overhang the lines around it (see [HitOverhang]), and no
          // tighter ancestor may clip them.
          ...homeHeaderRows(
            c,
            todayId: d.dayId,
            date: prettyDay(d.dayId, l),
            endInset: endInset,
            l: l,
            // Profile is the same avatar every tab carries; the coach moved to
            // its own chip at the foot of the screen. While a sync runs the
            // avatar gives way to a spinner: same button, same size, same tap,
            // same on-colour. It is where the eye already is, and it leaves the
            // sync row to the status text.
            end: syncBusyOf(c)
                ? Pressable(
                    semanticLabel:
                        '${l?.homeProfileSettings ?? 'Profile and settings'}, syncing',
                    onTap: () => go(c, const MoreSettings()),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: p.fill(C.domHome)),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: p.inkOnFill),
                        ),
                      ),
                    ),
                  )
                : const ProfileAvatar(accent: C.domHome),
          ),
          // Its own line, not squeezed into the sync row: at accessibility text
          // sizes that row has no slack left, and `Expanded` would only shrink
          // the sync text into extra wrapped lines to make room rather than
          // ever actually overflow.
          if (connectionLine(c, l) case final conn?) ...[
            const SizedBox(height: 2),
            conn,
          ],
        ]),
      ),

      if (bare && !building) ...[
        _detectedActivities(d),
      ],
      ...dayNavRow(_day ?? d.dayId, _days, _goDay),
      // Stepped back through the record: one tap home.
      if (!isToday)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => _goDay(todayLabel()),
            child: Text(l?.homeBackToToday ?? 'Back to today'),
          ),
        ),
      // No in-flight card above the rings on an ordinary morning: it would
      // land and leave mid-read and move everything under it. The header's
      // sync row says a sync is running, and "As of" under the rings says a
      // number is being recalculated, both in space they already hold.
      //
      // The active wearable's day, cell by cell. Nothing on a WHOOP-only
      // install, nor when the screen is handed its data.
      if (widget.data == null)
        WearableCells(kHomeWearableRows, date: isToday ? null : _day),

      if (bare) ...[
        // A live workout holds derivation, so a bare day with a session open
        // is the hold at work, not a sync problem — see [workoutHoldCard].
        // Only for TODAY: a live workout right now says nothing about why a
        // PAST day the switcher stepped onto has nothing on it.
        if (building)
          const InlineLoading()
        else
          isToday && (widget.workoutLive ?? workoutLiveOf(c))
              ? workoutHoldCard(l)
              : _bareStatusCard(c, d, l, pastDay: !isToday),
        // The first morning is exactly when "when do I get numbers?" is
        // loudest.
        if (firstWeeks && !building) ...[
          const SizedBox(height: S.x3),
          firstWeekCard(c,
              days: _days.length,
              strainScored: false,
              recoveryNightsLeft: recoveryNightsLeft),
        ],
      ] else ...[
        // ── the three rings ──
        //
        // Recovery, strain and sleep, each a door into its own screen. They
        // render as long as ONE of them has something to draw — a trio of
        // empty circles says less than the one written absence below, and the
        // empty state is a DOOR, not a dead end. The pipeline records why
        // readiness came back absent on every day it does — which input was
        // missing, how many of your own nights are behind each one — and that
        // diagnostic used to go nowhere but a Firebase breadcrumb. It belongs
        // one tap away, on the Readiness screen: a wall of per-input
        // diagnostics on Home makes the app read as broken.
        if (RingTrio.has(ringData, now: widget.now))
          RingTrio(
            d: ringData,
            now: widget.now,
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
          )
        else
          Builder(builder: (c) {
            final need = needMessageFromNote(d.readiness.note);
            // readinessInputShortfallNote/readinessUnstableBaselineNote off
            // d.absentDiag are the SAME functions and the SAME stored
            // diagnostic readiness_detail.dart's banner uses — not a second,
            // independently-worded explanation — so this card and the detail
            // screen can never say two different things about the same
            // absence.
            final shortfall = need == null
                ? readinessInputShortfallNote(d.absentDiag) ??
                    readinessUnstableBaselineNote(
                        d.absentDiag?['note']?.toString())
                : null;
            return StatusCard(
              l?.homeReadinessNotScoredTitle ?? 'Recovery is not scored today',
              need != null
                  ? (l?.homeReadinessNeedBody(need) ??
                      '$need to know what normal looks like for you.')
                  // Was "Needs a night of beat-to-beat data, plus your own
                  // history to compare it to" — a cause, stated for every
                  // absence the note convention did not cover. The door below
                  // is what actually answers it.
                  : shortfall ??
                      whyFromNote(d.readiness.note) ??
                      (l?.homeReadinessNoReason ?? 'Nothing recorded says why.'),
              fix: l?.homeSeeWhatWasMissing ?? 'See what was missing',
              icon: LucideIcons.batteryCharging,
              onFix: () => go(c, const ReadinessDetail()),
            );
          }),
        _homeAsOf(c, d),

        // Right under the rings, above everything else — the one spot on
        // this screen nobody scrolls past without seeing. A failed gesture
        // comes first: the newest undismissed one, one card at a time.
        if (gestureFailuresOf(c) case final failures?)
          GestureFailureCard(store: failures),
        const SizedBox(height: S.x3),
        _detectedActivities(d),
        const CommunityNudge(),

        // ── the rollup was withheld, not absent ──
        if (stale != null) ...[const SizedBox(height: S.x3), stale],

        // ── at a glance ──
        // First, in the first weeks too: resting HR, steps and the night's
        // sleep are real from night one, so they lead and the "what arrives
        // when" card follows them.
        Section(l?.homeAtAGlance ?? 'At a glance',
            _glance(c, d, isToday: isToday)),
        if (firstWeeks) ...[
          const SizedBox(height: S.x3),
          firstWeekCard(c,
              days: _days.length,
              strainScored: !d.strain.isEmpty,
              recoveryNightsLeft: recoveryNightsLeft),
        ],

        // ── today's plan: only what the app can actually stand behind ──
        // Skipped on a past day — "3,000 steps left" or "aim for 11.4
        // strain" about a day already over is an instruction, not a fact.
        if (isToday)
          Section(l?.homeTodaysPlan ?? "Today's plan", _plan(c, p, d)),

        // ── the way into the whole day ──
        //
        // A DOOR, NOT A CARD, and that is what keeps it on the right side of
        // the law at the top of this file. It shows no number, previews no
        // shape and makes no observation — it names a place and goes there.
        // Home decides; the day view is where you go to look, and until this
        // row existed the only ways in were two screens deep.
        const SizedBox(height: S.x5),
        detailLinkRow(c, LucideIcons.chartGantt,
            l?.homeBreakdownTitle ?? 'Breakdown of your day',
            l?.homeBreakdownSubtitle ?? 'Hour by hour',
            () => go(c, DayTimelineScreen(day: _day))),
      ],

      // ── the next alarm: a door, same as the one above ──
      // Only on a bare day: otherwise it is a tile in "At a glance", and the
      // same alarm twice on one screen is one too many.
      if (isToday && bare && !building)
        if (alarmArmOfContext(c) case final (DateTime?, AlarmArmState) a) ...[
          const SizedBox(height: S.x3),
          alarmDoor(c, a.$1, a.$2),
        ],
      // The coach, set up or not, on every ordinary or bare today. Not while
      // today is building: the figures landing above would push it down.
      if (isToday && !building) ...[
        const SizedBox(height: S.x4),
        coachChip(c),
      ],
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
    final zAbs = z == null ? '' : z.abs().toStringAsFixed(1);

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
                'Your resting heart rate has run above your usual over recent nights. This tracks one signal, so it shows a pattern, not a cause.')
            : (z >= 0
                ? (l?.homeIllnessBodyAbove(zAbs) ??
                    'Recent nights put your resting heart rate above your usual. That night was $zAbs× your normal night-to-night swing above it. A pattern, not a cause.')
                : (l?.homeIllnessBodyBelow(zAbs) ??
                    'Recent nights together put your resting heart rate above your usual, even though that night on its own was $zAbs× your normal night-to-night swing below it. A pattern, not a cause.')),
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
    final absent = <StatusCard>[];

    void add(Metric m, Widget Function() card, StatusCard? Function() gap) {
      if (m.isEmpty) {
        final s = gap();
        if (s != null) absent.add(s);
      } else {
        cards.add(card());
      }
    }

    // Resting heart rate comes off the SAME overnight block readiness does,
    // and it used to carry a date on its own line for the mornings that block
    // was held over from an older night. It cannot be an older night any more
    // — the loader refuses those — so every tile in this row is today's and
    // none of them needs a date.

    // Sleep is a RING now, duration and all — the card here was the same
    // number twice on one screen, and the ring is the one that says what the
    // duration was measured against.
    add(
      d.rhr,
      () => SignalCard(LucideIcons.heart, C.red, l?.homeHeartRate ?? 'Heart rate',
          '${d.rhr.value!.round()}',
          unit: 'bpm',
          sub: l?.homeRestingSub ?? 'Resting',
          onTap: () => go(c, const MetricDetail('resting_hr'))),
      // "no sleep was recorded" was stated as fact, unconditionally — and it
      // was rendered directly beside a Sleep card showing that night's
      // duration. Sleep duration and nocturnal RHR are gated separately: a
      // night staged from the accelerometer with no clean resting window
      // produces exactly that pair.
      // The else-branch used to name the gate — "no stretch of beats clean
      // enough" — which is one of several reasons a scored night yields no
      // resting rate, picked by a human writing copy. Only the branch the
      // screen can actually see is stated; the other defers to the note, or to
      // saying it does not know.
      () => StatusCard.forMetric(l?.homeNoRestingHr ?? 'No resting heart rate', d.rhr,
          why: d.sleepMin.isEmpty
              ? (l?.homeNoRestingHrWhy ??
                  'Resting heart rate is read from sleep, and no sleep was recorded.')
              : ''),
    );
    // Steps keeps its tile whether or not a counter reported. Zero steps is a
    // real reading — an unmoved counter — and it renders as 0, not as absence.
    // When nothing counted at all the tile stays and says so in two words,
    // rather than the whole card being replaced by a paragraph about wrist
    // motion: the answer to "how many steps" is short either way.
    cards.add(SignalCard(
      LucideIcons.footprints,
      C.green,
      l?.homeSteps ?? MetricLabels.steps,
      d.steps.value == null ? (l?.homeStepsNone ?? 'None') : thousands(d.steps.value),
      // The sensor rides the line that is already there rather than adding a
      // row: the day is resolved per window now, so "8,412" can be the strap's
      // count, the phone's, or both, and the card has to say which. The split
      // behind a mixed day is on Nerd stats, one tap down.
      sub: d.steps.value == null
          ? (l?.homeStepsNotRecorded ?? 'NOT RECORDED')
          : [
              if (d.stepGoal > 0)
                l?.homeStepsPercentGoal(
                        ((d.steps.value! / d.stepGoal) * 100).clamp(0, 999).round()) ??
                    '${((d.steps.value! / d.stepGoal) * 100).clamp(0, 999).round()}% of goal',
              ?stepSensorLabel(d.steps, l),
            ].join(' · '),
      onTap: () => go(c, const MetricDetail('steps')),
      trailing: d.steps.value == null || d.stepGoal <= 0
          ? null
          : SizedBox(
              width: 20,
              height: 20,
              child: CustomPaint(
                painter: Ring(d.steps.value! / d.stepGoal, C.green,
                    P.of(c).track,
                    stroke: 3, solid: true),
              ),
            ),
    ));
    add(
      d.calories,
      () => SignalCard(LucideIcons.flame, C.orange, l?.homeActiveEnergy ?? 'Active energy',
          thousands(d.calories.value),
          unit: 'kcal',
          sub: d.caloriesTotal.value == null
              ? (l?.homeCaloriesEstimated ?? 'Estimated')
              : (l?.homeCaloriesTotal(thousands(d.caloriesTotal.value)) ??
                  '${thousands(d.caloriesTotal.value)} total'),
          onTap: () => go(c, const MetricDetail('calories'))),
      // No `why:`. It said "Needs your weight and age" — and the measured run
      // printed that to a profile carrying both, because energy had gone absent
      // for an entirely different reason that the card never asked for.
      () => StatusCard.forMetric(l?.homeNoEnergyEstimate ?? 'No energy estimate', d.calories),
    );
    // The next alarm is not a reading of the day, so only today carries it —
    // "Tomorrow 07:30" under a day already over would be about a different day.
    if (isToday) {
      if (alarmArmOfContext(c) case final (DateTime?, AlarmArmState) a) {
        cards.add(alarmGlanceCard(c, a.$1, a.$2));
      }
    }

    return Column(children: [
      for (var i = 0; i < cards.length; i += 2) ...[
        if (i > 0) const SizedBox(height: S.x3),
        // IntrinsicHeight, because `stretch` inside a ListView asks for an
        // infinite height. The two cards in a row must match: a short card
        // beside a tall one reads as a layout bug, not as less data.
        // An odd last card takes the whole width rather than half of it with a
        // hole beside it. Three cards is the ordinary count now that sleep is
        // a ring, so the gap would be there every day.
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
        // One card for everything missing, not one card each: a partial
        // night used to stack two or three absence cards and read as broken.
        if (absent.length == 1) ...[const SizedBox(height: S.x3), absent.single]
        else if (absent.length > 1) ...[
          const SizedBox(height: S.x3),
          StatusCard(
            l?.homeSomeDataMissingTitle ?? 'Some of today\'s data is missing',
            [
              for (final s in absent)
                [s.what, s.why, s.fix].where((t) => t.isNotEmpty).join('. '),
            ].join('\n'),
            icon: LucideIcons.circleDashed,
          ),
        ],
      ],
    );
  }


  Widget _plan(BuildContext c, P p, HomeData d) {
    final l = AppLocalizations.of(c);
    final rows = <Widget>[];

    final stepsLeft = d.steps.value == null
        ? null
        : (d.stepGoal - d.steps.value!).round();
    if (stepsLeft != null && stepsLeft > 0) {
      rows.add(_row(
          p,
          LucideIcons.footprints,
          C.green,
          l?.homeStepsLeft(thousands(stepsLeft)) ?? '${thousands(stepsLeft)} steps left',
          l?.homeMovement ?? 'Movement',
          l?.homeGoalSteps(thousands(d.stepGoal)) ?? 'Goal ${thousands(d.stepGoal)}',
          false));
    } else if (stepsLeft != null) {
      rows.add(_row(p, LucideIcons.footprints, C.green,
          l?.homeStepGoalMet ?? 'Step goal met',
          l?.homeMovement ?? 'Movement', l?.actionDone ?? 'Done', true));
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
    }

    final planBody = rows.isEmpty
        ? StatusCard.forMetric(l?.homeNoPlanTitle ?? 'No plan for today yet', d.sleepNeedMin,
                // "none are established yet" is the COLD-START reason, and it
                // is a wrong answer when the baselines exist and are being
                // withheld.
                why: d.insightsStale != null
                    ? (l?.homeNoPlanWhyStale ?? 'Your trends are being updated. This takes a minute after a sync.')
                    : (l?.homeNoPlanWhyNone ?? 'None are established yet.')) ??
            const SizedBox.shrink()
        : Surface(
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
          : cached?.oneLiner ?? (l?.homeBriefingSubtitleEmpty ?? 'Tap to write today\'s summary'),
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

/// What happens in the first weeks, with the counts the pipeline actually
/// gates on: sleep after the first night, strain once [quietHrrMinDays] earlier
/// days give it a resting level, recovery once [readinessCompositeMinBaseline]
/// earlier nights give it a normal range. Read from the analytics constants so
/// the card cannot drift from the gate.
Widget firstWeekCard(BuildContext c,
    {required int days, required bool strainScored, int? recoveryNightsLeft}) {
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  final strainDay = quietHrrMinDays + 1;
  final recoveryNight = readinessCompositeMinBaseline + 1;
  Widget step(bool done, String text) => Semantics(
        // The tick is drawn, so it is also said.
        label: done ? (l?.homeFirstWeekDone(text) ?? 'Done: $text') : text,
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x2),
          child: Row(children: [
            Icon(done ? LucideIcons.circleCheck : LucideIcons.circle,
                size: 18, color: done ? p.on(C.green) : p.ink3),
            const SizedBox(width: S.x3),
            Expanded(
                child: Text(text, style: F.body.copyWith(color: p.ink))),
          ]),
        ),
      );
  return Surface(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(l?.homeFirstWeekTitle ?? 'Your first weeks',
          style: F.head.copyWith(color: p.ink)),
      const SizedBox(height: S.x2),
      step(days > 0, l?.homeFirstWeekWear ?? 'Wear the band tonight'),
      step(days > 0,
          l?.homeFirstWeekSleep ?? 'Sleep: the morning after your first night'),
      step(strainScored,
          l?.homeFirstWeekStrain(strainDay) ?? 'Strain: from day $strainDay'),
      // The live countdown when the pipeline says how many nights are left;
      // the static "from night N" only before it has said anything.
      step(
          false,
          recoveryNightsLeft != null
              ? (l?.homeRecoveryStartsIn(recoveryNightsLeft) ??
                  'Recovery starts in $recoveryNightsLeft nights')
              : (l?.homeFirstWeekRecovery(recoveryNight) ??
                  'Recovery: from night $recoveryNight, once it knows your normal')),
      const SizedBox(height: S.x1),
      Text(l?.homeFirstWeekSoFar(days) ?? '$days days recorded so far',
          style: F.cap.copyWith(color: p.ink3)),
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
      : (l?.homeCoachSetUpChip ?? 'Ask questions about your data: set up the coach');
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
