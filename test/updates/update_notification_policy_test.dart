// WHY: a release alert must go out at most once, only for an opted-in install,
// never wake or buzz the wearer through quiet hours or sleep, and never open the
// health database. The central alert policy (quiet/sleep hold, destination
// routing, fallback) decides WHEN; the update store's claim decides WHETHER.
// Proves CLAIM(release-check-once), CLAIM(release-check-consent),
// CLAIM(release-check-page-only).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_policy.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/feature_flags.dart';
import 'package:openstrap_edge/sync/update_background.dart';
import 'package:openstrap_edge/sync/update_claim_ledger.dart';
import 'package:openstrap_edge/sync/update_coordinator.dart';
import 'package:openstrap_edge/sync/update_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/alert_sleep_source.dart';
import 'update_checker_test.dart' show release;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final center = NotificationCenter.instance;
  late Directory directory;
  late UpdateStore store;
  late List<NotificationEvent> shown;
  late List<bool> prompts;
  late int bandBuzzes;
  var bandConnected = true;
  late AlertDispatcher originalDispatcher;
  late Future<bool> Function(NotificationEvent, {bool allowPermissionPrompt})
  originalSink;
  late AlertSleepSource originalSleep;
  late AlertRule originalRule;

  NotificationEvent event({int id = 1, String source = 'fork', String? route}) =>
      NotificationEvent(
        dedupeKey: 'release:$source:$id',
        category: NotifCategory.updates,
        title: 'Update available',
        body: 'Fork next-2026.11.15',
        date: '2026-11-15',
        route: route ??
            releaseRoute(
              source == 'fork' ? ReleaseSource.fork : ReleaseSource.official,
              source == 'fork' ? 'next-2026.11.15' : 'v0.11.4',
            ),
      );

  Future<int?> storedOsId(String identity) async {
    final rows = await store.db.query('update_notifications',
        where: 'identity=?', whereArgs: [identity]);
    return rows.isEmpty ? null : 500000 + (rows.single['seq'] as int);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({'locale_override': 'en'});
    await const NotificationPrefs(quietEnabled: false).save();
    FeatureFlags.resetForTest();
    directory = await Directory.systemTemp.createTemp('update-policy-');
    store = await UpdateStore.openFile('${directory.path}/u.db',
        factory: databaseFactoryFfi);
    await store.setEnabled(true);
    shown = [];
    prompts = [];
    bandBuzzes = 0;
    bandConnected = true;
    originalDispatcher = center.dispatcher;
    originalSink = center.presentSink;
    originalSleep = AlertPolicy.sleepSource;
    originalRule = center.updateRule;
    AlertPolicy.sleepSource = const AwakeAlertSleepSource();
    center.registerClaimLedger(
        NotifCategory.updates, UpdateClaimLedger(() async => store));
    NotificationCenterDeliveryLedger.registerRuleLedger(
        'updates', UpdateTargetLedger(() async => store));
    center.claimedPermission = () async => true;
    center.presentTimeout = const Duration(seconds: 10);
    center.presentSink = (e, {bool allowPermissionPrompt = true}) async {
      shown.add(e);
      prompts.add(allowPermissionPrompt);
      return true;
    };
    center.dispatcher = AlertDispatcher(
      phone: () async => false,
      band: () async {
        bandBuzzes++;
        return true;
      },
      isConnected: () => bandConnected,
      policy: AlertPolicy.permits,
      fallbackDestination: AlertPolicy.fallback,
      latestRule: AlertPolicy.currentRule,
      ledger: const NotificationCenterDeliveryLedger(),
    );
  });
  tearDown(() async {
    center.dispatcher = originalDispatcher;
    center.presentSink = originalSink;
    AlertPolicy.sleepSource = originalSleep;
    center.updateRule = originalRule;
    FeatureFlags.resetForTest();
    await store.db.close();
    await directory.delete(recursive: true);
  });

  for (final dispatcherOn in [false, true]) {
    group('dispatcher=$dispatcherOn', () {
      setUp(() => FeatureFlags.debugSet(FeatureFlag.alertDispatcher, dispatcherOn));

      // catches: a health-database claim or OS id (spec §5.4), a check-then-
      // record race, and a date-prefixed identity that re-alerts next day.
      test('one alert across races and rediscovery, store-owned OS id, no health DB', () async {
        final before = LocalDb.debugHandleRequests;
        final results = await Future.wait(List.generate(8, (_) => center.emit(event())));
        expect(results.where((v) => v), hasLength(1));
        expect(
          await center.emit(NotificationEvent(
            dedupeKey: event().dedupeKey,
            category: NotifCategory.updates,
            title: 't',
            body: 'b',
            date: '2026-11-16',
            route: event().route,
          )),
          isFalse,
        );
        expect(shown, hasLength(1));
        expect(shown.single.osId, await storedOsId('release:fork:1'));
        expect(shown.single.osId, greaterThanOrEqualTo(500000));
        expect(prompts, [false], reason: 'a headless path never prompts');
        expect(LocalDb.debugHandleRequests, before, reason: 'the health database stays closed');
      });

      // CLAIM(release-check-once) catches: releasing or re-allocating a claim the
      // central policy is holding (spec §5.5 mutation).
      test('sleep holds the alert, keeps the claim, releases it once awake', () async {
        AlertPolicy.sleepSource = const AsleepAlertSleepSource();
        expect(await center.emit(event()), isFalse);
        expect(shown, isEmpty);
        expect(await store.heldReleases(), ['release:fork:1']);
        final os = await storedOsId('release:fork:1');
        AlertPolicy.sleepSource = const AwakeAlertSleepSource();
        expect(await center.emit(event()), isTrue);
        expect(shown.single.osId, os, reason: 'the held claim is reused, not reallocated');
        expect(await store.heldReleases(), isEmpty);
        expect(await center.emit(event()), isFalse);
        expect(shown, hasLength(1));
      });

      test('quiet hours hold; the same claim goes out after they end', () async {
        await const NotificationPrefs(
          quietEnabled: true,
          quietStartMin: 22 * 60,
          quietEndMin: 7 * 60,
        ).save();
        await withClock(Clock.fixed(DateTime(2026, 11, 15, 23)), () async {
          expect(await center.emit(event()), isFalse);
        });
        expect(shown, isEmpty);
        expect(await store.heldReleases(), hasLength(1));
        await withClock(Clock.fixed(DateTime(2026, 11, 16, 8)), () async {
          expect(await center.emit(event()), isTrue);
        });
        expect(shown, hasLength(1));
      });

      // catches: a permission denial spending the permanent claim.
      test('denied permission gives the claim back and never prompts', () async {
        center.claimedPermission = () async => false;
        expect(await center.emit(event()), isFalse);
        expect(await store.heldReleases(), isEmpty);
        center.claimedPermission = () async => true;
        expect(await center.emit(event()), isTrue);
        expect(shown, hasLength(1));
      });

      // WHY: consent is checked again after every await between claim and show.
      // catches: delivering a stale announcement after the user opted out.
      test('opt-out between claim and presentation shows nothing and frees the claim', () async {
        center.claimedPermission = () async {
          await store.setEnabled(false);
          return true;
        };
        expect(await center.emit(event()), isFalse);
        expect(shown, isEmpty);
        await store.setEnabled(true);
        center.claimedPermission = () async => true;
        expect(await center.emit(event()), isTrue);
      });

      // WHY: at most once beats exactly once (owner 2026-11-17, R12).
      test('an ambiguous hand-off keeps the claim consumed', () async {
        center.presentTimeout = const Duration(milliseconds: 60);
        center.presentSink = (e, {bool allowPermissionPrompt = true}) =>
            Completer<bool>().future;
        expect(await center.emit(event()), isFalse);
        center.presentSink = (e, {bool allowPermissionPrompt = true}) async {
          shown.add(e);
          return true;
        };
        expect(await center.emit(event()), isFalse);
        expect(shown, isEmpty);
      });

      test('known non-delivery stays retryable', () async {
        var refuse = true;
        center.presentSink = (e, {bool allowPermissionPrompt = true}) async {
          if (refuse) return false;
          shown.add(e);
          return true;
        };
        expect(await center.emit(event()), isFalse);
        refuse = false;
        expect(await center.emit(event()), isTrue);
      });

      // catches: a payload that is not a checked release identity reaching the OS.
      for (final bad in [
        event(route: 'https://evil.test/a.apk'),
        event(route: '/release?source=fork&tag=nope'),
        event(source: 'official', route: releaseRoute(ReleaseSource.fork, 'next-2026.11.15')),
        event(id: 0),
        NotificationEvent(
          dedupeKey: 'release:fork:1',
          category: NotifCategory.updates,
          priority: NotifPriority.critical,
          title: 't',
          body: 'b',
          date: '2026-11-15',
          route: releaseRoute(ReleaseSource.fork, 'next-2026.11.15'),
        ),
        NotificationEvent(
          dedupeKey: 'release:fork:1',
          category: NotifCategory.updates,
          title: 't',
          body: 'b',
          date: '2026-11-15',
        ),
      ]) {
        test('refuses and consumes nothing for ${bad.dedupeKey} ${bad.route} ${bad.priority.name}', () async {
          expect(await center.emit(bad), isFalse);
          expect(shown, isEmpty);
          expect(await store.db.query('update_notifications'), isEmpty);
        });
      }
    });
  }

  group('central routing', () {
    AlertRule rule(int destinations) => AlertRule(
      id: 'updates',
      kind: 'updates',
      destinations: destinations,
      channelPolicyId: 'updates',
    );

    // WHY: one release claim across every routed destination, and never a
    // second claim in the health database (spec §2 dispatcher row).
    test('phone and band each fire once; a second discovery fires neither', () async {
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, true);
      center.updateRule = rule(AlertRule.phone | AlertRule.band);
      final before = LocalDb.debugHandleRequests;
      final reached = await center.emitReaching(event());
      expect(reached, {'phone', 'band'});
      expect(shown, hasLength(1));
      expect(bandBuzzes, 1);
      expect(await center.emitReaching(event()), isEmpty);
      expect(bandBuzzes, 1);
      expect(shown, hasLength(1));
      expect(await store.claimTarget('release:fork:1', 'band'), isFalse);
      expect(LocalDb.debugHandleRequests, before);
    });

    // catches: the pre-dispatcher path buzzing the band, which it cannot reach.
    test('with the dispatcher off only the phone is reached', () async {
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, false);
      center.updateRule = rule(AlertRule.phone | AlertRule.band);
      expect(await center.emitReaching(event()), {'phone'});
      expect(bandBuzzes, 0);
    });

    // WHY: global fallback destination (owner 2026-11-17, P6): phone by default.
    test('an unavailable band falls back to the phone, once', () async {
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, true);
      center.updateRule = rule(AlertRule.band);
      bandConnected = false;
      expect(await center.emitReaching(event()), {'phone'});
      expect(await center.emitReaching(event()), isEmpty);
      expect(bandBuzzes, 0);
      expect(shown, hasLength(1));
    });

    test('no reachable destination is non-delivery: the claim is given back', () async {
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, true);
      await const NotificationPrefs(
        quietEnabled: false,
        fallbackDestination: AlertDestination.band,
      ).save();
      center.updateRule = rule(AlertRule.band);
      bandConnected = false;
      expect(await center.emitReaching(event()), isEmpty);
      expect(await store.heldReleases(), isEmpty);
      bandConnected = true;
      expect(await center.emitReaching(event()), {'band'});
    });
  });

  group('the coordinator and held announcements', () {
    late UpdateCoordinator service;
    late DateTime now;
    late List<http.Request> requests;

    UpdateCoordinator build(String version) => UpdateCoordinator(
      store: store,
      client: MockClient((r) async {
        requests.add(r);
        return http.Response(
          '[${r.url.path.contains('OpenStrap') ? _json(release('v0.12.3', id: 9)) : ''}]',
          200,
        );
      }),
      installed: InstalledRelease(version: version, build: 81, fork: true, mode: 'profile'),
      clock: Clock(() => now),
      unmetered: () async => true,
      schedule: (_) async {},
      onRelease: notifyRelease,
    );

    setUp(() {
      now = DateTime.utc(2026, 11, 15, 12);
      requests = [];
      service = build('0.12.2-dev');
    });
    tearDown(() => service.dispose());

    // WHY: no checker-owned quiet-hour retry exists; the shared owner re-offers
    // a held cached candidate on its own recovery passes, with no network.
    test('a held announcement is released from cache without a request', () async {
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, true);
      AlertPolicy.sleepSource = const AsleepAlertSleepSource();
      await service.check(manual: true);
      expect(shown, isEmpty);
      expect(await store.heldReleases(), ['release:official:9']);
      final sent = requests.length;
      AlertPolicy.sleepSource = const AwakeAlertSleepSource();
      await service.releaseHeld();
      expect(requests, hasLength(sent));
      expect(shown, hasLength(1));
      expect(shown.single.route, releaseRoute(ReleaseSource.official, 'v0.12.3'));
      await service.releaseHeld();
      expect(shown, hasLength(1));
    });

    // catches: delivering a release the install has since caught up with.
    test('the relationship is revalidated before a held release goes out', () async {
      AlertPolicy.sleepSource = const AsleepAlertSleepSource();
      await service.check(manual: true);
      expect(await store.heldReleases(), hasLength(1));
      service.dispose();
      service = build('0.12.3-dev'); // upgraded meanwhile: v0.12.3 is now equal
      await service.load();
      AlertPolicy.sleepSource = const AwakeAlertSleepSource();
      await service.releaseHeld();
      expect(shown, isEmpty);
    });

    test('opting out cancels held checker intents', () async {
      AlertPolicy.sleepSource = const AsleepAlertSleepSource();
      await service.check(manual: true);
      expect(await store.heldReleases(), hasLength(1));
      await service.setEnabled(true);
      await service.setEnabled(false);
      expect(await store.heldReleases(), isEmpty);
    });
  });
}

String _json(Map<String, Object?> m) => jsonEncode(m);
