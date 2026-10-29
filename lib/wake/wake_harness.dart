// Wake dev harness (developer mode only): which early-wake rule runs and its
// coefficients. It only changes the early-buzz decision inside the window; the
// fallback alarm, snooze and fire guard never read it. See
// edge.research/wake-pr/dev-harness-spec.md §10.
//
// Parse policy (one, documented): an unknown rule, a wrong JSON type or a
// non-finite number gives THAT field its default; a finite number outside its
// bounds is clamped to the nearest bound. Corrupt JSON gives all defaults.
// Every degradation is added to `errors`; nothing throws.
import 'dart:convert';
import 'dart:math' as math;

import 'wake_confounders.dart';

/// SharedPreferences key (JSON). Device-local developer state: listed in
/// kPrefsNotBackedUp, so a restored experiment never changes a wake rule.
const String kWakeHarnessPrefKey = 'dev.wake_harness.v1';

enum WakeRule { natural, legacy, hybrid }

/// One coefficient's bounds, step and default (the UI reads these).
class HarnessBound {
  const HarnessBound(this.min, this.max, this.step, this.defaultValue);
  final double min, max, step, defaultValue;
}

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

  // Defaults equal the production constants (kNaturalRemTriggerRunSec,
  // kNaturalMinConfidence, kNaturalMaxEvidenceAgeMs / 1000, ConfounderProfile
  // identity). HR and motion bounds are what ConfounderProfile accepts.
  static const triggerRunBound = HarnessBound(30, 300, 30, 120);
  static const minConfidenceBound = HarnessBound(0, 0.9, 0.05, 0.3);
  static const evidenceAgeBound = HarnessBound(60, 600, 30, 150);
  static const hrRiseBound = HarnessBound(4, 15, 1, 4);
  static const motionCeilingBound = HarnessBound(0, 0.08, 0.01, 0.08);
  static const vetoBound = HarnessBound(0, 0.9, 0.05, 0.5);

  final WakeRule rule;
  final int triggerRunSec;
  final double minConfidence;
  final bool remOnly;

  /// The planner's own age cap. The live stager abstains after 120 s without
  /// new data regardless, so raising this cannot revive an absent stage.
  final int evidenceAgeCapSec;
  final double hrRiseBpm;
  final double motionCeilingG;
  final double vetoMinConfidence;
  final bool requireRemOrWake;

  factory WakeHarnessConfig.parse(
    String? raw, {
    List<String>? errors,
  }) {
    if (raw == null || raw.isEmpty) return defaults;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      errors?.add('wake harness: unreadable config ($e)');
      return defaults;
    }
    if (decoded is! Map) {
      errors?.add('wake harness: config is not an object');
      return defaults;
    }
    final j = decoded;
    final problems = <String>[];
    double num_(String k, HarnessBound b) {
      final v = j[k];
      if (v == null) return b.defaultValue;
      if (v is! num || !v.isFinite) {
        problems.add(k);
        return b.defaultValue;
      }
      final c = v.toDouble().clamp(b.min, b.max).toDouble();
      if (c != v) problems.add('$k clamped');
      return c;
    }

    bool bool_(String k) {
      final v = j[k];
      if (v == null) return false;
      if (v is! bool) {
        problems.add(k);
        return false;
      }
      return v;
    }

    var rule = WakeRule.natural;
    final r = j['rule'];
    if (r != null) {
      final match = WakeRule.values.where((e) => e.name == r);
      if (match.isEmpty) {
        problems.add('rule $r');
      } else {
        rule = match.first;
      }
    }
    final c = WakeHarnessConfig(
      rule: rule,
      triggerRunSec: num_('triggerRunSec', triggerRunBound).round(),
      minConfidence: num_('minConfidence', minConfidenceBound),
      remOnly: bool_('remOnly'),
      evidenceAgeCapSec: num_('evidenceAgeCapSec', evidenceAgeBound).round(),
      hrRiseBpm: num_('hrRiseBpm', hrRiseBound),
      motionCeilingG: num_('motionCeilingG', motionCeilingBound),
      vetoMinConfidence: num_('vetoMinConfidence', vetoBound),
      requireRemOrWake: bool_('requireRemOrWake'),
    );
    if (problems.isNotEmpty) {
      errors?.add('wake harness: defaulted ${problems.join(', ')}');
    }
    return c;
  }

  Map<String, Object?> toJson() => {
    'rule': rule.name,
    'triggerRunSec': triggerRunSec,
    'minConfidence': minConfidence,
    'remOnly': remOnly,
    'evidenceAgeCapSec': evidenceAgeCapSec,
    'hrRiseBpm': hrRiseBpm,
    'motionCeilingG': motionCeilingG,
    'vetoMinConfidence': vetoMinConfidence,
    'requireRemOrWake': requireRemOrWake,
  };

  String encode() => jsonEncode(toJson());

  bool get isDefault => encode() == defaults.encode();

  WakeHarnessConfig copyWith({
    WakeRule? rule,
    int? triggerRunSec,
    double? minConfidence,
    bool? remOnly,
    int? evidenceAgeCapSec,
    double? hrRiseBpm,
    double? motionCeilingG,
    double? vetoMinConfidence,
    bool? requireRemOrWake,
  }) => WakeHarnessConfig.parse(jsonEncode({
    ...toJson(),
    'rule': (rule ?? this.rule).name,
    'triggerRunSec': ?triggerRunSec,
    'minConfidence': ?minConfidence,
    'remOnly': ?remOnly,
    'evidenceAgeCapSec': ?evidenceAgeCapSec,
    'hrRiseBpm': ?hrRiseBpm,
    'motionCeilingG': ?motionCeilingG,
    'vetoMinConfidence': ?vetoMinConfidence,
    'requireRemOrWake': ?requireRemOrWake,
  }));

  Set<String> get eligibleStages =>
      remOnly ? const {'rem'} : const {'rem', 'wake'};

  /// The chosen trigger run plus the learned offset (clamped ±60 as today),
  /// never below 30 s.
  int effectiveTriggerRunSec(int learnedOffsetSec) =>
      math.max(30, triggerRunSec + learnedOffsetSec.clamp(-60, 60));

  /// legacy/hybrid: the chosen HR rise and motion ceiling replace the base
  /// constants; the journal policy still tightens on top (max HR, min motion,
  /// every flag kept). natural: the journal profile unchanged.
  ConfounderProfile compose(ConfounderProfile journal) =>
      rule == WakeRule.natural
      ? journal
      : journal.combine(
          ConfounderProfile(
            hrArousalBpm: hrRiseBpm,
            motionCeilingG: motionCeilingG,
          ),
        );

  /// The durable record of what actually ran: the stored params and the
  /// effective values after learned offsets and journal composition, the
  /// window and lead it ran on, and the rule the route really evaluated
  /// ([ranAs]; the stored rule when null). The digest identifies that
  /// effective snapshot (never the time it was written).
  Map<String, Object?> provenance({
    required int learnedOffsetSec,
    required ConfounderProfile composed,
    WakeRule? ranAs,
    int windowLeadMinutes = 0,
    int windowMinutes = 0,
  }) {
    final ran = ranAs ?? rule;
    final effective = <String, Object?>{
      'rule': ran.name,
      'windowMinutes': windowMinutes,
      'windowLeadMinutes': windowLeadMinutes,
      if (ran == WakeRule.natural) ...{
        'triggerRunSec': effectiveTriggerRunSec(learnedOffsetSec),
        'learnedTriggerOffsetSec': learnedOffsetSec,
        'minConfidence': minConfidence,
        'eligibleStages': (eligibleStages.toList()..sort()),
      },
      if (ran != WakeRule.legacy) 'evidenceAgeCapSec': evidenceAgeCapSec,
      // Every composed policy field a decision reads.
      'hrRiseBpm': composed.hrArousalBpm,
      'motionCeilingG': composed.motionCeilingG,
      'protectionMinutes': composed.protectionMinutes,
      'trendWindowMinutes': composed.trendWindowMinutes,
      'trendThresholdFactor': composed.trendThresholdFactor,
      'disableEarlyDelivery': composed.disableEarlyDelivery,
      'track': composed.track,
      if (ran == WakeRule.hybrid) ...{
        'vetoMinConfidence': vetoMinConfidence,
        'requireRemOrWake': requireRemOrWake,
      },
    };
    final canonical = jsonEncode(effective);
    return {
      'version': 1,
      'rule': ran.name,
      'params': toJson(),
      'effective': effective,
      'digest': _fnv1a(canonical),
    };
  }
}

String _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode(s)) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// The config the wake tick must use: developer mode off ignores the stored
/// value entirely (S4).
WakeHarnessConfig effectiveWakeHarness({
  required bool developerMode,
  required String? stored,
  List<String>? errors,
}) => developerMode
    ? WakeHarnessConfig.parse(stored, errors: errors)
    : WakeHarnessConfig.defaults;
