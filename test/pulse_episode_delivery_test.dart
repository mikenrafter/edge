import 'dart:convert';
import 'dart:math';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_episode_delivery.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/state/feature_flags.dart';
import 'package:openstrap_edge/data/day_label.dart';
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
    await PulseEpisodeWorker.run(
      [],
      processingContext: ProcessingContext.reanalysis,
    );
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

  // WHY/CLAIM(pulse-quiet): neither real-time nor summary alerts may wake
  // the wearer, even when critical health alerts may override quiet hours.
  // # catches: critical pulse priority bypassing quiet hours or consuming debt.
  for (final origin in ['sync', 'bulk']) {
    test(
      '$origin episode waits through quiet hours without consuming delivery',
      () async {
        final store = await seed(origin: origin);
        final now = DateTime.now();
        final minute = now.hour * 60 + now.minute;
        await (await NotificationPrefs.load())
            .copyWith(
              quietEnabled: true,
              quietStartMin: (minute + 1380) % 1440,
              quietEndMin: (minute + 60) % 1440,
              criticalOverridesQuiet: true,
            )
            .save();
        await PulseEpisodeDelivery.run();
        expect(
          shown,
          isEmpty,
          reason: 'no OS presentation means no sound or vibration',
        );
        expect((await store.get('strap:0'))!.alertState, 'owed');
        await LocalDb.close(); // quiet deferral survives process/database reopen
        expect(await LocalDb.notifFiredAt('pulse-episode:strap:0'), isNull);
        await (await NotificationPrefs.load())
            .copyWith(quietEnabled: false)
            .save();
        await PulseEpisodeDelivery.run();
        expect(shown, hasLength(1));
        expect(shown.single.silent, isTrue);
        final details = NotificationService.instance.detailsForEvent(
          shown.single,
        );
        expect(details.android!.playSound, isFalse);
        expect(details.android!.enableVibration, isFalse);
        expect(
          details.android!.channelId,
          isNot('health'),
          reason: 'Android channel sound settings are immutable after creation',
        );
        expect(details.iOS!.presentSound, isFalse);
        expect(
          (await PulseEpisodeStore(
            await LocalDb.instance,
          ).get('strap:0'))!.alertState,
          origin == 'sync' ? 'sent' : 'summary',
        );
        await PulseEpisodeDelivery.run();
        expect(shown, hasLength(1));
      },
    );
  }

  // WHY/CLAIM(pulse-reading-copy): actual delivered text follows the app
  // language and describes a reading without presenting a diagnosis.
  // # catches: hardcoded English episode notifications or untranslated summaries.
  const readingTitles = {
    'en': 'Irregular rhythm reading',
    'de': 'Messung mit unregelmäßigem Rhythmus',
    'es': 'Lectura de ritmo irregular',
    'fr': 'Mesure de rythme irrégulier',
    'hi': 'अनियमित लय की रीडिंग',
    'ru': 'Запись нерегулярного ритма',
    'zh': '不规则心律读数',
  };
  for (final entry in readingTitles.entries) {
    for (final origin in ['sync', 'bulk']) {
      test(
        '${entry.key} $origin episode uses calm translated reading copy',
        () async {
          await (await SharedPreferences.getInstance()).setString(
            'locale_override',
            entry.key,
          );
          await seed(origin: origin);
          await PulseEpisodeDelivery.run();
          expect(shown, hasLength(1));
          if (origin == 'sync') expect(shown.single.title, entry.value);
          if (origin == 'bulk') expect(shown.single.title, contains('1'));
          expect(shown.single.body, contains('1970'));
          if (entry.key != 'en') {
            expect(shown.single.body, isNot(contains('A wrist pulse flag')));
            expect(shown.single.title, isNot(startsWith('Found')));
          }
        },
      );
    }
  }

  // WHY/CLAIM(pulse-quiet): the shared gate covers both transports and the
  // legacy phone fallback, even if another caller incorrectly marks it critical.
  // # catches: phone-only quiet gating or a critical override on either route.
  for (final dispatcherEnabled in [false, true]) {
    for (final route in ['/pulse-episode?id=strap%3A0', '/pulse-episodes']) {
      test(
        'quiet gate covers $route with dispatcher=$dispatcherEnabled',
        () async {
          final center = NotificationCenter.instance;
          final originalDispatcher = center.dispatcher;
          addTearDown(() async {
            center.dispatcher = originalDispatcher;
            await FeatureFlags.load();
          });
          await (await SharedPreferences.getInstance()).setBool(
            FeatureFlag.alertDispatcher.prefsKey,
            dispatcherEnabled,
          );
          await FeatureFlags.load();
          var bands = 0;
          center.dispatcher = AlertDispatcher(
            phone: () async => false,
            band: () async {
              bands++;
              return true;
            },
            isConnected: () => true,
            ledger: const NotificationCenterDeliveryLedger(),
          );
          final now = DateTime.now();
          final minute = now.hour * 60 + now.minute;
          await (await NotificationPrefs.load())
              .withAlertRule(
                const AlertRule(
                  id: 'health',
                  kind: 'health',
                  destinations: 3,
                  channelPolicyId: 'health',
                ).toJson(),
              )
              .copyWith(
                quietEnabled: true,
                quietStartMin: (minute + 1380) % 1440,
                quietEndMin: (minute + 60) % 1440,
                criticalOverridesQuiet: true,
              )
              .save();
          final event = NotificationEvent(
            dedupeKey: 'pulse-quiet:$route',
            pulseSourceTime: DateTime.now(),
            category: NotifCategory.health,
            priority: NotifPriority.critical,
            title: 'Reading',
            body: 'Reading',
            date: todayLabel(),
            route: route,
          );
          expect(await center.emitReaching(event), isEmpty);
          expect(shown, isEmpty);
          expect(bands, 0);
          await (await NotificationPrefs.load())
              .copyWith(quietEnabled: false)
              .save();
          expect(
            await center.emitReaching(event),
            dispatcherEnabled ? {'phone', 'band'} : {'phone'},
          );
          expect(shown, hasLength(1));
          expect(bands, dispatcherEnabled ? 1 : 0);
        },
      );
    }
  }

  // WHY/CLAIM(pulse-quiet): silent recovery must never fall back to band haptics.
  // # catches: suppressing OS audio while still buzzing the connected band.
  test('a silent current episode reaches only the phone', () async {
    final center = NotificationCenter.instance;
    final previous = center.dispatcher;
    addTearDown(() => center.dispatcher = previous);
    await (await SharedPreferences.getInstance()).setBool(
      FeatureFlag.alertDispatcher.prefsKey,
      true,
    );
    await FeatureFlags.load();
    var bands = 0;
    center.dispatcher = AlertDispatcher(
      phone: () async => false,
      band: () async {
        bands++;
        return true;
      },
      isConnected: () => true,
      ledger: const NotificationCenterDeliveryLedger(),
    );
    await (await NotificationPrefs.load())
        .withAlertRule(
          const AlertRule(
            id: 'health',
            kind: 'health',
            destinations: 3,
            channelPolicyId: 'health',
          ).toJson(),
        )
        .save();
    final reached = await center.emitReaching(
      NotificationEvent(
        dedupeKey: 'silent-pulse',
        category: NotifCategory.health,
        title: 'Reading',
        body: 'Reading',
        date: todayLabel(),
        route: '/pulse-episode?id=current',
        silent: true,
      ),
    );
    expect(reached, {'phone'});
    expect(bands, 0);
  });

  // WHY/CLAIM(pulse-settings): quiet recovery must not bypass a disabled health rule.
  // # catches: losing the durable quiet reason on a notifications-off retry.
  test(
    'quiet recovery remains silent after notifications are re-enabled',
    () async {
      await seed();
      final minute = DateTime.now().hour * 60 + DateTime.now().minute;
      await (await NotificationPrefs.load())
          .copyWith(
            quietEnabled: true,
            quietStartMin: (minute + 1380) % 1440,
            quietEndMin: (minute + 60) % 1440,
          )
          .save();
      await PulseEpisodeDelivery.run();
      await (await NotificationPrefs.load())
          .copyWith(quietEnabled: false, healthEnabled: false)
          .save();
      await PulseEpisodeDelivery.run();
      expect(shown, isEmpty);
      expect(
        (await PulseEpisodeStore(
          await LocalDb.instance,
        ).get('strap:0'))!.alertReason,
        'quiet hours',
      );
      await (await NotificationPrefs.load())
          .copyWith(healthEnabled: true)
          .save();
      await PulseEpisodeDelivery.run();
      expect(shown, hasLength(1));
      expect(shown.single.silent, isTrue);
      await PulseEpisodeDelivery.run();
      expect(shown, hasLength(1));
    },
  );

  // WHY: the pulse exception must not alter other intentional critical alerts.
  // # catches: globally disabling critical overrides instead of narrowing pulse.
  test('other critical health alerts still follow the user override', () {
    final now = DateTime.now();
    final minute = now.hour * 60 + now.minute;
    final prefs = NotificationPrefs(
      quietEnabled: true,
      quietStartMin: (minute + 1380) % 1440,
      quietEndMin: (minute + 60) % 1440,
      criticalOverridesQuiet: true,
    );
    final other = NotificationEvent(
      dedupeKey: 'health-exception',
      category: NotifCategory.health,
      priority: NotifPriority.critical,
      title: 'Health',
      body: 'Health',
      date: todayLabel(),
      route: '/heart',
    );
    expect(prefs.shouldFireOs(other, minute), isTrue);
    expect(
      prefs.copyWith(criticalOverridesQuiet: false).shouldFireOs(other, minute),
      isFalse,
    );
  });

  // WHY/CLAIM(health-episode-read): the production repository serves the real
  // episode/outbox read, rather than inheriting the empty-ledger default.
  test(
    'the repository reads stored episode summaries and delivery state',
    () async {
      await seed();
      final repo = LocalRepositoryImpl(getProfileMap: () => const {});
      final episodes = await repo.getPulseEpisodes();
      expect(episodes.map((e) => e.id), ['strap:0']);
      expect(episodes.single.alertState, 'owed');
      expect(
        episodes.single.evidence,
        isNull,
        reason: 'the overview reads metadata without decoding evidence blobs',
      );
      await PulseEpisodeDelivery.run();
      expect((await repo.getPulseEpisodes()).single.alertState, 'sent');
    },
  );

  // WHY/CLAIM(health-episode-read): a broken ledger must reach the overview as
  // a read failure, not an empty list claiming the wearer had no episodes.
  test('the repository propagates episode ledger failures', () async {
    await seed();
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    await (await LocalDb.instance).execute('DROP TABLE pulse_episode_outbox');
    await expectLater(repo.getPulseEpisodes(), throwsException);
  });

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
