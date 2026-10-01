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

class GestureSettings extends ChangeNotifier {
  static const _kActions = 'gesture_double_tap_actions';

  /// Legacy single-action key (a string id). Read once when [_kActions] is
  /// absent, and deliberately NOT deleted: notification_prefs.dart still reads it
  /// for the one-time `gesture` alert-rule migration.
  static const _kLegacyDoubleTap = 'gesture_double_tap';
  static const _kReplayPrefix = 'gesture_replay_';

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

  /// Explicit user choices only; absence means "follow the default".
  final Map<DeviceAction, bool> _replay = {};

  /// What a double-tap currently does, in enum order. Empty (the default) is the
  /// off state — opt-in, so we never surprise a user (or pay the iOS bg
  /// keep-alive cost) until they switch an action on.
  Set<DeviceAction> get doubleTapActions => Set.unmodifiable(_actions);

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
    var actions = stored != null
        ? actionsOfMask(stored)
        : {
            if (DeviceActionX.fromId(prefs.getString(_kLegacyDoubleTap))
                case final a? when a != DeviceAction.none)
              a,
          };
    _replay.clear();
    for (final a in DeviceAction.values) {
      final v = prefs.getBool('$_kReplayPrefix${a.id}');
      if (v != null) _replay[a] = v;
    }

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
