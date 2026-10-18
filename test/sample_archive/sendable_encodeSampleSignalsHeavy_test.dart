// ignore_for_file: file_names
// Sendable round trip + parity for the sample archive's encode entry (design 02
// follow-up: the encode that was an inline `Isolate.run` closure in
// `SampleArchiver._archiveDevice` is the registered @heavy entry
// `encodeSampleSignalsHeavy`).
//
// Pins: `SampleEncodeInput` (per-signal slots as Float64List with NaN gaps, and
// the resolved codec modes) crosses into a worker and the per-signal encoded
// parts come back intact; and the blobs the entry produces are BYTE-IDENTICAL to
// `SampleCodec.encode` on the same slots (the code the entry replaces), on this
// isolate and in a worker.

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sample_heavy.dart';

import '../guards/support/sendability.dart';
import '../support/sample_heavy_fixtures.dart';

Object? _inputShape(SampleEncodeInput i) => [
      for (final e in i.slots.entries) [e.key, e.value.toList().map((v) => '$v').toList()],
      for (final e in i.modes.entries) [e.key, e.value.name],
    ];

Object? _resultShape(Map<String, SampleEncodedPart> r) => [
      for (final e in r.entries)
        [e.key, e.value.blob.toList(), e.value.nValid, e.value.rmsErr, e.value.maxErr],
    ];

void main() {
  test('the input crosses an isolate boundary with every field intact', () async {
    await expectIsolateRoundTrip<SampleEncodeInput>(sampleEncodeInput(),
        project: _inputShape);
  });

  test('the result crosses an isolate boundary with every field intact',
      () async {
    final result = sampleEncodeOracle(sampleEncodeInput());
    await expectIsolateRoundTrip<Map<String, SampleEncodedPart>>(result,
        project: _resultShape);
  });

  test('the entry\'s blobs are byte-identical to SampleCodec.encode', () {
    final input = sampleEncodeInput();
    final got = encodeSampleSignalsHeavy(sampleHeavyInputs, input);
    expect(jsonEncode(_resultShape(got)),
        jsonEncode(_resultShape(sampleEncodeOracle(input))));
    expect(got.keys.toSet(), input.slots.keys.toSet());
  });

  test('a worker answers with the bytes this isolate would produce', () async {
    final input = sampleEncodeInput();
    final here = jsonEncode(
        _resultShape(encodeSampleSignalsHeavy(sampleHeavyInputs, input)));
    final inWorker = jsonEncode(_resultShape(await Isolate.run(
        () => encodeSampleSignalsHeavy(sampleHeavyInputs, input))));
    expect(inWorker, here);
  });
}
