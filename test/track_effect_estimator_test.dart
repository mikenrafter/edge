import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/track_model.dart';
import 'package:openstrap_edge/tracks/learning.dart';

TrackDefinition track(String id, {List<String> systems = const ['sleep'],
    double? halfLife = 6}) => TrackDefinition(
  id: id, name: id, icon: 'track', kind: 'consumed', systems: systems,
  kinetics: TrackKinetics({'half_life_hours': TrackKineticField(value: halfLife)}));

// Alternating whole weeks gives exposed and confirmed-clean nights for each
// weekday. Sleep changes by exactly eight units, with all match covariates equal.
List<TrackNight> cohort({int count = 112, bool complete = true,
    double coverage = 1, List<String> coOccurring = const ['a'],
    String? mismatch, bool negativeControl = false, bool shuffled = false}) {
  final random = Random(197);
  final outcomes = List.generate(count, (i) => (i ~/ 7).isOdd ? 58.0 : 50.0);
  if (shuffled) outcomes.shuffle(random);
  return List.generate(count, (i) {
    final exposed = (i ~/ 7).isOdd;
    final at = DateTime.utc(2025, 1, 1, 22).add(Duration(days: i));
    return TrackNight(at: at,
      bedtimeMinute: mismatch == 'bedtime' && exposed ? 480 : 1320,
      sleepDebtHours: mismatch == 'debt' && exposed ? 8 : 0,
      load: mismatch == 'load' && exposed ? 100 : 0,
      baselines: {'sleep': mismatch == 'baseline' && exposed ? 80 : 50},
      outcomes: {'sleep': outcomes[i]},
      events: exposed ? [for (final id in coOccurring) TrackEvent(
        id: '$id-$i', trackId: id, date: '2025-01-01',
        amount: 100, atMs: at.subtract(const Duration(hours: 6)).millisecondsSinceEpoch)] : [],
      completeTrackIds: complete ? coOccurring.toSet() : {},
      coverage: coverage,
      negativeControls: negativeControl ? {'sleep': exposed ? 58 : 50} : {});
  });
}

void main() {
  const estimator = TrackEffectEstimator();
  final cutoff = DateTime.utc(2026);
  TrackEffectEstimate estimate(List<TrackNight> nights,
      {List<TrackDefinition>? tracks, Map<String, double> priors = const {}}) =>
    estimator.estimate(tracks: tracks ?? [track('a')], nights: nights,
      asOf: cutoff, priors: priors).first;

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

  test('unlogged absence is unknown rather than an invented clean comparison', () {
    final result = estimate(cohort(complete: false));
    expect(result.effect, isNull);
    expect(result.reason, 'logging_incomplete');
    // The otherwise-identical explicitly confirmed cohort is estimable.
    expect(estimate(cohort()).effect, greaterThan(0));
  });

  test('insufficient sensor coverage blocks a numerically strong association', () {
    final result = estimate(cohort(coverage: .2));
    expect(result.effect, isNull);
    expect(result.reason, 'coverage');
  });

  for (final covariate in ['bedtime', 'debt', 'load', 'baseline']) {
    test('unmatched $covariate cannot be attributed to the track', () {
      final result = estimate(cohort(mismatch: covariate));
      expect(result.effect, isNull);
      expect(result.reason, 'unmatched');
    });
  }

  test('weekday is a matching covariate', () {
    final nights = cohort().where((n) => n.events.isEmpty
      ? n.at.weekday == DateTime.monday : n.at.weekday == DateTime.friday).toList();
    final result = estimate(nights);
    expect(result.effect, isNull);
    expect(result.reason, anyOf('unmatched', 'insufficient_samples'));
  });

  test('perfect co-occurrence reports cannot separate yet for both tracks', () {
    final results = estimator.estimate(tracks: [track('a'), track('b')],
      nights: cohort(coOccurring: ['a', 'b']), asOf: cutoff);
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
      return TrackNight(at: at, bedtimeMinute: 1320, sleepDebtHours: 0,
        load: 0, baselines: const {'sleep': 50},
        outcomes: {'sleep': 50 + (a ? 8.0 : 0) + (b ? 4.0 : 0)},
        completeTrackIds: const {'a', 'b'}, events: [
          for (final id in [if (a) 'a', if (b) 'b']) TrackEvent(
            id: '$id-$i', trackId: id, date: '2025-01-01', amount: 100,
            atMs: at.subtract(const Duration(hours: 6)).millisecondsSinceEpoch),
        ]);
    });
    final results = estimator.estimate(tracks: [track('a'), track('b')],
      nights: nights, asOf: cutoff);
    final a = results.singleWhere((e) => e.trackId == 'a');
    final b = results.singleWhere((e) => e.trackId == 'b');
    expect(a.effect, allOf(greaterThan(0), lessThan(8)));
    expect(b.effect, allOf(greaterThan(0), lessThan(4)));
    expect(a.effect, greaterThan(b.effect!));
  });

  test('multiple selected systems increase the corrected evidence threshold', () {
    final nights = cohort().map((n) => TrackNight(at: n.at,
      bedtimeMinute: n.bedtimeMinute, sleepDebtHours: n.sleepDebtHours,
      load: n.load, events: n.events, completeTrackIds: n.completeTrackIds,
      baselines: const {'sleep': 50, 'hr': 50},
      outcomes: {...n.outcomes, 'hr': 50})).toList();
    final results = estimator.estimate(tracks: [track('a', systems: ['sleep', 'hr'])],
      nights: nights, asOf: cutoff);
    final sleep = results.singleWhere((e) => e.system == 'sleep');
    final hr = results.singleWhere((e) => e.system == 'hr');
    expect(sleep.effect, greaterThan(0));
    expect(sleep.adjustedP, greaterThan(sleep.shuffleP!));
    expect(hr.effect, isNull);
  });

  test('only selected systems are tested and missing outcomes stay absent', () {
    final results = estimator.estimate(tracks: [track('a', systems: ['hr'])],
      nights: cohort(), asOf: cutoff);
    expect(results.map((e) => e.system), ['hr']);
    expect(results.single.effect, isNull);
    expect(results.single.reason, 'missing_system_data');
  });

  test('future outcome nights cannot train an earlier estimate', () {
    final results = estimator.estimate(tracks: [track('a')], nights: cohort(),
      asOf: DateTime.utc(2024, 12, 31));
    expect(results.single.effect, isNull);
    expect(results.single.matchedPairs, 0);
  });

  test('negative-control association vetoes the apparent track effect', () {
    final result = estimate(cohort(negativeControl: true));
    expect(result.effect, isNull);
    expect(result.reason, 'negative_control');
  });

  test('date-shuffled outcomes fail the evidence check', () {
    final result = estimate(cohort(shuffled: true));
    expect(result.effect, isNull);
    expect(result.reason, anyOf('date_shuffle', 'multiple_comparisons', 'no_evidence'));
  });

  test('dose residual timing and next-night lag use event time in order', () {
    final bedtime = DateTime.utc(2025, 1, 2, 22);
    TrackEvent event(String id, double amount, int hoursBefore) => TrackEvent(
      id: id, trackId: 'a', date: '2025-01-02', amount: amount,
      atMs: bedtime.subtract(Duration(hours: hoursBefore)).millisecondsSinceEpoch);
    final f = estimator.features(track('a'), [event('current', 100, 6),
      event('prior', 80, 30), event('future', 900, -1)], bedtime);
    expect(f.dose, 100);
    // 100 at one half-life + 80 at five half-lives = 50 + 2.5 mg.
    expect(f.residualMg, closeTo(52.5, 1e-10));
    expect(f.timingHours, 6);
    expect(f.nextNightDose, 80);
  });

  test('unknown half-life leaves residual absent instead of guessing kinetics', () {
    final bedtime = DateTime.utc(2025, 1, 2, 22);
    final f = estimator.features(track('a', halfLife: null), [TrackEvent(
      id: 'a', trackId: 'a', date: '2025-01-02', amount: 100,
      atMs: bedtime.subtract(const Duration(hours: 6)).millisecondsSinceEpoch)], bedtime);
    expect(f.dose, 100);
    expect(f.residualMg, isNull);
  });
}
