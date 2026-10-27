import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late TracksStore store;
  setUp(() async {
    env = await BackupEnv.create('tracks_store_t1.db');
    store = TracksStore(await LocalDb.instance);
  });
  tearDown(() async => env.dispose());
  TrackDefinition custom({int min = 0, int max = 10}) =>
      TrackDefinition.fromJson({
        'id': 'reading',
        'name': 'Reading',
        'icon': 'book',
        'kind': 'activity',
        'kinetics': {
          'half_life_hours': {'value': null, 'locked': true},
          'onset_hours': {'value': 0.5, 'locked': false},
        },
        'systems': ['sleep', 'future_system'],
        'roles': ['own_sleep'],
        'detection_min': min,
        'detection_max': max,
      });

  test(
    'setup transaction rejects overlap and rolls back definition on storage failure',
    () async {
      await store.saveDefinition(
        custom(),
        history: [
          const TrackSetupRange(
            id: 'first',
            trackId: 'reading',
            startDate: '2026-10-01',
            endDate: '2026-10-03',
            done: true,
          ),
        ],
      );
      final edited = TrackDefinition.fromJson({
        ...custom().toJson(),
        'name': 'Changed',
      });
      await expectLater(
        store.saveDefinition(
          edited,
          history: [
            const TrackSetupRange(
              id: 'a',
              trackId: 'reading',
              startDate: '2026-10-01',
              endDate: '2026-10-03',
              done: true,
            ),
            const TrackSetupRange(
              id: 'b',
              trackId: 'reading',
              startDate: '2026-10-03',
              endDate: '2026-10-05',
              done: false,
            ),
          ],
        ),
        throwsArgumentError,
      );
      final db = await LocalDb.instance;
      await db.execute(
        "CREATE TRIGGER reject_history BEFORE INSERT ON track_setup_history WHEN NEW.id = 'reject' BEGIN SELECT RAISE(ABORT, 'test'); END",
      );
      await expectLater(
        store.saveDefinition(
          edited,
          history: [
            const TrackSetupRange(
              id: 'reject',
              trackId: 'reading',
              startDate: '2026-10-01',
              endDate: '2026-10-02',
              done: false,
            ),
          ],
        ),
        throwsA(anything),
      );
      final after = (await store.definitions()).singleWhere(
        (d) => d.id == 'reading',
      );
      expect(after.name, 'Reading');
      expect(after.kinetics.fields['half_life_hours']!.toJson(), {
        'value': null,
        'locked': true,
      });
      expect(after.systems, ['sleep', 'future_system']);
      expect((await store.history('reading')).single.id, 'first');
    },
  );

  test('invalid bounds and event inputs never persist', () async {
    await expectLater(
      store.saveDefinition(custom(min: 3, max: 2)),
      throwsArgumentError,
    );
    await store.saveDefinition(custom());
    for (final e in [
      const TrackEvent(id: 'bad-date', trackId: 'reading', date: '2026-02-31'),
      const TrackEvent(
        id: 'bad-sub',
        trackId: 'reading',
        date: '2026-10-01',
        subActivityId: 'unknown',
      ),
      const TrackEvent(
        id: 'bad-amount',
        trackId: 'reading',
        date: '2026-10-01',
        amount: double.nan,
      ),
      const TrackEvent(
        id: 'bad-source',
        trackId: 'reading',
        date: '2026-10-01',
        sourceKind: 'food',
      ),
      const TrackEvent(
        id: 'bad-time',
        trackId: 'reading',
        date: '2026-10-02',
        atMs: 1790845200000,
      ),
    ]) {
      await expectLater(store.log(e), throwsArgumentError);
    }
    expect(await store.events(), isEmpty);
  });

  test(
    'nullable manual log retries are idempotent and recent lookup includes quiet tracks',
    () async {
      await store.saveDefinition(custom());
      const reading = TrackEvent(
        id: 'reading1',
        trackId: 'reading',
        date: '2026-10-01',
      );
      await store.log(reading);
      await store.log(reading);
      // More logs than the UI page cap cannot hide another track's last record.
      final batch = store.db.batch();
      for (var i = 0; i < 205; i++) {
        batch.insert(
          'track_event',
          TrackEvent(
            id: 'c$i',
            trackId: 'caffeine',
            date: '2026-10-02',
          ).toJson(),
        );
      }
      await batch.commit(noResult: true);
      expect(await store.events(limit: 200), hasLength(200));
      final last = await store.lastEvents();
      expect(last['reading']!.toJson(), {...reading.toJson(), 'unit': ''});
      expect(last['reading']!.amount, isNull);
      await store.deleteEvent(reading);
      expect(await store.events(trackId: 'reading'), isEmpty);
    },
  );

  test(
    'workout reverse log and edit use canonical session, clear stale scores',
    () async {
      const log = TrackEvent(
        id: 'run',
        trackId: 'late_workout',
        date: '2026-10-01',
        atMs: 1790863200000,
        amount: 30,
      );
      await store.log(log);
      await store.log(log);
      final db = await LocalDb.instance;
      expect(await db.query('track_event'), isEmpty);
      expect(await db.query('sessions'), hasLength(1));
      await db.update(
        'sessions',
        {'strain': 12, 'steps': 5000, 'private': 1, 'rpe': 7},
        where: 'id = ?',
        whereArgs: ['run'],
      );
      final feed = (await store.events()).single;
      await store.log(TrackEvent.fromJson({...feed.toJson(), 'amount': 60}));
      final workout = (await db.query('sessions')).single;
      expect(workout['end_ts'], 1790866800);
      expect(workout['strain'], isNull);
      expect(workout['steps'], isNull);
      expect(workout['private'], 1);
      expect(workout['rpe'], 7);
      await store.deleteEvent((await store.events()).single);
      expect(await db.query('sessions'), isEmpty);
      expect(await store.events(), isEmpty);
    },
  );

  test(
    'food reverse edit retains nutrient evidence and delete reaches owner',
    () async {
      final db = await LocalDb.instance;
      await NutritionDb.put(
        db,
        const FoodEntry(
          id: 'food',
          date: '2026-10-01',
          meal: 'dinner',
          label: 'Soup',
          quantity: 2,
          unit: 'bowls',
          kcal: 300,
        ),
      );
      await store.log(
        TrackEvent.fromJson({
          ...(await store.events()).single.toJson(),
          'amount': 3,
        }),
      );
      final entry = (await NutritionDb.entriesForDay(db, '2026-10-01')).single;
      expect(entry.quantity, 3);
      expect(entry.kcal, 300);
      expect(entry.label, 'Soup');
      expect(entry.unit, 'bowls');
      await store.deleteEvent((await store.events()).single);
      expect(await NutritionDb.entriesForDay(db, '2026-10-01'), isEmpty);
    },
  );

  test(
    'medication reverse logging preserves unknown amount and definition owner',
    () async {
      final db = await LocalDb.instance;
      await MedDb.putDef(
        db,
        const MedDef(
          key: 'vitamin',
          label: 'Vitamin',
          doseValue: 1000,
          doseUnit: 'IU',
        ),
      );
      final definition = (await store.definitions()).singleWhere(
        (d) => d.id == 'med:vitamin',
      );
      await store.saveDefinition(
        TrackDefinition.fromJson({
          ...definition.toJson(),
          'name': 'My vitamin',
          'unit': 'tablets',
        }),
      );
      expect((await MedDb.defs(db)).single.label, 'My vitamin');
      await store.log(
        const TrackEvent(
          id: 'dose',
          trackId: 'med:vitamin',
          date: '2026-10-01',
          atMs: 1790845200000,
        ),
      );
      final event = (await store.events()).single;
      expect(event.amount, isNull);
      expect(event.atMs, 1790845200000);
      expect(await db.query('track_event'), isEmpty);
      await store.deleteEvent(event);
      expect(await store.events(), isEmpty);
      await MedDb.putDef(
        db,
        const MedDef(key: 'vitamin', label: 'Owner edit', active: false),
      );
      final inactive = (await store.definitions()).singleWhere(
        (d) => d.id == 'med:vitamin',
      );
      expect(inactive.name, 'Owner edit');
      expect(inactive.enabled, false);
    },
  );

  test(
    'caffeine moment edit and journal residual edit keep one consistent total',
    () async {
      await LocalDb.putJournalMetrics('2026-10-01', {
        'caffeine_mg': const JournalMetricValue(250),
      });
      await LocalDb.putMomentLabel(
        const MomentLabel(
          date: '2026-10-01',
          hhmm: '09:00',
          label: 'caffeine',
          caffeineMg: 100,
          answeredAtMs: 1,
        ),
      );
      var events = await store.events(trackId: 'caffeine');
      await store.log(
        TrackEvent.fromJson({
          ...events.singleWhere((e) => e.sourceKind == 'moment').toJson(),
          'amount': 80,
        }),
      );
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.value,
        230,
      );
      events = await store.events(trackId: 'caffeine');
      expect(events.singleWhere((e) => e.sourceKind == 'journal').amount, 150);
      await store.log(
        TrackEvent.fromJson({
          ...events.singleWhere((e) => e.sourceKind == 'journal').toJson(),
          'amount': 20,
        }),
      );
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.value,
        100,
      );
      await store.deleteEvent(
        (await store.events(
          trackId: 'caffeine',
        )).singleWhere((e) => e.sourceKind == 'journal'),
      );
      expect((await store.events(trackId: 'caffeine')).single.amount, 80);
    },
  );

  test('rejected nap never becomes an occurrence; explicit nap does', () async {
    final db = await LocalDb.instance;
    await db.insert('sleep_nap', {
      'day_id': '2026-10-01',
      'start_ts': 1790863200,
      'end_ts': 1790865000,
      'source': 'rejected',
      'created_at': 1,
    });
    expect(await store.events(trackId: 'naps'), isEmpty);
    await db.update('sleep_nap', {'source': 'manual'});
    expect((await store.events(trackId: 'naps')).single.amount, 30);
  });

  test(
    'edited preset restores over seeds and disabled preset stays disabled on reopen',
    () async {
      var caffeine = (await store.definitions()).singleWhere(
        (d) => d.id == 'caffeine',
      );
      await store.saveDefinition(
        TrackDefinition.fromJson({
          ...caffeine.toJson(),
          'name': 'Owner coffee',
        }),
      );
      await env.seedData();
      final backup = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(backup);
      store = TracksStore(await LocalDb.instance);
      expect(
        (await store.definitions()).singleWhere((d) => d.id == 'caffeine').name,
        'Owner coffee',
      );
      await store.deleteDefinition('caffeine');
      await LocalDb.close();
      store = TracksStore(await LocalDb.instance);
      caffeine = (await store.definitions()).singleWhere(
        (d) => d.id == 'caffeine',
      );
      expect(caffeine.enabled, false);
      expect(caffeine.name, 'Owner coffee');
      expect(
        jsonDecode(
          (await store.db.query(
                'track_definition',
                where: 'id = ?',
                whereArgs: ['caffeine'],
              )).single['payload_json']
              as String,
        )['name'],
        'Owner coffee',
      );
    },
  );
  test(
    'substance dose identity preserves same-minute logs and journal aggregate on retries/edits/deletes',
    () async {
      const first = TrackEvent(
        id: 'cup1',
        trackId: 'caffeine',
        date: '2026-10-01',
        atMs: 1790845200123,
        amount: 100,
        subActivityId: 'coffee',
      );
      const second = TrackEvent(
        id: 'cup2',
        trackId: 'caffeine',
        date: '2026-10-01',
        atMs: 1790845220456,
        amount: 80,
        subActivityId: 'tea',
      );
      await store.log(first);
      await store.log(first);
      await store.log(second);
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.value,
        180,
      );
      var events = await store.events(trackId: 'caffeine');
      expect(events, hasLength(2));
      expect(events.map((e) => e.atMs).toSet(), {1790845200123, 1790845220456});
      expect(events.map((e) => e.subActivityId).toSet(), {'coffee', 'tea'});
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.atMinuteOfDay,
        540,
      );
      await store.log(
        TrackEvent.fromJson({
          ...first.toJson(),
          'date': '2026-10-02',
          'at_ms': 1790931600123,
          'amount': 120,
        }),
      );
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.value,
        80,
      );
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-02',
        ))['caffeine_mg']!.value,
        120,
      );
      await store.deleteEvent(second);
      expect(
        (await LocalDb.journalMetricsForDay('2026-10-01'))['caffeine_mg'],
        isNull,
      );
      await store.log(
        const TrackEvent(
          id: 'drink',
          trackId: 'alcohol',
          date: '2026-10-02',
          amount: 2,
        ),
      );
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-02',
        ))['alcohol_units']!.value,
        2,
      );
      expect((await store.events(trackId: 'alcohol')).single.amount, 2);
      await LocalDb.putJournalMetrics('2026-10-02', {
        'caffeine_mg': const JournalMetricValue(50),
      });
      final moved = (await store.events(trackId: 'caffeine')).single;
      await store.log(
        moved,
      ); // A lower edited daily total cannot make retry add again.
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-02',
        ))['caffeine_mg']!.value,
        50,
      );
      expect((await store.events(trackId: 'caffeine')).single.amount, 120);
    },
  );

  test(
    'residual journal edits retain both explicit moments and track doses',
    () async {
      await LocalDb.putJournalMetrics('2026-10-01', {
        'caffeine_mg': const JournalMetricValue(150),
      });
      await LocalDb.putMomentLabel(
        const MomentLabel(
          date: '2026-10-01',
          hhmm: '09:00',
          label: 'caffeine',
          caffeineMg: 100,
          answeredAtMs: 1,
        ),
      );
      await store.log(
        const TrackEvent(
          id: 'later-cup',
          trackId: 'caffeine',
          date: '2026-10-01',
          atMs: 1790859600000,
          amount: 80,
        ),
      );
      var events = await store.events(trackId: 'caffeine');
      expect(events, hasLength(3));
      final residual = events.singleWhere((e) => e.sourceKind == 'journal');
      expect(residual.amount, 50);
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.atMinuteOfDay,
        780,
      );
      await store.log(
        TrackEvent.fromJson({...residual.toJson(), 'amount': 20}),
      );
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.value,
        200,
      );
      await store.deleteEvent(residual);
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.value,
        180,
      );
      expect(await store.events(trackId: 'caffeine'), hasLength(2));
    },
  );

  test(
    'canonical nap and workout duration limits refuse before persisting',
    () async {
      for (final minutes in [1.0, 361.0]) {
        await expectLater(
          store.log(
            TrackEvent(
              id: 'nap',
              trackId: 'naps',
              date: '2026-10-01',
              atMs: 1790863200000,
              amount: minutes,
            ),
          ),
          throwsArgumentError,
        );
      }
      await expectLater(
        store.log(
          const TrackEvent(
            id: 'short',
            trackId: 'late_workout',
            date: '2026-10-01',
            atMs: 1790863200000,
            amount: 0.5,
          ),
        ),
        throwsA(anything),
      );
      expect(await store.events(), isEmpty);
      await store.log(
        const TrackEvent(
          id: 'valid',
          trackId: 'late_workout',
          date: '2026-10-01',
          atMs: 1790863200000,
          amount: 30,
        ),
      );
      await expectLater(
        store.log(
          const TrackEvent(
            id: 'overlap',
            trackId: 'late_workout',
            date: '2026-10-01',
            atMs: 1790863260000,
            amount: 30,
          ),
        ),
        throwsA(anything),
      );
      expect(await store.events(), hasLength(1));
    },
  );
  test(
    'known evening residual time survives morning timed log, removing residual exposes dose time',
    () async {
      await LocalDb.putJournalMetrics('2026-10-01', {
        'caffeine_mg': const JournalMetricValue(100, atMinuteOfDay: 1200),
      });
      await store.log(
        const TrackEvent(
          id: 'morning',
          trackId: 'caffeine',
          date: '2026-10-01',
          atMs: 1790845200000,
          amount: 80,
        ),
      );
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.atMinuteOfDay,
        1200,
      );
      final remainder = (await store.events(
        trackId: 'caffeine',
      )).singleWhere((e) => e.sourceKind == 'journal');
      await store.deleteEvent(remainder);
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.atMinuteOfDay,
        540,
      );
    },
  );

  test(
    'event unit snapshots prevent editable cups preset from becoming milligrams',
    () async {
      await store.log(
        const TrackEvent(
          id: 'mg',
          trackId: 'caffeine',
          date: '2026-10-01',
          amount: 80,
        ),
      );
      final definition = (await store.definitions()).singleWhere(
        (d) => d.id == 'caffeine',
      );
      await store.saveDefinition(
        TrackDefinition.fromJson({...definition.toJson(), 'unit': 'cups'}),
      );
      await store.log(
        const TrackEvent(
          id: 'cup',
          trackId: 'caffeine',
          date: '2026-10-01',
          amount: 1,
        ),
      );
      final events = await store.events(trackId: 'caffeine');
      expect(events.singleWhere((e) => e.id == 'mg').unit, 'mg');
      expect(events.singleWhere((e) => e.id == 'cup').unit, 'cups');
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.value,
        80,
      );
      await store.deleteEvent(events.singleWhere((e) => e.id == 'cup'));
      expect(
        (await LocalDb.journalMetricsForDay(
          '2026-10-01',
        ))['caffeine_mg']!.value,
        80,
      );
    },
  );
  test(
    'linked durations keep explicit minutes after the editable default unit changes',
    () async {
      final workout = (await store.definitions()).singleWhere(
        (d) => d.id == 'late_workout',
      );
      await store.saveDefinition(
        TrackDefinition.fromJson({...workout.toJson(), 'unit': 'hours'}),
      );
      await store.log(
        const TrackEvent(
          id: 'duration',
          trackId: 'late_workout',
          date: '2026-10-01',
          atMs: 1790863200000,
          amount: 30,
          unit: 'minutes',
        ),
      );
      final event = (await store.events(trackId: 'late_workout')).single;
      expect(event.amount, 30);
      expect(event.unit, 'minutes');
    },
  );
  test('new nutrition mirror preserves the editable portion unit', () async {
    final meal = (await store.definitions()).singleWhere(
      (d) => d.id == 'late_meal',
    );
    await store.saveDefinition(
      TrackDefinition.fromJson({...meal.toJson(), 'unit': 'bowls'}),
    );
    await store.log(
      const TrackEvent(
        id: 'soup',
        trackId: 'late_meal',
        date: '2026-10-01',
        amount: 2,
      ),
    );
    final entry = (await NutritionDb.entriesForDay(
      store.db,
      '2026-10-01',
    )).single;
    expect(entry.quantity, 2);
    expect(entry.unit, 'bowls');
    final event = (await store.events(trackId: 'late_meal')).single;
    expect(event.amount, 2);
    expect(event.unit, 'bowls');
  });
}
