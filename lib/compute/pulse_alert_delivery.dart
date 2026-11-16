// Owner: how a newly flagged irregular-pulse day reaches the wearer.
//
// POLICY (owner, 2026-11-15): every flagged day is announced exactly once,
// whenever it is first found and however old, under its own recorded day.
//   * A band sync that carried records for the day announces it by itself.
//   * Every other path (import, backfill, restore, reanalysis, algorithm bump)
//     folds the days it finds into ONE summary notification.
//   * Notifications off or not permitted: the day is recorded as not sent and
//     joins the next summary that gets through.
//   * Each day's outcome is a durable row (`pulse_alert`) shown on Observations.
//     THAT ROW IS THE CLAIM: a pass moves a day to `pending` in one transaction
//     before anything is shown, and only the pass that did may show it, so the
//     foreground and the background can never both name a day. A `pending` row
//     left behind by a dead pass becomes `unknown` and is never sent again.
// Nothing here changes a flag, a day result or any analytics output.
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../data/day_label.dart';
import '../data/db.dart';
import '../l10n/app_localizations.dart';
import '../l10n/date_text.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/notification_prefs.dart';
import '../state/locale_controller.dart' show LocaleController;
import 'findings.dart';
import 'pulse_alert_record.dart';

/// More individually announced days than this in one pass is a flood, not news
/// one at a time: all of them go in one summary instead.
const kMaxIndividualPulseAlerts = 3;

/// The longest date list a summary prints; the rest are counted.
const kMaxSummaryDays = 5;

/// A claim younger than this belongs to a pass that may still be presenting
/// (the other isolate); older ones were left behind.
const kPulseClaimGrace = Duration(minutes: 2);

/// The seams tests use. The default does nothing and defers to the real
/// notification center.
class PulseDeliveryProbe {
  const PulseDeliveryProbe();

  /// After a pass read which days are owed, before it claims any.
  Future<void> afterOwed() async {}

  /// After a notification was presented, before its record is finished.
  Future<void> afterPresent() async {}

  /// The targets reached, or null to use the real notification center.
  Future<Set<String>?> emit(NotificationEvent event) async => null;
}

class PulseAlertDelivery {
  const PulseAlertDelivery._();

  /// Tests only: the points where a process can die or another pass can slip
  /// in, and a stand-in for the notification center.
  @visibleForTesting
  static PulseDeliveryProbe probe = const PulseDeliveryProbe();

  static final Random _nonce = Random();

  /// Announce every flagged day that is still owed an alert. [individualDays]
  /// are the days a recent band sync delivered records for and this pass
  /// derived under that authority; all other owed days go in the summary.
  /// [pendingGrace]: how old a `pending` claim must be before it is taken as
  /// left behind (`unknown`).
  ///
  /// Throws on a store failure; the notification step and the early return in
  /// the engine both catch and log it, so a failed delivery never fails a pass.
  static Future<void> run({
    Set<String> individualDays = const {},
    Duration pendingGrace = kPulseClaimGrace,
  }) async {
    await LocalDb.markStalePulseUnknown(
      DateTime.now().millisecondsSinceEpoch - pendingGrace.inMilliseconds,
    );
    final owed = await LocalDb.pulseDaysToAlert();
    if (owed.isEmpty) return;
    final records = await LocalDb.pulseAlertRecords();
    final l = await LocaleController.currentStrings();
    var individual = [
      for (final d in owed)
        if (individualDays.contains(d) && !records.containsKey(d)) d,
    ];
    if (individual.length > kMaxIndividualPulseAlerts) individual = const [];
    await probe.afterOwed();
    for (final day in individual) {
      await _announce(day, l);
    }
    // Days a competing pass holds are simply not ours: the claim below filters.
    final rest = [
      for (final d in owed)
        if (!individual.contains(d)) d,
    ];
    if (rest.isNotEmpty) await _summarize(rest, l);
  }

  static String _token(String key) =>
      '$key#${DateTime.now().microsecondsSinceEpoch}-${_nonce.nextInt(1 << 32)}';

  static Future<void> _announce(String day, AppLocalizations l) async {
    final key = '$day:irregular-pulse';
    final token = _token(key);
    final owned = await LocalDb.claimPulseDays(
      [day],
      token: token,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (owned.isEmpty) return;
    // The key was claimed by an earlier pass that died before the screen: the
    // alert's fate is unknown, and it is not sent again.
    final claimedAt = await LocalDb.notifFiredAt(key);
    if (claimedAt != null) {
      await LocalDb.finishPulseDays(owned,
          token: token, state: PulseAlertState.unknown, atMs: claimedAt);
      return;
    }
    final notice = ExceptionNotice(day, [Finding(FindingKind.irregularRhythm, day)]);
    final event = NotificationEvent(
      dedupeKey: key,
      category: NotifCategory.health,
      priority: NotifPriority.normal,
      title: notice.title(l),
      body: notice.body(l),
      date: day,
      route: '/heart',
    );
    await _deliver(owned, event, token, PulseAlertState.sent, null);
  }

  static Future<void> _summarize(List<String> days, AppLocalizations l) async {
    final key = 'pulse-summary:${_fingerprint(days)}:'
        '${DateTime.now().microsecondsSinceEpoch}';
    final token = _token(key);
    final owned = await LocalDb.claimPulseDays(
      days,
      token: token,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (owned.isEmpty) return;
    final shown = owned.length > kMaxSummaryDays
        ? owned.sublist(owned.length - kMaxSummaryDays)
        : owned;
    var list = joinDates([
      for (final d in shown)
        localizedDate(DateTime.parse(d), l.localeName, withDayOfWeek: true),
    ], l.localeName);
    if (owned.length > shown.length) {
      list = l.pulseSummaryDaysMore(list, owned.length - shown.length);
    }
    final event = NotificationEvent(
      dedupeKey: key,
      category: NotifCategory.health,
      priority: NotifPriority.normal,
      title: l.pulseSummaryTitle(owned.length),
      body: l.pulseSummaryBody(owned.length, list),
      date: todayLabel(),
      route: '/heart',
    );
    await _deliver(owned, event, token, PulseAlertState.summary, key);
  }

  /// Dates that themselves contain commas are separated by semicolons; Chinese
  /// has its own enumeration mark.
  @visibleForTesting
  static String joinDates(List<String> dates, String locale) =>
      dates.join(locale == 'zh' ? '、' : '; ');

  static Future<void> _deliver(
    List<String> days,
    NotificationEvent event,
    String token,
    PulseAlertState okState,
    String? summaryKey,
  ) async {
    final reached = await probe.emit(event) ??
        await NotificationCenter.instance.emitReaching(event);
    await probe.afterPresent();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (reached.isNotEmpty) {
      await LocalDb.finishPulseDays(days,
          token: token, state: okState, atMs: now, summaryKey: summaryKey);
      return;
    }
    await LocalDb.finishPulseDays(days,
        token: token,
        state: PulseAlertState.notSent,
        atMs: now,
        reason: await _why(event));
  }

  /// Why nothing reached the wearer: their settings, quiet hours, or the OS.
  static Future<PulseAlertReason> _why(NotificationEvent event) async {
    final prefs = await NotificationPrefs.load();
    final rule = prefs.alertRule(event.category.name);
    if (!rule.enabled || !rule.phoneSelected || !prefs.categoryEnabled(event.category)) {
      return PulseAlertReason.off;
    }
    final at = DateTime.now();
    final minute = at.hour * 60 + at.minute;
    if (prefs.inQuietHours(minute) && !prefs.shouldFireOs(event, minute)) {
      return PulseAlertReason.quiet;
    }
    return PulseAlertReason.blocked;
  }

  /// A stable name for a set of days (FNV-1a over the sorted dates).
  static String _fingerprint(List<String> days) {
    var h = 0x811c9dc5;
    for (final unit in days.join(',').codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xffffffff;
    }
    return '${days.length}:${h.toRadixString(16)}';
  }
}
