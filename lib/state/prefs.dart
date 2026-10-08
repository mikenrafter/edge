// Prefs — a tiny synchronous façade over SharedPreferences for UI selection
// state (selected tab, per-metric range toggles, etc.). Local-first, no auth.
//
// Screens need to RESTORE a saved selection in initState() without an async gap
// (which would flash the default first). So we keep a cached SharedPreferences
// instance, loaded once at startup via [ensureLoaded] (awaited in main before
// runApp). Reads are then synchronous; writes persist in the background.
//
// If a screen is somehow built before [ensureLoaded] completes, reads fall back
// to the provided default — never throws, never blocks.

import 'package:shared_preferences/shared_preferences.dart';

import '../compute/calc_power_policy.dart' show CalcPowerMode;
import '../haptics/band_queue.dart'
    show
        kBandCommandLimitDefault,
        kBandCommandLimitMax,
        kBandCommandLimitMin;

class Prefs {
  Prefs._();

  static SharedPreferences? _sp;

  /// Load + cache the SharedPreferences instance. Call once before runApp.
  /// Idempotent and best-effort — failures leave reads on their defaults.
  static Future<void> ensureLoaded() async {
    try {
      _sp ??= await SharedPreferences.getInstance();
    } catch (_) {/* reads fall back to defaults */}
  }

  /// Whether storage is actually available, i.e. whether a `getX` default is
  /// "the key is unset" or "we cannot see what you chose".
  ///
  /// For a tab index those are the same answer. For a CONSENT they are not:
  /// an on-by-default switch read through unavailable storage would send on
  /// behalf of somebody who turned it off. Anything gating an outbound call
  /// checks this first — see `offLookupAllowed`.
  static bool get loaded => _sp != null;

  // ── synchronous read (fall back to default until loaded) ────────────────────
  static int getInt(String key, int fallback) => _sp?.getInt(key) ?? fallback;
  static String getString(String key, String fallback) =>
      _sp?.getString(key) ?? fallback;
  static bool getBool(String key, bool fallback) =>
      _sp?.getBool(key) ?? fallback;

  // ── fire-and-forget write (kept in sync with the cache for immediate reads) ──
  static void setInt(String key, int value) {
    _sp?.setInt(key, value);
  }

  static void setString(String key, String value) {
    _sp?.setString(key, value);
  }

  static void setBool(String key, bool value) {
    _sp?.setBool(key, value);
  }

  /// The same write, with SharedPreferences' own acknowledgement handed back —
  /// false when there is no storage, or when the platform refused it.
  ///
  /// For a tab index nobody can be hurt by a write that quietly failed. For a
  /// CONSENT they can: SharedPreferences updates its cache OPTIMISTICALLY and
  /// never rolls it back, so a failed revocation reads as off for the rest of
  /// the session and is back ON at the next launch, with nobody told. The one
  /// caller that must know is `setOffLookupAllowed`.
  /// A THROW is the same answer as a false: the write did not land. Letting it
  /// propagate is worse than useless here — it skips the caller's "we could not
  /// save that" warning and takes out the flow that was asking (the scanner
  /// exits before the camera opens), so the one path that exists to TELL the
  /// person never runs. Failure is reported, never raised.
  static Future<bool> setBoolAcked(String key, bool value) async {
    try {
      return await _sp?.setBool(key, value) ?? false;
    } catch (_) {
      return false;
    }
  }

  // ── selection keys (one namespace; keep them disjoint) ──────────────────────
  static const String shellTab = 'ui.shell_tab';
  static const String recapRange = 'ui.recap_range';
  static const String workoutsRange = 'ui.workouts_range';

  /// Automatic local backup: the chosen cadence, and when one last ran.
  static const String backupCadence = 'backup.cadence';
  static const String backupLastRunMs = 'backup.last_run_ms';

  /// Developer mode. Off unless somebody deliberately turned it on — it is a
  /// tool for us, not a feature, so it has no switch in the normal settings
  /// list and nothing reads it except the surfaces it reveals.
  static const String devMode = 'dev.mode';

  /// Lift the 10 s cap on compiled band haptics. Off by default; the
  /// 8-command plan cap and the band's rolling command limit still apply.
  static const String hapticsAllowLong = 'haptics_allow_long_sequences';
  static bool get allowLongHaptics => getBool(hapticsAllowLong, false);

  /// Developer setting: how many band haptic commands may be sent in any 2
  /// minutes, 10..60, default 30. Read on every use (the ledger asks each
  /// time); a stored value out of range is clamped on read.
  static const String hapticsCommandLimit = 'haptics_command_limit';
  static int get hapticCommandLimit =>
      getInt(hapticsCommandLimit, kBandCommandLimitDefault)
          .clamp(kBandCommandLimitMin, kBandCommandLimitMax);
  static void setHapticCommandLimit(int v) => setInt(hapticsCommandLimit,
      v.clamp(kBandCommandLimitMin, kBandCommandLimitMax));

  /// The notes editor's mode, 'follow_rhythm' (the default: every note is
  /// a `*` note and the dynamics bar is hidden) or 'allow_dynamics'.
  static const String hapticsEditorMode = 'haptics_editor_mode';

  /// The pattern each gesture cue was given, a JSON map of slot key to
  /// pattern id (see haptic_slots.dart). Written through the settings
  /// repository; a cue not in it plays its own built-in.
  static const String hapticsCueAssign = 'haptics_gesture_cue_assign';

  /// "Tasker connection": the one switch for the Tasker integration (the
  /// Broadcast to Tasker gesture action and the incoming Tasker plays). On
  /// unless somebody turned it off, so existing Tasker users see no change.
  static const String taskerConnection = 'tasker_connection';
  static bool get taskerConnectionOn => getBool(taskerConnection, true);

  /// "Send reviewed moments to Tasker": consent for the marked-moment review's
  /// MOMENT_REVIEWED broadcast. Those answers are health information (a
  /// medication, a dose, a symptom), so unlike the Tasker connection this is OFF
  /// until somebody turns it on, and it is a separate switch from it.
  static const String taskerMomentExport = 'tasker_moment_export';
  static bool get taskerMomentExportOn => getBool(taskerMomentExport, false);

  /// setString with the platform's own acknowledgement: false when there is no
  /// storage or the write was refused or threw (see [setBoolAcked]). The cache
  /// is updated before the first await, so a read right after sees the value.
  static Future<bool> setStringAcked(String key, String value) async {
    try {
      return await _sp?.setString(key, value) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The gestures that failed to activate, one JSON string (see
  /// gestures/gesture_failures.dart); bounded to the newest 20.
  static const String gestureFailures = 'gesture_failures';

  /// "Pull down to sync": Home's pull-to-refresh. On unless somebody turned it
  /// off, so nobody else sees a change; off leaves syncing to the status line's
  /// Sync now button.
  static const String pullToSync = 'pull_to_sync';
  static bool get pullToSyncOn => getBool(pullToSync, true);

  /// Settings > Data & privacy > Calculations: when derive work and warming run
  /// (see CalcPowerPolicy). The enum's name; balanced when unset or unknown.
  static const String calcPowerMode = 'calc_power_mode';
  static CalcPowerMode get calcPowerModeValue {
    final name = getString(calcPowerMode, '');
    for (final m in CalcPowerMode.values) {
      if (m.name == name) return m;
    }
    return CalcPowerMode.balanced;
  }

  static void setCalcPowerMode(CalcPowerMode m) => setString(calcPowerMode, m.name);

  /// Per-metric range toggle on the shared MetricScreen (Today/Week/Month/3M).
  /// Keyed by the metric id so Sleep / Heart / Body each remember independently.
  static String metricTab(String metric) => 'ui.metric_tab.$metric';

  /// One-shot: a second framed band's ASK provisioning is requested and should
  /// run at the next start-up, before anything touches flutter_blue_plus (the
  /// only moment the ASK picker can show — see AppState._provisionAdditionalAccessory).
  /// Cleared in a `finally` regardless of outcome.
  static const String kAskAddPendingKey = 'ble.ask_add_pending';

  /// The live-workout HR-zone-crossing haptic: buzz when HR crosses into or
  /// out of [zoneAlertTargetZone]. Off by default — an existing user did not
  /// ask their band to start buzzing mid-run.
  static const String zoneAlertEnabled = 'workout.zone_alert_enabled';

  /// The zone (1..5) the crossing alert watches. Zone 3 by default: a
  /// reasonable "stay in this effort band" target with no session history to
  /// personalise it from.
  static const String zoneAlertTargetZone = 'workout.zone_alert_target_zone';

  /// The finished session row of a workout whose save failed (JSON), written
  /// ahead so a relaunch can bank it instead of losing the tallies. Empty when
  /// nothing is waiting. Cleared once the row is saved or the workout deleted.
  static const String workoutStopPending = 'workout.stop_pending';

  /// Demo Mode: the app is showing a synthetic ~2-month backfill instead of a
  /// paired band's real data. Checked by `_Gate` (persistent banner) and by
  /// `AppState._persistPaired` (purge before a real pairing ever touches the
  /// database) — see `lib/demo/demo_data_generator.dart`.
  static const String demoModeEnabled = 'demo.mode_enabled';
}
