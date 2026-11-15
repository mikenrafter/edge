// Owner: pulse episode delivery. Store claims, not OS return timing, own once-only delivery.
import 'dart:math';
import 'package:intl/intl.dart';
import '../data/db.dart';
import '../data/pulse_episode_store.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';

class PulseEpisodeDelivery {
  static final _random = Random();

  /// A pending claim older than two minutes is ambiguous, never retried.
  static Future<void> run({Duration grace = const Duration(minutes: 2)}) async {
    final store = PulseEpisodeStore(await LocalDb.instance);
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.recoverClaims(beforeMs: now - grace.inMilliseconds);
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

  static String recordedWhen(Map<String, Object?> r) {
    final time = DateTime.fromMillisecondsSinceEpoch(
      r['start_ms'] as int,
      isUtc: true,
    ).add(Duration(minutes: (r['offset_min'] as int?) ?? 0));
    return DateFormat('EEE d MMM yyyy, HH:mm').format(time);
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
    final dates = owned.take(5).map(recordedWhen).join('; ');
    final event = NotificationEvent(
      dedupeKey: key,
      category: NotifCategory.health,
      priority: NotifPriority.critical,
      title: summary
          ? 'Found ${owned.length} irregular pulse episodes'
          : 'Irregular pulse pattern',
      body:
          '$dates${owned.length > 5 ? '; and ${owned.length - 5} more' : ''}. '
          'A wrist pulse flag cannot identify AF or rule out a rhythm problem. A clinician can check with an ECG.',
      date: owned.first['day'] as String,
      route: summary
          ? '/pulse-episodes'
          : '/pulse-episode?id=${Uri.encodeQueryComponent(ids.single)}',
    );
    // CLAIM(pulse-claim): transaction claim precedes any OS handoff [pulse_episode_delivery_test].
    final reached = await NotificationCenter.instance.emitReaching(event);
    final fired = await LocalDb.notifFiredAt(key);
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
          : 'notifications off',
      summaryKey: summary ? key : null,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
