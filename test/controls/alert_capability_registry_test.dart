import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';

void main() {
  test(
    'reminder phone schedule and live band delivery have separate labels',
    () {
      for (final kind in ['water', 'meds', 'movement']) {
        final rule = NotificationPrefs.legacyRule(kind, true, 3);
        expect(
          AlertCapabilityRegistry.effectiveMode(rule, 'phone'),
          AlertExecutionMode.osScheduled,
        );
        expect(
          AlertCapabilityRegistry.effectiveMode(rule, 'band'),
          AlertExecutionMode.phoneLive,
        );
        expect(
          AlertCapabilityRegistry.summary(rule.copyWith(destinations: 1)),
          'On phone — system scheduled',
        );
        expect(
          AlertCapabilityRegistry.summary(rule.copyWith(destinations: 2)),
          'On band — phone must be connected',
        );
        final both = AlertCapabilityRegistry.summary(
          rule,
          bandConnected: false,
        );
        expect(both, contains('On phone — system scheduled'));
        expect(both, contains('Band disconnected'));
      }
    },
  );
  test('derived findings sent to band still require live phone and link', () {
    final rule = NotificationPrefs.legacyRule('health', true, 3);
    expect(
      AlertCapabilityRegistry.summary(rule),
      'On phone — Edge must be running; On band — phone must be connected',
    );
    expect(
      AlertCapabilityRegistry.destinationSupportReason(rule, 'phone'),
      isNull,
    );
    expect(
      AlertCapabilityRegistry.destinationSupportReason(rule, 'band'),
      isNull,
    );
  });
  test(
    'native autonomy requires known native capability and valid destination',
    () {
      final rule = NotificationPrefs.legacyRule('nativeAlarm', true, 2);
      expect(
        AlertCapabilityRegistry.destinationSupportReason(rule, 'band'),
        'unsupportedDeviceExecution',
      );
      const knownNative = {AlertExecutionMode.bandNative};
      expect(
        AlertCapabilityRegistry.destinationSupportReason(
          rule,
          'band',
          supportedBandModes: knownNative,
        ),
        isNull,
      );
      expect(
        AlertCapabilityRegistry.summary(
          rule,
          bandConnected: false,
          supportedBandModes: knownNative,
        ),
        'On band — works without phone',
      );
      expect(
        AlertCapabilityRegistry.destinationSupportReason(rule, 'phone'),
        'unsupportedDestinationExecution',
      );
      final fallback = rule.copyWith(
        fallback: AlertFallback.phoneIfBandUnavailable,
      );
      expect(AlertCapabilityRegistry.effectiveMode(fallback, 'phone'), isNull);
    },
  );
  test('unsupported kind or execution cannot claim a capability', () {
    final health = NotificationPrefs.legacyRule('health', true, 2);
    expect(
      AlertCapabilityRegistry.destinationSupportReason(
        health.copyWith(executionMode: AlertExecutionMode.bandNative),
        'band',
      ),
      'unsupportedExecution',
    );
    final unknown = NotificationPrefs.legacyRule('unknown', true, 1);
    expect(
      AlertCapabilityRegistry.destinationSupportReason(unknown, 'phone'),
      'unsupportedRuleKind',
    );
    expect(
      AlertCapabilityRegistry.destinationSupportReason(
        health,
        'band',
        supportedTargets: {'phone'},
      ),
      'unsupportedTarget',
    );
    expect(
      AlertCapabilityRegistry.summary(health.copyWith(enabled: false)),
      'Off',
    );
  });
  test('OS schedule never implies autonomous band execution', () {
    final rule = NotificationPrefs.legacyRule('water', true, 3);
    expect(
      AlertCapabilityRegistry.effectiveMode(rule, 'band'),
      AlertExecutionMode.phoneLive,
    );
    expect(
      AlertCapabilityRegistry.summary(rule),
      contains('phone must be connected'),
    );
  });
  test('phone-only schedules expose the absent band producer', () {
    final rule = NotificationPrefs.legacyRule('checkIn', true, 3);
    expect(AlertCapabilityRegistry.destinationSupportReason(rule, 'band'),
        'bandScheduleUnavailable');
    expect(AlertCapabilityRegistry.summary(rule), contains('unsupported'));
  });

  test('connected generic adapters do not acquire WHOOP haptic support', () {
    expect(AlertCapabilityRegistry.targetsForBandFamily('ble_hrs'), {'phone'});
    expect(AlertCapabilityRegistry.targetsForBandFamily(null), {'phone'});
    expect(AlertCapabilityRegistry.targetsForBandFamily('gen4'), {'phone', 'band'});
    expect(AlertCapabilityRegistry.targetsForBandFamily('gen5'), {'phone', 'band'});
  });

}
