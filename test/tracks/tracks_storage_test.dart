import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';

import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async => env = await BackupEnv.create('tracks_storage_t1.db'));
  tearDown(() async => env.dispose());

  test('fresh install seeds editable evidence-based presets, cycle disabled', () async {
    final db = await LocalDb.instance;
    final rows = await db.query('track_definition');
    final byId = {for (final r in rows) r['id']: jsonDecode(r['payload_json'] as String) as Map};
    expect(byId.keys.toSet(), containsAll(const {
      'caffeine', 'alcohol', 'cannabis', 'nicotine', 'late_meal', 'late_workout',
      'sauna', 'cold', 'naps', 'travel', 'illness', 'sleep_aids', 'meditation',
      'fluids', 'late_screens', 'menstrual_cycle',
    }));
    final caffeine = byId['caffeine']!;
    expect(caffeine['kinetics']['half_life_hours'], {'value': 5, 'locked': false});
    expect(caffeine['kinetics']['tolerance_days']['value'], inInclusiveRange(1, 4));
    expect(caffeine['kinetics']['withdrawal_days']['value'], 9);
    expect(caffeine['detection_min'], 0);
    expect(caffeine['detection_max'], 10);
    expect((caffeine['sub_activities'] as List).map((e) => e['id']).toSet(),
        {'coffee', 'tea', 'pill'});
    expect(byId['menstrual_cycle']!['enabled'], false);
    expect(caffeine['sources'], isNotEmpty);
    // Presets are starting values: a user edit survives the open-time repair.
    caffeine['name'] = 'My tea';
    caffeine['detection_max'] = 2;
    await db.update('track_definition', {'payload_json': jsonEncode(caffeine)},
        where: 'id = ?', whereArgs: ['caffeine']);
    await LocalDb.close();
    final reopened = await LocalDb.instance;
    final edited = jsonDecode((await reopened.query('track_definition',
        where: 'id = ?', whereArgs: ['caffeine'])).single['payload_json'] as String);
    expect(edited['name'], 'My tea');
    expect(edited['detection_max'], 2);
  });

  test('definitions, setup history and nullable timed logs survive backup import', () async {
    final db = await LocalDb.instance;
    final payload = jsonEncode({
      'id': 'custom', 'name': 'Reading', 'icon': 'book', 'kind': 'activity',
      'unit': 'minutes', 'systems': ['sleep', 'future_system'],
      'kinetics': {'half_life_hours': {'value': 2.5, 'locked': true}},
      'sub_activities': [{'id': 'paper', 'name': 'Paper', 'kinetics': {}}],
      'roles': ['own_sleep', 'exclude_baselines'],
      'detection_min': 1, 'detection_max': 3, 'no_unadjusted_data': true,
    });
    await db.insert('track_definition', {'id': 'custom', 'payload_json': payload});
    await db.insert('track_setup_history', {
      'id': 'history-yes', 'track_id': 'custom', 'start_date': '2026-09-01',
      'end_date': '2026-09-30', 'done': 1,
    });
    await db.insert('track_setup_history', {
      'id': 'history-no', 'track_id': 'custom', 'start_date': '2026-10-01',
      'end_date': '2026-10-05', 'done': 0,
    });
    await db.insert('track_event', {
      'id': 'log1', 'track_id': 'custom', 'date': '2026-10-26',
      'at_ms': 1793030400000, 'amount': null, 'sub_activity_id': 'paper',
      'source_kind': 'manual', 'source_id': 'log1',
    });
    await env.seedData();
    final backup = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.instance;
    await LocalDb.importFromDbFile(backup);
    final after = await LocalDb.instance;
    expect((await after.query('track_definition', where: 'id = ?',
        whereArgs: ['custom'])).single['payload_json'], payload);
    expect(await after.query('track_setup_history', where: 'track_id = ?',
        whereArgs: ['custom'], orderBy: 'start_date'), [
      {'id': 'history-yes', 'track_id': 'custom', 'start_date': '2026-09-01',
        'end_date': '2026-09-30', 'done': 1},
      {'id': 'history-no', 'track_id': 'custom', 'start_date': '2026-10-01',
        'end_date': '2026-10-05', 'done': 0},
    ]);
    final event = (await after.query('track_event', where: 'id = ?', whereArgs: ['log1'])).single;
    expect(event['amount'], isNull, reason: 'unknown amount must not become zero');
    expect(event['at_ms'], 1793030400000);
    expect(event['sub_activity_id'], 'paper');
    for (final table in ['track_definition', 'track_event', 'track_setup_history']) {
      expect(LocalDb.restoreTablesForTest, contains(table));
    }
  });

  test('one source record cannot acquire duplicate track events', () async {
    final db = await LocalDb.instance;
    final row = {
      'id': 'first', 'track_id': 'caffeine', 'date': '2026-10-26',
      'at_ms': null, 'amount': 80, 'sub_activity_id': null,
      'source_kind': 'manual', 'source_id': 'same-record',
    };
    await db.insert('track_event', row);
    await expectLater(db.insert('track_event', {...row, 'id': 'duplicate'}), throwsA(anything));
    expect(await db.query('track_event', where: 'source_id = ?',
        whereArgs: ['same-record']), hasLength(1));
  });
}
