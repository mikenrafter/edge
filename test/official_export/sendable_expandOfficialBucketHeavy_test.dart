// Worker guard requires the entry symbol in this exact filename.
// ignore_for_file: file_names
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/worker.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';

void main() {
  // WHY: grouping must preserve parent time keys and exact ordered beats in
  // the result actually received by the caller. CLAIM(export-input-identity).
  test(
    'archive parent and beat maps cross worker with exact keys and values',
    () async {
      final bucket = ArchiveBucket(
        (ArchiveTableBuilder()..addRows([
              {
                'device_id': 'A',
                'ts_ms': 1000,
                'rec_ts': 1,
                'counter': 7,
                'hr': null,
              },
            ]))
            .build(),
        (ArchiveTableBuilder()..addRows([
              {
                'device_id': 'A',
                'ts_ms': 1000,
                'rec_ts': 1,
                'beat_index': 0,
                'rr_ms': 952,
                'rr_ts_ms': 1000,
              },
              {
                'device_id': 'A',
                'ts_ms': 1000,
                'rec_ts': 1,
                'beat_index': 1,
                'rr_ms': 960,
                'rr_ts_ms': 1000,
              },
            ]))
            .build(),
      );
      final blob = SubstrateArchiveCodec.encode(bucket),
          fp = SubstrateArchiveCodec.fingerprint(bucket);
      final result = await Isolate.run(
        () => expandOfficialBucketHeavy(exportWorkerInputs, blob, 1, fp),
      );
      expect(result!.onehz, [
        {
          'device_id': 'A',
          'ts_ms': 1000,
          'rec_ts': 1,
          'counter': 7,
          'hr': null,
        },
      ]);
      expect(result.beats.keys, [1000]);
      expect(result.beats[1000]!.map((r) => r['rr_ms']).toList(), [952, 960]);
      expect(result.beats[1000]!.map((r) => r['beat_index']).toList(), [0, 1]);
    },
  );
}
