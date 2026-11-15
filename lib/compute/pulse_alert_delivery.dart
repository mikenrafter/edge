// Owner: how a newly flagged irregular-pulse day reaches the wearer.
//
// POLICY (owner, 2026-11-15): every flagged day is announced exactly once,
// whenever it is first found and however old, under its own recorded day.
//   * A band sync that carried records for the day announces it by itself.
//   * Every other path (import, backfill, restore, reanalysis, algorithm bump)
//     folds the days it finds into ONE summary notification.
//   * Notifications off or not permitted: the day is recorded as not sent and
//     joins the next summary that gets through.
//   * Each day's outcome is a durable row (`pulse_alert`) shown on Observations;
//     a day whose row says sent or summary never alerts again.
// Nothing here changes a flag, a day result or any analytics output.
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
/// one at a time: they go in one summary instead.
const kMaxIndividualPulseAlerts = 3;

/// The longest date list a summary prints; the rest are counted.
const kMaxSummaryDays = 5;

class PulseAlertDelivery {
  const PulseAlertDelivery._();

  /// Announce every flagged day that is still owed an alert. [individualDays]
  /// are the days a recent band sync delivered records for and this pass
  /// derived under that authority; all other owed days go in the summary.
  ///
  /// Throws on a store failure; the notification step and the early return in
  /// the engine both catch and log it, so a failed delivery never fails a pass.
  static Future<void> run({Set<String> individualDays = const {}}) async {
    final owed = await LocalDb.pulseDaysToAlert();
    if (owed.isEmpty) return;
    final records = await LocalDb.pulseAlertRecords();
    final l = await LocaleController.currentStrings();
    var individual = [
      for (final d in owed)
        if (individualDays.contains(d) && !records.containsKey(d)) d,
    ];
    if (individual.length > kMaxIndividualPulseAlerts) individual = const [];
    for (final day in individual) {
      await _announce(day, l);
    }
    final rest = [
      for (final d in owed)
        if (!individual.contains(d)) d,
    ];
    if (rest.isNotEmpty) await _summarize(rest, l);
  }

  static Future<void> _announce(String day, AppLocalizations l) async {
    final key = '$day:irregular-pulse';
    final now = DateTime.now().millisecondsSinceEpoch;
    // Claimed already (an earlier pass presented it and stopped before it wrote
    // the record): that is the one alert this day gets.
    if (await LocalDb.notifFiredExists(key)) {
      await LocalDb.recordPulseAlert([day],
          state: PulseAlertState.sent, atMs: now);
      return;
    }
    final notice = ExceptionNotice(day, [Finding(FindingKind.irregularRhythm, day)]);
    final event = NotificationEvent(
      dedupeKey: key,
      category: NotifCategory.health,
      priority: NotifPriority.critical,
      title: notice.title(l),
      body: notice.body(l),
      date: day,
      route: '/heart',
    );
    await _deliver([day], event, PulseAlertState.sent, null);
  }

  static Future<void> _summarize(List<String> days, AppLocalizations l) async {
    final key = 'pulse-summary:${_fingerprint(days)}';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (await LocalDb.notifFiredExists(key)) {
      await LocalDb.recordPulseAlert(days,
          state: PulseAlertState.summary, atMs: now, summaryKey: key);
      return;
    }
    final shown = days.length > kMaxSummaryDays
        ? days.sublist(days.length - kMaxSummaryDays)
        : days;
    var list = [
      for (final d in shown)
        localizedDate(DateTime.parse(d), l.localeName, withDayOfWeek: true),
    ].join(', ');
    if (days.length > shown.length) {
      list = l.pulseSummaryDaysMore(list, days.length - shown.length);
    }
    final event = NotificationEvent(
      dedupeKey: key,
      category: NotifCategory.health,
      priority: NotifPriority.critical,
      title: l.pulseSummaryTitle(days.length),
      body: l.pulseSummaryBody(list),
      date: todayLabel(),
      route: '/heart',
    );
    await _deliver(days, event, PulseAlertState.summary, key);
  }

  static Future<void> _deliver(
    List<String> days,
    NotificationEvent event,
    PulseAlertState okState,
    String? summaryKey,
  ) async {
    final fired = await NotificationCenter.instance.emit(event);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (fired) {
      await LocalDb.recordPulseAlert(days,
          state: okState, atMs: now, summaryKey: summaryKey);
      return;
    }
    // A claim somebody else already holds is a delivered alert, not a refusal.
    if (await LocalDb.notifFiredExists(event.dedupeKey)) {
      await LocalDb.recordPulseAlert(days,
          state: okState, atMs: now, summaryKey: summaryKey);
      return;
    }
    await LocalDb.recordPulseAlert(days,
        state: PulseAlertState.notSent, atMs: now, reason: await _why(event));
  }

  /// Settings that keep this event off the phone, or else the OS said no.
  static Future<PulseAlertReason> _why(NotificationEvent event) async {
    final prefs = await NotificationPrefs.load();
    final rule = prefs.alertRule(event.category.name);
    final at = DateTime.now();
    final allowed = rule.enabled &&
        rule.phoneSelected &&
        prefs.shouldFireOs(event, at.hour * 60 + at.minute);
    return allowed ? PulseAlertReason.blocked : PulseAlertReason.off;
  }

  /// A stable name for a set of days (FNV-1a over the sorted dates), so the
  /// same set is the same summary however many passes see it.
  static String _fingerprint(List<String> days) {
    var h = 0x811c9dc5;
    for (final unit in days.join(',').codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xffffffff;
    }
    return '${days.length}:${h.toRadixString(16)}';
  }
}
