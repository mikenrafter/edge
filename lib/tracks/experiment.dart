// Randomized N-of-1 experiments. Pure functions: the store owns persistence.
// Assignment is an invitation, never evidence that the wearer followed it.
import 'dart:math' as math;

import '../data/track_model.dart';

const experimentWeeks = [2, 3, 4];

/// Why an experiment was refused; match it exhaustively.
enum ExperimentRefusal { prescribed, washout }

class ExperimentRefused implements Exception {
  const ExperimentRefused(this.reason);
  final ExperimentRefusal reason;
  @override
  String toString() => 'ExperimentRefused(${reason.name})';
}

/// A track that may be randomized. There is no public constructor: a
/// prescribed track (a `med:` track, or one the wearer marked prescribed)
/// cannot be wrapped, so no caller can ask the wearer to skip a prescribed
/// treatment.
// CLAIM(never-ask-skip-prescribed): the app never tells the wearer to skip a
// prescribed track. `from` returns null for it; the start refuses; the
// reminder query and the experiment screen read the live definition, so a
// stored, restored or later-prescribed experiment stays silent
// [owner decision 2026-10-27; tracks_experiments_t3_test.dart].
class ExperimentableTrack {
  const ExperimentableTrack._(this.definition);
  final TrackDefinition definition;
  static ExperimentableTrack? from(TrackDefinition definition) =>
      definition.isPrescribed ? null : ExperimentableTrack._(definition);
}

/// Days a track needs to clear: the larger of five half-lives (the "several
/// half-lives" of the learning policy, learning.dart `minimumFor`) and its
/// withdrawal period, over the track and every sub-activity.
// CLAIM(washout-vs-block): blocks are two adjacent days, so a skip day is only
// about one day after a do day; a longer washout leaves it exposed and biases
// the effect toward zero [review T6; experiment_effect_test.dart].
double experimentWashoutDays(TrackDefinition track) {
  var days = 0.0;
  for (final kinetics in [track.kinetics, ...track.subActivities.map((s) => s.kinetics)]) {
    final halfLife = kinetics.fields['half_life_hours']?.value ?? 0;
    final withdrawal = kinetics.fields['withdrawal_days']?.value ?? 0;
    days = math.max(days, math.max(halfLife * 5 / 24, withdrawal));
  }
  return days;
}

/// True when [experimentWashoutDays] is longer than one day (the gap between
/// a do day and the skip day beside it).
bool experimentWashoutExceedsBlock(TrackDefinition track) =>
    experimentWashoutDays(track) > 1 + 1e-9;

/// Systems with a stored nightly outcome the report can compare.
const experimentSystems = {
  'sleep',
  'hr',
  'hrv',
  'stress',
  'skin_temp',
  'workout_intensity',
  'recovery',
  'respiration',
};

/// Balanced blocks of two consecutive calendar days, one "do" and one "skip",
/// in random order (a single odd day is a coin flip). The generator is local
/// so a fixed seed reproduces the allocation on every platform and release.
List<bool> assignExperimentDays(int days, int seed) {
  var state = seed & 0xFFFFFFFF;
  bool coin() {
    state = (state + 0x9E3779B9) & 0xFFFFFFFF;
    var z = state;
    z = ((z ^ (z >> 16)) * 0x85EBCA6B) & 0xFFFFFFFF;
    z = ((z ^ (z >> 13)) * 0xC2B2AE35) & 0xFFFFFFFF;
    z ^= z >> 16;
    return (z >> 15) & 1 == 1;
  }

  final out = <bool>[];
  while (out.length + 1 < days) {
    final first = coin();
    out..add(first)..add(!first);
  }
  if (out.length < days) out.add(coin());
  return out;
}

/// Share of assigned days the wearer must have confirmed for a report.
const minExperimentAdherence = .7;
const minArmDays = 3;

/// Difference of arm means (do minus skip) with a 95% Welch interval, or null
/// when an arm is too small or both arms have no spread.
// ↳ CLAIM(t-quantile)
Map<String, Object?>? experimentEffect(List<double> doDays, List<double> skip) {
  if (doDays.length < minArmDays || skip.length < minArmDays) return null;
  double mean(List<double> v) => v.reduce((a, b) => a + b) / v.length;
  double variance(List<double> v, double m) =>
      v.fold<double>(0, (s, x) => s + (x - m) * (x - m)) / (v.length - 1);
  final mDo = mean(doDays), mSkip = mean(skip);
  final vDo = variance(doDays, mDo) / doDays.length;
  final vSkip = variance(skip, mSkip) / skip.length;
  final effect = mDo - mSkip, se = math.sqrt(vDo + vSkip);
  // No spread in either arm (whole-bpm values can tie): an interval of zero
  // width would claim certainty from a few nights.
  if (se == 0) return null;
  final df =
      (vDo + vSkip) *
      (vDo + vSkip) /
      (vDo * vDo / (doDays.length - 1) + vSkip * vSkip / (skip.length - 1));
  final half = studentT975(df) * se;
  return {
    'effect': effect,
    'lower': effect - half,
    'upper': effect + half,
    'n_do': doDays.length,
    'n_dont': skip.length,
  };
}

/// Two-sided 95% Student-t quantile, qt(.975, df) in R.
// CLAIM(t-quantile): exact table values for integer df 1-30 (rounded to 4
// places); fractional df interpolates linearly in 1/df between rows, which
// is at most ~1.6% wide of the true quantile, never narrow; beyond 30 the
// quantile runs linearly in 1/df from the df=30 row to z = 1.959964 at
// infinity [published t table; experiment_effect_test.dart].
double studentT975(double df) {
  const z = 1.959964;
  const table = [
    12.7062, 4.3027, 3.1824, 2.7764, 2.5706, 2.4469, 2.3646, 2.3060, 2.2622,
    2.2281, 2.2010, 2.1788, 2.1604, 2.1448, 2.1314, 2.1199, 2.1098, 2.1009,
    2.0930, 2.0860, 2.0796, 2.0739, 2.0687, 2.0639, 2.0595, 2.0555, 2.0518,
    2.0484, 2.0452, 2.0423,
  ];
  if (df <= 1) return table.first;
  if (df >= 30) return z + (table.last - z) * 30 / df;
  final low = df.floor();
  if (low == df) return table[low - 1];
  final weight = (1 / df - 1 / (low + 1)) / (1 / low - 1 / (low + 1));
  return table[low] + (table[low - 1] - table[low]) * weight;
}
