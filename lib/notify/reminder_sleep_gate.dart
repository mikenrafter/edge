// P3 RED declaration only. Future owner of reminder sleep eligibility and diagnostics.
// Storage failures from load must propagate; unknown sleep must stay unknown.
import '../state/control_operations.dart' show ExpectedSleepSchedule;
import 'notification_prefs.dart';

enum ReminderSuppression { quietHours, sleepSchedule, asleep }

class ReminderSleepPeriod {
  const ReminderSleepPeriod(this.start, [this.end]);
  final DateTime start;
  final DateTime? end;
}

class SuppressedReminderSlot {
  const SuppressedReminderSlot(this.at, this.reason);
  final DateTime at;
  final ReminderSuppression reason;
}

class ReminderSleepGate {
  const ReminderSleepGate({this.schedule, this.periods = const []});
  final ExpectedSleepSchedule? schedule;
  final List<ReminderSleepPeriod> periods;

  // RED: accepts every slot. GREEN precedence: quiet hours, schedule, asleep.
  ReminderSuppression? reasonAt(NotificationPrefs prefs, DateTime at) => null;

  // RED: does not read expected_sleep_schedule_v1 or persisted sleep windows.
  static Future<ReminderSleepGate> load({required DateTime now}) async =>
      const ReminderSleepGate();
}
