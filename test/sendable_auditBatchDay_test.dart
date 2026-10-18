// ignore_for_file: file_names
// The @SendableShape round trip for the finalization audit's batch entry
// (design 02: an entry whose argument or result carries a
// `Map<String, dynamic>` JSON bundle is outside the closed grammar and owes a
// real Isolate.run round trip).
//
// Pins: `AuditBatchInput` (the serialized day bundle input) crosses into a
// worker and `AuditBatchResult` (the derived bundle) comes back, intact in both
// directions, and the worker answers with what the same call on this isolate
// answers.

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' show CalculationMode;
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import 'guards/support/sendability.dart';
import 'support/incremental_day_fixture.dart';

const _inputs =
    WorkerInputs(nowEpochMs: 1760000000000, zoneId: 'UTC', localeTag: 'en');

void main() {
  tearDown(WorkerInit.resetForTest);

  test('the input crosses an isolate boundary with its map intact', () async {
    final input = AuditBatchInput(copyDay(incrementalDay()));
    await expectIsolateRoundTrip<AuditBatchInput>(input,
        project: (i) => jsonEncode(i.json));
  });

  test('the result crosses an isolate boundary with its map intact', () async {
    final result = AuditBatchResult(
        {'scalars': {'rhr': 51.5}, 'series': <String, dynamic>{}, 'n': 3});
    await expectIsolateRoundTrip<AuditBatchResult>(result,
        project: (r) => jsonEncode(r.bundle));
  });

  test('the worker answers with the JSON text this isolate would produce',
      () async {
    final input = AuditBatchInput(copyDay(incrementalDay()));
    String run() => jsonEncode(
        auditBatchDay(_inputs, input, CalculationMode.forced).bundle);
    final here = run();
    final inWorker = await Isolate.run(run);
    expect(inWorker, here);
  });
}
