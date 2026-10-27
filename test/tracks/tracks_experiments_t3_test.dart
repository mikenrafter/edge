import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  late TracksStore store;
  setUp(() async {
    env = await BackupEnv.create('tracks_experiments_t3.db');
    db = await LocalDb.instance;
    store = TracksStore(db);
    await store.saveDefinition(
      const TrackDefinition(
        id: 'custom',
        name: 'Evening walk',
        icon: 'track',
        kind: 'activity',
        unit: 'minutes',
        systems: ['hr'],
        roles: ['reminder_aware'],
      ),
    );
  });
  tearDown(() => env.dispose());

  Future<Map> start({int weeks = 2, int seed = 17}) async =>
      await (store as dynamic).startExperiment(
            trackId: 'custom',
            startDate: '2026-09-01',
            weeks: weeks,
            seed: seed,
          )
          as Map;
  List<Map> assignments(Map experiment) =>
      (experiment['assignments'] as List).cast<Map>();
  Future<Map> report(Map experiment, DateTime asOf) async =>
      await (store as dynamic).experimentReport(experiment['id'], asOf: asOf)
          as Map;

  Future<void> observations(Map experiment, {bool adherence = true}) async {
    var doIndex = 0, dontIndex = 0;
    for (final day in assignments(experiment)) {
      final date = day['date'] as String;
      final at = DateTime.parse('${date}T22:00:00Z');
      final done = day['do'] as bool;
      if (adherence) {
        if (done) {
          await store.log(
            TrackEvent(
              id: 'adherence:$date',
              trackId: 'custom',
              date: date,
              atMs: at
                  .subtract(const Duration(hours: 2))
                  .millisecondsSinceEpoch,
              amount: 20,
            ),
          );
        } else {
          await store.confirmNone('custom', date);
        }
      }
      // Every arm has observations [x-1,x,x+1,...], so uncertainty must be
      // finite and positive; every do outcome remains above every don't.
      final noise = ((done ? doIndex++ : dontIndex++) % 3) - 1;
      await db.insert('day_result', {
        'day_id': date,
        'algo_version': 118,
        'computed_at': 1,
        'finalized': 1,
        'partial': 0,
        'window_json': jsonEncode({
          'value': {
            'onset_ms': at.millisecondsSinceEpoch,
            'offset_ms': at
                .add(const Duration(hours: 8))
                .millisecondsSinceEpoch,
          },
        }),
        'payload_json': jsonEncode({
          'scalars': {'rhr': (done ? 68 : 60) + noise},
        }),
      });
    }
  }

  test(
    'two to four weeks randomize balanced calendar days and persist unchanged',
    () async {
      final experiment = await start(weeks: 3);
      final days = assignments(experiment);
      expect(days, hasLength(21));
      expect(days.first['date'], '2026-09-01');
      expect(days.last['date'], '2026-09-21');
      expect(days.map((d) => d['date']).toSet(), hasLength(21));
      final doCount = days.where((d) => d['do'] == true).length;
      expect(doCount, anyOf(10, 11));
      expect(days.map((d) => d['do']).toSet(), {true, false});
      expect(
        await store.events(trackId: 'custom'),
        isEmpty,
        reason: 'assignment is an invitation, never an observed occurrence',
      );
      await LocalDb.close();
      db = await LocalDb.instance;
      store = TracksStore(db);
      final restored =
          await (store as dynamic).experiments(trackId: 'custom') as List;
      expect(restored, hasLength(1));
      expect((restored.single as Map)['assignments'], days);
      expect((restored.single as Map)['id'], experiment['id']);
    },
  );

  test(
    'seed changes allocation; fixed seed reproduces it after a fresh install',
    () async {
      final first = assignments(await start(seed: 17));
      await env.wipe();
      db = await LocalDb.instance;
      store = TracksStore(db);
      await store.saveDefinition(
        const TrackDefinition(
          id: 'custom',
          name: 'Walk',
          icon: 'track',
          kind: 'activity',
          systems: ['hr'],
        ),
      );
      final second = assignments(await start(seed: 29));
      expect(
        second.map((d) => d['do']).toList(),
        isNot(first.map((d) => d['do']).toList()),
      );
    },
  );

  test(
    'invalid duration and a second running experiment are refused without partial rows',
    () async {
      for (final weeks in [0, 1, 5]) {
        await expectLater(start(weeks: weeks), throwsArgumentError);
      }
      expect(await (store as dynamic).experiments(trackId: 'custom'), isEmpty);
      final experiment = await start(weeks: 4);
      expect(assignments(experiment), hasLength(28));
      await expectLater(start(), throwsStateError);
      expect(
        await (store as dynamic).experiments(trackId: 'custom'),
        hasLength(1),
      );
    },
  );

  test(
    'running experiment withholds final effect and assignments do not establish adherence',
    () async {
      final experiment = await start();
      await observations(experiment, adherence: false);
      final running = await report(experiment, DateTime.utc(2026, 9, 5));
      expect(running['status'], 'running');
      expect((running['effects'] as Map?)?['hr'], isNull);
      final complete = await report(experiment, DateTime.utc(2026, 9, 16));
      expect(complete['reason'], 'insufficient_adherence');
      expect((complete['effects'] as Map?)?['hr'], isNull);
    },
  );

  test(
    'completed experiment reports observed effect with uncertainty, replay unchanged',
    () async {
      final experiment = await start(weeks: 4);
      await observations(experiment);
      final result = await report(experiment, DateTime.utc(2026, 10, 1));
      expect(result['status'], 'completed');
      final effect = (result['effects'] as Map)['hr'] as Map;
      expect(effect['n_do'], 14);
      expect(effect['n_dont'], 14);
      // Both arms have the same noise sequence: their mean difference is 8 bpm.
      expect(effect['effect'], closeTo(8, 1e-9));
      expect(effect['lower'], allOf(isA<num>(), lessThan(8), greaterThan(0)));
      expect(effect['upper'], allOf(isA<num>(), greaterThan(8), lessThan(16)));
      expect(await report(experiment, DateTime.utc(2026, 10, 2)), result);
    },
  );

  test(
    'reminder descriptors identify the assigned day without logging adherence',
    () async {
      final experiment = await start();
      final reminders =
          await (store as dynamic).experimentReminders(date: '2026-09-01')
              as List;
      expect(reminders, hasLength(1));
      final reminder = reminders.single as Map;
      expect(reminder['date'], '2026-09-01');
      expect(reminder['category'], 'reminders');
      expect(reminder['dedupe_key'], contains(experiment['id']));
      expect(reminder['route'], contains(experiment['id']));
      expect(
        await (store as dynamic).experimentReminders(date: '2026-08-31'),
        isEmpty,
      );
      expect(await store.events(trackId: 'custom'), isEmpty);
      expect(await db.query('track_absence'), isEmpty);
    },
  );

  test(
    'active experiment takes precedence in real T2 refresh without observational fallback',
    () async {
      await db.insert('track_learning', {
        'track_id': 'custom',
        'started_ms': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
        'last_step_date': '2026-08-31',
        'state_json': jsonEncode({
          'effects': [
            {
              'system': 'hr',
              'effect': -8.0,
              'reason': 'estimated',
              'matched_pairs': 24,
              'adjusted_p': .01,
            },
          ],
        }),
      });
      // These older observed days are deliberately outside the assignment
      // window. They must not fill missing experiment adherence or outcomes.
      for (var i = 0; i < 28; i++) {
        final at = DateTime.utc(2026, 8, 1 + i, 22);
        final date = at.toIso8601String().substring(0, 10);
        await store.confirmNone('custom', date);
        await db.insert('day_result', {
          'day_id': date,
          'algo_version': 118,
          'computed_at': 1,
          'finalized': 1,
          'partial': 0,
          'window_json': jsonEncode({
            'value': {
              'onset_ms': at.millisecondsSinceEpoch,
              'offset_ms': at
                  .add(const Duration(hours: 8))
                  .millisecondsSinceEpoch,
            },
          }),
          'payload_json': jsonEncode({
            'scalars': {'rhr': 60 + i % 3},
          }),
        });
      }
      await start();
      final summary = (await store.refreshLearning(
        asOf: DateTime.utc(2026, 9, 5),
      ))['custom']!;
      final effect = (summary['effects'] as List).single as Map;
      expect(effect['reason'], 'experiment_learning');
      expect(effect['effect'], isNull);
      final persisted =
          jsonDecode(
                (await db.query(
                      'track_learning',
                      where: 'track_id = ?',
                      whereArgs: ['custom'],
                    )).single['state_json']
                    as String,
              )
              as Map;
      expect(
        ((persisted['effects'] as List).single as Map)['reason'],
        'experiment_learning',
      );
    },
  );
}
