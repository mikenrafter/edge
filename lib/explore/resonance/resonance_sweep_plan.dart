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
// RED-phase stub: every body throws until the implementation lands.
import 'package:flutter/foundation.dart' show immutable;

import '../../stress/breath_phases.dart';

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
  BreathPattern get pattern => throw UnimplementedError();
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
  }) =>
      throw UnimplementedError();

  final List<SweepBlock> blocks;
  final int hapticLimitPer2Min;
  final int hapticReserve;

  /// End of the last block.
  Duration get total => throw UnimplementedError();

  /// The rates in this plan, sorted ascending.
  List<double> get testedRates => throw UnimplementedError();

  /// Band haptic commands one block's cues cost per 2 minutes: two cues per
  /// breath, so `ceil(rate * 2 * 2)`.
  static int cueCommandsPer2Min(double rateBpm) => throw UnimplementedError();

  /// Whether the band's command budget can carry this block's cues:
  /// [cueCommandsPer2Min] <= [hapticLimitPer2Min] - [hapticReserve].
  bool hapticEligible(SweepBlock block) => throw UnimplementedError();

  /// The block running at [elapsed]; start inclusive, end exclusive. Null
  /// before the start and at or after [total].
  SweepBlock? blockAt(Duration elapsed) => throw UnimplementedError();

  /// Where the breathing cue is at [elapsed], with the phase measured from the
  /// block's own start. Null outside the plan.
  ({SweepBlock block, BreathPhase phase, double progress, int cycle})? phaseAt(
    Duration elapsed,
  ) =>
      throw UnimplementedError();

  /// True only inside a block's measure window (settleEnd inclusive, end
  /// exclusive).
  bool inMeasureWindow(Duration elapsed) => throw UnimplementedError();
}
