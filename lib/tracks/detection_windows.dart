// Builds detection windows from a derived day's own curves (hr_curve per
// minute, hrv_timeline, activity_curve per 5 minutes; epoch seconds). One
// source per concern: nothing here reads raw samples, so there is no second
// pass over the substrate. A missing signal stays null and a detector refuses
// it; no value is imputed from another signal.
//
// Baselines are the wearer's own:
//   early sleep: median of the prior nights' resting HR and RMSSD (>= 7 nights).
//   awake: the median of the same day's resting hours (>= 4 of them).
// The nightly resting HR is the lowest sustained rate, so it sits a little
// under the first hours of sleep; that biases the HR half toward a match and
// is why alcohol also needs the RMSSD drop.
import 'dart:math' as math;

class TrackDetectionWindows {
  const TrackDetectionWindows._();

  static const earlySleepSeconds = 3 * 3600;
  static const awakeSeconds = 3600;
  static const minBaselineNights = 7;
  static const minRestingHours = 4;
  static const restingMotion = .1;
  static const restingCoverage = .5;

  static double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

  /// (t, v) points that are finite and in order of appearance.
  static List<(int, double)> _points(Iterable<Object?> curve) => [
    for (final p in curve)
      if (p is Map && _num(p['t']) != null && _num(p['v']) != null)
        (_num(p['t'])!.toInt(), _num(p['v'])!),
  ];

  static double? _mean(Iterable<double> v) =>
      v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;

  static double? _median(List<double> v) {
    if (v.isEmpty) return null;
    final s = [...v]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  static double? _baseline(List<double> history) {
    final finite = [for (final h in history) if (h.isFinite) h];
    return finite.length >= minBaselineNights ? _median(finite) : null;
  }

  static List<Map<String, Object?>> build({
    required List<Object?> hrCurve,
    required List<Object?> hrvTimeline,
    required List<Object?> activityCurve,
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required List<double> rhrHistory,
    required List<double> rmssdHistory,
  }) {
    final hr = _points(hrCurve), hrv = _points(hrvTimeline);
    final motion = _points(activityCurve);
    final out = <Map<String, Object?>>[];
    final slept = sleepOffsetSec > sleepOnsetSec;

    if (slept) {
      final end = math.min(sleepOnsetSec + earlySleepSeconds, sleepOffsetSec);
      final hrIn = [for (final p in hr) if (p.$1 >= sleepOnsetSec && p.$1 < end) p.$2];
      final hrvIn = [for (final p in hrv) if (p.$1 >= sleepOnsetSec && p.$1 < end) p.$2];
      final motionIn = [
        for (final p in motion) if (p.$1 >= sleepOnsetSec && p.$1 < end) p.$2,
      ];
      out.add({
        'start_ts': sleepOnsetSec,
        'end_ts': end,
        'phase': 'early_sleep',
        'hr': _mean(hrIn),
        'rmssd': _mean(hrvIn),
        'baseline_hr': _baseline(rhrHistory),
        'baseline_rmssd': _baseline(rmssdHistory),
        'motion': _mean(motionIn),
        'coverage': math.min(1.0, hrIn.length * 60 / (end - sleepOnsetSec)),
      });
    }

    final first = hr.isEmpty ? null : hr.map((p) => p.$1).reduce(math.min);
    final last = hr.isEmpty ? null : hr.map((p) => p.$1).reduce(math.max);
    final awake = <Map<String, Object?>>[];
    if (first != null && last != null) {
      for (var s = first - first % awakeSeconds; s <= last; s += awakeSeconds) {
        final e = s + awakeSeconds;
        if (slept && s < sleepOffsetSec && e > sleepOnsetSec) continue;
        final hrIn = [for (final p in hr) if (p.$1 >= s && p.$1 < e) p.$2];
        if (hrIn.isEmpty) continue;
        final motionIn = [for (final p in motion) if (p.$1 >= s && p.$1 < e) p.$2];
        awake.add({
          'start_ts': s,
          'end_ts': e,
          'phase': 'awake',
          'hr': _mean(hrIn),
          'rmssd': null,
          'baseline_hr': null,
          'baseline_rmssd': null,
          'motion': _mean(motionIn),
          'coverage': math.min(1.0, hrIn.length * 60 / awakeSeconds),
        });
      }
    }
    final resting = [
      for (final w in awake)
        if ((w['motion'] as double?) != null &&
            (w['motion'] as double) <= restingMotion &&
            (w['coverage'] as double) >= restingCoverage)
          w['hr'] as double,
    ];
    final dayBaseline = resting.length >= minRestingHours ? _median(resting) : null;
    for (final w in awake) {
      w['baseline_hr'] = dayBaseline;
    }
    return [...out, ...awake];
  }
}
