// alarm_stop_policy.dart — the pure rule for what a stopped main alarm becomes.
//
// Pinned by test/alarm_snooze/alarm_stop_policy_test.dart.
//
// The rule (owner spec 2026-10-07):
//   * error                      -> [AlarmStopDecision.error] (log only).
//   * a confirmed wake exists    -> [AlarmStopDecision.confirmedAwake].
//   * userDoubleTap: the tap that stopped the alarm is tap #1. Taps in
//     [stoppedAt, stoppedAt + window] (inclusive) count; `1 + n >= requiredTaps`
//     is [AlarmStopDecision.dismissed] at the moment the n-th tap is in, without
//     waiting out the window. Fewer by the window's end -> snooze.
//   * expired                    -> snooze at once.
//   * reAlarm (the app's own re-alarm): there is no stopping tap; every tap
//     counts; otherwise as userDoubleTap.

/// Why the band's wake alarm stopped (HAPTICS_TERMINATED(100)), plus the app's
/// own re-alarm, which has no band cause.
enum AlarmStopCause {
  userDoubleTap,
  expired,
  error,

  /// The app-driven re-alarm of a snooze (never produced by [parse]).
  reAlarm;

  /// The engine's termination string ('user_double_tap', 'expired', 'error').
  /// Anything else, including null and 'unknown', is [error]: no snooze is
  /// invented from a cause nobody understands.
  static AlarmStopCause parse(String? band) => switch (band) {
        'user_double_tap' => userDoubleTap,
        'expired' => expired,
        _ => error,
      };
}

enum AlarmStopDecision { pending, dismissed, snooze, confirmedAwake, error }

class AlarmStopPolicy {
  const AlarmStopPolicy({required this.requiredTaps, required this.window});

  /// Double taps (the stopping one included) that dismiss. 1..5.
  final int requiredTaps;

  /// How long after [decide]'s `stoppedAt` the taps are counted.
  final Duration window;

  /// [taps] are the phone-clock instants of double-tap events since the stop,
  /// NOT counting the one that stopped a native alarm (it is implicit for
  /// [AlarmStopCause.userDoubleTap]). Taps before [stoppedAt], after the
  /// window, or after [now] are ignored.
  AlarmStopDecision decide({
    required AlarmStopCause cause,
    required DateTime stoppedAt,
    required Iterable<DateTime> taps,
    required bool confirmedWake,
    required DateTime now,
  }) {
    if (cause == AlarmStopCause.error) return AlarmStopDecision.error;
    if (confirmedWake) return AlarmStopDecision.confirmedAwake;
    if (cause == AlarmStopCause.expired) return AlarmStopDecision.snooze;
    final end = stoppedAt.add(window);
    var counted = cause == AlarmStopCause.userDoubleTap ? 1 : 0;
    for (final t in taps) {
      if (t.isBefore(stoppedAt) || t.isAfter(end) || t.isAfter(now)) continue;
      counted++;
    }
    if (counted >= requiredTaps) return AlarmStopDecision.dismissed;
    return now.isBefore(end)
        ? AlarmStopDecision.pending
        : AlarmStopDecision.snooze;
  }
}
