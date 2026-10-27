import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/typical_day_model.dart';

import 'backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('daytime sleeper and wrapping windows keep their actual clock spans', () {
    const daytime = ClockWindow(8 * 60, 16 * 60);
    expect(daytime.segments, [(480, 960)]);
    expect(daytime.contains(8 * 60), isTrue);
    expect(daytime.contains(12 * 60), isTrue);
    expect(daytime.contains(16 * 60), isFalse);
    expect(daytime.contains(23 * 60), isFalse);
    const overnight = ClockWindow(23 * 60, 7 * 60);
    expect(overnight.segments, [(1380, 1440), (0, 420)]);
    expect(overnight.contains(0), isTrue);
    expect(overnight.contains(6 * 60), isTrue);
    expect(overnight.contains(12 * 60), isFalse);
    expect(const ClockWindow(480, 480).segments, isEmpty);
  });

  test('residual caffeine uses five-hour half-life and only earlier doses', () {
    final bed = DateTime.utc(2026, 10, 1, 22);
    // 100 mg ten hours earlier -> 25; 80 mg five hours earlier -> 40.
    expect(residualCaffeineMgHeavy([
      CaffeineDose(at: DateTime.utc(2026, 10, 1, 12), mg: 100),
      CaffeineDose(at: DateTime.utc(2026, 10, 1, 17), mg: 80),
      CaffeineDose(at: DateTime.utc(2026, 10, 1, 23), mg: 100),
    ], bed), closeTo(65, 1e-9));
    expect(residualCaffeineMgHeavy([], bed), 0);
  });

  List<CaffeineDay> history(int n, {bool missingSleep = false}) => [
    for (var i = 0; i < n; i++)
      CaffeineDay(dayId: '2026-10-${(i + 1).toString().padLeft(2, '0')}',
        wakeAt: DateTime.utc(2026, 10, i + 1, 7),
        bedAt: DateTime.utc(2026, 10, i + 1, 22),
        doses: [CaffeineDose(at: DateTime.utc(2026, 10, i + 1, 7, i * 5),
            mg: 100)],
        afternoonDip: i.toDouble(), napsMinutes: i * 2.0,
        restingHr: 55 + i.toDouble(),
        sleepLatencyMinutes: missingSleep ? null : 10 + i.toDouble(),
        totalSleepMinutes: missingSleep ? null : 480 - i * 2.0),
  ];

  test('few days report the observed count and abstain on every comparison', () {
    final s = caffeineTimingSummaryHeavy(history(3));
    expect(s.dayCount, 3);
    expect(s.enoughDays, isFalse);
    expect([s.wakeDelayVsDip, s.wakeDelayVsNap, s.wakeDelayVsRestingHr,
      s.residualVsLatency, s.residualVsTotalSleep], everyElement(isNull));
  });

  test('timing comparisons use first dose and observed paired outcomes', () {
    final s = caffeineTimingSummaryHeavy(history(21));
    expect(s.dayCount, 21);
    expect(s.enoughDays, isTrue);
    // First-dose delays and these outcomes rise linearly together.
    expect(s.wakeDelayVsDip, closeTo(1, 1e-9));
    expect(s.wakeDelayVsNap, closeTo(1, 1e-9));
    expect(s.wakeDelayVsRestingHr, closeTo(1, 1e-9));
    // Later intake leaves more residual, with longer latency and shorter TST.
    expect(s.residualVsLatency, greaterThan(0.99));
    expect(s.residualVsTotalSleep, lessThan(-0.99));
  });

  test('missing sleep and wake times never borrow another metric', () {
    final s = caffeineTimingSummaryHeavy(history(21, missingSleep: true));
    expect(s.wakeDelayVsDip, closeTo(1, 1e-9));
    expect(s.residualVsLatency, isNull);
    expect(s.residualVsTotalSleep, isNull);
    final noWake = caffeineTimingSummaryHeavy([
      for (var i = 0; i < 21; i++) CaffeineDay(dayId: 'day$i',
        bedAt: DateTime.utc(2026, 10, i + 1, 22),
        doses: [CaffeineDose(at: DateTime.utc(2026, 10, i + 1, 9), mg: 100)],
        afternoonDip: i.toDouble()),
    ]);
    expect(noWake.wakeDelayVsDip, isNull);
    expect(noWake.wakeDelayVsNap, isNull);
    expect(noWake.wakeDelayVsRestingHr, isNull);
  });

  test('duplicate days and constant observations cannot invent evidence', () {
    final d = history(1).single;
    final s = caffeineTimingSummaryHeavy(List.filled(30, d));
    expect(s.dayCount, 1);
    expect(s.enoughDays, isFalse);
    final same = caffeineTimingSummaryHeavy([
      for (var i = 0; i < 21; i++) CaffeineDay(dayId: 'day$i',
        wakeAt: DateTime.utc(2026, 10, i + 1, 7),
        bedAt: DateTime.utc(2026, 10, i + 1, 22),
        doses: [CaffeineDose(at: DateTime.utc(2026, 10, i + 1, 9), mg: 100)],
        afternoonDip: 2, sleepLatencyMinutes: 15),
    ]);
    expect(same.wakeDelayVsDip, isNull);
    expect(same.residualVsLatency, isNull);
  });

  test('an incomplete newest day never shows an older bedtime residual', () {
    final older = history(1).single;
    final latest = CaffeineDay(dayId: '2026-10-02',
      wakeAt: DateTime.utc(2026, 10, 2, 7),
      bedAt: DateTime.utc(2026, 10, 2, 22),
      firstRecordedAt: DateTime.utc(2026, 10, 2, 9),
      dosesComplete: false);
    expect(caffeineTimingSummaryHeavy([older]).latestResidualMg, 12.5);
    final summary = caffeineTimingSummaryHeavy([latest, older]);
    expect(summary.dayCount, 2);
    expect(summary.latestResidualMg, isNull);
    expect(summary.pairedCounts['latency'], 1);
  });

  test('each outcome needs fourteen pairs and invalid amounts abstain', () {
    final days = history(13);
    days.add(CaffeineDay(dayId: '2026-10-14',
      wakeAt: DateTime.utc(2026, 10, 14, 7),
      bedAt: DateTime.utc(2026, 10, 14, 22),
      firstRecordedAt: DateTime.utc(2026, 10, 14, 10),
      doses: [CaffeineDose(at: DateTime.utc(2026, 10, 14, 10), mg: double.nan)],
      napsMinutes: 30, sleepLatencyMinutes: 30));
    final summary = caffeineTimingSummaryHeavy(days);
    expect(summary.dayCount, 14);
    expect(summary.pairedCounts['nap'], 14);
    expect(summary.wakeDelayVsNap, isNotNull);
    expect(summary.pairedCounts['dip'], 13);
    expect(summary.wakeDelayVsDip, isNull);
    expect(summary.pairedCounts['latency'], 13);
    expect(summary.residualVsLatency, isNull);
    expect(summary.latestResidualMg, isNull);
  });

  test('rank comparisons follow a nonlinear ordered personal pattern', () {
    final summary = caffeineTimingSummaryHeavy([
      for (var i = 0; i < 14; i++) CaffeineDay(dayId: 'day$i',
        wakeAt: DateTime.utc(2026, 10, i + 1, 7),
        doses: [CaffeineDose(at: DateTime.utc(2026, 10, i + 1, 7, i + 1), mg: 100)],
        napsMinutes: (i * i).toDouble()),
    ]);
    // Both observations have identical ordering, despite the quadratic scale.
    expect(summary.wakeDelayVsNap, closeTo(1, 1e-9));
    expect(summary.pairedCounts['nap'], 14);
  });

  test('typical large meals persist locally, normalize, and survive restore', () async {
    final env = await BackupEnv.create('batch_b_typical_meals.db');
    addTearDown(env.dispose);
    expect(await TypicalMealTimes.load(), isEmpty);
    await TypicalMealTimes.save([19 * 60, 8 * 60, 8 * 60]);
    expect(await TypicalMealTimes.load(), [480, 1140]);
    await expectLater(TypicalMealTimes.save([-1]), throwsArgumentError);
    expect(await TypicalMealTimes.load(), [480, 1140]);
    await env.seedData();
    final path = await LocalDb.exportCopy();
    await env.wipe();
    expect(await TypicalMealTimes.load(), isEmpty);
    await LocalDb.importFromDbFile(path);
    expect(await TypicalMealTimes.load(), [480, 1140]);
    await TypicalMealTimes.save([]);
    expect(await TypicalMealTimes.load(), isEmpty);
    // It is a real preference, so a new reader sees the restored value.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isNotEmpty);
  });
}
