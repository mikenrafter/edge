// BedtimePlan: validation, the linear taper, the fixed pace, and the pattern it
// hands the phase engine. Bedtime breathing cues; evidence Tsai et al. 2015,
// doi:10.1111/psyp.12333. No HR-driven slowing: the pace is a function of
// elapsed time only.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_pacing_policy.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

const _min = Duration(minutes: 1);

void main() {
  group('defaults', () {
    test('a plan with no arguments is a fixed 6 bpm, 15 minute, no-stop plan', () {
      final p = BedtimePlan();
      expect(p.startBpm, 6.0);
      expect(p.endBpm, p.startBpm, reason: 'fixed: end == start');
      expect(p.duration, const Duration(minutes: 15));
      expect(p.stopOnSleep, isFalse, reason: 'the sleep stop is optional');
    });

    test('the cap constants say what the owner asked for', () {
      expect(kBedtimeDefaultDuration, const Duration(minutes: 15));
      expect(kBedtimeMaxDuration, const Duration(minutes: 20));
      expect(kBedtimeMinDuration, const Duration(minutes: 1));
      expect(kBedtimeMinBpm, 4.0);
      expect(kBedtimeMaxBpm, 7.0,
          reason: '8 bpm needs 32 band commands per 2 min; the budget is 30');
      expect(kBedtimeSustainedEpochs, 4);
      expect(kBedtimeFreshness, const Duration(seconds: 90));
      expect(kBedtimeMaxMissedCues, 3);
      expect(kBedtimeObserveInterval, const Duration(seconds: 30));
    });

    test('a default-constructed plan paces at 6 bpm for its whole length', () {
      final p = BedtimePlan();
      expect(p.rateAt(Duration.zero), closeTo(6.0, 1e-9));
      expect(p.rateAt(const Duration(minutes: 15)), closeTo(6.0, 1e-9));
    });
  });

  group('validation', () {
    test('rates outside 4..7 bpm are refused', () {
      expect(() => BedtimePlan(startBpm: 3.9), throwsArgumentError);
      expect(() => BedtimePlan(startBpm: 7.1), throwsArgumentError);
      expect(() => BedtimePlan(startBpm: 8), throwsArgumentError,
          reason: '8 bpm is 32 band commands per 2 min, over the budget of 30');
      expect(() => BedtimePlan(startBpm: 6, endBpm: 3.9), throwsArgumentError);
      expect(() => BedtimePlan(startBpm: 6, endBpm: 7.1), throwsArgumentError);
    });

    test('a taper may not speed up: endBpm above startBpm is refused', () {
      expect(() => BedtimePlan(startBpm: 5, endBpm: 6), throwsArgumentError);
      expect(() => BedtimePlan(startBpm: 4, endBpm: 4.01), throwsArgumentError);
    });

    test('NaN and infinite rates are refused', () {
      expect(() => BedtimePlan(startBpm: double.nan), throwsArgumentError);
      expect(() => BedtimePlan(startBpm: double.infinity), throwsArgumentError);
      expect(() => BedtimePlan(startBpm: 6, endBpm: double.nan),
          throwsArgumentError);
    });

    test('duration must be 1..20 minutes', () {
      expect(() => BedtimePlan(duration: Duration.zero), throwsArgumentError);
      expect(() => BedtimePlan(duration: const Duration(seconds: 59)),
          throwsArgumentError);
      expect(() => BedtimePlan(duration: const Duration(minutes: 21)),
          throwsArgumentError);
      expect(() => BedtimePlan(duration: const Duration(minutes: 20, seconds: 1)),
          throwsArgumentError);
      expect(() => BedtimePlan(duration: const Duration(minutes: -5)),
          throwsArgumentError);
    });

    test('the edges are allowed: 4 and 7 bpm, 1 and 20 minutes', () {
      final widest = BedtimePlan(
          startBpm: 7, endBpm: 4, duration: const Duration(minutes: 20));
      expect(widest.rateAt(const Duration(minutes: 10)), closeTo(5.5, 1e-9));
      final shortest = BedtimePlan(startBpm: 4, duration: _min);
      expect(shortest.rateAt(const Duration(seconds: 30)), closeTo(4.0, 1e-9));
    });
  });

  group('rateAt', () {
    test('fixed: the same rate at every elapsed time', () {
      final p = BedtimePlan(startBpm: 6.5);
      for (final m in [0, 1, 7, 14, 15, 40]) {
        expect(p.rateAt(Duration(minutes: m)), closeTo(6.5, 1e-9), reason: '$m');
      }
    });

    test('6 to 5 over 15 minutes is linear in time', () {
      final p = BedtimePlan(startBpm: 6, endBpm: 5);
      expect(p.rateAt(Duration.zero), closeTo(6.0, 1e-9));
      expect(p.rateAt(const Duration(minutes: 3)), closeTo(5.8, 1e-9));
      expect(p.rateAt(const Duration(seconds: 450)), closeTo(5.5, 1e-9));
      expect(p.rateAt(const Duration(minutes: 15)), closeTo(5.0, 1e-9));
    });

    test('the taper follows the plan duration, not a fixed 15 minutes', () {
      final p = BedtimePlan(
          startBpm: 7, endBpm: 5, duration: const Duration(minutes: 10));
      expect(p.rateAt(const Duration(minutes: 5)), closeTo(6.0, 1e-9));
      expect(p.rateAt(const Duration(minutes: 10)), closeTo(5.0, 1e-9));
    });

    test('clamped: before the start is startBpm, after the end is endBpm', () {
      final p = BedtimePlan(startBpm: 6, endBpm: 5);
      expect(p.rateAt(const Duration(seconds: -30)), closeTo(6.0, 1e-9));
      expect(p.rateAt(const Duration(minutes: 60)), closeTo(5.0, 1e-9));
    });

    test('never speeds up: the rate is non-increasing in elapsed time', () {
      final p = BedtimePlan(startBpm: 7, endBpm: 4);
      var prev = double.infinity;
      for (var s = 0; s <= 900; s += 15) {
        final r = p.rateAt(Duration(seconds: s));
        expect(r, lessThanOrEqualTo(prev));
        expect(r, inInclusiveRange(4.0, 7.0));
        prev = r;
      }
    });
  });

  group('patternAt', () {
    test('a fixed 6 bpm plan is a 10 s cycle: 5 s inhale, 5 s exhale, no holds', () {
      final pat = BedtimePlan(startBpm: 6).patternAt(Duration.zero);
      expect(pat.rate, closeTo(6.0, 1e-9));
      expect(pat.cycleSeconds, closeTo(10.0, 1e-9));
      expect(pat.phases.map((p) => p.kind),
          [BreathPhaseKind.inhale, BreathPhaseKind.exhale]);
      expect(pat.phases[0].seconds, closeTo(5.0, 1e-9));
      expect(pat.phases[1].seconds, closeTo(5.0, 1e-9));
    });

    test('a taper hands out a slower pattern later in the session', () {
      final p = BedtimePlan(startBpm: 6, endBpm: 5);
      final early = p.patternAt(Duration.zero);
      final late = p.patternAt(const Duration(minutes: 15));
      expect(early.rate, closeTo(6.0, 1e-9));
      expect(late.rate, closeTo(5.0, 1e-9));
      expect(late.cycleSeconds, greaterThan(early.cycleSeconds));
      expect(p.patternAt(const Duration(seconds: 450)).rate, closeTo(5.5, 1e-9));
    });

    test('the pattern is not coherence-rated and runs on the shared phase engine',
        () {
      final pat = BedtimePlan(startBpm: 6).patternAt(Duration.zero);
      expect(pat.coherenceRated, isFalse,
          reason: 'no resonance claim for a bedtime pace');
      final at = phaseAt(pat, const Duration(seconds: 6));
      expect(at, isNotNull);
      expect(at!.phase.kind, BreathPhaseKind.exhale);
    });
  });
}
