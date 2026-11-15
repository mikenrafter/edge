// Owner: the immutable derive job. Delivery provenance never changes analytics.
import 'dart:convert';

import '../data/day_label.dart';

/// Where a derive pass's input came from. It only chooses HOW a newly flagged
/// day is announced: [recentSync] days alert one by one, every other origin
/// folds them into one summary. No origin silences a flagged day.
enum ProcessingOrigin { recentSync, historical, reanalysis }

/// CLAIM(pulse-origin): a day flagged for the first time is announced exactly
/// once, whatever its age [pulse_phase1_notification_test]. A band sync that
/// carried records for the day announces it by itself; any other path (import,
/// backfill, restore, reanalysis, algorithm bump) announces it in one summary.
class ProcessingContext {
  const ProcessingContext(this.origin, [this.pulseDays = const {}]);
  static const reanalysis = ProcessingContext(ProcessingOrigin.reanalysis);
  static const historical = ProcessingContext(ProcessingOrigin.historical);

  final ProcessingOrigin origin;

  // Day -> first arrival instant (epoch ms) of a record the band delivered for
  // it. Used to scope the pass and to pick individual alerts. No episode bounds
  // are implied.
  final Map<String, int> pulseDays;

  factory ProcessingContext.arrival(
    Iterable<({int recordedMs, int arrivedMs})> records,
  ) {
    final days = <String, int>{};
    for (final r in records) {
      if (r.recordedMs <= 0) continue;
      final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(r.recordedMs));
      final prior = days[day];
      if (prior == null || r.arrivedMs < prior) days[day] = r.arrivedMs;
    }
    return ProcessingContext(ProcessingOrigin.recentSync, Map.unmodifiable(days));
  }

  /// The days this context announces one by one.
  Set<String> get individualDays =>
      origin == ProcessingOrigin.recentSync ? pulseDays.keys.toSet() : const {};

  /// A version migration, import snapshot or forced pass is a bulk path even
  /// when new records arrived with it: its days fold into the summary.
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
  });

  ProcessingContext merge(ProcessingContext other) {
    // Different origins are separate queue jobs.
    if (origin != other.origin) return this;
    return ProcessingContext(origin, {
      ...other.pulseDays,
      for (final e in pulseDays.entries)
        e.key: e.value <= (other.pulseDays[e.key] ?? e.value)
            ? e.value
            : other.pulseDays[e.key]!,
    });
  }

  String encode() => jsonEncode({
    'origin': origin.name,
    'pulseDays': pulseDays,
  });
  static ProcessingContext decode(Object? raw) {
    try {
      final m = jsonDecode(raw as String) as Map;
      final origin = ProcessingOrigin.values.byName(m['origin'] as String);
      final days = (m['pulseDays'] as Map).cast<String, int>();
      return ProcessingContext(origin, Map.unmodifiable(days));
    } catch (_) {
      return reanalysis;
    }
  }
}
