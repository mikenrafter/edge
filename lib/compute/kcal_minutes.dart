// The intraday calorie series: `Calories.minuteEnergy` over one
// day, in the shape the `kcal_minutes|<day>` artifact stores.
//
// It is `dailyEnergy`'s computation, one record per minute, fed EXACTLY the way
// `DerivationEngine.wakeDayEnergy` is fed from `_buildWakeDayFeatures`, so the
// minutes fold back to the day's stored ACTIVE figure:
//
//   * the series is the WAKE series: the per-minute mean of the seconds with
//     hr > 0, keyed by `tsSec ~/ 60`, minutes inside the sleep window left out
//     (sleep is not exercise: an older sleeper's night would bill as active);
//   * hrmax is `estimatedMaxHr(age, family)`, cadence is
//     `cadenceSpmForMinutes(keys, stepSpans)`;
//   * a minute that is not in the wake series (a gap in the data, or the sleep
//     window) goes in with hr 0 AND its cadence masked to null. `dailyEnergy`
//     never sees those minutes, and `minuteEnergy` would otherwise bill a gap
//     minute from cadence alone. It abstains instead, and the minute keeps its
//     place on the clock. Gaps are never interpolated.
//
// Null (never a made-up series) wherever `wakeDayEnergy` is null: no calorie
// anchors, no height, no resting HR, no wake HR at all. Those gates are
// repeated here rather than called, because the engine imports this file.
// `p3_kcal_builder_test.dart` pins the two together.
//
// Pure and isolate-safe: no I/O, no clock, plain maps in and out.
import 'package:openstrap_analytics/onehz.dart' as ana;

import 'hr_max.dart';
import 'profile.dart';
import 'step_cadence.dart';
import 'substrate.dart';

/// The payload is `{v, basal_kcal_per_min, covered_minutes, minutes: [{t, total,
/// active, basal, source}]}`. `t` is epoch SECONDS of the minute; an abstained
/// minute has all four other fields null. `basal_kcal_per_min` is BMR / 1440, so
/// `* 1440` is the day's basal. The sum of `active` is the HR-trace active
/// figure: it does not include the workout-gap credit, which has no minute.
Map<String, dynamic>? buildKcalMinutes({
  required Substrate daySub,
  required Profile profile,
  required double? restingHr,
  required int sleepOnsetSec,
  required int sleepOffsetSec,
  List<List<int>> stepSpans = const [],
}) {
  if (!profile.hasCalorieAnchors || restingHr == null) return null;
  final heightCm = profile.heightCm;
  final hrmax = estimatedMaxHr(profile.ageYears, daySub.deviceFamily);
  if (heightCm == null || hrmax == null) return null;

  final buckets = <int, List<double>>{};
  for (var i = 0; i < daySub.hr.length && i < daySub.tsSec.length; i++) {
    if (daySub.hr[i] <= 0) continue;
    final t = daySub.tsSec[i];
    if (sleepOffsetSec > sleepOnsetSec &&
        t >= sleepOnsetSec &&
        t < sleepOffsetSec) {
      continue;
    }
    (buckets[t ~/ 60] ??= []).add(daySub.hr[i].toDouble());
  }
  if (buckets.isEmpty) return null;
  final keys = buckets.keys.toList()..sort();
  final wakeCadence =
      stepSpans.isEmpty ? null : cadenceSpmForMinutes(keys, stepSpans);
  final byKey = <int, int>{for (var i = 0; i < keys.length; i++) keys[i]: i};

  final first = keys.first, last = keys.last;
  final epochMinutes = [for (var k = first; k <= last; k++) k];
  final hr = <double>[];
  final cadence = wakeCadence == null ? null : <double?>[];
  for (final k in epochMinutes) {
    final at = byKey[k];
    if (at == null) {
      hr.add(0.0);
      cadence?.add(null);
      continue;
    }
    var sum = 0.0;
    for (final x in buckets[k]!) {
      sum += x;
    }
    hr.add(sum / buckets[k]!.length);
    cadence?.add(wakeCadence![at]);
  }

  final series = ana.Calories.minuteEnergy(
    hr,
    profile: ana.WorkoutUserProfile(
      weightKg: profile.weightKg!,
      heightCm: heightCm,
      age: profile.ageYears!.toDouble(),
      sex: workoutSex(profile.sex),
    ),
    hrmax: hrmax,
    restingHr: restingHr,
    cadenceSpmPerMin: cadence,
    epochMinutes: epochMinutes,
  );
  if (series == null) return null;
  return {
    'v': 1,
    'basal_kcal_per_min': series.basalKcalPerMin,
    'covered_minutes': series.coveredMinutes,
    'minutes': [
      for (final m in series.minutes)
        {
          't': m.minute * 60,
          'total': m.total,
          'active': m.active,
          'basal': m.basal,
          'source': m.source?.name,
        },
    ],
  };
}

/// What a stored `kcal_minutes|<day>` row was computed from, as the body of its
/// signature (the caller prefixes `kAlgoVersion`): the day's decoded-raw
/// fingerprint and the calorie anchors. The derive that stores the row and the
/// repository that asks whether it is fresh both go through here, so a day
/// derived from here on reads fresh to the warmer.
String kcalSignatureBody(String decodedFingerprint, Profile profile) =>
    '$decodedFingerprint|'
    '${profile.toMap().entries.map((e) => '${e.key}=${e.value}').join(',')}';
