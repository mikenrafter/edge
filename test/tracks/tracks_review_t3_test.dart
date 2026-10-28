import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/tracks/detection.dart';
import 'package:openstrap_edge/tracks/learning.dart';
import 'package:openstrap_edge/tracks/learning_worker.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';

const day = '2026-10-01';
final onset = DateTime.utc(2026, 10, 1, 1).millisecondsSinceEpoch ~/ 1000;

Map<String, Object?> window({
  int start = 0,
  String phase = 'early_sleep',
  double hr = 68,
}) => {
  'start_ts': onset + start,
  'end_ts': onset + start + 1800,
  'phase': phase,
  'hr': hr,
  'rmssd': 30.0,
  'baseline_hr': 60.0,
  'baseline_rmssd': 45.0,
  'motion': 0.0,
  'coverage': 1.0,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late TracksStore tracks;
  late ActivityStore activities;
  late LocalRepositoryImpl repo;
  setUp(() async {
    env = await BackupEnv.create('tracks_review_t3_fix.db');
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    tracks = TracksStore(db);
    activities = ActivityStore(db);
    repo = LocalRepositoryImpl(getProfileMap: () => {});
    for (final d in await tracks.definitions()) {
      await tracks.saveDefinition(
        TrackDefinition.fromJson({...d.toJson(), 'roles': <String>[]}),
      );
    }
  });
  tearDown(() => env.dispose());

  Future<void> detectable(String id, {int max = 10, List<String>? systems}) =>
      tracks.saveDefinition(
        TrackDefinition(
          id: id,
          name: id,
          icon: 'track',
          kind: 'consumed',
          roles: const ['detectable'],
          systems: systems ?? const ['hr', 'hrv'],
          detectionMax: max,
        ),
      );

  Future<Map> detect(List<Map<String, Object?>> windows) async =>
      await tracks.refreshDetections(date: day, windows: windows);

  group('review T3: sleep evidence is logged before the night it explains', () {
    test('a confirmed early-sleep candidate belongs to that night for T2', () async {
      await detectable('alcohol');
      final found =
          ((await detect([window()]))['candidates'] as List).cast<ActivitySuggestion>();
      await repo.confirmActivity(found.single);
      final event = (await tracks.events(trackId: 'alcohol')).single;
      final onsetMs = onset * 1000;
      expect(event.atMs, isNotNull);
      expect(event.atMs!, lessThan(onsetMs));
      expect(onsetMs - event.atMs!, lessThan(60 * 1000));

      // The learner's own night assembly counts it for the night starting at
      // onset, with a positive lead time, not as a later night's exposure.
      final track = TrackDefinition(
        id: 'alcohol',
        name: 'alcohol',
        icon: 'track',
        kind: 'consumed',
        systems: const ['sleep'],
      );
      final nights = trackNightsHeavy(
        TrackLearningInput(
          definitions: [
            {'id': 'alcohol', 'payload_json': jsonEncode(track.toJson())},
          ],
          events: [event.toJson()],
          history: const [],
          absences: const [],
          states: const [],
          days: [
            {
              'day_id': day,
              'window_json': jsonEncode({
                'value': {
                  'onset_ms': onsetMs,
                  'offset_ms': onsetMs + 7 * 3600 * 1000,
                },
              }),
              'payload_json': jsonEncode({
                'scalars': {'rhr': 55},
                'sleep': {'accounting': {'value': {'tst_sec': 25200}}},
                'coverage': {'rr_coverage': .9},
              }),
            },
          ],
          worker: WorkerInputs(
            nowEpochMs: onsetMs + 24 * 3600 * 1000,
            zoneId: 'UTC',
            localeTag: 'en',
          ),
        ),
        [track],
        [event],
        const [],
      );
      final night = nights.single;
      expect(
        night.events.any((e) => e.id == event.id && e.atMs! < night.at.millisecondsSinceEpoch),
        isTrue,
      );
    });

    test('a time the wearer edited is kept as chosen', () async {
      await detectable('alcohol');
      final found =
          ((await detect([window()]))['candidates'] as List).cast<ActivitySuggestion>();
      await repo.saveDayReview(
        activities: [
          ActivityDecision(
            found.single,
            keep: true,
            startTs: onset + 600,
            endTs: onset + 2400,
          ),
        ],
        moments: [],
      );
      expect(
        (await tracks.events(trackId: 'alcohol')).single.atMs,
        (onset + 600) * 1000,
      );
    });
  });
}
