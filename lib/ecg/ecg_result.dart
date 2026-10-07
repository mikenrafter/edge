// ECG results (ecg-features): the saved result's metrics, the rule that lets a
// new reading replace a recent inconclusive one, and the thresholds around a
// partial recording. Pure Dart.
//
// RED STUBS: every function here throws UnimplementedError until the green
// phase. The constants are the decisions the tests pin.
//
// WHAT METRICS REALLY EXIST FOR ECG. Only what the band reports plus facts
// about the window: average heart rate (the band's terminal packet, or the
// live-HR mean of a partial), the band's signal quality, the duration, the
// interruption count and sample amplitude statistics. There is NO RMSSD or SDNN
// from an ECG: the pinned analytics computes those from the PPG-derived RR
// series ("PRV not ECG-HRV"), and neither it nor edge has an R-peak detector.
// A phone-side R-peak detector would be a new metric and belongs in the
// analytics repo (AGENTS.md section 1). So [ecgMetricsOf] never returns
// 'rmssd'/'sdnn' and a page never invents them.

import 'ecg_models.dart';

/// A new reading that starts within this long after an inconclusive one ended
/// replaces it (owner spec: 10 minutes). Inclusive: exactly 10:00 still replaces.
const Duration kEcgOverwriteWindow = Duration(minutes: 10);

/// A partial recording keeps metrics only with at least this many accepted
/// samples (10 s at the band's 100 Hz). Fewer: heart rate and quality are null.
const int kEcgPartialMinSamples = 1000;

/// One named metric of a result. [value] null = absent, shown as "—".
class EcgMetric {
  const EcgMetric({
    required this.key,
    required this.name,
    required this.value,
    required this.unit,
  });

  /// Stable id: 'avgHr', 'quality' (and any future 'rmssd', 'sdnn').
  final String key;

  /// What the page calls it: 'Average heart rate', 'Signal quality'.
  final String name;

  /// Null when absent. Never zero for "absent".
  final double? value;

  /// 'bpm', 'ms', or '' for a unitless value.
  final String unit;

  /// "77 bpm", "42 ms", "3" (no unit), "—" when [value] is null. A whole value
  /// has no decimals; 42.4 keeps one.
  String get display => throw UnimplementedError('EcgMetric.display');
}

/// The metrics a saved [r] really has, in page order: Average heart rate (bpm)
/// then Signal quality. A band value of 0 (it sends 0 for "none") is null here,
/// never 0. Never contains 'rmssd' or 'sdnn'.
List<EcgMetric> ecgMetricsOf(EcgReading r) =>
    throw UnimplementedError('ecgMetricsOf');

/// The id of the reading [incoming] replaces, or null to add it as a new one.
///
/// [latest] is the most recent saved reading (by end time), or null. Replace
/// iff ALL hold: [latest] is [EcgReadingStatus.inconclusive]; [incoming] is
/// complete or inconclusive (a partial neither replaces nor is replaced: a
/// fuller record is never traded for a thinner one); and 0 <= incoming.startTs
/// - latest.endTs <= [kEcgOverwriteWindow] in seconds (a start before the end,
/// a clock skew, adds). A complete or partial [latest] is never replaced, and
/// an older inconclusive hidden behind a newer reading is not considered.
String? ecgReplaceTargetId({
  required EcgReading? latest,
  required EcgReading incoming,
}) => throw UnimplementedError('ecgReplaceTargetId');
