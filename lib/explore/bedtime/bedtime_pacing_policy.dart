// bedtime_pacing_policy.dart — the pure rules of "Bedtime breathing cues".
//
// Bedtime breathing cues, with an optional stop when the band estimates sleep.
//
// Evidence: Tsai et al. 2015, Psychophysiology, doi:10.1111/psyp.12333 (20
// minutes of paced breathing before sleep, 14 self-reported insomniacs and 14
// good sleepers). It supports TESTING bedtime slow breathing. It does not
// validate wrist haptics that slow with heart rate, and it does not validate
// stopping on this causal stager.
//
// What this is NOT. No HR-driven slowing: the pace is a comfortable fixed rate
// or a taper the USER chose, a pure function of elapsed time. The duration is
// hard-capped (default 15, max 20 minutes). The optional sleep stop needs a
// SUSTAINED estimate from the one existing causal stager (`NaturalStageObserver`
// in lib/wake/natural_wake.dart); missing or stale stage data is "sleep
// estimate unavailable", which never stops the session and never claims awake.
// Nothing here ever produces a "fell asleep in X minutes" figure.
//
// Pure: no clock, no I/O, no state. PHASE 1 STUBS: bodies throw.

import '../../stress/breath_phases.dart';

/// Default session length.
const Duration kBedtimeDefaultDuration = Duration(minutes: 15);

/// Shortest and longest session a plan may ask for.
const Duration kBedtimeMinDuration = Duration(minutes: 1);
const Duration kBedtimeMaxDuration = Duration(minutes: 20);

/// The comfortable default pace and the allowed range, breaths per minute.
const double kBedtimeDefaultBpm = 6.0;
const double kBedtimeMinBpm = 4.0;
const double kBedtimeMaxBpm = 8.0;

/// A stage sample is fresh while now minus when it was observed is at most this.
const Duration kBedtimeFreshness = Duration(seconds: 90);

/// Consecutive non-wake epoch observations the sleep stop needs.
const int kBedtimeSustainedEpochs = 4;

/// Consecutive cues that did not reach the band before the session ends.
const int kBedtimeMaxMissedCues = 3;

/// The stager is asked at most this often.
const Duration kBedtimeObserveInterval = Duration(seconds: 30);

/// What the user asked for. Rates are breaths per minute, [4, 8]; the end rate
/// may not exceed the start rate (a taper never speeds up). [endBpm] defaults
/// to [startBpm], which is the fixed pace.
class BedtimePlan {
  BedtimePlan({
    this.startBpm = kBedtimeDefaultBpm,
    double? endBpm,
    this.duration = kBedtimeDefaultDuration,
    this.stopOnSleep = false,
  }) : endBpm = endBpm ?? startBpm;
  // STUB: validation (ArgumentError) is implemented in phase 2.

  final double startBpm;

  /// Equal to [startBpm] for a fixed pace.
  final double endBpm;

  /// 1..20 minutes, else ArgumentError.
  final Duration duration;

  /// Stop early when the band estimates sleep (sustained). Off by default.
  final bool stopOnSleep;

  /// Linear taper from [startBpm] to [endBpm] across [duration]; clamped
  /// outside [0, duration].
  double rateAt(Duration elapsed) => throw UnimplementedError();

  /// The breath pattern at [elapsed]: an equal inhale and exhale (no holds) at
  /// [rateAt] breaths per minute.
  BreathPattern patternAt(Duration elapsed) => throw UnimplementedError();
}

enum BedtimeStopReason {
  durationCap,
  sleepEstimated,
  userStopped,
  deliveryFailing,
  disconnected,
}

/// One stage observation. [stage] is 'wake' | 'nrem' | 'rem' | 'absent'; [at]
/// is the start of the 30 s epoch it describes; [observedAt] is when we asked.
class StageSample {
  const StageSample({
    required this.at,
    required this.stage,
    required this.observedAt,
  });
  final DateTime at;
  final String stage;
  final DateTime observedAt;
}

class BedtimePacingPolicy {
  BedtimePacingPolicy({required this.plan});
  final BedtimePlan plan;

  /// Why the session should end now, or null to carry on. [recentStages] is
  /// oldest first. Order of precedence: duration cap, disconnected, delivery
  /// failing, sleep estimated.
  BedtimeStopReason? onTick({
    required Duration elapsed,
    required DateTime now,
    required List<StageSample> recentStages,
    required int consecutiveMissedCues,
    required bool connected,
  }) =>
      throw UnimplementedError();

  /// 'unavailable' | 'awake' | 'not yet sustained' | 'sustained'.
  String sleepEstimateStatus(List<StageSample> recent, DateTime now) =>
      throw UnimplementedError();
}
