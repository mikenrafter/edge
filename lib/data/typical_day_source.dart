// Bounded read adapter. The worker owns dated caffeine matching and comparisons;
// the repository remains the only reader of derived sleep/heart shapes.
import 'dart:isolate';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../util/heavy.dart';
import '../util/worker_init.dart';
import 'db.dart';
import 'day_label.dart';
import 'local_repository.dart';
import 'moment_label.dart';
import 'typical_day_model.dart';

@SendableShape('Primitive repository row maps; sendable_typicalCaffeineHeavy_test')
class TypicalCaffeineInput {
  const TypicalCaffeineInput(this.days, this.moments, this.totals, this.worker);
  final List<Map<String, Object?>> days, moments, totals;
  final WorkerInputs worker;
}

Future<CaffeineTimingSummary> loadTypicalCaffeine(LocalRepository repo,
    {DateTime? now}) async {
  final at = now ?? DateTime.now();
  final from = DateTime(at.year, at.month, at.day - 49);
  final to = DateTime(at.year, at.month, at.day + 1);
  final db = await LocalDb.instance;
  final moments = await db.query('track_event_feed',
    columns: ['date', 'at_ms', 'amount', 'unit'],
    where: "date >= ? AND date <= ? AND track_id = 'caffeine' AND source_kind <> 'journal'",
    whereArgs: [dayLabelOf(from), dayLabelOf(to)]);
  final totals = await db.query('journal_metric',
    where: "date >= ? AND date <= ? AND field = 'caffeine_mg'",
    whereArgs: [dayLabelOf(from), dayLabelOf(to)]);
  final days = <Map<String, Object?>>[];
  // At most 43 reads; never walk an unbounded history on screen open.
  for (var back = 42; back >= 0; back--) {
    final date = dayLabelOf(DateTime(at.year, at.month, at.day - back));
    days.add({'date': date, 'sleep': await repo.getDaySleepV2(date),
      'heart': await repo.getDayHeart(date)});
  }
  final input = TypicalCaffeineInput(days, moments, totals,
      WorkerInputs(nowEpochMs: at.millisecondsSinceEpoch,
        zoneId: at.timeZoneName, localeTag: 'en'));
  return Isolate.run(() => typicalCaffeineHeavy(input));
}

@heavy
CaffeineTimingSummary typicalCaffeineHeavy(TypicalCaffeineInput input) {
  WorkerInit.ensure(input.worker);
  assertWorker();
  Map map(Object? v) => v is Map ? v : const {};
  double? number(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
  DateTime? instant(Object? v) => v is num
      ? DateTime.fromMillisecondsSinceEpoch((v * 1000).round()) : null;
  final observations = <CaffeineDay>[];
  for (var i = 0; i + 1 < input.days.length; i++) {
    final row = input.days[i];
    final sleep = map(row['sleep']);
    final wake = instant(sleep['wake_ts']);
    if (wake == null || number(sleep['duration_min']) == null) continue;
    // Find the next *observed* onset, including a daytime sleeper's next date.
    Map? next;
    for (var j = i + 1; j < input.days.length; j++) {
      final candidate = map(input.days[j]['sleep']);
      final onset = instant(candidate['onset_ts']);
      if (onset != null && onset.isAfter(wake) &&
          number(candidate['duration_min']) != null) {
        next = input.days[j]; break;
      }
    }
    final nextSleep = map(next?['sleep']);
    final bed = instant(nextSleep['onset_ts']);
    if (bed == null || bed.difference(wake).inHours > 36) continue;
    final doses = <CaffeineDose>[];
    final residualDoses = <CaffeineDose>[];
    final residualFrom = bed.subtract(const Duration(days: 7));
    DateTime? first;
    var complete = true;
    final sums = <String, double>{};
    for (final m in input.moments) {
      final date = m['date'] as String;
      final at = m['at_ms'] is num
          ? DateTime.fromMillisecondsSinceEpoch((m['at_ms'] as num).toInt())
          : m['hhmm'] is String ? momentLocalTime(date, m['hhmm'] as String) : null;
      if (at == null && date.compareTo(dayLabelOf(residualFrom)) >= 0 &&
          date.compareTo(dayLabelOf(bed)) <= 0) {
        complete = false;
      }
      if (at == null || at.isBefore(residualFrom) || at.isAfter(bed)) continue;
      final inWake = !at.isBefore(wake);
      if (inWake && (first == null || at.isBefore(first))) first = at;
      final mg = m['unit'] != null && m['unit'] != 'mg' ? null : number(m.containsKey('amount') ? m['amount'] : m['caffeine_mg']);
      if (mg == null || mg <= 0) { complete = false; continue; }
      residualDoses.add(CaffeineDose(at: at, mg: mg));
      if (inWake) doses.add(CaffeineDose(at: at, mg: mg));
    }
    // A daily total may include un-timed intake. Only dates completely
    // accounted for by explicit dose moments support a residual estimate.
    for (final m in input.moments) {
      final date = m['date'] as String;
      sums[date] = (sums[date] ?? 0) + (m['unit'] != null && m['unit'] != 'mg' ? 0 : number(m.containsKey('amount') ? m['amount'] : m['caffeine_mg']) ?? 0);
    }
    for (final t in input.totals) {
      final date = t['date'] as String;
      if (date.compareTo(dayLabelOf(residualFrom)) < 0 || date.compareTo(dayLabelOf(bed)) > 0) continue;
      final total = number(t['value']);
      if (total != null && (total - (sums[date] ?? 0)).abs() > .01) complete = false;
    }
    if (first == null) continue;
    double? naps;
    final napWindows = <String>{};
    for (final source in [sleep, nextSleep]) {
      final periods = source['periods'];
      if (periods is! List) continue;
      for (final p in periods.whereType<Map>()) {
        if (p['is_main'] != false) continue;
        final onset = instant(p['onset_ts']);
        final minutes = number(p['duration_min']);
        if (onset != null && !onset.isBefore(wake) && onset.isBefore(bed) && minutes != null &&
            napWindows.add('${p['onset_ts']}/${p['wake_ts']}')) {
          naps = (naps ?? 0) + minutes;
        }
      }
    }
    final forecast = ana.alertnessForecast(wakeLocalHour: wake.hour + wake.minute / 60,
      sleepDurationHours: number(sleep['duration_min'])! / 60).value;
    double? afternoonDip;
    if (forecast != null) {
      final afternoon = <double>[];
      for (var k = 0; k < forecast.shape.length; k++) {
        final hour = (forecast.startHour + 18 * k / (forecast.shape.length - 1)) % 24;
        if (hour >= 12 && hour < 18) afternoon.add(forecast.shape[k]);
      }
      // A within-afternoon peak-to-trough span, shape units only. No
      // observations or interpolation are invented for unsupported hours.
      if (afternoon.length >= 2) {
        afternoonDip = afternoon.reduce((a,b) => a>b?a:b) - afternoon.reduce((a,b) => a<b?a:b);
      }
    }
    observations.add(CaffeineDay(dayId: row['date'] as String, wakeAt: wake,
      bedAt: bed, firstRecordedAt: first, doses: doses, residualDoses: residualDoses, dosesComplete: complete,
      afternoonDip: afternoonDip, napsMinutes: naps,
      restingHr: number(map(next?['heart'])['resting_hr']),
      sleepLatencyMinutes: number(nextSleep['sol_min']),
      totalSleepMinutes: number(nextSleep['duration_min'])));
  }
  return caffeineTimingSummaryHeavy(observations);
}
