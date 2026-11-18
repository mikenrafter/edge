// ignore_for_file: file_names
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_ep_worker.dart';

import 'pulse_ep_fixture.dart';

void main() {
  // WHY: the analytics beat inputs and the immutable detection cross the send
  // boundary intact; a field lost in transit would change which window qualifies.
  test('beat inputs go in and an immutable detection comes back', () async {
    final rows = irregularRows(1794268800000, 25);
    final input = PulseDetectInput(
      source: 's',
      rows: rowMaps(rows),
      completeThroughMs: 1794268800000 + 35 * 60000,
      sourceStartMs: 1794268800000 - 3600000,
    );
    final detection = (await Isolate.run(() => detectPulseEpisodesHeavy(input))).detection;
    expect(detection.windows, isNotEmpty);
    expect(detection.episodes.first.beats.first.id, startsWith('s:'));
    expect(detection.episodes.first.source, 's');
  });
}
