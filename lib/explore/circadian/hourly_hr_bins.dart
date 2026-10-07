// hourly_hr_bins.dart — local-hour bins of recorded heart rate, from a day's
// stored minute curve. Input to the circadian explore rhythm fit.
//
// Source: `series.hr_curve` of a derived day (`getDayHeart(day)['hr']`), one
// `{t: epochSec, v: bpm, n: validSeconds}` point per minute that had at least
// one valid sample (hr > 0). `n` is the count of valid seconds behind that
// minute's mean. It is what survives: `decoded_onehz` is pruned at
// `rawRetentionDays` = 3, so a 14-day window cannot be read from it, while
// `day_result` is never pruned.
//
// A stored minute is NOT a real minute: it exists from even one valid second.
// So a minute counts toward [HourlyBin.realMinutes] only with
// `n >= kMinValidSecondsPerMinute`. Days stored before `n` existed carry no
// `n`; their real-minute count is unknown, and a missing `n` on any point of an
// hour makes that hour's [HourlyBin.realMinutes] null, never an assumed number.
//
// Hour boundaries are found with LOCAL DateTime, never 3600 s arithmetic from a
// midnight: a spring-forward day has 23 local hours, a fall-back day has 25
// (the repeated wall hour is two bins). Pure; [toLocal] is injectable so a test
// can stand in any time zone.

import 'hr_rhythm_fit.dart';

/// A minute counts as a real minute only with at least this many valid
/// seconds behind its mean.
const int kMinValidSecondsPerMinute = 30;

/// Bins [curve] by local clock hour. A point with no usable `t`/`v`, or with
/// `v <= 0`, is skipped (no sample, not a zero).
///
/// [HourlyBin.realMinutes] is the count of minutes with
/// `n >= kMinValidSecondsPerMinute`, or null (unknown) when any point of the
/// hour has no numeric `n`. When it is known, [HourlyBin.meanHr] is the mean of
/// those counted minutes only (null when there are none); when it is unknown,
/// the mean of every stored minute, which the fit will not admit. Oldest hour
/// first.
List<HourlyBin> hourlyBinsFromHrCurve(
  Iterable<Object?> curve, {
  DateTime Function(int epochSec)? toLocal,
}) {
  DateTime local(int sec) => (toLocal ?? _device)(sec);
  final all = <int, List<double>>{}; // hour start (epoch s) -> every minute
  final real = <int, List<double>>{}; // ... only minutes with enough seconds
  final unknown = <int>{}; // hours with a point that has no `n`
  for (final e in curve) {
    if (e is! Map) continue;
    final t = e['t'], v = e['v'], n = e['n'];
    if (t is! num || v is! num || !v.isFinite || v <= 0) continue;
    final sec = t.toInt();
    final l = local(sec);
    // Back to the start of this local hour, in real seconds, so a repeated
    // wall hour keeps its two instants apart.
    final hourStart = sec - l.minute * 60 - l.second;
    (all[hourStart] ??= []).add(v.toDouble());
    if (n is! num || !n.isFinite) {
      unknown.add(hourStart);
    } else if (n >= kMinValidSecondsPerMinute) {
      (real[hourStart] ??= []).add(v.toDouble());
    }
  }
  final starts = all.keys.toList()..sort();
  return [
    for (final h in starts)
      if (unknown.contains(h))
        HourlyBin(
          hourStartLocal: local(h),
          meanHr: _mean(all[h]!),
          realMinutes: null,
        )
      else
        HourlyBin(
          hourStartLocal: local(h),
          meanHr: real[h] == null ? null : _mean(real[h]!),
          realMinutes: real[h]?.length ?? 0,
        ),
  ];
}

double _mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;

DateTime _device(int sec) => DateTime.fromMillisecondsSinceEpoch(sec * 1000);
