import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late ActivityStore activities;
  late LocalRepositoryImpl repo;
  final start = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch ~/ 1000;

  setUp(() async {
    env = await BackupEnv.create('tracks_review_t1.db');
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    activities = ActivityStore(db);
    repo = LocalRepositoryImpl(getProfileMap: () => {});
  });
  tearDown(() => env.dispose());

  Future<ActivitySuggestion> meal([int offset = 0]) async =>
      (await activities.reconcile(ActivityKind.meal, [
        {
          'start_ts': start + offset,
          'end_ts': start + offset + 1500,
          'confidence': 0.5,
        },
      ])).single;

  test(
    'only confirmed review items log, and confirmation retries log once',
    () async {
      final candidate = await meal();
      expect(await db.query('track_event_feed'), isEmpty);
      await repo.confirmActivity(candidate);
      await repo.confirmActivity(candidate);
      final rows = await db.query('track_event_feed');
      expect(rows, hasLength(1));
      expect(rows.single['track_id'], 'late_meal');
      expect(rows.single['at_ms'], start * 1000);
      expect(rows.single['amount'], isNull);
      expect(
        await db.query('track_event'),
        isEmpty,
        reason: 'the moment owner already stores this occurrence',
      );
      final discarded = await meal(3 * 3600);
      await repo.discardActivity(discarded);
      expect(await db.query('track_event_feed'), rows);
    },
  );

  test(
    'a confirmed meal already logged in nutrition has one track occurrence',
    () async {
      await NutritionDb.put(
        db,
        FoodEntry(
          id: 'lunch',
          date: '2026-10-01',
          atTs: start,
          meal: 'lunch',
          label: 'Rice',
          kcal: 550,
        ),
      );
      await repo.confirmActivity(await meal());
      final rows = await db.query('track_event_feed');
      expect(
        rows,
        hasLength(1),
        reason: 'confirmation describes the same eating occasion',
      );
      expect(rows.single['track_id'], 'late_meal');
      expect(rows.single['at_ms'], start * 1000);
      expect((await db.query('food_entry')).single['kcal'], 550);
    },
  );

  test('batch review failure rolls back its track occurrence', () async {
    final first = await meal();
    final stale = await meal(3 * 3600);
    await activities.reconcile(ActivityKind.meal, [
      {'start_ts': stale.startTs, 'end_ts': stale.endTs + 300},
    ]);
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
    expect(await db.query('track_event_feed'), isEmpty);
    expect(
      (await activities.get(first.id))!.status,
      ActivityReviewStatus.pending,
    );
  });
}
