// TypicalMealTimes owns the local meal-clock preference. Caffeine comparisons
// use distinct dated observations; a missing outcome never becomes a zero.
import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../settings/settings_repository.dart';
import '../util/heavy.dart';

class ClockWindow {
  const ClockWindow(this.startMinute, this.endMinute);
  final int startMinute, endMinute;
  List<(int, int)> get segments => startMinute == endMinute ? []
      : startMinute < endMinute ? [(startMinute, endMinute)]
      : [(startMinute, 1440), (0, endMinute)];
  bool contains(int minute) => segments.any((s) => minute >= s.$1 && minute < s.$2);
}

class CaffeineDose {
  const CaffeineDose({required this.at, required this.mg});
  final DateTime at;
  final double mg;
}

class CaffeineDay {
  const CaffeineDay({required this.dayId, this.wakeAt, this.bedAt,
    this.doses = const [], this.residualDoses, this.firstRecordedAt, this.dosesComplete = true,
    this.afternoonDip, this.napsMinutes, this.restingHr,
    this.sleepLatencyMinutes, this.totalSleepMinutes});
  final String dayId;
  final DateTime? wakeAt, bedAt, firstRecordedAt;
  final List<CaffeineDose> doses;
  final List<CaffeineDose>? residualDoses;
  final bool dosesComplete;
  final double? afternoonDip, napsMinutes, restingHr;
  final double? sleepLatencyMinutes, totalSleepMinutes;
}

@SendableShape('Primitive scalar results; sendable_typicalCaffeineHeavy_test')
class CaffeineTimingSummary {
  const CaffeineTimingSummary({this.dayCount = 0, this.enoughDays = false,
    this.wakeDelayVsDip, this.wakeDelayVsNap, this.wakeDelayVsRestingHr,
    this.residualVsLatency, this.residualVsTotalSleep,
    this.pairedCounts = const {}, this.latestResidualMg});
  final int dayCount;
  final bool enoughDays;
  final double? wakeDelayVsDip, wakeDelayVsNap, wakeDelayVsRestingHr;
  final double? residualVsLatency, residualVsTotalSleep, latestResidualMg;
  final Map<String, int> pairedCounts;
}

@heavy
double residualCaffeineMgHeavy(List<CaffeineDose> doses, DateTime bedtime) =>
    doses.where((d) => !d.at.isAfter(bedtime) && d.mg.isFinite && d.mg > 0)
      .fold(0.0, (sum, d) => sum + d.mg * math.pow(.5,
          bedtime.difference(d.at).inMinutes / 300));

@heavy
CaffeineTimingSummary caffeineTimingSummaryHeavy(List<CaffeineDay> days) {
  final unique = {for (final d in days) d.dayId: d};
  final pairs = <String, List<(double, double)>>{
    for (final k in ['dip', 'nap', 'rhr', 'latency', 'sleep']) k: [],
  };
  var count = 0;
  double? latestResidual;
  String? latestDay;
  for (final d in unique.values) {
    final times = [if (d.firstRecordedAt != null) d.firstRecordedAt!,
      for (final dose in d.doses) if (dose.mg.isFinite && dose.mg > 0) dose.at]
      ..sort();
    if (times.isEmpty) continue;
    count++;
    void pair(String k, double? x, double? y) {
      if (x != null && y != null && x.isFinite && y.isFinite) pairs[k]!.add((x, y));
    }
    final first = d.firstRecordedAt ?? times.first;
    final delay = d.wakeAt != null && !first.isBefore(d.wakeAt!)
        ? first.difference(d.wakeAt!).inMinutes.toDouble() : null;
    pair('dip', delay, d.afternoonDip);
    pair('nap', delay, d.napsMinutes);
    pair('rhr', delay, d.restingHr);
    final residualDoses = d.residualDoses ?? d.doses;
    final residual = d.bedAt != null && d.dosesComplete && residualDoses.isNotEmpty &&
        residualDoses.every((dose) => dose.mg.isFinite && dose.mg > 0)
        ? residualCaffeineMgHeavy(residualDoses, d.bedAt!) : null;
    if (latestDay == null || d.dayId.compareTo(latestDay) > 0) {
      latestDay = d.dayId;
      latestResidual = residual;
    }
    pair('latency', residual, d.sleepLatencyMinutes);
    pair('sleep', residual, d.totalSleepMinutes);
  }
  // Engineering evidence floor, per outcome. No p-values or causal claim.
  double? correlation(String k) {
    final xs = pairs[k]!;
    if (xs.length < 14) return null;
    // Analytics owns the statistic; Edge only aligns and gates observations.
    return ana.spearmanRho([for (final p in xs) p.$1], [for (final p in xs) p.$2]);
  }
  return CaffeineTimingSummary(dayCount: count, enoughDays: count >= 14,
    wakeDelayVsDip: correlation('dip'), wakeDelayVsNap: correlation('nap'),
    wakeDelayVsRestingHr: correlation('rhr'), residualVsLatency: correlation('latency'),
    residualVsTotalSleep: correlation('sleep'), latestResidualMg: latestResidual,
    pairedCounts: {for (final e in pairs.entries) e.key: e.value.length});
}

class TypicalMealTimes {
  static const key = 'typical_large_meals_v1';
  static Future<List<int>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(key);
    if (raw == null) return [];
    final minutes = (jsonDecode(raw) as List).cast<int>();
    _validate(minutes);
    return minutes.toSet().toList()..sort();
  }
  static void _validate(List<int> minutes) {
    if (minutes.any((m) => m < 0 || m >= 1440)) {
      throw ArgumentError.value(minutes, 'minutes', 'Clock minutes must be 0–1439');
    }
  }
  static Future<void> save(List<int> minutes) async {
    _validate(minutes);
    final normalized = minutes.toSet().toList()..sort();
    await SettingsRepository.instance.update(
      (d) => d.setString(key, jsonEncode(normalized)), sections: const {});
  }
}
