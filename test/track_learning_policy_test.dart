import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/track_model.dart';
import 'package:openstrap_edge/tracks/learning.dart';

TrackDefinition definition({bool locked = false, double? halfLife = 24}) =>
    TrackDefinition(
      id: 'custom',
      name: 'Custom',
      icon: 'track',
      kind: 'consumed',
      kinetics: TrackKinetics({
        'half_life_hours': TrackKineticField(value: halfLife, locked: locked),
        'onset_hours': const TrackKineticField(value: 1),
        'tolerance_days': const TrackKineticField(value: 2),
        'withdrawal_days': const TrackKineticField(value: 60),
      }),
    );

void main() {
  const policy = TrackLearningPolicy();
  test('global learning minimum comes before every field-specific gate', () {
    final track = definition(halfLife: 1);
    for (final field in trackKineticKeys) {
      final result = policy.step(
        track: track,
        field: field,
        age: policy.globalMinimum - const Duration(microseconds: 1),
        target: 100,
        reason: 'Matched sleep observations',
      );
      expect(result.value, track.kinetics.fields[field]!.value);
      expect(result.changed, isFalse, reason: field);
      expect(result.reason, 'global_learning');
    }
  });

  test(
    'withdrawal and tolerance wait for washout even after global minimum',
    () {
      final track = definition();
      for (final field in ['tolerance_days', 'withdrawal_days']) {
        final minimum = policy.minimumFor(field, track.kinetics);
        // A 60-day withdrawal outlasts several 24-hour half-lives.
        expect(minimum, greaterThanOrEqualTo(const Duration(days: 60)));
        final result = policy.step(
          track: track,
          field: field,
          age: const Duration(days: 40),
          target: 100,
          reason: 'Matched sleep observations',
        );
        expect(result.changed, isFalse);
        expect(result.value, track.kinetics.fields[field]!.value);
        expect(result.reason, 'field_learning');
      }
      expect(
        policy.minimumFor('half_life_hours', track.kinetics),
        lessThan(policy.minimumFor('withdrawal_days', track.kinetics)),
      );
    },
  );

  test(
    'half-life gate grows with half-life rather than a fixed calendar period',
    () {
      expect(
        policy.minimumFor(
          'half_life_hours',
          definition(halfLife: 240).kinetics,
        ),
        greaterThan(
          policy.minimumFor(
            'half_life_hours',
            definition(halfLife: 1).kinetics,
          ),
        ),
      );
    },
  );

  test(
    'learned field periods stay within intrinsic and twice intrinsic bounds',
    () {
      final kinetics = definition().kinetics;
      final floor = policy.minimumFor('withdrawal_days', kinetics);
      final shorter = policy.minimumFor(
        'withdrawal_days',
        kinetics,
        learnedMinimum: Duration.zero,
      );
      final longer = policy.minimumFor(
        'withdrawal_days',
        kinetics,
        learnedMinimum: Duration(microseconds: floor.inMicroseconds * 100),
      );
      expect(shorter, floor);
      expect(longer, Duration(microseconds: floor.inMicroseconds * 2));
    },
  );

  test('global boundary permits a mature short-half-life field to change', () {
    final result = policy.step(
      track: definition(halfLife: 1),
      field: 'half_life_hours',
      age: policy.globalMinimum,
      target: 2,
      reason: 'Matched sleep observations',
    );
    expect(result.changed, isTrue);
    expect(result.value, inInclusiveRange(1.01, 1.03));
  });

  test('locks and unknown values survive mature learning unchanged', () {
    final locked = policy.step(
      track: definition(locked: true),
      field: 'half_life_hours',
      age: const Duration(days: 100),
      target: 100,
      reason: 'Matched sleep observations',
    );
    expect(locked.value, 24);
    expect(locked.changed, isFalse);
    expect(locked.reason, 'locked');
    final unknown = policy.step(
      track: definition(halfLife: null),
      field: 'half_life_hours',
      age: const Duration(days: 100),
      target: 100,
      reason: 'Matched sleep observations',
    );
    expect(unknown.value, isNull);
    expect(unknown.changed, isFalse);
    expect(unknown.reason, 'unknown_kinetics');
  });

  test(
    'mature changes are bounded in either direction and retain their reason',
    () {
      for (final field in trackKineticKeys) {
        final before = definition().kinetics.fields[field]!.value!;
        for (final target in [before * 10, before / 10]) {
          final result = policy.step(
            track: definition(),
            field: field,
            age: const Duration(days: 100),
            target: target,
            reason: 'Matched sleep observations',
          );
          expect(result.changed, isTrue);
          final fraction = (result.value! - before).abs() / before;
          expect(fraction, inInclusiveRange(.01 - 1e-12, .03 + 1e-12));
          expect((result.value! - before).sign, (target - before).sign);
          expect(result.reason, 'Matched sleep observations');
        }
      }
    },
  );

  test('empty explanations and nonfinite targets cannot change kinetics', () {
    for (final target in [double.nan, double.infinity, -1.0]) {
      final result = policy.step(
        track: definition(),
        field: 'half_life_hours',
        age: const Duration(days: 100),
        target: target,
        reason: 'Evidence',
      );
      expect(result.value, 24);
      expect(result.changed, isFalse);
    }
    expect(
      policy
          .step(
            track: definition(),
            field: 'half_life_hours',
            age: const Duration(days: 100),
            target: 25,
            reason: '',
          )
          .changed,
      isFalse,
    );
  });
}
