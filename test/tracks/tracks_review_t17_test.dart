import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/tracks/detection.dart';
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
  setUp(() async {
    env = await BackupEnv.create('tracks_review_t17_fix.db');
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    tracks = TracksStore(db);
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

  group('review T17: thresholds carry separate floors and say unvalidated', () {
    test('a learned HRV change needs its own millisecond floor', () {
      const sig = [LearnedSignature('hrv', -4)];
      final small = DetectionWindow(
        startTs: 0,
        endTs: 1800,
        phase: 'awake',
        rmssd: 41,
        baselineRmssd: 45,
        motion: 0,
        coverage: 1,
      );
      expect(const TrackDetectors().learned(small, sig), isNull);
      const big = [LearnedSignature('hrv', -8)];
      final enough = DetectionWindow(
        startTs: 0,
        endTs: 1800,
        phase: 'awake',
        rmssd: 37,
        baselineRmssd: 45,
        motion: 0,
        coverage: 1,
      );
      expect(const TrackDetectors().learned(enough, big), 'learned_signature');
    });

    test('every candidate says its thresholds are unvalidated', () async {
      await detectable('alcohol');
      final found =
          ((await detect([window()]))['candidates'] as List).cast<ActivitySuggestion>();
      expect(found.single.details['validation'], 'unvalidated');
    });
  });
}
