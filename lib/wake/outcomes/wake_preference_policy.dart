// wake_preference_policy.dart — SHADOW policy: from the recorded outcomes, say
// which early-wake setting it WOULD choose. Nothing reads this to change an
// alarm; it is displayed (WakeOutcomesScreen) and nothing else.
//
// Honesty rules: usable, RATED mornings only; unrated mornings are excluded
// from the comparison, never imputed; below the evidence floor the answer is
// null with reason 'insufficient'. The counts are a floor for showing anything,
// not a statistical sufficiency claim. Grogginess is user-entered; lower is
// better. The user's current window is a hard ceiling.

import 'wake_outcome.dart';

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

  /// 'insufficient' | 'lowerGrogginess' | 'tie'.
  final String reason;

  /// Usable mornings (rated or not) per policy key.
  final Map<String, int> usableByPolicy;
}

/// Policy key = `'STAGE:W'`: STAGE is stageAtFire ('rem' | 'awake') or
/// 'none'; W is the window of the bucket of round(minutesBeforeT): 0–15 -> 15,
/// 15–30 -> 30, 30–60 -> 60, 60+ -> 120 (the bucket's upper bound; 120 is
/// kWakeWindowMaxMinutes). Buckets are half-open: round(m) < 15 is the first.
///
/// Only keys with W <= [currentWindowMinutes] are candidates; the choice is
/// never larger than the ceiling. Evidence floor: at least [kPolicyMinTotal]
/// rated usable mornings in total AND at least [kPolicyMinPerKey] rated usable
/// mornings in each of at least two candidate keys; else wouldChoose null and
/// reason 'insufficient'. Keys under the per-key floor are not compared.
/// Compared keys are ranked by median grogginess (even count: mean of the
/// middle two), lower better. A unique lowest median chooses `'window:W'` with
/// reason 'lowerGrogginess'. A tie for the lowest keeps the current setting:
/// wouldChoose 'window:$currentWindowMinutes', reason 'tie'.
/// [usableByPolicy] counts usable outcomes (rated or not) for every key,
/// including keys above the ceiling.
ShadowPolicyResult evaluate(
  List<WakeOutcome> outcomes, {
  required int currentWindowMinutes,
}) {
  String? policyKey(WakeOutcome outcome) {
    final minutes = outcome.minutesBeforeT;
    if (minutes == null) return null;
    final rounded = minutes.round();
    final window = rounded < 15
        ? 15
        : rounded < 30
            ? 30
            : rounded < 60
                ? 60
                : 120;
    return '${outcome.stageAtFire ?? 'none'}:$window';
  }

  final usableByPolicy = <String, int>{};
  final ratedByPolicy = <String, List<int>>{};
  var totalRated = 0;
  for (final outcome in outcomes) {
    if (!outcome.usable) continue;
    final key = policyKey(outcome);
    if (key == null) continue;
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

  double median(List<int> values) {
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle].toDouble()
        : (sorted[middle - 1] + sorted[middle]) / 2.0;
  }

  final medians = <String, double>{
    for (final entry in candidates.entries) entry.key: median(entry.value),
  };
  final lowest = medians.values.reduce((a, b) => a < b ? a : b);
  final best = [
    for (final entry in medians.entries) if (entry.value == lowest) entry.key,
  ];
  if (best.length != 1) {
    return ShadowPolicyResult(
      wouldChoose: 'window:$currentWindowMinutes',
      reason: 'tie',
      usableByPolicy: usableByPolicy,
    );
  }
  return ShadowPolicyResult(
    wouldChoose: 'window:${best.single.split(':').last}',
    reason: 'lowerGrogginess',
    usableByPolicy: usableByPolicy,
  );
}
