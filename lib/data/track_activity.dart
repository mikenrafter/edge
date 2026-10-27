// Review decisions for track candidates, inside the caller's transaction so a
// batch Save stays atomic. A candidate supplies a time and never a dose.
import 'package:sqflite/sqflite.dart';
import '../models/activity_suggestion.dart';
import 'day_label.dart';

class TrackActivity {
  /// Logs the occurrence the wearer confirmed and returns the event id. A
  /// minimum-count question has no observed time, so its answer is untimed.
  static Future<String> confirm(
    DatabaseExecutor tx,
    ActivitySuggestion expected, {
    required String dayId,
    required int startTs,
    required int nowMs,
  }) async {
    final trackId = expected.trackId;
    if (trackId == null ||
        (await tx.query(
          'track_definition',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [trackId],
        )).isEmpty) {
      throw const ActivityReviewException('That track is no longer available.');
    }
    final id = 'suggestion:${expected.id}';
    final at = expected.isPrompt ? null : startTs * 1000;
    await tx.insert('track_event', {
      'id': id,
      'track_id': trackId,
      'date': at == null
          ? dayId
          : dayLabelOf(DateTime.fromMillisecondsSinceEpoch(at)),
      'at_ms': at,
      'amount': null,
      'sub_activity_id': null,
      'unit': null,
      'source_kind': 'manual',
      'source_id': id,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return id;
  }

  /// "No" to a minimum-count question is an explicit absence, unless the day
  /// already holds a logged occurrence.
  static Future<void> answerNo(
    DatabaseExecutor tx,
    ActivitySuggestion expected,
    String dayId,
  ) async {
    final trackId = expected.trackId;
    if (trackId == null) return;
    final logged = await tx.query(
      'track_event_feed',
      columns: ['id'],
      where: 'track_id = ? AND date = ?',
      whereArgs: [trackId, dayId],
      limit: 1,
    );
    if (logged.isNotEmpty) return;
    await tx.insert('track_absence', {
      'track_id': trackId,
      'date': dayId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}
