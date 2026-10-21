// User data and ledgers that sit in an export must come back through import,
// and every table in the schema must be classified as restored or not (with a
// reason), so a new table cannot silently fall out of export -> import.
//
// Carried:     wake_confirmation (a night the wearer confirmed), wake_meta
//              (snooze settings, the Smart Wake upgrade acknowledgement),
//              wake_evidence, sync_ledger, band_backlog, notif_slots,
//              sleep_session_candidates (the only copy of a night once its
//              raw is pruned).
// Not carried: see kTablesNotRestored, each with its reason.
//
// Assumed API: kTablesNotRestored (Map<String, String>) in
// lib/data/restore_classification.dart, beside LocalDb.restoreTablesForTest.
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/restore_classification.dart';

import 'backup_support.dart';

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_wake_ledger_tables.db'));
  tearDownAll(() async => env.dispose());

  test('every table in the schema is restored or classified with a reason',
      () async {
    await env.wipe();
    final db = await LocalDb.instance;
    final tables = {
      for (final r in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'"))
        r['name'] as String,
    };
    final restored = LocalDb.restoreTablesForTest.toSet();
    final unclassified = tables
        .where((t) => !restored.contains(t) && !kTablesNotRestored.containsKey(t))
        .toList()
      ..sort();
    expect(unclassified, isEmpty,
        reason: 'add to LocalDb._restoreTables or to kTablesNotRestored '
            '(lib/data/restore_classification.dart) with a reason');
    expect(kTablesNotRestored.keys.where(restored.contains), isEmpty,
        reason: 'a table cannot be both restored and not restored');
    // Present only on an upgraded database (raw_records) or on an export copy
    // (the backup_* tables), so a fresh live schema does not show them.
    const notInFreshSchema = {'raw_records', 'backup_prefs', 'backup_files'};
    expect(
        kTablesNotRestored.keys
            .where((t) => !tables.contains(t) && !notInFreshSchema.contains(t)),
        isEmpty,
        reason: 'stale entry: no such table in the schema');
    expect(kTablesNotRestored.values.where((r) => r.trim().isEmpty), isEmpty);
  });

  test('the wake and ledger tables are in the restore list', () {
    for (final t in const [
      'wake_confirmation', 'wake_meta', 'wake_evidence', 'sync_ledger',
      'band_backlog', 'notif_slots', 'sleep_session_candidates',
    ]) {
      expect(LocalDb.restoreTablesForTest, contains(t), reason: t);
    }
  });

  test('wake_confirmation and wake_meta round-trip through export and import',
      () async {
    await env.wipe();
    final db = await LocalDb.instance;
    await db.insert('wake_confirmation', {
      'day_id': '2026-09-21', 'at_sec': 1790000000, 'basis': 'user',
      'created_at': 1790000100,
    });
    await db.insert('wake_meta', {
      'key': 'snooze_settings', 'value': '{"enabled":true,"minutes":9}',
    });
    await db.insert('wake_meta',
        {'key': 'upgrade_explanation', 'value': 'acknowledged'});
    await db.insert('wake_meta', {'key': 'run_state', 'value': '{"x":1}'});
    await env.seedData();
    final path = await LocalDb.exportCopy();

    await env.wipe();
    await LocalDb.instance;
    await LocalDb.importFromDbFile(path);
    final after = await LocalDb.instance;
    expect(await after.query('wake_confirmation'), [
      {
        'day_id': '2026-09-21', 'at_sec': 1790000000, 'basis': 'user',
        'created_at': 1790000100,
      },
    ]);
    expect(await LocalDb.wakeMetaGet('snooze_settings'),
        '{"enabled":true,"minutes":9}');
    expect(await LocalDb.wakeMetaGet('upgrade_explanation'), 'acknowledged');
    expect(await LocalDb.wakeMetaGet('run_state'), isNull,
        reason: 'the orchestrator run state belongs to the old phone');
  });

  test('the ledgers round-trip through export and import',
      () async {
    await env.wipe();
    final db = await LocalDb.instance;
    await db.insert('wake_evidence', {
      'onset_sec': 1789990000, 'kind': 'motion', 'at_sec': 1790000000,
      'created_at': 1790000001,
    });
    await db.insert('sync_ledger', {
      'chunk_id': 'c1', 'kind': 'history', 'status': 'acked',
      'created_at': 1, 'updated_at': 2, 'acked_at': 2, 'last_error': null,
      'meta_json': '{}',
    });
    await db.insert('band_backlog', {
      'device_id': '', 'ts': 1790000000, 'written': 5, 'used': 4,
      'capacity': 9, 'trim_page': 1, 'wrap_count': 0, 'free_records': 3,
      'device_family': 'gen4',
    });
    await db.insert('notif_slots',
        {'category': 'readiness', 'dedupe_key': 'k1', 'slot': 7});
    await db.insert('sleep_session_candidates', {
      'day_id': '2026-09-21', 'algo_version': 100,
      'payload_json': '{"a":1}', 'computed_at': 5,
    });
    await env.seedData();
    Future<Map<String, List<Map<String, Object?>>>> dump() async => {
          for (final t in const [
            'wake_evidence', 'sync_ledger', 'band_backlog', 'notif_slots',
            'sleep_session_candidates',
          ])
            t: await (await LocalDb.instance).query(t),
        };
    final before = await dump();
    final path = await LocalDb.exportCopy();

    await env.wipe();
    await LocalDb.instance;
    await LocalDb.importFromDbFile(path);
    expect(await dump(), before);
  });
}
