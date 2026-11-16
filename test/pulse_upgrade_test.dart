// Upgrade delivery regressions through the production committed-beat worker.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/compute/pulse_episode_delivery.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup/backup_support.dart';
import 'pulse_band_fixture.dart';
import 'pulse_episode_store_test.dart' show detection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;
  final day1 = DateTime(2026, 11, 10, 2).millisecondsSinceEpoch;
  final day2 = DateTime(2026, 11, 12, 2).millisecondsSinceEpoch;
  const days = ['2026-11-10', '2026-11-12'];
  const sync = ProcessingContext(ProcessingOrigin.recentSync, {
    '2026-11-10': 1,
    '2026-11-12': 1,
  });
  setUpAll(() async => env = await BackupEnv.create('pulse-upgrade.db'));
  tearDownAll(() async {
    NotificationCenter.instance.presentSink = original;
    await env.dispose();
  });
  setUp(() async {
    await env.wipe();
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    NotificationIds.instance.resetForTest();
    shown.clear();
    NotificationCenter.instance.presentSink =
        (event, {bool allowPermissionPrompt = true}) async {
          shown.add(event);
          return true;
        };
  });
  Future<List<Map<String, Object?>>> seedHistory() async {
    final db = await LocalDb.instance;
    final first = bandRows(day1, 25);
    final second = bandRows(day2, 25, device: 'second', seed: 5);
    await insertRows(db, first);
    await insertRows(db, second);
    await PulseEpisodeStore(db).certifyCurrentSource('');
    await PulseEpisodeStore(db).certifyCurrentSource('second');
    return [...first, ...second];
  }

  Future<void> expectHistorical({int count = 2}) async {
    final store = PulseEpisodeStore(await LocalDb.instance);
    final episodes = await store.list();
    expect(episodes, hasLength(count));
    for (final episode in episodes) {
      expect(episode.alertState, 'sent');
      expect(episode.alertReason, 'before this version');
      expect(episode.alertNote, contains('before this version'));
      final detail = (await store.get(episode.id))!;
      expect(detail.alertNote, episode.alertNote);
    }
    expect(await store.owed(), isEmpty);
    expect(shown, isEmpty);
  }

  // WHY/CLAIM(pulse-upgrade): upgrading a populated device never floods it.
  // catches: first-run history treated as ordinary sync or bulk summary.
  test(
    'populated upgrade marks every historical episode before this version',
    () async {
      await seedHistory();
      final result = await PulseEpisodeWorker.run(
        days,
        processingContext: sync,
      );
      expect(result.failedDays, isEmpty);
      await expectHistorical();
      await PulseEpisodeDelivery.run();
      expect(shown, isEmpty, reason: 'no catch-up summary either');
    },
  );

  // WHY/CLAIM(pulse-upgrade): arrival, not recording time, defines new data.
  // catches: a timestamp cutoff suppressing later arrival of older band data.
  test('old data arriving after upgrade alerts once on each source', () async {
    await PulseEpisodeWorker.run(
      [],
      processingContext: ProcessingContext.reanalysis,
    );
    await seedHistory();
    await PulseEpisodeWorker.run(days, processingContext: sync);
    expect(shown, hasLength(2));
    expect(shown.every((e) => e.title == 'Irregular rhythm reading'), isTrue);
    await LocalDb.close();
    await PulseEpisodeWorker.run(
      days,
      processingContext: ProcessingContext.reanalysis,
    );
    expect(shown, hasLength(2));
  });

  // WHY/CLAIM(pulse-upgrade): the boundary is durable and never recaptured.
  // catches: process-local flag, max recording timestamp, or recapture per run.
  test(
    'watermark survives restart and is written once across late arrivals',
    () async {
      final historicalRows = await seedHistory();
      await PulseEpisodeWorker.run(days, processingContext: sync);
      await expectHistorical();
      final db = await LocalDb.instance;
      final marker = await db.query('pulse_upgrade');
      final keys = await db.query(
        'pulse_upgrade_record',
        orderBy: 'source,ts_ms',
      );
      expect(marker, hasLength(1));
      expect(
        {for (final k in keys) '${k['source']}:${k['ts_ms']}'},
        {for (final r in historicalRows) '${r['device_id']}:${r['ts_ms']}'},
      );
      // A repeated write fails even if it would store identical values.
      await db.execute(
        "CREATE TRIGGER upgrade_once BEFORE INSERT ON pulse_upgrade "
        "BEGIN SELECT RAISE(ABORT,'watermark rewritten'); END",
      );
      await db.execute(
        "CREATE TRIGGER upgrade_keys_once BEFORE INSERT ON pulse_upgrade_record "
        "BEGIN SELECT RAISE(ABORT,'watermark recaptured'); END",
      );
      await LocalDb.close();
      final reopened = await LocalDb.instance;
      // Older than the high timestamp, same source, but a previously absent key.
      await insertRows(reopened, bandRows(day1 - 3600000, 25, seed: 3));
      await PulseEpisodeStore(reopened).certifyCurrentSource('');
      await PulseEpisodeWorker.run(days, processingContext: sync);
      expect(shown, hasLength(1));
      expect(await reopened.query('pulse_upgrade'), marker);
      expect(
        await reopened.query('pulse_upgrade_record', orderBy: 'source,ts_ms'),
        keys,
      );
    },
  );

  // WHY/CLAIM(pulse-upgrade): a failed first scan cannot leak historical alerts.
  // catches: initialization that depends on finishing every day's detection.
  test(
    'crash during first scan retries unmarked history without alerts',
    () async {
      await seedHistory();
      final db = await LocalDb.instance;
      await db.execute(
        "CREATE TRIGGER fail_upgrade_episode BEFORE INSERT ON pulse_episode "
        "WHEN NEW.day='2026-11-12' BEGIN SELECT RAISE(ABORT,'crash'); END",
      );
      final first = await PulseEpisodeWorker.run(days, processingContext: sync);
      expect(first.failedDays.keys, ['2026-11-12']);
      await expectHistorical(count: 1);
      await db.execute('DROP TRIGGER fail_upgrade_episode');
      await LocalDb.close();
      final retry = await PulseEpisodeWorker.run(days, processingContext: sync);
      expect(retry.failedDays, isEmpty);
      await expectHistorical();
    },
  );

  // WHY/CLAIM(pulse-upgrade): marker and snapshot commit in one transaction.
  // catches: marker committed before a partial/failed snapshot insertion.
  test(
    'failed watermark transaction rolls back and first-run retry stays silent',
    () async {
      await seedHistory();
      final db = await LocalDb.instance;
      await db.execute(
        "CREATE TRIGGER fail_upgrade_snapshot BEFORE INSERT ON pulse_upgrade_record "
        "WHEN NEW.source='second' BEGIN SELECT RAISE(ABORT,'crash'); END",
      );
      final first = await PulseEpisodeWorker.run(days, processingContext: sync);
      expect(first.failedDays, isNotEmpty);
      expect(await db.query('pulse_upgrade'), isEmpty);
      expect(await db.query('pulse_upgrade_record'), isEmpty);
      expect(await db.query('pulse_episode_outbox'), isEmpty);
      expect(shown, isEmpty);
      await db.execute('DROP TRIGGER fail_upgrade_snapshot');
      await LocalDb.close();
      await PulseEpisodeWorker.run(days, processingContext: sync);
      await expectHistorical();
    },
  );

  // WHY/CLAIM(pulse-upgrade): restores and reanalysis cannot revive old debt,
  // even when backed up after the boundary but before any episode existed.
  // catches: delivery-only tombstones or watermark excluded from restore.
  test(
    'restore before detection and raw replay preserve the upgrade boundary',
    () async {
      await env.seedData();
      await seedHistory();
      await PulseEpisodeWorker.run(
        [],
        processingContext: ProcessingContext.reanalysis,
      );
      final backup = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(backup);
      await PulseEpisodeWorker.run(
        days,
        processingContext: ProcessingContext.reanalysis,
      );
      await expectHistorical();
      final db = await LocalDb.instance;
      // Re-decode/replacement uses the original record identities.
      await db.delete('decoded_rr');
      await seedHistory();
      await db.delete('pulse_input_arrival', where: "source LIKE 'all:%'");
      await PulseEpisodeWorker.run(
        days,
        processingContext: ProcessingContext.reanalysis,
      );
      await expectHistorical();
      final withEpisodes = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(withEpisodes);
      await PulseEpisodeWorker.run(
        days,
        processingContext: ProcessingContext.reanalysis,
      );
      await expectHistorical();
    },
  );

  // WHY/CLAIM(pulse-upgrade): backup must carry the boundary, not recapture
  // everything as old on the restored installation.
  // catches: excluding watermark tables from backup merge.
  test(
    'restore preserves distinction between old history and post-upgrade arrivals',
    () async {
      await env.seedData();
      await seedHistory();
      await PulseEpisodeWorker.run(
        [],
        processingContext: ProcessingContext.reanalysis,
      );
      final db = await LocalDb.instance;
      final marker = await db.query('pulse_upgrade');
      final keys = await db.query(
        'pulse_upgrade_record',
        orderBy: 'source,ts_ms',
      );
      await insertRows(db, bandRows(day1 - 3600000, 25, seed: 3));
      final path = await LocalDb.exportCopy();
      await env.wipe();
      final fresh = await LocalDb.instance;
      await LocalDb.importFromDbFile(path);
      expect(await fresh.query('pulse_upgrade'), marker);
      expect(
        await fresh.query('pulse_upgrade_record', orderBy: 'source,ts_ms'),
        keys,
      );
      await PulseEpisodeWorker.run(
        days,
        processingContext: ProcessingContext.reanalysis,
      );
      final episodes = await PulseEpisodeStore(fresh).list();
      expect(episodes, hasLength(3));
      expect(
        episodes.where((e) => e.alertReason == 'before this version'),
        hasLength(2),
      );
      expect(episodes.where((e) => e.alertState == 'summary'), hasLength(1));
      expect(shown, hasLength(1));
      expect(shown.single.route, '/pulse-episodes');
      await PulseEpisodeWorker.run(
        days,
        processingContext: ProcessingContext.reanalysis,
      );
      expect(shown, hasLength(1));
    },
  );

  // WHY/CLAIM(pulse-upgrade): the engine has a delivery-only path when there
  // is no derive work, so a previous pilot's owed episodes must close there too.
  // catches: initializing only in the beat worker, leaving direct delivery live.
  test(
    'first delivery-only pass closes earlier pilot debt without a handoff',
    () async {
      final store = PulseEpisodeStore(await LocalDb.instance);
      await store.reconcile(detection(), origin: 'sync', nowMs: 1);
      expect(await store.owed(), hasLength(1));
      await PulseEpisodeDelivery.run();
      final episode = (await store.get('strap:0'))!;
      expect(episode.alertState, 'sent');
      expect(episode.alertReason, 'before this version');
      expect(shown, isEmpty);
      await PulseEpisodeDelivery.run();
      expect(shown, isEmpty);
    },
  );
}
