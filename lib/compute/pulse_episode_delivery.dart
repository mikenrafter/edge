// Owner: pulse episode delivery. Store claims, not OS return timing, own once-only delivery.
import 'dart:math';
import 'package:intl/intl.dart';
import '../data/db.dart';
import '../data/pulse_episode_store.dart';
import '../l10n/date_text.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../notify/notification_prefs.dart';
import '../state/locale_controller.dart';

class PulseEpisodeDelivery {
  static final _random = Random();

  /// A pending claim older than two minutes is ambiguous, never retried.
  static Future<void> run({Duration grace = const Duration(minutes: 2)}) async {
    final store = PulseEpisodeStore(await LocalDb.instance);
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.initializeUpgrade(nowMs: now);
    await store.recoverClaims(beforeMs: now - grace.inMilliseconds);
    final prefs = await NotificationPrefs.load();
    final localNow = DateTime.now();
    if (prefs.inQuietHours(localNow.hour * 60 + localNow.minute)) {
      await store.deferQuiet();
      return;
    }
    final owed = await store.owed();
    final individual = owed
        .where((r) => r['origin'] == 'sync' && r['state'] == 'owed')
        .toList();
    for (final r in individual) {
      await _deliver(store, [r], summary: false);
    }
    final bulk = owed.where((r) => !individual.contains(r)).toList();
    if (bulk.isNotEmpty) await _deliver(store, bulk, summary: true);
  }

  static String recordedWhen(Map<String, Object?> r, {String? locale}) {
    final time = DateTime.fromMillisecondsSinceEpoch(
      r['start_ms'] as int,
      isUtc: true,
    ).add(Duration(minutes: (r['offset_min'] as int?) ?? 0));
    return '${localizedDate(time, locale ?? 'en', withDayOfWeek: true)}, ${DateFormat.Hm(locale).format(time)}';
  }

  static Future<void> _deliver(
    PulseEpisodeStore store,
    List<Map<String, Object?>> rows, {
    required bool summary,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final token = '$now-${_random.nextInt(1 << 32)}';
    final ids = await store.claim(
      [for (final r in rows) r['episode_id'] as String],
      token: token,
      nowMs: now,
    );
    if (ids.isEmpty) return;
    final owned = rows.where((r) => ids.contains(r['episode_id'])).toList();
    final key = summary
        ? 'pulse-episode-summary:$token'
        : owned.single['delivery_key'] as String;
    final l = await LocaleController.currentStrings();
    final silent = owned.any((r) => r['reason'] == 'quiet hours');
    var dates = owned
        .take(5)
        .map((r) => recordedWhen(r, locale: l.localeName))
        .join(l.localeName == 'zh' ? '、' : '; ');
    if (owned.length > 5) {
      dates = l.pulseSummaryDaysMore(dates, owned.length - 5);
    }
    final event = NotificationEvent(
      dedupeKey: key,
      category: NotifCategory.health,
      priority: NotifPriority.normal,
      silent: silent,
      title: summary
          ? l.pulseEpisodeSummaryTitle(owned.length)
          : l.pulseEpisodeReadingTitle,
      body: l.pulseEpisodeReadingBody(dates),
      date: owned.first['day'] as String,
      route: summary
          ? '/pulse-episodes'
          : '/pulse-episode?id=${Uri.encodeQueryComponent(ids.single)}',
    );
    // CLAIM(pulse-claim): transaction claim precedes any OS handoff [pulse_episode_delivery_test].
    final reached = await NotificationCenter.instance.emitReaching(event);
    final fired = await LocalDb.notifFiredAt(key);
    final after = DateTime.now();
    final quietHeld =
        silent ||
        (await NotificationPrefs.load()).inQuietHours(
          after.hour * 60 + after.minute,
        );
    await store.finish(
      ids,
      token: token,
      state: reached.isNotEmpty
          ? (summary ? 'summary' : 'sent')
          : fired != null
          ? 'unknown'
          : 'not_sent',
      reason: reached.isNotEmpty
          ? null
          : fired != null
          ? 'delivery unknown'
          : quietHeld
          ? 'quiet hours'
          : 'notifications off',
      summaryKey: summary ? key : null,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
