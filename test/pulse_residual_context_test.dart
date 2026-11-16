// Run diagnostics are retained in the research logs.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'pulse_fixes_worker_test.dart' as f;
import 'pulse_band_fixture.dart';
import 'pulse_sleep_rr_fixture.dart';
import 'backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // WHY: a genuine semantic exclusion still retires a current episode and cancels unclaimed debt.
  // # catches: the residual guard accidentally disabling late-context retraction or damaging consumed delivery.
  for (final kind in ['sleep', 'motion', 'offWrist', 'charging']) {
    for (final delivered in [false, true]) {
      test(
        'actual worker converges after late $kind with delivered=$delivered',
        () async {
          final env = await BackupEnv.create(
            'pulse-residual-late-$kind-$delivered.db',
          );
          try {
            // Initialize before ingest, so the trace is newly eligible for delivery.
            final first = await PulseEpisodeWorker.run(
              [],
              processingContext: ProcessingContext.reanalysis,
            );
            expect(first.failedDays, isEmpty);
            final db = await LocalDb.instance;
            final store = PulseEpisodeStore(db);
            await insertRows(db, f.pulseFixRows(sleepRrFixtures.first));
            Future<void> run() async {
              final r = await PulseEpisodeWorker.run([
                '2026-11-10',
              ], processingContext: ProcessingContext.reanalysis);
              expect(r.failedDays, isEmpty);
              expect(r.retryDays, isEmpty);
            }

            await run();
            final prior = await store.list();
            expect(prior, hasLength(1));
            final id = prior.single.id;
            // Recovery debt must be canceled as well as fresh owed debt.
            await db.update('pulse_episode_outbox', {
              'state': 'not_sent',
              'reason': 'notifications off',
            });
            if (delivered) {
              final ids = await store.claim([id], token: 'r2', nowMs: 1);
              expect(ids, [id]);
              await store.finish(ids, token: 'r2', state: 'sent', nowMs: 2);
            }
            final consumed = jsonEncode(await db.query('pulse_episode_outbox'));
            final evidence = [
              for (final table in [
                'pulse_episode_revision',
                'pulse_evidence_chunk',
                'pulse_episode_alias',
              ])
                jsonEncode(await db.query(table)),
            ];
            if (kind == 'sleep') {
              await f.pulseFixContext(motion: 0.006, wrist: 1);
            }
            if (kind == 'motion') {
              await f.pulseFixContext(sleep: false, motion: 0.2, wrist: 1);
            }
            if (kind == 'offWrist') {
              await f.pulseFixContext(sleep: false, motion: 0.006, wrist: 0);
            }
            if (kind == 'charging') {
              await db.insert('band_events', {
                'device_id': '',
                'hex': 'charging',
                'event_id': proto.EventId.chargingOn,
                'name': 'CHARGING_ON',
                'ts': f.pulseFixStart ~/ 1000 - 60,
                'captured_at': 0,
              });
            }
            await run();
            expect(await store.list(), isEmpty);
            expect((await store.get(id))!.row['status'], 'retracted');
            expect(await store.owed(), isEmpty);
            expect([
              for (final table in [
                'pulse_episode_revision',
                'pulse_evidence_chunk',
                'pulse_episode_alias',
              ])
                jsonEncode(await db.query(table)),
            ], evidence);
            if (delivered) {
              expect(
                jsonEncode(await db.query('pulse_episode_outbox')),
                consumed,
              );
            }
            expect(await store.claim([id], token: 'again', nowMs: 3), isEmpty);
            await run();
            expect(await store.list(), isEmpty);
            print('R2_LATE kind=$kind delivered=$delivered PASS');
          } finally {
            await env.dispose();
          }
        },
      );
    }
  }
}
