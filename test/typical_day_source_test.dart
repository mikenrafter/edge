import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/data/typical_day_source.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real journal moments retain amounts through backup and nocturnal cycle loader', () async {
    final env = await BackupEnv.create('typical_doses.db');
    addTearDown(env.dispose);
    Future<void> night(String day, DateTime onset, DateTime wake, {bool nap = false}) async {
      await LocalDb.putDayResult(dayId: day, algoVersion: 1, windowJson: '{}',
        payloadJson: jsonEncode({
          'scalars': {'tst_min': 480, 'rhr': 55, 'sol_min': 12},
          'sleep': {
            'window': {'value': {'onset_ms': onset.millisecondsSinceEpoch,
              'offset_ms': wake.millisecondsSinceEpoch, 'spt_sec': 8 * 3600}},
            'accounting': {'value': {'tst_sec': 8 * 3600, 'efficiency_pct': 100}},
          },
          'sleep_periods': {'periods': [
            {'is_main': true, 'onset_ts': onset.millisecondsSinceEpoch ~/ 1000,
              'wake_ts': wake.millisecondsSinceEpoch ~/ 1000, 'duration_min': 480},
            if (nap) {'is_main': false,
              'onset_ts': DateTime(2026,10,1,22).millisecondsSinceEpoch ~/ 1000,
              'wake_ts': DateTime(2026,10,1,22,30).millisecondsSinceEpoch ~/ 1000,
              'duration_min': 30},
          ], 'total_asleep_min': nap ? 510 : 480},
        }));
    }
    await night('2026-10-01', DateTime(2026,10,1,8), DateTime(2026,10,1,16), nap: true);
    await night('2026-10-02', DateTime(2026,10,2,8), DateTime(2026,10,2,16));
    const writer = MomentAnswerWriter();
    await writer.answer(const PendingMoment(date:'2026-10-01', hhmm:'22:00'), MomentChoice.caffeine, value: 100);
    await writer.answer(const PendingMoment(date:'2026-10-02', hhmm:'03:00'), MomentChoice.caffeine, value: 80);
    final labels = await LocalDb.momentLabels(date: '2026-10-01');
    expect(labels.single.caffeineMg, 100);
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    expect((await repo.getDaySleepV2('2026-10-02'))['sol_min'], 12);
    final summary = await loadTypicalCaffeine(repo, now: DateTime(2026,10,2,18));
    expect(summary.dayCount, 1);
    // Bed 08:00: 100 mg at 22:00 -> 25 mg; 80 mg at 03:00 -> 40 mg.
    expect(summary.latestResidualMg, closeTo(65, 1e-9));
    expect(summary.pairedCounts['nap'], 1);
    expect(summary.pairedCounts['latency'], 1);
    expect(summary.residualVsLatency, isNull);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.importFromDbFile(path);
    expect((await LocalDb.momentLabels(date: '2026-10-02')).single.caffeineMg, 80);
    expect((await loadTypicalCaffeine(repo, now: DateTime(2026,10,2,18))).latestResidualMg,
      closeTo(65, 1e-9));

    // A historic total with a timed label has no known per-dose amount.
    await LocalDb.putMomentLabel(const MomentLabel(date:'2026-10-01', hhmm:'20:00',
      label:'caffeine', answeredAtMs:1));
    await LocalDb.putJournalMetrics('2026-10-01', {
      'caffeine_mg': const JournalMetricValue(200, atMinuteOfDay: 22 * 60),
    });
    final incomplete = await loadTypicalCaffeine(repo, now: DateTime(2026,10,2,18));
    expect(incomplete.dayCount, 1);
    expect(incomplete.latestResidualMg, isNull);
    expect(incomplete.pairedCounts['latency'], 0);
  });
}
