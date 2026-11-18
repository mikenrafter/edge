// ignore_for_file: file_names
// WHY: CLAIM(official-export-unit-keys) also depends on real sendability of
// nullable SQL values, BLOBs, projected rows and the manifest across isolates.
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/mapping_worker.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:openstrap_edge/util/raw_readers.dart';

void main() {
  test('actual projection inputs and outputs cross the registered worker', () async {
    final input = MappingInput('page', 'journal_field_def', const [
      {'__export_rowid': -2, 'key': 'custom_é', 'label': 'Dose', 'unit': 'g',
       'kind': 'dose', 'created_at': 1, 'max_value': 10.0, 'step': 0.1, 'has_time': 0},
    ]);
    final out = await Isolate.run(() => officialMappingHeavy(
        const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'), input));
    expect(out.rows.single['key'], 'custom_u1_637573746f6d5fc3a9_67');
    expect(out.rows.single['max_value'], 10.0);
    expect(out.notes.single['key_map'], {'original': 'custom_é', 'mapped': 'custom_u1_637573746f6d5fc3a9_67', 'unit': 'g'});
    final raw = MappingInput('page', 'raw_archive_legacy', [
      {'__export_rowid': 1, 'device_id': '', 'hex': 'aa01', 'counter': null,
       'packet_type': 36, 'rec_ts': null, 'captured_at': 1, 'reason': 'unknown'},
    ]);
    final frame = await Isolate.run(() => officialMappingHeavy(mappingWorkerInputs, raw));
    expect(frame.rows.single['frame'], Uint8List.fromList([0xaa, 1]));
    expect(frame.rows.single['rec_ts'], isNull);
    final metadataInput=MappingInput('keys','',const [],batch:RowBatch<Map<String,Object?>>.wrap([{'cursor':-1,'device_id':'ring','ts_ms':1234}]));
    final metadata=await Isolate.run(()=>officialMappingHeavy(mappingWorkerInputs,metadataInput));
    expect(metadata.rows,[{'cursor':-1,'device_id':'ring','ts_ms':1234}]);
  });
}
