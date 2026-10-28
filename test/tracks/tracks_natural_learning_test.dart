import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/wake/wake_night_context_db.dart';
import 'package:openstrap_edge/wake/wake_journal.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';
import 'package:openstrap_edge/wake/natural_wake_tuning.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late TracksStore store;
  setUp(() async {
    env = await BackupEnv.create('tracks_natural_t2.db');
    store = TracksStore(await LocalDb.instance);
    for (final id in ['tea ritual', 'reading']) {
      await store.saveDefinition(
        TrackDefinition(
          id: id,
          name: id,
          icon: 'track',
          kind: 'activity',
          roles: ['own_sleep'],
          systems: ['sleep'],
        ),
      );
    }
  });
  tearDown(() => env.dispose());
  Future<void> log(String id, DateTime at) => store.log(
    TrackEvent(
      id: '$id:${at.millisecondsSinceEpoch}',
      trackId: id,
      date: dayLabelOf(at),
      atMs: at.millisecondsSinceEpoch,
    ),
  );
  Future<ConfounderProfile> profile(DateTime bed) =>
      const DbWakeNightSource().profile(
        DateTime(bed.year, bed.month, bed.day),
        DateTime(bed.year, bed.month, bed.day + 1),
        bed,
      );

  test(
    'own-sleep user identities compose without inventing thresholds',
    () async {
      final bed = DateTime(2026, 9, 1, 22);
      await log('tea ritual', bed.subtract(const Duration(hours: 6)));
      final a = await profile(bed);
      expect(a, isNot(ConfounderProfile.identity));
      expect(a.hrArousalBpm, 4);
      expect(a.combine(ConfounderProfile.identity), a);
      await log('reading', bed.subtract(const Duration(hours: 1)));
      final ab = await profile(bed);
      final bed2 = DateTime(2026, 9, 2, 22);
      await log('reading', bed2.subtract(const Duration(hours: 1)));
      final b = await profile(bed2);
      expect(a, isNot(b));
      expect(a.combine(b), ab);
      expect(a.combine(b), b.combine(a));
      expect(a.combine(b).combine(a), a.combine(b.combine(a)));
    },
  );

  test(
    'definition and event edits invalidate the occurrence cache revision',
    () async {
      const source = DbWakeNightSource();
      final from = DateTime(2026, 9, 1), to = DateTime(2026, 9, 2);
      final before = await source.revision(from, to);
      await log('reading', DateTime(2026, 9, 1, 21));
      final logged = await source.revision(from, to);
      expect(logged, isNot(before));
      final d = (await store.definitions()).firstWhere(
        (d) => d.id == 'reading',
      );
      await store.saveDefinition(
        TrackDefinition.fromJson({...d.toJson(), 'roles': []}),
      );
      expect(await source.revision(from, to), isNot(logged));
    },
  );

  test('future, disabled and non-sleep tracks cannot affect tonight', () async {
    final bed = DateTime(2026, 9, 1, 22);
    await log('reading', bed.add(const Duration(minutes: 1)));
    expect(await profile(bed), ConfounderProfile.identity);
    await log('tea ritual', bed.subtract(const Duration(hours: 1)));
    await store.deleteDefinition('tea ritual');
    expect(await profile(bed), ConfounderProfile.identity);
    final d = (await store.definitions()).firstWhere((d) => d.id == 'reading');
    await store.saveDefinition(
      TrackDefinition.fromJson({
        ...d.toJson(),
        'systems': ['glucose'],
      }),
    );
    await log('reading', bed.subtract(const Duration(hours: 1)));
    expect(await profile(bed), ConfounderProfile.identity);
  });

  test('user wake warmup never borrows nights from a different active set', () {
    WakeNightOutcome night(int i, Set<String> ids) {
      final wake = DateTime.utc(2026, 9, 2 + i * 7, 7);
      return WakeNightOutcome(
        dayId: dayLabelOf(wake),
        userTrackIds: ids,
        wakeEpochSec: wake.millisecondsSinceEpoch ~/ 1000,
        timeToWake: const Duration(minutes: 1),
        snoozeCount: 0,
        dream: WakeDreamResponse(
          answer: DreamAnswer.dream,
          path: WakePath.natural,
          at: wake,
        ),
        recovery: 80,
        mainSleepTst: const Duration(hours: 8),
      );
    }

    final history = [
      for (var i = 0; i < 7; i++) night(i, {'reading'}),
      night(7, {'reading', 'tea ritual'}),
    ];
    final mixed = NaturalWakeTuning.evaluate(history, userTrackId: 'reading');
    expect(mixed.applied, false);
    expect(mixed.eligibleNights, 1);
    expect(mixed.reason, 'global_learning');
    final alone = NaturalWakeTuning.evaluate(
      history.take(7).toList(),
      userTrackId: 'reading',
    );
    expect(alone.applied, true);
    expect(alone.parameters.windowLeadMinutes, 1);
  });

  test(
    'learned wake offsets combine once with identity and either grouping',
    () {
      const identity = NaturalWakeParameters();
      final values = [
        for (final t in [-60, -15, 0, 15, 60])
          for (final w in [-10, -1, 0, 1, 10])
            NaturalWakeParameters(triggerRunOffsetSec: t, windowLeadMinutes: w),
      ];
      List<int> fields(NaturalWakeParameters p) => [
        p.triggerRunOffsetSec,
        p.windowLeadMinutes,
      ];
      for (final a in values) {
        expect(fields(a.combine(identity)), fields(a));
        expect(fields(a.combine(a)), fields(a));
        for (final b in values) {
          expect(fields(a.combine(b)), fields(b.combine(a)));
          for (final c in values) {
            expect(
              fields(a.combine(b).combine(c)),
              fields(a.combine(b.combine(c))),
            );
          }
        }
      }
    },
  );

  test(
    'user Natural wake learns independently and persists an explained step',
    () async {
      final db = await LocalDb.instance;
      const journal = DbWakeJournal();
      for (var i = 0; i < 7; i++) {
        final onset = DateTime(2026, 9, 1 + i * 7, 22);
        final wake = DateTime(2026, 9, 2 + i * 7, 7);
        final epoch = wake.millisecondsSinceEpoch ~/ 1000;
        await log('reading', onset.subtract(const Duration(hours: 1)));
        await db.insert('day_result', {
          'day_id': dayLabelOf(wake),
          'algo_version': 118,
          'computed_at': 1,
          'finalized': 1,
          'window_json': jsonEncode({
            'onset_ms': onset.millisecondsSinceEpoch,
            'offset_ms': wake.millisecondsSinceEpoch,
          }),
          'payload_json': jsonEncode({
            'scalars': {'readiness': 80},
            'sleep': {
              'accounting': {
                'value': {'tst_sec': 28800},
              },
            },
          }),
        });
        await db.insert('wake_trace', {
          'wake_epoch': epoch,
          'at_ms': (epoch - 60) * 1000,
          'kind': 'natural',
          'data_json': '{"reason":"fire"}',
        });
        await db.insert('wake_trace', {
          'wake_epoch': epoch,
          'at_ms': epoch * 1000,
          'kind': 'ack',
          'data_json': jsonEncode({
            'dreamAnswer': 'dream',
            'wakePath': 'natural',
            'dreamAnsweredAtMs': epoch * 1000,
          }),
        });
        await journal.tuneFor(epoch);
      }
      await LocalDb.close();
      final meta = await (await LocalDb.instance).query(
        'wake_meta',
        where: 'key = ?',
        whereArgs: ['natural_wake_user_reading'],
      );
      expect(meta, hasLength(1));
      final values = jsonDecode(meta.single['value'] as String) as Map;
      expect(values['windowLeadMinutes'], 1);
      final learned = await journal.parametersForProfile(
        const ConfounderProfile(userTrackIds: {'reading'}),
      );
      expect(learned.windowLeadMinutes, 1);
      expect(learned.triggerRunOffsetSec, -15);
      final overlap = await journal.parametersForProfile(
        const ConfounderProfile(userTrackIds: {'reading', 'tea ritual'}),
      );
      expect(overlap.windowLeadMinutes, 0);
      expect(overlap.triggerRunOffsetSec, 0);
      final other = await (await LocalDb.instance).query(
        'wake_meta',
        where: 'key = ?',
        whereArgs: ['natural_wake_user_tea%20ritual'],
      );
      expect(other, isEmpty);
    },
  );
  test(
    'medication owner metadata reaches the wake worker and cache revision',
    () async {
      final db = await LocalDb.instance;
      final bed = DateTime(2026, 9, 1, 22);
      await db.insert('med_def', {
        'key': 'test',
        'label': 'Medication',
        'dose_unit': 'mg',
        'active': 1,
        'created_at': 1,
      });
      await store.confirmNone('med:test', '2026-09-02');
      expect(
        await db.query(
          'track_absence',
          where: 'track_id = ?',
          whereArgs: ['med:test'],
        ),
        [
          {'track_id': 'med:test', 'date': '2026-09-02'},
        ],
      );
      await store.saveDefinition(
        const TrackDefinition(
          id: 'med:test',
          name: 'Medication',
          icon: 'pill',
          kind: 'consumed',
          unit: 'mg',
          roles: ['own_sleep'],
          systems: ['sleep'],
        ),
      );
      final raw =
          jsonDecode(
                (await db.query(
                      'track_definition',
                      where: 'id = ?',
                      whereArgs: ['med:test'],
                    )).single['payload_json']
                    as String,
              )
              as Map;
      expect(raw.containsKey('name'), false);
      await db.insert('med_dose', {
        'med_key': 'test',
        'date': '2026-09-01',
        'slot_min': 1260,
        'taken_ts':
            bed.subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/
            1000,
        'dose_value': 5,
        'updated_at': 1,
      });
      final first = await profile(bed);
      expect(first.userTrackIds, {'med:test'});
      // Observed context only until learned parameters exist (S12).
      expect(first.adjustedFor, isEmpty);
      await db.insert('wake_meta', {
        'key': 'natural_wake_user_med%3Atest',
        'value': jsonEncode({
          'triggerRunOffsetSec': -15,
          'windowLeadMinutes': 1,
        }),
      });
      expect((await profile(bed)).adjustedFor, {'Medication 1 h before bed'});
      const source = DbWakeNightSource();
      final from = DateTime(2026, 9, 1), to = DateTime(2026, 9, 2);
      final before = await source.revision(from, to);
      await db.update(
        'med_def',
        {'label': 'Renamed'},
        where: 'key = ?',
        whereArgs: ['test'],
      );
      expect(await source.revision(from, to), isNot(before));
      expect((await profile(bed)).adjustedFor, {'Renamed 1 h before bed'});
    },
  );
}
