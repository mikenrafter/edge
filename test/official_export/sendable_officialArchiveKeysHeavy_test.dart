// The worker guard requires this exact entry-symbol filename.
// ignore_for_file: file_names
// WHY: archive batching must retain complete live-second ownership and all
// prior archive keys across the worker boundary. CLAIM(export-input-identity).
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/worker.dart';

void main() {
  test('live and prior-archive key sets survive a worker round trip', () async {
    const live = OfficialRows([
      {'ts_ms': 1000},
      {'ts_ms': 2000},
      {'ts_ms': 1000},
    ]);
    const prior = OfficialRows([
      {'ts_ms': 2000},
      {'ts_ms': 3000},
    ]);
    final keys = await Isolate.run(
      () => officialArchiveKeysHeavy(exportWorkerInputs, live, prior),
    );
    expect(keys.live, {1000, 2000});
    expect(keys.archived, {2000, 3000});
  });
}
