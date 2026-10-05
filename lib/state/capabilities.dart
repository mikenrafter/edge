// capabilities.dart — one place decides what a screen shows, hides or disables.
//
// A screen asks `caps.of(Feature.x)` and draws the answer. It does not read
// the platform, a feature flag, dev mode, the band generation or the link
// state itself. The inputs below are collected once (AppState.capabilities,
// provided to the tree by main.dart) and every answer is a pure function of
// them, so two screens that ask about the same fact cannot disagree.
//
//   Available   draw it and let it work
//   Hidden      leave it out (wrong platform, switched off, not this band)
//   Disabled    draw it, dimmed and inert, with a reason (the "disable, don't
//               hide" rule for rows whose precondition can change while the
//               screen is open: no live link, no ECG sensor)
//
// Inventory of the gates this file replaced. Line numbers are as of
// the migration and drift; the symbol is what to search for.
//
//   Gate (before)                                        Where                           Feature
//   ---------------------------------------------------  ------------------------------  ----------------------
//   defaultTargetPlatform == android -> relaySupported   ui2/profile/settings.dart:221   relayEntry
//     (ignored FeatureFlag.nativeRelay: it disagreed
//     with NotificationRelay.supported, a bug)
//   _dev = Prefs.getBool(Prefs.devMode) -> devMode       ui2/profile/settings.dart:82    developerMode
//   Prefs.getBool(Prefs.devMode) -> devMode              ui2/profile/haptics_settings    developerMode
//                                                        .dart:143
//   Prefs.getBool(Prefs.devMode) in _eligible/_hide      ui2/nudges.dart:37,76           developerMode
//   FeatureFlags.isOn(tapClassifiers) -> extraTaps       ui2/profile/gestures.dart:63    extraTapCounting
//   FeatureFlags.isOn(tapClassifiers) -> tapTools        ui2/profile/device_lab.dart:85  deviceLabTapTools
//   pairedIsMaverick -> ecgSupported (method rows)       ui2/profile/gestures.dart:54,56 ecgTouchTaps
//   pairedIsMaverick -> ecgSupported (lab switch)        ui2/profile/device_lab.dart:69  ecgTouchTaps
//   pairedIsMaverickOf(c) -> Heart Screener door         ui2/screens/health_screen.dart  ecgEntry
//                                                        :824
//   engine.isConnected && engine.isMaverick -> canTake   ui2/screens/ecg.dart:162        ecgTake
//   FeatureFlags.isOn(sourceResolverUi) catalog          ui2/profile/devices.dart:1094   sourceCatalog
//   FeatureFlags.isOn(sourceResolverUi) || contended     ui2/profile/devices.dart:1099   signalPriority
//   app.wake.naturalEnabled -> naturalWakeSupported      ui2/profile/alarm.dart:136      naturalWake
//   app.isConnected -> connected (alarm test/cancel)     ui2/profile/alarm.dart:129      alarmBandControls
//   app.engine.isConnected -> bandConnected (Buzz,       ui2/profile/haptics_settings    bandBuzz
//     preview rows, pattern sheets)                      .dart:146
//   app.engine.isConnected -> bandConnected (pickers)    ui2/profile/band_notifications  bandBuzz
//                                                        .dart:138
//   app.engine.isConnected -> bandConnected (picker)     ui2/profile/settings.dart:1080  bandBuzz
//   HapticDeviceProfile.forGeneration(generation)        haptics_settings.dart:141,      hapticVocabulary
//                                                        band_notifications.dart:141,
//                                                        settings.dart:1083
//   app.isConnected -> beat-timing rows                  ui2/screens/calm_breathing      breathingBeatTiming
//                                                        .dart:745,754
//   app.isConnected -> onRename                          ui2/profile/devices.dart:1861   bandRename
//   kSideloadOtaEnabled via updateChecksAvailable        ui2/profile/settings.dart:209   updateChecks
//   kHealthDataContributionEnabled || consent            ui2/profile/settings.dart:204   healthShare
//   defaultTargetPlatform == android (intent copy)       ui2/profile/settings.dart:1963  androidAutomation
//   targetsForBandFamily(device.generation)              state/app_state.dart:605        bandAlerts
//
// Left where they are on purpose (a status line or an OS probe, not a gate on
// what a screen may offer):
//   ui2/live_hr.dart:91, ui2/profile/devices.dart:959, live_devices.dart:245,
//     workout_screen.dart:1257,1291 / activity/live.dart:791, setup.dart:175:
//     the link state worded as text ("Band connected"); nothing is hidden or
//     disabled by it. Capabilities would only rename the same bool.
//   ui2/screens/day_steps.dart:514, devices.dart:954: bandLabelFor(generation)
//     is a display label, not a visibility rule.
//   ui2/profile/settings.dart:121 AppIcon.available, :1014 notification
//     permission, band_notifications.dart:93 relay permission: asynchronous OS
//     probes each screen owns and refreshes on resume; AppState has no copy.
//   notify/notification_relay.dart:546 NotificationRelay.supported: the
//     relay's own runtime gate with a debug seam; same predicate as relayEntry
//     (Android and nativeRelay), kept so the relay never depends on the UI.
//   ui2/profile/settings.dart:1130 AlertCapabilityRegistry
//     .destinationSupportReason: per-RULE support (kind x execution mode), not
//     a band capability. Only its band-family target set was folded in, via
//     bandAlerts/bandAlertTargets.

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, setEquals;

import '../haptics/haptic_profile.dart';
import '../notify/alert_rule.dart';
import 'feature_flags.dart';

/// Every thing a screen can gate on.
enum Feature {
  /// Developer mode: the Developer settings group, the Device lab row, nudges
  /// that ignore their own dismissal.
  developerMode,

  /// Settings > Alerts > App notifications on the band (Android only, and only
  /// while nativeRelay is on, exactly like NotificationRelay.supported).
  relayEntry,

  /// The 3-5 tap rows and the method choice on the Gestures screen.
  extraTapCounting,

  /// The tap tools inside the Device lab.
  deviceLabTapTools,

  /// ECG sensor touches as a tap counter: the remembered band is an MG.
  /// Disabled, never hidden, on a band without the sensor.
  ecgTouchTaps,

  /// The Heart Screener door on Health: the paired band identified itself as an
  /// MG once, and stays while it is away.
  ecgEntry,

  /// Taking a reading now: a live link to a band that identified itself as an
  /// MG this connection.
  ecgTake,

  /// The Source catalog and resolved-data entry.
  sourceCatalog,

  /// The signal priority editor (a contended signal also opens it; that is a
  /// data fact the caller adds).
  signalPriority,

  /// Natural Wake rows and the upgrade card.
  naturalWake,

  /// The band can be an alert destination (WHOOP 4.0 / MG).
  bandAlerts,

  /// The band has a measured haptic vocabulary (an MG): notes patterns, the
  /// editor, the pattern detail.
  hapticVocabulary,

  /// Alarm test and cancel need a live link.
  alarmBandControls,

  /// Anything that sends a buzz to the band right now: Buzz the band, pattern
  /// previews.
  bandBuzz,

  /// Breathing measurements that compare beat timing need the band on.
  breathingBeatTiming,

  /// Renaming the band writes to it.
  bandRename,

  /// Check for updates (the sideload build).
  updateChecks,

  /// Contribute my health data: the build has it, or this install already
  /// consented and must be able to withdraw.
  healthShare,

  /// The Automation screen's Android intent copy.
  androidAutomation,

  /// Counting steps with this phone's own sensor (CMPedometer on iOS, the step
  /// counter on Android). Disabled, never hidden, where the platform has none:
  /// My devices keeps listing the phone and says why it cannot count.
  phoneSteps,
}

/// What a screen does with a [Feature].
sealed class Availability {
  const Availability();

  static const Availability available = _Available();
  static const Availability hidden = _Hidden();
  static Availability disabled(String reason) => _Disabled(reason);

  bool get isAvailable => this is _Available;
  bool get isHidden => this is _Hidden;
  bool get isDisabled => this is _Disabled;

  /// Why a [Disabled] row is off, else null.
  String? get reason => null;
}

final class _Available extends Availability {
  const _Available();
  @override
  String toString() => 'Availability.available';
}

final class _Hidden extends Availability {
  const _Hidden();
  @override
  String toString() => 'Availability.hidden';
}

final class _Disabled extends Availability {
  const _Disabled(this.reason);
  @override
  final String reason;
  @override
  bool operator ==(Object other) => other is _Disabled && other.reason == reason;
  @override
  int get hashCode => Object.hash(_Disabled, reason);
  @override
  String toString() => 'Availability.disabled($reason)';
}

/// Everything the answers depend on. Plain values, so equal inputs compare
/// equal and a provider can skip a rebuild when nothing moved.
class CapabilityInputs {
  const CapabilityInputs({
    this.platform = TargetPlatform.android,
    this.generation,
    this.ecgPaired = false,
    this.ecgLive = false,
    this.connected = false,
    this.devMode = false,
    this.flagsOff = const {},
    this.updateChecksBuild = false,
    this.healthShareBuild = false,
    this.healthShareConsent = false,
  });

  /// No band, the process-wide flags and platform: what a screen outside an
  /// AppState (a golden) sees. [devMode] is the caller's, since reading it
  /// needs Prefs.
  factory CapabilityInputs.detached({bool devMode = false}) => CapabilityInputs(
        platform: defaultTargetPlatform,
        devMode: devMode,
        flagsOff: {
          for (final f in FeatureFlag.values)
            if (!FeatureFlags.isOn(f)) f,
        },
      );

  final TargetPlatform platform;

  /// The paired band's family ('gen4' / 'gen5' / another adapter), null unknown.
  final String? generation;

  /// The paired band positively identified itself as a WHOOP MG, ever.
  final bool ecgPaired;

  /// The connected band identified itself as a WHOOP MG this connection.
  final bool ecgLive;

  /// A live link to the primary band right now.
  final bool connected;
  final bool devMode;

  /// Flags that are OFF; absent means on, the shipped default.
  final Set<FeatureFlag> flagsOff;

  /// The build can check for updates (sideload OTA).
  final bool updateChecksBuild;

  /// The build can contribute health data.
  final bool healthShareBuild;
  final bool healthShareConsent;

  @override
  bool operator ==(Object other) =>
      other is CapabilityInputs &&
      other.platform == platform &&
      other.generation == generation &&
      other.ecgPaired == ecgPaired &&
      other.ecgLive == ecgLive &&
      other.connected == connected &&
      other.devMode == devMode &&
      setEquals(other.flagsOff, flagsOff) &&
      other.updateChecksBuild == updateChecksBuild &&
      other.healthShareBuild == healthShareBuild &&
      other.healthShareConsent == healthShareConsent;

  @override
  int get hashCode => Object.hash(
        platform,
        generation,
        ecgPaired,
        ecgLive,
        connected,
        devMode,
        Object.hashAllUnordered(flagsOff),
        updateChecksBuild,
        healthShareBuild,
        healthShareConsent,
      );
}

/// The answers. Immutable; build a new one when an input moves.
class Capabilities {
  const Capabilities(this.inputs);

  final CapabilityInputs inputs;

  static const String _noEcg = 'This band has no ECG sensor';
  static const String _needMg = 'Take ECG needs a connected WHOOP MG.';
  static const String _noLink = 'Connect to the band first';
  static const String _noStepSensor = 'This device cannot count steps';

  bool _on(FeatureFlag f) => !inputs.flagsOff.contains(f);

  Availability _flag(FeatureFlag f) =>
      _on(f) ? Availability.available : Availability.hidden;

  Availability _when(bool ok) =>
      ok ? Availability.available : Availability.hidden;

  Availability _link(String reason) =>
      inputs.connected ? Availability.available : Availability.disabled(reason);

  Availability of(Feature f) => switch (f) {
        Feature.developerMode => _when(inputs.devMode),
        Feature.relayEntry => _when(
            inputs.platform == TargetPlatform.android &&
                _on(FeatureFlag.nativeRelay)),
        Feature.extraTapCounting => _flag(FeatureFlag.tapClassifiers),
        Feature.deviceLabTapTools => _flag(FeatureFlag.tapClassifiers),
        Feature.ecgTouchTaps => inputs.ecgPaired
            ? Availability.available
            : Availability.disabled(_noEcg),
        Feature.ecgEntry => _when(inputs.ecgPaired),
        Feature.ecgTake => inputs.connected && inputs.ecgLive
            ? Availability.available
            : Availability.disabled(_needMg),
        Feature.sourceCatalog => _flag(FeatureFlag.sourceResolverUi),
        Feature.signalPriority => _flag(FeatureFlag.sourceResolverUi),
        Feature.naturalWake => _flag(FeatureFlag.naturalWake),
        Feature.bandAlerts =>
          _when(bandAlertTargets.contains('band')),
        Feature.hapticVocabulary => _when(hapticProfile != null),
        Feature.alarmBandControls => _link('The band is not connected'),
        Feature.bandBuzz => _link(_noLink),
        Feature.breathingBeatTiming =>
          _link('Needs the band on. The comparison uses beat timing.'),
        Feature.bandRename => _link(_noLink),
        Feature.updateChecks => _when(inputs.updateChecksBuild),
        Feature.healthShare =>
          _when(inputs.healthShareBuild || inputs.healthShareConsent),
        Feature.androidAutomation =>
          _when(inputs.platform == TargetPlatform.android),
        Feature.phoneSteps => inputs.platform == TargetPlatform.android ||
                inputs.platform == TargetPlatform.iOS
            ? Availability.available
            : Availability.disabled(_noStepSensor),
      };

  /// Shorthand for the many call sites that only draw or do not draw.
  bool has(Feature f) => of(f).isAvailable;

  /// The measured haptic vocabulary of the paired band, null on a band without
  /// one. The one place that maps a generation to a profile.
  HapticDeviceProfile? get hapticProfile =>
      HapticDeviceProfile.forGeneration(inputs.generation);

  /// Where an alert may be delivered for the paired band's family. The
  /// registry owns which families have a band transport.
  Set<String> get bandAlertTargets =>
      AlertCapabilityRegistry.targetsForBandFamily(inputs.generation);

  @override
  bool operator ==(Object other) =>
      other is Capabilities && other.inputs == inputs;

  @override
  int get hashCode => inputs.hashCode;
}
