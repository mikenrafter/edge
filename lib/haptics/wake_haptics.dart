// 8AF.6 D: wake buzzes on the band's measured vocabulary.
//
// Gradual wake and Natural / Smart wake play fixed plans of phrases from the
// MG's vocabulary instead of per-tap buzzes or RUN_ALARM. The plans live here
// in code: they are not stored patterns and the wearer cannot edit them. A band
// with no haptic profile (a 4.0) keeps today's behaviour, and RUN_ALARM is
// still what runs when the plan cannot be delivered.
//
// Like GestureCues this only plays. Callers reach it from inside an
// AlertDispatcher delivery.

import '../notify/buzz_sequence.dart';
import '../wake/wake_settings.dart';
import 'haptic_profile.dart';
import 'haptics_service.dart';

/// The phrase a gradual wake step plays. Steady is the same fast single at
/// every step; ramp climbs one rung per step and stays on the last.
String gradualPhraseId(GradualPattern pattern, int stepIndex) {
  if (pattern == GradualPattern.steady) return 'buzz14';
  const ramp = ['click1', 'buzz14', 'buzz47', 'buzz47x2', 'buzz47x3'];
  final i = stepIndex < 0 ? 0 : stepIndex;
  return ramp[i < ramp.length ? i : ramp.length - 1];
}

/// Natural / Smart wake: three of the strongest phrase, back to back.
const List<String> kNaturalWakePhraseIds = ['buzz47x3', 'buzz47x3', 'buzz47x3'];

class WakeHaptics {
  WakeHaptics(this.haptics);

  final HapticsService haptics;

  // [ids] as one plan on [p], each command written the instant the one before
  // ended (a 0 ms gap). Null when the profile lacks a phrase.
  BuzzSequence? _plan(HapticDeviceProfile p, List<String> ids) {
    final steps = <BakedStep>[];
    for (final id in ids) {
      final ph = p.phrases.where((x) => x.id == id).firstOrNull;
      if (ph == null) return null;
      steps.add(BakedStep(effects: ph.effects, loop: ph.loop, delayMs: 0));
    }
    return BuzzSequence(
      const [0],
      durationsMs: const [500],
      profileId: p.id,
      profileVersion: p.version,
      bakedSteps: steps,
    );
  }

  /// One gradual step. On a band with a profile, the step's phrase; on a band
  /// without, [perTap] (the step's own rhythm) exactly as before.
  Future<BuzzDelivery> gradualStep(
    GradualPattern pattern,
    int stepIndex, {
    required BuzzSequence perTap,
  }) {
    final p = haptics.profile;
    final plan =
        p == null ? null : _plan(p, [gradualPhraseId(pattern, stepIndex)]);
    return haptics.deliver(plan ?? perTap);
  }

  /// Natural / Smart wake. The plan when the band has a profile and takes it;
  /// [runAlarm] (the band-native RUN_ALARM) on a band without a profile, or
  /// when nothing of the plan could be written. A plan that started but did not
  /// finish is not followed by RUN_ALARM: the wearer already felt it, and a
  /// second wake buzz on top would replay it.
  Future<BuzzDelivery> natural({
    required Future<BuzzDelivery> Function() runAlarm,
  }) async {
    final p = haptics.profile;
    final plan = p == null ? null : _plan(p, kNaturalWakePhraseIds);
    if (plan == null) return runAlarm();
    final r = await haptics.deliver(plan);
    return r == BuzzDelivery.rejected ? runAlarm() : r;
  }
}
