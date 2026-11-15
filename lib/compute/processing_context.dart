// Owner: the immutable derive job. Delivery provenance never changes analytics.
import 'dart:convert';

import '../data/day_label.dart';

/// Product latency policy for daily pulse alerts, not a detector threshold.
const kPulseAlertArrivalBudget = Duration(hours: 36);

enum ProcessingOrigin { recentSync, historical, reanalysis }

/// CLAIM(pulse-origin): only newly inserted pulse records from a recent sync
/// authorize interruption [pulse_phase1_notification_test]. Unknown provenance
/// is silent. Eligibility is frozen at arrival, never inferred at compute time.
class ProcessingContext {
  const ProcessingContext(
    this.origin, [
    this.pulseDays = const {},
    this.historyRevision = 0,
  ]);
  static const reanalysis = ProcessingContext(ProcessingOrigin.reanalysis);
  static const historical = ProcessingContext(ProcessingOrigin.historical);

  final ProcessingOrigin origin;
  final int historyRevision;
  // Day -> first arrival instant (epoch ms). No episode bounds are implied.
  final Map<String, int> pulseDays;

  factory ProcessingContext.arrival(
    Iterable<({int recordedMs, int arrivedMs})> records, {
    int historyRevision = 0,
  }) {
    final days = <String, int>{};
    for (final r in records) {
      final latency = r.arrivedMs - r.recordedMs;
      if (r.recordedMs <= 0 ||
          latency < 0 ||
          latency > kPulseAlertArrivalBudget.inMilliseconds) {
        continue;
      }
      final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(r.recordedMs));
      final prior = days[day];
      if (prior == null || r.arrivedMs < prior) days[day] = r.arrivedMs;
    }
    return ProcessingContext(
      ProcessingOrigin.recentSync,
      Map.unmodifiable(days),
      historyRevision,
    );
  }

  bool allowsPulseDay(String day, DateTime now) {
    final arrival = pulseDays[day];
    if (origin != ProcessingOrigin.recentSync || arrival == null) return false;
    final age = now.millisecondsSinceEpoch - arrival;
    return age >= 0 && age <= kPulseAlertArrivalBudget.inMilliseconds;
  }

  /// A version migration, import snapshot or forced pass never becomes fresh.
  ProcessingContext forDerivation({
    required bool forced,
    required int algoVersion,
    required Map<String, ({int version, bool imported})> previous,
  }) {
    if (forced) return reanalysis;
    if (origin != ProcessingOrigin.recentSync) return this;
    return onlyDays({
      for (final day in pulseDays.keys)
        if (previous[day] == null ||
            (previous[day]!.version == algoVersion && !previous[day]!.imported))
          day,
    });
  }

  ProcessingContext onlyDays(Set<String> days) => ProcessingContext(origin, {
    for (final e in pulseDays.entries)
      if (days.contains(e.key)) e.key: e.value,
  }, historyRevision);

  ProcessingContext merge(ProcessingContext other) {
    // Different origins are separate queue jobs. Never upgrade historical work.
    if (origin != other.origin) return this;
    if (historyRevision != other.historyRevision) {
      return historyRevision > other.historyRevision ? this : other;
    }
    return ProcessingContext(origin, {
      ...other.pulseDays,
      for (final e in pulseDays.entries)
        e.key: e.value <= (other.pulseDays[e.key] ?? e.value)
            ? e.value
            : other.pulseDays[e.key]!,
    }, historyRevision);
  }

  String encode() => jsonEncode({
    'origin': origin.name,
    'pulseDays': pulseDays,
    'historyRevision': historyRevision,
  });
  static ProcessingContext decode(Object? raw) {
    try {
      final m = jsonDecode(raw as String) as Map;
      final origin = ProcessingOrigin.values.byName(m['origin'] as String);
      final days = (m['pulseDays'] as Map).cast<String, int>();
      return ProcessingContext(
        origin,
        Map.unmodifiable(days),
        (m['historyRevision'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return reanalysis;
    }
  }
}
