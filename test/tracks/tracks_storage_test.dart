import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';

import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async => env = await BackupEnv.create('tracks_storage_t1.db'));
  tearDown(() async => env.dispose());

  test(
    'fresh install seeds editable evidence-based presets, cycle disabled',
    () async {
      final db = await LocalDb.instance;
      final rows = await db.query('track_definition');
      final byId = {
        for (final r in rows)
          r['id']: jsonDecode(r['payload_json'] as String) as Map,
      };
      expect(
        byId.keys.toSet(),
        containsAll(const {
          'caffeine',
          'alcohol',
          'cannabis',
          'nicotine',
          'late_meal',
          'late_workout',
          'sauna',
          'cold',
          'naps',
          'travel',
          'illness',
          'sleep_aids',
          'meditation',
          'fluids',
          'late_screens',
          'menstrual_cycle',
        }),
      );
      final caffeine = byId['caffeine']!;
      expect(caffeine['kinetics']['half_life_hours'], {
        'value': 5,
        'locked': false,
      });
      expect(
        caffeine['kinetics']['tolerance_days']['value'],
        inInclusiveRange(1, 4),
      );
      expect(caffeine['kinetics']['withdrawal_days']['value'], 9);
      expect(caffeine['detection_min'], 0);
      expect(caffeine['detection_max'], 10);
      expect((caffeine['sub_activities'] as List).map((e) => e['id']).toSet(), {
        'coffee',
        'tea',
        'pill',
      });
      expect(byId['menstrual_cycle']!['enabled'], false);
      expect(caffeine['sources'], isNotEmpty);
      // Presets are starting values: a user edit survives the open-time repair.
      caffeine['name'] = 'My tea';
      caffeine['detection_max'] = 2;
      await db.update(
        'track_definition',
        {'payload_json': jsonEncode(caffeine)},
        where: 'id = ?',
        whereArgs: ['caffeine'],
      );
      await LocalDb.close();
      final reopened = await LocalDb.instance;
      final edited = jsonDecode(
        (await reopened.query(
              'track_definition',
              where: 'id = ?',
              whereArgs: ['caffeine'],
            )).single['payload_json']
            as String,
      );
      expect(edited['name'], 'My tea');
      expect(edited['detection_max'], 2);
    },
  );

  test(
    'definitions, setup history and nullable timed logs survive backup import',
    () async {
      final db = await LocalDb.instance;
      final payload = jsonEncode({
        'id': 'custom',
        'name': 'Reading',
        'icon': 'book',
        'kind': 'activity',
        'unit': 'minutes',
        'systems': ['sleep', 'future_system'],
        'kinetics': {
          'half_life_hours': {'value': 2.5, 'locked': true},
        },
        'sub_activities': [
          {'id': 'paper', 'name': 'Paper', 'kinetics': {}},
        ],
        'roles': ['own_sleep', 'exclude_baselines'],
        'detection_min': 1,
        'detection_max': 3,
        'no_unadjusted_data': true,
      });
      await db.insert('track_definition', {
        'id': 'custom',
        'payload_json': payload,
      });
      await db.insert('track_setup_history', {
        'id': 'history-yes',
        'track_id': 'custom',
        'start_date': '2026-09-01',
        'end_date': '2026-09-30',
        'done': 1,
      });
      await db.insert('track_setup_history', {
        'id': 'history-no',
        'track_id': 'custom',
        'start_date': '2026-10-01',
        'end_date': '2026-10-05',
        'done': 0,
      });
      await db.insert('track_event', {
        'id': 'log1',
        'track_id': 'custom',
        'date': '2026-10-26',
        'at_ms': 1793030400000,
        'amount': null,
        'sub_activity_id': 'paper',
        'source_kind': 'manual',
        'source_id': 'log1',
      });
      await env.seedData();
      final backup = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(backup);
      final after = await LocalDb.instance;
      expect(
        (await after.query(
          'track_definition',
          where: 'id = ?',
          whereArgs: ['custom'],
        )).single['payload_json'],
        payload,
      );
      expect(
        await after.query(
          'track_setup_history',
          where: 'track_id = ?',
          whereArgs: ['custom'],
          orderBy: 'start_date',
        ),
        [
          {
            'id': 'history-yes',
            'track_id': 'custom',
            'start_date': '2026-09-01',
            'end_date': '2026-09-30',
            'done': 1,
          },
          {
            'id': 'history-no',
            'track_id': 'custom',
            'start_date': '2026-10-01',
            'end_date': '2026-10-05',
            'done': 0,
          },
        ],
      );
      final event = (await after.query(
        'track_event',
        where: 'id = ?',
        whereArgs: ['log1'],
      )).single;
      expect(
        event['amount'],
        isNull,
        reason: 'unknown amount must not become zero',
      );
      expect(event['at_ms'], 1793030400000);
      expect(event['sub_activity_id'], 'paper');
      for (final table in [
        'track_definition',
        'track_event',
        'track_setup_history',
      ]) {
        expect(LocalDb.restoreTablesForTest, contains(table));
      }
    },
  );

  test('one source record cannot acquire duplicate track events', () async {
    final db = await LocalDb.instance;
    final row = {
      'id': 'first',
      'track_id': 'caffeine',
      'date': '2026-10-26',
      'at_ms': null,
      'amount': 80,
      'sub_activity_id': null,
      'source_kind': 'manual',
      'source_id': 'same-record',
    };
    await db.insert('track_event', row);
    await expectLater(
      db.insert('track_event', {...row, 'id': 'duplicate'}),
      throwsA(anything),
    );
    expect(
      await db.query(
        'track_event',
        where: 'source_id = ?',
        whereArgs: ['same-record'],
      ),
      hasLength(1),
    );
  });

  // WHY S9: a selected-day export omitted track rows, so restoring it lost the
  // custom track and turned timed substance doses into untimed remainders.
  // proves: export/import parity for the selected day's track rows.
  test('selected-day export carries track rows, definitions and history', () async {
    final db = await LocalDb.instance;
    await db.insert('track_definition', {
      'id': 'custom',
      'payload_json': jsonEncode({'id': 'custom', 'name': 'Reading', 'kind': 'activity'}),
    });
    for (final (id, start, end) in [
      ('h-in', '2026-10-20', '2026-10-27'),
      ('h-out', '2026-08-01', '2026-08-05'),
    ]) {
      await db.insert('track_setup_history', {
        'id': id,
        'track_id': 'custom',
        'start_date': start,
        'end_date': end,
        'done': 1,
      });
    }
    for (final (id, date) in [('in', '2026-10-26'), ('out', '2026-10-01')]) {
      await db.insert('track_event', {
        'id': id,
        'track_id': 'custom',
        'date': date,
        'at_ms': 1793030400000,
        'source_kind': 'manual',
        'source_id': id,
      });
    }
    await db.insert('track_absence', {'track_id': 'custom', 'date': '2026-10-26'});
    await db.insert('track_absence', {'track_id': 'custom', 'date': '2026-10-01'});
    await env.seedData();
    final days = await LocalDb.exportDaysDb({'2026-10-26'});
    await env.wipe();
    await LocalDb.instance;
    await LocalDb.importFromDbFile(days);
    final after = await LocalDb.instance;
    expect(
      (await after.query('track_definition', where: "id = 'custom'")).length,
      1,
    );
    expect((await after.query('track_event')).map((r) => r['id']), ['in']);
    expect((await after.query('track_absence')).map((r) => r['date']), [
      '2026-10-26',
    ]);
    expect((await after.query('track_setup_history')).map((r) => r['id']), [
      'h-in',
    ]);
  });

  // WHY R2-7: the selected-day export copied only manual track rows; medication
  // doses (med_dose), caffeine moments (moment_label), meals (food_entry) and
  // the medication definitions stayed behind, so the restored track_event_feed
  // lost them. proves: feed parity before and after export, wipe and import.
  test('selected-day export restores the same track_event_feed', () async {
    final db = await LocalDb.instance;
    await MedDb.putDef(db, const MedDef(key: 'vit', label: 'Vitamin', doseUnit: 'IU'));
    await MedDb.logTrack(
      db,
      medKey: 'vit',
      date: '2026-10-26',
      explicitSlotMin: 8 * 60,
      atMs: 1793000000000,
      amount: 1000,
    );
    await LocalDb.putMomentLabel(
      const MomentLabel(
        date: '2026-10-26',
        hhmm: '09:30',
        label: 'caffeine',
        caffeineMg: 90,
        answeredAtMs: 1,
      ),
    );
    await NutritionDb.logTrack(
      db,
      id: 'meal1',
      date: '2026-10-26',
      atTs: 1793010000,
      quantity: 2,
      unit: 'bowls',
    );
    await env.seedData();
    Future<List<String>> feed(dynamic d) async => [
      for (final r in await d.query(
        'track_event_feed',
        where: "date = '2026-10-26' AND source_kind <> 'journal'",
        orderBy: 'id',
      ))
        jsonEncode(r),
    ];
    final before = await feed(db);
    expect(before.length, 3, reason: 'fixture must exercise three owners');
    final days = await LocalDb.exportDaysDb({'2026-10-26'});
    await env.wipe();
    await LocalDb.instance;
    await LocalDb.importFromDbFile(days);
    expect(await feed(await LocalDb.instance), before);
    expect((await MedDb.defs(await LocalDb.instance)).single.label, 'Vitamin');
  });
}
