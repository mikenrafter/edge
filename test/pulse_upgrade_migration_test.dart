// Upgrade boundary through the real schema ladder and sync/derive paths.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/pulse_episode_delivery.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'backup/backup_support.dart';
import 'pulse_band_fixture.dart';
import 'pulse_episode_store_test.dart' show detection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;
  final oldStart = DateTime(2026, 11, 10, 2).millisecondsSinceEpoch;
  const day = '2026-11-10';
  const sync = ProcessingContext(ProcessingOrigin.recentSync, {day: 1});
  var counter = 0;

  setUpAll(() async => env = await BackupEnv.create('pulse-migration.db'));
  tearDownAll(() async {
    NotificationCenter.instance.presentSink = original;
    await env.dispose();
  });
  setUp(() async {
    await env.wipe();
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    NotificationIds.instance.resetForTest();
    shown.clear();
    counter = 0;
    NotificationCenter.instance.presentSink =
        (event, {bool allowPermissionPrompt = true}) async {
          shown.add(event);
          return true;
        };
  });

  // Use the actual BandHost -> commitSyncBatch -> decoded_rr path, preserving
  // multi-beat records and their subsecond anchors from the band-shaped fixture.
  Future<void> bandCommit(List<Map<String, Object?>> rows) async {
    final records = <int, List<Map<String, Object?>>>{};
    for (final r in rows) {
      (records[r['rec_ts'] as int] ??= []).add(r);
    }
    final raws = <RawRecord>[], samples = <Sample?>[];
    for (final entry in records.entries) {
      final c = ++counter;
      final second = entry.key;
      final within = (entry.value.last['beat_ts_ms'] as int) - second * 1000;
      raws.add(
        RawRecord(
          counter: c,
          packetType: 47,
          hex: '2f18',
          recTs: second,
          capturedAt: oldStart,
        ),
      );
      samples.add(
        Sample(
          tsEpoch: second,
          counter: c,
          hr: 70,
          tsSubsec: (within * 32768 / 1000).ceil(),
          rrIntervalsMs: [for (final r in entry.value) r['rr_ms'] as int],
        ),
      );
    }
    await BandHost(
      adapter: kBleHrsAdapter,
      deviceId: LocalDb.kPrimaryDeviceId,
    ).commitNativeBatch(raws, samples, '0011223344556677');
  }

  // Schema 88 already has all episode tables except the two boundary tables.
  // Build that on-disk fixture without duplicating the entire schema ladder,
  // close it, and reopen via LocalDb's production onUpgrade transaction.
  Future<void> reopenAsUpgrade() async {
    final db = await LocalDb.instance;
    await db.execute('DROP TABLE pulse_upgrade_record');
    await db.execute('DROP TABLE pulse_upgrade');
    await db.setVersion(88);
    await LocalDb.close();
    await LocalDb.instance;
  }

  Future<void> certify() async =>
      PulseEpisodeStore(await LocalDb.instance).certifyCurrentSource('');
  Iterable<NotificationEvent> getEpisodeAlerts() => shown.where(
    (e) =>
        (e.route ?? '').startsWith('/pulse-episode?id=') ||
        e.route == '/pulse-episodes',
  );

  Future<void> expectOldAndNew({bool summary = false}) async {
    final episodes = await PulseEpisodeStore(await LocalDb.instance).list();
    expect(episodes, hasLength(2));
    final old = episodes.singleWhere(
      (e) => e.startMs >= oldStart && e.startMs < oldStart + 25 * 60000,
    );
    expect(old.alertState, 'sent');
    expect(old.alertReason, 'before this version');
    final fresh = episodes.singleWhere((e) => e.id != old.id);
    expect(fresh.alertState, summary ? 'summary' : 'sent');
    expect(fresh.alertReason, isNot('before this version'));
    expect(getEpisodeAlerts(), hasLength(1));
    await PulseEpisodeWorker.run([day], processingContext: sync);
    await PulseEpisodeDelivery.run();
    expect(getEpisodeAlerts(), hasLength(1));
  }

  // WHY/CLAIM(pulse-upgrade): the version boundary precedes every post-upgrade
  // sync, even if no worker has run. Also pins the migration's prior-pilot sweep.
  test(
    'schema 88 to 89 captures history and closes debt before any worker',
    () async {
      final rows = bandRows(oldStart, 25);
      await insertRows(await LocalDb.instance, rows);
      await PulseEpisodeStore(
        await LocalDb.instance,
      ).reconcile(detection(), origin: 'sync', nowMs: 1);
      await reopenAsUpgrade();
      final db = await LocalDb.instance;
      expect(await db.getVersion(), 89);
      expect(await db.query('pulse_upgrade'), hasLength(1));
      final keys = await db.query('pulse_upgrade_record');
      expect(
        {for (final k in keys) '${k['source']}:${k['ts_ms']}'},
        {for (final r in rows) '${r['device_id']}:${r['ts_ms']}'},
      );
      final debt = (await db.query('pulse_episode_outbox')).single;
      expect(debt['state'], 'sent');
      expect(debt['reason'], 'before this version');
      expect(shown, isEmpty);
    },
  );

  // WHY/CLAIM(pulse-upgrade): the delayed first worker must not swallow band
  // rows committed after migration, even when their recording time is older.
  test(
    'band rows arriving between migration and first worker alert once',
    () async {
      await insertRows(await LocalDb.instance, bandRows(oldStart, 25));
      await reopenAsUpgrade();
      await bandCommit(bandRows(oldStart - 3600000, 25, seed: 3));
      await certify();
      final result = await PulseEpisodeWorker.run([
        day,
      ], processingContext: sync);
      expect(result.failedDays, isEmpty);
      expect(result.retryDays, isEmpty);
      await expectOldAndNew();
    },
  );

  // WHY/CLAIM(pulse-upgrade): reproduce the actual ordering: the algorithm bump
  // starts re-deriving history; a real sync commits while processDay is held;
  // only then does the engine reach its first episode worker.
  test(
    'real band sync during the first derive pass remains new input',
    () async {
      await bandCommit(bandRows(oldStart, 25));
      await reopenAsUpgrade();
      final entered = Completer<void>(), release = Completer<void>();
      final engine = DerivationEngine(log: (_) {})
        ..debugDayHook = (_) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        };
      final pass = engine.run(
        Profile.fromMap(const <String, dynamic>{}),
        processingContext: sync,
        force: true,
      );
      try {
        await entered.future.timeout(const Duration(seconds: 20));
        expect(await PulseEpisodeStore(await LocalDb.instance).list(), isEmpty);
        await bandCommit(bandRows(oldStart + 2 * 3600000, 25, seed: 3));
        await certify();
      } finally {
        release.complete();
        await pass;
      }
      // Forced reanalysis uses the existing one-summary policy. Assert before
      // a direct retry: the engine's own worker must deliver the new episode.
      await expectOldAndNew(summary: true);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // WHY/CLAIM(pulse-upgrade): only an entirely historical episode is silent.
  // One continuous episode crossing the record boundary alerts (r2 M1).
  test('an episode straddling migration alerts once', () async {
    final rows = bandRows(oldStart, 25);
    final boundary = oldStart + 10 * 60000;
    await insertRows(
      await LocalDb.instance,
      rows.where((r) => (r['ts_ms'] as int) < boundary).toList(),
    );
    await reopenAsUpgrade();
    await bandCommit(
      rows.where((r) => (r['ts_ms'] as int) >= boundary).toList(),
    );
    await certify();
    final result = await PulseEpisodeWorker.run([day], processingContext: sync);
    expect(result.failedDays, isEmpty);
    final episode = (await PulseEpisodeStore(
      await LocalDb.instance,
    ).list()).single;
    expect(episode.startMs, lessThan(boundary));
    expect(episode.endMs, greaterThan(boundary));
    expect(episode.alertState, 'sent');
    expect(episode.alertReason, isNot('before this version'));
    expect(getEpisodeAlerts(), hasLength(1));
    await PulseEpisodeWorker.run([day], processingContext: sync);
    expect(getEpisodeAlerts(), hasLength(1));
  });
}
