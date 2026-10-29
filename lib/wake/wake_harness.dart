// Wake dev harness (developer mode only): which early-wake rule runs and its
// coefficients. Never touches the fallback alarm; see dev-harness-spec §10.
import 'wake_confounders.dart';

/// SharedPreferences key (JSON). Device-local, never backed up.
const String kWakeHarnessPrefKey = 'dev.wake_harness.v1';

enum WakeRule { natural, legacy, hybrid }

class WakeHarnessConfig {
  const WakeHarnessConfig({
    this.rule = WakeRule.natural,
    this.triggerRunSec = 120,
    this.minConfidence = 0.3,
    this.remOnly = false,
    this.evidenceAgeCapSec = 150,
    this.hrRiseBpm = 4,
    this.motionCeilingG = 0.08,
    this.vetoMinConfidence = 0.5,
    this.requireRemOrWake = false,
  });

  static const defaults = WakeHarnessConfig();

  final WakeRule rule;
  final int triggerRunSec;
  final double minConfidence;
  final bool remOnly;
  final int evidenceAgeCapSec;
  final double hrRiseBpm;
  final double motionCeilingG;
  final double vetoMinConfidence;
  final bool requireRemOrWake;

  factory WakeHarnessConfig.parse(
    String? raw, {
    void Function(String error)? onError,
  }) => defaults;

  String encode() => '{}';

  bool get isDefault => true;

  Set<String> get eligibleStages => const {'rem', 'wake'};

  int effectiveTriggerRunSec(int learnedOffsetSec) => 120 + learnedOffsetSec;

  ConfounderProfile compose(ConfounderProfile journal) => journal;

  Map<String, Object?> provenance({
    required int learnedOffsetSec,
    required ConfounderProfile composed,
  }) => const {};
}

/// The config the wake tick must use: developer mode off ignores the stored
/// value entirely (S4).
WakeHarnessConfig effectiveWakeHarness({
  required bool developerMode,
  required String? stored,
  void Function(String error)? onError,
}) => WakeHarnessConfig.defaults;
