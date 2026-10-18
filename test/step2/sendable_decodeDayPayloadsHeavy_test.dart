// ignore_for_file: file_names
// The @SendableShape round trip for the BundleStore decode entry (design 02,
// step 2, P2.2). `DecodedChunk` carries frozen JSON graphs (Map/List of
// String, num, bool, null), which sit outside the closed sendable grammar, so
// the entry owes a real Isolate.run round trip.
//
// Pins: the input crosses into a worker and the result comes back with the
// graph still frozen (mutation throws) and equal to what this isolate builds.
// The first two tests pin the types and pass on the stub; the third needs the
// entry itself.

import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/bundle_store.dart';

import '../guards/support/sendability.dart';

const _json = '{"scalars":{"rhr":50.5,"rmssd":60},"series":{"hr_curve":'
    '{"t0":1000,"dt":60,"v":[60,61,62,63]}}}';

Object? _freeze(Object? v) => switch (v) {
  Map() => Map<String, dynamic>.unmodifiable({
    for (final e in v.entries) e.key as String: _freeze(e.value),
  }),
  List() => List<dynamic>.unmodifiable([for (final e in v) _freeze(e)]),
  _ => v,
};

void main() {
  test('the chunk input crosses an isolate boundary intact', () async {
    await expectIsolateRoundTrip<DecodeChunkInput>(
      const DecodeChunkInput(payloadJson: [_json, '{}'], projections: ['full', 'cycleScalars']),
      project: (c) => [c.payloadJson, c.projections],
    );
  });

  test('a frozen compact graph crosses back and stays frozen', () async {
    final graph = _freeze({
      'scalars': {'rhr': 50.5},
      'series': {
        'hr_curve': {'t0': 1000, 'dt': 60, 'v': [60, 61, 62]},
      },
    });
    final chunk = DecodedChunk(graphs: [graph, null], estimatedBytes: [100, 0], nodes: [9, 0]);
    final back = await Isolate.run(() => chunk);
    expect(back.graphs.first, graph);
    expect(back.graphs.last, isNull);
    expect(
      () => ((back.graphs.first as Map)['scalars'] as Map)['rhr'] = 1,
      throwsUnsupportedError,
      reason: 'a frozen graph sent through Isolate.exit arrives frozen',
    );
  });

  test('the worker answers with the frozen compact graph, curves unexpanded',
      () async {
    final got = await Isolate.run(
      () => decodeDayPayloadsHeavy(
        bundleWorkerInputs,
        const DecodeChunkInput(payloadJson: [_json], projections: ['full']),
      ),
    );
    final root = got.graphs.single as Map;
    expect(((root['series'] as Map)['hr_curve'] as Map)['dt'], 60,
        reason: 'stored grid shape: the worker never expands a curve');
    // payloadNodeCount: root, scalars (+ rhr, rmssd), series, hr_curve
    // (+ t0, dt, v and its 4 items) = 14. No string VALUES, so the estimate is
    // 64 + 24 x 14 + 2 x 0 (keys are not counted, as in payloadNodeCount).
    expect(got.nodes.single, 14);
    expect(got.estimatedBytes.single, 400, reason: 'sized in the worker');
    expect(() => (root['scalars'] as Map)['rhr'] = 1, throwsUnsupportedError);
  });
}
