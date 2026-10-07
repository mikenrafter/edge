// Scores each paced block and compares the blocks of a sweep.
//
// PROTOTYPE. This is a metric, so it moves to the analytics repo before any
// merge to edge (AGENTS.md section 1). It lives here only so the experiment
// can run end to end.
//
// What it measures: how much heart rate swings per breath at each paced rate.
// Output is a tentative practice rate or, often, "inconclusive". It is never
// called a "resonance frequency" and makes no health claim. Absent or thin
// input abstains (null / a rejection), it never imputes (AGENTS.md 3.3, 4.1).
//
// Evidence:
//   Lehrer, Vaschillo & Vaschillo 2000, doi 10.1023/A:1009554825745
//   Shaffer & Meehan 2020, doi 10.3389/fnins.2020.570400
//
// The gates below are proposed engineering gates, not published thresholds.
//
// RED-phase stub: every body throws until the implementation lands.
import 'package:flutter/foundation.dart' show immutable;

import 'resonance_sweep_plan.dart';

/// Share of the measure window that observed beats must cover.
const double kMinCoverage = 0.90;

/// Share of beats that must be observed (not interpolated or replaced by the
/// correction stage).
const double kMinObservedFraction = 0.95;

/// Share of the measure window that must be judged still.
const double kMinStillFraction = 0.90;

/// Complete paced cycles a block needs.
const int kMinCycles = 6;

/// Observed beats a cycle needs to count.
const int kMinBeatsPerCycle = 3;

/// Admitted blocks a comparison needs.
const int kMinAdmittedBlocks = 3;

/// Best minus worst admitted amplitude below which the sweep is flat (bpm).
const double kFlatSpreadBpm = 1.0;

/// A block ties the best when within max([kTieAbsoluteBpm],
/// [kTieRelative] of the best).
const double kTieAbsoluteBpm = 0.5;
const double kTieRelative = 0.10;

@immutable
class SweepBeat {
  const SweepBeat({
    required this.tMs,
    required this.rrMs,
    required this.observed,
  });

  /// Session-relative time of the beat, in ms (same clock as the plan).
  final int tMs;
  final double rrMs;

  /// False when the correction stage interpolated or replaced the beat.
  final bool observed;
}

@immutable
class BlockInput {
  const BlockInput({
    required this.block,
    required this.beats,
    required this.stillFraction,
    required this.missedCues,
    required this.hapticOnly,
  });

  final SweepBlock block;

  /// Beats inside the measure window only.
  final List<SweepBeat> beats;

  /// 0..1 share of the measure window judged still.
  final double stillFraction;
  final int missedCues;
  final bool hapticOnly;
}

enum BlockRejection { lowCoverage, artifacts, movement, missedCues, tooFewCycles }

@immutable
class BlockResult {
  const BlockResult({
    required this.rateBpm,
    required this.amplitudeBpm,
    required this.coverage,
    required this.observedFraction,
    required this.cycles,
    required this.rejection,
  });

  final double rateBpm;

  /// Mean over complete paced cycles of (max HR - min HR) within the cycle,
  /// from observed beats only. Null when rejected.
  final double? amplitudeBpm;

  /// Sum of observed rr over the measure window length.
  final double coverage;

  /// Observed beats over all beats.
  final double observedFraction;

  /// Complete cycles that had enough observed beats to count.
  final int cycles;
  final BlockRejection? rejection;

  bool get admitted => throw UnimplementedError();
}

enum ComparisonOutcome {
  tentativeRate,
  tiedRange,
  inconclusiveTooFewBlocks,
  inconclusiveFlat,
  inconclusiveBoundary,
  stoppedEarly,
}

@immutable
class SweepComparison {
  const SweepComparison({
    required this.blocks,
    required this.outcome,
    required this.rateBpm,
    required this.range,
  });

  final List<BlockResult> blocks;
  final ComparisonOutcome outcome;

  /// Non-null only for [ComparisonOutcome.tentativeRate].
  final double? rateBpm;

  /// Non-null only for [ComparisonOutcome.tiedRange].
  final ({double lo, double hi})? range;
}

/// Scores every input, then decides the outcome. [testedRates] is every rate
/// in the plan, ascending; its min and max are the boundaries.
SweepComparison compareBlocks(
  List<BlockInput> inputs, {
  required List<double> testedRates,
  bool stoppedEarly = false,
}) =>
    throw UnimplementedError();
