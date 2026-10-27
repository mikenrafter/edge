// wake_controller.dart — the view-model for the Natural Wake / Gradual Wake
// settings. SCREENS BIND TO THIS FILE; AppState owns one instance as
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
// ArgumentError, never silently clamps). NONE of these writes the band: this
// class has no band access, and the saveEntry it is given only stores the row.
// Natural and Gradual are phone-orchestrated; only the fixed alarm at T is ever
// stored on the band, and that is armed by AppState, once per alarm-screen Save.
// (The alarm screen edits a draft and stores the whole week in one transaction
// instead of calling these per row; they remain for other callers.)
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
//   * Natural Wake buzzes when the sleeper is NOT in light or deep sleep
//     (estimated REM, or awake), an autonomic estimate from the band's
//     heart-rate/motion data, not sleep staging; say "estimated".
//   * Natural Wake needs a connected phone and only applies to the main
//     sleep; naps never use it. Say which parts are band-native (the alarm at
//     T) and which need the phone (everything before T).
//   * `setScheduleDay(smartWindowMinutes:)` on AppState still exists for the
//     old row and for programmatic callers (Siri); the alarm screen uses
//     neither it nor these setters but its draft (lib/state/alarm_draft.dart).

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'wake_journal.dart';
import 'wake_outcome.dart';

import '../state/alarm_schedule.dart';
import '../state/feature_flags.dart';
import 'wake_orchestrator.dart';
import 'wake_settings.dart';

abstract interface class NaturalWakeLeadReader {
  Future<int> leadFor(DateTime wakeAt);
}

class WakeController extends ChangeNotifier
    implements NaturalWakePolicyListener {
  WakeController({
    required List<AlarmScheduleEntry> Function() schedule,
    required Future<void> Function(AlarmScheduleEntry entry) saveEntry,
    required Future<WakeUpgradeState> Function() loadUpgradeState,
    required Future<void> Function(WakeUpgradeState state) saveUpgradeState,
    required Future<WakeAckOutcome> Function(bool cancelNative) acknowledgeWake,
    required Future<List<WakeTraceEntry>> Function(DateTime wakeAt) traceFor,
    this.journal = const DbWakeJournal(),
    this.journalNow = DateTime.now,
    this.loadNaturalLead,
    bool Function()? naturalEnabled,
  }) : _journalClock = Clock(journalNow),
       _naturalEnabled =
           naturalEnabled ?? (() => FeatureFlags.isOn(FeatureFlag.naturalWake)),
       _schedule = schedule,
       _saveEntry = saveEntry,
       _loadUpgradeState = loadUpgradeState,
       _saveUpgradeState = saveUpgradeState,
       _acknowledgeWake = acknowledgeWake,
       _traceFor = traceFor;

  final NaturalWakeLeadReader? loadNaturalLead;
  final Map<int, int> _timelineLeads = {};
  @override
  void noteNaturalLead(DateTime wakeAt, int lead) {
    if (_disposed) return;
    final key = wakeAt.millisecondsSinceEpoch;
    if (_timelineLeads[key] == lead) return;
    // Seven preview occurrences plus the active occurrence are sufficient.
    if (_timelineLeads.length > 14) _timelineLeads.clear();
    _timelineLeads[key] = lead;
    notifyListeners();
  }

  final DbWakeJournal journal;
  final DateTime Function() journalNow;
  // Read the injected source when answering, through a resolved clock method.
  final Clock _journalClock;

  // This controller owns the visible pending occurrence. A late result from
  // an older acknowledgement must not dismiss a newer wake.
  int? _awaitingEpoch, _acknowledgedEpoch;
  WakePath? _awaitingPath;
  int? get awaitingWakeEpoch => _awaitingEpoch;
  WakePath? get awaitingWakePath => _awaitingPath;

  void noteWakeAwaitingAck(int wakeEpochSec, WakePath path) {
    if (_disposed || _acknowledgedEpoch == wakeEpochSec) return;
    if (_awaitingEpoch == wakeEpochSec &&
        _awaitingPath != null &&
        _awaitingPath!.index <= path.index) {
      return;
    }
    _awaitingEpoch = wakeEpochSec;
    _awaitingPath = path;
    notifyListeners();
  }

  Future<void> answerDream(int epoch, DreamAnswer? answer) =>
      journal.answerDream(
        wakeEpochSec: epoch,
        at: _journalClock.now(),
        answer: answer,
      );

  final bool Function() _naturalEnabled;
  final List<AlarmScheduleEntry> Function() _schedule;
  final Future<void> Function(AlarmScheduleEntry) _saveEntry;
  final Future<WakeUpgradeState> Function() _loadUpgradeState;
  final Future<void> Function(WakeUpgradeState) _saveUpgradeState;
  final Future<WakeAckOutcome> Function(bool) _acknowledgeWake;
  final Future<List<WakeTraceEntry>> Function(DateTime) _traceFor;

  WakeUpgradeState _upgrade = WakeUpgradeState.none;

  /// Bumped once each time a tick (or an acknowledgement) added rows to the
  /// decision trace. A screen that shows the trace listens to this, NOT to the
  /// controller: the trace changes every few seconds overnight and must not
  /// rebuild everything that listens to [WakeController] (or AppState).
  final ValueNotifier<int> traceRevision = ValueNotifier<int>(0);

  /// True while Natural Wake is repeating its buzz and waiting to be dismissed
  /// ("I'm up" via [acknowledgeWake], or a double tap on the band). A screen
  /// shows its dismiss card from this; flipped by the orchestrator.
  final ValueNotifier<bool> naturalBuzzing = ValueNotifier<bool>(false);

  bool _disposed = false;

  /// The orchestrator's repeat started or stopped.
  void noteNaturalRepeat(bool running) {
    if (!_disposed) naturalBuzzing.value = running;
  }

  /// A tick can finish after the app state is gone; that is not an error.
  void noteTraceChanged() {
    if (!_disposed) traceRevision.value++;
  }

  @override
  void dispose() {
    _disposed = true;
    traceRevision.dispose();
    naturalBuzzing.dispose();
    super.dispose();
  }

  /// Re-read persisted state. Call after the schedule is (re)loaded.
  Future<void> reload() async {
    _upgrade = await _loadUpgradeState();
    final load = loadNaturalLead;
    if (load != null) {
      final now = _journalClock.now().toLocal();
      for (var weekday = 0; weekday < 7; weekday++) {
        final entry = _entry(weekday);
        final delta = (entry.weekday - (now.weekday - 1) + 7) % 7;
        final at = DateTime(
          now.year,
          now.month,
          now.day + delta,
          entry.hour,
          entry.minute,
        );
        final wakeAt = at.isAfter(now)
            ? at
            : DateTime(at.year, at.month, at.day + 7, entry.hour, entry.minute);
        final lead = await load.leadFor(wakeAt);
        if (_disposed) return;
        _timelineLeads[wakeAt.millisecondsSinceEpoch] = lead;
      }
    }
    if (!_disposed) notifyListeners();
  }

  // ── reading ──────────────────────────────────────────────────────────────

  WakeUpgradeState get upgradeState => _upgrade;
  bool get upgradeExplanationPending => _upgrade == WakeUpgradeState.pending;

  /// FeatureFlag.naturalWake. Off: Natural is hidden and never runs.
  bool get naturalEnabled => _naturalEnabled();

  /// The legacy Smart Wake heuristic (and its collection window) runs instead
  /// of Natural: the explanation is still pending, or Natural is switched off.
  bool get legacySmartWakeActive =>
      upgradeExplanationPending || !naturalEnabled;

  /// [upgradeState] as the RUNNING code must see it (collection windows).
  WakeUpgradeState get runningUpgradeState =>
      gateNaturalWake(_upgrade, enabled: naturalEnabled);

  AlarmScheduleEntry _entry(int weekday) {
    _checkWeekday(weekday);
    return _schedule().firstWhere((e) => e.weekday == weekday);
  }

  int naturalWindowMinutes(int weekday) => _entry(weekday).naturalWindowMinutes;
  bool naturalActive(int weekday) =>
      naturalEnabled &&
      naturalWindowMinutes(weekday) > 0 &&
      !upgradeExplanationPending;
  int gradualWindowMinutes(int weekday) => _entry(weekday).gradualWindowMinutes;
  GradualPattern gradualPattern(int weekday) => _entry(weekday).gradualPattern;
  int gradualCadenceSeconds(int weekday) => _entry(weekday).gradualCadenceSec;

  WakeConfiguration configurationFor(int weekday) => wakeConfigurationOf(
    naturalMinutes: naturalActive(weekday) ? naturalWindowMinutes(weekday) : 0,
    gradualMinutes: gradualWindowMinutes(weekday),
  );

  /// The exact schedule for the alarm resolving to [wakeAt] (an absolute
  /// instant; its LOCAL weekday picks the configured day).
  ///
  /// [entry] previews a DRAFT day (the alarm screen edits a draft that is not
  /// saved yet); without it the saved schedule is used. The upgrade gate
  /// applies either way.
  WakeTimeline timelineAt(DateTime wakeAt, {AlarmScheduleEntry? entry}) {
    if (entry != null) {
      return WakeTimeline.compute(
        wakeAt: wakeAt,
        naturalLeadMinutes: _timelineLeads[wakeAt.millisecondsSinceEpoch] ?? 0,
        naturalMinutes: upgradeExplanationPending || !naturalEnabled
            ? 0
            : entry.naturalWindowMinutes,
        gradualMinutes: entry.gradualWindowMinutes,
      );
    }
    final weekday = wakeAt.toLocal().weekday - 1;
    return WakeTimeline.compute(
      wakeAt: wakeAt,
      naturalLeadMinutes: _timelineLeads[wakeAt.millisecondsSinceEpoch] ?? 0,
      naturalMinutes: naturalActive(weekday)
          ? naturalWindowMinutes(weekday)
          : 0,
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
      throw ArgumentError.value(
        seconds,
        'seconds',
        'cadence is $kGradualCadenceMinSec..$kGradualCadenceMaxSec s in '
            '${kGradualCadenceStepSec}s steps',
      );
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
    final epoch = _awaitingEpoch;
    final out = await _acknowledgeWake(cancelNative);
    if (epoch != null && epoch == _awaitingEpoch) {
      _acknowledgedEpoch = epoch;
      _awaitingEpoch = null;
      _awaitingPath = null;
    }
    if (!_disposed) notifyListeners();
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
      throw ArgumentError.value(
        minutes,
        'minutes',
        '0 (off) or $kWakeWindowStepMinutes..$kWakeWindowMaxMinutes in '
            '$kWakeWindowStepMinutes-minute steps',
      );
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
