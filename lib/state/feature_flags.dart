// feature_flags.dart — five independent rollout switches (phase 7).
//
// Every flag is ON by default, so shipping this file changes nothing. A flag is
// LOCAL: a compile-time default (`--dart-define=OS_FF_<NAME>=false`) that a
// local SharedPreferences value (`ff.<id>`) can override. Nothing here reads a
// network, a remote-config service or telemetry.
//
// Each flag, when OFF, falls back to the old path or hides the feature:
//   alertDispatcher   NotificationCenter.emit delivers to the phone only, the
//                     way it did before typed destinations. Band haptics are
//                     NOT affected: they stay behind AlertDispatcher either
//                     way (invariant: no direct band buzz).
//   nativeRelay       NotificationRelay is unsupported: no listener is armed,
//                     the Android Relay UI is hidden.
//   sourceResolverUi  No Source catalog / resolved-data entry; the priority
//                     editor shows only when two devices contend, as before.
//   tapClassifiers    A double tap is just a double tap: no ECG touch counting,
//                     no repeated-double-tap window, no lab modes, and the 3-5
//                     tap rows are hidden.
//   naturalWake       No Natural Wake: its row and the upgrade card are
//                     hidden, the orchestrator is given no Natural window, and
//                     the pre-split Smart Wake heuristic keeps running. Gradual
//                     Wake and the native alarm at T are untouched.
//
// The synchronous reads ([isOn]) are served from memory; [load] fills it from
// SharedPreferences (main.dart at launch; headless entries call it themselves).
// Until [load] runs, every flag reads its compile-time default.

import 'package:shared_preferences/shared_preferences.dart';

enum FeatureFlag {
  alertDispatcher('alert_dispatcher'),
  nativeRelay('native_relay'),
  sourceResolverUi('source_resolver_ui'),
  tapClassifiers('tap_classifiers'),
  naturalWake('natural_wake');

  const FeatureFlag(this.id);
  final String id;

  /// The SharedPreferences key holding the local override.
  String get prefsKey => 'ff.$id';
}

class FeatureFlags {
  FeatureFlags._();

  /// Compile-time defaults. `const` so `--dart-define` can flip one in a build.
  static const Map<FeatureFlag, bool> _defaults = {
    FeatureFlag.alertDispatcher:
        bool.fromEnvironment('OS_FF_ALERT_DISPATCHER', defaultValue: true),
    FeatureFlag.nativeRelay:
        bool.fromEnvironment('OS_FF_NATIVE_RELAY', defaultValue: true),
    FeatureFlag.sourceResolverUi:
        bool.fromEnvironment('OS_FF_SOURCE_RESOLVER_UI', defaultValue: true),
    FeatureFlag.tapClassifiers:
        bool.fromEnvironment('OS_FF_TAP_CLASSIFIERS', defaultValue: true),
    FeatureFlag.naturalWake:
        bool.fromEnvironment('OS_FF_NATURAL_WAKE', defaultValue: true),
  };

  static final Map<FeatureFlag, bool> _stored = {};
  static bool _loaded = false;

  static bool defaultOf(FeatureFlag f) => _defaults[f] ?? true;

  /// The flag's value now: the stored override, else the compile-time default.
  static bool isOn(FeatureFlag f) => _stored[f] ?? defaultOf(f);

  /// Read every override from SharedPreferences. Never throws: storage that
  /// cannot be read leaves the compile-time defaults, i.e. the shipped
  /// behaviour. Safe to call from any isolate, any number of times.
  static Future<void> load() async {
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      _stored.clear();
      for (final f in FeatureFlag.values) {
        final v = p.getBool(f.prefsKey);
        if (v != null) _stored[f] = v;
      }
    } catch (_) {
      /* defaults stand */
    }
  }

  /// [load] once per isolate: for entries that can run headless (a background
  /// derive or sync) and have no launch hook of their own.
  static Future<void> ensureLoaded() => _loaded ? Future.value() : load();

  /// Persist an override. The in-memory value changes first so the switch takes
  /// effect even when the write fails (it then lasts until the next launch).
  static Future<void> set(FeatureFlag f, bool on) async {
    _stored[f] = on;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(f.prefsKey, on);
    } catch (_) {
      /* in-memory value stands for this run */
    }
  }

  /// Drop one override (back to the compile-time default).
  static Future<void> clear(FeatureFlag f) async {
    _stored.remove(f);
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(f.prefsKey);
    } catch (_) {}
  }

  /// Tests only: forget every in-memory override.
  static void resetForTest() {
    _stored.clear();
    _loaded = false;
  }

  /// Tests only: set a value without touching storage.
  static void debugSet(FeatureFlag f, bool on) {
    _stored[f] = on;
    _loaded = true; // an explicit test value must not be overwritten by a load
  }
}
