// `series.hr_curve` carries `n`, the count of valid (hr > 0) seconds behind each
// minute's mean, so a reader can tell a full minute from one stray second.
// Additive: `t` and `v` are unchanged (no kAlgoVersion bump).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  // A multiple of 60, so each minute below is one whole bucket.
  const t0 = 1786700040;

  Map<String, dynamic> bundleFor(List<int> hr) {
    final n = hr.length;
    final ts = <int>[for (var i = 0; i < n; i++) t0 + i];
    return deriveDayBundle(DayBundleInput(
      date: '2026-08-15',
      dayTsSec: ts,
      dayHr: hr,
      sleepTsSec: ts,
      sleepHr: hr,
      sleepRrTsMs: const [],
      sleepRrMs: const [],
      sleepSkinTemp: List<int>.filled(n, 0),
      sleepJson: {
        'tst_sec': n,
        'in_bed_sec': n,
        'unobserved_sec': 0,
        'window': {'onset_ms': t0 * 1000, 'offset_ms': (t0 + n) * 1000},
      },
      hypnoStages: List<String>.filled(n, 'light'),
      sleepOnsetSec: t0,
      sleepOffsetSec: t0 + n,
      profile: const {
        'age': 35,
        'sex': 'm',
        'weight_kg': 75,
        'height_cm': 178,
      },
    ).toJson());
  }

  test('each minute carries n, the count of its valid seconds', () {
    final hr = <int>[
      // Minute 0: 45 valid seconds at 60 bpm, 15 off-skin.
      for (var s = 0; s < 60; s++) s < 45 ? 60 : 0,
      // Minute 1: ONE valid second.
      for (var s = 0; s < 60; s++) s == 20 ? 80 : 0,
      // Minute 2: nothing valid, so no point at all (not a zero).
      for (var s = 0; s < 60; s++) 0,
      // Minute 3: all 60 valid.
      for (var s = 0; s < 60; s++) 70,
    ];
    final curve = ((bundleFor(hr)['series'] as Map)['hr_curve'] as List)
        .cast<Map>();
    expect(curve, hasLength(3));
    expect(curve[0], {'t': t0, 'v': 60, 'n': 45});
    expect(curve[1], {'t': t0 + 60, 'v': 80, 'n': 1});
    expect(curve[2], {'t': t0 + 180, 'v': 70, 'n': 60});
  });
}
