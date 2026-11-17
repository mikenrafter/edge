// Worker-contract tests use the registered entry symbol in their filename.
// ignore_for_file: file_names
// WHY/CLAIM CROSSDAY-WORKER: the real publication worker must transfer its
// populated read snapshot and artifact, with metadata and absent need intact.
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_artifact_worker.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'guards/support/sendability.dart';
import 'support/crossday_artifact_fixture.dart';

void main() {
  tearDown(WorkerInit.resetForTest);
  test('populated inputs and encoded artifact cross the worker boundary', () async {
    final input = crossDayArtifactFixture();
    await expectIsolateRoundTrip(input, project: (i) => [i.days,
      i.profile, i.cycleStarts, i.sessionTypes, i.methodFamilies,
      i.algorithm, i.builtForDay, i.builtAtEpoch, i.zone, i.inputSignature]);
    final result = await Isolate.run(() => buildCrossDayArtifactHeavy(input));
    final bundle = jsonDecode(result.json) as Map<String, dynamic>;
    expect(bundle['algo_version'], 125);
    expect(bundle['built_for_day'], '2026-10-15');
    expect(bundle['zone'], 'UTC|0|0|0');
    expect(bundle['input_sig'], 'fixture-signature');
    final expected = buildCrossDayBundle(input.days, input.profile,
      cycleStartDates: input.cycleStarts, sessionTypesByDate: input.sessionTypes,
      methodFamilies: input.methodFamilies);
    expect(bundle['sleep_coach'], expected['sleep_coach']);
    expect(result.needMin, crossDayNeedMinutes(expected));
    await expectIsolateRoundTrip(result,
      project: (r) => [r.json, r.dropped, r.needMin]);
  });
}
