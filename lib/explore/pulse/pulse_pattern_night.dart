// One night of the EXISTING cardiac-pattern detector's output, as the
// developer-only research view reads it. Prototype: lib/explore/pulse/.
//
// What this is: a parse of the persisted metric envelope at
// `respiration.cvhr_apnea` in the day bundle (analytics `cvhrApneaScreen`,
// serialised by `Metric.toJson` around `CvhrResult.toJson`):
//
//   {"value": {"cycle_count": int, "cvhr_per_hour": num,
//              "analyzed_hours": num, "mean_depth_ms": num?,
//              "mean_width_sec": num?, "depth_quartiles_ms": [..]?,
//              "width_quartiles_sec": [..]?},
//    "confidence": num, "tier": str, "inputs_used": [..], "note": str?}
//
// An absent metric has `"value": "—"` (a string) and a `note` saying why.
//
// What this is NOT: a breathing measurement. The band has no airflow or
// oxygen sensor, the detector reads pulse-interval swings only, and nothing
// here derives minutes, an index or a category from the count. Absent is
// `cycleCount == null` and is never rendered or stored as 0.

/// Proposed engineering gate (not a clinical minimum): a night is admitted to
/// the comparison only with at least this many OBSERVED, analysed hours.
const double kPulseMinAnalysedHours = 4.0;

/// Proposed engineering gate (not a clinical minimum): analysed hours divided
/// by the night's sleep hours must reach this fraction.
const double kPulseMinCoverage = 0.80;

/// Exclusion wording, as it appears on screen.
const String kPulseExclusionNotAnalysed = 'not analysed';
const String kPulseExclusionUnderHours = 'under 4 analysed hours';
const String kPulseExclusionUnderCoverage = 'coverage under 80%';
const String kPulseExclusionCoverageUnknown = 'coverage unknown';

class PulsePatternNight {
  const PulsePatternNight({
    required this.dayId,
    this.analysedHours,
    this.coverage,
    this.cycleCount,
    this.cyclesPerHour,
    this.exclusions = const [],
    this.detectorNote,
  });

  /// Local day label (`data/day_label.dart`), e.g. `2026-10-07`.
  final String dayId;

  /// Observed hours the detector analysed (`analyzed_hours`); null when the
  /// night was not analysed.
  final double? analysedHours;

  /// analysedHours / sleep hours, clamped to 0..1; null when either is
  /// unknown.
  final double? coverage;

  /// Detector cycles (`cycle_count`). null = NOT ANALYSED, which is a
  /// different fact from 0 (analysed, none found).
  final int? cycleCount;

  /// cycleCount / analysedHours; null when either is null or hours are 0.
  final double? cyclesPerHour;

  /// Why the night is out of the comparison, in words
  /// (`kPulseExclusion*`). Empty for an admitted night.
  final List<String> exclusions;

  /// The envelope's `note`, exactly as stored (it uses vocabulary the screen
  /// must not repeat). Null when the envelope had none.
  final String? detectorNote;

  /// True when the night was analysed and no gate excluded it:
  /// `cycleCount != null && exclusions.isEmpty`.
  bool get admitted => throw UnimplementedError();
}

/// Parses the persisted `respiration.cvhr_apnea` envelope exactly as stored.
///
/// [envelope] is whatever the read seam hands over (`getDayLungs()['cvhr']`):
/// a Map, null, or something malformed. [sleepHours] is the night's sleep
/// duration, the coverage denominator; null/non-positive makes coverage
/// unknown (never assumed 100%).
///
/// Never throws. Absent, malformed or incomplete (`cycle_count` or
/// `analyzed_hours` missing, non-numeric, negative or non-finite) means
/// `cycleCount == null` with exclusions `['not analysed']`.
PulsePatternNight fromCvhrEnvelope(
  String dayId,
  Object? envelope, {
  double? sleepHours,
}) =>
    throw UnimplementedError();
