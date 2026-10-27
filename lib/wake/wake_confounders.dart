// Owns the journal-to-detector policy. No delivery or mutable state.
import 'dart:math' as math;
import '../data/journal_fields.dart';
import '../util/heavy.dart';

class WakeJournalDay {
  final DateTime date;
  final Set<String> tags;
  final Map<String, JournalMetricValue> metrics;
  const WakeJournalDay(this.date, this.tags, this.metrics);
}

@SendableShape(
  'Immutable scalar fields and string sets; sendable_wakeProfileHeavy_test',
)
class ConfounderProfile {
  final double hrArousalBpm, motionCeilingG;
  final int protectionMinutes, trendWindowMinutes;
  final bool learningAlcohol,
      alcohol,
      caffeine,
      stress,
      sick,
      lateMeal,
      workout;
  final Set<String> userTrackIds, adjustedFor;
  const ConfounderProfile({
    this.userTrackIds = const {},
    this.adjustedFor = const {},
    this.hrArousalBpm = 4,
    this.motionCeilingG = .08,
    this.protectionMinutes = 5,
    this.trendWindowMinutes = 3,
    this.learningAlcohol = false,
    this.alcohol = false,
    this.caffeine = false,
    this.workout = false,
    this.stress = false,
    this.sick = false,
    this.lateMeal = false,
  }) : assert(hrArousalBpm >= 4 && hrArousalBpm < double.infinity),
       assert(motionCeilingG >= 0 && motionCeilingG <= .08),
       assert(protectionMinutes >= 5),
       assert(trendWindowMinutes >= 3);
  static const identity = ConfounderProfile();
  double get trendThresholdFactor =>
      (stress || sick ? .5 : 1) * (lateMeal ? 1.5 : 1);
  // Stable active-set identity. Persisted and displayed only as a number.
  int get track =>
      (alcohol || learningAlcohol ? 1 : 0) |
      (caffeine ? 2 : 0) |
      (lateMeal ? 4 : 0) |
      (stress ? 8 : 0) |
      (sick ? 16 : 0) |
      (workout ? 32 : 0);
  bool get disableEarlyDelivery => alcohol && stress;
  // Product of max/min semilattices and boolean OR. Derive multipliers only
  // after combination: stress+sick tightens once, independent of grouping.
  ConfounderProfile combine(ConfounderProfile other) => ConfounderProfile(
    hrArousalBpm: math.max(hrArousalBpm, other.hrArousalBpm),
    motionCeilingG: math.min(motionCeilingG, other.motionCeilingG),
    protectionMinutes: math.max(protectionMinutes, other.protectionMinutes),
    trendWindowMinutes: math.max(trendWindowMinutes, other.trendWindowMinutes),
    userTrackIds: {...userTrackIds, ...other.userTrackIds},
    adjustedFor: {...adjustedFor, ...other.adjustedFor},
    learningAlcohol: learningAlcohol || other.learningAlcohol,
    alcohol: alcohol || other.alcohol,
    caffeine: caffeine || other.caffeine,
    workout: workout || other.workout,
    stress: stress || other.stress,
    sick: sick || other.sick,
    lateMeal: lateMeal || other.lateMeal,
  );
  @override
  bool operator ==(Object other) =>
      other is ConfounderProfile &&
      userTrackIds.length == other.userTrackIds.length &&
      userTrackIds.containsAll(other.userTrackIds) &&
      adjustedFor.length == other.adjustedFor.length &&
      adjustedFor.containsAll(other.adjustedFor) &&
      hrArousalBpm == other.hrArousalBpm &&
      motionCeilingG == other.motionCeilingG &&
      protectionMinutes == other.protectionMinutes &&
      trendWindowMinutes == other.trendWindowMinutes &&
      learningAlcohol == other.learningAlcohol &&
      alcohol == other.alcohol &&
      caffeine == other.caffeine &&
      workout == other.workout &&
      stress == other.stress &&
      sick == other.sick &&
      lateMeal == other.lateMeal;
  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(userTrackIds),
    Object.hashAllUnordered(adjustedFor),
    hrArousalBpm,
    motionCeilingG,
    protectionMinutes,
    trendWindowMinutes,
    learningAlcohol,
    alcohol,
    caffeine,
    workout,
    stress,
    sick,
    lateMeal,
  );
}

/// Built-in presets form a monoid on the domain of tightening profiles:
/// HR>=4, ceiling<=.08, protection>=5, trend>=3. Identity is the default.
/// Engineering choices inherited from #630; no claim of clinical validation.
ConfounderProfile wakeConfounders(
  List<WakeJournalDay> days, {
  DateTime? expectedBedtime,
}) {
  var result = ConfounderProfile.identity;
  final tags = <String>{};
  var stressRating = false;
  for (final day in days) {
    tags.addAll(day.tags);
    final rating = day.metrics['stress']?.value;
    stressRating |= rating != null && rating.isFinite && rating >= 4;
    bool active(
      String field,
      double minimum,
      int leadHours,
      int fallbackMinute,
    ) {
      final v = day.metrics[field];
      final minute = v?.atMinuteOfDay;
      if (v == null ||
          !v.value.isFinite ||
          v.value < minimum ||
          minute == null ||
          minute < 0 ||
          minute >= 1440) {
        return false;
      }
      final bed = expectedBedtime;
      if (bed == null) return minute >= fallbackMinute;
      final at = DateTime(
        day.date.year,
        day.date.month,
        day.date.day,
        minute ~/ 60,
        minute % 60,
      );
      return !at.isBefore(bed.subtract(Duration(hours: leadHours))) &&
          !at.isAfter(bed);
    }

    final units = day.metrics['alcohol_units']?.value;
    final minute = day.metrics['alcohol_units']?.atMinuteOfDay;
    final intake = minute == null
        ? null
        : DateTime(
            day.date.year,
            day.date.month,
            day.date.day,
            minute ~/ 60,
            minute % 60,
          );
    final beforeBed =
        expectedBedtime == null ||
        intake == null ||
        !intake.isAfter(expectedBedtime);
    if (beforeBed &&
        (day.tags.contains('alcohol') ||
            (units != null && units.isFinite && units > 0))) {
      result = result.combine(const ConfounderProfile(learningAlcohol: true));
    }
    if (active('alcohol_units', double.minPositive, 2, 20 * 60)) {
      result = result.combine(
        const ConfounderProfile(
          alcohol: true,
          hrArousalBpm: 6,
          trendWindowMinutes: 5,
        ),
      );
    }
    if (active('caffeine_mg', 200, 6, 16 * 60)) {
      result = result.combine(
        const ConfounderProfile(caffeine: true, hrArousalBpm: 6),
      );
    }
  }
  if (tags.contains('stress') || stressRating) {
    result = result.combine(
      const ConfounderProfile(stress: true, motionCeilingG: .06),
    );
  }
  if (tags.contains('sick')) {
    result = result.combine(
      const ConfounderProfile(sick: true, hrArousalBpm: 5, motionCeilingG: .06),
    );
  }
  if (tags.contains('late meal')) {
    result = result.combine(
      const ConfounderProfile(lateMeal: true, hrArousalBpm: 5),
    );
  }
  if (tags.contains('workout') && !tags.contains('rest day')) {
    result = result.combine(
      const ConfounderProfile(
        workout: true,
        protectionMinutes: 10,
        trendWindowMinutes: 5,
      ),
    );
  }
  return result;
}
