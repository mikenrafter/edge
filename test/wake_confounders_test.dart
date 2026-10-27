import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';
import 'package:openstrap_edge/data/journal_fields.dart';

WakeJournalDay day(
  Set<String> tags, {
  Map<String, JournalMetricValue> metrics = const {},
  DateTime? date,
}) => WakeJournalDay(date ?? DateTime(2026, 10, 25), tags, metrics);
void main() {
  final bed = DateTime(2026, 10, 25, 22);
  ConfounderProfile p(
    Set<String> tags, [
    Map<String, JournalMetricValue> metrics = const {},
  ]) => wakeConfounders([day(tags, metrics: metrics)], expectedBedtime: bed);
  test('all presets and exact dose/time boundaries', () {
    expect(p({}), const ConfounderProfile());
    expect(
      p({}, {
        'alcohol_units': const JournalMetricValue(1, atMinuteOfDay: 1200),
      }).hrArousalBpm,
      6,
    );
    expect(
      p({}, {
        'alcohol_units': const JournalMetricValue(1, atMinuteOfDay: 1199),
      }).hrArousalBpm,
      4,
    );
    expect(p({'alcohol'}).hrArousalBpm, 4);
    expect(
      p({}, {
        'alcohol_units': const JournalMetricValue(0, atMinuteOfDay: 1260),
      }).hrArousalBpm,
      4,
    );
    expect(
      p({}, {
        'caffeine_mg': const JournalMetricValue(200, atMinuteOfDay: 960),
      }).hrArousalBpm,
      6,
    );
    expect(
      p({}, {
        'caffeine_mg': const JournalMetricValue(199, atMinuteOfDay: 960),
      }).hrArousalBpm,
      4,
    );
    expect(
      p({}, {
        'caffeine_mg': const JournalMetricValue(200, atMinuteOfDay: 959),
      }).hrArousalBpm,
      4,
    );
    expect(p({'stress'}).motionCeilingG, .06);
    expect(
      p({}, {'stress': const JournalMetricValue(4)}).trendThresholdFactor,
      .5,
    );
    expect(p({'late meal'}).hrArousalBpm, 5);
    expect(p({'late meal'}).trendThresholdFactor, 1.5);
    expect(p({'sick'}).hrArousalBpm, 5);
    expect(p({'workout'}).protectionMinutes, 10);
    expect(p({'workout'}).trendWindowMinutes, 5);
    expect(p({'workout', 'rest day'}).protectionMinutes, 5);
    expect(p({'stress', 'sick', 'late meal'}).trendThresholdFactor, .75);
    expect(
      p(
        {'stress'},
        {'alcohol_units': const JournalMetricValue(1, atMinuteOfDay: 1260)},
      ).disableEarlyDelivery,
      isTrue,
    );
  });
  test(
    'explicit monoid identity associative and commutative for every triple',
    () {
      const xs = [
        ConfounderProfile(),
        ConfounderProfile(
          alcohol: true,
          hrArousalBpm: 6,
          trendWindowMinutes: 5,
        ),
        ConfounderProfile(stress: true, motionCeilingG: .06),
        ConfounderProfile(sick: true, hrArousalBpm: 5),
        ConfounderProfile(lateMeal: true, hrArousalBpm: 5),
        ConfounderProfile(protectionMinutes: 10, trendWindowMinutes: 5),
      ];
      for (final a in xs) {
        expect(a.combine(ConfounderProfile.identity), a);
        expect(ConfounderProfile.identity.combine(a), a);
        for (final b in xs) {
          expect(a.combine(b), b.combine(a));
          for (final c in xs) {
            expect(a.combine(b).combine(c), a.combine(b.combine(c)));
          }
        }
      }
    },
  );
  test('dated nocturnal and midnight timing, missing schedule fallback', () {
    final morning = DateTime(2026, 10, 26, 8);
    final d = day(
      {},
      date: DateTime(2026, 10, 26),
      metrics: {
        'alcohol_units': const JournalMetricValue(1, atMinuteOfDay: 360),
        'caffeine_mg': const JournalMetricValue(200, atMinuteOfDay: 120),
      },
    );
    expect(wakeConfounders([d], expectedBedtime: morning).hrArousalBpm, 6);
    final midnight = DateTime(2026, 10, 26, 1);
    expect(
      wakeConfounders([
        day(
          {},
          metrics: {
            'alcohol_units': const JournalMetricValue(
              1,
              atMinuteOfDay: 23 * 60,
            ),
          },
        ),
      ], expectedBedtime: midnight).hrArousalBpm,
      6,
    );
    expect(wakeConfounders([d], expectedBedtime: bed).hrArousalBpm, 4);
    expect(wakeConfounders([d]).hrArousalBpm, 4);
    expect(
      wakeConfounders([
        day(
          {},
          metrics: {
            'alcohol_units': const JournalMetricValue(
              1,
              atMinuteOfDay: 22 * 60,
            ),
          },
        ),
      ]).hrArousalBpm,
      6,
    );
  });
  test('missing time, invalid dose and events after bedtime are inactive', () {
    for (final value in [
      const JournalMetricValue(1),
      const JournalMetricValue(double.nan, atMinuteOfDay: 1260),
      const JournalMetricValue(1, atMinuteOfDay: 1440),
      const JournalMetricValue(1, atMinuteOfDay: 1321),
    ]) {
      expect(p({}, {'alcohol_units': value}), value.atMinuteOfDay == null
          ? const ConfounderProfile(learningAlcohol: true)
          : const ConfounderProfile());
    }
    expect(
      p({}, {'caffeine_mg': const JournalMetricValue(200)}),
      const ConfounderProfile(),
    );
    expect(
      p({}, {'stress': const JournalMetricValue(3)}).trendThresholdFactor,
      1,
    );
    expect(p({'stress', 'sick'}).trendThresholdFactor, .5);
    final morning = DateTime(2026, 10, 26, 8);
    for (final entry in [
      ('alcohol_units', 1.0, 360),
      ('caffeine_mg', 200.0, 120),
    ]) {
      for (final delta in [-1, 0]) {
        final d = day(
          {},
          date: DateTime(2026, 10, 26),
          metrics: {
            entry.$1: JournalMetricValue(
              entry.$2,
              atMinuteOfDay: entry.$3 + delta,
            ),
          },
        );
        expect(
          wakeConfounders([d], expectedBedtime: morning).hrArousalBpm,
          delta == 0 ? 6 : 4,
        );
      }
    }
  });
}
