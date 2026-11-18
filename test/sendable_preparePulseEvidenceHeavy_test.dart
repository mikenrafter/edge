// ignore_for_file: file_names
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/pulse_ep_worker.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_codec.dart';

import 'pulse_ep_fixture.dart';

void main() {
  // WHY: encoded bytes, checksum and the retained evidence cross back whole.
  test('an immutable detection becomes bounded compressed evidence', () async {
    final t0 = 1794268800000;
    final detection = ana.detectPulseEpisodes(beatInputs('s', irregularRows(t0, 25)),
        completeThroughMs: t0 + 35 * 60000, sourceStartMs: t0 - 3600000);
    final prepared = await Isolate.run(() => preparePulseEvidenceHeavy(PulsePrepareInput(detection)));
    final enc = prepared.episodes.values.first as PulseEncoded;
    expect(enc.encodedBytes, lessThanOrEqualTo(kPulseEvidenceMaxBytes));
    expect(enc.checksum, hasLength(64));
    expect(enc.evidence.beats, isNotEmpty);
  });
}
