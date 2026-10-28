import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/track_model.dart';
import 'package:openstrap_edge/tracks/learning.dart';

TrackDefinition track(
  String id, {
  List<String> systems = const ['sleep'],
  double? halfLife = 6,
}) => TrackDefinition(
  id: id,
  name: id,
  icon: 'track',
  kind: 'consumed',
  systems: systems,
  kinetics: TrackKinetics({
    'half_life_hours': TrackKineticField(value: halfLife),
    'onset_hours': TrackKineticField(value: 0),
  }),
);

// Alternating whole weeks gives exposed and confirmed-clean nights for each
// weekday. Sleep changes by exactly eight units, with all match covariates equal.
List<TrackNight> cohort({
  int count = 112,
  bool complete = true,
  double coverage = 1,
  List<String> coOccurring = const ['a'],
  String? mismatch,
  bool negativeControl = false,
  bool controlsComplete = true,
  bool shuffled = false,
}) {
  final random = Random(197);
  final outcomes = List.generate(count, (i) => (i ~/ 7).isOdd ? 58.0 : 50.0);
  if (shuffled) outcomes.shuffle(random);
  return List.generate(count, (i) {
    final exposed = (i ~/ 7).isOdd;
    final at = DateTime.utc(2025, 1, 1, 22).add(Duration(days: i));
    return TrackNight(
      at: at,
      bedtimeMinute: mismatch == 'bedtime' && exposed ? 480 : 1320,
      sleepDebtHours: mismatch == 'debt' && exposed ? 8 : 0,
      load: mismatch == 'load' && exposed ? 100 : 0,
      baselines: {'sleep': mismatch == 'baseline' && exposed ? 80 : 50},
      outcomes: {'sleep': outcomes[i]},
      events: exposed
          ? [
              for (final id in coOccurring)
                TrackEvent(
                  id: '$id-$i',
                  trackId: id,
                  date: '2025-01-01',
                  amount: 100,
                  atMs: at
                      .subtract(const Duration(hours: 6))
                      .millisecondsSinceEpoch,
                ),
            ]
          : [],
      completeTrackIds: complete ? coOccurring.toSet() : {},
      coverage: coverage,
      negativeControls: !controlsComplete
          ? {}
          : {'sleep': negativeControl && exposed ? 58 : 50},
    );
  });
}

// Synthetic ground truth for the documented engineering history model.
// The entered day scales mean90% approach to tolerance and90% loss during
// abstinence. Each fit starts from one deliberately wrong user-entered scale.
List<TrackNight> historyCohort({bool complete = true, bool varying = true}) {
  final events = <TrackEvent>[], nights = <TrackNight>[];
  var tolerance = 0.0;
  final segments = varying ? [1, 3, 7, 2, 2, 8, 5, 5] : [1, 1];
  final cycle = segments.reduce((a, b) => a + b);
  for (var i = 0; i < 560; i++) {
    var position = i % cycle, segment = 0;
    while (position >= segments[segment]) {
      position -= segments[segment++];
    }
    final exposed = segment.isEven;
    final at = DateTime.utc(2024, 1, 1, 22).add(Duration(days: i));
    final hours = [1, 4, 7][i % 3];
    if (exposed) {
      events.add(
        TrackEvent(
          id: 'history-$i',
          trackId: 'a',
          date: '2024-01-01',
          atMs: at.subtract(Duration(hours: hours)).millisecondsSinceEpoch,
          amount: 100,
        ),
      );
      tolerance = 1 - (1 - tolerance) * exp(-log(10) / 3);
    } else {
      tolerance *= exp(-log(10) / 6);
    }
    var residual = 0.0;
    for (final event in events) {
      final age =
          (at.millisecondsSinceEpoch - event.atMs!) /
          Duration.millisecondsPerHour;
      if (age >= 0 && age <= 48) residual += 100 * pow(.5, age / 6);
    }
    if (i < 180) continue;
    nights.add(
      TrackNight(
        at: at,
        bedtimeMinute: 1320,
        sleepDebtHours: 0,
        load: 0,
        outcomes: {
          'sleep':
              50 +
              residual * (1 - tolerance) * .2 +
              (exposed ? 0 : tolerance * 8),
        },
        baselines: const {'sleep': 50},
        completeTrackIds: const {'a'},
        negativeControls: const {'sleep': 50},
        completeHistoryTrackIds: complete ? const {'a'} : const {},
        events: [...events],
      ),
    );
  }
  return nights;
}

TrackDefinition historyTrack({
  double tolerance = 3,
  double withdrawal = 6,
  String? locked,
}) => TrackDefinition(
  id: 'a',
  name: 'A',
  icon: 'track',
  kind: 'consumed',
  systems: const ['sleep'],
  kinetics: TrackKinetics({
    'half_life_hours': const TrackKineticField(value: 6),
    'onset_hours': const TrackKineticField(value: 0),
    'tolerance_days': TrackKineticField(
      value: tolerance,
      locked: locked == 'tolerance_days',
    ),
    'withdrawal_days': TrackKineticField(
      value: withdrawal,
      locked: locked == 'withdrawal_days',
    ),
  }),
);

void main() {
  const estimator = TrackEffectEstimator();
  final cutoff = DateTime.utc(2026);
  TrackEffectEstimate estimate(
    List<TrackNight> nights, {
    List<TrackDefinition>? tracks,
    Map<String, double> priors = const {},
  }) => estimator
      .estimate(
        tracks: tracks ?? [track('a')],
        nights: nights,
        asOf: cutoff,
        priors: priors,
      )
      .first;

  test('supported effect is shrunk toward preset or zero custom prior', () {
    final custom = estimate(cohort());
    final preset = estimate(cohort(), priors: {'a:sleep': 2});
    expect(custom.effect, allOf(greaterThan(0), lessThan(8)));
    expect(preset.effect, allOf(greaterThan(custom.effect!), lessThan(8)));
    expect(custom.matchedPairs, greaterThanOrEqualTo(estimator.minimumPairs));
    expect(custom.shuffleP, inInclusiveRange(0, .05));
    expect(custom.adjustedP, greaterThanOrEqualTo(custom.shuffleP!));
  });

  test('empty and thin samples abstain rather than displaying the prior', () {
    expect(estimate([], priors: {'a:sleep': 2}).effect, isNull);
    final thin = estimate(cohort(count: 14), priors: {'a:sleep': 2});
    expect(thin.effect, isNull);
    expect(thin.reason, 'insufficient_samples');
  });

  test(
    'unlogged absence is unknown rather than an invented clean comparison',
    () {
      final result = estimate(cohort(complete: false));
      expect(result.effect, isNull);
      expect(result.reason, 'logging_incomplete');
      // The otherwise-identical explicitly confirmed cohort is estimable.
      expect(estimate(cohort()).effect, greaterThan(0));
    },
  );

  test(
    'insufficient sensor coverage blocks a numerically strong association',
    () {
      final result = estimate(cohort(coverage: .2));
      expect(result.effect, isNull);
      expect(result.reason, 'coverage');
    },
  );

  for (final covariate in ['bedtime', 'debt', 'load', 'baseline']) {
    test('unmatched $covariate cannot be attributed to the track', () {
      final result = estimate(cohort(mismatch: covariate));
      expect(result.effect, isNull);
      expect(result.reason, 'unmatched');
    });
  }

  test('weekday is a matching covariate', () {
    final nights = cohort()
        .where(
          (n) => n.events.isEmpty
              ? n.at.weekday == DateTime.monday
              : n.at.weekday == DateTime.friday,
        )
        .toList();
    final result = estimate(nights);
    expect(result.effect, isNull);
    expect(result.reason, anyOf('unmatched', 'insufficient_samples'));
  });

  test('perfect co-occurrence reports cannot separate yet for both tracks', () {
    final results = estimator.estimate(
      tracks: [track('a'), track('b')],
      nights: cohort(coOccurring: ['a', 'b']),
      asOf: cutoff,
    );
    expect(results.map((e) => e.trackId), unorderedEquals(['a', 'b']));
    for (final result in results) {
      expect(result.effect, isNull);
      expect(result.reason, 'cannot_separate');
    }
  });

  test('independent overlap permits separate estimates for both tracks', () {
    final nights = List.generate(224, (i) {
      final a = (i ~/ 7).isOdd, b = (i ~/ 14).isOdd;
      final at = DateTime.utc(2025, 1, 1, 22).add(Duration(days: i));
      return TrackNight(
        at: at,
        bedtimeMinute: 1320,
        sleepDebtHours: 0,
        load: 0,
        baselines: const {'sleep': 50},
        outcomes: {'sleep': 50 + (a ? 8.0 : 0) + (b ? 4.0 : 0)},
        completeTrackIds: const {'a', 'b'},
        negativeControls: const {'sleep': 50},
        events: [
          for (final id in [if (a) 'a', if (b) 'b'])
            TrackEvent(
              id: '$id-$i',
              trackId: id,
              date: '2025-01-01',
              amount: 100,
              atMs: at
                  .subtract(const Duration(hours: 6))
                  .millisecondsSinceEpoch,
            ),
        ],
      );
    });
    final results = estimator.estimate(
      tracks: [track('a'), track('b')],
      nights: nights,
      asOf: cutoff,
    );
    final a = results.singleWhere((e) => e.trackId == 'a');
    final b = results.singleWhere((e) => e.trackId == 'b');
    expect(a.effect, allOf(greaterThan(0), lessThan(8)));
    expect(b.effect, allOf(greaterThan(0), lessThan(4)));
    expect(a.effect, greaterThan(b.effect!));
  });

  test(
    'multiple selected systems increase the corrected evidence threshold',
    () {
      final nights = cohort()
          .map(
            (n) => TrackNight(
              at: n.at,
              bedtimeMinute: n.bedtimeMinute,
              sleepDebtHours: n.sleepDebtHours,
              load: n.load,
              events: n.events,
              completeTrackIds: n.completeTrackIds,
              baselines: const {'sleep': 50, 'hr': 50},
              negativeControls: const {'sleep': 50, 'hr': 50},
              outcomes: {...n.outcomes, 'hr': 50},
            ),
          )
          .toList();
      final results = estimator.estimate(
        tracks: [
          track('a', systems: ['sleep', 'hr']),
        ],
        nights: nights,
        asOf: cutoff,
      );
      final sleep = results.singleWhere((e) => e.system == 'sleep');
      final hr = results.singleWhere((e) => e.system == 'hr');
      expect(sleep.effect, greaterThan(0));
      expect(sleep.adjustedP, greaterThan(sleep.shuffleP!));
      expect(hr.effect, isNull);
    },
  );

  test('only selected systems are tested and missing outcomes stay absent', () {
    final results = estimator.estimate(
      tracks: [
        track('a', systems: ['hr']),
      ],
      nights: cohort(),
      asOf: cutoff,
    );
    expect(results.map((e) => e.system), ['hr']);
    expect(results.single.effect, isNull);
    expect(results.single.reason, 'missing_system_data');
  });

  test('future outcome nights cannot train an earlier estimate', () {
    final results = estimator.estimate(
      tracks: [track('a')],
      nights: cohort(),
      asOf: DateTime.utc(2024, 12, 31),
    );
    expect(results.single.effect, isNull);
    expect(results.single.matchedPairs, 0);
  });

  test('negative-control outcomes belong to the estimated track history', () {
    List<TrackNight> controlled(String id) => cohort(controlsComplete: false)
        .map(
          (n) => TrackNight(
            at: n.at,
            bedtimeMinute: n.bedtimeMinute,
            sleepDebtHours: n.sleepDebtHours,
            load: n.load,
            outcomes: n.outcomes,
            baselines: n.baselines,
            events: n.events,
            completeTrackIds: n.completeTrackIds,
            negativeControlsByTrack: {
              id: {'sleep': 50},
            },
          ),
        )
        .toList();
    expect(estimate(controlled('a')).effect, greaterThan(0));
    final wrongTrack = estimate(controlled('b'));
    expect(wrongTrack.effect, isNull);
    expect(wrongTrack.reason, 'negative_control_missing');
  });

  test('missing negative controls abstain instead of skipping the check', () {
    final result = estimate(cohort(controlsComplete: false));
    expect(result.effect, isNull);
    expect(result.reason, 'negative_control_missing');
    expect(estimate(cohort()).effect, greaterThan(0));
  });

  test('negative-control association vetoes the apparent track effect', () {
    final result = estimate(cohort(negativeControl: true));
    expect(result.effect, isNull);
    expect(result.reason, 'negative_control');
  });

  test('date-shuffled outcomes fail the evidence check', () {
    final result = estimate(cohort(shuffled: true));
    expect(result.effect, isNull);
    expect(
      result.reason,
      anyOf('date_shuffle', 'multiple_comparisons', 'no_evidence'),
    );
  });

  test('dose residual timing and next-night lag use event time in order', () {
    final bedtime = DateTime.utc(2025, 1, 2, 22);
    TrackEvent event(String id, double amount, int hoursBefore) => TrackEvent(
      id: id,
      trackId: 'a',
      date: '2025-01-02',
      amount: amount,
      atMs: bedtime
          .subtract(Duration(hours: hoursBefore))
          .millisecondsSinceEpoch,
    );
    final f = estimator.features(track('a'), [
      event('current', 100, 6),
      event('prior', 80, 30),
      event('future', 900, -1),
    ], bedtime);
    expect(f.dose, 100);
    // 100 at one half-life + 80 at five half-lives = 50 + 2.5 mg.
    expect(f.residualMg, closeTo(52.5, 1e-10));
    expect(f.timingHours, 6);
    expect(f.nextNightDose, 80);
  });

  test(
    'unknown half-life leaves residual absent instead of guessing kinetics',
    () {
      final bedtime = DateTime.utc(2025, 1, 2, 22);
      final f = estimator.features(track('a', halfLife: null), [
        TrackEvent(
          id: 'a',
          trackId: 'a',
          date: '2025-01-02',
          amount: 100,
          atMs: bedtime
              .subtract(const Duration(hours: 6))
              .millisecondsSinceEpoch,
        ),
      ], bedtime);
      expect(f.dose, 100);
      expect(f.residualMg, isNull);
    },
  );
  test('unset sub-activity kinetics inherit the track half-life', () {
    final bedtime = DateTime.utc(2025, 1, 2, 22);
    final definition = TrackDefinition.fromJson({
      ...track('a').toJson(),
      'sub_activities': [
        {'id': 'coffee', 'name': 'Coffee', 'kinetics': {}},
      ],
    });
    final result = estimator.features(definition, [
      TrackEvent(
        id: 'coffee-1',
        trackId: 'a',
        subActivityId: 'coffee',
        date: '2025-01-02',
        amount: 100,
        atMs: bedtime.subtract(const Duration(hours: 6)).millisecondsSinceEpoch,
      ),
    ], bedtime);
    // Inherited six-hour half-life leaves exactly half of the 100 mg dose.
    expect(result.residualMg, closeTo(50, 1e-10));
  });

  test('constant-dose constant-time association cannot identify kinetics', () {
    expect(estimate(cohort()).kineticTargets, isEmpty);
  });

  test('chronological held-out temporal evidence identifies half-life', () {
    final nights = List.generate(224, (i) {
      final exposed = (i ~/ 7).isOdd;
      final at = DateTime.utc(2025, 1, 1, 22).add(Duration(days: i));
      final dose = [80.0, 100.0, 140.0, 200.0][i % 4];
      final hours = [1, 3, 5, 8, 10][i % 5];
      // Ground truth has a three-hour half-life; preset starts at six.
      final residual = dose * pow(.5, hours / 3);
      return TrackNight(
        at: at,
        bedtimeMinute: 1320,
        sleepDebtHours: 0,
        load: 0,
        baselines: const {'sleep': 50},
        outcomes: {'sleep': 50 + (exposed ? residual * .1 : 0)},
        completeTrackIds: const {'a'},
        negativeControls: const {'sleep': 50},
        events: [
          if (exposed)
            TrackEvent(
              id: 'a-$i',
              trackId: 'a',
              date: '2025-01-01',
              amount: dose,
              atMs: at.subtract(Duration(hours: hours)).millisecondsSinceEpoch,
            ),
        ],
      );
    });
    final result = estimate(nights);
    expect(result.effect, greaterThan(0));
    expect(result.kineticTargets['half_life_hours'], 3);
    expect(result.kineticTargets.containsKey('tolerance_days'), isFalse);
    expect(result.kineticTargets.containsKey('withdrawal_days'), isFalse);
  });

  test(
    'old untimed logs block slow history but preserve known acute exposure',
    () {
      final at = DateTime.utc(2025, 4, 1, 22);
      final events = [
        const TrackEvent(
          id: 'old',
          trackId: 'a',
          date: '2025-03-01',
          amount: 100,
        ),
        TrackEvent(
          id: 'current',
          trackId: 'a',
          date: '2025-04-01',
          amount: 100,
          atMs: at.subtract(const Duration(hours: 6)).millisecondsSinceEpoch,
        ),
      ];
      final f = estimator.features(
        historyTrack(),
        events,
        at,
        historyComplete: true,
      );
      expect(f.dose, 100);
      expect(f.residualMg, closeTo(50, 1e-10));
      expect(f.effectiveResidual, isNull);
      expect(f.withdrawalPressure, isNull);
    },
  );

  test('fixed frequency and abstinence cannot identify slow kinetics', () {
    final result = estimator
        .estimate(
          tracks: [historyTrack(tolerance: 6, withdrawal: 12)],
          nights: historyCohort(varying: false),
          asOf: DateTime.utc(2026),
        )
        .single;
    expect(result.effect, isNotNull);
    expect(result.kineticTargets.containsKey('tolerance_days'), isFalse);
    expect(result.kineticTargets.containsKey('withdrawal_days'), isFalse);
  });

  for (final field in ['tolerance_days', 'withdrawal_days']) {
    test('identified $field history proposes the held-out ground truth', () {
      final definition = historyTrack(
        tolerance: field == 'tolerance_days' ? 6 : 3,
        withdrawal: field == 'withdrawal_days' ? 12 : 6,
      );
      final result = estimator
          .estimate(
            tracks: [definition],
            nights: historyCohort(),
            asOf: DateTime.utc(2026),
          )
          .single;
      expect(result.effect, isNotNull);
      expect(result.kineticTargets[field], field == 'tolerance_days' ? 3 : 6);
    });

    test('$field never fits locked or incompletely logged history', () {
      final locked = historyTrack(tolerance: 6, withdrawal: 12, locked: field);
      final incomplete = estimator
          .estimate(
            tracks: [historyTrack(tolerance: 6, withdrawal: 12)],
            nights: historyCohort(complete: false),
            asOf: DateTime.utc(2026),
          )
          .single;
      final fixed = estimator
          .estimate(
            tracks: [locked],
            nights: historyCohort(),
            asOf: DateTime.utc(2026),
          )
          .single;
      expect(incomplete.kineticTargets.containsKey(field), isFalse);
      expect(fixed.kineticTargets.containsKey(field), isFalse);
    });
  }

  test(
    'strong effects remain estimable for a larger selected-system family',
    () {
      final systems = List.generate(20, (i) => 'system_$i');
      final nights = cohort()
          .map(
            (n) => TrackNight(
              at: n.at,
              bedtimeMinute: n.bedtimeMinute,
              sleepDebtHours: n.sleepDebtHours,
              load: n.load,
              events: n.events,
              completeTrackIds: n.completeTrackIds,
              baselines: {for (final system in systems) system: 50},
              negativeControls: {for (final system in systems) system: 50},
              outcomes: {
                for (final system in systems) system: n.outcomes['sleep']!,
              },
            ),
          )
          .toList();
      final estimates = estimator.estimate(
        tracks: [track('a', systems: systems)],
        nights: nights,
        asOf: cutoff,
      );
      expect(estimates, hasLength(20));
      for (final estimate in estimates) {
        expect(estimate.effect, allOf(greaterThan(0), lessThan(8)));
        expect(estimate.adjustedP, lessThanOrEqualTo(.05));
      }
    },
  );

  test(
    'a large selected-system family vetoes individually significant effects',
    () {
      final systems = List.generate(20, (i) => 'system_$i');
      var clean = 0, exposed = 0;
      // Swap 21 outcomes in each 56-night group. The remaining mean contrast
      // is two units: detectable alone, too weak for twenty simultaneous tests.
      final weak = cohort()
          .map(
            (n) => TrackNight(
              at: n.at,
              bedtimeMinute: n.bedtimeMinute,
              sleepDebtHours: n.sleepDebtHours,
              load: n.load,
              events: n.events,
              completeTrackIds: n.completeTrackIds,
              baselines: n.baselines,
              negativeControls: n.negativeControls,
              outcomes: {
                'sleep': n.events.isEmpty
                    ? (clean++ < 21 ? 58 : 50)
                    : (exposed++ < 21 ? 50 : 58),
              },
            ),
          )
          .toList();
      expect(estimate(weak).effect, greaterThan(0));
      final nights = weak
          .map(
            (n) => TrackNight(
              at: n.at,
              bedtimeMinute: n.bedtimeMinute,
              sleepDebtHours: n.sleepDebtHours,
              load: n.load,
              events: n.events,
              completeTrackIds: n.completeTrackIds,
              baselines: {for (final system in systems) system: 50},
              negativeControls: {for (final system in systems) system: 50},
              outcomes: {
                for (final system in systems) system: n.outcomes['sleep']!,
              },
            ),
          )
          .toList();
      final results = estimator.estimate(
        tracks: [track('a', systems: systems)],
        nights: nights,
        asOf: cutoff,
      );
      expect(results, hasLength(20));
      for (final result in results) {
        expect(result.effect, isNull);
        expect(result.reason, 'multiple_comparisons');
        expect(result.shuffleP, lessThan(.05));
        expect(result.adjustedP, greaterThan(.05));
      }
    },
  );

  // WHY S3: after caffeine changed from mg to cups, 100 historical mg and 2 new
  // cups were summed into one dose scale (dose 102). proves: CLAIM(unit-abstain)
  test('amounts in another unit than the track abstain instead of summing', () {
    final bedtime = DateTime.utc(2025, 1, 2, 22);
    TrackEvent event(String id, double amount, String? unit, int hoursBefore) =>
        TrackEvent(
          id: id,
          trackId: 'a',
          date: '2025-01-02',
          amount: amount,
          unit: unit,
          atMs: bedtime
              .subtract(Duration(hours: hoursBefore))
              .millisecondsSinceEpoch,
        );
    final cups = TrackDefinition(
      id: 'a',
      name: 'a',
      icon: 'track',
      kind: 'consumed',
      unit: 'cups',
      kinetics: const TrackKinetics({
        'half_life_hours': TrackKineticField(value: 6),
      }),
    );
    final mixed = estimator.features(cups, [
      event('old', 100, 'mg', 8),
      event('new', 2, 'cups', 2),
    ], bedtime);
    expect(mixed.dose, isNull);
    expect(mixed.residualMg, isNull);
    // Positive control: same-unit (and unstated-unit) amounts still add.
    final same = estimator.features(cups, [
      event('a1', 1, 'cups', 8),
      event('a2', 2, null, 2),
    ], bedtime);
    expect(same.dose, 3);
    // The slow-history window applies the same rule to a 10-day-old mg dose.
    final slowTrack = TrackDefinition(
      id: 'a',
      name: 'a',
      icon: 'track',
      kind: 'consumed',
      unit: 'cups',
      kinetics: const TrackKinetics({
        'half_life_hours': TrackKineticField(value: 6),
        'onset_hours': TrackKineticField(value: 0),
        'tolerance_days': TrackKineticField(value: 1),
        'withdrawal_days': TrackKineticField(value: 1),
      }),
    );
    final slowSame = estimator.features(slowTrack, [
      event('old', 1, 'cups', 24 * 5),
      event('new', 2, 'cups', 2),
    ], bedtime, historyComplete: true);
    expect(slowSame.effectiveResidual, isNotNull, reason: 'positive control');
    final slow = estimator.features(slowTrack, [
      event('old', 100, 'mg', 24 * 5),
      event('new', 2, 'cups', 2),
    ], bedtime, historyComplete: true);
    expect(slow.effectiveResidual, isNull);
  });

  // WHY S4: with "this track is my baseline" the reference was the minimum
  // observed dose, so 14 late abstinence nights replaced the habitual 100 mg
  // reference and the 150-vs-100 contrast was no longer estimated.
  // proves: CLAIM(baseline-reference)
  test('baseline reference stays habitual after later abstinence nights', () {
    TrackEvent dose(TrackNight n, double amount) => TrackEvent(
      id: 'd-${n.at.millisecondsSinceEpoch}',
      trackId: 'a',
      date: '2025-01-01',
      amount: amount,
      atMs: n.at.subtract(const Duration(hours: 6)).millisecondsSinceEpoch,
    );
    TrackNight withEvents(TrackNight n, double amount) => TrackNight(
      at: n.at,
      bedtimeMinute: n.bedtimeMinute,
      sleepDebtHours: n.sleepDebtHours,
      load: n.load,
      outcomes: n.outcomes,
      baselines: n.baselines,
      negativeControls: n.negativeControls,
      completeTrackIds: {'a'},
      events: [dose(n, amount)],
    );
    // Habitual 100 mg weeks vs 150 mg weeks differ by exactly 8 sleep units.
    final base = cohort();
    final nights = [
      for (final n in base) withEvents(n, n.events.isEmpty ? 100 : 150),
    ];
    final tail = [
      for (var i = 0; i < 14; i++)
        withEvents(
          TrackNight(
            at: base.last.at.add(Duration(days: i + 1)),
            bedtimeMinute: 1320,
            sleepDebtHours: 0,
            load: 0,
            outcomes: const {'sleep': 50},
            baselines: const {'sleep': 50},
            negativeControls: const {'sleep': 50},
          ),
          0,
        ),
    ];
    final tracked = TrackDefinition(
      id: 'a',
      name: 'a',
      icon: 'track',
      kind: 'consumed',
      systems: const ['sleep'],
      noUnadjustedData: true,
      kinetics: const TrackKinetics({
        'half_life_hours': TrackKineticField(value: 6),
      }),
    );
    final result = estimate([...nights, ...tail], tracks: [tracked]);
    expect(result.reason, 'estimated');
    // 56 pairs, contrast 8, shrinkage 56 / (56 + 8) = .875 -> 7.
    expect(result.effect, closeTo(7, 1e-6));
    // Deviation below the reference: habitual 100 mg weeks (earliest, so the
    // reference) against 50 mg weeks that sleep 8 units better -> -8 per
    // +50 mg, shrunk to -7. The sign shows the higher dose is the exposed side.
    final below = estimate(
      [for (final n in base) withEvents(n, n.events.isEmpty ? 100 : 50)],
      tracks: [tracked],
    );
    expect(below.reason, 'estimated');
    expect(below.effect, closeTo(-7, 1e-6));
  });

  // WHY S5: the default caffeine preset has onset null; it was read as 0 h, so a
  // numeric residual was reported with no kinetics behind it.
  // proves: CLAIM(onset-unknown)
  test('unknown onset leaves residual absent while dose stays known', () {
    final bedtime = DateTime.utc(2025, 1, 2, 22);
    final events = [
      TrackEvent(
        id: 'a',
        trackId: 'a',
        date: '2025-01-02',
        amount: 100,
        atMs: bedtime
            .subtract(const Duration(hours: 6))
            .millisecondsSinceEpoch,
      ),
    ];
    TrackDefinition withOnset(double? onset) => TrackDefinition(
      id: 'a',
      name: 'a',
      icon: 'track',
      kind: 'consumed',
      kinetics: TrackKinetics({
        'half_life_hours': const TrackKineticField(value: 6),
        'onset_hours': TrackKineticField(value: onset),
      }),
    );
    final unknown = estimator.features(withOnset(null), events, bedtime);
    expect(unknown.dose, 100);
    expect(unknown.residualMg, isNull);
    // Positive control: a known 1 h onset keeps 100 * 0.5^(6/6) = 50.
    expect(
      estimator.features(withOnset(1), events, bedtime).residualMg,
      closeTo(50, 1e-10),
    );
  });

  // WHY S6: a dose 72 h before bed with a 100 h half-life (61% left) fell past
  // the fixed 48 h cutoff and reported residual 0.
  // proves: CLAIM(residual-window)
  test('long half-life residual outlives 48 h or abstains without history', () {
    final bedtime = DateTime.utc(2025, 1, 5, 22);
    final events = [
      TrackEvent(
        id: 'old',
        trackId: 'a',
        date: '2025-01-02',
        amount: 100,
        atMs: bedtime
            .subtract(const Duration(hours: 72))
            .millisecondsSinceEpoch,
      ),
    ];
    final longLived = track('a', halfLife: 100);
    // 100 * 0.5^(72/100) = 60.7 mg (hand: 2^-0.72 = 0.6071).
    expect(
      estimator
          .features(longLived, events, bedtime, historyComplete: true)
          .residualMg,
      closeTo(60.71, 0.01),
    );
    expect(estimator.features(longLived, events, bedtime).residualMg, isNull);
    // Positive control: a short half-life needs no history and still drops it.
    expect(estimator.features(track('a'), events, bedtime).residualMg, 0);
  });

  // WHY S11: a sub-activity half-life override (every dose here uses it) hid the
  // parent's fit and was never itself learned. proves: CLAIM(sub-override-scale)
  test('sub-activity overrides scale with the parent and enter the fit', () {
    TrackKinetics kinetics(double hl, {bool locked = false}) => TrackKinetics({
      'half_life_hours': TrackKineticField(value: hl, locked: locked),
    });
    final subs = [
      TrackSubActivity(id: 'free', name: 'free', kinetics: kinetics(8)),
      TrackSubActivity(
        id: 'pinned',
        name: 'pinned',
        kinetics: kinetics(8, locked: true),
      ),
      const TrackSubActivity(id: 'inherits', name: 'inherits'),
    ];
    final scaled = scaleSubActivityKinetics(subs, 'half_life_hours', .5);
    expect(scaled[0].kinetics.fields['half_life_hours']!.value, 4);
    expect(scaled[1].kinetics.fields['half_life_hours']!.value, 8);
    expect(scaled[2].kinetics.fields.containsKey('half_life_hours'), isFalse);

    // Ground truth: every dose has a 3 h half-life, set by the only
    // sub-activity's override. The user entered override 6 h under parent 6 h.
    // Scaling both by .5 reaches the truth (override 3, parent 3). Before the
    // fix candidates changed the unused parent only, so the loss stayed flat.
    final nights = List.generate(224, (i) {
      final exposed = (i ~/ 7).isOdd;
      final at = DateTime.utc(2025, 1, 1, 22).add(Duration(days: i));
      final dose = [80.0, 100.0, 140.0, 200.0][i % 4];
      final hours = [1, 3, 5, 8, 10][i % 5];
      return TrackNight(
        at: at,
        bedtimeMinute: 1320,
        sleepDebtHours: 0,
        load: 0,
        baselines: const {'sleep': 50},
        outcomes: {'sleep': 50 + (exposed ? dose * pow(.5, hours / 3) * .1 : 0)},
        completeTrackIds: const {'a'},
        negativeControls: const {'sleep': 50},
        events: [
          if (exposed)
            TrackEvent(
              id: 'a-$i',
              trackId: 'a',
              date: '2025-01-01',
              amount: dose,
              subActivityId: 'only',
              atMs: at.subtract(Duration(hours: hours)).millisecondsSinceEpoch,
            ),
        ],
      );
    });
    final overridden = TrackDefinition(
      id: 'a',
      name: 'a',
      icon: 'track',
      kind: 'consumed',
      systems: const ['sleep'],
      kinetics: const TrackKinetics({
        'half_life_hours': TrackKineticField(value: 6),
        'onset_hours': TrackKineticField(value: 0),
      }),
      subActivities: [
        TrackSubActivity(
          id: 'only',
          name: 'only',
          kinetics: const TrackKinetics({
            'half_life_hours': TrackKineticField(value: 6),
          }),
        ),
      ],
    );
    final result = estimate(nights, tracks: [overridden]);
    expect(result.reason, 'estimated');
    expect(result.kineticTargets['half_life_hours'], 3);
  });
}
