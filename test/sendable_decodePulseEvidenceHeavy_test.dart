// ignore_for_file: file_names
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_ep_worker.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_codec.dart';

void main() {
  // WHY: a sealed read result, including the failure variants, survives the send.
  test('bytes in, a sealed read result out; a bad checksum is corrupt in the worker', () async {
    final enc = encodePulseEvidence(PulseEvidence(
      episodeId: 's:0', source: 's', startMs: 0, endMs: 1000, ongoing: false,
      beats: const [PulseBeat(recordTsMs: 0, beatIndex: 0, ordinal: 0, timeMs: 0, originalTimeMs: 0, rawMs: 800)],
    )) as PulseEncoded;
    final bytes = enc.bytes, sum = enc.checksum;
    final ok = (await Isolate.run(() => decodePulseEvidenceHeavy(PulseDecodeInput(bytes, sum)))).read;
    expect(ok, isA<PulseEvidenceAvailable>());
    final bad = (await Isolate.run(() => decodePulseEvidenceHeavy(PulseDecodeInput(bytes, 'x')))).read;
    expect(bad, isA<PulseEvidenceCorrupt>());
  });
}
