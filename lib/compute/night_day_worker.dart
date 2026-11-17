// Owns the pure first half of a day derive. The coordinator passes values;
// no engine closure or database handle crosses the isolate boundary.
import 'dart:typed_data';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../util/heavy.dart';
import '../util/worker_init.dart';
import '../util/worker_audit.dart';
import 'day_calculation_state.dart';
import 'ed2b_stream_diagnostics.dart';
import 'night_checkpoint.dart';
import 'night_rr_state.dart' show NightRrState;
import 'onehz_pipeline.dart';

@SendableShape('JSON day input and caller-owned calculation states; real round trip in test/sendable_deriveNightDayHeavy_test.dart')
class NightDayInput {
  const NightDayInput(this.json, this.previous, this.mode, this.night,
    this.diagnostics, this.restored, this.revision, this.generation,
    this.algorithm, this.batchReference, this.canCheckpoint, this.chunks,
    this.day, this.context, this.from, this.boundary, this.revisions);
  final Map<String, dynamic> json;
  final DayCalculationState? previous;
  final ana.CalculationMode mode;
  final NightRrState? night, restored;
  final Ed2bStreamDiagnostics? diagnostics;
  final int revision, generation, algorithm, from, boundary;
  final bool batchReference, canCheckpoint;
  final List<Uint8List> chunks;
  final Uint8List revisions;
  final String day, context;
}

@SendableShape('JSON result and caller-owned calculation states; real round trip in test/sendable_deriveNightDayHeavy_test.dart')
class NightDayResult {
  const NightDayResult(this.bundle, this.night, this.diagnostics, this.resumed,
    this.rejected, this.checkpoint, this.dayState);
  final Map<String, dynamic> bundle;
  final NightRrState? night;
  final Ed2bStreamDiagnostics? diagnostics;
  final bool resumed, rejected;
  final NightCheckpointWrite? checkpoint;
  final DayCalculationState dayState;
}

@heavy
NightDayResult deriveNightDayHeavy(WorkerInputs inputs, NightDayInput job) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('deriveNightDayHeavy');
  if (job.batchReference) {
    final result = auditBatchDay(inputs, AuditBatchInput(job.json), job.mode);
    return NightDayResult(result.bundle, null, job.diagnostics, false, false,
        null, DayCalculationState());
  }
  var state = job.night;
  var resumed = false;
  final input = DayBundleInput.fromJson(job.json);
  final restored = job.restored;
  if (restored != null && restored.acceptsPrefix(input.sleepRrMs,
      input.sleepRrTsMs, input.date, input.sleepOnsetSec)) {
    restored.bindRestoredContext(job.revision, job.generation, job.algorithm,
        previous: state);
    state = restored;
    resumed = true;
    if (job.diagnostics != null) job.diagnostics!.nightState = state;
  }
  final dayState = job.previous ?? DayCalculationState();
  final bundle = deriveDayBundle(job.json, state: dayState, mode: job.mode,
      streamDiagnostics: job.diagnostics, nightState: state);
  NightCheckpointWrite? checkpoint;
  if (job.canCheckpoint) {
    try {
      checkpoint = encodeNightCheckpointHeavy(state, job.chunks, job.day,
          job.algorithm, job.context, job.from, job.boundary, job.revisions);
    } catch (_) {
      // A disposable cache cannot turn a completed derive into a failure.
    }
  }
  return NightDayResult(bundle, state, job.diagnostics, resumed,
      restored != null && !resumed, checkpoint, dayState);
}
