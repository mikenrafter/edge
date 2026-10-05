import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every legacy switch keeps its existing destination', () async {
    SharedPreferences.setMockInitialValues({
      for (final key in [
        'notif_health',
        'notif_recovery',
        'notif_reminders',
        'notif_device',
        'notif_water',
        'notif_auto_detect',
        'notif_movement',
        'notif_meds',
        'notif_checkin',
        'notif_stepgoal',
        'notif_winddown',
        'notif_alarm_latch_failed',
        'notif_alarm_night_check',
        'workout.zone_alert_enabled',
        'notif_relay_enabled',
      ])
        key: true,
      'alarm_epoch': 1800000000,
      'gesture_double_tap': 'mark_moment',
    });
    final p = await NotificationPrefs.load();
    for (final id in [
      'health',
      'recovery',
      'reminders',
      'device',
      'autoDetect',
      'checkIn',
      'stepGoal',
      'windDown',
      'alarmLatchFailed',
      'alarmNightCheck',
    ]) {
      expect(p.alertRule(id).destinations, 1, reason: id);
    }
    for (final id in ['water', 'meds', 'movement']) {
      expect(p.alertRule(id).destinations, 3, reason: id);
    }
    for (final id in ['zone', 'wake', 'relay', 'gesture']) {
      expect(p.alertRule(id).destinations, 2, reason: id);
    }
    final store = await SharedPreferences.getInstance();
    expect(
      jsonDecode(
        store.getString(NotificationPrefs.storageKey)!,
      )['schemaVersion'],
      1,
    );
    expect(p.alertRule('alarm').destinations, 1);
    expect(
      p.alertRule('nativeAlarm').executionMode,
      AlertExecutionMode.bandNative,
    );
    expect(p.alertRule('wake').executionMode, AlertExecutionMode.phoneLive);
    expect(p.alertRule('breath').destinations, 2);
    expect(p.alertRule('tasker').destinations, 2);
  });

  test('disabled legacy rules stay off independently', () async {
    SharedPreferences.setMockInitialValues({
      for (final key in [
        'notif_health',
        'notif_recovery',
        'notif_reminders',
        'notif_device',
        'notif_water',
        'notif_auto_detect',
        'notif_movement',
        'notif_meds',
        'notif_checkin',
        'notif_stepgoal',
        'notif_winddown',
        'notif_alarm_latch_failed',
        'notif_alarm_night_check',
        'workout.zone_alert_enabled',
        'notif_relay_enabled',
      ])
        key: false,
    });
    final p = await NotificationPrefs.load();
    for (final id in [
      'health',
      'recovery',
      'reminders',
      'device',
      'autoDetect',
      'checkIn',
      'stepGoal',
      'windDown',
      'alarmLatchFailed',
      'alarmNightCheck',
      'water',
      'meds',
      'movement',
      'zone',
      'relay',
      'gesture',
    ]) {
      expect(p.alertRule(id).destinations, 0, reason: id);
    }
  });

  test(
    'migration commits once and policy edits own the legacy switches',
    () async {
      SharedPreferences.setMockInitialValues({'notif_health': true});
      final p = await NotificationPrefs.load();
      final next = p.withAlertRule(
        p.alertRule('health').copyWith(destinations: 2).toJson(),
      );
      await next.save();
      final store = await SharedPreferences.getInstance();
      await store.setBool('notif_health', false);
      expect(
        (await NotificationPrefs.load()).alertRule('health').destinations,
        2,
      );
      expect((await NotificationPrefs.load()).healthEnabled, true);
    },
  );

  test(
    'boolean compatibility preserves chosen destinations and resets off',
    () async {
      final p = (await NotificationPrefs.load()).withAlertRule(
        const AlertRule(
          id: 'water',
          kind: 'water',
          destinations: 1,
          channelPolicyId: 'water',
        ).toJson(),
      );
      expect(p.waterEnabled, true);
      expect(
        p.copyWith(waterIntervalMin: 60).alertRule('water').destinations,
        1,
      );
      expect(p.copyWith(waterEnabled: true).alertRule('water').destinations, 1);
      final off = p.copyWith(waterEnabled: false);
      expect(off.alertRule('water').destinations, 0);
      expect(
        off.copyWith(waterEnabled: true).alertRule('water').destinations,
        3,
      );
    },
  );

  test(
    'one complete blob round trips policy and all scalar preferences',
    () async {
      final p = (await NotificationPrefs.load()).copyWith(
        quietEnabled: false,
        waterIntervalMin: 45,
        batteryAlertPct: 22,
        alarmNightCheckEnabled: false,
      );
      final next = p.withAlertRule(
        p
            .alertRule('health')
            .copyWith(
              destinations: 3,
              fallback: AlertFallback.phoneIfBandUnavailable,
              historicalReplay: AlertHistoricalReplay.ask,
              staleAfter: const Duration(seconds: 75),
            )
            .toJson(),
      );
      await next.save();
      final loaded = await NotificationPrefs.load();
      expect(loaded.toJson(), next.toJson());
      expect(loaded.phoneDeliveryEnabled('health'), true);
      expect(loaded.bandDeliveryEnabled('health'), true);
      expect(loaded.alarmNightCheckEnabled, false);
    },
  );

  test(
    'legacy quiet changes stay live without overwriting rule destinations',
    () async {
      final p = await NotificationPrefs.load();
      await p
          .withAlertRule(
            p.alertRule('health').copyWith(destinations: 2).toJson(),
          )
          .save();
      final store = await SharedPreferences.getInstance();
      await store.setBool('notif_quiet_enabled', false);
      await store.setInt('notif_quiet_start', 100);
      await store.setBool('notif_critical_override', false);
      await store.setInt('notif_water_interval', 45);
      await store.setInt('notif_battery_pct', 100);
      await store.setBool('notif_health', false);
      final loaded = await NotificationPrefs.load();
      expect(loaded.quietEnabled, false);
      expect(loaded.quietStartMin, 100);
      expect(loaded.criticalOverridesQuiet, false);
      expect(loaded.waterIntervalMin, 45);
      expect(loaded.batteryAlertPct, NotificationPrefs.batteryPctMax);
      expect(loaded.alertRule('health').destinations, 2);
    },
  );

  test('invalid masks fail rather than gaining another target', () {
    expect(
      () => AlertRule.fromJson({'id': 'health', 'destinations': 4}),
      throwsFormatException,
    );
  });
}
