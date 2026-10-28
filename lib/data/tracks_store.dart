// TracksStore owns definitions, setup history and manual events. SQLite
// transactions serialize its writes. Linked records delegate to their owner.
// Invalid writes throw ArgumentError; database/owner failures propagate.
import 'dart:isolate';
import 'package:clock/clock.dart';
import 'dart:math' as math;
import 'package:sqflite/sqflite.dart';
import '../models/activity_suggestion.dart';
import '../tracks/detection.dart';
import '../tracks/detection_windows.dart';
import '../tracks/experiment.dart';
import '../tracks/learning_worker.dart';
import '../util/worker_init.dart';
import '../util/worker_audit.dart';
import '../util/worker_entries.dart' show Dispatcher;
import 'activity_store.dart';
import 'db.dart';
import '../compute/manual_session.dart'
    show validateManualWindow, ManualWindowException, SessionSpan;
import '../compute/nap_edits.dart' show manualNapWindowIsValid;
import 'day_label.dart';
import 'json_payload_lane.dart';
import 'med_store.dart';
import 'nutrition_store.dart';
import 'track_model.dart';
export 'track_model.dart';
part 'tracks_learning_store.dart';
part 'tracks_detection_store.dart';
part 'tracks_experiment_store.dart';

class TracksStore {
  TracksStore(this.db);
  final Database db;
  Future<Map<String, Map<String, Object?>>> refreshLearning({DateTime? asOf}) =>
      _refreshLearning(asOf: asOf);
  Future<void> confirmNone(String trackId, String date) =>
      _confirmNone(trackId, date);

  /// Review candidates and "did you ...?" questions for [date] from observed
  /// [windows]; see TracksDetectionStore. Returns `candidates` (new review
  /// activities) and `prompts` (open minimum-count questions).
  Future<Map<String, Object?>> refreshDetections({
    required String date,
    required List<Map<String, Object?>> windows,
    DateTime? asOf,
  }) => _refreshDetections(date: date, windows: windows, asOf: asOf);

  /// [refreshDetections] fed by a derived day's stored curves; see
  /// TracksDetectionStore. Also returns `abstained` (typed reasons).
  Future<Map<String, Object?>> refreshFromDerivedDay({
    required String date,
    required List<Object?> hrCurve,
    required List<Object?> hrvTimeline,
    required List<Object?> activityCurve,
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required List<double> rhrHistory,
    required List<double> rmssdHistory,
    required bool dayComplete,
    List<(int, int)> excludedSpans = const [],
    DateTime? asOf,
  }) => _refreshFromDerivedDay(
    date: date,
    hrCurve: hrCurve,
    hrvTimeline: hrvTimeline,
    activityCurve: activityCurve,
    sleepOnsetSec: sleepOnsetSec,
    sleepOffsetSec: sleepOffsetSec,
    rhrHistory: rhrHistory,
    rmssdHistory: rmssdHistory,
    dayComplete: dayComplete,
    excludedSpans: excludedSpans,
    asOf: asOf,
  );

  Future<Map<String, Object?>> startExperiment({
    required String trackId,
    required String startDate,
    required int weeks,
    int? seed,
  }) => _startExperiment(
    trackId: trackId,
    startDate: startDate,
    weeks: weeks,
    seed: seed,
  );
  Future<List<Map<String, Object?>>> experiments({String? trackId}) =>
      _experiments(trackId: trackId);

  /// Records what the wearer did on an assigned [date] of experiment [id]:
  /// [didIt] logs it, otherwise confirms none. Only dates up to today, and only
  /// until the day after the experiment ends. ArgumentError for an unknown
  /// experiment or a date outside it, StateError('experiment_finished') late,
  /// StateError('already_logged') for a "didn't" that contradicts a log.
  Future<void> answerExperimentDay(String id, String date, {required bool didIt}) =>
      _answerExperimentDay(id, date, didIt: didIt);

  /// Date -> whether the wearer said they did it, for answered dates only.
  Future<Map<String, bool>> experimentAnswers(String id) => _experimentAnswers(id);

  /// Ends a running experiment at yesterday (see TracksExperimentStore).
  /// ArgumentError for an unknown id, StateError('experiment_finished') once
  /// its last day has passed.
  Future<void> stopExperiment(String id) => _stopExperiment(id);
  Future<Map<String, Object?>> experimentReport(String id, {DateTime? asOf}) =>
      _experimentReport(id, asOf: asOf);
  Future<List<Map<String, Object?>>> experimentReminders({
    required String date,
  }) => _experimentReminders(date: date);

  Future<List<TrackDefinition>> definitions({bool enabledOnly = false}) async {
    final rows = await db.query('track_definition', orderBy: 'id');
    final decoded = await const IsolateJsonPayloadLane().run(
      JsonPayloadsInput(
        values: [for (final r in rows) r['payload_json']],
        encode: false,
      ),
    );
    final meds = await MedDb.defs(db, activeOnly: false);
    final byKey = {for (final med in meds) 'med:${med.key}': med};
    final definitions = <TrackDefinition>[];
    for (final value in decoded.values) {
      if (value is! Map) continue;
      final json = value.cast<String, dynamic>();
      final med = byKey.remove(json['id']);
      if (med != null) {
        json.addAll({
          'name': med.label,
          'unit': med.doseUnit,
          'enabled': med.active,
        });
      } else if ((json['id'] as String).startsWith('med:')) {
        continue;
      }
      definitions.add(TrackDefinition.fromJson(json));
    }
    for (final med in byKey.values) {
      definitions.add(
        TrackDefinition(
          id: 'med:${med.key}',
          name: med.label,
          icon: 'pill',
          kind: 'consumed',
          unit: med.doseUnit,
          enabled: med.active,
        ),
      );
    }
    return [
      for (final d in definitions)
        if (!enabledOnly || d.enabled) d,
    ];
  }

  Future<void> saveDefinition(
    TrackDefinition definition, {
    List<TrackSetupRange>? history,
  }) async {
    final error = definition.validationError;
    if (error != null) throw ArgumentError(error);
    if (history != null) _validateHistory(definition.id, history);
    final payload = definition.toJson();
    if (definition.loggingComplete &&
        definition.loggingCompleteSinceMs == null) {
      payload['logging_complete_since_ms'] =
          DateTime.now().millisecondsSinceEpoch;
    }
    if (!definition.loggingComplete) {
      payload['logging_complete_since_ms'] = null;
    }
    if (definition.id.startsWith('med:')) {
      // Names and units are read from MedDb; only track config lives here.
      payload.remove('name');
      payload.remove('unit');
      payload.remove('enabled');
    }
    final encoded = await JsonPayloadLane.shared.encode(payload);
    if (encoded == null) throw ArgumentError('definition');
    await db.transaction((tx) async {
      if (definition.id.startsWith('med:')) {
        await MedDb.editTrackDefinition(
          tx,
          key: definition.id.substring(4),
          name: definition.name,
          unit: definition.unit,
          enabled: definition.enabled,
        );
      }
      await tx.insert('track_definition', {
        'id': definition.id,
        'payload_json': encoded,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (history != null) await _writeHistory(tx, definition.id, history);
    });
  }

  Future<List<TrackSetupRange>> history(String trackId) async => [
    for (final r in await db.query(
      'track_setup_history',
      where: 'track_id = ?',
      whereArgs: [trackId],
      orderBy: 'start_date',
    ))
      TrackSetupRange.fromJson(r),
  ];

  Future<void> saveHistory(String trackId, List<TrackSetupRange> ranges) async {
    _validateHistory(trackId, ranges);
    await db.transaction((tx) => _writeHistory(tx, trackId, ranges));
  }

  static void _validateHistory(String trackId, List<TrackSetupRange> ranges) {
    final sorted = [...ranges]
      ..sort((a, b) => a.startDate.compareTo(b.startDate));
    String? previousEnd;
    final ids = <String>{};
    for (final range in sorted) {
      if (range.id.isEmpty ||
          !ids.add(range.id) ||
          range.trackId != trackId ||
          !_validDay(range.startDate) ||
          !_validDay(range.endDate) ||
          range.startDate.compareTo(range.endDate) > 0 ||
          (previousEnd != null &&
              range.startDate.compareTo(previousEnd) <= 0)) {
        throw ArgumentError('history');
      }
      previousEnd = range.endDate;
    }
  }

  static bool _validDay(String date) {
    final parsed = DateTime.tryParse(date);
    return parsed != null &&
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) &&
        dayLabelOf(parsed) == date;
  }

  static Future<void> _writeHistory(
    Transaction tx,
    String id,
    List<TrackSetupRange> ranges,
  ) async {
    await tx.delete(
      'track_setup_history',
      where: 'track_id = ?',
      whereArgs: [id],
    );
    for (final range in ranges) {
      await tx.insert('track_setup_history', range.toJson());
    }
  }

  Future<List<TrackEvent>> events({
    String? trackId,
    String? date,
    int limit = 200,
  }) async {
    final clauses = [
      if (trackId != null) 'track_id = ?',
      if (date != null) 'date = ?',
    ];
    final rows = await db.query(
      'track_event_feed',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: [?trackId, ?date],
      orderBy: 'date DESC, at_ms DESC, id',
      limit: limit.clamp(1, 1000),
    );
    return [for (final row in rows) TrackEvent.fromJson(row)];
  }

  /// One last record per track, with no global-log truncation hiding quiet tracks.
  Future<Map<String, TrackEvent>> lastEvents() async {
    final rows = await db.rawQuery('''
      SELECT e.* FROM track_event_feed e WHERE NOT EXISTS (
        SELECT 1 FROM track_event_feed newer WHERE newer.track_id = e.track_id
        AND (newer.date > e.date OR (newer.date = e.date AND (
          COALESCE(newer.at_ms, -1) > COALESCE(e.at_ms, -1) OR
          (COALESCE(newer.at_ms, -1) = COALESCE(e.at_ms, -1) AND newer.id > e.id)))))
    ''');
    return {
      for (final row in rows)
        row['track_id'] as String: TrackEvent.fromJson(row),
    };
  }

  Future<void> log(TrackEvent event) async {
    if (!_validDay(event.date) ||
        event.id.isEmpty ||
        (event.amount != null &&
            (!event.amount!.isFinite || event.amount! < 0))) {
      throw ArgumentError('event');
    }
    final defs = await definitions();
    final matching = defs.where((d) => d.id == event.trackId);
    if (matching.isEmpty) throw ArgumentError('track');
    final definition = matching.single;
    if (event.unit == null) {
      event = TrackEvent.fromJson({...event.toJson(), 'unit': definition.unit});
    }
    if (event.atMs != null &&
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(event.atMs!)) !=
            event.date) {
      throw ArgumentError('event_date');
    }
    if (event.sourceKind == 'manual' &&
        event.subActivityId != null &&
        !['late_workout', 'late_meal'].contains(event.trackId) &&
        !definition.subActivities.any((s) => s.id == event.subActivityId)) {
      throw ArgumentError('sub_activity');
    }
    // Presets tied to an existing section use that section in either direction.
    final kind = event.sourceKind == 'manual'
        ? switch (event.trackId) {
            'late_workout' => 'session',
            'late_meal' => 'food',
            'naps' => 'nap',
            final id when id.startsWith('med:') => 'med',
            _ => 'manual',
          }
        : event.sourceKind;
    if ((kind == 'session' && event.trackId != 'late_workout') ||
        (kind == 'food' && event.trackId != 'late_meal') ||
        (kind == 'nap' && event.trackId != 'naps') ||
        (kind == 'med' && !event.trackId.startsWith('med:'))) {
      throw ArgumentError('source_track');
    }
    switch (kind) {
      case 'session':
        final at = event.atMs;
        if (at == null || event.amount == null || event.amount! <= 0) {
          throw ArgumentError('workout_time_duration');
        }
        if (event.unit != 'minutes') throw ArgumentError('workout_unit');
        final start = at ~/ 1000;
        final end = start + (event.amount! * 60).round();
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await db.transaction((tx) async {
          final prior = await tx.query(
            'sessions',
            where: 'id = ?',
            whereArgs: [event.sourceId],
            limit: 1,
          );
          final existing = prior.isEmpty ? null : prior.single;
          final others = await tx.query(
            'sessions',
            where: 'start_ts < ? AND (end_ts IS NULL OR end_ts > ?)',
            whereArgs: [end, start],
          );
          final invalid = validateManualWindow(
            startSec: start,
            endSec: end,
            nowSec: nowSec,
            editingId: event.sourceId,
            existing: [
              for (final row in others)
                SessionSpan(
                  row['id'] as String,
                  row['start_ts'] as int,
                  (row['end_ts'] as int?) ?? nowSec,
                ),
            ],
          );
          if (invalid != null) throw ManualWindowException(invalid);
          final changedWindow =
              existing != null &&
              (existing['start_ts'] != start || existing['end_ts'] != end);
          await LocalDb.putSession({
            if (existing != null && !changedWindow) ...existing,
            'id': event.sourceId,
            'start_ts': start,
            'end_ts': end,
            'duration_min': event.amount!.round(),
            'type': event.subActivityId ?? existing?['type'] ?? 'other',
            'status': 'done',
            'private': existing?['private'] ?? 0,
            'rpe': existing?['rpe'],
            'source': existing?['source'] ?? 'manual',
            'created_at': existing?['created_at'] ?? at,
          }, transaction: tx);
        });
      case 'food':
        await NutritionDb.logTrack(
          db,
          id: event.sourceId,
          date: event.date,
          atTs: event.atMs == null ? null : event.atMs! ~/ 1000,
          quantity: event.amount,
          meal: event.subActivityId,
          unit: event.unit,
        );
      case 'med':
        final parts = event.sourceId.split(':');
        final explicitSlot = parts.length >= 3
            ? int.tryParse(parts.last)
            : null;
        final at = event.atMs;
        if (at == null) throw ArgumentError('medication_time');
        // ↳ CLAIM(med-slot-pick)
        await MedDb.logTrack(
          db,
          medKey: event.trackId.substring(4),
          date: event.date,
          explicitSlotMin: explicitSlot,
          atMs: at,
          amount: event.amount,
        );
      case 'nap':
        final at = event.atMs;
        if (at == null || event.amount == null || event.amount! <= 0) {
          throw ArgumentError('nap_time_duration');
        }
        final end = at ~/ 1000 + (event.amount! * 60).round();
        if (event.unit != 'minutes' ||
            !manualNapWindowIsValid(at ~/ 1000, end) ||
            end > DateTime.now().millisecondsSinceEpoch ~/ 1000) {
          throw ArgumentError('nap_time_duration');
        }
        await LocalDb.putNapEdit(
          dayId: event.date,
          startTs: at ~/ 1000,
          endTs: at ~/ 1000 + (event.amount! * 60).round(),
          source: 'manual',
        );
      case 'moment':
        await LocalDb.editTrackMoment(event.sourceId, amount: event.amount);
      case 'journal':
        final field = event.trackId == 'caffeine'
            ? 'caffeine_mg'
            : 'alcohol_units';
        final unit = event.trackId == 'caffeine' ? 'mg' : 'units';
        if (!['caffeine', 'alcohol'].contains(event.trackId) ||
            event.sourceId != '${event.date}:$field' ||
            event.unit != unit) {
          throw ArgumentError('journal_source');
        }
        await LocalDb.editTrackJournal(event.sourceId, event.amount);
      case 'manual':
        final rows = await db.query(
          'track_definition',
          where: 'id = ?',
          whereArgs: [event.trackId],
          limit: 1,
        );
        if (rows.isEmpty) throw ArgumentError('track');
        if (['caffeine', 'alcohol'].contains(event.trackId)) {
          await LocalDb.writeTrackSubstance(event);
        } else {
          await db.insert(
            'track_event',
            event.toJson(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      default:
        throw ArgumentError('source_kind');
    }
  }

  Future<void> deleteEvent(TrackEvent event) async {
    switch (event.sourceKind) {
      case 'session':
        await LocalDb.deleteSession(event.sourceId);
      case 'food':
        await NutritionDb.removeEntry(db, event.sourceId);
      case 'med':
        final parts = event.sourceId.split(':');
        await MedDb.mark(
          db,
          medKey: event.trackId.substring(4),
          date: event.date,
          slotMin: int.parse(parts.last),
          taken: false,
        );
      case 'nap':
        await LocalDb.deleteNapEdit(event.date, event.atMs! ~/ 1000);
      case 'moment':
        await LocalDb.editTrackMoment(event.sourceId, delete: true);
      case 'journal':
        await LocalDb.editTrackJournal(event.sourceId, null);
      case 'manual':
        if (['caffeine', 'alcohol'].contains(event.trackId)) {
          await LocalDb.writeTrackSubstance(event, delete: true);
        } else {
          await db.delete(
            'track_event',
            where: 'id = ?',
            whereArgs: [event.id],
          );
        }
      default:
        throw ArgumentError('source_kind');
    }
  }

  /// Removal archives a definition so open-time preset repair cannot revive it.
  /// Its explicit history remains available for interpretation and backup.
  Future<void> deleteDefinition(String id) async {
    final definition = (await definitions())
        .where((d) => d.id == id)
        .firstOrNull;
    if (definition == null) return;
    await saveDefinition(
      TrackDefinition.fromJson({...definition.toJson(), 'enabled': false}),
    );
  }
}
