import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';

const detectionDay = '2026-10-01';
final detectionStart =
    DateTime.utc(2026, 10, 1, 1).millisecondsSinceEpoch ~/ 1000;

// Evidence values are explicit, independent of whatever defaults the detector
// ships. Neither an elevated HR alone nor missing RMSSD supports alcohol.
Map<String, Object?> detectionWindow({
  int offset = 0,
  String phase = 'early_sleep',
  double? hr = 68,
  double? rmssd = 30,
  double? baselineHr = 60,
  double? baselineRmssd = 45,
  double motion = 0,
  double coverage = 1,
}) => {
  'start_ts': detectionStart + offset,
  'end_ts': detectionStart + offset + 1800,
  'phase': phase,
  'hr': hr,
  'rmssd': rmssd,
  'baseline_hr': baselineHr,
  'baseline_rmssd': baselineRmssd,
  'motion': motion,
  'coverage': coverage,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late TracksStore tracks;
  late ActivityStore activities;
  late LocalRepositoryImpl repo;
  setUp(() async {
    env = await BackupEnv.create('tracks_detection_t3.db');
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    tracks = TracksStore(db);
    activities = ActivityStore(db);
    repo = LocalRepositoryImpl(getProfileMap: () => {});
    for (final definition in await tracks.definitions()) {
      await tracks.saveDefinition(
        TrackDefinition.fromJson({...definition.toJson(), 'roles': <String>[]}),
      );
    }
  });
  tearDown(() => env.dispose());

  Future<void> detectable(
    String id, {
    int min = 0,
    int max = 10,
    bool enabled = true,
    List<String> systems = const ['hr', 'hrv'],
  }) => tracks.saveDefinition(
    TrackDefinition(
      id: id,
      name: id,
      icon: 'track',
      kind: 'consumed',
      enabled: enabled,
      roles: const ['detectable'],
      systems: systems,
      detectionMin: min,
      detectionMax: max,
    ),
  );

  Future<Map> detect(List<Map<String, Object?>> windows) async =>
      await (tracks as dynamic).refreshDetections(
            date: detectionDay,
            windows: windows,
          )
          as Map;
  List<ActivitySuggestion> candidates(Map result) =>
      (result['candidates'] as List).cast<ActivitySuggestion>();

  test(
    'alcohol evidence produces a review candidate without logging use',
    () async {
      await detectable('alcohol');
      // Alcohol evidence may overlap actual sleep: a nap overlap guard must not
      // suppress an early-sleep track candidate.
      await db.insert('sleep_nap', {
        'day_id': detectionDay,
        'created_at': 1,
        'start_ts': detectionStart,
        'end_ts': detectionStart + 3600,
        'source': 'manual',
      });
      final proposed = candidates(await detect([detectionWindow()]));
      expect(proposed, hasLength(1));
      expect(proposed.single.kind.name, 'track');
      expect(proposed.single.details['track_id'], 'alcohol');
      expect(proposed.single.status, ActivityReviewStatus.pending);
      expect(await tracks.events(trackId: 'alcohol'), isEmpty);
      expect(await db.query('sessions'), isEmpty);
    },
  );

  test(
    'alcohol needs both directions and personal baseline with usable coverage',
    () async {
      await detectable('alcohol');
      for (final window in [
        detectionWindow(hr: 59),
        detectionWindow(rmssd: 46),
        detectionWindow(rmssd: null),
        detectionWindow(baselineHr: null),
        detectionWindow(baselineRmssd: null),
        detectionWindow(coverage: .1),
        detectionWindow(phase: 'awake'),
      ]) {
        expect(candidates(await detect([window])), isEmpty, reason: '$window');
      }
      expect(await db.query('activity_suggestions'), isEmpty);
    },
  );

  test(
    'cannabis requires a resting 15 bpm jump, no motion; caffeine never detects',
    () async {
      await detectable('cannabis', systems: ['hr']);
      await detectable('caffeine');
      for (final window in [
        detectionWindow(phase: 'awake', hr: 74.9),
        detectionWindow(phase: 'awake', hr: 80, motion: 1),
        detectionWindow(phase: 'awake', hr: null),
      ]) {
        expect(candidates(await detect([window])), isEmpty);
      }
      final found = candidates(
        await detect([detectionWindow(phase: 'awake', hr: 75)]),
      );
      expect(found.map((s) => s.details['track_id']), ['cannabis']);
      expect(await tracks.events(), isEmpty);
    },
  );

  test(
    'detectable role, enabled state and selected systems gate evidence',
    () async {
      await detectable('alcohol', enabled: false);
      expect(candidates(await detect([detectionWindow()])), isEmpty);
      await detectable('alcohol', systems: ['glucose']);
      expect(candidates(await detect([detectionWindow()])), isEmpty);
      await tracks.saveDefinition(
        const TrackDefinition(
          id: 'alcohol',
          name: 'Alcohol',
          icon: 'wine',
          kind: 'consumed',
          systems: ['hr', 'hrv'],
        ),
      );
      expect(candidates(await detect([detectionWindow()])), isEmpty);
    },
  );

  test('custom role alone cannot invent a signature', () async {
    await detectable('custom');
    expect(
      candidates(
        await detect([
          detectionWindow(hr: 100, rmssd: 10),
          detectionWindow(offset: 4000, phase: 'awake', hr: 100),
        ]),
      ),
      isEmpty,
    );
    expect(await db.query('activity_suggestions'), isEmpty);
  });

  test(
    'custom detection uses a mature supported T2 signature only for its selected system',
    () async {
      await detectable('custom', systems: ['hr']);
      await db.insert('track_learning', {
        'track_id': 'custom',
        'started_ms': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
        'last_step_date': '2026-09-30',
        'state_json': jsonEncode({
          'effects': [
            {
              'system': 'hr',
              'effect': 16.0,
              'reason': 'estimated',
              'matched_pairs': 24,
              'adjusted_p': .01,
              'shuffle_p': .005,
            },
          ],
        }),
      });
      final found = candidates(
        await detect([detectionWindow(phase: 'awake', hr: 76)]),
      );
      expect(found.map((s) => s.details['track_id']), ['custom']);
      await detectable('custom', systems: ['glucose']);
      expect(
        candidates(
          await detect([detectionWindow(offset: 4000, phase: 'awake', hr: 76)]),
        ),
        isEmpty,
      );
    },
  );

  test(
    'daily maximum includes prior candidates and survives reruns and decisions',
    () async {
      await detectable('alcohol', max: 2);
      final first = candidates(
        await detect([
          for (var i = 0; i < 5; i++) detectionWindow(offset: i * 3600),
        ]),
      );
      expect(first, hasLength(2));
      await repo.confirmActivity(first.first);
      await repo.discardActivity(first.last);
      expect(
        candidates(
          await detect([
            for (var i = 0; i < 6; i++) detectionWindow(offset: i * 3600),
          ]),
        ),
        isEmpty,
      );
      expect(await db.query('activity_suggestions'), hasLength(2));
      expect(await tracks.events(trackId: 'alcohol'), hasLength(1));
      await detectable('cannabis', max: 0, systems: ['hr']);
      expect(
        candidates(
          await detect([
            detectionWindow(offset: 22000, phase: 'awake', hr: 80),
          ]),
        ),
        isEmpty,
      );
    },
  );

  test(
    'below minimum produces a did-you prompt, no fabricated occurrence',
    () async {
      await detectable('alcohol', min: 2, max: 3);
      final result = await detect([]);
      expect(candidates(result), isEmpty);
      expect((result['prompts'] as List).map((p) => (p as Map)['track_id']), [
        'alcohol',
      ]);
      expect(await tracks.events(), isEmpty);
      final rows = await db.query('activity_suggestions');
      expect(rows, hasLength(1));
      expect(
        rows.every(
          (row) =>
              (jsonDecode(row['details_json'] as String) as Map)['prompt'] ==
              true,
        ),
        isTrue,
      );
      await tracks.confirmNone('alcohol', detectionDay);
      expect(
        (await detect([]))['prompts'],
        isEmpty,
        reason: 'an explicit answer must suppress repeated missing-log prompts',
      );
    },
  );

  test(
    'overlapping different tracks remain distinct and direct confirm is idempotent',
    () async {
      final kind = ActivityKind.values.byName('track');
      final found = await activities.reconcile(kind, [
        for (final id in ['alcohol', 'cannabis'])
          {
            'id': '$id:$detectionStart',
            'track_id': id,
            'track_name': id,
            'start_ts': detectionStart,
            'end_ts': detectionStart + 1800,
          },
      ]);
      expect(found, hasLength(2));
      for (final suggestion in found) {
        await repo.confirmActivity(suggestion);
        await repo.confirmActivity(suggestion);
      }
      final events = await tracks.events();
      expect(events.map((e) => e.trackId).toSet(), {'alcohol', 'cannabis'});
      expect(events, hasLength(2));
      expect(
        events.every((e) => e.amount == null),
        isTrue,
        reason: 'a physiological candidate supplies no dose',
      );
      expect(await db.query('sleep_nap'), isEmpty);
      expect(await db.query('sessions'), isEmpty);
      expect(await db.query('food_entry'), isEmpty);
    },
  );

  test(
    'batch stale decision rolls back track events; edited confirm preserves chosen time',
    () async {
      final kind = ActivityKind.values.byName('track');
      Future<ActivitySuggestion> propose(int offset, {int extra = 0}) async =>
          (await activities.reconcile(kind, [
            {
              'track_id': 'alcohol',
              'track_name': 'Alcohol',
              'start_ts': detectionStart + offset,
              'end_ts': detectionStart + offset + 1800 + extra,
            },
          ])).single;
      final first = await propose(0);
      final stale = await propose(7200);
      await propose(7200, extra: 300);
      await expectLater(
        repo.saveDayReview(
          activities: [
            ActivityDecision(first, keep: true),
            ActivityDecision(stale, keep: true),
          ],
          moments: [],
        ),
        throwsA(isA<ActivityReviewException>()),
      );
      expect(await tracks.events(), isEmpty);
      expect(
        (await activities.get(first.id))!.status,
        ActivityReviewStatus.pending,
      );
      await repo.saveDayReview(
        activities: [
          ActivityDecision(
            first,
            keep: true,
            startTs: detectionStart + 300,
            endTs: detectionStart + 2100,
          ),
        ],
        moments: [],
      );
      expect(
        (await tracks.events(trackId: 'alcohol')).single.atMs,
        (detectionStart + 300) * 1000,
      );
    },
  );
}
