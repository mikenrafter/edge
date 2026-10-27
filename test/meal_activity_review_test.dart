import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backup/backup_support.dart';

// Fixed UTC fixture. The production writer still validates against real time;
// every bound here is historical and cannot become future at midnight.
final _start = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch ~/ 1000;
const _day = '2026-10-01';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late ActivityStore store;
  late LocalRepositoryImpl repo;
  setUpAll(() async => env = await BackupEnv.create('batch_b_meal_review.db'));
  tearDownAll(() => env.dispose());
  setUp(() async {
    await env.wipe();
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    store = ActivityStore(db);
    repo = LocalRepositoryImpl(getProfileMap: () => {});
  });

  ActivityKind kind() => ActivityKind.values.byName('meal');
  Future<ActivitySuggestion> proposal({int offset = 0}) async =>
      (await store.reconcile(kind(), [{
        'start_ts': _start + offset, 'end_ts': _start + offset + 25 * 60,
        'confidence': 0.5,
      }])).single;

  Future<void> assertMealOnly({required int minute, int foodCount = 0}) async {
    final labels = await LocalDb.momentLabels(date: _day);
    expect(labels.map((l) => (l.hhmm, l.label)),
        [('${minute ~/ 60}:${(minute % 60).toString().padLeft(2, '0')}', 'meal')]);
    expect(await db.query('sleep_nap'), isEmpty,
        reason: 'meal confirmation must never take the nap else branch');
    expect(await db.query('sessions'), isEmpty);
    expect(await db.query('food_entry'), hasLength(foodCount));
  }

  test('meal enum decodes persisted rows', () {
    final row = ActivitySuggestion.fromRow({
      'id': 'meal:1', 'kind': 'meal', 'start_ts': _start,
      'end_ts': _start + 1500, 'revision': 0, 'status': 'pending',
      'details_json': '{}',
    });
    expect(row.kind.name, 'meal');
    expect(row.startTs, _start);
  });

  test('reconcile is candidate-only; direct confirm creates one meal moment', () async {
    final p = await proposal();
    expect(await LocalDb.momentLabels(date: _day), isEmpty);
    expect(await db.query('food_entry'), isEmpty);
    await repo.confirmActivity(p);
    await repo.confirmActivity(p);
    expect((await store.get(p.id))!.status, ActivityReviewStatus.confirmed);
    await assertMealOnly(minute: 720);
    expect(await store.reconcile(kind(), [{
      'start_ts': _start + 60, 'end_ts': _start + 1600,
    }]), isEmpty, reason: 'a later derive cannot undo the user decision');
  });

  test('confirm preserves existing nutrition instead of inventing a second meal', () async {
    const food = FoodEntry(id: 'lunch', date: _day, meal: 'lunch',
        label: 'Rice bowl', kcal: 550, proteinG: 20);
    await NutritionDb.put(db, FoodEntry(id: food.id, date: food.date,
        meal: food.meal, label: food.label, atTs: _start,
        kcal: food.kcal, proteinG: food.proteinG));
    final before = (await db.query('food_entry')).single;
    final p = await proposal();
    await repo.confirmActivity(p);
    await assertMealOnly(minute: 720, foodCount: 1);
    expect((await db.query('food_entry')).single, before,
        reason: 'existing nutrition details and timestamp survive confirmation');
  });

  test('discard is durable and creates neither food nor moment', () async {
    final p = await proposal();
    await repo.discardActivity(p);
    await repo.discardActivity(p);
    expect((await store.get(p.id))!.status, ActivityReviewStatus.discarded);
    expect(await LocalDb.momentLabels(date: _day), isEmpty);
    expect(await db.query('food_entry'), isEmpty);
    expect(await store.reconcile(kind(), [{
      'start_ts': _start, 'end_ts': _start + 1800,
    }]), isEmpty);
  });

  test('batch Save uses the edited meal time, never sleep credit', () async {
    final p = await proposal();
    await repo.saveDayReview(activities: [ActivityDecision(p, keep: true,
        startTs: _start + 300, endTs: _start + 1800)], moments: []);
    await assertMealOnly(minute: 725);
    expect((await store.get(p.id))!.status, ActivityReviewStatus.confirmed);
  });

  test('batch Save rolls back meals if another decision is stale', () async {
    final first = await proposal();
    final second = await proposal(offset: 3 * 3600);
    await store.reconcile(kind(), [{
      'start_ts': second.startTs, 'end_ts': second.endTs + 300,
    }]);
    await expectLater(repo.saveDayReview(activities: [
      ActivityDecision(first, keep: true), ActivityDecision(second, keep: true),
    ], moments: []), throwsA(isA<ActivityReviewException>()));
    expect((await store.get(first.id))!.status, ActivityReviewStatus.pending);
    expect(await LocalDb.momentLabels(date: _day), isEmpty);
  });

  test('meal suggestion and confirmed moment survive full backup restore', () async {
    final accepted = await proposal();
    final discarded = await proposal(offset: 3 * 3600);
    await repo.confirmActivity(accepted);
    await repo.discardActivity(discarded);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.importFromDbFile(path);
    db = await LocalDb.instance;
    store = ActivityStore(db);
    expect((await store.get(accepted.id))!.status, ActivityReviewStatus.confirmed);
    expect((await store.get(discarded.id))!.status, ActivityReviewStatus.discarded);
    await assertMealOnly(minute: 720);
  });

  test('recent issue slice carries the meal suggestion and its moment', () async {
    final p = await proposal();
    await repo.confirmActivity(p);
    final path = await exportRecentSlice(now: DateTime.utc(2026, 10, 2));
    final copy = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      expect((await copy.query('activity_suggestions')).single['kind'], 'meal');
      expect((await copy.query('moment_label')).single['label'], 'meal');
      expect(await copy.query('sleep_nap'), isEmpty);
    } finally {
      await copy.close();
    }
  });
  test('invalid edited bounds roll back the decision and moment', () async {
    final p = await proposal();
    for (final bounds in [(_start + 1, _start), (_start, _start),
        (-1, _start)]) {
      await expectLater(repo.confirmActivity(p,
          startTs: bounds.$1, endTs: bounds.$2),
          throwsA(isA<ActivityReviewException>()));
      expect((await store.get(p.id))!.status, ActivityReviewStatus.pending);
      expect(await LocalDb.momentLabels(date: _day), isEmpty);
    }
  });

  for (final decision in ['discarded', 'edited']) {
    test('restore keeps local $decision meal decision and only its moment', () async {
      final p = await proposal();
      final pending = await LocalDb.exportCopy();
      await repo.confirmActivity(p);
      final confirmed = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.importFromDbFile(pending);
      db = await LocalDb.instance;
      store = ActivityStore(db);
      if (decision == 'discarded') {
        await repo.discardActivity(p);
      } else {
        await repo.confirmActivity(p, startTs: _start + 300,
            endTs: _start + 1800);
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        await LocalDb.importFromDbFile(confirmed);
        expect((await store.get(p.id))!.status, decision == 'discarded'
            ? ActivityReviewStatus.discarded : ActivityReviewStatus.confirmed);
        if (decision == 'discarded') {
          expect(await LocalDb.momentLabels(date: _day), isEmpty);
        } else {
          await assertMealOnly(minute: 725);
        }
      }
    });
  }

}
