import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_plan.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

Duration s(num sec) => Duration(microseconds: (sec * 1e6).round());

void main() {
  group('build: timing and order', () {
    test('defaults give five 2.5 minute blocks, back to back, in given order',
        () {
      final plan = ResonanceSweepPlan.build();
      expect(plan.blocks.map((b) => b.rateBpm), [6.5, 6.0, 5.5, 5.0, 4.5]);
      for (var i = 0; i < 5; i++) {
        final b = plan.blocks[i];
        expect(b.start, s(150.0 * i));
        expect(b.settleEnd, s(150.0 * i + 30));
        expect(b.end, s(150.0 * i + 150));
        if (i > 0) expect(b.start, plan.blocks[i - 1].end);
      }
      expect(plan.total, s(750));
    });

    test('custom settle and measure change every block', () {
      final plan = ResonanceSweepPlan.build(
        ratesBpm: [6, 5],
        settle: s(10),
        measure: s(60),
      );
      expect(plan.blocks[0].settleEnd, s(10));
      expect(plan.blocks[0].end, s(70));
      expect(plan.blocks[1].start, s(70));
      expect(plan.blocks[1].end, s(140));
      expect(plan.total, s(140));
    });

    test('rates keep the given order; testedRates is ascending', () {
      final plan = ResonanceSweepPlan.build(ratesBpm: [5.5, 6.5, 4.5, 5.0]);
      expect(plan.blocks.map((b) => b.rateBpm), [5.5, 6.5, 4.5, 5.0]);
      expect(plan.testedRates, [4.5, 5.0, 5.5, 6.5]);
    });

    test('the pattern is equal inhale and exhale with a 60/rate second cycle',
        () {
      final plan = ResonanceSweepPlan.build();
      for (final b in plan.blocks) {
        final p = b.pattern;
        expect(p.phases.map((x) => x.kind),
            [BreathPhaseKind.inhale, BreathPhaseKind.exhale]);
        expect(p.phases[0].seconds, closeTo(p.phases[1].seconds, 1e-9));
        expect(p.cycleSeconds, closeTo(60 / b.rateBpm, 1e-9));
        expect(p.rate, closeTo(b.rateBpm, 1e-9));
      }
    });

    test('the extreme legal rates 3 and 10 are accepted', () {
      final plan = ResonanceSweepPlan.build(ratesBpm: [3.0, 10.0]);
      expect(plan.testedRates, [3.0, 10.0]);
    });
  });

  group('blockAt', () {
    late ResonanceSweepPlan plan;
    setUp(() => plan = ResonanceSweepPlan.build());
    test('start is inclusive, end is exclusive', () {
      expect(plan.blockAt(Duration.zero)!.rateBpm, 6.5);
      expect(plan.blockAt(s(149.999))!.rateBpm, 6.5);
      expect(plan.blockAt(s(150))!.rateBpm, 6.0);
      expect(plan.blockAt(s(749.999))!.rateBpm, 4.5);
    });
    test('null before the start and at or after the total', () {
      expect(plan.blockAt(s(-1)), isNull);
      expect(plan.blockAt(s(750)), isNull);
      expect(plan.blockAt(s(900)), isNull);
    });
  });

  group('phaseAt', () {
    late ResonanceSweepPlan plan;
    setUp(() => plan = ResonanceSweepPlan.build());
    test('time zero is the first block, inhale, progress 0', () {
      final p = plan.phaseAt(Duration.zero)!;
      expect(p.block.rateBpm, 6.5);
      expect(p.phase.kind, BreathPhaseKind.inhale);
      expect(p.progress, closeTo(0, 1e-9));
      expect(p.cycle, 0);
    });

    test('each block restarts at inhale, cycle 0, at its own start', () {
      for (var i = 0; i < plan.blocks.length; i++) {
        final p = plan.phaseAt(plan.blocks[i].start)!;
        expect(p.block.rateBpm, plan.blocks[i].rateBpm);
        expect(p.phase.kind, BreathPhaseKind.inhale);
        expect(p.progress, closeTo(0, 1e-9));
        expect(p.cycle, 0);
      }
    });

    test('exhale begins half a cycle in; progress runs within the phase', () {
      // 6.5 bpm: cycle 60/6.5 s, so the exhale starts at 30/6.5 s.
      final half = 30 / 6.5;
      expect(plan.phaseAt(s(half - 0.01))!.phase.kind, BreathPhaseKind.inhale);
      expect(plan.phaseAt(s(half + 0.01))!.phase.kind, BreathPhaseKind.exhale);
      // 6.0 bpm block starts at 150 s; its phases are 5 s long.
      final q = plan.phaseAt(s(153))!;
      expect(q.block.rateBpm, 6.0);
      expect(q.phase.kind, BreathPhaseKind.inhale);
      expect(q.progress, closeTo(0.6, 1e-6));
      expect(plan.phaseAt(s(155))!.phase.kind, BreathPhaseKind.exhale);
      expect(plan.phaseAt(s(160.5))!.cycle, 1);
    });

    test('null outside the plan', () {
      expect(plan.phaseAt(s(-1)), isNull);
      expect(plan.phaseAt(s(750)), isNull);
    });
  });

  group('inMeasureWindow', () {
    late ResonanceSweepPlan plan;
    setUp(() => plan = ResonanceSweepPlan.build());
    test('false while settling, true inside, false at the next settle', () {
      expect(plan.inMeasureWindow(Duration.zero), isFalse);
      expect(plan.inMeasureWindow(s(29.999)), isFalse);
      expect(plan.inMeasureWindow(s(30)), isTrue);
      expect(plan.inMeasureWindow(s(100)), isTrue);
      expect(plan.inMeasureWindow(s(149.999)), isTrue);
      expect(plan.inMeasureWindow(s(150)), isFalse);
      expect(plan.inMeasureWindow(s(179.999)), isFalse);
      expect(plan.inMeasureWindow(s(180)), isTrue);
    });
    test('false outside the plan', () {
      expect(plan.inMeasureWindow(s(-5)), isFalse);
      expect(plan.inMeasureWindow(s(750)), isFalse);
      expect(plan.inMeasureWindow(s(1000)), isFalse);
    });
  });

  group('haptic budget', () {
    test('two cues per breath: ceil(rate * 4)', () {
      expect(ResonanceSweepPlan.cueCommandsPer2Min(6.5), 26);
      expect(ResonanceSweepPlan.cueCommandsPer2Min(6.0), 24);
      expect(ResonanceSweepPlan.cueCommandsPer2Min(5.5), 22);
      expect(ResonanceSweepPlan.cueCommandsPer2Min(5.0), 20);
      expect(ResonanceSweepPlan.cueCommandsPer2Min(4.5), 18);
      expect(ResonanceSweepPlan.cueCommandsPer2Min(6.3), 26); // 25.2 rounds up
      expect(ResonanceSweepPlan.cueCommandsPer2Min(4.1), 17); // 16.4 rounds up
    });

    test('6.5 bpm costs 26 of the 26 allowed at the defaults: eligible', () {
      final plan = ResonanceSweepPlan.build();
      for (final b in plan.blocks) {
        expect(plan.hapticEligible(b), isTrue, reason: '${b.rateBpm}');
      }
    });

    test('a faster block than the budget carries is ineligible', () {
      final plan = ResonanceSweepPlan.build(ratesBpm: [7.0, 6.0]);
      expect(plan.hapticEligible(plan.blocks[0]), isFalse); // 28 > 26
      expect(plan.hapticEligible(plan.blocks[1]), isTrue);
    });

    test('with a limit of 20 and reserve 4, 6.5 is ineligible', () {
      final plan = ResonanceSweepPlan.build(hapticLimitPer2Min: 20);
      expect(plan.hapticEligible(plan.blocks.first), isFalse);
      // 16 is the ceiling: even 4.5 bpm (18) is over it.
      expect(plan.blocks.any(plan.hapticEligible), isFalse);
    });

    test('the reserve is subtracted from the limit', () {
      final plan = ResonanceSweepPlan.build(
          ratesBpm: [5.0, 4.5], hapticLimitPer2Min: 22);
      expect(plan.hapticEligible(plan.blocks[0]), isFalse); // 20 > 18
      expect(plan.hapticEligible(plan.blocks[1]), isTrue); // 18 <= 18
      final loose = ResonanceSweepPlan.build(
          ratesBpm: [5.0], hapticLimitPer2Min: 22, hapticReserve: 2);
      expect(loose.hapticEligible(loose.blocks[0]), isTrue); // 20 <= 20
    });
  });

  group('invalid input throws ArgumentError', () {
    void bad(String why, ResonanceSweepPlan Function() make) =>
        test(why, () => expect(make, throwsArgumentError));

    bad('empty rates', () => ResonanceSweepPlan.build(ratesBpm: []));
    bad('a zero rate', () => ResonanceSweepPlan.build(ratesBpm: [6, 0]));
    bad('a negative rate', () => ResonanceSweepPlan.build(ratesBpm: [-5.5]));
    bad('a rate under 3', () => ResonanceSweepPlan.build(ratesBpm: [2.9]));
    bad('a rate over 10', () => ResonanceSweepPlan.build(ratesBpm: [10.1]));
    bad('a NaN rate',
        () => ResonanceSweepPlan.build(ratesBpm: [double.nan]));
    bad('an infinite rate',
        () => ResonanceSweepPlan.build(ratesBpm: [double.infinity]));
    bad('duplicate rates', () => ResonanceSweepPlan.build(ratesBpm: [6, 5, 6]));
    bad('a zero measure',
        () => ResonanceSweepPlan.build(measure: Duration.zero));
    bad('a negative measure',
        () => ResonanceSweepPlan.build(measure: const Duration(seconds: -1)));
  });
}
