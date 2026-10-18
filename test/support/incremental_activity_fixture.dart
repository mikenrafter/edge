import 'dart:math' as math;
import 'package:openstrap_edge/compute/substrate.dart';
import 'incremental_day_fixture.dart';

/// HR/axis fixture follows daily_energy_consistency_test's hand-built substrate
/// approach. The existing documented synthetic day supplies timestamps and HR;
/// axis rotation and smooth RR are added to exercise motion and rolling curves.
Substrate incrementalActivity({
  int seed = 42,
  int seconds = 601,
  bool gaps = false,
  String? family = 'gen4',
  bool moving = true,
  bool missingAccel = false,
}) {
  final input = incrementalDay(seed: seed, daySeconds: seconds, gaps: gaps);
  final ts = (input['day_ts'] as List).cast<int>();
  final hr = (input['day_hr'] as List).cast<int>();
  final rr = <double>[], rrTs = <double>[];
  if (ts.isNotEmpty) {
    var t = ts.first * 1000.0;
    for (var i = 0; t < (ts.last + 1) * 1000; i++) {
      final value = 940 + 43 * math.sin(i * .13 + seed * .003);
      t += value;
      if (gaps && i == 239) t += 31000;
      rr.add(i % 151 == 150 ? 2200 : value);
      rrTs.add(t);
    }
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: rrTs,
    rrMs: rr,
    ax: List.generate(
      ts.length,
      (i) => !moving || missingAccel ? 0 : .16 * math.sin(i * .27),
    ),
    ay: List.generate(
      ts.length,
      (i) => !moving || missingAccel ? 0 : .09 * math.cos(i * .17),
    ),
    az: List.generate(
      ts.length,
      (i) => missingAccel
          ? 0
          : moving
          ? 1.0 + .03 * math.sin(i * .09)
          : 1.0,
    ),
    spo2Red: List.filled(ts.length, 0),
    spo2Ir: List.filled(ts.length, 0),
    skinTemp: List.filled(ts.length, 30000),
    skinContact: List.filled(ts.length, 0),
    deviceFamily: family,
  );
}
