import 'dart:convert';
import 'dart:math';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_episode_delivery.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup/backup_support.dart';
import 'pulse_episode_store_test.dart' show detection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;
  setUpAll(() async {
    env = await BackupEnv.create('pulse2-delivery.db');
  });
  tearDownAll(() async {
    NotificationCenter.instance.presentSink = original;
    await env.dispose();
  });
  setUp(() async {
    await env.wipe();
    // These cases exercise arrivals after the upgrade boundary.
    await PulseEpisodeWorker.run([], processingContext: ProcessingContext.reanalysis);
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    shown.clear();
    NotificationIds.instance.resetForTest();
    NotificationCenter.instance.presentSink =
        (event, {bool allowPermissionPrompt = true}) async {
          shown.add(event);
          return true;
        };
  });
  Future<PulseEpisodeStore> seed({
    String origin = 'sync',
    int offset = 0,
  }) async {
    final store = PulseEpisodeStore(await LocalDb.instance);
    await store.reconcile(detection(offset: offset), origin: origin, nowMs: 1);
    return store;
  }

  // WHY/CLAIM(pulse-delivery): actual notification center, exact episode route, real old date; once across races.
  test(
    'sync episodes of any age fire individually exactly once through NotificationCenter',
    () async {
      final store = await seed();
      await seed(offset: 3600000);
      await Future.wait([
        PulseEpisodeDelivery.run(),
        PulseEpisodeDelivery.run(),
      ]);
      expect(shown, hasLength(2));
      expect(shown.first.body, contains('1970'));
      expect(shown.first.route, '/pulse-episode?id=strap%3A0');
      expect((await store.get('strap:0'))!.alertState, 'sent');
      await PulseEpisodeDelivery.run();
      expect(shown, hasLength(2));
    },
  );
  // WHY/CLAIM(pulse-no-double): episode coverage suppresses the old daily
  // alert, without modifying its stored scalar or already-sent delivery record.
  test(
    'a covered daily flag does not also send a phase 1 daily alert',
    () async {
      await LocalDb.putMetricSeriesValue(
        '1970-01-01',
        'irregular_rhythm_flag',
        1,
      );
      expect(await LocalDb.pulseDaysToAlert(), ['1970-01-01']);
      await seed();
      expect(await LocalDb.pulseDaysToAlert(), isEmpty);
    },
  );
  // WHY/CLAIM(pulse-summary): bulk paths get one summary, and suppressed items are summarized when permitted.
  test(
    'bulk and notifications-off recovery each produce one summary',
    () async {
      final store = await seed(origin: 'bulk');
      await seed(origin: 'bulk', offset: 3600000);
      await PulseEpisodeDelivery.run();
      expect(shown, hasLength(1));
      expect(shown.single.title, contains('2'));
      expect((await store.get('strap:0'))!.alertState, 'summary');
      await seed(offset: 7200000);
      NotificationCenter.instance.presentSink =
          (event, {bool allowPermissionPrompt = true}) async => false;
      await PulseEpisodeDelivery.run();
      expect(
        (await store.get('strap:7200000'))!.alertReason,
        'notifications off',
      );
      NotificationCenter.instance.presentSink =
          (event, {bool allowPermissionPrompt = true}) async {
            shown.add(event);
            return true;
          };
      await PulseEpisodeDelivery.run();
      expect(shown, hasLength(2));
      expect(shown.last.route, '/pulse-episodes');
      expect((await store.get('strap:7200000'))!.alertState, 'summary');
    },
  );
  // WHY/CLAIM(pulse-claim): both an abandoned claim and a throwing OS handoff are ambiguous and never resent.
  test('crash between claim/show and ambiguous handoff never retry', () async {
    var store = await seed();
    expect(await store.claim(['strap:0'], token: 'dead', nowMs: 1), [
      'strap:0',
    ]);
    await LocalDb.close();
    store = PulseEpisodeStore(await LocalDb.instance);
    await PulseEpisodeDelivery.run(grace: Duration.zero);
    expect(shown, isEmpty);
    expect((await store.get('strap:0'))!.alertState, 'unknown');
    await seed(offset: 3600000);
    NotificationCenter.instance.presentSink =
        (event, {bool allowPermissionPrompt = true}) async {
          throw StateError('ambiguous OS return');
        };
    await PulseEpisodeDelivery.run();
    expect((await store.get('strap:3600000'))!.alertState, 'unknown');
    await PulseEpisodeDelivery.run();
    expect(shown, isEmpty);
  });
  // WHY/CLAIM(pulse-restore): genuine export/import preserves delivery records and prevents replay.
  test(
    'restore retains sent and unknown claims; unsent restoration is bulk',
    () async {
      await env.seedData();
      var store = await seed();
      await PulseEpisodeDelivery.run();
      await seed(offset: 3600000);
      await store.claim(['strap:3600000'], token: 'dead', nowMs: 1);
      await seed(offset: 7200000);
      final path = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(path);
      store = PulseEpisodeStore(await LocalDb.instance);
      expect((await store.get('strap:0'))!.alertState, 'sent');
      expect((await store.get('strap:3600000'))!.alertState, 'unknown');
      shown.clear();
      await PulseEpisodeDelivery.run();
      expect(shown, hasLength(1));
      expect(shown.single.route, '/pulse-episodes');
    },
  );
  // WHY/CLAIM(pulse-production): the committed-beat worker actually detects and alerts,
  // rather than tests only manually inserting an episode no runtime path creates.
  test(
    'committed beat worker finds and alerts an old episode with unknown motion',
    () async {
      final db = await LocalDb.instance;
      final random = Random(17);
      final start = DateTime(2026, 11, 12, 2).millisecondsSinceEpoch;
      var time = start.toDouble();
      final batch = db.batch();
      while (time < start + 25 * 60000) {
        final rr = 750 + random.nextDouble() * 500;
        time += rr;
        batch.insert('decoded_rr', {
          'device_id': 'strap',
          'ts_ms': time.round(),
          'rec_ts': time.round() ~/ 1000,
          'beat_index': 0,
          'rr_ts_ms': time.round(),
          'beat_ts_ms': time.round(),
          'rr_ms': rr.round(),
        });
      }
      batch.insert('decoded_onehz', {
        'device_id': 'strap',
        'ts_ms': start,
        'rec_ts': start ~/ 1000,
        'counter': 1,
        'hr': 60,
      });
      batch.insert('decoded_onehz', {
        'device_id': 'other',
        'ts_ms': start,
        'rec_ts': start ~/ 1000,
        'counter': 2,
        'hr': 180,
      });
      await batch.commit(noResult: true);
      await PulseEpisodeWorker.run(
        ['2026-11-12'],
        processingContext: const ProcessingContext(
          ProcessingOrigin.recentSync,
          {'2026-11-12': 1},
        ),
      );
      expect(
        shown,
        isEmpty,
        reason: 'a committed transport chunk is not complete history',
      );
      expect(await PulseEpisodeStore(db).list(), isEmpty);
      await PulseEpisodeStore(db).certifyCurrentSource('strap');
      await PulseEpisodeWorker.run(
        ['2026-11-12'],
        processingContext: ProcessingContext(ProcessingOrigin.recentSync, {
          '2026-11-12': 1,
        }),
      );
      final episodes = await PulseEpisodeStore(db).list();
      expect(episodes, hasLength(1));
      expect(episodes.single.alertState, 'sent');
      final recording = (await PulseEpisodeStore(db).get(episodes.single.id))!;
      expect(
        (recording.evidence!['heartRate'] as List).single['bpm'],
        60,
        reason:
            'episode HR context belongs to its own sensor, never an average across devices',
      );
      expect(shown, hasLength(1));
      expect(shown.single.body, contains('2026'));
      await PulseEpisodeWorker.run([
        '2026-11-12',
      ], processingContext: ProcessingContext.reanalysis);
      expect(shown, hasLength(1));
    },
  );
  // WHY/CLAIM(pulse-additive): real production schema migration and pulse processing preserve signal and frozen output.
  test(
    'production migration and reconciliation leave durable signal and legacy checksums unchanged',
    () async {
      await env.seedData();
      var db = await LocalDb.instance;
      await db.insert('raw_archive', {
        'device_id': '',
        'hex': 'aabb',
        'packet_type': 99,
        'captured_at': 1,
        'reason': 'pilot fixture',
      });
      await db.insert('decoded_rr', {
        'device_id': '',
        'ts_ms': 1790000000000,
        'rec_ts': 1790000000,
        'beat_index': 0,
        'rr_ts_ms': 1790000000000,
        'beat_ts_ms': 1790000000000,
        'rr_ms': 1000,
      });
      final tables = [
        'raw_archive',
        'decoded_onehz',
        'decoded_rr',
        'day_result',
      ];
      expect(
        (await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name='raw_records'",
        )),
        isEmpty,
        reason:
            'the integrated schema already retired raw_records; archives are the raw ledger',
      );
      Future<String> checksum() async => sha256
          .convert(
            utf8.encode(
              jsonEncode([
                for (final t in tables) await db.query(t, orderBy: 'rowid'),
              ]),
            ),
          )
          .toString();
      final before = await checksum();
      for (final table in pulseEpisodeTables) {
        await db.execute('DROP TABLE $table');
      }
      await db.execute('PRAGMA user_version=87');
      await LocalDb.close();
      db = await LocalDb.instance;
      await seed();
      await PulseEpisodeDelivery.run();
      expect(await checksum(), before);
      await LocalDb.close();
      db = await LocalDb.instance;
      expect(await checksum(), before);
    },
  );
}
