// Owner: pulse notification handoff policy, shared by phone and band transports.
import 'package:clock/clock.dart';
import 'alert_rule.dart';
import 'notification_event.dart';
import 'notification_prefs.dart';

class PulseNotificationPolicy {
  /// Re-read settings after transport waits. Null means no handoff; the caller
  /// releases unspent ownership. No scheduling or delivery claim is made here.
  /// CLAIM(pulse-handoff): called immediately before OS show and each queued
  /// band write [pulse_handoff_test]. Non-pulse critical policy is unchanged.
  static Future<NotificationEvent?> atHandoff(
    NotificationEvent event, {
    String target = 'phone',
  }) async {
    if (!event.isPulse) return event;
    final prefs = await NotificationPrefs.load();
    final now = clock.now();
    final rule = prefs.alertRule(event.category.name);
    if (!prefs.shouldFireOs(event, now.hour * 60 + now.minute)) return null;
    if (target == 'band'
        ? !rule.bandSelected
        : !rule.phoneSelected &&
              rule.fallback != AlertFallback.phoneIfBandUnavailable) {
      return null;
    }
    // Only a positively fresh recorded episode can interrupt. Legacy daily
    // flags have no intraday recording time; recovered debt is explicitly silent.
    final recorded = event.pulseSourceTime;
    final age = recorded == null ? null : now.difference(recorded);
    final fresh = age != null && !age.isNegative && age <= rule.staleAfter;
    final outgoing = fresh && !event.silent ? event : event.asSilent();
    return target == 'band' && outgoing.silent ? null : outgoing;
  }
}
