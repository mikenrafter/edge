import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/resonance/resonance_analyzer.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_plan.dart';

import 'support/sweep_fixtures.dart';

/// Scores one block through the public comparison entry point.
BlockResult scoreOne(BlockInput input) =>
    compareBlocks([input], testedRates: [input.block.rateBpm]).blocks.single;

void main() {
  final b6 = blocksFor([6.0]).single;

  group('amplitude', () {
    for (final rate in [6.5, 6.0, 5.5, 5.0, 4.5]) {
      for (final a in [3.0, 5.0, 8.0]) {
        test('rate $rate, HR swing A=$a reads about 2A', () {
          final b = blocksFor([rate]).single;
          final r = scoreOne(inputFor(b, amplitudeBpm: a));
          expect(r.admitted, isTrue);
          expect(r.rejection, isNull);
          expect(r.rateBpm, rate);
          // One beat a second samples the sine; a peak can be missed by a
          // few percent, never overshot.
          expect(r.amplitudeBpm, inInclusiveRange(2 * a * 0.90, 2 * a + 1e-6));
          expect(r.coverage, greaterThan(0.98));
          expect(r.observedFraction, 1.0);
          expect(r.cycles, greaterThanOrEqualTo(6));
        });
      }
    }

    test('a bigger swing reads bigger', () {
      final small = scoreOne(inputFor(b6, amplitudeBpm: 3)).amplitudeBpm!;
      final big = scoreOne(inputFor(b6, amplitudeBpm: 8)).amplitudeBpm!;
      expect(big, greaterThan(small * 2));
    });

    test('cycles are counted from the block start (6.0 bpm: 12, 5.0 bpm: 9)',
        () {
      // 6.0: ten second cycles, first complete one starts at 30 s, last ends
      // at 150 s. 5.0: twelve second cycles, first complete one starts at
      // 36 s, the ninth ends at 144 s.
      expect(scoreOne(inputFor(b6)).cycles, inInclusiveRange(11, 12));
      expect(scoreOne(inputFor(blocksFor([5.0]).single)).cycles, 9);
    });

    test('a window with no beats abstains instead of inventing a number', () {
      final r = scoreOne(inputFor(b6, beats: const []));
      expect(r.admitted, isFalse);
      expect(r.rejection, BlockRejection.lowCoverage);
      expect(r.amplitudeBpm, isNull);
      expect(r.coverage, 0.0);
      expect(r.observedFraction.isFinite, isTrue);
    });
  });

  group('observed versus interpolated beats', () {
    test('interpolated beats do not count toward coverage', () {
      final beats = synthBeats(b6, amplitudeBpm: 5);
      final full = scoreOne(inputFor(b6, beats: beats));
      // Every 25th beat (4 percent) replaced by the correction stage.
      final patched = scoreOne(inputFor(b6,
          beats: withUnobserved(beats, (i, _) => i % 25 == 0)));
      expect(patched.rejection, isNull);
      expect(patched.coverage, lessThan(full.coverage - 0.02));
      expect(patched.observedFraction, closeTo(0.96, 0.01));
    });

    test('their wild rr values never reach the amplitude', () {
      final beats = synthBeats(b6, amplitudeBpm: 5);
      // rr of 250 ms would read as 240 bpm if it were used.
      final patched = scoreOne(inputFor(b6,
          beats: withUnobserved(beats, (i, _) => i % 40 == 0, rrMs: 250)));
      expect(patched.rejection, isNull);
      expect(patched.amplitudeBpm, lessThanOrEqualTo(10 + 1e-6));
      expect(patched.amplitudeBpm, greaterThan(9.0));
    });

    test('a cycle with only 2 observed beats does not count', () {
      final b = SweepBlock(
        rateBpm: 5.0,
        start: Duration.zero,
        settleEnd: const Duration(seconds: 30),
        end: const Duration(seconds: 330),
      );
      final beats = synthBeats(b, amplitudeBpm: 5);
      final baseline = scoreOne(inputFor(b, beats: beats));
      // Cycle 10 spans 120 s .. 132 s. Keep its first n beats observed.
      List<SweepBeat> keep(int n) {
        var seen = 0;
        return withUnobserved(beats, (i, beat) {
          if (beat.tMs < 120000 || beat.tMs >= 132000) return false;
          return seen++ >= n;
        });
      }

      final two = scoreOne(inputFor(b, beats: keep(2)));
      final three = scoreOne(inputFor(b, beats: keep(3)));
      expect(two.rejection, isNull);
      expect(two.cycles, baseline.cycles - 1);
      expect(three.rejection, isNull);
      expect(three.cycles, baseline.cycles);
    });
  });

  group('admission gates', () {
    test('a gap in the beats is low coverage', () {
      final beats = synthBeats(b6, amplitudeBpm: 5)
          .where((b) => b.tMs < 60000 || b.tMs >= 80000) // 20 s of 120 s
          .toList();
      final r = scoreOne(inputFor(b6, beats: beats));
      expect(r.rejection, BlockRejection.lowCoverage);
      expect(r.admitted, isFalse);
      expect(r.amplitudeBpm, isNull);
      expect(r.coverage, lessThan(kMinCoverage));
    });

    test('too many corrected beats is artifacts', () {
      final beats = synthBeats(b6, amplitudeBpm: 5);
      // Every 15th beat (6.7 percent): coverage stays above the gate.
      final r = scoreOne(inputFor(b6,
          beats: withUnobserved(beats, (i, _) => i % 15 == 0)));
      expect(r.rejection, BlockRejection.artifacts);
      expect(r.amplitudeBpm, isNull);
      expect(r.coverage, greaterThanOrEqualTo(kMinCoverage));
      expect(r.observedFraction, lessThan(kMinObservedFraction));
    });

    test('moving is movement; exactly the gate is admitted', () {
      final under =
          scoreOne(inputFor(b6, stillFraction: kMinStillFraction - 0.01));
      expect(under.rejection, BlockRejection.movement);
      expect(under.amplitudeBpm, isNull);
      final at = scoreOne(inputFor(b6, stillFraction: kMinStillFraction));
      expect(at.rejection, isNull);
      expect(at.amplitudeBpm, isNotNull);
    });

    test('a missed cue rejects a haptic-only block, and only that', () {
      final hapticOnly =
          scoreOne(inputFor(b6, missedCues: 1, hapticOnly: true));
      expect(hapticOnly.rejection, BlockRejection.missedCues);
      expect(hapticOnly.amplitudeBpm, isNull);
      // With the on-screen ring as well, a missed buzz is not a lost cue.
      final withRing =
          scoreOne(inputFor(b6, missedCues: 3, hapticOnly: false));
      expect(withRing.rejection, isNull);
      // No missed cues on a haptic-only block is fine.
      expect(scoreOne(inputFor(b6, hapticOnly: true)).rejection, isNull);
    });

    test('a short measure window is tooFewCycles', () {
      // 40 s of measuring at 6 bpm holds four ten second cycles.
      final short = blocksFor([6.0], measure: const Duration(seconds: 40))
          .single;
      final r = scoreOne(inputFor(short, amplitudeBpm: 5));
      expect(r.rejection, BlockRejection.tooFewCycles);
      expect(r.amplitudeBpm, isNull);
      expect(r.cycles, lessThan(kMinCycles));
    });

    test('rejections are checked in order: coverage, artifacts, movement, '
        'missed cues, cycles', () {
      final good = synthBeats(b6, amplitudeBpm: 5);
      final gap = good.where((b) => b.tMs < 60000 || b.tMs >= 90000).toList();
      final patched = withUnobserved(good, (i, _) => i % 15 == 0);
      final short =
          blocksFor([6.0], measure: const Duration(seconds: 40)).single;

      expect(
          scoreOne(inputFor(b6,
                  beats: gap, stillFraction: 0.1, missedCues: 2, hapticOnly: true))
              .rejection,
          BlockRejection.lowCoverage);
      expect(
          scoreOne(inputFor(b6,
                  beats: patched, stillFraction: 0.1, missedCues: 2, hapticOnly: true))
              .rejection,
          BlockRejection.artifacts);
      expect(
          scoreOne(inputFor(b6, stillFraction: 0.1, missedCues: 2, hapticOnly: true))
              .rejection,
          BlockRejection.movement);
      expect(
          scoreOne(inputFor(short, missedCues: 2, hapticOnly: true)).rejection,
          BlockRejection.missedCues);
    });
  });

  group('compareBlocks', () {
    void expectNoRate(SweepComparison c) {
      expect(c.rateBpm, isNull);
      expect(c.range, isNull);
    }

    test('scores every input, in input order', () {
      final c = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 4, 5.5: 6, 5.0: 4, 4.5: 3}),
        testedRates: kRatesAsc,
      );
      expect(c.blocks.map((r) => r.rateBpm), kPlanRates);
    });

    test('a clear interior winner is a tentative rate', () {
      final c = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 4, 5.5: 6, 5.0: 4, 4.5: 3}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.tentativeRate);
      expect(c.rateBpm, 5.5);
      expect(c.range, isNull);
    });

    test('the winner counts as interior by tested rates, not admitted ones',
        () {
      final c = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 3, 5.5: 6, 5.0: 3, 4.5: 3},
            reject: {6.5, 4.5}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.tentativeRate);
      expect(c.rateBpm, 5.5);
    });

    test('a rejected tested rate leaves an admitted-boundary winner inconclusive',
        () {
      final c = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 8, 5.5: 5, 5.0: 4, 4.5: 3},
            reject: {6.5}),
        testedRates: kRatesAsc,
      );
      // 6.0 is the fastest admitted rate, so nothing was measured above it.
      expect(c.outcome, ComparisonOutcome.inconclusiveBoundary);
      expectNoRate(c);
    });

    test('fewer than three admitted blocks is inconclusive', () {
      final c = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 4, 5.5: 8, 5.0: 4, 4.5: 3},
            reject: {6.5, 6.0, 4.5}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.inconclusiveTooFewBlocks);
      expectNoRate(c);
      expect(c.blocks.where((r) => r.admitted).length, 2);
    });

    test('too few blocks is decided before flat', () {
      final c = compareBlocks(
        sweepInputs({6.5: 4, 6.0: 4, 5.5: 4, 5.0: 4, 4.5: 4},
            reject: {6.5, 6.0, 5.5}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.inconclusiveTooFewBlocks);
    });

    test('a spread under 1 bpm is flat', () {
      final c = compareBlocks(
        sweepInputs({6.5: 4, 6.0: 4, 5.5: 4, 5.0: 4, 4.5: 4}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.inconclusiveFlat);
      expectNoRate(c);
    });

    test('a lone winner at the slowest tested rate is a boundary', () {
      final c = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 4, 5.5: 5, 5.0: 6, 4.5: 8}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.inconclusiveBoundary);
      expectNoRate(c);
    });

    test('a lone winner at the fastest tested rate is a boundary', () {
      final c = compareBlocks(
        sweepInputs({6.5: 8, 6.0: 6, 5.5: 5, 5.0: 4, 4.5: 3}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.inconclusiveBoundary);
      expectNoRate(c);
    });

    test('a contiguous tie of interior rates is a range', () {
      final c = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 5, 5.5: 5, 5.0: 3, 4.5: 3}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.tiedRange);
      expect(c.rateBpm, isNull);
      expect(c.range, isNotNull);
      expect(c.range!.lo, 5.5);
      expect(c.range!.hi, 6.0);
    });

    test('rejected blocks between tied rates do not break the run', () {
      final c = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 5, 5.5: 5, 5.0: 5, 4.5: 3}, reject: {5.5}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.tiedRange);
      expect(c.range!.lo, 5.0);
      expect(c.range!.hi, 6.0);
      expect(c.rateBpm, isNull);
    });

    test('a tie that touches a boundary is inconclusive, at either end', () {
      final top = compareBlocks(
        sweepInputs({6.5: 5, 6.0: 5, 5.5: 3, 5.0: 3, 4.5: 3}),
        testedRates: kRatesAsc,
      );
      expect(top.outcome, ComparisonOutcome.inconclusiveBoundary);
      expectNoRate(top);
      final bottom = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 3, 5.5: 3, 5.0: 5, 4.5: 5}),
        testedRates: kRatesAsc,
      );
      expect(bottom.outcome, ComparisonOutcome.inconclusiveBoundary);
      expectNoRate(bottom);
    });

    test('ties that are not contiguous are flat', () {
      final c = compareBlocks(
        sweepInputs({6.5: 3, 6.0: 5, 5.5: 3, 5.0: 5, 4.5: 3}),
        testedRates: kRatesAsc,
      );
      expect(c.outcome, ComparisonOutcome.inconclusiveFlat);
      expectNoRate(c);
    });

    test('stoppedEarly wins over a clear winner, but blocks are still scored',
        () {
      final inputs = sweepInputs(
        {6.5: 3, 6.0: 4, 5.5: 6, 5.0: 4, 4.5: 3},
        rates: [6.5, 6.0, 5.5],
      );
      final c = compareBlocks(inputs, testedRates: kRatesAsc, stoppedEarly: true);
      expect(c.outcome, ComparisonOutcome.stoppedEarly);
      expectNoRate(c);
      expect(c.blocks.length, 3);
      expect(c.blocks.every((r) => r.admitted && r.amplitudeBpm != null), isTrue);
    });
  });
}
