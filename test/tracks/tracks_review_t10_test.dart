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
    env = await BackupEnv.create('tracks_review_t10_fix.db');
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

  group('review T10: logged occurrences count', () {
    test('an occurrence logged earlier that evening explains the window', () async {
      await detectable('alcohol');
      await tracks.log(
        TrackEvent(
          id: 'manual-1',
          trackId: 'alcohol',
          date: '2026-09-30',
          atMs: (onset - 4 * 3600) * 1000,
          amount: 2,
        ),
      );
      final r = await detect([window()]);
      expect(r['candidates'], isEmpty);
      expect(await db.query('activity_suggestions'), isEmpty);
    });

    test('logged events count toward the daily maximum', () async {
      await detectable('alcohol', max: 1);
      await tracks.log(
        TrackEvent(
          id: 'manual-early',
          trackId: 'alcohol',
          date: day,
          atMs: DateTime.utc(2026, 10, 1, 8).millisecondsSinceEpoch,
          amount: 1,
        ),
      );
      // Far from the window (17 h), so it does not explain it, but it uses
      // the day's only allowed occurrence.
      expect((await detect([window()]))['candidates'], isEmpty);
    });

    test('a confirmed candidate does not count twice', () async {
      await detectable('alcohol', max: 2);
      final first =
          ((await detect([window()]))['candidates'] as List).cast<ActivitySuggestion>();
      await repo.confirmActivity(first.single);
      final again = await detect([window(start: 50000)]);
      expect(again['candidates'], hasLength(1));
    });
  });
}
