// Headless refresh uses the same eligibility and storage owners as AppState.
import '../data/assumed_water.dart';
import '../state/units_controller.dart';
import 'notification_center.dart';
import 'notification_prefs.dart';
import 'reminder_sleep_gate.dart';

Future<void> refreshHeadlessReminderSleep() async {
  final now = DateTime.now();
  final prefs = await NotificationPrefs.load();
  final sleep = await ReminderSleepGate.load(now: now);
  await AssumedWater.catchUp(
    prefs,
    now: now,
    system: await UnitsController.savedSystem(),
    sleep: sleep,
  );
  await NotificationCenter.instance.scheduleStandingReminders(
    prefs,
    sleep: sleep,
  );
}
