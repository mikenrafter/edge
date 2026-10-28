import 'dart:convert';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
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
}
