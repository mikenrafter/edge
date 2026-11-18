// WHY: round-2 regressions must exercise saved policy and real transport hops.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_policy.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/state/feature_flags.dart';

import 'backup/backup_support.dart';
import 'support/alert_sleep_source.dart';

class _DisconnectLedger extends MemoryAlertDeliveryLedger {
  _DisconnectLedger(this.disconnect);
  final void Function() disconnect;
  @override
  Future<bool> claim(String key) async {
    disconnect();
    return super.claim(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('alert_policy_fix_r2.db'));
  tearDownAll(() => env.dispose());
  setUp(() async {
    await env.wipe();
    AlertPolicy.sleepSource = const AwakeAlertSleepSource();
    FeatureFlags.resetForTest();
    FeatureFlags.debugSet(FeatureFlag.nativeRelay, true);
    FeatureFlags.debugSet(FeatureFlag.alertDispatcher, true);
  });
  tearDown(() {
    AlertPolicy.sleepSource = const StoredAlertSleepSource();
    FeatureFlags.resetForTest();
  });

  AlertDispatcher production({bool Function()? connected,
      Future<bool> Function()? phone, AlertDeliveryLedger? ledger}) =>
      AlertDispatcher(
        policy: AlertPolicy.permits,
        fallbackDestination: AlertPolicy.fallback,
        latestRule: AlertPolicy.currentRule,
        phone: phone ?? () async => false,
        band: () async => false,
        isConnected: connected ?? () => true,
        ledger: ledger ?? MemoryAlertDeliveryLedger(),
      );

  Future<NotificationPrefs> save({bool quiet = false,
      AlertDestination fallback = AlertDestination.phone}) async {
    final now = DateTime.now();
    final minute = now.hour * 60 + now.minute;
    final prefs = NotificationPrefs(
      quietEnabled: quiet,
      quietStartMin: (minute + 1435) % 1440,
      quietEndMin: (minute + 55) % 1440,
      fallbackDestination: fallback,
      alertRules: {
        for (final id in ['relay', 'breath', 'wake'])
          id: NotificationPrefs.legacyRule(id, true, 2),
      },
    );
    await prefs.save();
    return prefs;
  }

  Map<String, Object?> post(String category) => {
    'kind': 'post', 'keyHash': category, 'package': 'app',
    'category': category, 'postTimeMs': DateTime.now().millisecondsSinceEpoch,
  };

  // WHY / CLAIM(alert-release): production supplies GLOBAL quiet keys even
  // when alarms have no override; only their own override may hold the band.
  for (final override in [false, true]) {
    test('S1 alarm with production global quiet keys, override=$override', () async {
      final prefs = await save(quiet: true);
      var buzzes = 0;
      final c = RelayController(
        dispatcher: production(),
        buzz: (_) async { buzzes++; return true; },
        phone: () async => false,
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
        policy: (_) => {'enabled': true, 'packages': ['app'],
          'quietEnabled': prefs.quietEnabled,
          'quietStartMin': prefs.quietStartMin,
          'quietEndMin': prefs.quietEndMin},
      );
      addTearDown(c.dispose);
      c.channels['alarms'] = c.channels['alarms']!.copyWith(enabled: true,
        overrideQuietHours: override, quietStartMinute: prefs.quietStartMin,
        quietEndMinute: prefs.quietEndMin);
      await c.listenerConnected(const []);
      final result = await c.handleMetadata(post('alarm'));
      expect(buzzes, override ? 0 : 1);
      expect(result.targets, override ? isEmpty : ['band']);
      if (override) expect(result.suppression, 'quietHours');
    });
  }

  // WHY: the phone's bedtime DND must not silence relayed alarms by default;
  // an explicit channel choice to respect it still applies.
  for (final allow in [true, false]) {
    test('alarm default passes DND; allow=$allow', () async {
      await save();
      var buzzes = 0;
      final c = RelayController(dispatcher: production(),
        buzz: (_) async { buzzes++; return true; }, phone: () async => false,
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
        policy: (_) => {'enabled': true, 'dnd': true});
      addTearDown(c.dispose);
      c.channels['alarms'] = allow
          ? c.channels['alarms']!.copyWith(enabled: true)
          : c.channels['alarms']!.copyWith(enabled: true, allowDuringDnd: false);
      await c.listenerConnected(const []);
      await c.handleMetadata(post('alarm'));
      expect(buzzes, allow ? 1 : 0);
    });
  }

  // WHY: skipped breath phases are intentional queue refusals, not alerts.
  // The saved global phone fallback must still cover a refused wake rhythm.
  for (final id in ['breath', 'wake']) {
    test('S2 rejected immediate $id cue uses only alert fallback', () async {
      await save();
      final queue = BandHapticQueue(ledger: BandCommandLedger());
      queue.beginLab(); // a phase cannot start immediately while the lab owns it
      addTearDown(queue.endLab);
      var cards = 0, writes = 0;
      BuzzDelivery? bandResult;
      final rule = (await NotificationPrefs.load()).alertRule(id);
      final result = await production(phone: () async { cards++; return true; })
          .dispatch(rule, eventId: id, sourceTime: DateTime.now(),
            historical: false, bandDelivery: () async {
              bandResult = await queue.asImmediate(() => queue.run((token) async {
                writes++;
                return BuzzDelivery.complete;
              }, commands: 1, timeout: const Duration(seconds: 1)));
              return bandResult!;
            });
      expect(bandResult, BuzzDelivery.rejected);
      expect(writes, 0);
      expect(queue.pending, 0);
      expect(cards, id == 'breath' ? 0 : 1);
      expect(result.targets, id == 'breath' ? isEmpty : ['phone']);
    });
  }

  // WHY: test the real relay -> _phoneFallback -> NotificationCenter.emit hop,
  // where a saved global Band fallback used to override the channel twice.
  for (final dispatcherOn in [false, true]) {
    for (final on in [false, true]) {
      for (final quiet in [false, true]) {
        test('S3 real card hop, global Band, on=$on quiet=$quiet dispatcher=$dispatcherOn', () async {
          await save(quiet: quiet, fallback: AlertDestination.band);
          FeatureFlags.debugSet(FeatureFlag.alertDispatcher, dispatcherOn);
          var cards = 0;
          final center = NotificationCenter.instance;
          final oldSink = center.presentSink, oldDispatcher = center.dispatcher;
          addTearDown(() { center.presentSink = oldSink; center.dispatcher = oldDispatcher; });
          center.presentSink = (_, {allowPermissionPrompt = true}) async {
            cards++; return true;
          };
          center.dispatcher = production(connected: () => false);
          const channel = MethodChannel('openstrap/notification_relay');
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async =>
                  call.method == 'isPermissionGranted' ? true : null);
          addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null));
          final relay = NotificationRelay(buzz: () async {},
            isConnected: () => false, debugSupported: true,
            dispatcher: production(connected: () => false));
          addTearDown(relay.dispose);
          await relay.setEnabled(true);
          await relay.refreshPermission();
          // Alarm band delivery passes quiet hours; its extra card stays held.
          await relay.setChannel('alarms', relay.controller.channels['alarms']!
              .copyWith(enabled: true, phoneFallback: on));
          await relay.controller.listenerConnected(const []);
          final result = await relay.controller.handleMetadata(post('alarm'));
          expect(cards, on && !quiet ? 1 : 0);
          expect(result.targets, on && !quiet ? ['phone'] : isEmpty);
        });
      }
    }
  }

  // WHY / CLAIM(alert-handoff): a future direct caller must fail closed before
  // queueing or writing, while lab probes remain usable without alert policy.
  test('S4 non-lab queue job without handoff asserts and logs', () async {
    final logs = <String>[];
    var writes = 0;
    final queue = BandHapticQueue(ledger: BandCommandLedger(), log: logs.add);
    Future<BuzzDelivery> job(BandJobToken _) async {
      writes++;
      return BuzzDelivery.complete;
    }
    expect(() => queue.run(job, commands: 1,
        timeout: const Duration(seconds: 1)), throwsAssertionError);
    expect(logs, contains(contains('missing alert handoff')));
    expect(queue.pending, 0);
    expect(writes, 0);
    expect(await queue.run(job, commands: 1, settle: Duration.zero,
        timeout: const Duration(seconds: 1), lab: true), BuzzDelivery.complete);
    expect(writes, 1);
  });

  // WHY: if the band drops during the durable claim and the phone also fails,
  // the caller needs the original availability reason to offer the right fix.
  test('empty refusal retry retains bandUnavailable', () async {
    await save();
    var connected = true, cards = 0;
    final rule = (await NotificationPrefs.load()).alertRule('wake');
    final result = await production(connected: () => connected,
      ledger: _DisconnectLedger(() => connected = false),
      phone: () async { cards++; return false; })
        .dispatch(rule, eventId: 'disconnect', sourceTime: DateTime.now(),
            historical: false, bandDelivery: () async => BuzzDelivery.complete);
    expect(cards, 1);
    expect(result.targets, isEmpty);
    expect(result.suppressionReason, 'bandUnavailable');
  });
}
