// wake_controller.dart — the view-model for the Natural Wake / Gradual Wake
// settings. THE UI PHASE BINDS TO THIS FILE; AppState owns one instance as
// `app.wake` (a ChangeNotifier — listen to it, or read it through Provider).
//
// Reading (all synchronous, after the first `await wake.reload()`; weekday is
// 0=Mon..6=Sun, the same as AlarmScheduleEntry):
//   naturalWindowMinutes(weekday)   0 = off, else 15..120 in steps of 15
//   naturalActive(weekday)          window > 0 AND the upgrade explanation is
//                                   settled — the value to show as "on"
//   gradualWindowMinutes(weekday)   0 = off, else 15..120 in steps of 15
//   gradualPattern(weekday)         GradualPattern.ramp | steady
//   gradualCadenceSeconds(weekday)  60..900 in steps of 60 (default 180)
//   configurationFor(weekday)       WakeConfiguration: neither | naturalOnly |
//                                   gradualOnly | both
//   upgradeState                    WakeUpgradeState: none | pending |
//                                   acknowledged
//   upgradeExplanationPending       true => show the Smart Wake -> Natural
//                                   Wake explanation BEFORE enabling anything
//   timelineAt(wakeAt)              WakeTimeline: exact parts in time order,
//                                   each marked bandNative / requiresPhone.
//                                   The 'fallback' part (native alarm at T,
//                                   band-native, no phone needed) is in every
//                                   configuration.
//   traceFor(wakeAt)                the persisted decision trace for that wake
//
// Writing (each validates, persists, notifies; invalid input throws
// ArgumentError, never silently clamps):
//   setNaturalWindow(weekday, minutes)
//   setGradualWindow(weekday, minutes)
//   setGradualPattern(weekday, pattern)
//   setGradualCadenceSeconds(weekday, seconds)
//   acknowledgeUpgrade({enableNatural = true})
//       The user has read the explanation. `true` lets the migrated Natural
//       windows start running; `false` switches them off. Never touches
//       Gradual Wake.
//   acknowledgeWake({cancelNative = false})
//       The user explicitly says "I'm up". Stops the remaining phone-driven
//       haptics. `cancelNative: true` additionally REQUESTS cancellation of
//       the native alarm; if that fails the alarm stays armed and the
//       returned WakeAckOutcome says so (fallbackArmed). Nothing else in the
//       app can cancel the alarm at T.
//
// Rules the UI should honour (see the design spec, "Wake model"):
//   * Setting a window never changes the alarm's hour/minute/enabled.
//   * Natural Wake is estimated REM, an autonomic estimate from the band's
//     heart-rate/motion data, not sleep staging; say "estimated".
//   * Natural Wake needs a connected phone and only applies to the main
//     sleep; naps never use it. Say which parts are band-native (the alarm at
//     T) and which need the phone (everything before T).
//   * `setScheduleDay(smartWindowMinutes:)` on AppState still exists for the
//     old row; new UI should use these setters instead.

import 'package:flutter/foundation.dart';

import '../state/alarm_schedule.dart';
import 'wake_orchestrator.dart';
import 'wake_settings.dart';

class WakeController extends ChangeNotifier {
  WakeController({
    required List<AlarmScheduleEntry> Function() schedule,
    required Future<void> Function(AlarmScheduleEntry entry) saveEntry,
    required Future<WakeUpgradeState> Function() loadUpgradeState,
    required Future<void> Function(WakeUpgradeState state) saveUpgradeState,
    required Future<WakeAckOutcome> Function(bool cancelNative) acknowledgeWake,
    required Future<List<WakeTraceEntry>> Function(DateTime wakeAt) traceFor,
  })  : _schedule = schedule,
        _saveEntry = saveEntry,
        _loadUpgradeState = loadUpgradeState,
        _saveUpgradeState = saveUpgradeState,
        _acknowledgeWake = acknowledgeWake,
        _traceFor = traceFor;

  final List<AlarmScheduleEntry> Function() _schedule;
  final Future<void> Function(AlarmScheduleEntry) _saveEntry;
  final Future<WakeUpgradeState> Function() _loadUpgradeState;
  final Future<void> Function(WakeUpgradeState) _saveUpgradeState;
  final Future<WakeAckOutcome> Function(bool) _acknowledgeWake;
  final Future<List<WakeTraceEntry>> Function(DateTime) _traceFor;

  WakeUpgradeState _upgrade = WakeUpgradeState.none;

  /// Re-read persisted state. Call after the schedule is (re)loaded.
  Future<void> reload() async {
    _upgrade = await _loadUpgradeState();
    notifyListeners();
  }

  // ── reading ──────────────────────────────────────────────────────────────

  WakeUpgradeState get upgradeState => _upgrade;
  bool get upgradeExplanationPending => _upgrade == WakeUpgradeState.pending;

  AlarmScheduleEntry _entry(int weekday) {
    _checkWeekday(weekday);
    return _schedule().firstWhere((e) => e.weekday == weekday);
  }

  int naturalWindowMinutes(int weekday) => _entry(weekday).naturalWindowMinutes;
  bool naturalActive(int weekday) =>
      naturalWindowMinutes(weekday) > 0 && !upgradeExplanationPending;
  int gradualWindowMinutes(int weekday) => _entry(weekday).gradualWindowMinutes;
  GradualPattern gradualPattern(int weekday) => _entry(weekday).gradualPattern;
  int gradualCadenceSeconds(int weekday) => _entry(weekday).gradualCadenceSec;

  WakeConfiguration configurationFor(int weekday) => wakeConfigurationOf(
      naturalMinutes: naturalActive(weekday) ? naturalWindowMinutes(weekday) : 0,
      gradualMinutes: gradualWindowMinutes(weekday));

  /// The exact schedule for the alarm resolving to [wakeAt] (an absolute
  /// instant; its LOCAL weekday picks the configured day).
  WakeTimeline timelineAt(DateTime wakeAt) {
    final weekday = wakeAt.toLocal().weekday - 1;
    return WakeTimeline.compute(
      wakeAt: wakeAt,
      naturalMinutes: naturalActive(weekday) ? naturalWindowMinutes(weekday) : 0,
      gradualMinutes: gradualWindowMinutes(weekday),
    );
  }

  Future<List<WakeTraceEntry>> traceFor(DateTime wakeAt) => _traceFor(wakeAt);

  // ── writing ──────────────────────────────────────────────────────────────

  Future<void> setNaturalWindow(int weekday, int minutes) =>
      _update(weekday, naturalWindowMinutes: _window(minutes));

  Future<void> setGradualWindow(int weekday, int minutes) =>
      _update(weekday, gradualWindowMinutes: _window(minutes));

  Future<void> setGradualPattern(int weekday, GradualPattern pattern) =>
      _update(weekday, gradualPattern: pattern);

  Future<void> setGradualCadenceSeconds(int weekday, int seconds) {
    if (!isValidGradualCadence(seconds)) {
      throw ArgumentError.value(seconds, 'seconds',
          'cadence is $kGradualCadenceMinSec..$kGradualCadenceMaxSec s in '
          '${kGradualCadenceStepSec}s steps');
    }
    return _update(weekday, gradualCadenceSec: seconds);
  }

  /// The user has read the Smart Wake -> Natural Wake explanation.
  Future<void> acknowledgeUpgrade({bool enableNatural = true}) async {
    if (!enableNatural) {
      for (final e in _schedule().where((e) => e.naturalWindowMinutes > 0)) {
        await _saveEntry(e.copyWith(naturalWindowMinutes: 0));
      }
    }
    await _saveUpgradeState(WakeUpgradeState.acknowledged);
    _upgrade = WakeUpgradeState.acknowledged;
    notifyListeners();
  }

  /// An explicit "I'm up". See the file header.
  Future<WakeAckOutcome> acknowledgeWake({bool cancelNative = false}) async {
    final out = await _acknowledgeWake(cancelNative);
    notifyListeners();
    return out;
  }

  // ── internals ────────────────────────────────────────────────────────────

  static void _checkWeekday(int weekday) {
    if (weekday < 0 || weekday > 6) {
      throw ArgumentError.value(weekday, 'weekday', '0=Mon..6=Sun');
    }
  }

  static int _window(int minutes) {
    if (!isValidWakeWindow(minutes)) {
      throw ArgumentError.value(minutes, 'minutes',
          '0 (off) or $kWakeWindowStepMinutes..$kWakeWindowMaxMinutes in '
          '$kWakeWindowStepMinutes-minute steps');
    }
    return minutes;
  }

  /// Validates synchronously (a bad weekday throws at the call), then saves.
  Future<void> _update(
    int weekday, {
    int? naturalWindowMinutes,
    int? gradualWindowMinutes,
    GradualPattern? gradualPattern,
    int? gradualCadenceSec,
  }) {
    final next = _entry(weekday).copyWith(
      naturalWindowMinutes: naturalWindowMinutes,
      gradualWindowMinutes: gradualWindowMinutes,
      gradualPattern: gradualPattern,
      gradualCadenceSec: gradualCadenceSec,
    );
    return _save(next);
  }

  Future<void> _save(AlarmScheduleEntry next) async {
    await _saveEntry(next);
    notifyListeners();
  }
}
