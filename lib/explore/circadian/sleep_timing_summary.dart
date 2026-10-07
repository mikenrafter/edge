// sleep_timing_summary.dart — observed sleep timing and its variability, from
// nightly sleep windows. Output 1 of 3 of the circadian explore prototype.
//
// Pure: no Flutter, no database. Clock values are circular statistics over the
// 24 h clock (23:30 and 00:30 average to 00:00, not 12:00). Under three nights
// every field is null: nothing is estimated from one or two nights.
//
// PROTOTYPE: moves to the analytics repo if it ships (AGENTS.md section 1).

/// One night's sleep window, in local time (a TZDateTime in the wearer's zone
/// is fine). Elapsed time is `offset.difference(onset)`, so a night that spans
/// a DST change counts real elapsed hours, never wall-clock subtraction.
class NightWindow {
  const NightWindow({required this.onset, required this.offset});
  final DateTime onset;
  final DateTime offset;
}

/// Fewer valid nights than this and every clock field is null.
const int kMinNightsForSummary = 3;

class SleepTimingSummary {
  const SleepTimingSummary({
    this.meanOnsetClock,
    this.meanWakeClock,
    this.onsetSpread,
    this.midSleepClock,
    required this.nights,
  });

  /// Circular mean of onset, as time since local midnight, in [0, 24 h).
  final Duration? meanOnsetClock;

  /// Circular mean of wake time, since local midnight, in [0, 24 h).
  final Duration? meanWakeClock;

  /// Circular standard deviation of onset.
  final Duration? onsetSpread;

  /// Circular mean of each night's midpoint (onset + elapsed / 2).
  final Duration? midSleepClock;

  /// Valid nights counted (offset after onset). Reported even when under
  /// [kMinNightsForSummary].
  final int nights;
}

SleepTimingSummary summarise(List<NightWindow> nights) =>
    throw UnimplementedError();
