// Run diagnostics are retained in the research logs.
// ignore_for_file: avoid_print
import 'dart:math';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'pulse_fixes_worker_test.dart' as f;
import 'pulse_band_fixture.dart';
import 'backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // WHY/CLAIM(pulse-respiratory-residual): a confirmed sleep label must not retract independent irregularity.
  // # catches: matching respiratory peaks used as sufficient semantic exclusion.
  test(
    'late sleep must not erase independent irregularity with mild respiratory modulation',
    () async {
      final env = await BackupEnv.create('pulse-residual-worker.db');
      try {
        await PulseEpisodeWorker.run(
          [],
          processingContext: ProcessingContext.reanalysis,
        );
        final db = await LocalDb.instance, random = Random(0);
        var t = 0;
        final rr = <int>[];
        while (t < 1200000) {
          final noise = 120 * (2 * random.nextDouble() - 1);
          final value = t >= 300000 && t < 900000
              ? (60000 / 52 + noise + 50 * sin(2 * pi * .25 * t / 1000)).round()
              : (60000 / 52).round();
          rr.add(value);
          t += value;
        }
        await insertRows(db, f.pulseFixRows(rr, minutes: 20));
        Future<void> run() async {
          final r = await PulseEpisodeWorker.run([
            '2026-11-10',
          ], processingContext: ProcessingContext.reanalysis);
          expect(r.failedDays, isEmpty);
        }

        await run();
        final store = PulseEpisodeStore(db);
        final prior = await store.list();
        expect(prior, hasLength(1));
        final id = prior.single.id;
        final before = await db.query('pulse_episode_outbox');
        await f.pulseFixContext(motion: 0.006, wrist: 1, minutes: 20);
        await run();
        final row = (await store.get(id))!.row;
        final after = await db.query('pulse_episode_outbox');
        print(
          'WORKER_LOSS ${jsonEncode({'status': row['status'], 'before': before, 'after': after})}',
        );
        expect(
          await store.list(),
          hasLength(1),
          reason:
              'independent irregular component remains present after sleep is confirmed',
        );
      } finally {
        await env.dispose();
      }
    },
  );
}
