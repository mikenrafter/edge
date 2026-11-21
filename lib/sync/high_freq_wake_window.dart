import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/db.dart';
import '../state/control_operations.dart' show ExpectedSleepSchedule;
import '../wake/wake_stores.dart' show loadNaturalWakeLead;
import '../wake/wake_settings.dart' show naturalCollectionLead;




/// The saved expected sleep schedule, read straight from preferences so a
/// headless run (no AppState) plans collection from the same value the
/// foreground does. Null when none is saved or the stored value is unreadable.
ExpectedSleepSchedule? loadSavedExpectedSleepSchedule(SharedPreferences prefs) {
  final raw = prefs.getString('expected_sleep_schedule_v1');
  if (raw == null) return null;
  try {
    return ExpectedSleepSchedule.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>());
  } catch (_) {
    return null;
  }
}

class HighFreqWakePlan {
  final bool shouldEnable;
  final DateTime? targetWake;
  final String source;
  final int sampleCount;

  /// How long the band is asked to keep prompting: [HighFreqWakeWindow.lease]
  /// by default, longer when a Natural Wake window needs its warm-up covered.
  final Duration lease;

  const HighFreqWakePlan({this.preSyncAt, 
    required this.shouldEnable,
    required this.targetWake,
    required this.source,
    required this.sampleCount,
    this.lease = HighFreqWakeWindow.lease,
  });


  /// Time at which the band prompt lease should start — [preSyncLead] before
  /// the smart-wake window opens — so the app wakes periodically and backfills
  /// `decoded_onehz` with the last ~3h of nocturnal data before the window
  /// opens. The smart-wake DETECTION still only runs inside the actual window
  /// (checked by `inSmartWakeWindow` in `_checkSmartWake`); this only extends
  /// the DATA COLLECTION lease, not the buzz window.
  ///
  /// Set whenever the plan has a target (habitual or scheduled), including
  /// before it opens and after it closed, so a caller can say when the lease
  /// will start. Null only when there is no plan at all (too little sleep
  /// history); [shouldEnable] says whether the lease applies right now.
  final DateTime? preSyncAt;

  /// The total duration the band prompt lease should cover: from [preSyncAt]
  /// (when set) or the shipped window start, until [targetWake]. Used by
  /// callers to compute the lease duration for `BandPromptRequest.smartWake`.
  ///
  /// The fallback uses this plan's lease, including the Natural Wake warm-up
  /// when its window exceeds the default.
  Duration? get effectiveLease {
    if (targetWake == null) return null;
    final start = preSyncAt ??
        targetWake!.subtract(lease);
    return targetWake!.difference(start);
  }

  /// The lease to hand the band when it is programmed at [now]: what is left
  /// until [targetWake], never more than [effectiveLease]. Programming the
  /// full [effectiveLease] on a late connect or refresh (after [preSyncAt])
  /// would keep the band prompting past the wake time.
  Duration? leaseFrom(DateTime now) {
    final full = effectiveLease;
    final target = targetWake;
    if (full == null || target == null) return null;
    final remaining = target.difference(now);
    if (remaining.isNegative) return Duration.zero;
    return remaining < full ? remaining : full;
  }
}

class HighFreqWakeWindow {
  /// The floor. A Natural Wake window longer than 30 minutes needs more: see
  /// [leaseFor].
  static const Duration lease = Duration(minutes: 90);

  /// Lead time for an armed window of [naturalMinutes] (0 = none): the window
  /// itself plus the causal stager's warm-up and a margin
  /// ([naturalCollectionLead]), never less than [lease]. 90 minutes cannot
  /// cover 120 + 20.
  static Duration leaseFor(int naturalMinutes) {
    if (naturalMinutes <= 0) return lease;
    final need = naturalCollectionLead(naturalMinutes);
    return need > lease ? need : lease;
  }
  static const int historyDays = 14;
  static const int minSamples = 3;

  /// [scheduledWindowEnd]/[scheduledWindowMinutes] are the currently-armed
  /// alarm's smart-wake window (see `alarm_schedule.armedSmartWakeWindow`),
  /// when known. They widen the lease to also cover an alarm set well before
  /// the habitual wake — e.g. a 05:30 alarm on a 07:30-habitual-wake person —
  /// which the habitual-only window used to miss entirely, starving
  /// `_checkSmartWake`'s "last 3 minutes" query of fresh `decoded_onehz` rows
  /// for the whole real window. Omitting them (every existing call site that
  /// hasn't been updated) keeps today's habitual-only behaviour byte-for-byte.
  static Future<HighFreqWakePlan> planNow({
    DateTime? now,
    DateTime? scheduledWindowEnd,
    int scheduledWindowMinutes = 0,
    ExpectedSleepSchedule? expectedSchedule,
  }) async {
    var effectiveWindow = scheduledWindowMinutes;
    if (scheduledWindowEnd != null && scheduledWindowMinutes > 0) {
      effectiveWindow += await loadNaturalWakeLead(scheduledWindowEnd, expectedSchedule);
    }
    final rows = await LocalDb.sleepWindowRows(historyDays);
    return planFromRows(
      rows,
      now ?? DateTime.now(),
      scheduledWindowEnd: scheduledWindowEnd,
      scheduledWindowMinutes: effectiveWindow,
      expectedSchedule: expectedSchedule,
    );
  }

  static HighFreqWakePlan planFromRows(
    List<Map<String, dynamic>> rows,
    DateTime now, {
    DateTime? scheduledWindowEnd,
    int scheduledWindowMinutes = 0,
    ExpectedSleepSchedule? expectedSchedule,
  }) {
    final lease = leaseFor(scheduledWindowMinutes);
    final wakeMinutes = <int>[];
    for (final row in rows) {
      final minute = _wakeMinuteOfDay(row);
      if (minute != null) wakeMinutes.add(minute);
    }

    HighFreqWakePlan? historyPlan;
    if (wakeMinutes.length >= minSamples) {
      wakeMinutes.sort();
      final habitualWakeMinute = wakeMinutes[wakeMinutes.length ~/ 2];
      final todayTarget = DateTime(
        now.year,
        now.month,
        now.day,
        habitualWakeMinute ~/ 60,
        habitualWakeMinute % 60,
      );
      // Calendar arithmetic, not a Duration(days: 1) add — that's exactly 24
      // elapsed hours, which lands an hour off across a DST transition.
      final targetWake = now.isAfter(todayTarget)
          ? DateTime(
              now.year,
              now.month,
              now.day + 1,
              habitualWakeMinute ~/ 60,
              habitualWakeMinute % 60,
            )
          : todayTarget;
      // The fork's Natural warm-up already includes a collection lead.
      // Cover main's 135-minute habit plan without adding that lead twice.
      final mainLease = HighFreqWakeWindow.lease + preSyncLead;
      final fullLease = lease > mainLease ? lease : mainLease;
      final preSyncAt = targetWake.subtract(fullLease);
      historyPlan = HighFreqWakePlan(
        shouldEnable: !now.isBefore(preSyncAt) && now.isBefore(targetWake),
        targetWake: targetWake,
        source: 'habitual_wake',
        sampleCount: wakeMinutes.length,
        preSyncAt: preSyncAt,
        lease: lease,
      );
    }

    // A saved expectation is collection planning only. It never creates a
    // measured night or automatically arms an alarm. Calendar construction
    // preserves the selected wall-clock time on either side of DST.
    //
    // It ADDS a window; it never takes one away. It used to REPLACE the
    // history-derived habitual plan, so the moment someone saved a schedule the
    // window their own measured nights had been collecting in went dark
    // whenever the schedule's wake differed from their habit. Both stand: if
    // either says "collect now", collect (the one ending later, so its lease
    // covers the longer span). With nothing enabled the schedule is the
    // reported plan, as before.
    HighFreqWakePlan? habitualPlan = historyPlan;
    if (expectedSchedule != null) {
      var window = expectedSchedule.windowFor(now);
      if (!now.isBefore(window.$2)) {
        window = expectedSchedule.windowFor(DateTime(now.year, now.month, now.day + 1));
      }
      final start = window.$2.subtract(lease);
      final schedulePlan = HighFreqWakePlan(
        shouldEnable: !now.isBefore(start) && now.isBefore(window.$2),
        targetWake: window.$2, source: 'expected_sleep_schedule', sampleCount: 0,
        lease: lease);
      if (historyPlan != null &&
          historyPlan.shouldEnable &&
          (!schedulePlan.shouldEnable ||
              historyPlan.targetWake!.isAfter(schedulePlan.targetWake!))) {
        habitualPlan = historyPlan;
      } else {
        habitualPlan = schedulePlan;
      }
    }

    // The scheduled-alarm window only takes over when the habitual window
    // isn't already covering `now` — habitual stays the reported source
    // whenever it alone would enable, matching pre-existing behaviour.
    //
    // "Covering" includes the END: a habitual/expected wake time earlier than
    // the alarm's window stops the band's prompt before the Natural Wake window
    // does, leaving the last stretch (where the early wake can fire) without
    // fresh rows until some later refresh. Then the alarm's window wins.
    final habitualCovers = habitualPlan != null &&
        habitualPlan.shouldEnable &&
        scheduledWindowEnd != null &&
        !(habitualPlan.targetWake?.isBefore(scheduledWindowEnd) ?? true);
    if (scheduledWindowEnd != null &&
        scheduledWindowMinutes > 0 &&
        !habitualCovers) {
      final preSyncAt = scheduledWindowEnd
          .subtract(Duration(minutes: scheduledWindowMinutes) + preSyncLead);
      final forkStart = scheduledWindowEnd.subtract(lease);
      final scheduledStart = forkStart.isBefore(preSyncAt) ? forkStart : preSyncAt;
      if (!now.isBefore(scheduledStart) && now.isBefore(scheduledWindowEnd)) {
        return HighFreqWakePlan(
          shouldEnable: true,
          targetWake: scheduledWindowEnd,
          source: 'scheduled_alarm',
          sampleCount: wakeMinutes.length,
          preSyncAt: scheduledStart,
          lease: lease,
        );
      }
    }

    return habitualPlan ??
        const HighFreqWakePlan(
          shouldEnable: false,
          targetWake: null,
          source: 'insufficient_sleep_history',
          sampleCount: 0,
        );
  }

  static int? _wakeMinuteOfDay(Map<String, dynamic> row) {
    final win = _decodeMap(row['window_json']);
    final env = win['value'];
    var offsetMs = ((env is Map ? env : win)['offset_ms'] as num?)?.toInt();
    if (offsetMs == null && row['payload_json'] != null) {
      final sleep = _asMap(_decodeMap(row['payload_json'])['sleep']);
      final sleepWindow = _asMap(sleep['window']);
      offsetMs = (_asMap(sleepWindow['value'])['offset_ms'] as num?)?.toInt();
    }
    if (offsetMs == null || offsetMs <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(offsetMs);
    return dt.hour * 60 + dt.minute;
  }

  static Map<String, dynamic> _decodeMap(Object? raw) {
    if (raw is Map) return raw.cast<String, dynamic>();
    if (raw is! String || raw.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return const <String, dynamic>{};
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is Map) return raw.cast<String, dynamic>();
    return const <String, dynamic>{};
  }


  /// Extra time the band prompt lease extends BEFORE the smart-wake window
  /// opens, so the app wakes periodically and backfills `decoded_onehz` with
  /// the last ~3h of nocturnal data. Without this, the 10th-percentile HR
  /// baseline (smart_wake v2, Q2) has no data to compute from when the window
  /// opens — the band was offline or the app was suspended all night.
  ///
  /// The band prompt is the ONLY reliable cross-platform wake mechanism at a
  /// specific wall-clock time (iOS BGTask/BGAppRefresh are opportunistic and
  /// never guaranteed; Android has no periodic background scheduler since the
  /// WorkManager tombstone). Extending the existing 61s prompt lease 45 min
  /// earlier costs ~45 extra BLE wake cycles per night — negligible battery
  /// impact, and it reuses infrastructure that already works.
  ///
  /// preSyncAt = targetWake − (lease + preSyncLead).
  static const Duration preSyncLead = Duration(minutes: 45);
}

