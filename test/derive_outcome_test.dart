// The pure part of structured run outcomes.
//
// API (lib/compute/derive_outcome.dart, new, pure Dart, no imports from
// db/engine):
//
//   class DeriveOutcome {
//     const DeriveOutcome({
//       this.computed = 0,
//       this.transientFailures = 0,
//       this.failed = false,      // pass-level error, or refused because busy
//       this.error,               // String?
//     });
//     final int computed;
//     final int transientFailures;
//     final bool failed;
//     final String? error;
//     bool get complete => !failed && transientFailures == 0;
//     Map<String, Object?> toMap();  // {computed, transient_failures, failed,
//                                    //  error, complete}: what
//                                    //  DerivationEngine.snapshot()
//                                    //  ['last_outcome'] carries
//   }
//
//   /// How long a failed derive job waits before its next attempt. [attempts]
//   /// is the job's attempt count INCLUDING the one that just failed (the
//   /// first failure passes 1): 30 s * 2^(attempts-1), capped at 15 minutes.
//   /// Anything below 1 is treated as 1.
//   Duration deriveRetryBackoff(int attempts);
//
//   /// A job that has failed this many times is parked as 'failed'.
//   const int kDeriveMaxAttempts = 5;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_outcome.dart';

void main() {
  group('DeriveOutcome', () {
    test('a clean pass is complete', () {
      expect(const DeriveOutcome(computed: 3).complete, isTrue);
      expect(const DeriveOutcome().complete, isTrue,
          reason: 'a pass with nothing to do did everything asked of it');
    });

    test('a transient failure is not complete, even if days computed', () {
      const o = DeriveOutcome(computed: 2, transientFailures: 1);
      expect(o.complete, isFalse);
      expect(o.failed, isFalse, reason: 'the pass itself ran');
    });

    test('a failed pass is not complete', () {
      const o = DeriveOutcome(failed: true, error: 'busy');
      expect(o.complete, isFalse);
      expect(o.error, 'busy');
    });

    test('failed with no transient failures is still incomplete', () {
      expect(const DeriveOutcome(failed: true).complete, isFalse);
    });

    test('toMap carries every field under snake_case keys', () {
      const o = DeriveOutcome(
          computed: 4, transientFailures: 2, failed: false, error: 'x');
      expect(o.toMap(), {
        'computed': 4,
        'transient_failures': 2,
        'failed': false,
        'error': 'x',
        'complete': false,
      });
    });
  });

  group('deriveRetryBackoff', () {
    test('doubles from 30 s', () {
      expect(deriveRetryBackoff(1), const Duration(seconds: 30));
      expect(deriveRetryBackoff(2), const Duration(seconds: 60));
      expect(deriveRetryBackoff(3), const Duration(seconds: 120));
      expect(deriveRetryBackoff(4), const Duration(seconds: 240));
      expect(deriveRetryBackoff(5), const Duration(seconds: 480));
    });

    test('is capped at 15 minutes', () {
      expect(deriveRetryBackoff(6), const Duration(minutes: 15));
      expect(deriveRetryBackoff(7), const Duration(minutes: 15));
      expect(deriveRetryBackoff(40), const Duration(minutes: 15));
      expect(deriveRetryBackoff(1000), const Duration(minutes: 15),
          reason: 'no integer overflow on a pathological count');
    });

    test('zero or negative attempts behave like the first failure', () {
      expect(deriveRetryBackoff(0), const Duration(seconds: 30));
      expect(deriveRetryBackoff(-3), const Duration(seconds: 30));
    });

    test('five attempts, then the job is parked', () {
      expect(kDeriveMaxAttempts, 5);
    });
  });
}
