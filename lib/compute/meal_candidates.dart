// Meal candidates are an unvalidated review aid, never a meal record. The
// day-block worker owns execution; ActivityStore owns the wearer's decision.
import '../data/day_label.dart';
import '../util/heavy.dart';

class MealSample {
  const MealSample({required this.ts, required this.hr, required this.motion,
    required this.minuteOfDay});
  final int ts, minuteOfDay;
  final double? hr, motion;
}

class MealExclusion {
  const MealExclusion(this.startTs, this.endTs);
  final int startTs, endTs;
}

/// Engineering thresholds and research limits: docs/meal-detection.md.
@heavy
List<Map<String, dynamic>> detectMealCandidatesHeavy(List<MealSample> samples, {
  List<MealExclusion> sleep = const [],
  List<MealExclusion> workouts = const [],
  List<int> typicalMealMinutes = const [],
  int maxPerDay = 10,
}) {
  if (maxPerDay <= 0) return [];
  // Unique minute input prevents repeated offloads extending a bout.
  final ordered = {for (final s in samples) s.ts: s}.values.toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));
  final candidates = <Map<String, dynamic>>[];
  final history = <MealSample>[];
  MealSample? first, last;
  double? baseline;
  var count = 0;
  void finish() {
    if (first != null && last != null && count >= 20) {
      final minute = first!.minuteOfDay;
      var distance = 720;
      for (final at in typicalMealMinutes) {
        if (at < 0 || at >= 1440) continue;
        final direct = (minute - at).abs();
        final circular = direct < 1440 - direct ? direct : 1440 - direct;
        if (circular < distance) distance = circular;
      }
      candidates.add({'start_ts': first!.ts, 'end_ts': last!.ts + 60,
        'baseline_hr': baseline, 'meal_time_distance_min': distance,
        'source': 'awake_hr_rise'});
    }
    first = last = null;
    baseline = null;
    count = 0;
  }
  for (final s in ordered) {
    final hr = s.hr, motion = s.motion;
    final excluded = [...sleep, ...workouts].any((e) =>
        s.ts < e.endTs && s.ts + 60 > e.startTs);
    final valid = hr != null && hr.isFinite && hr > 0 &&
        motion != null && motion.isFinite && motion >= 0 && motion <= .02 &&
        s.minuteOfDay >= 6 * 60 && s.minuteOfDay < 22 * 60 && !excluded;
    if (last != null && s.ts != last!.ts + 60) finish();
    history.removeWhere((p) => p.ts < s.ts - 3600);
    if (!valid) {
      finish();
      continue;
    }
    double? reference = baseline;
    if (reference == null && history.length >= 30) {
      final values = [for (final p in history) p.hr!]..sort();
      reference = values[values.length ~/ 2];
    }
    final rise = reference == null ? null : hr - reference;
    // Freeze the pre-rise baseline while a bout is in progress; letting the
    // rise enter its own reference would erase a sustained signal.
    final elevated = reference != null && rise! >= 8 &&
        rise / reference >= .06 && rise / reference <= .21;
    if (elevated) {
      first ??= s;
      baseline ??= reference;
      last = s;
      count++;
    } else {
      finish();
      history.add(s);
    }
  }
  finish();
  candidates.sort((a, b) {
    final prior = (a['meal_time_distance_min'] as int)
        .compareTo(b['meal_time_distance_min'] as int);
    return prior != 0 ? prior : (a['start_ts'] as int).compareTo(b['start_ts'] as int);
  });
  final counts = <String, int>{};
  final selected = <Map<String, dynamic>>[];
  for (final row in candidates) {
    final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
        (row['start_ts'] as int) * 1000));
    if ((counts[day] ?? 0) >= maxPerDay) continue;
    counts[day] = (counts[day] ?? 0) + 1;
    selected.add(row);
  }
  return selected..sort((a, b) =>
      (a['start_ts'] as int).compareTo(b['start_ts'] as int));
}
