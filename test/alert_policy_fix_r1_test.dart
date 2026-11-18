// WHY: fix round 1 of the central alert policy (Opus review S1-S8). Every case
// runs through the production wiring (policy + fallbackDestination +
// latestRule from AlertPolicy, rules saved in NotificationPrefs), because the
// first round's tests passed with a hand-built dispatcher that hid S2 and S3.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_cues.dart' show kEcgCueRule;
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart'
    show hardwareProbeRule;
import 'package:openstrap_edge/gestures/tap_ack.dart' show kGestureAckRule;
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_policy.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart' show BuzzDelivery;
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;
import 'backup/backup_support.dart';
import 'support/settings_sections.dart';
import 'support/alert_sleep_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('alert_policy_fix_r1.db'));
  tearDownAll(() => env.dispose());
  setUp(() async {
    await env.wipe();
    AlertPolicy.sleepSource = const AwakeAlertSleepSource();
  });
  tearDown(() => AlertPolicy.sleepSource = const StoredAlertSleepSource());

  int minuteNow() => DateTime.now().hour * 60 + DateTime.now().minute;

  /// Global quiet hours that contain the present, saved with [rules].
  Future<void> saveQuietNow(Map<String, AlertRule> rules,
      {bool healthEnabled = true}) async {
    final m = minuteNow();
    await NotificationPrefs(
      quietEnabled: true,
      quietStartMin: (m - 5 + 1440) % 1440,
      quietEndMin: (m + 55) % 1440,
      healthEnabled: healthEnabled,
      alertRules: rules,
    ).save();
  }

  Future<void> saveAwake(Map<String, AlertRule> rules) async =>
      NotificationPrefs(quietEnabled: false, alertRules: rules).save();

  AlertDispatcher production({
    Future<bool> Function()? phone,
    bool Function()? connected,
  }) => AlertDispatcher(
    phone: phone ?? () async => false,
    band: () async => true,
    isConnected: connected ?? () => true,
    policy: AlertPolicy.permits,
    fallbackDestination: AlertPolicy.fallback,
    latestRule: AlertPolicy.currentRule,
    ledger: MemoryAlertDeliveryLedger(),
  );

  // ---------------------------------------------------------------- S1
  group('S1 relayed alarms are wake class', () {
    Future<(int, int)> relayOnce(String category, {required bool sleep}) async {
      var buzzes = 0, cards = 0;
      final rule = NotificationPrefs.legacyRule('relay', true, 2);
      if (sleep) {
        AlertPolicy.sleepSource = const AsleepAlertSleepSource();
        await saveAwake({'relay': rule});
      } else {
        await saveQuietNow({'relay': rule});
      }
      final prefs = await NotificationPrefs.load();
      final c = RelayController(
        dispatcher: production(phone: () async { cards++; return true; }),
        buzz: (_) async { buzzes++; return true; },
        phone: () async { cards++; return true; },
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
        policy: (_) => {'enabled': true, 'packages': ['app'],
          'quietEnabled': prefs.quietEnabled,
          'quietStartMin': prefs.quietStartMin,
          'quietEndMin': prefs.quietEndMin},
      );
      addTearDown(c.dispose);
      for (final name in ['apps', 'alarms', 'calls']) {
        c.channels[name] = c.channels[name]!.copyWith(enabled: true);
      }
      await c.listenerConnected(const []);
      await c.handleMetadata({'kind': 'post', 'keyHash': category,
        'package': 'app', 'category': category,
        'postTimeMs': DateTime.now().millisecondsSinceEpoch});
      return (buzzes, cards);
    }

    // CLAIM(alert-release): owner rule, alarm/wake always sends.
    for (final sleep in [false, true]) {
      final when = sleep ? 'sleep' : 'quiet hours';
      test('alarms channel reaches the band in $when', () async {
        expect((await relayOnce('alarm', sleep: sleep)).$1, 1);
      });
      test('apps and calls channels stay held in $when', () async {
        expect((await relayOnce('msg', sleep: sleep)).$1, 0);
        await env.wipe();
        expect((await relayOnce('call', sleep: sleep)).$1, 0);
      });
    }
  });

  // ---------------------------------------------------------------- S2
  group('S2 a known band refusal moves to the fallback', () {
    final rule = NotificationPrefs.legacyRule('health', true, 2);

    test('saved band-only rule, band still connected: phone gets it', () async {
      await saveAwake({'health': rule});
      var phones = 0;
      final result = await production(phone: () async { phones++; return true; })
          .dispatch(rule, eventId: 's2', sourceTime: DateTime.now(),
              historical: false,
              bandDelivery: () async => BuzzDelivery.rejected);
      expect(result.targets, ['phone']);
      expect(phones, 1);
    });

    test('quiet hours reached while the band refused still hold the phone',
        () async {
      await saveAwake({'health': rule});
      var phones = 0;
      final result = await production(phone: () async { phones++; return true; })
          .dispatch(rule, eventId: 's2-quiet', sourceTime: DateTime.now(),
              historical: false, bandDelivery: () async {
                await saveQuietNow({'health': rule});
                return BuzzDelivery.rejected;
              });
      expect(result.targets, isEmpty);
      expect(phones, 0);
    });
  });

  // ---------------------------------------------------------------- S3
  group('S3 the relay fallback toggle is honoured', () {
    Future<int> cardsWith({required bool phoneFallback}) async {
      await saveAwake({'relay': NotificationPrefs.legacyRule('relay', true, 2)});
      var cards = 0;
      final c = RelayController(
        dispatcher: production(
            phone: () async { cards++; return true; }, connected: () => false),
        buzz: (_) async => true,
        phone: () async { cards++; return true; },
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
        policy: (_) => {'enabled': true, 'packages': ['app']},
      );
      addTearDown(c.dispose);
      c.channels['apps'] =
          c.channels['apps']!.copyWith(phoneFallback: phoneFallback);
      await c.listenerConnected(const []);
      await c.handleMetadata({'kind': 'post', 'keyHash': 'k', 'package': 'app',
        'category': 'msg', 'postTimeMs': DateTime.now().millisecondsSinceEpoch});
      return cards;
    }

    test('toggle off: no relayed-alert card while the band is away', () async {
      expect(await cardsWith(phoneFallback: false), 0);
    });
    test('toggle on: exactly one card', () async {
      expect(await cardsWith(phoneFallback: true), 1);
    });
  });

  // ------------------------------------------------------------ S4 + S8
  group('user-started buzzes and session cues are not held', () {
    final rules = <String, AlertRule>{
      'preview/test buzz/find band': kBuzzPreviewRule,
      'device-lab probe': hardwareProbeRule,
      'ECG cue': kEcgCueRule,
      'gesture tap-ack': kGestureAckRule,
    };
    for (final MapEntry(:key, :value) in rules.entries) {
      for (final sleep in [false, true]) {
        test('$key reaches the band in ${sleep ? 'sleep' : 'quiet hours'}',
            () async {
          if (sleep) {
            AlertPolicy.sleepSource = const AsleepAlertSleepSource();
            await saveAwake({});
          } else {
            await saveQuietNow({});
          }
          final result = await production().dispatch(value, eventId: key,
              sourceTime: DateTime.now(), historical: false,
              bandDelivery: () async => BuzzDelivery.complete);
          expect(result.targets, ['band'], reason: result.suppressionReason);
        });
      }
    }

    test('breathing session cues pass quiet hours; tasker stays held', () async {
      await saveQuietNow({
        'breath': NotificationPrefs.legacyRule('breath', true, 2),
        'tasker': NotificationPrefs.legacyRule('tasker', true, 2),
      });
      final prefs = await NotificationPrefs.load();
      expect(await AlertPolicy.permits(prefs.alertRule('breath'), 'band'), isTrue);
      expect(await AlertPolicy.permits(prefs.alertRule('tasker'), 'band'), isFalse);
    });

    test('a refusal names its real reason, not the band', () {
      String msg(String? r) => AppState.userBuzzFailureMessage(r);
      expect(msg('channelSuppressed'), isNot(contains('quiet hours')));
      expect(msg('bandUnavailable'), contains('Connect'));
      expect(msg('stale'), isNot(contains('did not take')));
      expect(msg('transportUnavailable'), isNot(contains('did not take')));
      expect(msg('deliveryFailed'), contains('did not take the buzz'));
    });
  });

  // ---------------------------------------------------------------- S5
  group('S5 fallback row copy is localized', () {
    const keys = ['settingsFallbackRowTitle', 'settingsFallbackPhone',
      'settingsFallbackBand'];
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;

    test('the three keys exist in all 8 locales and are translated', () {
      final en = arb('en');
      for (final code in ['de', 'en', 'es', 'fr', 'hi', 'ru', 'th', 'zh']) {
        final m = arb(code);
        for (final k in keys) {
          expect(m[k], isA<String>(), reason: '$code is missing $k');
          // "Band" is the German word too.
          if (code != 'en' && !(code == 'de' && k == 'settingsFallbackBand')) {
            expect(m[k], isNot(en[k]), reason: '$code $k is still English');
          }
        }
      }
    });

    test('the quiet-hours subtitle no longer says nothing buzzes', () {
      expect(arb('en')['settingsQuietHoursRowSub'],
          'Only alarms, medication and wake alerts come through');
      expect(arb('es')['settingsFallbackBand'], 'Banda');
      expect(arb('hi')['settingsFallbackBand'], 'बैंड');
      for (final code in ['de', 'es', 'fr', 'hi', 'ru', 'th', 'zh']) {
        expect(arb(code)['settingsQuietHoursRowSub'],
            isNot(arb('en')['settingsQuietHoursRowSub']),
            reason: '$code is not translated');
      }
    });

    testWidgets('the row follows the app locale', (tester) async {
      tester.view.physicalSize = const Size(1170, 24000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NotificationSettingsView(
            prefs: const NotificationPrefs(), onChanged: (_) async {}),
      ));
      await tester.pumpAndSettle();
      await openSettingsSection(tester,
          lookupAppLocalizations(const Locale('es')).settingsGroupQuietHours);
      final es = arb('es');
      expect(find.text('If unavailable, send to'), findsNothing);
      expect(find.text('${es['settingsFallbackRowTitle']}'), findsOneWidget);
      expect(find.text('${es['settingsFallbackPhone']}'), findsOneWidget);
    });
  });

  test('the fallback destination default stays the phone', () async {
    await saveAwake({});
    expect(await AlertPolicy.fallback(), 'phone');
  });
}
