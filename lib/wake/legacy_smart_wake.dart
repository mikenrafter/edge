// Owns the legacy detector's reads and shared night context. AppState retains
// occurrence deduplication and its existing haptic delivery.
import 'dart:isolate';

import '../data/db.dart';
import '../state/control_operations.dart';
import '../state/smart_wake.dart';
import '../util/heavy.dart';
import '../util/worker_init.dart';
import 'wake_confounders.dart';
import 'wake_night_context.dart';
import 'wake_night_context_db.dart';

class LegacySmartWake {
  final WakeNightContext context;
  LegacySmartWake() : context = WakeNightContext(const DbWakeNightSource());

  Future<bool> detected(
    DateTime now,
    DateTime end,
    ExpectedSleepSchedule? schedule,
  ) async {
    final night = await context.load(end, schedule);
    final rows = await LocalDb.onehzForStager(
      now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch ~/ 1000,
      (now.millisecondsSinceEpoch + 999) ~/ 1000,
    );
    final nights = await LocalDb.recentDayResults(8);
    final input = LegacyWakeInput(
      WorkerInputs(
        nowEpochMs: now.millisecondsSinceEpoch,
        zoneId: 'UTC',
        localeTag: 'en',
      ),
      end.millisecondsSinceEpoch,
      rows,
      nights,
      night.profile,
      schedule?.windowFor(end).$1.millisecondsSinceEpoch,
    );
    return Isolate.run(() => legacyWakeHeavy(input));
  }
}

@SendableShape(
  'SQLite primitive row maps; sendable_legacyWakeHeavy_test covers worker round trip',
)
class LegacyWakeInput {
  final WorkerInputs worker;
  final int endMs;
  final List<Map<String, Object?>> rows, nights;
  final ConfounderProfile profile;
  final int? historyBeforeMs;
  const LegacyWakeInput(
    this.worker,
    this.endMs,
    this.rows,
    this.nights,
    this.profile,
    this.historyBeforeMs,
  );
}

@heavy
bool legacyWakeHeavy(LegacyWakeInput input) {
  WorkerInit.ensure(input.worker);
  assertWorker();
  return evaluateLegacyWakeHeavy(
    input.worker.nowEpochMs,
    input.endMs,
    input.rows,
    input.nights,
    input.profile,
    historyBeforeMs: input.historyBeforeMs,
  );
}
