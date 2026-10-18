/// How one derivation pass ended, so the scheduler can tell "nothing to do"
/// from "it blew up" from "it skipped days it will want back". Pure Dart.
class DeriveOutcome {
  const DeriveOutcome({
    this.computed = 0,
    this.transientFailures = 0,
    this.failed = false,
    this.error,
  });

  /// Days the pass derived.
  final int computed;

  /// Days skipped for a reason that may not repeat (timeout, worker error).
  /// Structural skips are not counted: the same input would fail the same way.
  final int transientFailures;

  /// The pass itself failed, or was refused because another pass held the
  /// engine (it did not do the requested work).
  final bool failed;
  final String? error;

  /// Everything asked of the pass was done; the job can be dropped.
  bool get complete => !failed && transientFailures == 0;

  Map<String, Object?> toMap() => {
        'computed': computed,
        'transient_failures': transientFailures,
        'failed': failed,
        'error': error,
        'complete': complete,
      };
}

/// A job that has failed this many times is parked as 'failed'.
const int kDeriveMaxAttempts = 5;

/// How long a failed derive job waits before its next attempt. [attempts] is
/// the job's attempt count including the one that just failed (the first
/// failure passes 1): 30 s * 2^(attempts-1), capped at 15 minutes. Anything
/// below 1 is treated as 1.
Duration deriveRetryBackoff(int attempts) {
  const cap = Duration(minutes: 15);
  final n = attempts < 1 ? 1 : attempts;
  // 30 s * 2^5 already exceeds the cap; clamp the shift so a pathological
  // count cannot overflow.
  if (n > 6) return cap;
  final d = Duration(seconds: 30 * (1 << (n - 1)));
  return d > cap ? cap : d;
}
