// ECG results (ecg-features): the saved result's metrics, the rule that lets a
// new reading replace a recent inconclusive one, and the thresholds around a
// partial recording. Pure Dart.
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
  String get display {
    final v = value;
    if (v == null) return '—';
    final n = v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
    return unit.isEmpty ? n : '$n $unit';
  }
}

/// The metrics a saved [r] really has, in page order: Average heart rate (bpm)
/// then Signal quality. A band value of 0 (it sends 0 for "none") is null here,
/// never 0. Never contains 'rmssd' or 'sdnn'.
List<EcgMetric> ecgMetricsOf(EcgReading r) {
  // The band sends 0 for "none"; 0 is absence here, never a measured zero.
  double? present(int? v) => (v == null || v <= 0) ? null : v.toDouble();
  return [
    EcgMetric(
      key: 'avgHr',
      name: 'Average heart rate',
      value: present(r.avgHr),
      unit: 'bpm',
    ),
    EcgMetric(
      key: 'quality',
      name: 'Signal quality',
      value: present(r.quality),
      unit: '',
    ),
  ];
}

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
}) {
  if (latest == null || latest.status != EcgReadingStatus.inconclusive) {
    return null;
  }
  if (incoming.status == EcgReadingStatus.partial) return null;
  final gap = incoming.startTs - latest.endTs;
  if (gap < 0 || gap > kEcgOverwriteWindow.inSeconds) return null;
  return latest.id;
}

/// Design 04 R2''' - the attempt-group join rule, replacing the delete-based
/// [ecgReplaceTargetId] (RED stub).
///
/// The id of the latest reading that [incoming] joins as a further attempt, or
/// null when it starts a new group. gap = incoming.startTs - latest.endTs;
/// joins iff 0 <= gap <= [kEcgOverwriteWindow] in seconds AND [latest] is
/// non-final (status inconclusive, or category unreadable) AND neither side is
/// a partial.
String? ecgJoinTargetId({
  required EcgReading? latest,
  required EcgReading incoming,
}) => throw UnimplementedError('design 04 phase 1: ecgJoinTargetId');
