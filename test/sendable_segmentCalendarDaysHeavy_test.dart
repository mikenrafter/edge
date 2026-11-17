// Worker-contract tests use the registered entry symbol in their filename.
// ignore_for_file: file_names
// WHY/CLAIM IMPORT-STAGING-WORKER: imported day segmentation must leave the
// UI isolate, and populated input plus analytics sleep objects must transfer.
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calendar_days_worker.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'guards/support/sendability.dart';
import 'support/calendar_days_fixture.dart';

const inputs = WorkerInputs(nowEpochMs: 1792022400000, zoneId: 'UTC', localeTag: 'en');
List<Object?> projectDays(List<PhysioDay> days) => [for (final d in days)
  [d.date, d.startSec, d.endSec, d.sleepLoIdx, d.sleepHiIdx,
   d.confidence, d.sleepSource, d.flags, d.sleep.toJson()]];
void main() {
  tearDown(WorkerInit.resetForTest);
  test('populated substrate and both calendar days cross a real isolate', () async {
    final sub = calendarDaysFixture();
    await expectIsolateRoundTrip(sub, project: (s) => s.toJson());
    final input = CalendarDaysInput(sub);
    await expectIsolateRoundTrip(input, project: (i) => i.substrate.toJson());
    final result = await Isolate.run(() => segmentCalendarDaysHeavy(inputs, input));
    final days = result.days;
    expect(days.map((d) => d.date), ['2026-10-14', '2026-10-15']);
    expect(days.first.startSec, sub.tsSec.first);
    expect(days.last.endSec, sub.tsSec.last + 1);
    expect(days.first.endSec, days.last.startSec);
    expect(projectDays(days), projectDays(calendarDaysHeavy(sub)));
    await expectIsolateRoundTrip(result, project: (r) => projectDays(r.days));
  });
}
