import 'package:openstrap_edge/notify/alert_policy.dart';
import 'package:openstrap_edge/notify/reminder_sleep_gate.dart';

/// Independently known sleep for tests whose dedupe storage is unavailable.
class AwakeAlertSleepSource implements AlertSleepSource {
  const AwakeAlertSleepSource();
  @override
  Future<ReminderSleepGate> load(DateTime now) async => const ReminderSleepGate();
}

class FailedAlertSleepSource implements AlertSleepSource {
  const FailedAlertSleepSource();
  @override
  Future<ReminderSleepGate> load(DateTime now) async => throw StateError('unavailable');
}

/// An open sleep onset one hour old: the wearer is asleep right now.
class AsleepAlertSleepSource implements AlertSleepSource {
  const AsleepAlertSleepSource();
  @override
  Future<ReminderSleepGate> load(DateTime now) async => ReminderSleepGate(
      periods: [ReminderSleepPeriod(now.subtract(const Duration(hours: 1)))]);
}
