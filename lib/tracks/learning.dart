// Red-phase API scaffold. Tracks learning owns no mutable state.
import '../data/track_model.dart';

class TrackMoments {
  const TrackMoments({this.count = 0, this.mean = 0, this.m2 = 0});
  final int count;
  final double mean, m2;
  TrackMoments add(double value) => throw UnimplementedError();
  TrackMoments merge(TrackMoments other) => throw UnimplementedError();
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
  Duration minimumFor(String field, TrackKinetics kinetics,
      {Duration? learnedMinimum}) =>
      throw UnimplementedError();
  TrackLearningStep step({
    required TrackDefinition track,
    required String field,
    required Duration age,
    required double target,
    required String reason,
    Duration? learnedMinimum,
  }) => throw UnimplementedError();
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
  });
  final DateTime at;
  final int bedtimeMinute;
  final double sleepDebtHours, load, coverage;
  final Map<String, double> outcomes, baselines, negativeControls;
  final List<TrackEvent> events;
  final Set<String> completeTrackIds;
}

class TrackExposureFeatures {
  const TrackExposureFeatures({this.dose, this.residualMg,
    this.timingHours, this.nextNightDose});
  final double? dose, residualMg, timingHours, nextNightDose;
}

class TrackEffectEstimate {
  const TrackEffectEstimate({required this.trackId, required this.system,
    required this.reason, this.effect, this.matchedPairs = 0,
    this.shuffleP, this.adjustedP});
  final String trackId, system, reason;
  final double? effect;
  final int matchedPairs;
  final double? shuffleP, adjustedP;
}

class TrackEffectEstimator {
  const TrackEffectEstimator({this.minimumPairs = 12,
    this.priorWeight = 8, this.minimumCoverage = .8});
  final int minimumPairs;
  final double priorWeight, minimumCoverage;
  TrackExposureFeatures features(TrackDefinition track,
    List<TrackEvent> events, DateTime bedtime) => throw UnimplementedError();
  List<TrackEffectEstimate> estimate({required List<TrackDefinition> tracks,
    required List<TrackNight> nights, required DateTime asOf,
    Map<String, double> priors = const {}}) => throw UnimplementedError();
}
