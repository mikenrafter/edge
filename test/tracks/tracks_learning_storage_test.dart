import 'dart:convert';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'learning state, audit and explicit absences survive same-version reopen',
    () async {
      final env = await BackupEnv.create('tracks_learning_storage_t2.db');
      addTearDown(env.dispose);
      var db = await LocalDb.instance;
      await db.insert('track_learning', {
        'track_id': 'caffeine',
        'started_ms': 1,
        'state_json': '{}',
        'last_step_date': null,
      });
      await db.insert('track_learning_log', {
        'track_id': 'caffeine',
        'date': '2026-10-27',
        'field': 'half_life_hours',
        'before_value': 5,
        'after_value': 5.1,
        'reason': 'matched_observations',
      });
      await db.insert('track_absence', {
        'track_id': 'caffeine',
        'date': '2026-10-27',
      });
      await LocalDb.close();
      db = await LocalDb.instance;
      expect(await db.query('track_learning'), hasLength(1));
      expect((await db.query('track_learning_log')).single['after_value'], 5.1);
      expect(await db.query('track_absence'), hasLength(1));
      expect(LocalDb.schemaVersion, greaterThanOrEqualTo(83));
    },
  );
  test(
    'real refresh persists statistics once across concurrent replays',
    () async {
      final env = await BackupEnv.create('tracks_learning_refresh_t2.db');
      addTearDown(env.dispose);
      final db = await LocalDb.instance;
      final store = TracksStore(db);
      await store.saveDefinition(
        const TrackDefinition(
          id: 'custom',
          name: 'Custom',
          icon: 'track',
          kind: 'consumed',
          systems: ['hr'],
          loggingComplete: true,
          loggingCompleteSinceMs: 0,
          kinetics: TrackKinetics({
            'half_life_hours': TrackKineticField(value: 5),
            'onset_hours': TrackKineticField(value: 1),
            'tolerance_days': TrackKineticField(value: 2),
            'withdrawal_days': TrackKineticField(value: 9),
          }),
        ),
      );
      for (var i = 0; i < 3; i++) {
        final onset = DateTime.utc(2026, 5, 1 + i, 22);
        final day = '2026-05-0${i + 2}';
        await store.log(
          TrackEvent(
            id: 'event:$i',
            trackId: 'custom',
            date: '2026-05-0${i + 1}',
            atMs: onset
                .subtract(const Duration(hours: 2))
                .millisecondsSinceEpoch,
            amount: 10,
          ),
        );
        await db.insert('day_result', {
          'day_id': day,
          'algo_version': 118,
          'computed_at': 1,
          'finalized': 1,
          'partial': 0,
          'window_json': jsonEncode({
            'value': {
              'onset_ms': onset.millisecondsSinceEpoch,
              'offset_ms': onset
                  .add(const Duration(hours: 8))
                  .millisecondsSinceEpoch,
            },
          }),
          'payload_json': jsonEncode({
            'scalars': {'rhr': 58 + i * 2},
          }),
        });
      }
      final now = DateTime.utc(2026, 10, 27, 12);
      await Future.wait([
        store.refreshLearning(asOf: now),
        store.refreshLearning(asOf: now),
      ]);
      final firstLogs = await db.query(
        'track_learning_log',
        where: 'track_id = ?',
        whereArgs: ['custom'],
      );
      expect(firstLogs, hasLength(4));
      final state =
          jsonDecode(
                (await db.query(
                      'track_learning',
                      where: 'track_id = ?',
                      whereArgs: ['custom'],
                    )).single['state_json']
                    as String,
              )
              as Map;
      expect((state['statistics'] as Map)['hr'], {
        'count': 3,
        'mean': 60.0,
        'm2': 8.0,
      });
      await store.refreshLearning(asOf: now);
      expect(
        await db.query(
          'track_learning_log',
          where: 'track_id = ?',
          whereArgs: ['custom'],
        ),
        firstLogs,
      );
      final definition = (await store.definitions()).firstWhere(
        (d) => d.id == 'custom',
      );
      expect(definition.kinetics.fields['half_life_hours']!.value, 5);
      await store.confirmNone('custom', '2026-10-27');
      await expectLater(
        store.confirmNone('custom', '2026-05-01'),
        throwsStateError,
      );
    },
  );
  test(
    'cross-day orchestration refreshes learning without opening the hub',
    () async {
      final env = await BackupEnv.create('tracks_learning_auto_t2.db');
      addTearDown(env.dispose);
      final db = await LocalDb.instance;
      await TracksStore(db).saveDefinition(
        const TrackDefinition(
          id: 'custom',
          name: 'Custom',
          icon: 'track',
          kind: 'activity',
          systems: ['sleep'],
        ),
      );
      expect(
        await db.query(
          'track_learning',
          where: 'track_id = ?',
          whereArgs: ['custom'],
        ),
        isEmpty,
      );
      await DerivationEngine().runCrossDayForTest(const Profile());
      final rows = await db.query(
        'track_learning',
        where: 'track_id = ?',
        whereArgs: ['custom'],
      );
      expect(rows, hasLength(1));
      final state = jsonDecode(rows.single['state_json'] as String) as Map;
      expect(
        (state['effects'] as List).single['reason'],
        'missing_system_data',
      );
    },
  );

  // WHY S10: audit rows entered the generic REPLACE merge by AUTOINCREMENT id,
  // so an unrelated backup row with id 1 overwrote the local entry.
  // proves: CLAIM(audit-identity)
  test('restoring a backup merges audit rows by identity, not by local id', () async {
    final env = await BackupEnv.create('tracks_learning_audit_s10.db');
    addTearDown(env.dispose);
    Map<String, Object?> entry(String field, num after) => {
      'track_id': 'caffeine',
      'date': '2026-10-27',
      'field': field,
      'before_value': 5,
      'after_value': after,
      'reason': 'matched_observations',
    };
    var db = await LocalDb.instance;
    await db.insert('track_learning_log', entry('half_life_hours', 5.1));
    await env.seedData();
    final backup = await LocalDb.exportCopy();
    await env.wipe();
    db = await LocalDb.instance;
    // A different local entry now owns id 1.
    await db.insert('track_learning_log', entry('onset_hours', 1));
    expect((await db.query('track_learning_log')).single['id'], 1);
    await LocalDb.importFromDbFile(backup);
    await LocalDb.importFromDbFile(backup); // repeat import adds nothing
    final fields = (await (await LocalDb.instance).query(
      'track_learning_log',
      orderBy: 'field',
    )).map((r) => r['field']);
    expect(fields, ['half_life_hours', 'onset_hours']);
  });

  // WHY R3-3: the habitual reference was re-derived from whatever nights the
  // refresh read (latest 730), so it could drift after rollover. The refresh
  // must persist it in track_learning.state_json once established, and keep it
  // when the established nights are gone from the read window.
  // proves: CLAIM(baseline-reference) through the production read seam
  test('refresh persists the established baseline reference and keeps it after rollover', () async {
    final env = await BackupEnv.create('tracks_learning_reference_r33.db');
    addTearDown(env.dispose);
    final db = await LocalDb.instance;
    final store = TracksStore(db);
    await store.saveDefinition(
      const TrackDefinition(
        id: 'custom',
        name: 'Custom',
        icon: 'track',
        kind: 'consumed',
        systems: ['hr'],
        noUnadjustedData: true,
        loggingComplete: true,
        loggingCompleteSinceMs: 0,
        kinetics: TrackKinetics({
          'half_life_hours': TrackKineticField(value: 5),
          'onset_hours': TrackKineticField(value: 1),
        }),
      ),
    );
    Future<void> night(int i, double dose) async {
      final onset = DateTime.utc(2026, 5, 1 + i, 22);
      await store.log(
        TrackEvent(
          id: 'event:$i',
          trackId: 'custom',
          date: dayLabelOf(onset),
          atMs: onset.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
          amount: dose,
        ),
      );
      await db.insert('day_result', {
        'day_id': dayLabelOf(onset.add(const Duration(days: 1))),
        'algo_version': 118,
        'computed_at': 1,
        'finalized': 1,
        'partial': 0,
        'window_json': jsonEncode({
          'value': {
            'onset_ms': onset.millisecondsSinceEpoch,
            'offset_ms': onset.add(const Duration(hours: 8)).millisecondsSinceEpoch,
          },
        }),
        'payload_json': jsonEncode({
          'scalars': {'rhr': 58 + i % 5},
          'coverage': {'rr_coverage': 1},
        }),
      });
    }
    for (var i = 0; i < 30; i++) {
      await night(i, 100);
    }
    final now = DateTime.utc(2026, 10, 27, 12);
    await store.refreshLearning(asOf: now);
    Future<Map> state() async => jsonDecode(
      (await db.query('track_learning', where: "track_id = 'custom'"))
          .single['state_json'] as String,
    ) as Map;
    expect((await state())['reference_dose'], 100);
    // Rollover: the established nights leave the window, abstinence follows.
    await db.delete('day_result', where: "day_id < '2026-05-25'");
    for (var i = 30; i < 60; i++) {
      await night(i, 0);
    }
    await store.refreshLearning(asOf: now.add(const Duration(days: 1)));
    expect((await state())['reference_dose'], 100);
  });

  // WHY R4-4 / T3 R3-6: deleting any day cleared every track_learning row, so
  // an established baseline reference (unrecoverable after rollover) and a
  // wearer's experiment release were lost; the next refresh could re-establish
  // abstinence as the reference and reactivate an old experiment result.
  // proves: CLAIM(learning-keep)
  test('deleting an unrelated day keeps non-rebuildable learning state', () async {
    final env = await BackupEnv.create('tracks_learning_keep_r44.db');
    addTearDown(env.dispose);
    final db = await LocalDb.instance;
    await db.insert('track_learning', {
      'track_id': 'kept',
      'started_ms': 5,
      'state_json': jsonEncode({
        'reference_dose': 100,
        'experiment_released': {'hr': 'exp1'},
        'statistics': {'hr': {'count': 3}},
        'effects': [],
      }),
      'last_step_date': '2026-10-01',
    });
    await db.insert('track_learning', {
      'track_id': 'rebuildable',
      'started_ms': 5,
      'state_json': jsonEncode({'statistics': {'hr': {'count': 3}}}),
      'last_step_date': '2026-10-01',
    });
    await LocalDb.deleteDays({'2020-01-01'});
    final rows = await db.query('track_learning');
    expect(rows.map((r) => r['track_id']), ['kept']);
    expect(jsonDecode(rows.single['state_json'] as String), {
      'reference_dose': 100,
      'experiment_released': {'hr': 'exp1'},
    });
    expect(rows.single['last_step_date'], isNull);
  });
}
