// ONE name per metric. The table lives in lib/ui2/metric_labels.dart
// and Home and Health both read it, so "Resting heart rate" cannot be "Heart
// rate · Resting" on one screen and something else on the next (AGENTS.md
// 4.10). This file is separate from the screen tests on purpose: it is the only
// one that imports the new file, so the screen tests still compile and fail for
// their own reasons before the table exists.
//
// API assumed (the spec says "e.g."): `MetricLabels` with static const English
// strings. If the table is named differently, rename here and nowhere else.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/metric_labels.dart';

void main() {
  test('the shared table holds the one name per metric', () {
    expect(MetricLabels.restingHr, 'Resting heart rate');
    expect(MetricLabels.hrv, 'HRV');
    expect(MetricLabels.sleep, 'Sleep');
    expect(MetricLabels.daytimeSleep, 'Daytime sleep');
    expect(MetricLabels.respRate, 'Respiratory rate');
    expect(MetricLabels.stress, 'Stress');
    expect(MetricLabels.overnightStress, 'Overnight stress');
    expect(MetricLabels.skinTemp, 'Skin temperature');
    expect(MetricLabels.strain, 'Strain');
    expect(MetricLabels.steps, 'Steps');
  });

  test('"Time asleep" exists only as a sub-label, never as the Sleep name', () {
    expect(MetricLabels.timeAsleep, 'Time asleep');
    expect(MetricLabels.sleep, isNot(MetricLabels.timeAsleep));
  });

  test('no two metrics share a name', () {
    final names = [
      MetricLabels.restingHr,
      MetricLabels.hrv,
      MetricLabels.sleep,
      MetricLabels.daytimeSleep,
      MetricLabels.respRate,
      MetricLabels.stress,
      MetricLabels.overnightStress,
      MetricLabels.skinTemp,
      MetricLabels.strain,
      MetricLabels.steps,
    ];
    expect(names.toSet().length, names.length);
  });
}
