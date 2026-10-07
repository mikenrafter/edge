// wake_preference_policy.dart — SHADOW policy: from the recorded outcomes, say
// which early-wake setting it WOULD choose. Nothing reads this to change an
// alarm; it is displayed (WakeOutcomesScreen) and nothing else.
//
// Honesty rules: usable, RATED mornings only; unrated mornings are excluded
// from the comparison, never imputed; below the evidence floor the answer is
// null with reason 'insufficient'. The counts are only a floor for showing
// anything; a choice also has to clear an uncertainty gate (a median gap AND a
// permutation test), else the answer is null with reason 'uncertain'.
// Grogginess is user-entered; lower is better. The user's current window is a
// hard ceiling.
//
// A "policy" is the Natural window that was CONFIGURED for the night, never
// when the fire happened to land: one configuration fires early or late for
// reasons of its own, and a firing-time bucket is a setting nobody chose.

import 'wake_outcome.dart';

/// The best configuration must beat each other one by this many rating points
/// (medians) ...
const double kPolicyMinMedianGap = 1.0;

/// ... and the gap must have a permutation p-value below this.
const double kPolicyMaxP = 0.05;

/// Permutations per comparison, and the fixed seed: the same ratings always
/// give the same answer.
const int kPolicyPermutations = 5000;
const int _kPolicySeed = 20260607;

/// Rated, usable mornings needed in total before any comparison.
const int kPolicyMinTotal = 20;

/// Rated, usable mornings needed in each compared key.
const int kPolicyMinPerKey = 8;

class ShadowPolicyResult {
  const ShadowPolicyResult({
    this.wouldChoose,
    required this.reason,
    required this.usableByPolicy,
  });

  /// e.g. 'window:30' (minutes). Null unless the evidence floor is met.
  final String? wouldChoose;

  /// 'insufficient' | 'uncertain' | 'lowerGrogginess' | 'tie'.
  final String reason;

  /// Usable mornings (rated or not) per configured window ('window:W').
  final Map<String, int> usableByPolicy;
}

/// Policy key = `'window:W'`, W = [WakeOutcome.configuredWindowMinutes]. An
/// outcome with no recorded window (stored before it was kept, or Natural off)
/// has no known configuration and joins no group. Firing time and stage never
/// split or pool a configuration.
///
/// Only keys with W <= [currentWindowMinutes] are candidates; the choice is
/// never larger than the ceiling. Evidence floor: at least [kPolicyMinTotal]
/// rated usable mornings in total AND at least [kPolicyMinPerKey] rated usable
/// mornings in each of at least two candidate keys; else wouldChoose null and
/// reason 'insufficient'. Compared keys are ranked by median grogginess (even
/// count: mean of the middle two), lower better.
///
/// A tie for the lowest median keeps the current setting (reason 'tie') when
/// that window is itself a compared key, else names nothing: wouldChoose is
/// only ever a configuration used on at least [kPolicyMinPerKey] rated mornings.
/// A unique lowest median must also clear the uncertainty gate against EVERY
/// other compared key: medians at least [kPolicyMinMedianGap] apart AND a
/// two-sided permutation test on the rating ranks (Mann-Whitney statistic,
/// [kPolicyPermutations] shuffles, fixed seed) with p < [kPolicyMaxP]. Failing
/// it gives wouldChoose null, reason 'uncertain'. Passing gives
/// `'window:W'`, reason 'lowerGrogginess'.
/// [usableByPolicy] counts usable outcomes (rated or not) for every key,
/// including keys above the ceiling.
ShadowPolicyResult evaluate(
  List<WakeOutcome> outcomes, {
  required int currentWindowMinutes,
}) {
  final usableByPolicy = <String, int>{};
  final ratedByPolicy = <String, List<int>>{};
  var totalRated = 0;
  for (final outcome in outcomes) {
    if (!outcome.usable) continue;
    final window = outcome.configuredWindowMinutes;
    if (window == null || window <= 0) continue;
    final key = 'window:$window';
    usableByPolicy[key] = (usableByPolicy[key] ?? 0) + 1;
    final rating = outcome.grogginess;
    if (rating == null) continue;
    totalRated++;
    (ratedByPolicy[key] ??= []).add(rating);
  }

  final candidates = <String, List<int>>{};
  for (final entry in ratedByPolicy.entries) {
    final window = int.parse(entry.key.split(':').last);
    if (window <= currentWindowMinutes && entry.value.length >= kPolicyMinPerKey) {
      candidates[entry.key] = entry.value;
    }
  }
  if (totalRated < kPolicyMinTotal || candidates.length < 2) {
    return ShadowPolicyResult(
      reason: 'insufficient',
      usableByPolicy: usableByPolicy,
    );
  }

  final medians = <String, double>{
    for (final entry in candidates.entries) entry.key: _median(entry.value),
  };
  final lowest = medians.values.reduce((a, b) => a < b ? a : b);
  final best = [
    for (final entry in medians.entries) if (entry.value == lowest) entry.key,
  ];
  if (best.length != 1) {
    final current = 'window:$currentWindowMinutes';
    return ShadowPolicyResult(
      wouldChoose: candidates.containsKey(current) ? current : null,
      reason: 'tie',
      usableByPolicy: usableByPolicy,
    );
  }
  final winner = best.single;
  for (final entry in candidates.entries) {
    if (entry.key == winner) continue;
    final gap = medians[entry.key]! - lowest;
    if (gap < kPolicyMinMedianGap ||
        _permutationP(candidates[winner]!, entry.value) >= kPolicyMaxP) {
      return ShadowPolicyResult(
        reason: 'uncertain',
        usableByPolicy: usableByPolicy,
      );
    }
  }
  return ShadowPolicyResult(
    wouldChoose: winner,
    reason: 'lowerGrogginess',
    usableByPolicy: usableByPolicy,
  );
}

double _median(List<int> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle].toDouble()
      : (sorted[middle - 1] + sorted[middle]) / 2.0;
}

/// Two-sided permutation p-value that groups [a] and [b] differ in rating
/// level: the statistic is group a's rank sum (mid-ranks over the pooled
/// ratings, so ties are handled), and the pooled ranks are shuffled
/// [kPolicyPermutations] times with a fixed-seed generator. Input order does not
/// matter (groups are sorted first), and the result is the same on every run.
/// p = (hits + 1) / (shuffles + 1), never 0.
double _permutationP(List<int> a, List<int> b) {
  final pooled = [...a, ...b]..sort();
  // Mid-rank of each pooled position.
  final ranks = List<double>.filled(pooled.length, 0);
  for (var i = 0; i < pooled.length;) {
    var j = i;
    while (j + 1 < pooled.length && pooled[j + 1] == pooled[i]) {
      j++;
    }
    for (var k = i; k <= j; k++) {
      ranks[k] = (i + j) / 2 + 1;
    }
    i = j + 1;
  }
  double sumOfFirst(List<double> r) {
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      sum += r[i];
    }
    return sum;
  }

  final expected = a.length * (pooled.length + 1) / 2;
  // Group a's own rank sum: each of its ratings takes that rating's mid-rank.
  var rankSumA = 0.0;
  for (final value in a) {
    rankSumA += ranks[pooled.indexOf(value)];
  }
  final observed = (rankSumA - expected).abs();
  var state = _kPolicySeed;
  int next(int bound) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return (state >> 8) % bound;
  }

  final shuffled = [...ranks];
  var hits = 0;
  for (var n = 0; n < kPolicyPermutations; n++) {
    for (var i = shuffled.length - 1; i > 0; i--) {
      final j = next(i + 1);
      final tmp = shuffled[i];
      shuffled[i] = shuffled[j];
      shuffled[j] = tmp;
    }
    // 1e-9: rank sums are sums of halves, compared exactly enough.
    if ((sumOfFirst(shuffled) - expected).abs() >= observed - 1e-9) hits++;
  }
  return (hits + 1) / (kPolicyPermutations + 1);
}
