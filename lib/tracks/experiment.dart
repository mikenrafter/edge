// Randomized N-of-1 experiments. Pure functions: the store owns persistence.
// Assignment is an invitation, never evidence that the wearer followed it.
import 'dart:math' as math;

import '../data/track_model.dart';

const experimentWeeks = [2, 3, 4];

/// Why an experiment was refused; match it exhaustively.
enum ExperimentRefusal { medication, washout }

class ExperimentRefused implements Exception {
  const ExperimentRefused(this.reason);
  final ExperimentRefusal reason;
  @override
  String toString() => 'ExperimentRefused(${reason.name})';
}

/// A track that may be randomized. There is no public constructor: a
/// medication cannot be wrapped, so no caller can ask the app to tell a
/// wearer to skip a prescribed drug.
// CLAIM(no-med-experiment): every medication is a `med:` track and `from`
// returns null for all of them [review T1; tracks_experiments_t3_test.dart].
class ExperimentableTrack {
  const ExperimentableTrack._(this.definition);
  final TrackDefinition definition;
  static ExperimentableTrack? from(TrackDefinition definition) =>
      definition.id.startsWith('med:') ? null : ExperimentableTrack._(definition);
}

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
/// when an arm is too small to estimate a spread.
Map<String, Object?>? experimentEffect(List<double> doDays, List<double> skip) {
  if (doDays.length < minArmDays || skip.length < minArmDays) return null;
  double mean(List<double> v) => v.reduce((a, b) => a + b) / v.length;
  double variance(List<double> v, double m) =>
      v.fold<double>(0, (s, x) => s + (x - m) * (x - m)) / (v.length - 1);
  final mDo = mean(doDays), mSkip = mean(skip);
  final vDo = variance(doDays, mDo) / doDays.length;
  final vSkip = variance(skip, mSkip) / skip.length;
  final effect = mDo - mSkip, se = math.sqrt(vDo + vSkip);
  final df = se == 0
      ? doDays.length + skip.length - 2.0
      : (vDo + vSkip) *
            (vDo + vSkip) /
            (vDo * vDo / (doDays.length - 1) + vSkip * vSkip / (skip.length - 1));
  final half = _t975(df) * se;
  return {
    'effect': effect,
    'lower': effect - half,
    'upper': effect + half,
    'n_do': doDays.length,
    'n_dont': skip.length,
  };
}

/// Two-sided 95% Student-t quantile (Cornish-Fisher expansion about z).
double _t975(double df) {
  const z = 1.959964;
  final z3 = z * z * z, z5 = z3 * z * z;
  return z +
      (z3 + z) / (4 * df) +
      (5 * z5 + 16 * z3 + 3 * z) / (96 * df * df);
}
