// Real delivery boundaries: queued work cannot carry stale quiet authorization.
import 'dart:async';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/compute/pulse_episode_delivery.dart';
import 'package:openstrap_edge/compute/pulse_alert_delivery.dart';
import 'package:openstrap_edge/compute/pulse_alert_record.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/state/feature_flags.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup/backup_support.dart';
import 'pulse_episode_store_test.dart' show detection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late DateTime at;
  final center = NotificationCenter.instance,
      service = NotificationService.instance;
  final originalSink = center.presentSink,
      originalDispatcher = center.dispatcher;
  final originalAllocator = service.allocateId;
  final shown = <NotificationEvent>[], osPosts = <MethodCall>[];
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  setUpAll(() async => env = await BackupEnv.create('pulse-handoff.db'));
  setUp(() async {
    await env.wipe();
    await PulseEpisodeWorker.run(
      [],
      processingContext: ProcessingContext.reanalysis,
    );
    at = DateTime(2026, 11, 16, 21, 59, 50);
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    await FeatureFlags.load();
    NotificationIds.instance.resetForTest();
    shown.clear();
    osPosts.clear();
    center.onPhoneQueued = null;
    center.dispatcher = originalDispatcher;
    center.presentSink = (e, {bool allowPermissionPrompt = true}) async {
      shown.add(e);
      return true;
    };
    service.invalidatePermissionCache();
    service.debugRequestPermission = () async => true;
    service.allocateId = originalAllocator;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'show') osPosts.add(call);
          return null;
        });
  });
  tearDown(() {
    center.presentSink = originalSink;
    center.dispatcher = originalDispatcher;
    center.onPhoneQueued = null;
    service.allocateId = originalAllocator;
    service.debugRequestPermission = null;
    service.invalidatePermissionCache();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  tearDownAll(() => env.dispose());
  Future<void> quiet(bool enabled) async => (await NotificationPrefs.load())
      .copyWith(
        quietEnabled: enabled,
        quietStartMin: 22 * 60,
        quietEndMin: 7 * 60,
        criticalOverridesQuiet: true,
      )
      .save();
  Future<PulseEpisodeStore> seed({
    String origin = 'sync',
    bool fresh = true,
  }) async {
    final store = PulseEpisodeStore(await LocalDb.instance);
    await store.reconcile(
      detection(),
      origin: origin,
      nowMs: at.millisecondsSinceEpoch,
    );
    await (await LocalDb.instance).update('pulse_episode', {
      'day': dayLabelOf(at),
      'end_day': dayLabelOf(at),
      'end_ms': at
          .subtract(Duration(seconds: fresh ? 10 : 120))
          .millisecondsSinceEpoch,
    });
    return store;
  }

  NotificationEvent pulse() => NotificationEvent(
    dedupeKey: 'pulse-episode:boundary',
    category: NotifCategory.health,
    title: 'Reading',
    body: 'Reading',
    date: dayLabelOf(at),
    route: '/pulse-episode?id=boundary',
    pulseSourceTime: at,
  );
  void silent(NotificationEvent e) {
    expect(e.silent, isTrue);
    final details = service.detailsForEvent(e);
    expect(details.android!.playSound, isFalse);
    expect(details.android!.enableVibration, isFalse);
    expect(details.iOS!.presentSound, isFalse);
  }

  // WHY/CLAIM(pulse-handoff): lock waits invalidate entry-time authorization.
  // # catches: a pulse passing the gate before a long preceding presentation.
  for (final dispatch in [false, true]) {
    test('queued pulse waits into quiet with dispatcher=$dispatch', () async {
      await withClock(Clock(() => at), () async {
        await (await SharedPreferences.getInstance()).setBool(
          FeatureFlag.alertDispatcher.prefsKey,
          dispatch,
        );
        await FeatureFlags.load();
        final store = await seed();
        final entered = Completer<void>(), release = Completer<void>();
        center.presentSink = (e, {bool allowPermissionPrompt = true}) async {
          if (e.dedupeKey == 'blocker') {
            entered.complete();
            await release.future;
          } else {
            shown.add(e);
          }
          return true;
        };
        final blocking = center.emit(
          NotificationEvent(
            dedupeKey: 'blocker',
            category: NotifCategory.health,
            title: 'Other',
            body: 'Other',
            date: dayLabelOf(at),
          ),
        );
        await entered.future;
        final queued = Completer<void>();
        center.onPhoneQueued = (e) {
          if (e.dedupeKey.startsWith('pulse-episode:')) queued.complete();
        };
        final delivery = PulseEpisodeDelivery.run();
        await queued
            .future; // entry gate passed; the preceding sink owns the lock
        at = DateTime(2026, 11, 16, 22, 0, 1);
        await quiet(true);
        release.complete();
        await blocking;
        await delivery;
        expect(shown, isEmpty);
        expect(await LocalDb.notifFiredAt('pulse-episode:strap:0'), isNull);
        expect(
          (await store.get('strap:0'))!.alertState,
          isNot(isIn(['sent', 'summary', 'unknown', 'pending'])),
        );
        at = DateTime(2026, 11, 17, 7, 0, 1);
        await PulseEpisodeDelivery.run();
        expect(shown, hasLength(1));
        silent(shown.single);
        await PulseEpisodeDelivery.run();
        expect(shown, hasLength(1));
      });
    });
  }

  // WHY/CLAIM(pulse-handoff): the real plugin must recheck after every await.
  // # catches: a guard before permission or ID allocation, instead of OS show.
  for (final waitAt in ['permission', 'id']) {
    test('OS handoff rechecks quiet after $waitAt wait', () async {
      await withClock(Clock(() => at), () async {
        final entered = Completer<void>(), release = Completer<void>();
        if (waitAt == 'permission') {
          service.debugRequestPermission = () async {
            entered.complete();
            await release.future;
            return true;
          };
        } else {
          service.allocateId = (e) async {
            entered.complete();
            await release.future;
            return originalAllocator(e);
          };
        }
        final pending = service.presentEvent(pulse());
        await entered.future;
        at = DateTime(2026, 11, 16, 22, 0, 1);
        await quiet(true);
        release.complete();
        expect(await pending, isFalse);
        expect(osPosts, isEmpty);
        at = DateTime(2026, 11, 17, 7, 0, 1);
        service.allocateId = originalAllocator;
        expect(await service.presentEvent(pulse()), isTrue);
        expect(osPosts, hasLength(1));
      });
    });
  }

  // WHY/CLAIM(pulse-handoff): a queued band command needs its own last check.
  // # catches: checking only before ledger acquisition or band queue entry.
  test('band queued before quiet never writes during quiet', () async {
    await withClock(Clock(() => at), () async {
      final queue = BandHapticQueue(
        ledger: BandCommandLedger(),
        minGap: () => Duration.zero,
      );
      queue.beginLab();
      final entered = Completer<void>();
      var writes = 0;
      center.dispatcher = AlertDispatcher(
        phone: () async => false,
        isConnected: () => true,
        ledger: const NotificationCenterDeliveryLedger(),
        band: () async {
          entered.complete();
          return await queue.run(
                (job) async =>
                    await job.write(() async {
                      writes++;
                      return true;
                    })
                    ? BuzzDelivery.complete
                    : BuzzDelivery.rejected,
                commands: 1,
                timeout: const Duration(seconds: 1),
                settle: Duration.zero,
              ) ==
              BuzzDelivery.complete;
        },
      );
      await (await NotificationPrefs.load())
          .withAlertRule(
            const AlertRule(
              id: 'health',
              kind: 'health',
              destinations: 2,
              channelPolicyId: 'health',
            ).toJson(),
          )
          .save();
      final pending = center.emitReaching(pulse());
      await entered.future;
      at = DateTime(2026, 11, 16, 22, 0, 1);
      await quiet(true);
      queue.endLab();
      expect(await pending, isEmpty);
      expect(writes, 0);
    });
  });

  // WHY/CLAIM(pulse-recovery-silent): owed is not proof of an on-time delivery.
  // # catches: defining recovered by state or origin alone.
  for (final origin in ['sync', 'bulk']) {
    test('$origin older owed episode is silent', () async {
      await withClock(Clock(() => at), () async {
        await seed(origin: origin, fresh: false);
        await PulseEpisodeDelivery.run();
        expect(shown, hasLength(1));
        silent(shown.single);
      });
    });
  }
  test('fresh on-time sync episode keeps normal-channel eligibility', () async {
    await withClock(Clock(() => at), () async {
      await seed();
      await PulseEpisodeDelivery.run();
      expect(shown, hasLength(1));
      expect(shown.single.silent, isFalse);
    });
  });

  // WHY/CLAIM(pulse-recovery-silent): extending an episode cannot freshen old debt.
  // # catches: checking only the newest recording end of an already owed episode.
  test('old owed debt with a recent episode end is still silent', () async {
    await withClock(Clock(() => at), () async {
      await seed();
      await (await LocalDb.instance).update('pulse_episode', {
        'first_seen_ms': at
            .subtract(const Duration(minutes: 2))
            .millisecondsSinceEpoch,
      });
      await PulseEpisodeDelivery.run();
      expect(shown, hasLength(1));
      silent(shown.single);
    });
  });

  // WHY/CLAIM(pulse-handoff): actual OS options follow lateness after awaits.
  // # catches: a final quiet gate that forgets to downgrade an expired normal event.
  test(
    'OS show uses silent options when allocation outlasts freshness',
    () async {
      await withClock(Clock(() => at), () async {
        final event = pulse();
        service.allocateId = (e) async {
          at = at.add(const Duration(seconds: 31));
          return originalAllocator(e);
        };
        expect(await service.presentEvent(event), isTrue);
        expect(osPosts, hasLength(1));
        final options =
            (osPosts.single.arguments as Map)['platformSpecifics'] as Map;
        expect(options['playSound'], isFalse);
        expect(options['enableVibration'], isFalse);
        expect(options['channelId'], 'health_silent');
      });
    },
  );

  // WHY: use the shipped health freshness limit and include its exact boundary.
  // # catches: treating all sync debt as fresh or changing <= to an untested bound.
  for (final seconds in [30, 31]) {
    test(
      'recorded source age $seconds seconds has bounded audio eligibility',
      () async {
        await withClock(Clock(() => at), () async {
          await seed();
          await (await LocalDb.instance).update('pulse_episode', {
            'end_ms': at
                .subtract(Duration(seconds: seconds))
                .millisecondsSinceEpoch,
          });
          await PulseEpisodeDelivery.run();
          expect(shown, hasLength(1));
          expect(shown.single.silent, seconds > 30);
        });
      },
    );
  }

  // WHY/CLAIM(pulse-recovery-silent): quiet deferral is meaningful even when
  // toggled off before the source expires, while the row still says owed.
  // # catches: deciding silence from age or not_sent/summary state alone.
  test(
    'quiet-held owed episode stays silent within the freshness limit',
    () async {
      await withClock(Clock(() => at), () async {
        at = DateTime(2026, 11, 16, 22, 0, 5);
        final store = await seed();
        await quiet(true);
        await PulseEpisodeDelivery.run();
        expect(shown, isEmpty);
        expect((await store.get('strap:0'))!.alertState, 'owed');
        await quiet(false);
        await PulseEpisodeDelivery.run();
        expect(shown, hasLength(1));
        silent(shown.single);
      });
    },
  );
  // WHY: an immediate settings retry also counts as recovery, not fresh sync.
  // # catches: allowing every recent source to use the normal channel.
  test(
    'notifications-off retry is silent even before the source expires',
    () async {
      await withClock(Clock(() => at), () async {
        await seed();
        await (await NotificationPrefs.load())
            .copyWith(healthEnabled: false)
            .save();
        await PulseEpisodeDelivery.run();
        expect(shown, isEmpty);
        await (await NotificationPrefs.load())
            .copyWith(healthEnabled: true)
            .save();
        await PulseEpisodeDelivery.run();
        expect(shown, hasLength(1));
        silent(shown.single);
      });
    },
  );

  // WHY/CLAIM(pulse-recovery-silent): the old daily producer remains live.
  // # catches: a quiet-held daily summary sounding after an off/on retry.
  test(
    'legacy daily quiet recovery is silent across settings off/on',
    () async {
      await withClock(Clock(() => at), () async {
        final day = dayLabelOf(at);
        await LocalDb.putMetricSeriesValue(day, 'irregular_rhythm_flag', 1);
        at = DateTime(2026, 11, 16, 22, 0, 1);
        await quiet(true);
        await PulseAlertDelivery.run(individualDays: {day});
        expect(shown, isEmpty);
        expect(
          (await LocalDb.pulseAlertRecords())[day]!.reason,
          PulseAlertReason.quiet,
        );
        at = DateTime(2026, 11, 17, 7, 0, 1);
        await (await NotificationPrefs.load())
            .copyWith(healthEnabled: false)
            .save();
        await PulseAlertDelivery.run();
        expect(shown, isEmpty);
        await (await NotificationPrefs.load())
            .copyWith(healthEnabled: true)
            .save();
        await PulseAlertDelivery.run();
        expect(shown, hasLength(1));
        silent(shown.single);
        await PulseAlertDelivery.run();
        expect(shown, hasLength(1));
      });
    },
  );

  // WHY/CLAIM(pulse-restore): unclaimed historical debt is silent once, while
  // an imported pending claim remains consumed, even from an older backup.
  // # catches: restoring an old unheld copy erasing quiet deferral or retrying pending.
  for (final pending in [false, true]) {
    test(
      'older backup ${pending ? 'pending is never retried' : 'owed recovers silently once'}',
      () async {
        await withClock(Clock(() => at), () async {
          await env.seedData();
          final store = await seed();
          if (pending) {
            await store.claim(
              ['strap:0'],
              token: 'old-claim',
              nowMs: at.millisecondsSinceEpoch,
            );
          }
          final path = await LocalDb.exportCopy();
          if (!pending) {
            await store.deferQuiet();
          } else {
            await env
                .wipe(); // a restore into a fresh install must consume pending too
            await LocalDb.instance;
          }
          await LocalDb.importFromDbFile(path);
          await PulseEpisodeDelivery.run();
          if (pending) {
            expect(shown, isEmpty);
            expect(
              (await PulseEpisodeStore(
                await LocalDb.instance,
              ).get('strap:0'))!.alertState,
              isIn(['pending', 'unknown']),
            );
          } else {
            expect(shown, hasLength(1));
            silent(shown.single);
          }
          await LocalDb.importFromDbFile(path);
          await PulseEpisodeDelivery.run();
          expect(shown, hasLength(pending ? 0 : 1));
        });
      },
    );
  } // WHY/CLAIM(pulse-restore): an older owed backup cannot unclaim local pending.
  // # catches: replacing consumed local ancestry with imported unclaimed debt.
  test('older owed backup cannot retry a locally pending claim', () async {
    await withClock(Clock(() => at), () async {
      await env.seedData();
      final store = await seed();
      final path = await LocalDb.exportCopy();
      await store.claim(
        ['strap:0'],
        token: 'local-pending',
        nowMs: at.millisecondsSinceEpoch,
      );
      await LocalDb.importFromDbFile(path);
      at = at.add(
        const Duration(milliseconds: 1),
      ); // the claim is now strictly older
      await PulseEpisodeDelivery.run(grace: Duration.zero);
      expect(shown, isEmpty);
      expect(
        (await PulseEpisodeStore(
          await LocalDb.instance,
        ).get('strap:0'))!.alertState,
        'unknown',
      );
      await LocalDb.importFromDbFile(path);
      await PulseEpisodeDelivery.run();
      expect(shown, isEmpty);
    });
  });
}
