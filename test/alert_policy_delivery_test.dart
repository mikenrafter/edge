import 'support/band_handoff.dart' show withBandHandoff;
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/alert_sleep_source.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_policy.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/state/feature_flags.dart';
import 'backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('alert_policy_delivery.db'));
  tearDownAll(() => env.dispose());
  setUp(() async {
    await env.wipe();
    await const NotificationPrefs(quietEnabled: false).save();
    FeatureFlags.resetForTest();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    NotificationService.instance.debugRequestPermission = null;
    NotificationService.instance.invalidatePermissionCache();
    FeatureFlags.resetForTest();
  });

  NotificationEvent event(String key) => NotificationEvent(dedupeKey: key,
    category: NotifCategory.health, priority: NotifPriority.critical,
    title: 'Health', body: '', date: todayLabel());

  // WHY / CLAIM(alert-central): health holds even with the dispatcher disabled.
  for (final enabled in [false, true]) {
    test('stored sleep holds health then releases once, dispatcher=$enabled', () async {
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, enabled);
      final now = DateTime.now();
      final minute = now.hour * 60 + now.minute;
      final sp = await SharedPreferences.getInstance();
      await sp.setString('expected_sleep_schedule_v1',
        '{"onsetMinute":$minute,"wakeMinute":${(minute + 120) % 1440}}');
      var shown = 0;
      final center = NotificationCenter.instance;
      final oldSink = center.presentSink, oldDispatcher = center.dispatcher;
      addTearDown(() { center.presentSink = oldSink; center.dispatcher = oldDispatcher; });
      center.presentSink = (_, {allowPermissionPrompt = true}) async { shown++; return true; };
      center.dispatcher = AlertDispatcher(phone: () async => false,
        band: () async => false, isConnected: () => false,
        policy: AlertPolicy.permits, fallbackDestination: AlertPolicy.fallback,
        ledger: MemoryAlertDeliveryLedger());
      final e = event('health:$enabled');
      expect(await center.emit(e), isFalse);
      expect(shown, 0);
      await sp.remove('expected_sleep_schedule_v1');
      expect(await center.emit(e), isTrue);
      expect(await center.emit(e), isFalse);
      expect(shown, 1);
    });
  }

  test('sleep storage failure refuses rather than assuming awake', () async {
    final load = AlertPolicy.sleepSource;
    addTearDown(() => AlertPolicy.sleepSource = load);
    AlertPolicy.sleepSource = const FailedAlertSleepSource();
    final center = NotificationCenter.instance;
    var shown = 0;
    final previous = center.presentSink;
    addTearDown(() => center.presentSink = previous);
    center.presentSink = (_, {allowPermissionPrompt = true}) async { shown++; return true; };
    expect(await center.emit(event('failed-sleep')), isFalse);
    expect(shown, 0);
    AlertPolicy.sleepSource = load;
    expect(await center.emit(event('failed-sleep')), isTrue);
    expect(shown, 1);
  });

  // WHY / CLAIM(alert-handoff): quiet settings changed during authorization
  // must be read after permission and OS-id allocation, before the plugin show.
  test('phone permission wait cannot carry health across quiet start', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    var shows = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'show') shows++;
        return true;
      });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
    final service = NotificationService.instance;
    service.invalidatePermissionCache();
    var permissionWaits = 0;
    service.debugRequestPermission = () async {
      permissionWaits++;
      final minute = DateTime.now().hour * 60 + DateTime.now().minute;
      await NotificationPrefs(quietStartMin: minute,
        quietEndMin: (minute + 60) % 1440).save();
      return true;
    };
    final center = NotificationCenter.instance;
    final previous = center.presentSink;
    addTearDown(() => center.presentSink = previous);
    center.presentSink = service.presentEvent;
    expect(await center.emit(event('permission')), isFalse);
    expect(permissionWaits, 1);
    expect(shows, 0);
    await const NotificationPrefs(quietEnabled: false).save();
    service.invalidatePermissionCache();
    service.debugRequestPermission = () async => true;
    expect(await center.emit(event('permission')), isTrue);
    expect(shows, 1);
  });

  // WHY / CLAIM(alert-band-handoff): retain the check across queue ownership
  // and repeat it for every command in a saved pattern.
  test('queued band writes recheck after waiting and between commands', () async {
    final queue = BandHapticQueue(ledger: BandCommandLedger());
    final release = Completer<void>();
    final first = withBandHandoff(() => queue.run((_) async { await release.future; return BuzzDelivery.complete; },
      commands: 0, timeout: const Duration(seconds: 10), settle: Duration.zero));
    var allowed = true, writes = 0;
    final dispatcher = AlertDispatcher(phone: () async => false,
      band: () async => false, isConnected: () => true,
      ledger: MemoryAlertDeliveryLedger(),
      policy: (_, _) async => allowed);
    final rule = NotificationPrefs.legacyRule('health', true, 2);
    final queued = dispatcher.dispatch(rule, eventId: 'queued', sourceTime: DateTime.now(),
      historical: false, bandDelivery: () => queue.run((job) async {
        final ok = await job.write(() async { writes++; return true; });
        return ok ? BuzzDelivery.complete : BuzzDelivery.rejected;
      }, commands: 1, timeout: const Duration(seconds: 10), settle: Duration.zero));
    // Wait until the band job is queued behind the first, without wall time.
    await Future<void>.delayed(Duration.zero);
    allowed = false;
    release.complete();
    await first;
    expect((await queued).targets, isEmpty);
    expect(writes, 0);
    allowed = true;
    final result = await dispatcher.dispatch(rule, eventId: 'pattern',
      sourceTime: DateTime.now(), historical: false,
      bandDelivery: () => queue.run((job) async {
        expect(await job.write(() async { writes++; allowed = false; return true; }), isTrue);
        expect(await job.write(() async { writes++; return true; }), isFalse);
        return BuzzDelivery.partial;
      }, commands: 2, timeout: const Duration(seconds: 10), settle: Duration.zero));
    expect(result.suppressionReason, 'deliveryUnconfirmed');
    expect(writes, 1);
  });

  test('medication and explicit reminder reach phone and band during sleep', () async {
    final minute = DateTime.now().hour * 60 + DateTime.now().minute;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('expected_sleep_schedule_v1',
      '{"onsetMinute":$minute,"wakeMinute":${(minute + 120) % 1440}}');
    for (final kind in ['meds', 'reminders']) {
      final rule = NotificationPrefs.legacyRule(kind, true, 3)
          .copyWith(userScheduled: kind == 'reminders');
      await NotificationPrefs(quietStartMin: minute, quietEndMin: (minute + 60) % 1440,
        medsEnabled: true, alertRules: {kind: rule}).save();
      var phones = 0, bands = 0;
      final dispatcher = AlertDispatcher(phone: () async { phones++; return true; },
        band: () async { bands++; return true; }, isConnected: () => true,
        policy: AlertPolicy.permits, ledger: MemoryAlertDeliveryLedger());
      final result = await dispatcher.dispatch(rule, eventId: kind,
        sourceTime: DateTime.now(), historical: false);
      // The generic reminders band producer is absent; meds has a live one.
      expect(phones, 1);
      expect(bands, kind == 'meds' ? 1 : 0);
      expect(result.targets, kind == 'meds' ? ['phone', 'band'] : ['phone']);
    }
  });

  // WHY / CLAIM(alert-fallback): unsupported schedules and disconnected bands
  // reach only the configured executable fallback, without inventing a timer.
  test('global fallback covers unsupported scheduled band producers', () async {
    for (final kind in ['checkIn', 'windDown', 'reminders', 'alarmNightCheck']) {
      var phones = 0, bands = 0;
      final dispatcher = AlertDispatcher(phone: () async { phones++; return true; },
        band: () async { bands++; return true; }, isConnected: () => true,
        ledger: MemoryAlertDeliveryLedger(), fallbackDestination: () async => 'phone');
      final rule = NotificationPrefs.legacyRule(kind, true, 2);
      expect(AlertCapabilityRegistry.destinationSupportReason(rule, 'band'),
        'bandScheduleUnavailable');
      final result = await dispatcher.dispatch(rule, eventId: kind,
        sourceTime: DateTime.now(), historical: false);
      expect(result.targets, ['phone']);
      expect(phones, 1);
      expect(bands, 0);
    }
  });
  test('band fallback retains hardware and interruption restrictions', () async {
    for (final connected in [false, true]) {
      var bands = 0;
      final dispatcher = AlertDispatcher(phone: () async => false,
        band: () async { bands++; return true; }, isConnected: () => connected,
        supportedTargets: const {'band'}, fallbackDestination: () async => 'band',
        ledger: MemoryAlertDeliveryLedger());
      final result = await dispatcher.dispatch(
        NotificationPrefs.legacyRule('health', true, 1), eventId: 'band-fallback',
        sourceTime: DateTime.now(), historical: false);
      expect(result.targets, connected ? ['band'] : isEmpty);
      expect(bands, connected ? 1 : 0);
    }
    final blocked = AlertDispatcher(phone: () async => false,
      band: () async => throw StateError('must not write'), isConnected: () => true,
      supportedTargets: const {'band'}, fallbackDestination: () async => 'band',
      policy: (_, _) async => false, ledger: MemoryAlertDeliveryLedger());
    expect((await blocked.dispatch(NotificationPrefs.legacyRule('health', true, 1),
      eventId: 'blocked', sourceTime: DateTime.now(), historical: false)).targets, isEmpty);
  });
  test('known band refusal falls back while ambiguous handoff never does', () async {
    for (final delivery in [BuzzDelivery.rejected, BuzzDelivery.partial, BuzzDelivery.unknown]) {
      var phones = 0;
      var connected = true;
      final dispatcher = AlertDispatcher(phone: () async { phones++; return true; },
        band: () async => false, isConnected: () => connected,
        fallbackDestination: () async => 'phone', ledger: MemoryAlertDeliveryLedger());
      final result = await dispatcher.dispatch(
        NotificationPrefs.legacyRule('health', true, 2), eventId: delivery.name,
        sourceTime: DateTime.now(), historical: false,
        bandDelivery: () async { connected = false; return delivery; });
      expect(phones, delivery == BuzzDelivery.rejected ? 1 : 0);
      expect(result.targets, delivery == BuzzDelivery.rejected ? ['phone'] : isEmpty);
      if (delivery != BuzzDelivery.rejected) {
        expect(result.suppressionReason, 'deliveryUnconfirmed');
      }
    }
  });
}
