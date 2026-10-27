import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/tracks/learning.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';

void main() {
  test('moments have a hand-calculated count mean and M2', () {
    final values = [2.0, 4.0, 6.0];
    final result = values.fold(const TrackMoments(), (a, x) => a.add(x));
    expect(result.count, 3);
    expect(result.mean, 4);
    // Squared deviations: 4 + 0 + 4.
    expect(result.m2, 8);
  });

  test('every split merge equals one pass, including empty shards', () {
    final random = Random(417);
    for (var round = 0; round < 20; round++) {
      final values = List.generate(
        17 + round,
        (_) => random.nextDouble() * 100 - 50,
      );
      TrackMoments accumulate(Iterable<double> xs) =>
          xs.fold(const TrackMoments(), (a, x) => a.add(x));
      final one = accumulate(values);
      for (var split = 0; split <= values.length; split++) {
        final merged = accumulate(
          values.take(split),
        ).merge(accumulate(values.skip(split)));
        expect(merged.count, values.length);
        expect(merged.mean, closeTo(one.mean, 1e-10));
        expect(merged.m2, closeTo(one.m2, 1e-8));
      }
    }
  });

  test(
    'moments merge is associative and commutative without mutating shards',
    () {
      final a = const TrackMoments().add(1).add(3);
      final b = const TrackMoments().add(5);
      final c = const TrackMoments().add(7).add(9);
      final lhs = a.merge(b).merge(c);
      final rhs = c.merge(b.merge(a));
      expect(lhs.count, 5);
      expect(lhs.mean, 5);
      expect(lhs.m2, 40);
      expect(rhs.count, lhs.count);
      expect(rhs.mean, lhs.mean);
      expect(rhs.m2, lhs.m2);
      expect(a.count, 2);
      expect(a.mean, 2);
    },
  );

  test(
    'per-night confounder monoid has identity associativity and commutativity',
    () {
      final random = Random(191);
      ConfounderProfile draw() => ConfounderProfile(
        hrArousalBpm: 4 + random.nextDouble() * 4,
        motionCeilingG: random.nextDouble() * .08,
        protectionMinutes: 5 + random.nextInt(20),
        trendWindowMinutes: 3 + random.nextInt(10),
        stress: random.nextBool(),
        sick: random.nextBool(),
        lateMeal: random.nextBool(),
        workout: random.nextBool(),
      );
      for (var i = 0; i < 100; i++) {
        final a = draw(), b = draw(), c = draw();
        expect(a.combine(ConfounderProfile.identity), a);
        expect(ConfounderProfile.identity.combine(a), a);
        expect(a.combine(b), b.combine(a));
        expect(a.combine(b).combine(c), a.combine(b.combine(c)));
      }
      const stress = ConfounderProfile(stress: true);
      const sick = ConfounderProfile(sick: true);
      const meal = ConfounderProfile(lateMeal: true);
      // Stress and sickness belong to one multiplier class: .5 only once.
      expect(stress.combine(sick).combine(meal).trendThresholdFactor, .75);
    },
  );
}
