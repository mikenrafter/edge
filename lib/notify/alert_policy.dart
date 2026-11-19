import 'dart:async';
// Owns interruption eligibility for phone alerts and every queued band write.
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'alert_rule.dart';
import 'notification_prefs.dart';
import 'reminder_sleep_gate.dart';

enum AlertDestination {
  phone, band;

  /// A missing or unreadable stored value takes the phone. Only the log line
  /// below sees a corrupt local value; a corrupt IMPORT is refused and reported
  /// by the settings import itself.
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

  static final _sleepSourceKey = Object();

  /// A worker can scope a DB-free reader without changing foreground policy.
  static Future<T> withSleepSource<T>(
    AlertSleepSource source,
    Future<T> Function() action,
  ) => runZoned(action, zoneValues: {_sleepSourceKey: source});

  static AlertSleepSource get _currentSleepSource =>
      Zone.current[_sleepSourceKey] as AlertSleepSource? ?? sleepSource;

  /// Kinds the wearer started or is inside of: they are not alerts, so quiet
  /// hours and sleep never hold them (owner, 2026-11-18). The test/preview/find
  /// buzzes, Device lab probes, ECG cues, gesture tap-acks and the cues of a
  /// breathing session. They also take no alert fallback.
  static bool isSessionCue(AlertRule rule) => _sessionKinds.contains(rule.kind);

  static const _sessionKinds = {'buzzPreview', 'hardwareProbe', 'ecg',
    'gesture', 'breath'};

  // CLAIM(alert-release): priority never grants a wake pass [spec §4.5].
  static AlertReleaseClass releaseClass(AlertRule rule) {
    if (rule.userScheduled || isSessionCue(rule) ||
        const {'meds', 'wake', 'alarmLatchFailed', 'alarm', 'nativeAlarm'}
            .contains(rule.kind)) {
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

  /// The saved rule for [rule]'s id. A pass the caller's own rule carries
  /// (a relayed alarm is [AlertRule.userScheduled]) survives the reload.
  static AlertRule _saved(NotificationPrefs prefs, AlertRule rule) {
    final saved = prefs.alertRule(rule.id);
    return rule.userScheduled && !saved.userScheduled
        ? saved.copyWith(userScheduled: true) : saved;
  }

  static Future<AlertRule> currentRule(AlertRule rule) async {
    if (!NotificationPrefs.alertRuleOrder.contains(rule.id)) return rule;
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    return _saved(await NotificationPrefs.load(), rule);
  }

  static Future<String> fallback() async =>
      (await NotificationPrefs.load()).fallbackDestination.name;

  /// What the policy says about [rule] right now, with the same reloads as
  /// [permits]. A storage failure holds (a retryable refusal): the wearer is
  /// never assumed awake.
  static Future<AlertDisposition> dispositionOf(AlertRule rule) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      final prefs = await NotificationPrefs.load();
      final now = clock.now();
      final sleep = await _currentSleepSource.load(now);
      return AlertPolicy(prefs, sleep).decide(rule, now).disposition;
    } catch (error) {
      debugPrintSynchronously('[notify] eligibility unavailable: $error');
      return AlertDisposition.hold;
    }
  }

  /// Reloads at handoff; storage failure refuses delivery instead of assuming
  /// the wearer is awake. A cached onset is still aged against the new instant.
  static Future<bool> permits(AlertRule rule, String target) async {
    try {
      final saved = NotificationPrefs.alertRuleOrder.contains(rule.id);
      // A rule with no saved switch that always passes needs no storage read.
      if (!saved && releaseClass(rule) == AlertReleaseClass.alwaysPass) return true;
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      final prefs = await NotificationPrefs.load();
      final current = saved ? _saved(prefs, rule) : rule;
      // Internal cues have no saved switch. Saved rules must remain enabled.
      if (saved && !current.enabled) return false;
      if (releaseClass(current) == AlertReleaseClass.alwaysPass) return true;
      final now = clock.now();
      final sleep = await _currentSleepSource.load(now);
      final finalPrefs = await NotificationPrefs.load();
      final finalRule = saved ? _saved(finalPrefs, rule) : current;
      if (!finalRule.enabled) return false;
      return AlertPolicy(finalPrefs, sleep).decide(finalRule, now).allowed;
    } catch (error) {
      debugPrintSynchronously('[notify] eligibility unavailable: $error');
      return false;
    }
  }
}
