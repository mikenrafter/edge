// Worker guard requires the entry symbol in this exact filename.
// ignore_for_file: file_names
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/worker.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';

void main() {
  // WHY: a blob must cross the actual worker boundary as bytes, and NULL
  // must not collide with zero or empty text. CLAIM(export-typed-hash).
  test(
    'typed row hash survives worker boundary without conflating storage classes',
    () async {
      final input = OfficialRows([
        {
          'a': null,
          'b': 0,
          'c': 0.0,
          'd': '',
          'e': Uint8List.fromList([0, 255]),
        },
      ]);
      final columns = ['a', 'b', 'c', 'd', 'e'];
      final digest = await Isolate.run(
        () => hashOfficialRowsHeavy(exportWorkerInputs, input, columns, 'seed'),
      );
      final changed = OfficialRows([
        {
          'a': 0,
          'b': 0,
          'c': 0.0,
          'd': '',
          'e': Uint8List.fromList([0, 255]),
        },
      ]);
      final other = await Isolate.run(
        () =>
            hashOfficialRowsHeavy(exportWorkerInputs, changed, columns, 'seed'),
      );
      expect(digest, hasLength(64));
      expect(digest, isNot(other));
      final again = await Isolate.run(
        () => hashOfficialRowsHeavy(exportWorkerInputs, input, columns, 'seed'),
      );
      expect(again, digest);
    },
  );
}
