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
// Pure: no clock, no I/O, no state.

import '../../stress/breath_phases.dart';

/// Default session length.
const Duration kBedtimeDefaultDuration = Duration(minutes: 15);

/// Shortest and longest session a plan may ask for.
const Duration kBedtimeMinDuration = Duration(minutes: 1);
const Duration kBedtimeMaxDuration = Duration(minutes: 20);

/// The comfortable default pace and the allowed range, breaths per minute.
const double kBedtimeDefaultBpm = 6.0;
const double kBedtimeMinBpm = 4.0;

/// The fastest pace a plan may ask for: 7 breaths a minute, not 8.
///
/// Every breath is two band commands (an inhale cue and an exhale cue), and the
/// band's shared haptic budget is 30 commands in any 2 minutes
/// (`kBandCommandLimitDefault` in lib/haptics/band_queue.dart). At 7 bpm that is
/// 14 commands a minute, 28 per 2 minutes: inside the budget. At 8 bpm it would
/// be 32 per 2 minutes, which the queue would start refusing, and a refused cue
/// is a missed cue (three in a row end the session). So the range is 4..7.
const double kBedtimeMaxBpm = 7.0;

/// A stage sample is fresh while now minus when it was observed is at most this.
const Duration kBedtimeFreshness = Duration(seconds: 90);

/// Consecutive non-wake epoch observations the sleep stop needs.
const int kBedtimeSustainedEpochs = 4;

/// Consecutive cues that did not reach the band before the session ends.
const int kBedtimeMaxMissedCues = 3;

/// The stager is asked at most this often.
const Duration kBedtimeObserveInterval = Duration(seconds: 30);

/// What the user asked for. Rates are breaths per minute, [4, 7] (see
/// [kBedtimeMaxBpm] for why 7); the end rate may not exceed the start rate (a
/// taper never speeds up). [endBpm] defaults to [startBpm], which is the fixed
/// pace. Anything outside the range, or not a finite number, throws
/// [ArgumentError].
class BedtimePlan {
  BedtimePlan({
    this.startBpm = kBedtimeDefaultBpm,
    double? endBpm,
    this.duration = kBedtimeDefaultDuration,
    this.stopOnSleep = false,
  }) : endBpm = endBpm ?? startBpm {
    void rate(String name, double v) {
      // NaN fails both comparisons below, so it is refused with the rest.
      if (!(v >= kBedtimeMinBpm && v <= kBedtimeMaxBpm)) {
        throw ArgumentError.value(
            v, name, 'must be between $kBedtimeMinBpm and $kBedtimeMaxBpm');
      }
    }

    rate('startBpm', startBpm);
    rate('endBpm', this.endBpm);
    if (this.endBpm > startBpm) {
      throw ArgumentError.value(
          this.endBpm, 'endBpm', 'a taper never speeds up (above startBpm)');
    }
    if (duration < kBedtimeMinDuration || duration > kBedtimeMaxDuration) {
      throw ArgumentError.value(duration, 'duration',
          'must be between $kBedtimeMinDuration and $kBedtimeMaxDuration');
    }
  }

  final double startBpm;

  /// Equal to [startBpm] for a fixed pace.
  final double endBpm;

  /// 1..20 minutes, else ArgumentError.
  final Duration duration;

  /// Stop early when the band estimates sleep (sustained). Off by default.
  final bool stopOnSleep;

  /// Linear taper from [startBpm] to [endBpm] across [duration]; clamped
  /// outside [0, duration].
  double rateAt(Duration elapsed) {
    final t = _fraction(elapsed);
    return startBpm + (endBpm - startBpm) * t;
  }

  /// Breaths completed by [elapsed]: the area under the rate curve, so a taper
  /// keeps one continuous phase (a changing cycle length never makes the
  /// inhale/exhale jump). 0 before the start. A fixed pace is rate * minutes.
  double breathsAt(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    if (t <= 0) return 0;
    final d = duration.inMicroseconds / 1e6;
    if (t <= d) {
      return (startBpm * t + (endBpm - startBpm) * t * t / (2 * d)) / 60;
    }
    // Past the end the rate stays at [endBpm].
    final atEnd = (startBpm * d + (endBpm - startBpm) * d / 2) / 60;
    return atEnd + endBpm * (t - d) / 60;
  }

  /// The breath pattern at [elapsed]: an equal inhale and exhale (no holds) at
  /// [rateAt] breaths per minute.
  BreathPattern patternAt(Duration elapsed) {
    final half = 30.0 / rateAt(elapsed); // half of a 60 / rate second cycle
    return BreathPattern(
      key: 'bedtime',
      label: 'Bedtime',
      description: 'An equal inhale and exhale at a slow, fixed pace.',
      phases: [
        BreathPhase(BreathPhaseKind.inhale, half),
        BreathPhase(BreathPhaseKind.exhale, half),
      ],
    );
  }

  /// [elapsed] as a 0..1 share of [duration].
  double _fraction(Duration elapsed) {
    final t = elapsed.inMicroseconds / duration.inMicroseconds;
    return t < 0 ? 0 : (t > 1 ? 1 : t);
  }
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
  }) {
    if (elapsed >= plan.duration) return BedtimeStopReason.durationCap;
    if (!connected) return BedtimeStopReason.disconnected;
    if (consecutiveMissedCues >= kBedtimeMaxMissedCues) {
      return BedtimeStopReason.deliveryFailing;
    }
    if (plan.stopOnSleep &&
        sleepEstimateStatus(recentStages, now) == 'sustained') {
      return BedtimeStopReason.sleepEstimated;
    }
    return null;
  }

  /// 'unavailable' | 'awake' | 'not yet sustained' | 'sustained'.
  ///
  /// Only a fresh newest observation says anything: stale, absent or unknown
  /// data is 'unavailable', never 'awake'. 'sustained' needs
  /// [kBedtimeSustainedEpochs] distinct, consecutive, non-wake epochs ending at
  /// the newest, each observation within [kBedtimeFreshness] of the one before
  /// (a longer outage breaks the run).
  String sleepEstimateStatus(List<StageSample> recent, DateTime now) {
    if (recent.isEmpty) return 'unavailable';
    final newest = recent.last;
    if (now.difference(newest.observedAt) > kBedtimeFreshness) {
      return 'unavailable';
    }
    if (newest.stage == 'wake') return 'awake';
    if (!_isSleep(newest.stage)) return 'unavailable';

    // One entry per epoch (the latest look at it), oldest first.
    final epochs = <StageSample>[];
    for (final s in recent) {
      if (epochs.isNotEmpty && epochs.last.at == s.at) {
        epochs[epochs.length - 1] = s;
      } else {
        epochs.add(s);
      }
    }
    var run = 1;
    for (var i = epochs.length - 1; i > 0 && run < kBedtimeSustainedEpochs; i--) {
      final earlier = epochs[i - 1];
      final later = epochs[i];
      if (!_isSleep(earlier.stage) ||
          later.observedAt.difference(earlier.observedAt) > kBedtimeFreshness) {
        break;
      }
      run++;
    }
    return run >= kBedtimeSustainedEpochs ? 'sustained' : 'not yet sustained';
  }

  static bool _isSleep(String stage) => stage == 'nrem' || stage == 'rem';
}
