import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/notify/reminder_sleep_gate.dart';
import 'package:openstrap_edge/notify/water_buzzer.dart';
import 'sleep_gate_test.dart' show at, nocturnal;

NotificationPrefs bandPrefs({required bool quiet}) => NotificationPrefs(
  waterEnabled: true,
  quietEnabled: quiet,
  alertRules: const {
    'water': AlertRule(
      id: 'water',
      kind: 'water',
      destinations: 2,
      executionMode: AlertExecutionMode.phoneLive,
      channelPolicyId: 'water',
    ),
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    NotificationService.instance.debugRequestPermission = () async => true;
    NotificationService.instance.debugProbePermission = () async => true;
    NotificationService.instance.invalidatePermissionCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    calls.clear();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    NotificationService.instance.debugProbePermission = null;
    NotificationService.instance.debugRequestPermission = null;
    NotificationService.instance.invalidatePermissionCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'real OS scheduler omits sleeping water times and retains awake slots',
    () async {
      await NotificationCenter.instance.scheduleStandingReminders(
        const NotificationPrefs(waterEnabled: true),
        sleep: nocturnal,
      );
      final water =
          calls
              .where(
                (c) =>
                    c.method == 'zonedSchedule' &&
                    (c.arguments as Map)['title'] == 'Water',
              )
              .map((c) {
                final d = DateTime.parse(
                  (c.arguments as Map)['scheduledDateTime'] as String,
                );
                return d.hour * 60 + d.minute;
              })
              .toList()
            ..sort();
      // Positive control: this captured the actual plugin transport.
      expect(water, contains(1020));
      expect(water, [420, 1020, 1140, 1260]);
    },
  );
  test(
    'detected ongoing sleep cancels pending OS water interruptions',
    () async {
      await NotificationCenter.instance.scheduleStandingReminders(
        const NotificationPrefs(waterEnabled: true),
        sleep: ReminderSleepGate(periods: [ReminderSleepPeriod(at(0))]),
      );
      expect(
        calls.where((c) => c.method == 'cancel').length,
        greaterThanOrEqualTo(NotificationService.maxWaterSlots),
      );
      expect(
        calls.where(
          (c) =>
              c.method == 'zonedSchedule' &&
              (c.arguments as Map)['title'] == 'Water',
        ),
        isEmpty,
      );
    },
  );
  test(
    'band timer suppresses both assumption callback and buzz then resumes once',
    () async {
      var gate = nocturnal;
      final logged = <DateTime>[], buzzed = <DateTime>[];
      final suppressed = <SuppressedReminderSlot>[];
      var firing = at(9);
      await bandPrefs(quiet: true).save();
      final buzzer = WaterBuzzer(
        isConnected: () => true,
        buzz: () async {
          buzzed.add(firing);
        },
        dispatcher: AlertDispatcher(
          phone: () async => false,
          band: () async {
            buzzed.add(firing);
            return true;
          },
          isConnected: () => true,
          now: () => firing,
          ledger: MemoryAlertDeliveryLedger(),
        ),
        onSlot: (s) async {
          logged.add(s);
        },
        sleep: () => gate,
        onSuppressed: suppressed.add,
      );
      addTearDown(buzzer.dispose);
      // No wall-clock timer; drive exactly the callback used by the real timer.
      buzzer.configure(enabled: true, slotMinutes: []);
      for (final h in [9, 11, 13, 15, 17]) {
        firing = at(h);
        await buzzer.debugFireSlot(firing);
      }
      expect(logged, [at(17)]);
      expect(buzzed, [at(17)]);
      expect(suppressed.map((s) => s.at).toList(), [
        at(9),
        at(11),
        at(13),
        at(15),
      ]);
      expect(
        suppressed.map((s) => s.reason),
        everyElement(ReminderSuppression.sleepSchedule),
      );
      gate = ReminderSleepGate(periods: [ReminderSleepPeriod(at(18), at(20))]);
      firing = at(19);
      await buzzer.debugFireSlot(firing);
      firing = at(21);
      await buzzer.debugFireSlot(firing);
      expect(buzzed, [
        at(17),
        at(21),
      ], reason: 'no backlog delivered after waking');
    },
  );
  test(
    'awake nocturnal band slot fires but quiet hours still suppress it',
    () async {
      var gate = nocturnal;
      var buzzes = 0;
      final logged = <DateTime>[];
      final suppressed = <SuppressedReminderSlot>[];
      var firing = at(2);
      final buzzer = WaterBuzzer(
        isConnected: () => true,
        dispatcher: AlertDispatcher(
          phone: () async => false,
          band: () async {
            buzzes++;
            return true;
          },
          isConnected: () => true,
          now: () => firing,
          ledger: MemoryAlertDeliveryLedger(),
        ),
        buzz: () async {
          buzzes++;
        },
        onSlot: (s) async {
          logged.add(s);
        },
        sleep: () => gate,
        onSuppressed: suppressed.add,
      );
      addTearDown(buzzer.dispose);
      await bandPrefs(quiet: false).save();
      buzzer.configure(enabled: true, slotMinutes: []);
      await buzzer.debugFireSlot(at(2));
      expect(buzzes, 1);
      expect(logged, [at(2)]);
      await bandPrefs(quiet: true).save();
      gate = nocturnal;
      firing = at(4);
      await buzzer.debugFireSlot(firing);
      expect(buzzes, 1);
      expect(logged, [at(2)]);
      expect(suppressed.single.at, at(4));
      expect(suppressed.single.reason, ReminderSuppression.quietHours);
    },
  );
  test(
    'standing scheduler applies sleep gate to other periodic nudges',
    () async {
      await NotificationCenter.instance.scheduleStandingReminders(
        const NotificationPrefs(windDownEnabled: true, quietEnabled: false),
        bedtimeMinOfDay: 840,
        sleep: nocturnal,
      );
      expect(
        calls.where(
          (c) =>
              c.method == 'zonedSchedule' &&
              (c.arguments as Map)['id'] == NotificationService.idWindDown,
        ),
        isEmpty,
      );
    },
  );
  test(
    'production standing scheduler loads the saved sleep schedule',
    () async {
      SharedPreferences.setMockInitialValues({
        'expected_sleep_schedule_v1': '{"onsetMinute":480,"wakeMinute":960}',
      });
      await NotificationCenter.instance.scheduleStandingReminders(
        const NotificationPrefs(waterEnabled: true),
      );
      final water =
          calls
              .where(
                (c) =>
                    c.method == 'zonedSchedule' &&
                    (c.arguments as Map)['title'] == 'Water',
              )
              .map((c) {
                final d = DateTime.parse(
                  (c.arguments as Map)['scheduledDateTime'] as String,
                );
                return d.hour * 60 + d.minute;
              })
              .toList()
            ..sort();
      expect(water, contains(1020));
      expect(water, [420, 1020, 1140, 1260]);
    },
  );
  test(
    'production band callback loads sleep without an injected gate',
    () async {
      SharedPreferences.setMockInitialValues({
        'expected_sleep_schedule_v1': '{"onsetMinute":480,"wakeMinute":960}',
      });
      await bandPrefs(quiet: true).save();
      var buzzes = 0;
      final logged = <DateTime>[];
      final buzzer = WaterBuzzer(
        isConnected: () => true,
        buzz: () async {},
        onSlot: (s) async {
          logged.add(s);
        },
        dispatcher: AlertDispatcher(
          phone: () async => false,
          band: () async {
            buzzes++;
            return true;
          },
          isConnected: () => true,
          now: () => at(9),
          ledger: MemoryAlertDeliveryLedger(),
        ),
      );
      addTearDown(buzzer.dispose);
      buzzer.configure(enabled: true, slotMinutes: []);
      await buzzer.debugFireSlot(at(9));
      expect(logged, isEmpty);
      expect(buzzes, 0);
    },
  );
}
