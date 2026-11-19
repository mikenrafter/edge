// ignore_for_file: file_names
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_ep_worker.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_codec.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_types.dart';

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
  // WHY/R6: the metadata validator and its canonical import row cross the same
  // registered isolate boundary as decoding, including explicit unavailable state.
  test('validated import metadata and row survive the worker boundary', () async {
    final enc = encodePulseEvidence(const PulseEvidence(episodeId: 's:0', source: 's',
        startMs: 0, endMs: 1000, ongoing: false, beats: [])) as PulseEncoded;
    final input = PulseDecodeInput(enc.bytes, enc.checksum, importMeta: {
      'episode_id': 's:0', 'revision': 1, 'checksum': enc.checksum,
      'encoded_bytes': enc.encodedBytes, 'expanded_bytes': enc.expandedBytes,
      'created_ms': 1000,
    });
    final result = await Isolate.run(() => decodePulseEvidenceHeavy(input));
    expect(result.imported!.status, PulseEvidenceStatus.available);
    expect(result.imported!.row['payload'], enc.bytes);
    expect(result.imported!.row['retained_json'], '[[0,1000]]');
    expect(result.imported!.row['omitted_json'], '[]');
    final corrupt = PulseDecodeInput(enc.bytes, enc.checksum, importMeta: {
      ...input.importMeta!, 'episode_id': 'different',
    });
    final refusal = await Isolate.run(() => decodePulseEvidenceHeavy(corrupt));
    expect(refusal.imported!.status, PulseEvidenceStatus.corrupt);
    expect(refusal.imported!.reason, 'recording identity mismatch');
    expect(refusal.imported!.row.containsKey('payload'), isFalse);
  });

}
