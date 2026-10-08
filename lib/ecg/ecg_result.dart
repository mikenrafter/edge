// ECG results (ecg-features): the saved result's metrics, the rule that lets a
// new reading join a recent non-final one's attempt group, and the thresholds
// around a partial recording. Pure Dart.
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
import 'ecg_outcome.dart';

/// A new reading that starts within this long after a non-final one ended joins
/// its attempt group (owner spec: 10 minutes). Inclusive: exactly 10:00 still
/// joins.
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

/// The id of the latest reading that [incoming] joins as a further attempt, or
/// null when it starts a new group (design 04 R2, decision 2).
///
/// [latest] is the most recent saved reading (by end time), or null. It is
/// joined iff ALL hold: neither side is a partial (a fuller record is never
/// traded for a thinner one, and a stopped recording is never an attempt at
/// anything); [latest] is NON-FINAL, meaning its [ecgOutcome] is not readable or
/// inconclusive (the same outcome the screens show, so a "regular" reading the
/// band's noise bit overrode is retaken, not kept as a verdict); and
/// 0 <= incoming.startTs - latest.endTs <= [kEcgOverwriteWindow] in seconds (a
/// start before the end is clock skew or overlap and starts a new group).
/// Nothing is deleted: the join only decides the group.
String? ecgJoinTargetId({
  required EcgReading? latest,
  required EcgReading incoming,
}) {
  if (latest == null) return null;
  if (latest.status == EcgReadingStatus.partial ||
      incoming.status == EcgReadingStatus.partial) {
    return null;
  }
  final kind = ecgOutcome(latest).kind;
  if (kind != EcgOutcomeKind.notReadable &&
      kind != EcgOutcomeKind.inconclusive) {
    return null;
  }
  final gap = incoming.startTs - latest.endTs;
  if (gap < 0 || gap > kEcgOverwriteWindow.inSeconds) return null;
  return latest.id;
}
