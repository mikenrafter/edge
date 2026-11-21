// Worker-contract tests use the registered entry symbol in their filename.
// ignore_for_file: file_names
// WHY: persisted night state and its raw prefix must survive real worker
// transfer; a damaged checksum must return a cache miss, never a day state.
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/night_checkpoint.dart';
import 'package:openstrap_edge/compute/night_rr_state.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'guards/support/sendability.dart';

const _inputs = WorkerInputs(nowEpochMs: 1794703000000, zoneId: 'UTC', localeTag: 'en');
void main() {
  tearDown(WorkerInit.resetForTest);
  test('valid populated checkpoint crosses both directions; checksum damage refuses it', () async {
    const from = 1794700800, boundary = from + 1800;
    final rr = [for (var i = 0; i < 2000; i++) 950 + 15 * math.sin(i * .13)];
    final times = [for (var i = 0; i < 2000; i++) (from + i) * 1000.0];
    final state = NightRrState()..correctHeavy(rr, times, day: '2026-11-15', onsetSec: from);
    state.nightHrvFreqHeavy(0);
    state.nightRespHeavy(0);
    state.nightPrsaHeavy();
    final revisions = checkpointRevisions(const {}, from, boundary);
    final encoded = encodeNightCheckpointHeavy(state, const [], '2026-11-15', 125,
        'context', from, boundary, revisions)!;
    final row = <String, Object?>{'day_id': '2026-11-15', 'algo_version': 125,
      'fmt': nightCheckpointFormat, 'ctx_sig': 'context', 'cp_rec_ts': boundary,
      'rev_vec': revisions, 'state': encoded, 'night_ref': null, 'computed_at': 7};
    final job = NightCheckpointInput(row, '2026-11-15', 125, 'context', from,
        from + 1999, const {}, rr, times);
    await expectIsolateRoundTrip(job, project: (i) => [i.row, i.day, i.context,
      i.from, i.through, i.revisions, i.searchRr, i.searchTimes]);
    final result = await Isolate.run(() => restoreNightCheckpointHeavy(_inputs, job));
    expect(result.value.rejection, isNull);
    expect(result.value.night!.retainedNightBeats, 1800);
    await expectIsolateRoundTrip(result, project: (r) => [r.value.rejection,
      r.value.night!.retainedNightBeats, r.value.cardio]);
    encoded[40] ^= 1;
    final refused = await Isolate.run(() => restoreNightCheckpointHeavy(_inputs, job));
    expect(refused.value.rejection, isNotNull);
    expect(refused.value.night, isNull);
    expect(refused.value.cardio, isNull);
  });
}
