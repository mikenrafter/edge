// ignore_for_file: file_names
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_ep_worker.dart';

void main() {
  // WHY/R3: refusal normalization runs off the UI isolate, preserving unrelated
  // ranges and coalescing equal adjacent refusals with independent bounds.
  test('checkpoint refusal ranges cross the worker boundary', () async {
    const input = PulseRefusalInput('[{"start":0,"end":30,"reason":"pending"}]',
        '[{"start":10,"end":20,"reason":"timestamps"}]', 10, 20);
    final result = await Isolate.run(() => compactPulseRefusalsHeavy(input));
    expect(result.json, '[{"start":0,"end":10,"reason":"pending"},{"start":10,"end":20,"reason":"timestamps"},{"start":20,"end":30,"reason":"pending"}]');
  });
}
