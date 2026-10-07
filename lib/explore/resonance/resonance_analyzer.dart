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

  /// 0..1 share of the measure window judged still; null when there is no
  /// motion evidence at all. Unknown is not still: the block abstains
  /// ([BlockRejection.movementUnknown]).
  final double? stillFraction;
  final int missedCues;
  final bool hapticOnly;
}

enum BlockRejection {
  lowCoverage,
  artifacts,
  movement,

  /// No motion evidence for the block (no accelerometer data reached the
  /// sweep). It abstains rather than counting as still.
  movementUnknown,
  missedCues,
  tooFewCycles,
}

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

  /// Observed beats over all INPUT beats, including beats the correction stage
  /// dropped (the decode hands those over as unobserved placeholders).
  final double observedFraction;

  /// Complete cycles that had enough observed beats to count.
  final int cycles;
  final BlockRejection? rejection;

  bool get admitted => rejection == null && amplitudeBpm != null;
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
}) {
  final blocks = [for (final input in inputs) _scoreBlock(input)];
  final noRate = SweepComparison(
    blocks: blocks,
    outcome: ComparisonOutcome.inconclusiveTooFewBlocks,
    rateBpm: null,
    range: null,
  );

  if (stoppedEarly) {
    return SweepComparison(
      blocks: blocks,
      outcome: ComparisonOutcome.stoppedEarly,
      rateBpm: null,
      range: null,
    );
  }

  final admitted = blocks.where((block) => block.admitted).toList();
  if (admitted.length < kMinAdmittedBlocks) return noRate;

  final amplitudes = admitted.map((block) => block.amplitudeBpm!).toList();
  final bestAmplitude = amplitudes.reduce(_max);
  final worstAmplitude = amplitudes.reduce(_min);
  if (bestAmplitude - worstAmplitude < kFlatSpreadBpm) {
    return SweepComparison(
      blocks: blocks,
      outcome: ComparisonOutcome.inconclusiveFlat,
      rateBpm: null,
      range: null,
    );
  }

  final tieThreshold = _max(kTieAbsoluteBpm, bestAmplitude * kTieRelative);
  final tied = admitted
      .where((block) => bestAmplitude - block.amplitudeBpm! <= tieThreshold)
      .toList()
    ..sort((a, b) => a.rateBpm.compareTo(b.rateBpm));

  final tested = testedRates.where((rate) => rate.isFinite).toList()..sort();
  final admittedRates = admitted.map((block) => block.rateBpm).toList()..sort();
  final loBoundary = <double>{
    if (tested.isNotEmpty) tested.first,
    admittedRates.first,
  };
  final hiBoundary = <double>{
    if (tested.isNotEmpty) tested.last,
    admittedRates.last,
  };
  if (tied.any((block) =>
      loBoundary.contains(block.rateBpm) || hiBoundary.contains(block.rateBpm))) {
    return SweepComparison(
      blocks: blocks,
      outcome: ComparisonOutcome.inconclusiveBoundary,
      rateBpm: null,
      range: null,
    );
  }

  // Every tested rate between the tie's ends must itself be in the tie. A
  // rate that scored lower is a gap, and one that was rejected or never
  // scored is a hole: a range spanning it names a rate nothing measured.
  final tiedRates = tied.map((block) => block.rateBpm).toSet();
  final low = tied.first.rateBpm;
  final high = tied.last.rateBpm;
  final hasGap = [...tested, ...blocks.map((block) => block.rateBpm)].any(
      (rate) => rate > low && rate < high && !tiedRates.contains(rate));
  if (hasGap) {
    return SweepComparison(
      blocks: blocks,
      outcome: ComparisonOutcome.inconclusiveFlat,
      rateBpm: null,
      range: null,
    );
  }

  if (tied.length > 1) {
    return SweepComparison(
      blocks: blocks,
      outcome: ComparisonOutcome.tiedRange,
      rateBpm: null,
      range: (lo: low, hi: high),
    );
  }
  return SweepComparison(
    blocks: blocks,
    outcome: ComparisonOutcome.tentativeRate,
    rateBpm: tied.single.rateBpm,
    range: null,
  );
}

BlockResult _scoreBlock(BlockInput input) {
  final measureMs =
      input.block.end.inMilliseconds - input.block.settleEnd.inMilliseconds;
  final measureStartMs = input.block.settleEnd.inMilliseconds;
  final measureEndMs = input.block.end.inMilliseconds;
  final beats = input.beats;
  final observed = beats
      .where((beat) =>
          beat.observed && beat.rrMs.isFinite && beat.rrMs > 0)
      .toList();
  final coverage = measureMs <= 0
      ? 0.0
      : observed
              .where((beat) =>
                  beat.tMs >= measureStartMs && beat.tMs < measureEndMs)
              .fold<double>(0, (sum, beat) => sum + beat.rrMs) /
          measureMs;
  final observedFraction = beats.isEmpty ? 0.0 : observed.length / beats.length;
  final cycleMs = 60000.0 / input.block.rateBpm;
  final cycleAmplitudes = <double>[];
  if (cycleMs.isFinite && cycleMs > 0) {
    final firstCycle =
        ((measureStartMs - input.block.start.inMilliseconds) / cycleMs).ceil();
    final lastCycle =
        ((measureEndMs - input.block.start.inMilliseconds) / cycleMs).floor();
    for (var cycle = firstCycle; cycle < lastCycle; cycle++) {
      final cycleStart = input.block.start.inMilliseconds + cycle * cycleMs;
      final cycleEnd = cycleStart + cycleMs;
      final cycleBeats = observed.where((beat) =>
          beat.tMs >= cycleStart && beat.tMs < cycleEnd).toList();
      if (cycleBeats.length < kMinBeatsPerCycle) continue;
      final heartRates = cycleBeats.map((beat) => 60000 / beat.rrMs);
      cycleAmplitudes.add(heartRates.reduce(_max) - heartRates.reduce(_min));
    }
  }

  BlockRejection? rejection;
  if (coverage < kMinCoverage) {
    rejection = BlockRejection.lowCoverage;
  } else if (observedFraction < kMinObservedFraction) {
    rejection = BlockRejection.artifacts;
  } else if (input.stillFraction == null) {
    rejection = BlockRejection.movementUnknown;
  } else if (input.stillFraction! < kMinStillFraction) {
    rejection = BlockRejection.movement;
  } else if (input.hapticOnly && input.missedCues > 0) {
    rejection = BlockRejection.missedCues;
  } else if (cycleAmplitudes.length < kMinCycles) {
    rejection = BlockRejection.tooFewCycles;
  }

  return BlockResult(
    rateBpm: input.block.rateBpm,
    amplitudeBpm: rejection == null
        ? cycleAmplitudes.fold<double>(0, (sum, value) => sum + value) /
            cycleAmplitudes.length
        : null,
    coverage: coverage,
    observedFraction: observedFraction,
    cycles: cycleAmplitudes.length,
    rejection: rejection,
  );
}

double _max(double a, double b) => a > b ? a : b;

double _min(double a, double b) => a < b ? a : b;
