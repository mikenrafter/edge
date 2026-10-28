import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/tracks/experiment.dart';
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

  // The night after assigned date D has day_id D+1: the derive files a sleep
  // under the local date it ENDS on [lib/compute/substrate.dart "The main
  // sleep that ENDS in this calendar day"]. [onsetOf] gives the local onset.
  DateTime eveningOnset(String date) {
    final d = DateTime.parse(date);
    return DateTime(d.year, d.month, d.day, 22);
  }

  DateTime pastMidnightOnset(String date) {
    final d = DateTime.parse(date);
    return DateTime(d.year, d.month, d.day + 1, 0, 30);
  }

  Future<void> observations(
    Map experiment, {
    bool adherence = true,
    DateTime Function(String date)? onsetOf,
    bool Function(int index)? adhereAt,
    bool Function(int index)? nightAt,
  }) async {
    var doIndex = 0, dontIndex = 0, index = -1;
    for (final day in assignments(experiment)) {
      index++;
      final date = day['date'] as String;
      final at = (onsetOf ?? eveningOnset)(date);
      final done = day['do'] as bool;
      final d = DateTime.parse(date);
      final wakeDay = dayLabelOf(DateTime(d.year, d.month, d.day + 1));
      if (adherence && (adhereAt?.call(index) ?? true)) {
        if (done) {
          await store.log(
            TrackEvent(
              id: 'adherence:$date',
              trackId: 'custom',
              date: date,
              atMs: DateTime(d.year, d.month, d.day, 20).millisecondsSinceEpoch,
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
      if (!(nightAt?.call(index) ?? true)) continue;
      await db.insert('day_result', {
        'day_id': wakeDay,
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

  // why: review T11. The old test only compared seed 29 with seed 17, so it
  // passed even for a non-deterministic generator. A fixed seed must give the
  // same allocation again after a wipe, pairs must be balanced, and the
  // literal sequence pins the generator (D = do, s = skip) as worked out
  // independently from the splitmix-style steps in assignExperimentDays.
  // Mutation checked 2026-10-27: changing 0x9E3779B9 fails the literals.
  test('a fixed seed reproduces its allocation after a fresh install', () async {
    String letters(Map experiment) =>
        assignments(experiment).map((d) => d['do'] == true ? 'D' : 's').join();
    final first = await start(seed: 17);
    expect(letters(first), 'DssDDsDsDssDsD');
    final days = assignments(first);
    for (var k = 0; k + 1 < days.length; k += 2) {
      expect(days[k]['do'], isNot(days[k + 1]['do']), reason: 'block $k holds one do and one skip');
    }
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
    final again = await start(seed: 17);
    expect(assignments(again), days, reason: 'same seed, same assignments');
    expect(again['id'], first['id']);
    await env.wipe();
    db = await LocalDb.instance;
    store = TracksStore(db);
    await store.saveDefinition(
      const TrackDefinition(id: 'custom', name: 'Walk', icon: 'track', kind: 'activity', systems: ['hr']),
    );
    expect(letters(await start(seed: 29)), 'DsDsDssDDsDssD');
  });

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
      final running = await report(experiment, DateTime(2026, 9, 5, 12));
      expect(running['status'], 'running');
      expect((running['effects'] as Map?)?['hr'], isNull);
      final complete = await report(experiment, DateTime(2026, 9, 16, 12));
      expect(complete['reason'], 'insufficient_adherence');
      expect((complete['effects'] as Map?)?['hr'], isNull);
    },
  );

  test(
    'completed experiment reports observed effect with uncertainty, replay unchanged',
    () async {
      final experiment = await start(weeks: 4);
      await observations(experiment);
      final result = await report(experiment, DateTime(2026, 10, 1, 12));
      expect(result['status'], 'completed');
      final effect = (result['effects'] as Map)['hr'] as Map;
      expect(effect['n_do'], 14);
      expect(effect['n_dont'], 14);
      // Both arms have the same noise sequence: their mean difference is 8 bpm.
      expect(effect['effect'], closeTo(8, 1e-9));
      expect(effect['lower'], allOf(isA<num>(), lessThan(8), greaterThan(0)));
      expect(effect['upper'], allOf(isA<num>(), greaterThan(8), lessThan(16)));
      expect(await report(experiment, DateTime(2026, 10, 2, 12)), result);
    },
  );

  // why: review T2. A night that starts after midnight belongs to the evening
  // before (the derive's day_id is the wake day). Attributing by the onset's
  // calendar date shifts every such night onto the next assigned date, so the
  // effect would be mixed between arms. The same data with a 22:00 onset must
  // give the identical result. Run under TZ=UTC and TZ=America/Denver.
  // proves: CLAIM(night-by-wake-day)
  test('a night starting at 00:30 belongs to the evening before', () async {
    final experiment = await start(weeks: 4);
    await observations(experiment, onsetOf: pastMidnightOnset);
    final result = await report(experiment, DateTime(2026, 10, 1));
    final effect = (result['effects'] as Map)['hr'] as Map;
    expect(effect['n_do'], 14);
    expect(effect['n_dont'], 14);
    expect(effect['effect'], closeTo(8, 1e-9));
  });

  // why: review T2. One night per assigned date and none for a date whose night
  // is missing: a missing night is dropped, never borrowed from a neighbour.
  test('each assigned date takes only its own night', () async {
    final experiment = await start(weeks: 4);
    await observations(experiment);
    final doDates = [
      for (final d in assignments(experiment))
        if (d['do'] == true) d['date'] as String,
    ];
    // Remove the night after the first do date: n_do must drop by exactly one.
    final first = DateTime.parse(doDates.first);
    await db.delete(
      'day_result',
      where: 'day_id = ?',
      whereArgs: [dayLabelOf(DateTime(first.year, first.month, first.day + 1))],
    );
    final result = await report(experiment, DateTime(2026, 10, 1));
    final effect = (result['effects'] as Map)['hr'] as Map;
    expect(effect['n_do'], 13);
    expect(effect['n_dont'], 14);
  });

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
        final at = DateTime(2026, 8, 1 + i, 22);
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
        asOf: DateTime(2026, 9, 5, 12),
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

  // why: review T1 + owner decision 2026-10-27. A randomized "skip" day on a
  // prescribed treatment would tell the wearer to withhold it. A medication and
  // a track marked prescribed both refuse; neither is blocked from logging.
  // proves: CLAIM(never-ask-skip-prescribed)
  Future<void> addMedication() => MedDb.putDef(
    db,
    const MedDef(key: 'metformin', label: 'Metformin', doseValue: 500, doseUnit: 'mg'),
  );
  Future<void> setPrescribed(bool value) async {
    final current = (await store.definitions()).firstWhere((d) => d.id == 'custom');
    await store.saveDefinition(
      TrackDefinition.fromJson({...current.toJson(), 'prescribed': value}),
    );
  }

  test('a medication track can never start an experiment', () async {
    await addMedication();
    expect(
      (await store.definitions()).any((d) => d.id == 'med:metformin'),
      isTrue,
      reason: 'the medication is a visible, enabled track',
    );
    await expectLater(
      store.startExperiment(
        trackId: 'med:metformin',
        startDate: '2026-09-01',
        weeks: 2,
        seed: 17,
      ),
      throwsA(
        isA<ExperimentRefused>().having((e) => e.reason, 'reason', ExperimentRefusal.prescribed),
      ),
    );
    expect(await db.query('track_experiment'), isEmpty);
    expect(await db.query('track_experiment_day'), isEmpty);
  });

  test('a medication experiment row already stored sends no reminder', () async {
    await addMedication();
    // A restored backup could carry one: the reminder query is the last gate.
    await db.insert('track_experiment', {
      'id': 'xp-med',
      'track_id': 'med:metformin',
      'start_date': '2026-09-01',
      'end_date': '2026-09-14',
      'weeks': 2,
      'seed': 1,
      'created_ms': 1,
    });
    await db.insert('track_experiment_day', {
      'experiment_id': 'xp-med',
      'date': '2026-09-01',
      'do_it': 0,
    });
    expect(await store.experimentReminders(date: '2026-09-01'), isEmpty);
  });

  test('a prescribed custom track refuses, and the flag round-trips', () async {
    await setPrescribed(true);
    final saved = (await store.definitions()).firstWhere((d) => d.id == 'custom');
    expect(saved.prescribed, isTrue);
    expect(saved.toJson()['prescribed'], isTrue);
    await expectLater(
      store.startExperiment(trackId: 'custom', startDate: '2026-09-01', weeks: 2, seed: 17),
      throwsA(isA<ExperimentRefused>()),
    );
    await setPrescribed(false);
    expect((await start()).containsKey('id'), isTrue, reason: 'unflagged tracks still start');
  });

  test('marking a track prescribed mid-experiment silences every reminder', () async {
    final experiment = await start();
    final skipDay = assignments(experiment).firstWhere((d) => d['do'] == false)['date'] as String;
    final doDay = assignments(experiment).firstWhere((d) => d['do'] == true)['date'] as String;
    expect(await store.experimentReminders(date: skipDay), hasLength(1));
    await setPrescribed(true);
    expect(await store.experimentReminders(date: skipDay), isEmpty);
    expect(await store.experimentReminders(date: doDay), isEmpty);
    await setPrescribed(false);
    expect(await store.experimentReminders(date: skipDay), hasLength(1));
  });

  test('a restored experiment for a prescribed custom track sends no reminder', () async {
    await setPrescribed(true);
    await db.insert('track_experiment', {
      'id': 'xp-restored',
      'track_id': 'custom',
      'start_date': '2026-09-01',
      'end_date': '2026-09-14',
      'weeks': 2,
      'seed': 2,
      'created_ms': 1,
    });
    await db.insert('track_experiment_day', {
      'experiment_id': 'xp-restored',
      'date': '2026-09-01',
      'do_it': 0,
    });
    expect(await store.experimentReminders(date: '2026-09-01'), isEmpty);
  });

  test('ExperimentableTrack cannot be built from a prescribed track', () {
    const base = {'id': 'x', 'name': 'X', 'icon': 'track', 'kind': 'activity'};
    expect(ExperimentableTrack.from(TrackDefinition.fromJson({...base, 'id': 'med:x'})), isNull);
    expect(ExperimentableTrack.from(TrackDefinition.fromJson({...base, 'prescribed': true})), isNull);
    expect(ExperimentableTrack.from(TrackDefinition.fromJson(base)), isNotNull);
  });

  // why: review T6. The cannabis preset has withdrawal_days 28: every skip day
  // after a do day would still be exposed, biasing the effect toward zero.
  // proves: CLAIM(washout-vs-block)
  test('a track whose washout exceeds one day is refused with the washout reason', () async {
    await expectLater(
      store.startExperiment(trackId: 'cannabis', startDate: '2026-09-01', weeks: 2, seed: 17),
      throwsA(isA<ExperimentRefused>().having((e) => e.reason, 'reason', ExperimentRefusal.washout)),
    );
    expect(await db.query('track_experiment'), isEmpty);
    // The caffeine preset: 5 half-lives = 25 h and a 9 day withdrawal.
    await expectLater(
      store.startExperiment(trackId: 'caffeine', startDate: '2026-09-01', weeks: 2, seed: 17),
      throwsA(isA<ExperimentRefused>()),
    );
  });

  test('a short-lived track still starts', () async {
    final current = (await store.definitions()).firstWhere((d) => d.id == 'custom');
    await store.saveDefinition(
      TrackDefinition.fromJson({
        ...current.toJson(),
        'kinetics': {'half_life_hours': {'value': 2.0, 'locked': false}},
      }),
    );
    expect((await start()).containsKey('id'), isTrue);
  });

  // why: review T15. Deleting every day of an experiment must not leave a
  // zero-assignment parent that blocks new experiments and holds learning in
  // abstention. A partial delete keeps the experiment.
  test('deleteDays removes an experiment left with no days, not a partial one', () async {
    final experiment = await start();
    final dates = [for (final d in assignments(experiment)) d['date'] as String];
    await LocalDb.deleteDays({dates.first});
    expect(await db.query('track_experiment'), hasLength(1));
    expect(await db.query('track_experiment_day'), hasLength(dates.length - 1));
    await LocalDb.deleteDays(dates.toSet());
    expect(await db.query('track_experiment_day'), isEmpty);
    expect(await db.query('track_experiment'), isEmpty);
    expect((await start()).containsKey('id'), isTrue, reason: 'the range is free again');
  });

  // why: review T16. A restore merges experiments by id, which contains the
  // seed, so a backup's experiment for the same track and an overlapping range
  // would sit beside the local one: two sets of reminders, possibly opposite
  // for the same day. The earliest-created experiment of an overlapping group
  // is kept (with its days); other tracks and disjoint ranges are untouched,
  // and the drop is reported in the import counts.
  test('restore keeps one experiment among overlapping ones for a track', () async {
    Future<void> put(String id, String track, String from, int days, int created) async {
      final first = DateTime.parse(from);
      await db.insert('track_experiment', {
        'id': id,
        'track_id': track,
        'start_date': from,
        'end_date': dayLabelOf(DateTime(first.year, first.month, first.day + days - 1)),
        'weeks': days ~/ 7,
        'seed': 1,
        'created_ms': created,
      });
      for (var i = 0; i < days; i++) {
        await db.insert('track_experiment_day', {
          'experiment_id': id,
          'date': dayLabelOf(DateTime(first.year, first.month, first.day + i)),
          'do_it': i.isEven ? 1 : 0,
        });
      }
    }

    // Backup: A (09-01..09-14, older), plus a disjoint C (10-01..10-14) and
    // an other-track D on the same dates as A.
    await put('xp-a', 'custom', '2026-09-01', 14, 100);
    await put('xp-c', 'custom', '2026-10-01', 14, 120);
    await put('xp-d', 'other', '2026-09-01', 14, 130);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    db = await LocalDb.instance;
    store = TracksStore(db);
    // Local: B overlaps A (09-08..09-21), created later.
    await put('xp-b', 'custom', '2026-09-08', 14, 200);
    final counts = await LocalDb.importFromDbFile(path);
    db = await LocalDb.instance;
    final ids = [for (final r in await db.query('track_experiment', orderBy: 'id')) r['id']];
    expect(ids, ['xp-a', 'xp-c', 'xp-d']);
    expect(await db.query('track_experiment_day', where: 'experiment_id = ?', whereArgs: ['xp-b']), isEmpty);
    expect(await db.query('track_experiment_day', where: 'experiment_id = ?', whereArgs: ['xp-a']), hasLength(14));
    expect(counts['_track_experiment_overlap_dropped'], 1);
  });

  // why: review T8. Without a stop, deleting the track or changing your mind
  // left four weeks of daily notifications. Stopping ends the experiment at
  // yesterday, drops later assignments (no reminders), frees the range, and the
  // report says "stopped" instead of presenting a partial run as complete.
  // proves: CLAIM(stop-ends-reminders)
  test('stopExperiment ends reminders, frees the range and reports stopped', () async {
    final experiment = await start(); // 2026-09-01 .. 2026-09-14
    await withClock(Clock.fixed(DateTime(2026, 9, 4, 10)), () async {
      await store.stopExperiment(experiment['id'] as String);
    });
    final row = (await store.experiments(trackId: 'custom')).single;
    expect(row['end_date'], '2026-09-03');
    expect(assignments(row).map((d) => d['date']), ['2026-09-01', '2026-09-02', '2026-09-03']);
    expect(await store.experimentReminders(date: '2026-09-02'), hasLength(1));
    expect(await store.experimentReminders(date: '2026-09-04'), isEmpty);
    expect(await store.experimentReminders(date: '2026-09-10'), isEmpty);
    final result = await report(experiment, DateTime(2026, 10, 1));
    expect(result['status'], 'stopped');
    expect(result['effects'], isEmpty);
    // The range is free again.
    final again = await store.startExperiment(
      trackId: 'custom', startDate: '2026-09-04', weeks: 2, seed: 5);
    expect(again['start_date'], '2026-09-04');
  });

  test('stopping before the first day has passed removes the experiment', () async {
    final experiment = await start();
    await withClock(Clock.fixed(DateTime(2026, 9, 1, 8)), () async {
      await store.stopExperiment(experiment['id'] as String);
    });
    expect(await db.query('track_experiment'), isEmpty);
    expect(await db.query('track_experiment_day'), isEmpty);
  });

  test('stopExperiment refuses unknown and already finished experiments', () async {
    await expectLater(store.stopExperiment('nope'), throwsArgumentError);
    final experiment = await start();
    await withClock(Clock.fixed(DateTime(2026, 10, 1)), () async {
      await expectLater(store.stopExperiment(experiment['id'] as String), throwsStateError);
    });
    expect(await db.query('track_experiment_day'), hasLength(14));
  });

  // why: review T8. "Deleting" a track only disables it; reminders must follow.
  test('a disabled track sends no reminders and a re-enabled one does again', () async {
    final experiment = await start();
    final date = assignments(experiment).first['date'] as String;
    expect(await store.experimentReminders(date: date), hasLength(1));
    await store.deleteDefinition('custom');
    expect(await store.experimentReminders(date: date), isEmpty);
    final current = (await store.definitions()).firstWhere((d) => d.id == 'custom');
    await store.saveDefinition(TrackDefinition.fromJson({...current.toJson(), 'enabled': true}));
    expect(await store.experimentReminders(date: date), hasLength(1));
  });

  // why: review T9. During an experiment the estimates are abstentions, so
  // "no supported effect" is true by construction. Treating it as weak evidence
  // lengthened every field's minimum period 1% per day and logged
  // need_more_evidence_period for what is an experiment-imposed pause.
  // Control: the same state one refresh after the experiment does adapt.
  test('a running experiment leaves learning periods and the audit log unchanged', () async {
    final current = (await store.definitions()).firstWhere((d) => d.id == 'custom');
    await store.saveDefinition(
      TrackDefinition.fromJson({
        ...current.toJson(),
        'kinetics': {'half_life_hours': {'value': 2.0, 'locked': false}},
      }),
    );
    await db.insert('track_learning', {
      'track_id': 'custom',
      'started_ms': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      'last_step_date': '2026-08-31',
      'state_json': jsonEncode({'effects': []}),
    });
    await start(); // 2026-09-01 .. 2026-09-14
    await store.refreshLearning(asOf: DateTime(2026, 9, 5, 12));
    Future<Map> state() async => jsonDecode(
      (await db.query('track_learning', where: 'track_id = ?', whereArgs: ['custom']))
          .single['state_json'] as String,
    ) as Map;
    expect((await state())['periods_us'] ?? {}, isEmpty);
    expect(await db.query('track_learning_log'), isEmpty);
    await store.refreshLearning(asOf: DateTime(2026, 10, 1, 12));
    expect((await state())['periods_us'] as Map, isNotEmpty, reason: 'control: adapts outside an experiment');
    expect(await db.query('track_learning_log'), isNotEmpty);
  });

  // why: review T14. The last assigned night (date `end`) is filed under
  // end+1 and is only finalized after the wearer wakes. Opening the app at 07:00
  // on end+1 showed "Completed" with an effect missing that night, which then
  // changed silently. Stay running until the night is finalized, or until a
  // grace day (end+2) has passed.
  // proves: CLAIM(last-night-before-complete)
  test('the experiment waits for its last night, with a one day grace', () async {
    final experiment = await start(); // 2026-09-01 .. 2026-09-14, last night day_id 2026-09-15
    await observations(experiment);
    await db.delete('day_result', where: 'day_id = ?', whereArgs: ['2026-09-15']);
    final morning = DateTime(2026, 9, 15, 7);
    expect((await report(experiment, morning))['status'], 'running');
    expect((await report(experiment, DateTime(2026, 9, 14, 23)))['status'], 'running');
    final grace = await report(experiment, DateTime(2026, 9, 16, 7));
    expect(grace['status'], 'completed');
    expect(((grace['effects'] as Map)['hr'] as Map)['n_do'] + ((grace['effects'] as Map)['hr'] as Map)['n_dont'], 13);
    // Once the night is finalized the same morning completes, with all 14.
    final at = eveningOnset('2026-09-14');
    await db.insert('day_result', {
      'day_id': '2026-09-15',
      'algo_version': 118,
      'computed_at': 1,
      'finalized': 1,
      'partial': 0,
      'window_json': jsonEncode({
        'value': {
          'onset_ms': at.millisecondsSinceEpoch,
          'offset_ms': at.add(const Duration(hours: 8)).millisecondsSinceEpoch,
        },
      }),
      'payload_json': jsonEncode({'scalars': {'rhr': 60}}),
    });
    final done = await report(experiment, DateTime(2026, 9, 15, 10));
    expect(done['status'], 'completed');
    final effect = (done['effects'] as Map)['hr'] as Map;
    expect((effect['n_do'] as int) + (effect['n_dont'] as int), 14);
  });

  // why: review T7. A skip day counts only with an explicit absence, and the
  // only way to record one was "None today" for TODAY. A wearer who skipped on
  // Tuesday and opens the app on Wednesday could never count Tuesday; missing a
  // third of the skip days already makes an experiment insufficient. Answers for
  // every past assigned date, entered later, must count.
  // proves: CLAIM(backfill-answers)
  test('every past assigned date can be answered later and then counts', () async {
    final experiment = await start();
    await observations(experiment, adherence: false);
    await withClock(Clock.fixed(DateTime(2026, 9, 14, 22)), () async {
      for (final day in assignments(experiment)) {
        await store.answerExperimentDay(
          experiment['id'] as String,
          day['date'] as String,
          didIt: day['do'] == true,
        );
      }
    });
    final result = await report(experiment, DateTime(2026, 10, 1));
    expect(result['status'], 'completed');
    expect(result['adherence'], {'assigned': 14, 'followed': 14});
    final effect = (result['effects'] as Map)['hr'] as Map;
    expect(effect['n_do'], 7);
    expect(effect['n_dont'], 7);
  });

  test('an answer can be changed, and contradicting a real log is refused', () async {
    final experiment = await start();
    final id = experiment['id'] as String;
    final date = assignments(experiment).first['date'] as String;
    await withClock(Clock.fixed(DateTime(2026, 9, 5, 9)), () async {
      await store.answerExperimentDay(id, date, didIt: false);
      expect(await store.experimentAnswers(id), {date: false});
      await store.answerExperimentDay(id, date, didIt: true);
      expect(await store.experimentAnswers(id), {date: true});
      expect(await db.query('track_absence'), isEmpty);
      await store.answerExperimentDay(id, date, didIt: false);
      expect(await store.experimentAnswers(id), {date: false});
      expect(await store.events(trackId: 'custom'), isEmpty);
      // A real, separately logged occurrence cannot be answered "didn't".
      final other = assignments(experiment)[1]['date'] as String;
      await store.log(TrackEvent(id: 'real', trackId: 'custom', date: other, amount: 5));
      await expectLater(store.answerExperimentDay(id, other, didIt: false), throwsStateError);
      // Future dates and dates outside the experiment are refused.
      await expectLater(store.answerExperimentDay(id, '2026-09-09', didIt: true), throwsArgumentError);
      await expectLater(store.answerExperimentDay(id, '2026-08-01', didIt: true), throwsArgumentError);
    });
    await withClock(Clock.fixed(DateTime(2026, 9, 16)), () async {
      await expectLater(store.answerExperimentDay(id, date, didIt: true), throwsStateError);
    });
  });

  test('"did it" works for a substance track with an unknown dose', () async {
    final experiment = await store.startExperiment(
      trackId: 'alcohol', startDate: '2026-09-01', weeks: 2, seed: 17);
    final date = (experiment['assignments'] as List).cast<Map>().first['date'] as String;
    await withClock(Clock.fixed(DateTime(2026, 9, 2, 9)), () async {
      await store.answerExperimentDay(experiment['id'] as String, date, didIt: true);
    });
    expect((await store.events(trackId: 'alcohol')).single.date, date);
  });

  // why: review T12. The interval assertions in the completed-report test would
  // pass with a z quantile; the numbers are pinned in experiment_effect_test.
  // These pin the store's own rules: the three-night floor per arm, the 70%
  // adherence boundary, a skip day with a log, and which starts may overlap.
  List<int> indexesOf(Map experiment, bool done) => [
    for (var i = 0; i < assignments(experiment).length; i++)
      if (assignments(experiment)[i]['do'] == done) i,
  ];

  test('an arm with fewer than three nights gives insufficient_data; three is enough', () async {
    final experiment = await start();
    final doIdx = indexesOf(experiment, true), skipIdx = indexesOf(experiment, false);
    // 2 do nights, 5 skip nights, everyone adherent.
    var keep = {...doIdx.take(2), ...skipIdx.take(5)};
    await observations(experiment, nightAt: keep.contains);
    final thin = await report(experiment, DateTime(2026, 10, 1));
    expect(thin['status'], 'completed');
    expect(thin['reason'], 'insufficient_data');
    expect(thin['effects'], isEmpty);
    // Exactly 3 and 3 reports an effect.
    await db.delete('day_result');
    keep = {...doIdx.take(3), ...skipIdx.take(3)};
    await observations(experiment, adherence: false, nightAt: keep.contains);
    final enough = await report(experiment, DateTime(2026, 10, 1));
    expect(enough['reason'], isNull);
    final effect = (enough['effects'] as Map)['hr'] as Map;
    expect((effect['n_do'], effect['n_dont']), (3, 3));
  });

  test('adherence needs 70% of assigned days: 10 of 14 passes, 9 does not', () async {
    final experiment = await start();
    await observations(experiment, adhereAt: (i) => i < 10);
    final pass = await report(experiment, DateTime(2026, 10, 1));
    expect(pass['adherence'], {'assigned': 14, 'followed': 10});
    expect(pass['reason'], isNot('insufficient_adherence'));
    // Drop one answered day: 9 of 14 = 64% fails.
    final answered = assignments(experiment)[9];
    if (answered['do'] == true) {
      await db.delete('track_event');
    } else {
      await db.delete('track_absence', where: 'date = ?', whereArgs: [answered['date']]);
    }
    final fail = await report(experiment, DateTime(2026, 10, 1));
    if (answered['do'] == true) {
      expect((fail['adherence'] as Map)['followed'], lessThan(10));
    } else {
      expect(fail['adherence'], {'assigned': 14, 'followed': 9});
    }
    expect(fail['reason'], 'insufficient_adherence');
  });

  test('a skip day that also has a log is not followed and its night is excluded', () async {
    final experiment = await start();
    await observations(experiment);
    final skipDate = assignments(experiment).firstWhere((d) => d['do'] == false)['date'] as String;
    await store.log(TrackEvent(id: 'slip', trackId: 'custom', date: skipDate, amount: 10));
    final result = await report(experiment, DateTime(2026, 10, 1));
    expect(result['adherence'], {'assigned': 14, 'followed': 13});
    final effect = (result['effects'] as Map)['hr'] as Map;
    expect((effect['n_do'], effect['n_dont']), (7, 6));
  });

  test('overlapping starts are refused, back-to-back and other-track starts are allowed', () async {
    await start(); // 2026-09-01 .. 2026-09-14
    Future<Object?> startAt(String date, {int weeks = 2, String track = 'custom'}) async {
      try {
        return await store.startExperiment(trackId: track, startDate: date, weeks: weeks, seed: 3);
      } on StateError catch (e) {
        return e;
      }
    }

    expect(await startAt('2026-09-14'), isA<StateError>(), reason: 'shares the last day');
    expect(await startAt('2026-08-25'), isA<StateError>(), reason: 'ends inside the first');
    expect(await startAt('2026-08-20', weeks: 4), isA<StateError>(), reason: 'spans the first (08-20 to 09-16)');
    expect(await startAt('2026-08-19'), isA<StateError>(), reason: 'ends on the first day (08-19 to 09-01)');
    expect(await startAt('2026-09-15'), isA<Map>(), reason: 'back to back');
    expect(await startAt('2026-08-18'), isA<Map>(), reason: 'ends the day before');
    await store.saveDefinition(
      const TrackDefinition(id: 'other', name: 'Other', icon: 'track', kind: 'activity', systems: ['hr']),
    );
    expect(await startAt('2026-09-01', track: 'other'), isA<Map>(), reason: 'a different track');
  });
}
