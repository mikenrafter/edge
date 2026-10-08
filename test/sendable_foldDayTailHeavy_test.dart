// ignore_for_file: file_names
// The @SendableShape round trip for the day-tail fold entry (design 02: an
// entry whose result carries `Map<String, dynamic>` JSON envelopes is outside
// the closed grammar and owes a real Isolate.run round trip).
//
// Pins: `DayTailInput` (the stored checkpoint blob + the tail) crosses into a worker and
// `DayTailResult` (the persisted irregular-screen envelope with its PRV
// diagnostics, the curves, the daytime HRV, the tail) comes back, intact in both
// directions, and the worker answers with what the same call on this isolate
// answers.

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/day_curve_states.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';
import 'package:openstrap_edge/compute/day_tail_fold.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import 'guards/support/sendability.dart';

const _inputs = WorkerInputs(nowEpochMs: 1760000000000, zoneId: 'UTC', localeTag: 'en');

DayTailInput _input() => DayTailInput(
      checkpoint:
          encodeDayResumeState(DayResumeState(curves: DayCurveStates(cut: 0.02))),
      tailRr: const [812.0, 805.0, 790.0],
      tailTs: const [1760000001000.0, 1760000002000.0, 1760000003000.0],
      accTs: const [1760000000, 1760000001, 1760000002, 1760000003],
      ax: const [0.0, 0.1, 0.0, 0.1],
      ay: const [0.0, 0.0, 0.1, 0.1],
      az: const [1.0, 1.0, 0.99, 1.0],
      onsetSec: 1760000000,
      offsetSec: 1760003600,
    );

Object? _inputShape(DayTailInput i) => [
      i.checkpoint,
      i.tailRr,
      i.tailTs,
      i.accTs,
      i.ax,
      i.ay,
      i.az,
      i.onsetSec,
      i.offsetSec,
    ];

Object? _resultShape(DayTailResult? r) => r == null
    ? null
    : [r.irregular, r.hrv, r.resp, r.daytime, r.tailRr, r.tailTs];

void main() {
  test('the input crosses an isolate boundary with every field intact', () async {
    await expectIsolateRoundTrip<DayTailInput>(_input(), project: _inputShape);
  });

  test('the result crosses an isolate boundary with every field intact', () async {
    final result = DayTailResult(
      irregular: {
        'value': {'flag': false},
        'diagnostics': {
          'version': 1,
          'beats': {'rr_raw': 3, 'nn_in': 3, 'artifact_fraction': 0.0},
          'windows': null,
        },
      },
      hrv: [
        {'t': 1760000100, 'v': 41.5},
      ],
      resp: [
        {'t': 1760000100, 'v': 14.25},
      ],
      daytime: {'n_buckets': 0, 'median': null},
      tailRr: const [812.0, 805.0],
      tailTs: const [1760000001000.0, 1760000002000.0],
    );
    await expectIsolateRoundTrip<DayTailResult>(result, project: _resultShape);
  });

  test('the worker answers with the JSON text this isolate would produce',
      () async {
    final input = _input();
    final here = jsonEncode(_resultShape(foldDayTailHeavy(_inputs, input)));
    final inWorker = jsonEncode(_resultShape(
        await Isolate.run(() => foldDayTailHeavy(_inputs, input))));
    expect(inWorker, here);
    expect(inWorker, isNot('null'), reason: 'an empty-state fold of a short '
        'tail continues (it is not an abstention)');
  });
}
