// Shared builders for the resonance sweep tests: hand-made blocks, and
// synthetic beats with a known heart-rate oscillation at the paced frequency.
import 'dart:math' as math;

import 'package:openstrap_edge/explore/resonance/resonance_analyzer.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_plan.dart';

const Duration kSettle = Duration(seconds: 30);
const Duration kMeasure = Duration(minutes: 2);

/// The default plan order, fastest first.
const List<double> kPlanRates = [6.5, 6.0, 5.5, 5.0, 4.5];

/// The same rates ascending, as `ResonanceSweepPlan.testedRates` gives them.
const List<double> kRatesAsc = [4.5, 5.0, 5.5, 6.0, 6.5];

/// Back-to-back blocks, built by hand so the analyzer and controller tests do
/// not depend on `ResonanceSweepPlan.build`.
List<SweepBlock> blocksFor(
  List<double> rates, {
  Duration settle = kSettle,
  Duration measure = kMeasure,
}) {
  final out = <SweepBlock>[];
  var t = Duration.zero;
  for (final r in rates) {
    out.add(SweepBlock(
      rateBpm: r,
      start: t,
      settleEnd: t + settle,
      end: t + settle + measure,
    ));
    t += settle + measure;
  }
  return out;
}

ResonanceSweepPlan planFor(
  List<double> rates, {
  Duration settle = kSettle,
  Duration measure = kMeasure,
}) =>
    ResonanceSweepPlan.fromBlocks(
        blocksFor(rates, settle: settle, measure: measure));

/// Beats across [b]'s measure window with HR = meanHr + A sin(2 pi rate/60 t),
/// t counted from the block start. Each beat's rr is exactly the HR sampled at
/// the previous beat, so the true swing (max - min) is 2A.
List<SweepBeat> synthBeats(
  SweepBlock b, {
  required double amplitudeBpm,
  double meanHr = 65,
}) {
  final beats = <SweepBeat>[];
  final startMs = b.start.inMilliseconds;
  final endMs = b.end.inMilliseconds;
  var t = b.settleEnd.inMilliseconds.toDouble();
  while (true) {
    final tSec = (t - startMs) / 1000;
    final hr =
        meanHr + amplitudeBpm * math.sin(2 * math.pi * b.rateBpm / 60 * tSec);
    final rr = 60000 / hr;
    t += rr;
    if (t > endMs) break;
    beats.add(SweepBeat(tMs: t.round(), rrMs: rr, observed: true));
  }
  return beats;
}

/// A copy of [beats] where those [pick] selects are flagged not observed, and
/// optionally given a wild [rrMs] (what an interpolated beat might carry).
List<SweepBeat> withUnobserved(
  List<SweepBeat> beats,
  bool Function(int index, SweepBeat beat) pick, {
  double? rrMs,
}) =>
    [
      for (var i = 0; i < beats.length; i++)
        pick(i, beats[i])
            ? SweepBeat(
                tMs: beats[i].tMs,
                rrMs: rrMs ?? beats[i].rrMs,
                observed: false)
            : beats[i],
    ];

BlockInput inputFor(
  SweepBlock b, {
  double amplitudeBpm = 4,
  double stillFraction = 1.0,
  int missedCues = 0,
  bool hapticOnly = false,
  List<SweepBeat>? beats,
}) =>
    BlockInput(
      block: b,
      beats: beats ?? synthBeats(b, amplitudeBpm: amplitudeBpm),
      stillFraction: stillFraction,
      missedCues: missedCues,
      hapticOnly: hapticOnly,
    );

/// One input per rate in plan order. [amp] maps a rate to the HR amplitude A
/// (bpm) of its synthetic beats; rates in [reject] get stillFraction 0.5 so
/// the movement gate rejects them.
List<BlockInput> sweepInputs(
  Map<double, double> amp, {
  Set<double> reject = const {},
  List<double> rates = kPlanRates,
}) =>
    [
      for (final b in blocksFor(rates))
        inputFor(
          b,
          amplitudeBpm: amp[b.rateBpm]!,
          stillFraction: reject.contains(b.rateBpm) ? 0.5 : 1.0,
        ),
    ];
