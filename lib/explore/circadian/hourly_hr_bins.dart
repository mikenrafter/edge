// hourly_hr_bins.dart — local-hour bins of recorded heart rate, from a day's
// stored minute curve. Input to the circadian explore rhythm fit.
//
// Source: `series.hr_curve` of a derived day (`getDayHeart(day)['hr']`), one
// `{t: epochSec, v: bpm}` point per minute that had at least one valid sample
// (hr > 0). It is what survives: `decoded_onehz` is pruned at
// `rawRetentionDays` = 3, so a 14-day window cannot be read from it, while
// `day_result` is never pruned.
//
// Hour boundaries are found with LOCAL DateTime, never 3600 s arithmetic from a
// midnight: a spring-forward day has 23 local hours, a fall-back day has 25
// (the repeated wall hour is two bins). Pure; [toLocal] is injectable so a test
// can stand in any time zone.

import 'hr_rhythm_fit.dart';

/// Bins [curve] by local clock hour. A point with no usable `t`/`v`, or with
/// `v <= 0`, is skipped (no sample, not a zero). [HourlyBin.meanHr] is the mean
/// of the minute values; [HourlyBin.realMinutes] counts the minutes that
/// carried one. Oldest hour first.
List<HourlyBin> hourlyBinsFromHrCurve(
  Iterable<Object?> curve, {
  DateTime Function(int epochSec)? toLocal,
}) {
  DateTime local(int sec) => (toLocal ?? _device)(sec);
  final sums = <int, double>{}; // hour start (epoch s) -> sum of minute values
  final counts = <int, int>{};
  for (final e in curve) {
    if (e is! Map) continue;
    final t = e['t'], v = e['v'];
    if (t is! num || v is! num || !v.isFinite || v <= 0) continue;
    final sec = t.toInt();
    final l = local(sec);
    // Back to the start of this local hour, in real seconds, so a repeated
    // wall hour keeps its two instants apart.
    final hourStart = sec - l.minute * 60 - l.second;
    sums[hourStart] = (sums[hourStart] ?? 0) + v.toDouble();
    counts[hourStart] = (counts[hourStart] ?? 0) + 1;
  }
  final starts = sums.keys.toList()..sort();
  return [
    for (final h in starts)
      HourlyBin(
        hourStartLocal: local(h),
        meanHr: sums[h]! / counts[h]!,
        realMinutes: counts[h]!,
      ),
  ];
}

DateTime _device(int sec) => DateTime.fromMillisecondsSinceEpoch(sec * 1000);
