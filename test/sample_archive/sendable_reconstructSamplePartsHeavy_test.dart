// ignore_for_file: file_names
// Sendable round trip + parity for the sample archive's reconstruct entry
// (design 02 follow-up: the decode + overlay that was an inline `Isolate.run`
// closure in `SampleArchiver.reconstructWithOrigin` is the registered @heavy
// entry `reconstructSamplePartsHeavy`).
//
// Pins: `SampleReconstructInput` (the stored parts with their absolute origins,
// an optional coarse order) crosses into a worker and the
// `({originSec, samples})` record comes back intact, gaps (null) included; and
// the answer equals the independent decode + overlay oracle, full and coarse.

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sample_heavy.dart';

import '../guards/support/sendability.dart';
import '../support/sample_heavy_fixtures.dart';

Object? _inputShape(SampleReconstructInput i) => [
      for (final p in i.parts) [p.originSec, p.blob.toList()],
      i.maxOrder,
    ];

Object? _resultShape(({int originSec, List<double?> samples}) r) =>
    [r.originSec, r.samples];

void main() {
  test('the input crosses an isolate boundary with every field intact', () async {
    await expectIsolateRoundTrip<SampleReconstructInput>(
        sampleReconstructInput(maxOrder: 2),
        project: _inputShape);
  });

  test('the result crosses an isolate boundary with every field intact',
      () async {
    final r = sampleReconstructOracle(sampleReconstructInput());
    await expectIsolateRoundTrip<({int originSec, List<double?> samples})>(r,
        project: _resultShape);
  });

  test('the entry equals the decode + overlay oracle, full and coarse', () {
    for (final order in <int?>[null, 1]) {
      final input = sampleReconstructInput(maxOrder: order);
      final got = reconstructSamplePartsHeavy(sampleHeavyInputs, input);
      final want = sampleReconstructOracle(input);
      expect(jsonEncode(_resultShape(got)), jsonEncode(_resultShape(want)),
          reason: 'maxOrder $order');
      expect(got.originSec, 1790000000);
      expect(got.samples, hasLength(900), reason: 'parts span 1790000000..+900');
    }
  });

  test('a worker answers with what this isolate would produce', () async {
    final input = sampleReconstructInput();
    final here = jsonEncode(
        _resultShape(reconstructSamplePartsHeavy(sampleHeavyInputs, input)));
    final inWorker = jsonEncode(_resultShape(await Isolate.run(
        () => reconstructSamplePartsHeavy(sampleHeavyInputs, input))));
    expect(inWorker, here);
  });
}
