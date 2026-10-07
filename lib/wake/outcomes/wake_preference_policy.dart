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

/// Policy key = '<stage>:<W>': stage is stageAtFire ('rem' | 'awake') or
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
/// middle two), lower better. A unique lowest median chooses 'window:<W>' with
/// reason 'lowerGrogginess'. A tie for the lowest keeps the current setting:
/// wouldChoose 'window:$currentWindowMinutes', reason 'tie'.
/// [usableByPolicy] counts usable outcomes (rated or not) for every key,
/// including keys above the ceiling.
ShadowPolicyResult evaluate(
  List<WakeOutcome> outcomes, {
  required int currentWindowMinutes,
}) =>
    throw UnimplementedError();
