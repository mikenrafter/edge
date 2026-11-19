// Read-only presentation of published episode metadata. The structural store
// owns publication, evidence and delivery; this projection never schedules work.
import 'package:sqflite/sqflite.dart';

class PulseEpisodeSummary {
  const PulseEpisodeSummary({required this.id, required this.startMs,
    required this.endMs, required this.day, required this.endDay,
    required this.evidenceStatus, this.deliveryState, this.deliveryReason});
  final String id, day, endDay, evidenceStatus;
  final int startMs, endMs;
  final String? deliveryState, deliveryReason;
  bool occursOn(String date) => date.compareTo(day) >= 0 && date.compareTo(endDay) <= 0;
}

Future<List<PulseEpisodeSummary>> readPulseEpisodeSummaries(Database db) async {
  final rows = await db.rawQuery('''SELECT e.id, e.start_ms, e.end_ms,
    e.start_day, e.end_day, r.evidence_status, o.state, o.reason
    FROM pulse_ep_episode e
    JOIN pulse_ep_revision r ON r.episode_id = e.id AND r.revision = e.revision
    LEFT JOIN pulse_ep_outbox o ON o.episode_id = e.id
    WHERE e.status = 'active'
    ORDER BY e.start_ms DESC, e.id DESC LIMIT 200''');
  return [for (final r in rows) PulseEpisodeSummary(id: r['id'] as String,
    startMs: r['start_ms'] as int, endMs: r['end_ms'] as int,
    day: r['start_day'] as String, endDay: r['end_day'] as String,
    evidenceStatus: r['evidence_status'] as String,
    deliveryState: r['state'] as String?, deliveryReason: r['reason'] as String?)];
}
