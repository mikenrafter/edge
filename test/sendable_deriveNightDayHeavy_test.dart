// Worker-contract tests use the registered entry symbol in their filename.
// ignore_for_file: file_names
// WHY: a coordinator closure captured an unsendable engine Future after merge.
// Exercise the real worker with both retained owners, not an empty envelope.
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/ed2b_stream_diagnostics.dart';
import 'package:openstrap_edge/compute/night_day_worker.dart';
import 'package:openstrap_edge/compute/night_rr_state.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'guards/support/sendability.dart';
import 'support/incremental_day_fixture.dart';

const _inputs = WorkerInputs(nowEpochMs: 1760000000000, zoneId: 'UTC', localeTag: 'en');
NightDayInput _job(Map<String, dynamic> json, {DayCalculationState? day,
    NightRrState? night}) => NightDayInput(json, day, ana.CalculationMode.forced,
    night ?? NightRrState(), Ed2bStreamDiagnostics(), null, 7, 2, 125,
    false, false, const [], json['date'] as String, 'context', 0, 0, Uint8List(0));

void main() {
  tearDown(WorkerInit.resetForTest);
  test('populated day and night state cross both directions and append correctly', () async {
    final json = incrementalDay();
    final first = await Isolate.run(() => deriveNightDayHeavy(_inputs, _job(json)));
    expect(first.night!.retainedNightBeats, (json['sleep_rr_ms'] as List).length);
    expect(first.night!.processedNightBeats, greaterThan(0));
    expect(first.dayState.computations, greaterThan(0));
    final job = _job(json, day: first.dayState, night: first.night);
    await expectIsolateRoundTrip(job, project: (i) => [jsonEncode(i.json),
      i.night!.processedNightBeats, i.previous!.computations, i.revision, i.generation]);
    final again = await Isolate.run(() => deriveNightDayHeavy(_inputs, job));
    expect(jsonEncode(again.bundle), jsonEncode(first.bundle));
    expect(again.night!.processedNightBeats, first.night!.processedNightBeats,
      reason: 'an unchanged night must not refold its beats');
    await expectIsolateRoundTrip(again, project: (r) => [jsonEncode(r.bundle),
      r.night!.processedNightBeats, r.dayState.computations, r.resumed, r.rejected]);
  });
}
