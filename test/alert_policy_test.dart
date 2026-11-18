import 'package:openstrap_edge/notify/alert_policy.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/reminder_sleep_gate.dart';

void main() {
  // WHY / CLAIM(alert-quiet): old settings cannot authorize an interruption.
  test('legacy critical override true still holds health in quiet hours', () {
    const prefs = NotificationPrefs(criticalOverridesQuiet: true);
    final event = NotificationEvent(dedupeKey: 'health',
      category: NotifCategory.health, priority: NotifPriority.critical,
      title: 'Health', body: '', date: '2026-11-17');
    expect(prefs.shouldFireOs(event, 23 * 60), isFalse);
    expect(prefs.shouldFireOs(event, 12 * 60), isTrue);
  });

  test('critical priority alone never grants wake classification', () {
    final event = NotificationEvent(dedupeKey: 'ordinary',
      category: NotifCategory.reminders, priority: NotifPriority.critical,
      title: 'Reminder', body: '', date: '2026-11-17');
    expect(classOf(event), isNull);
    expect(const NotificationPrefs().shouldFireOs(event, 23 * 60), isFalse);
  });

  // WHY / CLAIM(alert-onset-bound): evaluate elapsed age at each future slot.
  test('cached open onset holds through sixteen hours then becomes unknown', () {
    final onset = DateTime(2026, 11, 17, 0);
    final gate = ReminderSleepGate(periods: [ReminderSleepPeriod(onset)]);
    const prefs = NotificationPrefs(quietEnabled: false);
    expect(gate.reasonAt(prefs, onset.add(const Duration(hours: 8))),
      ReminderSuppression.asleep);
    expect(gate.reasonAt(prefs, onset.add(const Duration(hours: 16))),
      ReminderSuppression.asleep);
    expect(gate.reasonAt(prefs, onset.add(const Duration(hours: 16,
      milliseconds: 1))), isNull);
    expect(gate.reasonAt(prefs, onset.add(const Duration(hours: 17))), isNull);
  });

  // WHY / CLAIM(alert-release): one category list covers every producer.
  // Owner 2026-11-18: cues inside a session the user started (breathing,
  // gesture acks) are not alerts, so they pass with wake and medication.
  test('every other producer holds or skips under the same gate', () {
    final at = DateTime(2026, 11, 17, 23);
    const policy = AlertPolicy(NotificationPrefs(), ReminderSleepGate());
    for (final kind in {...AlertCapabilityRegistry.scheduledKinds,
        ...AlertCapabilityRegistry.liveKinds, ...AlertCapabilityRegistry.derivedKinds,
        'nativeAlarm'}) {
      final rule = NotificationPrefs.legacyRule(kind, true, 3);
      final decision = policy.decide(rule, at);
      final wake = {'meds', 'wake', 'alarm', 'alarmLatchFailed', 'nativeAlarm',
          'breath', 'gesture', 'ecg', 'buzzPreview', 'hardwareProbe'}.contains(kind);
      expect(decision.allowed, wake, reason: kind);
      if (!wake) expect(decision.reason, ReminderSuppression.quietHours);
    }
  });

  // WHY / CLAIM(alert-reminder-pass): explicit scheduling, including recurring
  // reminders, always wins over both quiet hours and known sleep.
  test('user scheduled reminder passes quiet and sleep on every destination', () {
    final at = DateTime(2026, 11, 17, 23);
    final policy = AlertPolicy(const NotificationPrefs(),
      ReminderSleepGate(periods: [ReminderSleepPeriod(at.subtract(
        const Duration(hours: 2)))]));
    for (final destinations in [1, 2, 3]) {
      final rule = NotificationPrefs.legacyRule('reminders', true, destinations)
          .copyWith(userScheduled: true);
      expect(policy.decide(rule, at).allowed, isTrue);
      expect(AlertRule.fromJson(rule.toJson()).userScheduled, isTrue);
    }
    expect(policy.decide(NotificationPrefs.legacyRule('meds', true, 3), at)
        .allowed, isTrue);
    expect(policy.decide(NotificationPrefs.legacyRule('water', true, 3), at)
        .disposition, AlertDisposition.skip);
    expect(policy.decide(NotificationPrefs.legacyRule('health', true, 3), at)
        .disposition, AlertDisposition.hold);
  });

  // WHY / CLAIM(alert-onset-bound): age expiry never cancels an independent
  // quiet-hours or expected-sleep restriction.
  test('stale onset does not disable quiet hours', () {
    final at = DateTime(2026, 11, 17, 23);
    final gate = ReminderSleepGate(periods: [ReminderSleepPeriod(
      at.subtract(const Duration(hours: 17)))]);
    expect(gate.reasonAt(const NotificationPrefs(), at),
      ReminderSuppression.quietHours);
  });
  test('open onset age uses elapsed hours across DST transitions', () {
    const prefs = NotificationPrefs(quietEnabled: false);
    for (final onset in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
      final gate = ReminderSleepGate(periods: [ReminderSleepPeriod(onset)]);
      expect(gate.reasonAt(prefs, onset.add(const Duration(hours: 16))),
        ReminderSuppression.asleep);
      expect(gate.reasonAt(prefs, onset.add(const Duration(hours: 16, milliseconds: 1))),
        isNull);
    }
  });
}
