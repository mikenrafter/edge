// Immutable learning values and pure policies. TracksStore owns persisted state.
import 'dart:math' as math;
import '../data/track_model.dart';
import '../data/day_label.dart';

part 'learning_estimator.dart';
part 'learning_statistics.dart';
part 'learning_kinetics.dart';
part 'learning_history.dart';

class TrackMoments {
  const TrackMoments({this.count = 0, this.mean = 0, this.m2 = 0});
  final int count;
  final double mean, m2;
  TrackMoments add(double value) {
    if (!value.isFinite) throw ArgumentError.value(value, 'value');
    final delta = value - mean;
    final nextMean = mean + delta / (count + 1);
    return TrackMoments(
      count: count + 1,
      mean: nextMean,
      m2: m2 + delta * (value - nextMean),
    );
  }

  TrackMoments merge(TrackMoments other) {
    if (count == 0) return other;
    if (other.count == 0) return this;
    final n = count + other.count;
    final delta = other.mean - mean;
    return TrackMoments(
      count: n,
      mean: mean + delta * other.count / n,
      m2: m2 + other.m2 + delta * delta * count * other.count / n,
    );
  }
}

class TrackLearningStep {
  const TrackLearningStep(this.value, this.changed, this.reason);
  final double? value;
  final bool changed;
  final String reason;
}

class TrackLearningPolicy {
  const TrackLearningPolicy({this.globalMinimum = const Duration(days: 28)});
  final Duration globalMinimum;
  Duration minimumFor(
    String field,
    TrackKinetics kinetics, {
    Duration? learnedMinimum,
  }) {
    double value(String key) => kinetics.fields[key]?.value ?? 0;
    final halfLife = value('half_life_hours') * 5;
    final withdrawal = value('withdrawal_days') * 24;
    final hours = switch (field) {
      'half_life_hours' => halfLife,
      'onset_hours' => math.max(halfLife, value('onset_hours') * 5),
      'tolerance_days' => math.max(
        math.max(halfLife, withdrawal),
        value(field) * 24,
      ),
      'withdrawal_days' => math.max(halfLife, withdrawal),
      _ => 0.0,
    };
    final intrinsic = (hours * Duration.microsecondsPerHour).ceil();
    final bounded = (learnedMinimum?.inMicroseconds ?? intrinsic).clamp(
      intrinsic,
      intrinsic * 2,
    );
    return Duration(microseconds: bounded);
  }

  TrackLearningStep step({
    required TrackDefinition track,
    required String field,
    required Duration age,
    required double target,
    required String reason,
    Duration? learnedMinimum,
    bool ignoreLock = false,
  }) {
    final current = track.kinetics.fields[field];
    TrackLearningStep hold(String why) =>
        TrackLearningStep(current?.value, false, why);
    if (age < globalMinimum) return hold('global_learning');
    if (current?.locked == true && !ignoreLock) return hold('locked');
    final value = current?.value;
    if (value == null) return hold('unknown_kinetics');
    if (age <
        minimumFor(field, track.kinetics, learnedMinimum: learnedMinimum)) {
      return hold('field_learning');
    }
    if (!target.isFinite || target < 0 || reason.trim().isEmpty) {
      return hold('invalid_proposal');
    }
    if (target == value) return hold('unchanged');
    // Zero has no relative scale. Require an explicit user value before fitting.
    if (value == 0) return hold('unknown_scale');
    final fraction = switch (field) {
      'half_life_hours' => .01,
      'onset_hours' => .015,
      'tolerance_days' => .02,
      'withdrawal_days' => .03,
      _ => 0.0,
    };
    final delta = (target - value).clamp(-value * fraction, value * fraction);
    return TrackLearningStep(value + delta, delta != 0, reason);
  }
}

class TrackNight {
  const TrackNight({
    required this.at,
    required this.bedtimeMinute,
    required this.sleepDebtHours,
    required this.load,
    required this.outcomes,
    required this.baselines,
    this.events = const [],
    this.completeTrackIds = const {},
    this.coverage = 1,
    this.negativeControls = const {},
    this.completeHistoryTrackIds = const {},
    this.negativeControlsByTrack = const {},
  });
  final DateTime at;
  final int bedtimeMinute;
  final double sleepDebtHours, load, coverage;
  final Map<String, double> outcomes, baselines, negativeControls;
  final List<TrackEvent> events;
  final Set<String> completeTrackIds;
  final Set<String> completeHistoryTrackIds;
  final Map<String, Map<String, double>> negativeControlsByTrack;
}

class TrackExposureFeatures {
  const TrackExposureFeatures({
    this.dose,
    this.residualMg,
    this.timingHours,
    this.nextNightDose,
    this.effectiveResidual,
    this.withdrawalPressure,
    this.exposureRunDays,
    this.abstinenceDays,
  });
  final double? dose, residualMg, timingHours, nextNightDose;
  final double? effectiveResidual, withdrawalPressure;
  final int? exposureRunDays, abstinenceDays;
}

class TrackEffectEstimate {
  const TrackEffectEstimate({
    required this.trackId,
    required this.system,
    required this.reason,
    this.effect,
    this.matchedPairs = 0,
    this.shuffleP,
    this.adjustedP,
    this.kineticTargets = const {},
    this.coefficients = const {},
    this.experimentId,
  });
  final String trackId, system, reason;

  /// Set when this estimate IS a completed randomized experiment's result.
  final String? experimentId;
  final double? effect;
  final int matchedPairs;
  final double? shuffleP, adjustedP;
  // Only independently validated temporal fits may propose kinetics.
  final Map<String, double> kineticTargets, coefficients;
}
