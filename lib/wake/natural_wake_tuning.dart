// P2 RED signatures only. Pure policy; no mutable state owner.
import 'wake_outcome.dart';

// Proposed product bounds, not physiological cutoffs: offset [-60,60] s,
// step 15 s; window lead [-10,10] min, step 1 min. Base trigger remains 120 s.
class NaturalWakeParameters {
  const NaturalWakeParameters({
    this.triggerRunOffsetSec = 0,
    this.windowLeadMinutes = 0,
    this.lastLearnedEpoch,
  });
  final int triggerRunOffsetSec, windowLeadMinutes;
  final int? lastLearnedEpoch;
}

class NaturalTuningDecision {
  const NaturalTuningDecision({
    this.parameters = const NaturalWakeParameters(),
    this.applied = false,
    this.reason = 'red_stub',
    this.eligibleNights = 0,
    this.expectEarlyRem = true,
    this.dreamContextScore,
  });
  final NaturalWakeParameters parameters;
  final bool applied, expectEarlyRem;
  final String reason;
  final int eligibleNights;
  final double? dreamContextScore;
}

abstract final class NaturalWakeTuning {
  // Alcohol nights must be excluded from updates and early-REM expectations.
  // Ebrahim et al. 2013, doi:10.1111/acer.12006: first-half REM is suppressed
  // and delayed; see edge.research/substance-research/SYNTHESIS.md.
  static NaturalTuningDecision evaluate(
    List<WakeNightOutcome> history, {
    NaturalWakeParameters current = const NaturalWakeParameters(),
    WakeSubstance? tonightSubstance,
  }) => const NaturalTuningDecision();
}
