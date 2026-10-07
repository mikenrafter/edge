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
/// by the night's sleep WINDOW (onset to offset, wake included, the interval
/// the detector reads) must reach this fraction.
const double kPulseMinCoverage = 0.80;

/// Exclusion wording, as it appears on screen.
const String kPulseExclusionNotAnalysed = 'not analysed';
const String kPulseExclusionUnderHours = 'under 4 analysed hours';
const String kPulseExclusionUnderCoverage = 'coverage under 80%';
const String kPulseExclusionCoverageUnknown = 'coverage unknown';
const String kPulseExclusionLongerThanWindow =
    'analysis longer than the sleep window';
const String kPulseExclusionIrregularRhythm = 'irregular rhythm flagged';

/// Caveat wording (does not exclude the night): no stored irregular-rhythm
/// screen result exists for the day, so the exclusion could not be applied.
const String kPulseCaveatRhythmUnavailable = 'rhythm screen unavailable';

class PulsePatternNight {
  const PulsePatternNight({
    required this.dayId,
    this.analysedHours,
    this.coverage,
    this.cycleCount,
    this.cyclesPerHour,
    this.exclusions = const [],
    this.caveats = const [],
    this.detectorNote,
  });

  /// Local day label (`data/day_label.dart`), e.g. `2026-10-07`.
  final String dayId;

  /// Observed hours the detector analysed (`analyzed_hours`); null when the
  /// night was not analysed.
  final double? analysedHours;

  /// analysedHours / sleep window hours; null when either is unknown. Never
  /// clamped: a value above 1 is an excluded night
  /// ([kPulseExclusionLongerThanWindow]).
  final double? coverage;

  /// Detector cycles (`cycle_count`). null = NOT ANALYSED, which is a
  /// different fact from 0 (analysed, none found).
  final int? cycleCount;

  /// cycleCount / analysedHours; null when either is null or hours are 0.
  final double? cyclesPerHour;

  /// Why the night is out of the comparison, in words
  /// (`kPulseExclusion*`). Empty for an admitted night.
  final List<String> exclusions;

  /// Things worth saying about an admitted-or-not night that are NOT reasons
  /// to exclude it (`kPulseCaveat*`). Never affects [admitted].
  final List<String> caveats;

  /// The envelope's `note`, exactly as stored (it uses vocabulary the screen
  /// must not repeat). Null when the envelope had none.
  final String? detectorNote;

  /// True when the night was analysed and no gate excluded it:
  /// `cycleCount != null && exclusions.isEmpty`.
  bool get admitted => cycleCount != null && exclusions.isEmpty;
}

/// Parses the persisted `respiration.cvhr_apnea` envelope exactly as stored.
///
/// [envelope] is whatever the read seam hands over (`getDayLungs()['cvhr']`):
/// a Map, null, or something malformed. [windowHours] is the night's sleep
/// WINDOW length (onset to offset), the coverage denominator: the detector
/// reads RR across that whole window, wake included, so asleep time is the
/// wrong interval. Null/non-positive makes coverage unknown (never assumed
/// 100%). [rhythmFlagged] is the stored irregular-rhythm screen for the day:
/// true excludes the night, false is regular, null is unknown (not excluded;
/// a caveat says the screen was unavailable).
///
/// Never throws. Absent, malformed or incomplete (`cycle_count` or
/// `analyzed_hours` missing, non-numeric, negative or non-finite) means
/// `cycleCount == null` with exclusions `['not analysed']`.
PulsePatternNight fromCvhrEnvelope(
  String dayId,
  Object? envelope, {
  double? windowHours,
  bool? rhythmFlagged,
}) {
  final note = envelope is Map && envelope['note'] is String
      ? envelope['note'] as String
      : null;
  PulsePatternNight notAnalysed() => PulsePatternNight(
        dayId: dayId,
        exclusions: const [kPulseExclusionNotAnalysed],
        detectorNote: note,
      );

  final value = envelope is Map ? envelope['value'] : null;
  if (value is! Map) return notAnalysed();
  final rawCycles = value['cycle_count'];
  final rawHours = value['analyzed_hours'];
  if (rawCycles is! num ||
      rawHours is! num ||
      !rawCycles.isFinite ||
      !rawHours.isFinite ||
      rawCycles < 0 ||
      rawHours < 0 ||
      rawCycles != rawCycles.truncate()) {
    return notAnalysed();
  }
  final cycles = rawCycles.toInt();
  final hours = rawHours.toDouble();

  // An unknown window leaves coverage unknown; it is never read as full, and
  // analysis longer than the window is flagged, never clamped.
  final coverage = windowHours != null && windowHours > 0
      ? hours / windowHours
      : null;
  final exclusions = <String>[
    if (hours < kPulseMinAnalysedHours) kPulseExclusionUnderHours,
    if (coverage == null)
      kPulseExclusionCoverageUnknown
    else if (coverage > 1.0)
      kPulseExclusionLongerThanWindow
    else if (coverage < kPulseMinCoverage)
      kPulseExclusionUnderCoverage,
    if (rhythmFlagged == true) kPulseExclusionIrregularRhythm,
  ];
  return PulsePatternNight(
    dayId: dayId,
    analysedHours: hours,
    coverage: coverage,
    cycleCount: cycles,
    cyclesPerHour: hours > 0 ? cycles / hours : null,
    exclusions: exclusions,
    caveats: [if (rhythmFlagged == null) kPulseCaveatRhythmUnavailable],
    detectorNote: note,
  );
}
