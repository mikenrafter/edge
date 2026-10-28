import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';

final base = DateTime.utc(2026, 10, 1, 9).millisecondsSinceEpoch ~/ 1000;

Map<String, Object?> awake(int offset, {String date = '2026-10-01', double hr = 90}) => {
  'start_ts': base + offset,
  'end_ts': base + offset + 3600,
  'phase': 'awake',
  'date': date,
  'hr': hr,
  'baseline_hr': 70.0,
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
    env = await BackupEnv.create('tracks_review_r2_detection.db');
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
          systems: systems ?? const ['hr'],
          detectionMax: max,
        ),
      );
  Future<Map> detect(List<Map<String, Object?>> w, {String date = '2026-10-01'}) async =>
      await tracks.refreshDetections(date: date, windows: w);
  Future<List<ActivitySuggestion>> pending() =>
      activities.pending(nowTs: base);

  test('R2-3: three consecutive qualifying hours are one occurrence', () async {
    await detectable('cannabis');
    final r = await detect([awake(0), awake(3600), awake(7200)]);
    final found = (r['candidates'] as List).cast<ActivitySuggestion>();
    expect(found, hasLength(1));
    expect(found.single.startTs, base);
    expect(found.single.endTs, base + 3 * 3600);
  });

  test('R2-3: a gap starts a second occurrence', () async {
    await detectable('cannabis');
    final r = await detect([awake(0), awake(3600), awake(4 * 3600)]);
    expect(r['candidates'], hasLength(2));
  });

  test('R2-4: a manual log that explains a pending candidate supersedes it',
      () async {
    await detectable('cannabis');
    await detect([awake(0)]);
    expect(await pending(), hasLength(1));
    await tracks.log(
      TrackEvent(
        id: 'manual-1',
        trackId: 'cannabis',
        date: '2026-10-01',
        atMs: (base + 600) * 1000,
      ),
    );
    // The window is not even supplied again: the review row must still go.
    await detect([]);
    expect(await pending(), isEmpty);
    expect(
      (await db.query('activity_suggestions')).single['status'],
      'superseded',
    );
    expect(await tracks.events(trackId: 'cannabis'), hasLength(1));
  });

  test('R2-5: a night that began after midnight belongs to the evening before',
      () async {
    await detectable('alcohol', systems: ['hr', 'hrv']);
    final onset = DateTime.utc(2026, 10, 1, 0, 30).millisecondsSinceEpoch ~/ 1000;
    final night = {
      'start_ts': onset,
      'end_ts': onset + 3 * 3600,
      'phase': 'early_sleep',
      'date': '2026-09-30',
      'hr': 68.0,
      'rmssd': 30.0,
      'baseline_hr': 60.0,
      'baseline_rmssd': 45.0,
      'coverage': 1.0,
    };
    final r = await detect([night], date: '2026-09-30');
    final found = (r['candidates'] as List).cast<ActivitySuggestion>();
    expect(found, hasLength(1));
    await repo.confirmActivity(found.single);
    final event = (await tracks.events(trackId: 'alcohol')).single;
    expect(event.date, '2026-09-30');
    expect(event.atMs! , lessThan(onset * 1000));
  });

  test('R2-5: the daily maximum counts a night toward its evening', () async {
    await detectable('alcohol', max: 1, systems: ['hr', 'hrv']);
    Map<String, Object?> night(int onset, String date) => {
      'start_ts': onset,
      'end_ts': onset + 3 * 3600,
      'phase': 'early_sleep',
      'date': date,
      'hr': 68.0,
      'rmssd': 30.0,
      'baseline_hr': 60.0,
      'baseline_rmssd': 45.0,
      'coverage': 1.0,
    };
    final after = DateTime.utc(2026, 10, 1, 0, 30).millisecondsSinceEpoch ~/ 1000;
    expect((await detect([night(after, '2026-09-30')], date: '2026-09-30'))['candidates'], hasLength(1));
    // Same evening, found again from the next derive: the evening is full.
    final later = after + 20 * 3600;
    expect((await detect([night(later, '2026-09-30')], date: '2026-09-30'))['candidates'], isEmpty);
    // The next evening is a different date and may have its own.
    expect((await detect([night(later, '2026-10-01')], date: '2026-10-01'))['candidates'], hasLength(1));
  });
}
