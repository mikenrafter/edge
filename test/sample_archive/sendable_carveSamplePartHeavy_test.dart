// ignore_for_file: file_names
// Sendable round trip + parity for the sample archive's carve entry (design 02
// follow-up: the carve that `carveSamplePart` handed to `sampleCarveRunner` as an
// inline closure is the registered @heavy entry `carveSamplePartHeavy`).
//
// Pins: `SampleCarveInput` (the incoming blob, the covered minutes as a LIST, the
// part's valid count and error bounds) crosses into a worker and `SampleCarved?`
// comes back intact, null included; and the carve is BYTE-IDENTICAL to the
// existing `carveSamplePartSync` (blob and both error bounds).

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sample_heavy.dart';
import 'package:openstrap_edge/data/sample_import.dart';

import '../guards/support/sendability.dart';
import '../support/sample_heavy_fixtures.dart';

Object? _inputShape(SampleCarveInput i) =>
    [i.blob.toList(), i.coveredMinutes, i.valid, i.rmsErr, i.maxErr];

Object? _resultShape(SampleCarved? c) =>
    c == null ? null : [c.blob.toList(), c.nValid, c.rmsErr, c.maxErr];

SampleCarved? _oracle(SampleCarveInput i) => carveSamplePartSync(
      i.blob,
      i.coveredMinutes.toSet(),
      valid: i.valid,
      rmsErr: i.rmsErr,
      maxErr: i.maxErr,
    );

void main() {
  test('the input crosses an isolate boundary with every field intact', () async {
    await expectIsolateRoundTrip<SampleCarveInput>(sampleCarveInput(),
        project: _inputShape);
  });

  test('the result crosses an isolate boundary with every field intact',
      () async {
    final carved = _oracle(sampleCarveInput());
    expect(carved, isNotNull, reason: 'minutes 4 and 5 are not covered');
    await expectIsolateRoundTrip<SampleCarved?>(carved, project: _resultShape);
    await expectIsolateRoundTrip<SampleCarved?>(null);
  });

  test('the entry carves byte-identically to carveSamplePartSync', () {
    final input = sampleCarveInput();
    final got = carveSamplePartHeavy(sampleHeavyInputs, input);
    expect(jsonEncode(_resultShape(got)), jsonEncode(_resultShape(_oracle(input))));
    expect(got!.nValid, 120, reason: 'two uncovered minutes of 60 valid seconds');
  });

  test('nothing left to keep is null, as in the sync carve', () {
    final input = SampleCarveInput(
      blob: sampleCarveInput().blob,
      coveredMinutes: const [0, 1, 2, 3, 4, 5],
      valid: 360,
      rmsErr: 0.5,
      maxErr: 2.0,
    );
    expect(carveSamplePartHeavy(sampleHeavyInputs, input), isNull);
  });

  test('a worker answers with the bytes this isolate would produce', () async {
    final input = sampleCarveInput();
    final here =
        jsonEncode(_resultShape(carveSamplePartHeavy(sampleHeavyInputs, input)));
    final inWorker = jsonEncode(_resultShape(await Isolate.run(
        () => carveSamplePartHeavy(sampleHeavyInputs, input))));
    expect(inWorker, here);
    expect(inWorker, isNot('null'));
  });
}
