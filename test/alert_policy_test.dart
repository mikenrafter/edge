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
}
