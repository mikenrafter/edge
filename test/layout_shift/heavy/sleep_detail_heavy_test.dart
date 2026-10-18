// Heavy: SleepDetail against a real export (see support/heavy_db_fixture.dart).
// Skipped unless LAYOUT_SHIFT_HEAVY=1 and LAYOUT_SHIFT_HEAVY_DB is set.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/heavy_db_fixture.dart';
import '../../support/heavy_shift_run.dart';

void main() {
  heavyScreen('SleepDetail', [
    // Yesterday = the export's newest day after re-dating.
    HeavyCase('SleepDetail yesterday', () => SleepDetail(day: yesterdayLabel()),
        // The rough-night read only runs when the shown day IS today, and the
        // re-dated export ends yesterday; time it on its own.
        after: (repo) async {
      await loadRoughNight(repo, yesterdayLabel());
    }),
    // No day: today, which also runs the rough-night read.
    HeavyCase('SleepDetail today', () => const SleepDetail()),
    // Synthetic: a writer committing 10k-row replaces back to back while the
    // page loads (a drain landing as the user opens it).
    HeavyCase('SleepDetail yesterday + concurrent ingest writer',
        () => SleepDetail(day: yesterdayLabel()),
        prepare: startIngestWriter),
    // Synthetic: the same, but each round is one held-open transaction (what a
    // band chunk commit looks like to a reader).
    HeavyCase('SleepDetail yesterday + concurrent ingest transaction',
        () => SleepDetail(day: yesterdayLabel()),
        prepare: startIngestTxnWriter),
  ]);

  // Parity on the real export: the combined read is the per-key getChart path,
  // value for value (absent series included), for both the as-is and the
  // cloned-weeks database.
  for (final weeks in const [0, 5]) {
    group('SleepDetail bundle parity [weeks: $weeks]', () {
      late HeavyDb db;
      setUpAll(() async {
        TestWidgetsFlutterBinding.ensureInitialized();
        db = await openHeavyDb(weeks: weeks, name: 'ls_heavy_sleep_parity_w$weeks.db');
      });
      tearDownAll(() => db.dispose());
      test('bundle charts equal getChart per key', () async {
        const keys = [
          'sleep', 'deep', 'efficiency', 'unobserved_min', 'awakenings',
          'longest_sleep_min', 'sol_min',
        ];
        final repo = LocalRepositoryImpl(getProfileMap: () => const {});
        final b = await repo.getSleepDetailBundle(yesterdayLabel(),
            chartKeys: keys, windowDays: 29);
        for (final k in keys) {
          expect(jsonEncode(b.charts[k]), jsonEncode(await repo.getChart(k)),
              reason: k);
        }
        expect(jsonEncode(b.windows), jsonEncode(await repo.sleepWindows(days: 29)));
      }, skip: heavySkipReason() != null);
    }, skip: heavySkipReason() != null);
  }
}
