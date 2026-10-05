// calc_power_policy.dart — the "Calculations" setting as ONE pure policy.
//
// Three modes decide WHEN derive work and artifact warming run, nothing else:
// no metric, signature or stored value depends on the mode, so switching never
// recomputes anything and needs no kAlgoVersion bump.
//
//   maxBattery  derive only after a sync and on demand (a screen asking, pull
//               to sync, re-analyze); one worker; no background warming. While
//               the phone is unplugged AND under the OS power saver even the
//               automatic pass waits.
//   balanced    today's behaviour exactly. The OS power saver additionally
//               suppresses the NEW idle and plugged-in warming; the warm that
//               follows a pass stays, as it always did.
//   eager       ignores the power saver; after 5 continuous minutes on external
//               power it sweeps every missing or dirty day and artifact.
//
// Pure on purpose: the time is an argument and the power state is a value, so
// every case is exact and testable without a clock, a timer or a platform. The
// DeriveCoordinator owns the timers and feeds this the state a PowerSource
// reports. User-triggered work never asks this class.
import '../ble/ble_state.dart' show DeriveDebouncer;

enum CalcPowerMode { maxBattery, balanced, eager }

/// What the phone's power looks like right now.
class PowerState {
  const PowerState({
    required this.charging,
    this.chargingSince,
    this.powerSaver = false,
  });

  /// On external power (charging, full, or plugged in but not charging).
  final bool charging;

  /// Start of the CURRENT continuous external-power stretch. Null when
  /// unplugged, or when the start is not known: then no sweep is due, the start
  /// is never guessed.
  final DateTime? chargingSince;

  /// The OS power saver (Android battery saver, iOS Low Power Mode).
  final bool powerSaver;

  static const PowerState unplugged = PowerState(charging: false);

  @override
  bool operator ==(Object other) =>
      other is PowerState &&
      other.charging == charging &&
      other.chargingSince == chargingSince &&
      other.powerSaver == powerSaver;

  @override
  int get hashCode => Object.hash(charging, chargingSince, powerSaver);

  @override
  String toString() => 'PowerState(charging: $charging, since: $chargingSince, '
      'saver: $powerSaver)';
}

class CalcPowerPolicy {
  const CalcPowerPolicy(
    this.mode, {
    this.eagerPlugDelay = const Duration(minutes: 5),
    this.idleWarmDelay = const Duration(seconds: 30),
  });

  final CalcPowerMode mode;

  /// Continuous external power before Eager's sweep is due.
  final Duration eagerPlugDelay;

  /// Foreground idle time before Home/Health artifacts are warmed.
  final Duration idleWarmDelay;

  /// May an AUTOMATIC derive pass (the scheduler's) run now? Only Maximum
  /// battery ever says no: unplugged and under the saver.
  bool mayDeriveAutomatically(PowerState p) =>
      mode != CalcPowerMode.maxBattery || p.charging || !p.powerSaver;

  /// Worker cap for a pass, null = none (today's rule). Feeds DerivePacing.
  int? get maxWorkers => mode == CalcPowerMode.maxBattery ? 1 : null;

  /// Idle warming: Home/Health artifacts after [idleWarmDelay] of foreground
  /// quiet.
  bool mayWarmIdle(PowerState p) => switch (mode) {
        CalcPowerMode.maxBattery => false,
        CalcPowerMode.balanced => !p.powerSaver,
        CalcPowerMode.eager => true,
      };

  /// Warming of the recent artifacts while the phone is plugged in.
  bool mayWarmWhilePlugged(PowerState p) => p.charging && mayWarmIdle(p);

  /// The warm that follows a pass that computed days. Balanced keeps it under
  /// the saver because it always ran there; only Maximum battery drops it.
  bool mayWarmAfterPass(PowerState p) => mode != CalcPowerMode.maxBattery;

  /// Eager's plug-in sweep: the time left, [Duration.zero] when due, null when
  /// it cannot become due (another mode, not charging, or no known start).
  /// Measured against [PowerState.chargingSince], so a mode switch never resets
  /// the plug clock; an unplug and replug does, because the source stamps a new
  /// start.
  Duration? untilEagerSweep(PowerState p, DateTime now) {
    final since = p.chargingSince;
    if (mode != CalcPowerMode.eager || !p.charging || since == null) return null;
    final left = since.add(eagerPlugDelay).difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  bool eagerSweepDue(PowerState p, DateTime now) =>
      untilEagerSweep(p, now) == Duration.zero;

  /// The derive debounce tiers for this mode. Balanced is today's, field for
  /// field.
  DeriveDebouncer get debouncer => switch (mode) {
        CalcPowerMode.balanced => const DeriveDebouncer(),
        // Every tier at the background tier's 20 min / 45 min, the slowest that
        // exists: a burst of records waits for the stream to go quiet.
        CalcPowerMode.maxBattery => const DeriveDebouncer(
            staleQuietPeriod: Duration(minutes: 20),
            staleMaxWait: Duration(minutes: 45),
            freshQuietPeriod: Duration(minutes: 20),
            freshMaxWait: Duration(minutes: 45),
            foregroundQuietPeriod: Duration(minutes: 20),
            foregroundMaxWait: Duration(minutes: 45),
          ),
        // Faster fresh and foreground tiers; none slower than today.
        CalcPowerMode.eager => const DeriveDebouncer(
            staleQuietPeriod: Duration(seconds: 8),
            staleMaxWait: Duration(seconds: 60),
            freshQuietPeriod: Duration(seconds: 20),
            freshMaxWait: Duration(minutes: 2),
            foregroundQuietPeriod: Duration(seconds: 3),
            foregroundMaxWait: Duration(seconds: 10),
          ),
      };
}
