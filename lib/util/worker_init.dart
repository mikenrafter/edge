// worker_init.dart — explicit worker initialisation (design 02).
//
// A heavy worker entry starts with `assertWorker()` and `WorkerInit.ensure(…)`.
// Clock, zone and locale are PLAIN INPUTS in the entry's argument record, never
// read ambiently inside the worker (same inputs ⇒ same output). `ensure` only
// re-arms the analytics ambient globals (`cardioUserProfile`,
// `cardioRecordObservations`, the observation buffer) from those inputs; they
// are isolate-local and do not cross `Isolate.run`.
//
// No reliance on `Isolate.debugName`: a worker is a worker because `ensure` ran
// in this isolate, not because of what it is called.

import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart' as ana;

import 'heavy.dart';

/// Plain, sendable inputs every worker entry carries.
@sendable
class WorkerInputs {
  /// The instant "now" as epoch milliseconds, supplied by the caller.
  final int nowEpochMs;

  /// IANA zone id the worker should use for local-day arithmetic.
  final String zoneId;

  /// BCP-47 locale tag for any formatting the worker does.
  final String localeTag;

  /// `SleepUserProfile.toJson()` as a JSON string, or null for cold start.
  final String? sleepProfileJson;

  /// Whether this pass records sleep observations to fold back afterwards.
  final bool recordSleepObservations;

  const WorkerInputs({
    required this.nowEpochMs,
    required this.zoneId,
    required this.localeTag,
    this.sleepProfileJson,
    this.recordSleepObservations = false,
  });
}

class WorkerInit {
  WorkerInit._();

  static bool _initialised = false;

  /// Re-arms the analytics ambient globals from [inputs] in THIS isolate and
  /// marks the isolate as an initialised worker. Idempotent: the same inputs
  /// always leave the same state, and a second call REPLACES the first arming.
  static void ensure(WorkerInputs inputs) {
    final json = inputs.sleepProfileJson;
    ana.cardioUserProfile = json == null
        ? null
        : ana.SleepUserProfile.fromJson(
            (jsonDecode(json) as Map).cast<String, dynamic>());
    ana.cardioRecordObservations = inputs.recordSleepObservations;
    // A stale buffer from an earlier arming must not leak into this pass.
    ana.resetCardioObservations();
    _initialised = true;
  }

  /// True once [ensure] ran in this isolate.
  static bool get isInitialised => _initialised;

  /// Forgets initialisation. Test seam: the main isolate of a test process must
  /// be able to go back to "not a worker".
  static void resetForTest() {
    _initialised = false;
  }
}

/// Debug-only: fails (assert) unless [WorkerInit.ensure] ran in this isolate.
/// Put it at the top of every `@heavy` entry. Calling a heavy function
/// directly on the UI isolate must trip it.
void assertWorker() {
  assert(
    WorkerInit.isInitialised,
    'heavy function called outside a worker: WorkerInit.ensure has not run in '
    'this isolate',
  );
}
