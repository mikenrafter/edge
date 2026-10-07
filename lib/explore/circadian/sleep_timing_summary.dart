// sleep_timing_summary.dart — observed sleep timing and its variability, from
// nightly sleep windows. Output 1 of 3 of the circadian explore prototype.
//
// Pure: no Flutter, no database. Clock values are circular statistics over the
// 24 h clock (23:30 and 00:30 average to 00:00, not 12:00). Under three nights
// every field is null: nothing is estimated from one or two nights.
//
// PROTOTYPE: moves to the analytics repo if it ships (AGENTS.md section 1).

import 'dart:math' as math;

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

SleepTimingSummary summarise(List<NightWindow> nights) {
  final valid = [
    for (final n in nights)
      if (n.offset.isAfter(n.onset)) n,
  ];
  if (valid.length < kMinNightsForSummary) {
    return SleepTimingSummary(nights: valid.length);
  }
  final onsets = <double>[], wakes = <double>[], mids = <double>[];
  for (final n in valid) {
    onsets.add(_clockSeconds(n.onset));
    wakes.add(_clockSeconds(n.offset));
    // Real elapsed time, so a night that spans a DST change has its true
    // midpoint; `add` moves the instant, not the wall clock.
    final half = n.offset.difference(n.onset).inMicroseconds ~/ 2;
    mids.add(_clockSeconds(n.onset.add(Duration(microseconds: half))));
  }
  final onset = _Circular.of(onsets);
  return SleepTimingSummary(
    meanOnsetClock: onset.mean,
    meanWakeClock: _Circular.of(wakes).mean,
    onsetSpread: onset.sd,
    midSleepClock: _Circular.of(mids).mean,
    nights: valid.length,
  );
}

const double _daySeconds = 24 * 3600;

/// Wall-clock seconds since local midnight of [t].
double _clockSeconds(DateTime t) =>
    (t.hour * 3600 + t.minute * 60 + t.second).toDouble();

/// Mean and standard deviation of points on the 24 h circle.
class _Circular {
  _Circular(this.mean, this.sd);

  /// Both null when the points cancel out (resultant length ~ 0): no direction
  /// exists, so none is reported.
  final Duration? mean;
  final Duration? sd;

  factory _Circular.of(List<double> seconds) {
    var c = 0.0, s = 0.0;
    for (final x in seconds) {
      final a = 2 * math.pi * x / _daySeconds;
      c += math.cos(a);
      s += math.sin(a);
    }
    c /= seconds.length;
    s /= seconds.length;
    final r = math.sqrt(c * c + s * s);
    if (r < 1e-9) return _Circular(null, null);
    var secs = (math.atan2(s, c) * _daySeconds / (2 * math.pi)).round();
    secs = ((secs % 86400) + 86400) % 86400;
    // Circular SD, sqrt(-2 ln R) radians, in seconds of clock.
    final sdRad = math.sqrt(math.max(0.0, -2 * math.log(math.min(r, 1.0))));
    return _Circular(
      Duration(seconds: secs),
      Duration(seconds: (sdRad * _daySeconds / (2 * math.pi)).round()),
    );
  }
}
