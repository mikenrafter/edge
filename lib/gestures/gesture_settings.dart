// gesture_settings.dart — the persisted band-gesture → action mapping, plus the
// per-platform set of supported actions. Same persistence pattern as ThemeController
// (SharedPreferences) and same ChangeNotifier shape so the settings UI rebuilds and
// the dispatcher reads a live value.
//
// A double-tap maps to a SET of actions, stored as an int bitmask where bit i is
// `DeviceAction.values[i]` (so the enum order is persisted — never reorder it).

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/device_actions.dart';
import 'device_action.dart';
import 'ecg_tap_counter.dart';
import 'time_buzz.dart';

/// How taps beyond the firmware's double tap are counted. One mapping store
/// (slot n = n taps, 2..5) serves both; only the way the count is made differs.
enum TapCountMethod {
  /// Touches of the ECG sensor after the double tap (WHOOP MG only).
  ecg('ecg'),

  /// More firmware double taps inside a short window (any band).
  repeat('repeat');

  const TapCountMethod(this.id);
  final String id;

  static TapCountMethod? fromId(String? id) {
    for (final m in values) {
      if (m.id == id) return m;
    }
    return null;
  }
}

class GestureSettings extends ChangeNotifier {
  static const _kActions = 'gesture_double_tap_actions';

  /// Legacy single-action key (a string id). Read once when [_kActions] is
  /// absent, and deliberately NOT deleted: notification_prefs.dart still reads it
  /// for the one-time `gesture` alert-rule migration.
  static const _kLegacyDoubleTap = 'gesture_double_tap';
  static const _kReplayPrefix = 'gesture_replay_';

  /// 3–5 taps: one bitmask per count, same layout as [_kActions].
  /// 2 taps stays on [_kActions].
  static const _kTapActionsPrefix = 'gesture_tap_actions_';
  static const _kEcgOnDoubleTap = 'gesture_ecg_on_double_tap';
  static const _kEcgStartMs = 'gesture_ecg_start_ms';
  static const _kEcgGapMs = 'gesture_ecg_gap_ms';
  static const _kEcgConfirmMs = 'gesture_ecg_confirm_ms';
  static const _kEcgExtraSensitive = 'gesture_ecg_extra_sensitive';
  static const _kEcgTolerant = 'gesture_ecg_tolerant_startup';
  static const _kEcgFallback = 'gesture_ecg_fallback';
  static const _kTapMethod = 'gesture_tap_method';
  static const _kRepeatWindowMs = 'gesture_repeat_window_ms';
  static const _kRepeatLab = 'gesture_repeat_lab';
  static const _kTimeBuzzMode = 'gesture_time_buzz_mode';

  /// The pause allowed between repeated double taps: 1000..5000 ms in 250 ms
  /// steps, 2500 ms until changed.
  static const (int, int) repeatWindowRange = (1000, 5000);
  static const int repeatWindowStepMs = 250;
  static const int defaultRepeatWindowMs = 2500;

  static bool isValidRepeatWindow(int v) =>
      v >= repeatWindowRange.$1 &&
      v <= repeatWindowRange.$2 &&
      (v - repeatWindowRange.$1) % repeatWindowStepMs == 0;

  static int maskOf(Iterable<DeviceAction> actions) {
    var m = 0;
    for (final a in actions) {
      if (a == DeviceAction.none) continue;
      m |= 1 << DeviceAction.values.indexOf(a);
    }
    return m;
  }

  /// Enum order; ignores bit 0 (`none`) and bits past the enum.
  static Set<DeviceAction> actionsOfMask(int mask) => {
        for (var i = 1; i < DeviceAction.values.length; i++)
          if (mask & (1 << i) != 0) DeviceAction.values[i],
      };

  Set<DeviceAction> _actions = const {};

  /// Actions for 3, 4 and 5 taps. Absent key = no actions.
  final Map<int, Set<DeviceAction>> _tapActions = {};

  bool _ecgOnDoubleTap = false;
  EcgTapThresholds _ecgThresholds = EcgTapThresholds();
  TapCountMethod? _tapMethod;
  int _repeatWindowMs = defaultRepeatWindowMs;
  bool _repeatLab = false;
  TimeBuzzMode _timeBuzzMode = TimeBuzzMode.count;

  /// Explicit user choices only; absence means "follow the default".
  final Map<DeviceAction, bool> _replay = {};

  /// What a double-tap currently does, in enum order. Empty (the default) is the
  /// off state — opt-in, so we never surprise a user (or pay the iOS bg
  /// keep-alive cost) until they switch an action on.
  Set<DeviceAction> get doubleTapActions => Set.unmodifiable(_actions);

  /// Actions for [n] taps, 2..5. `n == 2` is [doubleTapActions].
  Set<DeviceAction> actionsForTaps(int n) {
    if (n < 2 || n > 5) throw ArgumentError.value(n, 'n', 'must be 2..5');
    if (n == 2) return doubleTapActions;
    return Set.unmodifiable(_tapActions[n] ?? const <DeviceAction>{});
  }

  /// The highest tap count with an action mapped; 2 when none of 3..5 is.
  int get maxMappedTaps {
    for (var n = 5; n >= 3; n--) {
      if ((_tapActions[n] ?? const <DeviceAction>{}).isNotEmpty) return n;
    }
    return 2;
  }

  /// The highest tap count the counter session waits for. In the Device lab
  /// (switch on) it is always 5 so the whole sequence can be tested; otherwise
  /// the highest mapped count, since a count nothing is mapped to is not worth
  /// waiting for.
  int get ecgTapMax => _ecgOnDoubleTap ? 5 : maxMappedTaps;

  /// A live double tap starts an ECG capture instead of its actions
  /// (WHOOP MG only; the Device lab owns the switch). Off by default.
  bool get ecgOnDoubleTap => _ecgOnDoubleTap;

  /// The user's explicit choice of counting method; null follows the default.
  TapCountMethod? get tapMethodChoice => _tapMethod;

  /// The method in force for the connected band: repeated double taps unless a
  /// WHOOP MG user chose ECG touches; double taps on every band without ECG
  /// (whatever was stored, since that band cannot count touches). A stored
  /// `gesture_ecg_tap_mode` from the retired Fast setting is never read.
  TapCountMethod tapMethodFor({required bool ecgSupported}) =>
      ecgSupported ? (_tapMethod ?? TapCountMethod.repeat) : TapCountMethod.repeat;

  /// The pause allowed between repeated double taps.
  int get repeatTapWindowMs => _repeatWindowMs;
  Duration get repeatTapWindow => Duration(milliseconds: _repeatWindowMs);

  /// The Device lab is trying the repeated-double-tap method: live double taps
  /// are counted (up to 5) and NO action runs. Exclusive with [ecgOnDoubleTap].
  bool get repeatTapsLab => _repeatLab;

  /// The most taps the repeated-double-tap window waits for: 5 in the lab,
  /// otherwise the highest mapped count.
  int get repeatTapMax => _repeatLab ? 5 : maxMappedTaps;

  /// The three adjustable ECG-touch windows.
  EcgTapThresholds get ecgTapThresholds => _ecgThresholds;

  /// Actions offerable on THIS platform: `none` always, plus whatever native says
  /// it can do. Until bootstrap() runs we only know `none`.
  Set<DeviceAction> supported = {DeviceAction.none};

  /// Selected actions that will also run for a tap replayed from history.
  Set<DeviceAction> get replayActions => {
        for (final a in _actions)
          if (replayHistorical(a)) a,
      };

  bool replayHistorical(DeviceAction a) =>
      a.supportsHistoricalReplay && (_replay[a] ?? _actions.contains(a));

  /// True once the user has mapped a real-time action — callers can use this to
  /// decide whether the iOS background BLE keep-alive is worth enabling.
  bool get hasActiveMapping => _actions.isNotEmpty;

  /// Load the saved mapping and query native capabilities. Call once at startup.
  Future<void> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(_kActions);
    final legacy = DeviceActionX.fromId(prefs.getString(_kLegacyDoubleTap));
    var actions = stored != null
        ? actionsOfMask(stored)
        : {
            if (legacy != null && legacy != DeviceAction.none) legacy,
          };
    _replay.clear();
    for (final a in DeviceAction.values) {
      final v = prefs.getBool('$_kReplayPrefix${a.id}');
      if (v != null) _replay[a] = v;
    }
    _ecgOnDoubleTap = prefs.getBool(_kEcgOnDoubleTap) ?? false;
    _repeatLab = prefs.getBool(_kRepeatLab) ?? false;
    if (_ecgOnDoubleTap && _repeatLab) _repeatLab = false; // exclusive
    _tapMethod = TapCountMethod.fromId(prefs.getString(_kTapMethod));
    final storedMode = prefs.getString(_kTimeBuzzMode);
    _timeBuzzMode = TimeBuzzMode.values
            .where((m) => m.name == storedMode)
            .firstOrNull ??
        TimeBuzzMode.count;
    final window = prefs.getInt(_kRepeatWindowMs);
    _repeatWindowMs = window != null && isValidRepeatWindow(window)
        ? window
        : defaultRepeatWindowMs;
    // A stored value that is out of range or off the 50 ms grid falls back to
    // THAT field's default; the other fields keep what was stored.
    int field(String key, int dflt, (int, int) range) {
      final v = prefs.getInt(key);
      return v != null && EcgTapThresholds.isValid(v, range) ? v : dflt;
    }

    final d = EcgTapThresholds();
    _ecgThresholds = EcgTapThresholds(
      startMs: field(_kEcgStartMs, d.startMs, EcgTapThresholds.startRange),
      gapMs: field(_kEcgGapMs, d.gapMs, EcgTapThresholds.gapRange),
      confirmMs:
          field(_kEcgConfirmMs, d.confirmMs, EcgTapThresholds.confirmRange),
      extraSensitive: prefs.getBool(_kEcgExtraSensitive) ?? d.extraSensitive,
      tolerantStartup: prefs.getBool(_kEcgTolerant) ?? d.tolerantStartup,
      fallbackToDoubleTap: prefs.getBool(_kEcgFallback) ?? d.fallbackToDoubleTap,
    );

    final caps = await DeviceActions.capabilities();
    supported = {
      DeviceAction.none,
      // In-app actions act on our own app, so they're offerable everywhere.
      ...DeviceAction.values.where((a) => a.isInApp),
      // Native actions: only what this platform reported it can do.
      ...caps.map(DeviceActionX.fromId).whereType<DeviceAction>(),
    };

    // A previously-chosen action this platform can't do (e.g. settings synced
    // from an Android backup onto an iPhone) is dropped rather than silently
    // mapped to something unsupported.
    actions = actions.where(supported.contains).toSet();
    _actions = actions;
    _tapActions.clear();
    for (var n = 3; n <= 5; n++) {
      final m = prefs.getInt('$_kTapActionsPrefix$n');
      if (m == null) continue;
      _tapActions[n] = actionsOfMask(m).where(supported.contains).toSet();
    }
    final mask = maskOf(actions);
    if (stored != mask) await prefs.setInt(_kActions, mask);
    notifyListeners();
  }

  Future<void> setDoubleTapActions(Set<DeviceAction> actions) async {
    final next = {
      for (final a in DeviceAction.values)
        if (a != DeviceAction.none && actions.contains(a)) a,
    };
    if (setEquals(next, _actions)) return;
    _actions = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kActions, maskOf(next));
    notifyListeners();
  }

  Future<void> setActionsForTaps(int n, Set<DeviceAction> actions) async {
    if (n < 2 || n > 5) throw ArgumentError.value(n, 'n', 'must be 2..5');
    if (n == 2) return setDoubleTapActions(actions);
    final next = {
      for (final a in DeviceAction.values)
        if (a != DeviceAction.none && actions.contains(a)) a,
    };
    if (setEquals(next, actionsForTaps(n))) return;
    _tapActions[n] = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_kTapActionsPrefix$n', maskOf(next));
    notifyListeners();
  }

  /// How Tell the time encodes the time. [TimeBuzzMode.count] until changed;
  /// an unreadable stored value is count. Stored under the SharedPreferences
  /// key `gesture_time_buzz_mode` as the mode's name ('count', 'binary',
  /// 'morse').
  TimeBuzzMode get timeBuzzMode => _timeBuzzMode;

  Future<void> setTimeBuzzMode(TimeBuzzMode mode) async {
    if (_timeBuzzMode == mode) return;
    _timeBuzzMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTimeBuzzMode, mode.name);
    notifyListeners();
  }

  Future<void> setEcgOnDoubleTap(bool on) async {
    if (_ecgOnDoubleTap == on) return;
    _ecgOnDoubleTap = on;
    final turnedOffLab = on && _repeatLab;
    if (turnedOffLab) _repeatLab = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEcgOnDoubleTap, on);
    if (turnedOffLab) await prefs.setBool(_kRepeatLab, false);
    notifyListeners();
  }

  Future<void> setRepeatTapsLab(bool on) async {
    if (_repeatLab == on) return;
    _repeatLab = on;
    final turnedOffLab = on && _ecgOnDoubleTap;
    if (turnedOffLab) _ecgOnDoubleTap = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRepeatLab, on);
    if (turnedOffLab) await prefs.setBool(_kEcgOnDoubleTap, false);
    notifyListeners();
  }

  Future<void> setTapMethod(TapCountMethod m) async {
    if (_tapMethod == m) return;
    _tapMethod = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTapMethod, m.id);
    notifyListeners();
  }

  /// Rejects a value outside 1000..5000 ms or off the 250 ms grid (never clamps).
  Future<void> setRepeatTapWindowMs(int ms) async {
    if (!isValidRepeatWindow(ms)) {
      throw ArgumentError.value(
          ms,
          'ms',
          'must be ${repeatWindowRange.$1}–${repeatWindowRange.$2} ms in '
              'steps of $repeatWindowStepMs; rejected, not clamped');
    }
    if (_repeatWindowMs == ms) return;
    _repeatWindowMs = ms;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kRepeatWindowMs, ms);
    notifyListeners();
  }

  Future<void> setEcgTapThresholds(EcgTapThresholds t) async {
    if (t == _ecgThresholds) return;
    _ecgThresholds = t;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kEcgStartMs, t.startMs);
    await prefs.setInt(_kEcgGapMs, t.gapMs);
    await prefs.setInt(_kEcgConfirmMs, t.confirmMs);
    await prefs.setBool(_kEcgExtraSensitive, t.extraSensitive);
    await prefs.setBool(_kEcgTolerant, t.tolerantStartup);
    await prefs.setBool(_kEcgFallback, t.fallbackToDoubleTap);
    notifyListeners();
  }

  Future<void> toggleDoubleTapAction(DeviceAction a, bool on) =>
      setDoubleTapActions(
        on ? {..._actions, a} : _actions.where((x) => x != a).toSet(),
      );

  Future<void> setReplayHistorical(DeviceAction a, bool on) async {
    if (!a.supportsHistoricalReplay) return;
    if (_replay[a] == on) return;
    _replay[a] = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_kReplayPrefix${a.id}', on);
    notifyListeners();
  }
}
