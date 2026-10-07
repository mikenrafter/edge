// The schedule of a "Pacing rates compared" session: several paced breathing
// rates back to back, each with a settle stretch (breathing finds the new
// rate, nothing is measured) and a measure stretch.
//
// Developer-only experiment. It compares how much heart rate oscillates per
// breath at each rate; it never names a "resonance frequency" and makes no
// health claim.
//
// Evidence:
//   Lehrer, Vaschillo & Vaschillo 2000, doi 10.1023/A:1009554825745
//   Shaffer & Meehan 2020, doi 10.3389/fnins.2020.570400
//
// Pure: no widgets, no timers, no BLE. Everything is a function of elapsed
// time, like lib/stress/breath_phases.dart, which this builds on.
//
import 'package:flutter/foundation.dart' show immutable;

import '../../stress/breath_phases.dart' as breath;

/// One paced rate inside a sweep. Blocks are back to back: a block's [end] is
/// the next block's [start]. The phase restarts at 0 (inhale) at [start].
@immutable
class SweepBlock {
  const SweepBlock({
    required this.rateBpm,
    required this.start,
    required this.settleEnd,
    required this.end,
  });

  final double rateBpm;
  final Duration start;

  /// Where the settle stretch ends and the measure window begins.
  final Duration settleEnd;
  final Duration end;

  /// Equal inhale and exhale; one cycle is 60 / [rateBpm] seconds.
  breath.BreathPattern get pattern {
    final phaseSeconds = 30.0 / rateBpm;
    return breath.BreathPattern(
      key: 'resonance_sweep_$rateBpm',
      label: 'Paced $rateBpm',
      description: 'Equal inhale and exhale at $rateBpm breaths per minute.',
      phases: [
        breath.BreathPhase(breath.BreathPhaseKind.inhale, phaseSeconds),
        breath.BreathPhase(breath.BreathPhaseKind.exhale, phaseSeconds),
      ],
    );
  }
}

class ResonanceSweepPlan {
  /// Builds a plan from hand-made blocks, skipping [build]'s validation.
  /// A seam for tests that need a plan without going through [build].
  ResonanceSweepPlan.fromBlocks(
    this.blocks, {
    this.hapticLimitPer2Min = 30,
    this.hapticReserve = 4,
  });

  /// Rates stay in the given order. Throws [ArgumentError] for an empty list,
  /// a rate that is not finite or outside 3..10 breaths/min, a duplicate, or
  /// a non-positive [measure].
  factory ResonanceSweepPlan.build({
    List<double> ratesBpm = const [6.5, 6.0, 5.5, 5.0, 4.5],
    Duration settle = const Duration(seconds: 30),
    Duration measure = const Duration(minutes: 2),
    int hapticLimitPer2Min = 30,
    int hapticReserve = 4,
  }) {
    if (ratesBpm.isEmpty ||
        ratesBpm.any((rate) => !rate.isFinite || rate < 3 || rate > 10) ||
        ratesBpm.toSet().length != ratesBpm.length ||
        measure <= Duration.zero) {
      throw ArgumentError('Invalid resonance sweep plan.');
    }

    var start = Duration.zero;
    final blocks = <SweepBlock>[];
    for (final rateBpm in ratesBpm) {
      final settleEnd = start + settle;
      final end = settleEnd + measure;
      blocks.add(SweepBlock(
        rateBpm: rateBpm,
        start: start,
        settleEnd: settleEnd,
        end: end,
      ));
      start = end;
    }
    return ResonanceSweepPlan.fromBlocks(
      blocks,
      hapticLimitPer2Min: hapticLimitPer2Min,
      hapticReserve: hapticReserve,
    );
  }

  final List<SweepBlock> blocks;
  final int hapticLimitPer2Min;
  final int hapticReserve;

  /// End of the last block.
  Duration get total => blocks.isEmpty ? Duration.zero : blocks.last.end;

  /// The rates in this plan, sorted ascending.
  List<double> get testedRates =>
      blocks.map((block) => block.rateBpm).toList()..sort();

  /// Band haptic commands one block's cues cost per 2 minutes: two cues per
  /// breath, so `ceil(rate * 2 * 2)`.
  static int cueCommandsPer2Min(double rateBpm) => (rateBpm * 4).ceil();

  /// Whether the band's command budget can carry this block's cues:
  /// [cueCommandsPer2Min] <= [hapticLimitPer2Min] - [hapticReserve].
  bool hapticEligible(SweepBlock block) =>
      cueCommandsPer2Min(block.rateBpm) <=
      hapticLimitPer2Min - hapticReserve;

  /// The block running at [elapsed]; start inclusive, end exclusive. Null
  /// before the start and at or after [total].
  SweepBlock? blockAt(Duration elapsed) {
    if (elapsed < Duration.zero || elapsed >= total) return null;
    for (final block in blocks) {
      if (elapsed >= block.start && elapsed < block.end) return block;
    }
    return null;
  }

  /// Where the breathing cue is at [elapsed], with the phase measured from the
  /// block's own start. Null outside the plan.
  ({SweepBlock block, breath.BreathPhase phase, double progress, int cycle})?
      phaseAt(
    Duration elapsed,
  ) {
    final block = blockAt(elapsed);
    if (block == null) return null;
    final phase = breath.phaseAt(block.pattern, elapsed - block.start);
    if (phase == null) return null;
    return (
      block: block,
      phase: phase.phase,
      progress: phase.progress,
      cycle: phase.cycle,
    );
  }

  /// True only inside a block's measure window (settleEnd inclusive, end
  /// exclusive).
  bool inMeasureWindow(Duration elapsed) {
    final block = blockAt(elapsed);
    return block != null && elapsed >= block.settleEnd;
  }
}
