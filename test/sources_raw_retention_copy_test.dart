// The rebuild-cost copy names how many days of raw readings the phone keeps.
// The view cannot import compute/, so it holds its own constant; this keeps it
// equal to the engine's.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show rawRetentionDays;
import 'package:openstrap_edge/ui2/sources/source_priority_view.dart' show kRebuildRawDays;

void main() {
  test('rebuild copy states the real raw retention', () {
    expect(kRebuildRawDays, rawRetentionDays);
  });
}
