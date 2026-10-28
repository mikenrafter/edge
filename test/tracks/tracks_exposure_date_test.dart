import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';

// A night that begins after midnight counts toward the evening before. That
// ownership is stored with the candidate and the confirmed event, so editing
// the time (00:30 to 00:20) cannot move it to another assignment.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late TracksStore tracks;
  late LocalRepositoryImpl repo;
  setUp(() async {
    env = await BackupEnv.create('tracks_exposure_date.db');
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    tracks = TracksStore(db);
    repo = LocalRepositoryImpl(getProfileMap: () => {});
    await tracks.saveDefinition(
      const TrackDefinition(
        id: 'alcohol',
        name: 'Alcohol',
        icon: 'wine',
        kind: 'consumed',
        roles: ['detectable'],
        systems: ['hr', 'hrv'],
      ),
    );
  });
  tearDown(() => env.dispose());

  /// An evening E assigned "do" whose next day is assigned "don't", so the
  /// wrong date would be visible in adherence.
  Future<(Map, String, String)> experiment() async {
    final x = await tracks.startExperiment(
      trackId: 'alcohol',
      startDate: '2026-10-01',
      weeks: 2,
      seed: 17,
    );
    final a = (x['assignments'] as List).cast<Map>();
    for (var i = 0; i + 1 < a.length; i++) {
      if (a[i]['do'] == true && a[i + 1]['do'] == false) {
        return (x, a[i]['date'] as String, a[i + 1]['date'] as String);
      }
    }
    fail('no do-then-dont pair');
  }

  for (final edit in [false, true]) {
    test(
      '${edit ? 'edited' : 'unedited'} confirmation of a night starting after '
      'midnight counts as the evening before in adherence',
      () async {
        final (x, evening, next) = await experiment();
        final d = DateTime.parse(next);
        final onset =
            DateTime(d.year, d.month, d.day, 0, 30).millisecondsSinceEpoch ~/ 1000;
        final found = ((await tracks.refreshDetections(
          date: evening,
          windows: [
            {
              'start_ts': onset,
              'end_ts': onset + 3 * 3600,
              'phase': 'early_sleep',
              'date': evening,
              'hr': 68.0,
              'rmssd': 30.0,
              'baseline_hr': 60.0,
              'baseline_rmssd': 45.0,
              'coverage': 1.0,
            },
          ],
        ))['candidates'] as List).cast<ActivitySuggestion>();
        expect(found.single.details['exposure_date'], evening);
        await repo.saveDayReview(
          activities: [
            ActivityDecision(
              found.single,
              keep: true,
              startTs: edit ? onset - 600 : null,
              endTs: edit ? onset - 600 + 3 * 3600 : null,
            ),
          ],
          moments: [],
        );
        final event = (await tracks.events(trackId: 'alcohol')).single;
        expect(event.date, evening);
        final report = await tracks.experimentReport(
          x['id'] as String,
          asOf: DateTime(2026, 10, 25),
        );
        expect((report['adherence'] as Map)['followed'], 1);
      },
    );
  }
}
