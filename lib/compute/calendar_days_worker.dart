import 'dart:isolate';
// Owns calendar segmentation for imported substrates. The import coordinator
// retains persistence and callbacks; no engine or database crosses the boundary.
import '../util/heavy.dart';
import '../util/worker_init.dart';
import '../util/worker_audit.dart';
import '../util/worker_entries.dart';
import 'substrate.dart';

@SendableShape('populated substrate columns; sendable_segmentCalendarDaysHeavy_test')
class CalendarDaysInput {
  const CalendarDaysInput(this.substrate, {this.targetDay, this.skipUnusedDays = false});
  final Substrate substrate;
  final String? targetDay;
  final bool skipUnusedDays;
}

@SendableShape('day bounds and analytics sleep objects; sendable_segmentCalendarDaysHeavy_test')
class CalendarDaysResult {
  const CalendarDaysResult(this.days, {this.segmentedDays = 0});
  final List<PhysioDay> days;
  final int segmentedDays;
}

@heavy
CalendarDaysResult segmentCalendarDaysHeavy(WorkerInputs worker, CalendarDaysInput input) {
  WorkerInit.ensure(worker);
  assertWorker();
  WorkerAudit.entered('segmentCalendarDaysHeavy');
  resetStagingWalkDiagnostics();
  final days = calendarDaysHeavy(input.substrate,
      targetDay: input.targetDay, skipUnusedDays: input.skipUnusedDays);
  return CalendarDaysResult(days, segmentedDays: stagingWalkSegmentedDays);
}

// Keep the dispatch closure outside an engine lock's async context: capturing
// that context also captures the engine and any pending, unsendable Future.
Future<CalendarDaysResult> segmentImportedCalendarDays(
    WorkerInputs worker, CalendarDaysInput input) {
  final dispatchId = WorkerAudit.dispatched(Dispatcher.run, 'import calendar days');
  final auditPort = WorkerAudit.auditPort;
  return Isolate.run(() {
    WorkerAudit.adopt(auditPort, dispatchId);
    return segmentCalendarDaysHeavy(worker, input);
  });
}
