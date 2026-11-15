// Worker guard requires the entry symbol in this exact filename.
// ignore_for_file: file_names
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/official_export/worker.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';

void main() {
  // WHY: report labels use the shared local-day API after the actual boundary.
  // CLAIM(export-input-identity). Noon avoids dependence on the runner's zone.
  test('local coverage labels cross worker as calendar dates', () async {
    final instant = DateTime(2026, 11, 1, 12).millisecondsSinceEpoch ~/ 1000;
    final input = OfficialRows([
      {'rec_ts': instant},
    ]);
    final days = await Isolate.run(
      () => officialCoveredDaysHeavy(exportWorkerInputs, input),
    );
    expect(days, ['2026-11-01']);
    expect(days.single, dayLabelOf(DateTime(2026, 11, 1, 12)));
  });
}
