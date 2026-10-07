import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome.dart';
import 'package:openstrap_edge/wake/outcomes/wake_preference_policy.dart';

import 'outcome_rig.dart';

int _n = 0;

/// [count] usable mornings run under a configured Natural window of [window]
/// minutes, each rated from [rates] (cycled); null in [rates] = unrated.
///
/// RED-EDIT (P2 firing-time buckets): this helper used to take the FIRING time
/// (minutes before T) and the policy grouped by it, which is the defect. The
/// group is now the CONFIGURED window recorded for the night
/// (`configuredWindowMinutes`). The mornings still fire at 2/3 of the window,
/// so the old firing-time grouping splits them exactly as before and these
/// tests fail on the key, not on the data.
List<WakeOutcome> mornings(
  int count,
  int window,
  List<int?> rates, {
  String? stage = 'rem',
}) =>
    [
      for (var i = 0; i < count; i++)
        outcome(
          kT + (_n++) * 86400,
          minutesBeforeT: window * 2 / 3,
          configuredWindowMinutes: window,
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
      ...mornings(10, 30, [4]),
      ...mornings(9, 60, [2]),
    ];
    final r19 = ev(nineteen);
    expect(r19.wouldChoose, isNull);
    expect(r19.reason, 'insufficient');
    final r20 = ev([...nineteen, ...mornings(1, 60, [2])]);
    expect(r20.wouldChoose, 'window:60');
    expect(r20.reason, 'lowerGrogginess');
  });

  test('20 mornings but only one key with 8 or more: insufficient', () {
    final r = ev([
      ...mornings(14, 30, [3]),
      ...mornings(6, 60, [1]),
    ]);
    expect(r.wouldChoose, isNull);
    expect(r.reason, 'insufficient');
    expect(r.usableByPolicy, {'window:30': 14, 'window:60': 6});
  });

  test('a key under the floor is not compared, even if it looks best', () {
    // 7 mornings at grogginess 1 must not win against two 8+ keys.
    final r = ev([
      ...mornings(8, 30, [4]),
      ...mornings(8, 60, [3]),
      ...mornings(7, 15, [1]),
    ]);
    expect(r.wouldChoose, 'window:60');
    expect(r.reason, 'lowerGrogginess');
  });

  test('chooses the key with the lower median grogginess', () {
    final r = ev([
      ...mornings(10, 30, [4]), // median 4
      ...mornings(10, 60, [2]), // median 2
    ]);
    expect(r.wouldChoose, 'window:60');
    expect(r.reason, 'lowerGrogginess');
    final back = ev([
      ...mornings(10, 30, [2]),
      ...mornings(10, 60, [4]),
    ]);
    expect(back.wouldChoose, 'window:30');
  });

  // RED-EDIT (P2 uncertainty gate): this test expected window:30 from a lower
  // median (1 vs 2) of a spread-out group (1,1,1,1,1,5,5,5) against a broad group centred on 2. That
  // is a definite choice made on overlapping distributions, which the gate must
  // now refuse. What survives is the rule it was written for: the MEAN (2.5 vs
  // 2.25) would pick window:60, and the policy must never choose by it.
  test('the mean never decides; a lower median on broad overlap abstains', () {
    final r = ev([
      ...mornings(8, 30, [1, 1, 1, 1, 1, 5, 5, 5]), // median 1, mean 2.5
      ...mornings(12, 60, [1, 1, 2, 2, 2, 2, 2, 2, 2, 3, 4, 5]), // 2, 2.25
    ]);
    expect(r.wouldChoose, isNot('window:60'));
    expect(r.wouldChoose, isNull);
    expect(r.reason, 'uncertain');
  });

  test('an even count averages the middle two', () {
    // A: 1,1,1,1,3,3,3,3 -> median 2. B: all 2 -> median 2. A tie.
    final r = ev([
      ...mornings(8, 30, [1, 1, 1, 1, 3, 3, 3, 3]),
      ...mornings(12, 60, [2]),
    ]);
    expect(r.reason, 'tie');
    expect(r.wouldChoose, 'window:60');
  });

  test('a tie keeps the current window', () {
    final r = ev([
      ...mornings(10, 30, [3]),
      ...mornings(10, 60, [3]),
    ], ceiling: 60);
    expect(r.wouldChoose, 'window:60');
    expect(r.reason, 'tie');
    final r30 = ev([
      ...mornings(10, 15, [3]),
      ...mornings(10, 30, [3]),
    ], ceiling: 30);
    expect(r30.wouldChoose, 'window:30');
    expect(r30.reason, 'tie');
  });

  test('never chooses a window larger than the ceiling', () {
    final data = [
      ...mornings(10, 60, [1]), // best, but above 30
      ...mornings(10, 30, [3]),
      ...mornings(10, 15, [4]),
    ];
    final r = ev(data, ceiling: 30);
    expect(r.wouldChoose, 'window:30');
    expect(r.reason, 'lowerGrogginess');
    final r15 = ev(data, ceiling: 15);
    expect(r15.wouldChoose, isNull, reason: 'one candidate key is not a comparison');
    expect(r15.reason, 'insufficient');
    // Counts still describe everything that happened.
    expect(r.usableByPolicy, {'window:60': 10, 'window:30': 10, 'window:15': 10});
  });

  test('every choice over many shapes stays within the ceiling', () {
    for (final ceiling in [15, 30, 45, 60, 90, 120]) {
      for (final best in [15, 30, 60, 120]) {
        final data = [
          for (final m in [15, 30, 60, 120])
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
      ...mornings(10, 30, [2]),
      ...mornings(10, 30, [null]),
      ...mornings(10, 60, [3]),
    ]);
    expect(r.wouldChoose, 'window:30');
    expect(r.reason, 'lowerGrogginess');
    expect(r.usableByPolicy, {'window:30': 20, 'window:60': 10},
        reason: 'counts include unrated usable mornings');
  });

  test('unrated mornings do not count toward the evidence floor', () {
    final r = ev([
      ...mornings(8, 30, [4]),
      ...mornings(30, 30, [null]),
      ...mornings(8, 60, [3]),
    ]);
    expect(r.wouldChoose, isNull, reason: 'only 16 rated mornings');
    expect(r.reason, 'insufficient');
  });

  test('unusable mornings are ignored entirely', () {
    final bad = [
      for (var i = 0; i < 30; i++)
        outcome(kT + (_n++) * 86400,
            minutesBeforeT: i.isEven ? 20 : 40,
            configuredWindowMinutes: 60,
            grogginess: 1,
            exclusions: [WakeExclusion.alreadyAwake]),
      for (var i = 0; i < 10; i++)
        outcome(kT + (_n++) * 86400,
            grogginess: 1, delivered: false, configuredWindowMinutes: 60),
    ];
    final r = ev(bad);
    expect(r.wouldChoose, isNull);
    expect(r.usableByPolicy, isEmpty);
  });

  // RED-EDIT (P2 firing-time buckets): the two tests that stood here pinned
  // the key as stage + a bucket of the FIRING time ('rem:30', 'awake:60', ...),
  // which is the defect. They are replaced by the tests below: the key is the
  // configured window only, so neither the firing time nor the stage splits or
  // pools a configuration differently.
  test('keys are the configured window; firing time and stage do not split it',
      () {
    final r = ev([
      for (var i = 0; i < 9; i++)
        outcome(kT + i * 86400,
            minutesBeforeT: [14.4, 29.6, 59.6, 100.0, 0.0, 20.0, 40.0, 5.0, 55.0][i],
            stageAtFire: i.isEven ? 'rem' : (i % 3 == 0 ? null : 'awake'),
            configuredWindowMinutes: 60,
            grogginess: 3),
    ]);
    expect(r.usableByPolicy, {'window:60': 9});
  });

  test('outcomes with no recorded configured window are not grouped by when '
      'they fired', () {
    // Stored before the window was recorded: the configuration is unknown, so
    // no firing-time stand-in may be made up.
    final r = ev([
      for (var i = 0; i < 10; i++)
        outcome(kT + (_n++) * 86400, minutesBeforeT: 20, grogginess: 4),
      for (var i = 0; i < 10; i++)
        outcome(kT + (_n++) * 86400, minutesBeforeT: 40, grogginess: 2),
    ]);
    expect(r.wouldChoose, isNull);
    expect(r.reason, 'insufficient');
    expect(r.usableByPolicy, isEmpty);
  });

  group('one configuration is not two policies (P2)', () {
    test('20 mornings under one 60-minute window fired early or late: no '
        'choice', () {
      // Ten fired 20 min early (better ratings), ten 40 min early. Same
      // configured window, so nothing was compared; "window:30" was never set.
      final r = ev([
        for (var i = 0; i < 10; i++)
          outcome(kT + (_n++) * 86400,
              minutesBeforeT: 20, configuredWindowMinutes: 60, grogginess: 2),
        for (var i = 0; i < 10; i++)
          outcome(kT + (_n++) * 86400,
              minutesBeforeT: 40, configuredWindowMinutes: 60, grogginess: 4),
      ]);
      expect(r.wouldChoose, isNull);
      expect(r.reason, 'insufficient');
      expect(r.usableByPolicy, {'window:60': 20});
    });

    test('wouldChoose never names a window not used on 8+ rated mornings', () {
      // Windows 30 and 45 were used; 60 is only the ceiling. A tie must not
      // answer "keep window:60".
      final tie = ev([
        ...mornings(10, 30, [3]),
        ...mornings(10, 45, [3]),
      ], ceiling: 60);
      expect(tie.wouldChoose, anyOf(isNull, 'window:30', 'window:45'));
      // A window used on fewer than 8 rated mornings is never named either.
      final few = ev([
        ...mornings(10, 30, [4]),
        ...mornings(10, 45, [2]),
        ...mornings(7, 15, [1]),
      ], ceiling: 60);
      expect(few.wouldChoose, anyOf(isNull, 'window:30', 'window:45'));
      expect(few.wouldChoose, 'window:45');
    });
  });

  group('counts do not replace the uncertainty gate (P2)', () {
    // Two ten-morning groups spanning ratings 1..5 whose medians differ by
    // half a point (2 vs 2.5): the reviewer's case.
    List<WakeOutcome> pair(List<int> a, List<int> b) => [
          for (final r in a)
            ...mornings(1, 30, [r]),
          for (final r in b)
            ...mornings(1, 60, [r]),
        ];

    test('medians 2 vs 2.5 over wide, overlapping ratings: uncertain', () {
      final r = ev(pair(
        [1, 1, 2, 2, 2, 2, 3, 4, 5, 5], // median 2
        [1, 2, 2, 2, 2, 3, 3, 4, 5, 5], // median 2.5
      ));
      expect(r.wouldChoose, isNull);
      expect(r.reason, 'uncertain');
    });

    test('a one-point median gap with broad overlap is still uncertain', () {
      final r = ev(pair(
        [1, 1, 1, 2, 2, 2, 3, 4, 5, 5], // median 2
        [1, 2, 2, 2, 3, 3, 3, 4, 5, 5], // median 3
      ));
      expect(r.wouldChoose, isNull);
      expect(r.reason, 'uncertain');
    });

    test('a clear separation still chooses, so the gate is not a blanket '
        'refusal', () {
      final r = ev(pair(
        [1, 2, 1, 2, 2, 1, 2, 1, 2, 2], // median 2, never above 2
        [4, 5, 4, 5, 4, 4, 5, 4, 5, 3], // median 4
      ));
      expect(r.wouldChoose, 'window:30');
      expect(r.reason, 'lowerGrogginess');
    });

    test('deterministic: same data, any order, same answer', () {
      final data = pair(
        [1, 1, 1, 2, 2, 2, 3, 4, 5, 5],
        [1, 2, 2, 2, 3, 3, 3, 4, 5, 5],
      );
      final first = ev(data);
      for (var i = 0; i < 5; i++) {
        final again = ev(i.isEven ? data.reversed.toList() : data);
        expect(again.wouldChoose, first.wouldChoose);
        expect(again.reason, first.reason);
      }
    });
  });
}
