import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:openstrap_edge/compute/onehz_pipeline.dart';

Map<String, dynamic> copyDay(Map<String, dynamic> input) =>
    jsonDecode(jsonEncode(input)) as Map<String, dynamic>;

/// Builds on the date and gen4 formulas documented in the existing synthetic
/// test/fixtures/two_device_day.json. A smooth seeded overnight RR trace adds
/// usable HRV to that fixture; it is synthetic and carries no ground truth.
Map<String, dynamic> incrementalDay({
  int seed = 42,
  int daySeconds = 901,
  int nightSeconds = 361,
  bool gaps = false,
  String sex = 'm',
}) {
  final spec =
      jsonDecode(File('test/fixtures/two_device_day.json').readAsStringSync())
          as Map;
  final base =
      DateTime.parse('${spec['day']}T00:00:00Z').millisecondsSinceEpoch ~/ 1000;
  final dayTs = <int>[], dayHr = <int>[];
  for (var i = 0; i < daySeconds; i++) {
    if (gaps && i >= 240 && i < 311) continue;
    dayTs.add(base + 8 * 3600 + i);
    // Includes rest, below-flex cadence walking, and high-HR priced minutes.
    dayHr.add(i % 97 == 96 ? 0 : [63, 95, 110, 148, 185][(i ~/ 60 + seed) % 5]);
  }
  final sleepTs = List.generate(nightSeconds, (i) => base + i);
  final sleepHr = List.generate(nightSeconds, (i) => 60 + ((base + i) % 7));
  final rr = <double>[], rrTs = <double>[];
  var t = base * 1000.0;
  for (var i = 0; t < (base + nightSeconds) * 1000; i++) {
    final r =
        940 + 47 * math.sin(i * .13 + seed * .003) + 13 * math.sin(i * .07);
    t += r;
    if (gaps && i == 113) t += 14000;
    rr.add(gaps && i % 149 == 148 ? 2100 : r);
    rrTs.add(t);
  }
  final stages = List.generate(
    nightSeconds,
    (i) => i % 181 < 150 ? 'nrem' : 'rem',
  );
  return DayBundleInput(
    date: spec['day'] as String,
    dayTsSec: dayTs,
    dayHr: dayHr,
    dayRrTsMs: rrTs,
    dayRrMs: rr,
    sleepTsSec: sleepTs,
    sleepHr: sleepHr,
    sleepRrTsMs: rrTs,
    sleepRrMs: rr,
    sleepSkinTemp: List.generate(nightSeconds, (i) => 30000 + (base + i) % 11),
    sleepJson: {
      'tst_sec': nightSeconds,
      'in_bed_sec': nightSeconds,
      'waso_sec': 0,
      'efficiency_pct': 100.0,
      'nrem_sec': stages.where((s) => s == 'nrem').length,
      'rem_sec': stages.where((s) => s == 'rem').length,
      'wake_sec': 0,
      'confidence': .8,
      'window': {
        'onset_ms': base * 1000,
        'offset_ms': (base + nightSeconds) * 1000,
      },
    },
    hypnoStages: stages,
    sleepOnsetSec: base,
    sleepOffsetSec: base + nightSeconds,
    profile: {
      'age': 35,
      'sex': sex,
      'weight_kg': 75,
      'height_cm': 178,
      'resting_hr': 54,
    },
    lnRmssdHistory: List.generate(14, (i) => 3.7 + (i % 5) * .03),
    rmssdHistory: List.generate(14, (i) => 40 + (i % 5) * 2.0),
    rhrHistory: List.generate(14, (i) => 60 + (i % 5) * .5),
    respHistory: List.generate(14, (i) => 13 + (i % 5) * .2),
    skinTempAdcHistory: List.generate(14, (i) => 30000 + (i % 5) * 2.0),
    deviceFamily: 'gen4',
    observedHrCeilingBpm: 186,
    dayConfidence: .8,
    stepSpans: [
      [base + 8 * 3600, base + 8 * 3600 + 240, 480],
    ],
    sleepSource: 'confirmed',
  ).toJson();
}

Map<String, dynamic> prefixDay(Map<String, dynamic> day, int seconds) {
  final result = copyDay(day);
  for (final key in ['day_ts', 'day_hr']) {
    result[key] = (result[key] as List).take(seconds).toList();
  }
  return result;
}
