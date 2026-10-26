// P2 RED signatures only. This owner will serialize outcome writes and tuning
// application over LocalDb. Storage errors may propagate to the caller.
import 'natural_wake_tuning.dart';
import 'wake_outcome.dart';
import 'wake_timeline.dart';

class DbWakeJournal {
  const DbWakeJournal();

  // Resolve the preceding wake path from durable trace, under this owner's
  // write boundary. A null answer means Skip and must create no record.
  Future<void> answerDream({
    required int wakeEpochSec,
    required DateTime at,
    required DreamAnswer? answer,
  }) async {}

  Future<WakeNightTimeline> forEpoch(int wakeEpochSec) async =>
      const WakeNightTimeline();

  Future<List<WakeNightOutcome>> outcomes() async => const [];

  // Load durable outcomes/current parameters, apply at most once for this
  // epoch, and commit the new state with its tune trace row atomically.
  Future<NaturalTuningDecision> tuneFor(int wakeEpochSec) async =>
      const NaturalTuningDecision();

  Future<NaturalWakeParameters> parameters() async =>
      const NaturalWakeParameters();
}
