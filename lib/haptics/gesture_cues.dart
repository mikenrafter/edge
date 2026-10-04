// 8AF.6 C: the gesture cue vocabulary. A gesture is answered by an ADDITIVE
// sequence of cues, each its own job of the band queue:
//
//   start()      the start cue (gesture.start), once, when the gesture begins
//   followUp()   ONE follow-up cue (gesture.followUp) per count increment
//                (the touch that makes it 3, then 4, then 5), queued the moment
//                the increment is seen; never a recount of the pulses so far
//   confirm()    the confirm cue (gesture.confirm), when the gesture ends
//   failed()     the failure cue (gesture.failed), when it was abandoned
//
// The queue spaces two jobs by the vocabulary's minimum gap
// (HapticDeviceProfile.minVibrationGapMs, 8AI), so no cue is dropped, merged or
// reordered. Each cue plays the pattern the wearer assigned to it, else the
// built-in; a customised one is what plays. A band with no haptic profile (a
// 4.0) plays one plain pulse per cue.
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

  /// The start cue: the gesture began.
  Future<BuzzDelivery> start() => _cue(kGestureStartKey);

  /// One follow-up cue: the count went up by one.
  Future<BuzzDelivery> followUp() => _cue(kGestureFollowUpKey);

  /// The confirm cue: the gesture ended.
  Future<BuzzDelivery> confirm() => _cue(kGestureConfirmKey);

  /// The failure cue: the gesture could not be activated (8AK).
  Future<BuzzDelivery> failed() => _cue(kGestureFailedKey);

  /// A breathing cue slot (Oct 4: `breath.inhale|exhale|hold|done`), played the
  /// same way: the wearer's pattern, else the built-in, as one queue job. A
  /// band with no vocabulary (a 4.0) plays a stored pattern as its taps, one
  /// buzz each, since the wearer who put one on a breathing slot there meant
  /// that rhythm; with none stored it plays one plain pulse. (The caller keeps
  /// the 4.0's own per-phase buzzes for a slot nobody assigned.)
  Future<BuzzDelivery> slot(String key) {
    if (haptics.profile != null) return _cue(key);
    final s = _pattern(key);
    return s == null ? _plainPulses(1) : haptics.deliver(s);
  }

  // [key]'s pattern as one queue job, compiled for the band like every other
  // stored pattern (the seeded default when the stored one does not compile).
  Future<BuzzDelivery> _cue(String key) {
    final p = haptics.profile;
    if (p == null) return _plainPulses(1);
    final steps = _steps(key, p);
    if (steps == null) return _plainPulses(1);
    return haptics.deliver(_sequence(p, steps));
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
