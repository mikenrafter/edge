// Owns the occurrence's journal profile and its sole in-memory cache.
import '../state/control_operations.dart';
import 'wake_confounders.dart';

abstract interface class WakeNightSource {
  Future<String> revision(DateTime from, DateTime to);
  Future<ConfounderProfile> profile(
    DateTime from,
    DateTime to,
    DateTime? expectedBedtime,
  );
}

class WakeNightValue {
  final ConfounderProfile profile;

  /// Neutral status only. Journal names and read errors never enter traces.
  final String diagnostic;
  const WakeNightValue(this.profile, this.diagnostic);
}

class WakeNightContext {
  final WakeNightSource source;
  WakeNightContext(this.source);
  (int, int?, int?, String)? _key;
  WakeNightValue? _cached;

  Future<WakeNightValue> load(
    DateTime occurrence,
    ExpectedSleepSchedule? schedule,
  ) async {
    final bed = schedule?.windowFor(occurrence).$1;
    // Without a saved schedule only, preserve the upstream 20:00/16:00
    // clock-time cutoffs on the preceding evening's date. No inferred bedtime.
    final d = occurrence.toLocal();
    final anchor =
        bed ?? DateTime(d.year, d.month, d.day - (d.hour < 22 ? 1 : 0), 22);
    final lead = anchor.subtract(const Duration(hours: 6));
    final from = DateTime(lead.year, lead.month, lead.day);
    final to = DateTime(anchor.year, anchor.month, anchor.day + 1);
    try {
      final revision = await source.revision(from, to);
      final key = (
        occurrence.millisecondsSinceEpoch,
        schedule?.onsetMinute,
        schedule?.wakeMinute,
        revision,
      );
      if (_key == key && _cached != null) return _cached!;
      final profile = await source.profile(from, to, bed);
      // A concurrent journal edit must not be cached under the old stamp.
      if (await source.revision(from, to) != revision) {
        return const WakeNightValue(ConfounderProfile(), 'context_changed');
      }
      final value = WakeNightValue(profile, 'context_ready');
      _key = key;
      _cached = value;
      return value;
    } catch (_) {
      _key = null;
      _cached = null; // Retry next tick, never cache a read failure.
      return const WakeNightValue(ConfounderProfile(), 'context_unavailable');
    }
  }
}
