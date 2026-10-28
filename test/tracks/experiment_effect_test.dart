import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/track_model.dart';
import 'package:openstrap_edge/tracks/experiment.dart';

// Reference values are independent of the code under test: the two-sided 95%
// Student-t quantiles are the published table values (qt(.975, df) in R), and
// the Welch df/standard error below are worked by hand in each test.
void main() {
  // why: review T4. The old two-term expansion gave 3.852 at df=2 (true 4.303)
  // and narrowed every small-sample interval. Integer df must be exact.
  // proves: CLAIM(t-quantile)
  test('t quantile matches published table values at integer df', () {
    const table = {
      1: 12.7062,
      2: 4.3027,
      3: 3.1824,
      4: 2.7764,
      5: 2.5706,
      10: 2.2281,
      14: 2.1448,
      26: 2.0555,
      30: 2.0423,
    };
    for (final e in table.entries) {
      expect(studentT975(e.key.toDouble()), closeTo(e.value, 1e-4), reason: 'df=${e.key}');
    }
  });

  test('t quantile is monotone, conservative between table rows, and tends to z', () {
    var previous = double.infinity;
    for (var df = 1.0; df <= 200; df += .25) {
      final t = studentT975(df);
      expect(t, lessThan(previous), reason: 'df=$df');
      expect(t, greaterThan(1.959964));
      previous = t;
    }
    // Independent numeric integration of the t density: df 2.5 -> 3.5747,
    // df 5.5 -> 2.5019, df 45 -> 2.0141, df 100 -> 1.9840. The interpolation
    // may be at most 2% wider, never narrower.
    final exact = {2.5: 3.5747, 5.5: 2.5019, 45.0: 2.0141, 100.0: 1.9840};
    for (final e in exact.entries) {
      final t = studentT975(e.key);
      expect(t, greaterThanOrEqualTo(e.value - 1e-3), reason: 'df=${e.key}');
      expect(t, lessThan(e.value * 1.02), reason: 'df=${e.key}');
    }
  });

  // Hand work: do [1,2,3], skip [11,12,13]: both variances 1, se^2 = 1/3+1/3,
  // se = .81650, Welch df = 4, t = 2.7764, half = 2.2670, effect -10.
  test('equal-variance n=3 arms give the df=4 interval', () {
    final e = experimentEffect([1, 2, 3], [11, 12, 13])!;
    expect(e['effect'], closeTo(-10, 1e-9));
    expect(e['lower'], closeTo(-10 - 2.2670, 2e-3));
    expect(e['upper'], closeTo(-10 + 2.2670, 2e-3));
  });

  // Hand work (R: t.test(c(1,2,4), c(5,9,20))): means 2.3333 / 11.3333, effect
  // -9, variances 2.3333 / 60.3333, se = 4.5705, Welch df = 2.1546, exact
  // t = 4.0199, half = 18.373. Interpolation may be up to 2% wider.
  test('unequal small arms give a wide Welch interval', () {
    final e = experimentEffect([1, 2, 4], [5, 9, 20])!;
    expect(e['effect'], closeTo(-9, 1e-9));
    final half = ((e['upper'] as double) - (e['lower'] as double)) / 2;
    expect(half, greaterThanOrEqualTo(18.373 - .01));
    expect(half, lessThan(18.373 * 1.02));
  });

  // Hand work: 14 per arm, noise [-1,0,1] cycle -> sum -1, sum sq 9, variance
  // (9-1/14)/13 = .68681 in both arms, se = .31324, df = 26, t = 2.0555,
  // half = .6439.
  test('n=14 arms use df=26', () {
    final noise = [for (var i = 0; i < 14; i++) (i % 3) - 1.0];
    final e = experimentEffect([for (final x in noise) x + 68], [for (final x in noise) x + 60])!;
    expect(e['effect'], closeTo(8, 1e-9));
    expect((e['upper'] as double) - (e['lower'] as double), closeTo(2 * .6439, 2e-3));
  });

  // why: review T5. Whole-bpm resting HR can make every night in an arm equal;
  // a zero-width interval would claim certainty from three nights.
  test('zero spread in both arms is not an estimate', () {
    expect(experimentEffect([68, 68, 68], [60, 60, 60]), isNull);
  });

  test('arms below the three-night floor are not an estimate', () {
    expect(experimentEffect([1, 2], [1, 2, 3]), isNull);
    expect(experimentEffect([1, 2, 3], [1, 2]), isNull);
    expect(experimentEffect([], []), isNull);
  });

  // why: review T6. Blocks are two adjacent days, so a "skip" day right after a
  // "do" day is only ~1 day clear. A track whose washout is longer than that
  // would leave every skip day exposed. Washout = max(5 half-lives,
  // withdrawal_days), the same "several half-lives" the learning policy uses
  // (learning.dart minimumFor: half_life_hours * 5).
  // proves: CLAIM(washout-vs-block)
  group('washout', () {
    TrackDefinition track({double? halfLifeHours, double? withdrawalDays, Map<String, Object?>? sub}) =>
        TrackDefinition.fromJson({
          'id': 't',
          'name': 'T',
          'icon': 'track',
          'kind': 'consumed',
          'kinetics': {
            'half_life_hours': {'value': halfLifeHours, 'locked': false},
            'withdrawal_days': {'value': withdrawalDays, 'locked': false},
          },
          'sub_activities': [
            if (sub != null) {'id': 's', 'name': 'S', 'kinetics': sub},
          ],
        });

    test('is the larger of five half-lives and the withdrawal period, in days', () {
      expect(experimentWashoutDays(track()), 0);
      expect(experimentWashoutDays(track(halfLifeHours: 4.8)), closeTo(1.0, 1e-12)); // 4.8*5/24
      expect(experimentWashoutDays(track(halfLifeHours: 5)), closeTo(25 / 24, 1e-12));
      expect(experimentWashoutDays(track(halfLifeHours: 5, withdrawalDays: 9)), 9);
      expect(experimentWashoutDays(track(halfLifeHours: 48, withdrawalDays: 1)), 10);
    });

    test('a sub-activity with a longer half-life counts', () {
      final t = track(
        halfLifeHours: 1,
        sub: {'half_life_hours': {'value': 24, 'locked': false}},
      );
      expect(experimentWashoutDays(t), 5);
    });

    test('one day exactly is allowed; anything longer is not', () {
      expect(ExperimentableTrack.from(track(halfLifeHours: 4.8)), isNotNull);
      expect(experimentWashoutExceedsBlock(track(halfLifeHours: 4.8)), isFalse);
      expect(experimentWashoutExceedsBlock(track(withdrawalDays: 1)), isFalse);
      expect(experimentWashoutExceedsBlock(track(halfLifeHours: 5)), isTrue);
      expect(experimentWashoutExceedsBlock(track(withdrawalDays: 28)), isTrue);
    });
  });
}
