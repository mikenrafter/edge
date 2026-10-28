import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
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
    env = await BackupEnv.create('tracks_review_t20_fix.db');
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

  group('review T20: moved candidates are not new', () {
    test('a candidate whose window moved is reported separately', () async {
      await detectable('alcohol');
      expect(((await detect([window()]))['candidates'] as List), hasLength(1));
      final r = await detect([window(start: 300)]);
      expect(r['candidates'], isEmpty);
      expect(r['moved'], hasLength(1));
    });
  });
}
