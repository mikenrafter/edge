// Tables the user fills in by hand (or whose rows guard something the user
// already saw) must survive a full export -> import. They were missing from
// LocalDb's restore list.
//
// Carried:   alarm_schedule (the weekly alarm), symptom_entry, moment_label
//            (answers the wearer typed), assumed_water (the ledger behind a
//            journal water_ml total that IS restored), notif_fired (fire-once
//            guard: without it old alerts fire again on the new phone).
// Not carried: session_score_mask (rewritten from sessions on every derive).
//
// RED: none of them is in the restore list, so none comes back.
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';

import 'backup_support.dart';

const _tables = [
  'alarm_schedule',
  'symptom_entry',
  'moment_label',
  'assumed_water',
  'notif_fired',
];

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_user_tables_test.db'));
  tearDownAll(() async => env.dispose());

  Future<void> seedUserRows() async {
    final db = await LocalDb.instance;
    await db.insert('alarm_schedule', {
      'weekday': 2, 'hour': 6, 'minute': 45, 'enabled': 1,
      'smart_window_minutes': 20, 'natural_window_minutes': 15,
      'gradual_window_minutes': 10, 'gradual_pattern': 'pulse',
      'gradual_cadence_sec': 120,
    });
    await db.insert('symptom_entry', {
      'date': '2026-09-21', 'hhmm': '08:15', 'severity': 'mild',
      'side': 'left', 'kind': 'ache', 'kind_other': null, 'area': 'head',
      'area_other': null, 'note': 'after run', 'created_at': 1790000100,
    });
    await db.insert('moment_label', {
      'date': '2026-09-21', 'hhmm': '09:00', 'label': 'coffee',
      'note': 'x', 'answered_at': 1790000200,
    });
    await db.insert('assumed_water', {
      'date': '2026-09-21', 'at_min': 600, 'ml': 250.0, 'state': 'assumed',
      'logged_at': 1790000300,
    });
    await db.insert('notif_fired',
        {'key': '2026-09-21:low_read', 'fired_at': 1790000400});
  }

  Future<Map<String, List<Map<String, Object?>>>> dumpUser() async {
    final db = await LocalDb.instance;
    return {
      for (final t in _tables)
        t: await db.query(t, orderBy: 'rowid'),
    };
  }

  test('every hand-entered table is in the restore list', () {
    for (final t in _tables) {
      expect(LocalDb.restoreTablesForTest, contains(t), reason: t);
    }
    expect(LocalDb.restoreTablesForTest, isNot(contains('session_score_mask')));
  });

  test('each table round-trips through export and import', () async {
    await env.wipe();
    await seedUserRows();
    await env.seedData();
    final before = await dumpUser();
    final path = await LocalDb.exportCopy();

    await env.wipe();
    await LocalDb.instance;
    await LocalDb.importFromDbFile(path);
    expect(await dumpUser(), before);
  });

  test('importing twice converges', () async {
    await env.wipe();
    await seedUserRows();
    await env.seedData();
    final before = await dumpUser();
    final path = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.importFromDbFile(path);
    await LocalDb.importFromDbFile(path);
    expect(await dumpUser(), before);
  });

  test('an alert that already fired does not fire again after import',
      () async {
    await env.wipe();
    await seedUserRows();
    await env.seedData();
    final path = await LocalDb.exportCopy();

    await env.wipe();
    await LocalDb.importFromDbFile(path);
    expect(await LocalDb.claimNotifFired('2026-09-21:low_read'), isFalse,
        reason: 'already fired on the old phone');
    expect(await LocalDb.claimNotifFired('2026-09-21:other'), isTrue,
        reason: 'a key the backup never saw still fires once');
  });

  test('a moment answered on this device keeps its answer', () async {
    await env.wipe();
    await seedUserRows();
    await env.seedData();
    final path = await LocalDb.exportCopy();

    await env.wipe();
    final db = await LocalDb.instance;
    await db.insert('moment_label', {
      'date': '2026-09-21', 'hhmm': '09:00', 'label': 'tea',
      'note': null, 'answered_at': 1790009999,
    });
    await LocalDb.importFromDbFile(path);
    final rows = await db.query('moment_label');
    expect(rows, hasLength(1));
    expect(rows.single['label'], 'tea', reason: 'a moment is answered once');
    // ...and the other tables still arrived.
    expect(await db.query('symptom_entry'), hasLength(1));
  });
}
