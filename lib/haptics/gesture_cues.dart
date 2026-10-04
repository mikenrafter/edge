// 8AF.6 C: the gesture response vocabulary. A response to a gesture is the
// start cue (gesture.start) and then, for a count above one, a follow-up cue
// (gesture.followUp) per extra pulse, chained at the vocabulary's minimum gap
// (HapticDeviceProfile.minVibrationGapMs), all as ONE job of the band queue.
// Two jobs in a row (the start cue the tap sends, then the count) are spaced by
// the same gap in the queue itself. The final "action
// done" ack is the confirm cue (gesture.confirm). The cues are the built-in
// patterns, so a customised one is what plays. A band with no haptic profile
// (a 4.0) keeps today's plain pulses.
//
// This class only plays; it never decides whether a gesture may buzz. Callers
// reach it from inside an AlertDispatcher delivery.

import '../notify/buzz_sequence.dart';
import 'builtin_patterns.dart';
import 'haptic_player.dart';
import 'haptic_profile.dart';
import 'haptics_service.dart';

class GestureCues {
  GestureCues({required this.haptics, this.patternFor});

  final HapticsService haptics;

  /// The stored (possibly customised) built-in for a system key, or null for
  /// the seeded default.
  final BuzzSequence? Function(String systemKey)? patternFor;

  // The stored pattern for [key], else the seeded default (MG profile).
  BuzzSequence? _pattern(String key) {
    BuzzSequence? stored;
    try {
      stored = patternFor?.call(key);
    } catch (_) {
      stored = null;
    }
    return stored ?? builtInDefault(key)?.sequence;
  }

  // [key]'s commands on [p]; the seeded default when the stored one does not
  // compile on this band.
  List<BakedStep>? _steps(String key, HapticDeviceProfile p) {
    final stored = _pattern(key);
    final own = stored == null ? null : bandStepsFor(stored, p, maxRuntime: null);
    if (own != null) return own;
    final fallback = builtInDefault(key)?.sequence;
    return fallback == null ? null : bandStepsFor(fallback, p, maxRuntime: null);
  }

  /// The start cue, then [pulses] - 1 follow-ups, in one queue job.
  Future<BuzzDelivery> response(int pulses) {
    final count = pulses < 1 ? 1 : pulses;
    final p = haptics.profile;
    if (p == null) return _plainPulses(count);
    final start = _steps(kGestureStartKey, p);
    final follow = _steps(kGestureFollowUpKey, p);
    if (start == null || follow == null) return _plainPulses(count);
    final wait = p.minVibrationGapMs;
    final cap = haptics.maxRuntime;
    var plan = [...start];
    for (var i = 1; i < count; i++) {
      final next = [
        ...plan,
        for (var j = 0; j < follow.length; j++)
          BakedStep(
            effects: follow[j].effects,
            loop: follow[j].loop,
            delayMs: j == 0 ? wait : follow[j].delayMs,
          ),
      ];
      if (next.length > BuzzSequence.maxBakedSteps) break;
      final felt = bakedRuntimeMsFor(_sequence(p, next), p);
      if (cap != null && felt != null && felt > cap.inMilliseconds) break;
      plan = next;
    }
    return haptics.deliver(_sequence(p, plan));
  }

  /// The confirm cue: the action is done.
  Future<BuzzDelivery> confirm() {
    final p = haptics.profile;
    final seq = p == null ? null : _pattern(kGestureConfirmKey);
    if (p == null || seq == null) return _plainPulses(1);
    return haptics.deliver(seq);
  }

  // A one-press sequence carrying [steps] as its stored plan for [p].
  BuzzSequence _sequence(HapticDeviceProfile p, List<BakedStep> steps) =>
      BuzzSequence(
        const [0],
        durationsMs: const [500],
        profileId: p.id,
        profileVersion: p.version,
        bakedSteps: steps,
      );

  // Today's path for a band with no profile: [count] plain pulses 300 ms
  // apart, one job in the band queue.
  Future<BuzzDelivery> _plainPulses(int count) {
    final seq = BuzzSequence([for (var i = 0; i < count; i++) i * 300]);
    return haptics.runJob(
      count,
      (job) => deliverBuzzSequence(
        seq,
        buzz: () => job.write(() => haptics.port.buzzBand()),
        isConnected: () => !job.cancelled && haptics.port.isConnected,
      ),
      timeout: seq.transportTimeout,
    );
  }
}
