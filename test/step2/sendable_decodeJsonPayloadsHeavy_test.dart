// ignore_for_file: file_names
// The @SendableShape boundary for the generic JSON lane (design 02 step 2).

import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/json_payload_lane.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import '../guards/support/sendability.dart';

void main() {
  const inputs = WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en');
  const decodeInput = JsonPayloadsInput(
    values: ['{"x":[1,null,"two"]}', '{bad'],
    encode: false,
  );

  test('JSON input values cross an isolate boundary intact', () async {
    await expectIsolateRoundTrip<JsonPayloadsInput>(
      decodeInput,
      project: (value) => [value.values, value.encode],
    );
  });

  test('JSON result values cross back intact', () async {
    const result = JsonPayloadsResult([
      {'x': [1, null, 'two']},
      null,
    ]);
    final back = await Isolate.run(() => result);
    expect(back.values, result.values);
  });

  test('the registered worker decodes and encodes JSON values', () async {
    final decoded = await Isolate.run(
      () => decodeJsonPayloadsHeavy(inputs, decodeInput),
    );
    expect(decoded.values, [
      {'x': [1, null, 'two']},
      null,
    ]);

    final encoded = await Isolate.run(
      () => decodeJsonPayloadsHeavy(
        inputs,
        const JsonPayloadsInput(values: [
          {'x': [1, null, 'two']},
        ], encode: true),
      ),
    );
    expect(encoded.values, ['{"x":[1,null,"two"]}']);
  });
}
