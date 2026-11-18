// Owns interruption eligibility for phone alerts and every queued band write.
import 'package:flutter/foundation.dart' show debugPrintSynchronously, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'alert_rule.dart';
import 'notification_prefs.dart';
import 'reminder_sleep_gate.dart';

enum AlertDestination {
  phone, band;

  static AlertDestination parse(Object? value) {
    if (value == null) return phone;
    for (final destination in values) {
      if (value == destination.name) return destination;
    }
    debugPrintSynchronously('[notify] refused invalid fallback destination; using phone');
    return phone;
  }
}

enum AlertReleaseClass { durableDebt, recurringSlot, alwaysPass }
enum AlertDisposition { deliver, hold, skip }

class AlertDecision {
  const AlertDecision(this.disposition, [this.reason]);
  final AlertDisposition disposition;
  final ReminderSuppression? reason;
  bool get allowed => disposition == AlertDisposition.deliver;
}

abstract interface class AlertSleepSource {
  Future<ReminderSleepGate> load(DateTime now);
}

class StoredAlertSleepSource implements AlertSleepSource {
  const StoredAlertSleepSource();
  @override
  Future<ReminderSleepGate> load(DateTime now) => ReminderSleepGate.load(now: now);
}

class AlertPolicy {
  const AlertPolicy(this.prefs, this.sleep);
  final NotificationPrefs prefs;
  final ReminderSleepGate sleep;

  @visibleForTesting
  static AlertSleepSource sleepSource = const StoredAlertSleepSource();

  // CLAIM(alert-release): priority never grants a wake pass [spec §4.5].
  static AlertReleaseClass releaseClass(AlertRule rule) {
    if (rule.userScheduled || const {'meds', 'wake', 'alarmLatchFailed',
        'alarm', 'nativeAlarm'}.contains(rule.kind)) {
      return AlertReleaseClass.alwaysPass;
    }
    if (rule.executionMode == AlertExecutionMode.osScheduled ||
        const {'water', 'movement'}.contains(rule.kind)) {
      return AlertReleaseClass.recurringSlot;
    }
    return AlertReleaseClass.durableDebt;
  }

  AlertDecision decide(AlertRule rule, DateTime at) {
    final release = releaseClass(rule);
    if (release == AlertReleaseClass.alwaysPass) {
      return const AlertDecision(AlertDisposition.deliver);
    }
    final reason = sleep.reasonAt(prefs, at);
    if (reason == null) return const AlertDecision(AlertDisposition.deliver);
    return AlertDecision(release == AlertReleaseClass.recurringSlot
        ? AlertDisposition.skip : AlertDisposition.hold, reason);
  }

  static Future<AlertRule> currentRule(AlertRule rule) async {
    if (!NotificationPrefs.alertRuleOrder.contains(rule.id)) return rule;
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    return (await NotificationPrefs.load()).alertRule(rule.id);
  }

  static Future<String> fallback() async =>
      (await NotificationPrefs.load()).fallbackDestination.name;

  /// Reloads at handoff; storage failure refuses delivery instead of assuming
  /// the wearer is awake. A cached onset is still aged against the new instant.
  static Future<bool> permits(AlertRule rule, String target) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      final prefs = await NotificationPrefs.load();
      final current = prefs.alertRule(rule.id);
      // Internal cues have no saved switch. Saved rules must remain enabled.
      if (NotificationPrefs.alertRuleOrder.contains(rule.id) && !current.enabled) {
        return false;
      }
      final effective = NotificationPrefs.alertRuleOrder.contains(rule.id) ? current : rule;
      if (releaseClass(effective) == AlertReleaseClass.alwaysPass) return true;
      final now = DateTime.now();
      final sleep = await sleepSource.load(now);
      final finalPrefs = await NotificationPrefs.load();
      final finalRule = NotificationPrefs.alertRuleOrder.contains(rule.id)
          ? finalPrefs.alertRule(rule.id) : effective;
      if (!finalRule.enabled) return false;
      return AlertPolicy(finalPrefs, sleep).decide(finalRule, DateTime.now()).allowed;
    } catch (error) {
      debugPrintSynchronously('[notify] eligibility unavailable: $error');
      return false;
    }
  }
}
