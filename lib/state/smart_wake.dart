// Legacy Smart Wake's gate. Analytics owns signal calculations; Edge owns
// policy and alarm delivery. This never changes the band's fallback alarm.
import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as ana;
import '../util/heavy.dart';
import '../wake/wake_confounders.dart';

class SmartWakeSample {
  final double hr;
  final double ax, ay, az;
  const SmartWakeSample(this.hr, this.ax, this.ay, this.az);
  factory SmartWakeSample.fromRow(Map<String, Object?> row) => SmartWakeSample(
    (row['hr'] as num).toDouble(),
    (row['ax'] as num).toDouble(),
    (row['ay'] as num).toDouble(),
    (row['az'] as num).toDouble(),
  );
}

// Retained timestamp-free API for compatibility with existing callers/tests.
// Production legacy delivery uses the timestamped shared evidence below.
bool likelyLightSleep({
  required List<SmartWakeSample> baseline,
  required List<SmartWakeSample> recent,
  double hrArousalBpm = 4,
  double motionCeilingG = 0.08,
  int minBaselineSamples = 30,
  int minRecentSamples = 30,
}) {
  if (baseline.length < minBaselineSamples ||
      recent.length < minRecentSamples) {
    return false;
  }
  final baseHr = _median([for (final s in baseline) s.hr]);
  final recentHr = _mean([for (final s in recent) s.hr]);
  final recentMotion = _mean([for (final s in recent) _enmo(s)]);
  return recentHr >= baseHr + hrArousalBpm && recentMotion < motionCeilingG;
}

double _enmo(SmartWakeSample s) =>
    (math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az) - 1.0).abs();

double _mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;

double _median(List<double> xs) {
  final sorted = [...xs]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

bool lateWakeProtection({
  required int nowMs,
  required int endMs,
  required double baselineHr,
  required double recentHr,
  int minutes = 5,
}) =>
    endMs > nowMs &&
    endMs - nowMs <= minutes * 60000 &&
    (recentHr - baselineHr).abs() <= 2;

/// Engineering thresholds, see docs/wake-port-evidence.md. Missing or thin
/// evidence vetoes early delivery. The historical baseline is independent of
/// current baseline coverage; recent HR and motion still need their own floor.
@heavy
bool evaluateLegacyWakeHeavy(
  int nowMs,
  int endMs,
  List<Map<String, Object?>> rows,
  List<Map<String, Object?>> nights,
  ConfounderProfile profile, {
  double? nightMin,
  int? historyBeforeMs,
}) {
  if (profile.disableEarlyDelivery || nowMs >= endMs) return false;
  final hr = <List<double>>[], accel = <List<double>>[];
  for (final r in rows) {
    final ts = (r['rec_ts'] as num).toDouble() * 1000;
    final h = r['hr'] as num?;
    if (h != null) hr.add([ts, h.toDouble()]);
    final x = r['ax'] as num?, y = r['ay'] as num?, z = r['az'] as num?;
    if (x != null && y != null && z != null) {
      accel.add([ts, x.toDouble(), y.toDouble(), z.toDouble()]);
    }
  }
  final historical =
      nightMin ??
      precedingNightBaselineHeavy(
        nights,
        historyBeforeMs ?? nowMs - 3 * 3600000,
      );
  final baseline = ana.wakeHrBaseline(hr, nowMs, nightMin: historical).bpm;
  final recent = ana.wakeRecentHr(hr, nowMs);
  final motion = ana.wakeRecentEnmo(accel, nowMs);
  if (baseline == null || recent == null || motion == null) return false;
  if (lateWakeProtection(
    nowMs: nowMs,
    endMs: endMs,
    baselineHr: baseline,
    recentHr: recent,
    minutes: profile.protectionMinutes,
  )) {
    return false;
  }
  if (recent < baseline + profile.hrArousalBpm ||
      motion >= profile.motionCeilingG) {
    return false;
  }
  final baselineMotion = ana.wakeBaselineEnmo(accel, nowMs);
  final threshold =
      math.max(.02, .5 * (baselineMotion ?? 0)) * profile.trendThresholdFactor;
  return ana.wakeEnmoTrend(
        accel,
        nowMs,
        windowMinutes: profile.trendWindowMinutes,
        threshold: threshold,
      ) ==
      false;
}

/// Select by completed main-sleep time, not a calendar label. Engineering
/// freshness cap: preceding completion must be within 72 h of this onset.
/// A partial, skipped, provisional or unsupported/imported payload cannot
/// establish a measured baseline. A newer invalid night does not shadow a
/// usable preceding completed night within the cap.
@heavy
double? precedingNightBaselineHeavy(
  List<Map<String, Object?>> nights,
  int beforeMs,
) {
  int? latest;
  double? selected;
  for (final row in nights) {
    if (row['skipped'] != 0 ||
        row['partial'] != 0 ||
        row['finalized'] != 1 ||
        (row['source'] != null && row['source'] != 'band')) {
      continue;
    }
    try {
      final rawWindow = jsonDecode(row['window_json'] as String);
      if (rawWindow is! Map<String, dynamic>) continue;
      final window = rawWindow['value'] is Map<String, dynamic>
          ? rawWindow['value'] as Map<String, dynamic>
          : rawWindow;
      final on = (window['onset_ms'] as num?)?.toInt();
      final off = (window['offset_ms'] as num?)?.toInt();
      if (on == null ||
          off == null ||
          off <= on ||
          off > beforeMs ||
          beforeMs - off > 72 * 3600000 ||
          (latest != null && off <= latest)) {
        continue;
      }
      final payload = jsonDecode(row['payload_json'] as String);
      if (payload is! Map<String, dynamic> ||
          payload['imported'] == true ||
          (payload['source'] != null && payload['source'] != 'band')) {
        continue;
      }
      final scalars = payload['scalars'];
      if (scalars is! Map<String, dynamic>) continue;
      final value = (scalars['hr_min_night'] as num?)?.toDouble();
      if (value == null || !value.isFinite || value <= 30 || value >= 200) {
        continue;
      }
      latest = off;
      selected = value;
    } catch (_) {
      /* Unsupported historical evidence is absent. */
    }
  }
  return selected;
}
