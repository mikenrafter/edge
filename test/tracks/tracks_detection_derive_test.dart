import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';

// A derived day goes in (its stored curves and baseline history), the review
// list comes out. Nothing here supplies a pre-built window.
const date = '2026-10-01';
final day = DateTime(2026, 10, 1).millisecondsSinceEpoch ~/ 1000;
int at(int hour, [int minute = 0]) => day + hour * 3600 + minute * 60;

List<Map<String, num>> run(int from, int to, num v, int step) => [
  for (var t = from; t < to; t += step) {'t': t, 'v': v},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late TracksStore tracks;
  late ActivityStore activities;
  setUp(() async {
    env = await BackupEnv.create('tracks_detection_derive.db');
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    tracks = TracksStore(db);
    activities = ActivityStore(db);
    for (final d in await tracks.definitions()) {
      await tracks.saveDefinition(
        TrackDefinition.fromJson({...d.toJson(), 'roles': <String>[]}),
      );
    }
  });
  tearDown(() => env.dispose());

  Future<void> detectable(String id, {int min = 0, List<String>? systems}) =>
      tracks.saveDefinition(
        TrackDefinition(
          id: id,
          name: id,
          icon: 'track',
          kind: 'consumed',
          roles: const ['detectable'],
          systems: systems ?? const ['hr', 'hrv'],
          detectionMin: min,
        ),
      );

  Future<Map<String, Object?>> derive({
    required List<Map<String, num>> hr,
    List<Map<String, num>> hrv = const [],
    List<Map<String, num>> activity = const [],
    int? onset,
    bool complete = true,
  }) => tracks.refreshFromDerivedDay(
    date: date,
    hrCurve: hr,
    hrvTimeline: hrv,
    activityCurve: activity,
    sleepOnsetSec: onset ?? at(1),
    sleepOffsetSec: at(8),
    rhrHistory: List.filled(8, 60.0),
    rmssdHistory: List.filled(8, 45.0),
    dayComplete: complete,
  );

  final nightHr = [...run(at(1), at(4), 68, 60), ...run(at(4), at(8), 58, 60)];
  final nightHrv = [...run(at(1, 5), at(4), 30, 300), ...run(at(4), at(8), 50, 300)];
  final calmHr = run(at(1), at(8), 58, 60);
  final calmHrv = run(at(1, 5), at(8), 48, 300);

  Future<List<ActivitySuggestion>> review() async => [
    for (final s in await activities.pending(nowTs: at(12)))
      if (s.kind == ActivityKind.track) s,
  ];

  test('an alcohol-like night puts one candidate in review, logs nothing',
      () async {
    await detectable('alcohol');
    await derive(hr: nightHr, hrv: nightHrv);
    final found = await review();
    expect(found, hasLength(1));
    expect(found.single.details['track_id'], 'alcohol');
    expect(found.single.startTs, at(1));
    expect(await tracks.events(trackId: 'alcohol'), isEmpty);
  });

  test('a calm night yields no candidate and, with minimum 0, no prompt',
      () async {
    await detectable('alcohol');
    await derive(hr: calmHr, hrv: calmHrv);
    expect(await review(), isEmpty);
  });

  test('a calm night with minimum 1 asks once the day is complete', () async {
    await detectable('alcohol', min: 1);
    await derive(hr: calmHr, hrv: calmHrv, complete: false);
    expect(await review(), isEmpty);
    await derive(hr: calmHr, hrv: calmHrv);
    final prompts = await review();
    expect(prompts, hasLength(1));
    expect(prompts.single.isPrompt, isTrue);
    // Re-deriving the same day does not stack a second question.
    await derive(hr: calmHr, hrv: calmHrv);
    expect(await review(), hasLength(1));
  });

  test('without an HRV series alcohol abstains with a typed reason', () async {
    await detectable('alcohol');
    final result = await derive(hr: nightHr);
    expect(await review(), isEmpty);
    expect(result['abstained'], [
      {'track_id': 'alcohol', 'reason': 'noHrvSeries'},
    ]);
  });

  test('a resting heart-rate jump becomes one cannabis candidate', () async {
    await detectable('cannabis', systems: ['hr']);
    // Two consecutive elevated hours are one event, not two.
    final hr = [
      ...run(at(9), at(14), 70, 60),
      ...run(at(14), at(16), 90, 60),
      ...run(at(16), at(18), 70, 60),
    ];
    await derive(hr: hr, activity: run(at(9), at(18), 0, 300));
    final found = await review();
    expect(found, hasLength(1));
    expect(found.single.details['track_id'], 'cannabis');
    expect(found.single.startTs, at(14));
  });

  test('a night that began the previous evening is filed on that day', () async {
    await detectable('alcohol');
    final evening = day - 3600; // 23:00 on 2026-09-30
    await derive(
      hr: [...run(evening, evening + 3 * 3600, 68, 60)],
      hrv: run(evening + 300, evening + 3 * 3600, 30, 300),
      onset: evening,
    );
    final found = await review();
    expect(found, hasLength(1));
    expect((await db.query('activity_suggestions')).single['day_id'],
        '2026-09-30');
  });
}
