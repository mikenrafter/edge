import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'backup/backup_support.dart';
import 'pulse_band_fixture.dart';
import 'pulse_sleep_rr_fixture.dart';

final pulseFixStart = DateTime(2026, 11, 10, 2).millisecondsSinceEpoch;

List<Map<String, Object?>> pulseFixRows(List<int> rr) {
  var time = pulseFixStart, i = 0;
  final rows = <Map<String, Object?>>[];
  while (time < pulseFixStart + 25 * 60000) {
    final value = rr[i % rr.length];
    time += value;
    rows.add({'device_id': '', 'ts_ms': time, 'rec_ts': time ~/ 1000,
      'beat_index': 0, 'rr_ts_ms': time, 'beat_ts_ms': time, 'rr_ms': value});
    i++;
  }
  return rows;
}

Future<void> pulseFixContext({bool sleep = true, double? motion, int? wrist}) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var t = pulseFixStart; t < pulseFixStart + 25 * 60000; t += 1000) {
    batch.insert('decoded_onehz', {'device_id': '', 'ts_ms': t, 'rec_ts': t ~/ 1000,
      'counter': t ~/ 1000, 'hr': 52, 'band_sleep_state': sleep ? 2 : 0,
      'dyn_accel_g': motion, 'on_wrist': wrist});
  }
  await batch.commit(noResult: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('pulse-fixes.db'));
  setUp(() async {
    await env.wipe();
    await PulseEpisodeWorker.run([], processingContext: ProcessingContext.reanalysis);
  });
  tearDownAll(() => env.dispose());
  Future<List<PulseEpisodeSnapshot>> run() async {
    final result = await PulseEpisodeWorker.run(['2026-11-10'],
      processingContext: ProcessingContext.reanalysis);
    expect(result.failedDays, isEmpty);
    return PulseEpisodeStore(await LocalDb.instance).list();
  }
  for (var i = 0; i < sleepRrFixtures.length; i++) {
    // WHY/CLAIM(pulse-sleep-pattern): the fixed thresholds flagged breathing variation.
    // # catches: ignoring sleep context or applying only the old metric thresholds.
    test('sleep RR capture ${i + 1} does not qualify', () async {
      await insertRows(await LocalDb.instance, pulseFixRows(sleepRrFixtures[i]));
      await pulseFixContext(motion: 0.006, wrist: 1);
      expect(await run(), isEmpty);
    });
  }
  // WHY/CLAIM(pulse-sleep-pattern): low heart rate alone must not hide irregularity.
  // # catches: suppressing all sleeping windows or refusing missing context.
  test('uncorrelated irregular low-HR sleep with unknown wear still alerts', () async {
    final random = Random(53);
    await insertRows(await LocalDb.instance,
      pulseFixRows(List.generate(5000, (_) => 950 + random.nextInt(400))));
    await pulseFixContext(motion: 0.006);
    final episodes = await run();
    expect(episodes, hasLength(1));
    expect(episodes.single.alertReason, isNot('recording quality'));
  });
  // WHY/CLAIM(pulse-context): only positive motion/wear evidence suppresses.
  // # catches: leaving the motion and wear inputs unwired.
  for (final kind in ['moving', 'off-wrist']) {
    test('$kind irregular series is suppressed', () async {
      final random = Random(53);
      await insertRows(await LocalDb.instance,
        pulseFixRows(List.generate(5000, (_) => 950 + random.nextInt(400))));
      await pulseFixContext(motion: kind == 'moving' ? 0.2 : 0.006,
        wrist: kind == 'off-wrist' ? 0 : 1);
      expect(await run(), isEmpty);
    });
  }
}
