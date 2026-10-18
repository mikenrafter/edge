// The weekly alarm schedule — pure occurrence math plus the thin engine
// orchestration that arms it, shared between AppState (foreground connect/
// sync) and background_sync.dart's headless drain, which has no AppState.
//
// [AlarmScheduleEntry.weekday] is 0=Mon..6=Sun — the same 0-indexed convention
// `workout_screen.dart` already uses for weekday array positions. This is a
// storage/UI indexing choice, not a replacement for `DateTime.weekday`
// (1=Mon..7=Sun), which every conversion below still goes through explicitly.

import '../ble/ble_state.dart' show AlarmBandWriter, AlarmConfirmation;
import '../wake/wake_settings.dart';

/// One weekday's slot in the schedule. Immutable — callers build a new one to
/// change a field.
class AlarmScheduleEntry {
  final int weekday; // 0=Mon..6=Sun
  final int hour;
  final int minute;
  final bool enabled;

  /// Smart Wake Window, minutes. 0 = off (the default — plain fixed-time
  /// alarm, unchanged behaviour). When > 0, `hour`:`minute` stays exactly what
  /// it always was — the band's own armed SET_ALARM, the hard fallback — and
  /// this is how much EARLIER than that the app may try an early buzz once it
  /// detects light sleep. It never moves, shortens, or cancels the fallback
  /// arm; see smart_wake.dart.
  ///
  /// LEGACY: superseded by [naturalWindowMinutes]. Kept (never dropped) so a
  /// rollback finds what it expects, and because it still drives the old
  /// light-sleep heuristic for users whose Smart Wake upgrade explanation is
  /// pending ([WakeUpgradeState.pending]).
  final int smartWindowMinutes;

  /// Natural Wake window, minutes before the must-be-up-by time (0 = off,
  /// 15..120 in steps of 15). Independent of [gradualWindowMinutes].
  final int naturalWindowMinutes;

  /// Gradual Wake window, minutes before the must-be-up-by time (0 = off).
  /// Never enabled by a migration.
  final int gradualWindowMinutes;
  final GradualPattern gradualPattern;
  final int gradualCadenceSec;

  const AlarmScheduleEntry({
    required this.weekday,
    required this.hour,
    required this.minute,
    this.enabled = true,
    this.smartWindowMinutes = 0,
    this.naturalWindowMinutes = 0,
    this.gradualWindowMinutes = 0,
    this.gradualPattern = GradualPattern.ramp,
    this.gradualCadenceSec = kGradualCadenceDefaultSec,
  });

  AlarmScheduleEntry copyWith({
    int? hour,
    int? minute,
    bool? enabled,
    int? smartWindowMinutes,
    int? naturalWindowMinutes,
    int? gradualWindowMinutes,
    GradualPattern? gradualPattern,
    int? gradualCadenceSec,
  }) =>
      AlarmScheduleEntry(
        weekday: weekday,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        enabled: enabled ?? this.enabled,
        smartWindowMinutes: smartWindowMinutes ?? this.smartWindowMinutes,
        naturalWindowMinutes: naturalWindowMinutes ?? this.naturalWindowMinutes,
        gradualWindowMinutes: gradualWindowMinutes ?? this.gradualWindowMinutes,
        gradualPattern: gradualPattern ?? this.gradualPattern,
        gradualCadenceSec: gradualCadenceSec ?? this.gradualCadenceSec,
      );

  factory AlarmScheduleEntry.fromRow(Map<String, Object?> row) =>
      AlarmScheduleEntry(
        weekday: row['weekday'] as int,
        hour: row['hour'] as int,
        minute: row['minute'] as int,
        enabled: (row['enabled'] as int) != 0,
        smartWindowMinutes: (row['smart_window_minutes'] as int?) ?? 0,
        naturalWindowMinutes: (row['natural_window_minutes'] as int?) ?? 0,
        gradualWindowMinutes: (row['gradual_window_minutes'] as int?) ?? 0,
        gradualPattern: GradualPattern.parse(row['gradual_pattern']),
        gradualCadenceSec:
            (row['gradual_cadence_sec'] as int?) ?? kGradualCadenceDefaultSec,
      );

  /// The `alarm_schedule` row for this entry; the inverse of [fromRow].
  Map<String, Object?> toRow() => {
        'weekday': weekday,
        'hour': hour,
        'minute': minute,
        'enabled': enabled ? 1 : 0,
        'smart_window_minutes': smartWindowMinutes,
        'natural_window_minutes': naturalWindowMinutes,
        'gradual_window_minutes': gradualWindowMinutes,
        'gradual_pattern': gradualPattern.name,
        'gradual_cadence_sec': gradualCadenceSec,
      };

  @override
  bool operator ==(Object other) =>
      other is AlarmScheduleEntry &&
      other.weekday == weekday &&
      other.hour == hour &&
      other.minute == minute &&
      other.enabled == enabled &&
      other.smartWindowMinutes == smartWindowMinutes &&
      other.naturalWindowMinutes == naturalWindowMinutes &&
      other.gradualWindowMinutes == gradualWindowMinutes &&
      other.gradualPattern == gradualPattern &&
      other.gradualCadenceSec == gradualCadenceSec;

  @override
  int get hashCode => Object.hash(weekday, hour, minute, enabled,
      smartWindowMinutes, naturalWindowMinutes, gradualWindowMinutes,
      gradualPattern, gradualCadenceSec);

  @override
  String toString() =>
      'AlarmScheduleEntry(weekday: $weekday, hour: $hour, minute: $minute, '
      'enabled: $enabled, smartWindowMinutes: $smartWindowMinutes, '
      'naturalWindowMinutes: $naturalWindowMinutes, '
      'gradualWindowMinutes: $gradualWindowMinutes)';
}

/// The window whose lead time high-frequency collection must cover for [e]:
/// Natural once the upgrade explanation is settled, the legacy Smart window
/// while it is pending (that is the behaviour still running).
int collectionWindowMinutes(AlarmScheduleEntry e, WakeUpgradeState upgrade) =>
    upgrade == WakeUpgradeState.pending
        ? e.smartWindowMinutes
        : e.naturalWindowMinutes;

/// The armed alarm's collection window under [upgrade], or null when there is
/// no armed [epoch] or that weekday has no window. Same lookup as
/// [armedSmartWakeWindow], but follows Natural Wake instead of the legacy
/// Smart window once the upgrade is settled.
({DateTime windowEnd, int minutes})? armedCollectionWindow({
  required int? epoch,
  required List<AlarmScheduleEntry> schedule,
  required WakeUpgradeState upgrade,
}) {
  if (epoch == null) return null;
  final windowEnd = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
  final entry = schedule
      .where((e) => e.weekday == windowEnd.weekday - 1)
      .firstOrNull;
  if (entry == null) return null;
  final minutes = collectionWindowMinutes(entry, upgrade);
  if (minutes <= 0) return null;
  return (windowEnd: windowEnd, minutes: minutes);
}

/// The wake occurrence whose Natural window high-frequency collection must
/// serve, whether or not this process currently TRACKS an armed alarm.
///
/// [armedCollectionWindow] needs the armed epoch. That epoch is app state: it
/// is cleared when an alarm fires (and the fire event is routinely missed), by
/// a replayed band event, on a reinstall or a prefs wipe, and it is simply
/// absent until the first arm after a launch. In every one of those the user's
/// schedule still says "wake at T with a Natural window", the band is still (or
/// about to be) armed for T, and collection has to cover the window anyway.
/// So: a FUTURE armed epoch wins (it is what the band holds), otherwise the next
/// enabled occurrence of the schedule, searched the way the arm engine
/// searches ([armSearchFrom], so an acknowledged occurrence is not planned).
({DateTime windowEnd, int minutes})? plannedCollectionWindow({
  required int? epoch,
  required List<AlarmScheduleEntry> schedule,
  required WakeUpgradeState upgrade,
  DateTime? now,
  int? ackedThroughEpochSec,
}) {
  final at = now ?? DateTime.now();
  if (epoch != null && epoch * 1000 > at.millisecondsSinceEpoch) {
    return armedCollectionWindow(
        epoch: epoch, schedule: schedule, upgrade: upgrade);
  }
  final next =
      nextAlarmOccurrence(schedule, armSearchFrom(at, ackedThroughEpochSec));
  if (next == null) return null;
  return armedCollectionWindow(
      epoch: next.millisecondsSinceEpoch ~/ 1000,
      schedule: schedule,
      upgrade: upgrade);
}

/// Whether a smart-wake early-fire attempt should happen right now.
///
/// [windowEnd] is always the strap's own already-armed fallback alarm epoch —
/// this function only ever decides whether to TRY an early buzz inside
/// `[windowEnd - minutes, windowEnd)`. The fallback arm itself is never
/// touched by this decision, in either branch: true means "try now", false
/// means "not yet / already past / smart wake is off", and in every case the
/// band fires the real SET_ALARM at [windowEnd] regardless. That is the whole
/// safety guarantee — it is a property of what this function does NOT do.
bool inSmartWakeWindow({
  required DateTime windowEnd,
  required int minutes,
  required DateTime now,
}) {
  if (minutes <= 0) return false;
  final start = windowEnd.subtract(Duration(minutes: minutes));
  return !now.isBefore(start) && now.isBefore(windowEnd);
}

/// The currently-armed alarm's smart-wake window, or null when there's no
/// armed [epoch] or that weekday's slot has smart wake off
/// (`smartWindowMinutes <= 0`) — both cases mean "no window" to every caller,
/// same as [inSmartWakeWindow] returning false for `minutes <= 0`.
///
/// Extracted so `AppState._checkSmartWake` and
/// `HighFreqWakeWindow`'s callers share one lookup instead of each doing
/// their own weekday-entry matching.
({DateTime windowEnd, int minutes})? armedSmartWakeWindow({
  required int? epoch,
  required List<AlarmScheduleEntry> schedule,
}) {
  if (epoch == null) return null;
  final windowEnd = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
  final entry = schedule.firstWhere(
    (e) => e.weekday == windowEnd.weekday - 1,
    orElse: () =>
        AlarmScheduleEntry(weekday: 0, hour: 0, minute: 0, enabled: false),
  );
  if (entry.smartWindowMinutes <= 0) return null;
  return (windowEnd: windowEnd, minutes: entry.smartWindowMinutes);
}

/// The default slot for a weekday nobody has configured yet: 07:00, off. A
/// made-up ON default would arm a wake alarm nobody asked for; the honest
/// default is silence with a sensible time already dialled in.
const int defaultAlarmHour = 7;
const int defaultAlarmMinute = 0;

/// Exactly 7 entries, one per weekday, in weekday order (index == weekday). A
/// weekday absent from [stored] gets [defaultAlarmHour]:[defaultAlarmMinute],
/// disabled. This is the ONE place "unconfigured" and "configured but off"
/// are made to look the same to every caller (the UI always renders 7 rows;
/// [nextAlarmOccurrence] only ever sees a fully-populated list).
List<AlarmScheduleEntry> fillDefaultAlarmSchedule(
  List<AlarmScheduleEntry> stored,
) {
  final byWeekday = {for (final e in stored) e.weekday: e};
  return [
    for (var w = 0; w < 7; w++)
      byWeekday[w] ??
          AlarmScheduleEntry(
            weekday: w,
            hour: defaultAlarmHour,
            minute: defaultAlarmMinute,
            enabled: false,
          ),
  ];
}

/// The next enabled occurrence strictly after [now], or null when every
/// weekday is disabled (or [schedule] is empty). Wraps to next week when this
/// week's occurrence for a weekday has already passed.
///
/// CALENDAR arithmetic throughout (`DateTime(y, m, d + n, h, min)`), not
/// `Duration` multiples of a day — the same reasoning as
/// `AlarmScreenView.nextAt`: a `Duration(days: 7)` add is 168 ELAPSED hours,
/// which is a different wall-clock time across a DST change.
DateTime? nextAlarmOccurrence(List<AlarmScheduleEntry> schedule, DateTime now) {
  DateTime? best;
  for (final e in schedule) {
    if (!e.enabled) continue;
    final entryDow = e.weekday + 1; // DateTime.monday(1)..sunday(7)
    var daysAhead = (entryDow - now.weekday) % 7;
    if (daysAhead < 0) daysAhead += 7; // Dart's % can return negative
    var candidate =
        DateTime(now.year, now.month, now.day + daysAhead, e.hour, e.minute);
    // Strictly after `now` — the same instant is treated as past, so an
    // alarm never arms for "right now" (mirrors AlarmScreenView.nextAt).
    if (!candidate.isAfter(now)) {
      candidate =
          DateTime(now.year, now.month, now.day + daysAhead + 7, e.hour, e.minute);
    }
    if (best == null || candidate.isBefore(best)) best = candidate;
  }
  return best;
}

/// The instant to compute the re-arm from right after the alarm armed for
/// [firedEpoch] (unix sec) fired. The strap fires on its own RTC, which can
/// run a second or more ahead of the phone (whole-second drift, sub-tolerance
/// skew, crystal drift over a link that stays up all day), so the fire event
/// can land just BEFORE the slot on the phone's clock. Computing from plain
/// `now` then re-picks the slot that just fired and leaves the next day
/// unarmed. A fire within 30 s of the armed slot is that slot, so floor past
/// it. A fire well before the slot isn't that slot, so `now` stands. (A
/// RUN_ALARM buzz is event 58, which never reaches here: it doesn't consume
/// the armed slot.)
DateTime alarmRearmFrom(DateTime now, int? firedEpoch) {
  if (firedEpoch == null) return now;
  final slot = DateTime.fromMillisecondsSinceEpoch(firedEpoch * 1000);
  if (slot.difference(now) > const Duration(seconds: 30)) return now;
  final after = slot.add(const Duration(seconds: 1));
  return after.isAfter(now) ? after : now;
}

/// Result of [armNextScheduledOccurrence]. [epoch] is the newly-armed unix
/// instant, or null when nothing changed on the strap (no enabled day and
/// already unarmed, the target already matches what's armed, or the write
/// was refused/failed). [disabled] is true only when this call actively sent
/// DISABLE_ALARM because the schedule now has nothing enabled but the strap
/// still held a live arm — the case a caller must clear its own
/// persisted/optimistic epoch for. [refused] is true when a SET_ALARM was
/// attempted and the band did not take it (the write never left the phone, or
/// the strap answered no): the one case where "epoch is null" means failure
/// rather than "nothing to do".
typedef AlarmArmResult = ({int? epoch, bool disabled, bool refused});

/// Where the search for the next occurrence starts. Normally [now]; but after
/// the user explicitly acknowledged a wake and cancelled its native alarm
/// ([ackedThroughEpochSec], unix s), that occurrence must not be re-armed by
/// the next connect or sync, so the search starts just after it.
DateTime armSearchFrom(DateTime now, int? ackedThroughEpochSec) {
  if (ackedThroughEpochSec == null) return now;
  final acked = DateTime.fromMillisecondsSinceEpoch(ackedThroughEpochSec * 1000);
  return acked.isBefore(now) ? now : acked.add(const Duration(seconds: 1));
}

/// Arms [engine] with the next scheduled occurrence, if one exists and it
/// differs from [currentArmedEpoch] (unix seconds) — the "don't hammer the
/// strap on every sync" rule. See [AlarmArmResult] for what's returned.
///
/// Pure I/O orchestration only: the occurrence math is [nextAlarmOccurrence],
/// tested independently with no engine, and the wire form is whatever
/// `engine.setAlarm` already sends (rev1 gen4 / gen5 rich — unchanged here).
Future<AlarmArmResult> armNextScheduledOccurrence({
  required AlarmBandWriter engine,
  required List<AlarmScheduleEntry> schedule,
  required int? currentArmedEpoch,
  DateTime? now,
  int? ackedThroughEpochSec,
}) async {
  final next = nextAlarmOccurrence(
      schedule, armSearchFrom(now ?? DateTime.now(), ackedThroughEpochSec));
  if (next == null) {
    // Nothing enabled. Toggling every weekday off individually (rather than
    // an explicit cancel-all) must not leave the strap holding its last arm
    // forever — nothing else in this flow ever tells the band to give it up.
    if (currentArmedEpoch == null) {
      return (epoch: null, disabled: false, refused: false);
    }
    await engine.disableAlarm();
    return (epoch: null, disabled: true, refused: false);
  }
  final epoch = next.millisecondsSinceEpoch ~/ 1000;
  if (epoch == currentArmedEpoch) {
    return (epoch: null, disabled: false, refused: false);
  }
  final armed = await engine.setAlarm(next);
  if (armed == null) return (epoch: null, disabled: false, refused: true);
  return (
    epoch: armed.millisecondsSinceEpoch ~/ 1000,
    disabled: false,
    refused: false
  );
}

/// The weekday/hour/minute a legacy single-alarm epoch maps onto, for the
/// one-time 49→50 seed (see AppState._seedAlarmScheduleFromLegacyEpoch).
/// [epoch] is unix seconds, LOCAL wall-clock time is what the user saw when
/// they set it, so this reads `DateTime.fromMillisecondsSinceEpoch` in local
/// time (not UTC) and maps `DateTime.weekday` (1=Mon..7=Sun) to the 0-indexed
/// column via `- 1`.
AlarmScheduleEntry seedEntryFromLegacyEpoch(int epoch) {
  final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
  return AlarmScheduleEntry(
    weekday: at.weekday - 1,
    hour: at.hour,
    minute: at.minute,
    enabled: true,
  );
}

/// Whether the alarm armed for [armedEpochSec] fires during tonight's
/// upcoming overnight sleep, as measured from [now]. TRUE iff the epoch is
/// non-null, strictly after [now], not before noon of [now]'s date, AND
/// strictly before noon of the day after [now]'s calendar date — the window covering the whole overnight sleep
/// ahead, whether the arm lands later tonight or in the small hours of
/// tomorrow morning. An epoch already past, or one two-or-more nights out, is
/// not "tonight". Calendar-date comparison of the two DateTimes is
/// deliberately not used: a wake alarm armed for tomorrow morning is tonight's
/// alarm even though its date differs from today's.
///
/// Pure — no AppState/DB/engine deps — so the 7pm "no alarm tonight" check can
/// be unit-tested without a clock or a strap.
///
/// CALENDAR arithmetic for the window boundary (`DateTime(y, m, d + 1, 12, 0)`),
/// not a `Duration` of hours — the same DST reasoning as [nextAlarmOccurrence]
/// above: noon tomorrow is a wall-clock instant, not 36 elapsed hours.
bool alarmArmsTonight(int? armedEpochSec, DateTime now) {
  if (armedEpochSec == null) return false;
  final at = DateTime.fromMillisecondsSinceEpoch(armedEpochSec * 1000);
  if (!at.isAfter(now)) return false;
  // Before noon the alarm still ahead is THIS morning's, not tonight's: opened
  // at 06:30, a 07:00 alarm would otherwise cancel the 7pm check for a night
  // that may have none.
  if (at.isBefore(DateTime(now.year, now.month, now.day, 12))) return false;
  final endOfTonight = DateTime(now.year, now.month, now.day + 1, 12, 0);
  return at.isBefore(endOfTonight);
}

/// Whether the latch-failure safety notification should fire for [epoch]: the
/// toggle is on, [epoch] is STILL the confirmation machine's current target (a
/// newer arm, or a cancel, superseded it), and the strap never confirmed it.
/// Pure — no notification plumbing, no clock reads — so the decision itself is
/// unit-testable without a fake OS notification sink.
bool alarmLatchFailed(AlarmConfirmation a, int epoch, {required bool enabled}) =>
    enabled && a.targetEpoch == epoch && !a.confirmed;

/// When the grace timer fires after a SET. With the auto-retry still to come it
/// fires just BEFORE the window closes, so the retry reopens "waiting" without
/// the row flashing "not confirmed" in between; the last window fires just
/// after it closes, so the UI rebuild lands on the warning.
Duration alarmGraceTimerDelay(int graceMs, {required bool retryLeft}) =>
    Duration(milliseconds: retryLeft ? graceMs - 250 : graceMs + 250);

/// Headless half of the grace window: no AppState timer to catch a late
/// ALARM_SET (56), so poll [latched] once a second for as long as the
/// foreground would wait. True as soon as it latches, false once the window
/// closes.
Future<bool> awaitAlarmLatch(Future<bool> Function() latched,
    {int graceMs = AlarmConfirmation.kDefaultGraceMs}) async {
  for (var waited = 0; waited < graceMs; waited += 1000) {
    await Future.delayed(const Duration(seconds: 1));
    if (await latched()) return true;
  }
  return false;
}

/// How long after the last grace window before the critical "alarm not
/// confirmed" alert goes out. Still connected = the strap may just be slow
/// (event 56 can lag by minutes, and a late one still confirms), so hold the
/// alert back; disconnected = nothing more can arrive, alert now.
Duration alarmLatchAlertDelay({required bool connected}) =>
    connected ? const Duration(minutes: 5) : Duration.zero;

/// When the critical "alarm not confirmed" alert is due for an arm made at
/// [armedAtMs]: both grace windows (first try + the one retry) plus the
/// connected hold. Persisted at arm time so a relaunch can still send it.
int alarmLatchAlertAtMs(int armedAtMs, int graceMs) =>
    armedAtMs +
    2 * graceMs +
    alarmLatchAlertDelay(connected: true).inMilliseconds;

/// After a relaunch, how long until the alert the dead process was holding
/// for [savedEpoch] goes out. [stored] is the persisted `[epoch, alertAtMs]`.
/// Null when there is nothing to resume: no stored hold, a different alarm,
/// already confirmed, or the alarm time itself has passed.
Duration? alarmLatchAlertResumeDelay(List<String>? stored,
    {required int? savedEpoch, required bool confirmed, required int nowMs}) {
  if (stored == null || stored.length != 2 || savedEpoch == null) return null;
  if (confirmed || int.tryParse(stored[0]) != savedEpoch) return null;
  if (savedEpoch * 1000 <= nowMs) return null;
  final alertAtMs = int.tryParse(stored[1]);
  if (alertAtMs == null) return null;
  return Duration(milliseconds: alertAtMs > nowMs ? alertAtMs - nowMs : 0);
}
