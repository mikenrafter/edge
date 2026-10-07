import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome.dart';
import 'package:openstrap_edge/wake/outcomes/wake_preference_policy.dart';

import 'outcome_rig.dart';

int _n = 0;

/// [count] usable mornings fired [minutes] before T, each rated from [rates]
/// (cycled); null in [rates] = unrated.
List<WakeOutcome> mornings(
  int count,
  double minutes,
  List<int?> rates, {
  String? stage = 'rem',
}) =>
    [
      for (var i = 0; i < count; i++)
        outcome(
          kT + (_n++) * 86400,
          minutesBeforeT: minutes,
          stageAtFire: stage,
          grogginess: rates[i % rates.length],
        ),
    ];

ShadowPolicyResult ev(List<WakeOutcome> o, {int ceiling = 60}) =>
    evaluate(o, currentWindowMinutes: ceiling);

void main() {
  setUp(() => _n = 0);

  test('no data: insufficient, null', () {
    final r = ev(const []);
    expect(r.wouldChoose, isNull);
    expect(r.reason, 'insufficient');
    expect(r.usableByPolicy, isEmpty);
  });

  test('19 usable rated mornings are not enough, 20 are', () {
    final nineteen = [
      ...mornings(10, 20, [4]), // bucket 15-30
      ...mornings(9, 40, [2]), // bucket 30-60
    ];
    final r19 = ev(nineteen);
    expect(r19.wouldChoose, isNull);
    expect(r19.reason, 'insufficient');
    final r20 = ev([...nineteen, ...mornings(1, 40, [2])]);
    expect(r20.wouldChoose, 'window:60');
    expect(r20.reason, 'lowerGrogginess');
  });

  test('20 mornings but only one key with 8 or more: insufficient', () {
    final r = ev([
      ...mornings(14, 20, [3]),
      ...mornings(6, 40, [1]),
    ]);
    expect(r.wouldChoose, isNull);
    expect(r.reason, 'insufficient');
    expect(r.usableByPolicy, {'rem:30': 14, 'rem:60': 6});
  });

  test('a key under the floor is not compared, even if it looks best', () {
    // 7 mornings at grogginess 1 must not win against two 8+ keys.
    final r = ev([
      ...mornings(8, 20, [4]),
      ...mornings(8, 40, [3]),
      ...mornings(7, 10, [1]),
    ]);
    expect(r.wouldChoose, 'window:60');
    expect(r.reason, 'lowerGrogginess');
  });

  test('chooses the key with the lower median grogginess', () {
    final r = ev([
      ...mornings(10, 20, [4]), // median 4
      ...mornings(10, 40, [2]), // median 2
    ]);
    expect(r.wouldChoose, 'window:60');
    expect(r.reason, 'lowerGrogginess');
    final back = ev([
      ...mornings(10, 20, [2]),
      ...mornings(10, 40, [4]),
    ]);
    expect(back.wouldChoose, 'window:30');
  });

  test('the median is used, not the mean', () {
    // A: 1,1,1,1,1,5,5,5 -> median 1, mean 2.5. B: 2 x 8 -> median 2.
    final r = ev([
      ...mornings(8, 20, [1, 1, 1, 1, 1, 5, 5, 5]),
      ...mornings(8, 40, [2]),
      ...mornings(4, 40, [2]),
    ]);
    expect(r.wouldChoose, 'window:30');
  });

  test('an even count averages the middle two', () {
    // A: 1,1,1,1,3,3,3,3 -> median 2. B: all 2 -> median 2. A tie.
    final r = ev([
      ...mornings(8, 20, [1, 1, 1, 1, 3, 3, 3, 3]),
      ...mornings(12, 40, [2]),
    ]);
    expect(r.reason, 'tie');
    expect(r.wouldChoose, 'window:60');
  });

  test('a tie keeps the current window', () {
    final r = ev([
      ...mornings(10, 20, [3]),
      ...mornings(10, 40, [3]),
    ], ceiling: 60);
    expect(r.wouldChoose, 'window:60');
    expect(r.reason, 'tie');
    final r30 = ev([
      ...mornings(10, 10, [3]),
      ...mornings(10, 20, [3]),
    ], ceiling: 30);
    expect(r30.wouldChoose, 'window:30');
    expect(r30.reason, 'tie');
  });

  test('never chooses a window larger than the ceiling', () {
    final data = [
      ...mornings(10, 50, [1]), // 30-60 bucket: best, but above 30
      ...mornings(10, 20, [3]), // 15-30
      ...mornings(10, 10, [4]), // 0-15
    ];
    final r = ev(data, ceiling: 30);
    expect(r.wouldChoose, 'window:30');
    expect(r.reason, 'lowerGrogginess');
    final r15 = ev(data, ceiling: 15);
    expect(r15.wouldChoose, isNull, reason: 'one candidate key is not a comparison');
    expect(r15.reason, 'insufficient');
    // Counts still describe everything that happened.
    expect(r.usableByPolicy, {'rem:60': 10, 'rem:30': 10, 'rem:15': 10});
  });

  test('every choice over many shapes stays within the ceiling', () {
    for (final ceiling in [15, 30, 45, 60, 90, 120]) {
      for (final best in [10.0, 20.0, 40.0, 90.0]) {
        final data = [
          for (final m in [10.0, 20.0, 40.0, 90.0])
            ...mornings(9, m, [m == best ? 1 : 4]),
        ];
        final w = ev(data, ceiling: ceiling).wouldChoose;
        if (w != null) {
          expect(int.parse(w.split(':').last), lessThanOrEqualTo(ceiling),
              reason: 'best=$best ceiling=$ceiling chose $w');
        }
      }
    }
  });

  test('unrated mornings are excluded from the comparison, not imputed', () {
    // A has 10 rated at 2 plus 10 unrated: imputing a high value for the
    // unrated ones would push A's median above B's 3.
    final r = ev([
      ...mornings(10, 20, [2]),
      ...mornings(10, 20, [null]),
      ...mornings(10, 40, [3]),
    ]);
    expect(r.wouldChoose, 'window:30');
    expect(r.reason, 'lowerGrogginess');
    expect(r.usableByPolicy, {'rem:30': 20, 'rem:60': 10},
        reason: 'counts include unrated usable mornings');
  });

  test('unrated mornings do not count toward the evidence floor', () {
    final r = ev([
      ...mornings(8, 20, [4]),
      ...mornings(30, 20, [null]),
      ...mornings(8, 40, [3]),
    ]);
    expect(r.wouldChoose, isNull, reason: 'only 16 rated mornings');
    expect(r.reason, 'insufficient');
  });

  test('unusable mornings are ignored entirely', () {
    final bad = [
      for (var i = 0; i < 30; i++)
        outcome(kT + (_n++) * 86400,
            minutesBeforeT: i.isEven ? 20 : 40,
            grogginess: 1,
            exclusions: [WakeExclusion.alreadyAwake]),
      for (var i = 0; i < 10; i++)
        outcome(kT + (_n++) * 86400, grogginess: 1, delivered: false),
    ];
    final r = ev(bad);
    expect(r.wouldChoose, isNull);
    expect(r.usableByPolicy, isEmpty);
  });

  test('keys are stage plus the rounded minutes bucket', () {
    final r = ev([
      outcome(kT, minutesBeforeT: 14.4, grogginess: 3), // rounds to 14: 0-15
      outcome(kT + 1, minutesBeforeT: 14.6, grogginess: 3), // 15: 15-30
      outcome(kT + 2, minutesBeforeT: 29.4, grogginess: 3), // 29: 15-30
      outcome(kT + 3, minutesBeforeT: 29.6, grogginess: 3), // 30: 30-60
      outcome(kT + 4, minutesBeforeT: 59.4, grogginess: 3), // 59: 30-60
      outcome(kT + 5, minutesBeforeT: 59.6, grogginess: 3), // 60: 60+
      outcome(kT + 6, minutesBeforeT: 100, grogginess: 3), // 60+
      outcome(kT + 7, minutesBeforeT: 0, grogginess: 3, stageAtFire: null),
      outcome(kT + 8, minutesBeforeT: 20, stageAtFire: 'awake'),
    ]);
    expect(r.usableByPolicy, {
      'rem:15': 1,
      'rem:30': 2,
      'rem:60': 2,
      'rem:120': 2,
      'none:15': 1,
      'awake:30': 1,
    });
  });

  test('stages are separate keys, so mixed stages are not pooled', () {
    final r = ev([
      ...mornings(8, 20, [3], stage: 'rem'),
      ...mornings(8, 20, [3], stage: 'awake'),
      ...mornings(4, 20, [3], stage: null),
    ]);
    expect(r.usableByPolicy, {'rem:30': 8, 'awake:30': 8, 'none:30': 4});
  });
}
