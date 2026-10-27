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

@sendable
class ConfounderProfile {
  final double hrArousalBpm, motionCeilingG;
  final int protectionMinutes, trendWindowMinutes;
  final bool alcohol, stress, sick, lateMeal;
  const ConfounderProfile({
    this.hrArousalBpm = 4,
    this.motionCeilingG = .08,
    this.protectionMinutes = 5,
    this.trendWindowMinutes = 3,
    this.alcohol = false,
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
  bool get disableEarlyDelivery => alcohol && stress;
  // Product of max/min semilattices and boolean OR. Derive multipliers only
  // after combination: stress+sick tightens once, independent of grouping.
  ConfounderProfile combine(ConfounderProfile other) => ConfounderProfile(
    hrArousalBpm: math.max(hrArousalBpm, other.hrArousalBpm),
    motionCeilingG: math.min(motionCeilingG, other.motionCeilingG),
    protectionMinutes: math.max(protectionMinutes, other.protectionMinutes),
    trendWindowMinutes: math.max(trendWindowMinutes, other.trendWindowMinutes),
    alcohol: alcohol || other.alcohol,
    stress: stress || other.stress,
    sick: sick || other.sick,
    lateMeal: lateMeal || other.lateMeal,
  );
  @override
  bool operator ==(Object other) =>
      other is ConfounderProfile &&
      hrArousalBpm == other.hrArousalBpm &&
      motionCeilingG == other.motionCeilingG &&
      protectionMinutes == other.protectionMinutes &&
      trendWindowMinutes == other.trendWindowMinutes &&
      alcohol == other.alcohol &&
      stress == other.stress &&
      sick == other.sick &&
      lateMeal == other.lateMeal;
  @override
  int get hashCode => Object.hash(
    hrArousalBpm,
    motionCeilingG,
    protectionMinutes,
    trendWindowMinutes,
    alcohol,
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
      result = result.combine(const ConfounderProfile(hrArousalBpm: 6));
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
      const ConfounderProfile(protectionMinutes: 10, trendWindowMinutes: 5),
    );
  }
  return result;
}
