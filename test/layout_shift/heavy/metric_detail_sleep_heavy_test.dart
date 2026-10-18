// Heavy: MetricDetail('sleep') against a real export.
// Skipped unless LAYOUT_SHIFT_HEAVY=1 and LAYOUT_SHIFT_HEAVY_DB is set.
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/heavy_shift_run.dart';

void main() {
  heavyScreen('MetricDetail', [
    HeavyCase('MetricDetail sleep', () => const MetricDetail('sleep')),
  ]);
}
