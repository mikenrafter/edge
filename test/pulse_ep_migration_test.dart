// Pulse structural phase 2: schema rung 95, the exact upgrade boundary and the
// admission hook, through the real LocalDb ladder and the real sync commit.
// CLAIM(pulse-upgrade-membership) CLAIM(pulse-admission-bound)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart' show TimeAnchor;
import 'package:openstrap_edge/ble/adapters/adapter.dart' show NeutralSample;
import 'package:openstrap_edge/data/db.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'backup/backup_support.dart';
import 'pulse_ep_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('pulse-ep-migration.db'));
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    SharedPreferences.setMockInitialValues({});
  });

  // Reopens the same file as an install that never ran rung 95: the Pulse
  // tables are gone and user_version names the previous rung.
  Future<Database> reopenAt(int version) async {
    final db = await LocalDb.instance;
    for (final t in kPulseEpTables.reversed) {
      await db.execute('DROP TABLE IF EXISTS $t');
    }
    await db.setVersion(version);
    await LocalDb.close();
    return LocalDb.instance;
  }

  // WHY: a fresh install must come up with the whole structural storage; a
  // build that only creates tables on upgrade leaves new installs without them.
  test('a fresh install is at schema 95 with every pulse_ep table and a marker', () async {
    final db = await LocalDb.instance;
    expect(await db.getVersion(), 95);
    expect(await pulseEpTablesPresent(db), kPulseEpTables.toSet());
    expect(await pulseRows(db, 'pulse_ep_upgrade'), hasLength(1));
    expect(await pulseRows(db, 'pulse_ep_upgrade_record'), isEmpty);
  });

  // WHY/CLAIM(pulse-upgrade-membership): the upgrade snapshots the exact
  // (device, record) keys present, inside the migration, before any sync can add
  // a key. A timestamp cutoff would call a late older record "before".
  test('92 -> 95 snapshots exactly the stored record keys', () async {
    final first = await LocalDb.instance;
    await seedRr(first, '', 1000, 3);
    await seedRr(first, '', 1001, 1);
    await seedRr(first, 'chest-1', 1000, 2);
    final db = await reopenAt(92);
    expect(await db.getVersion(), 95);
    final keys = await pulseRows(db, 'pulse_ep_upgrade_record',
        orderBy: 'source, ts_ms');
    expect([for (final k in keys) '${k['source']}|${k['ts_ms']}'],
        ['|1000000', '|1001000', 'chest-1|1000000']);
    expect(await pulseRows(db, 'pulse_ep_upgrade'), hasLength(1));
  });

  // WHY: Sleep lands rungs 93 and 94 first; Pulse's rung must still run for a
  // database that stands at 94.
  test('94 -> 95 also runs the Pulse rung', () async {
    final db = await reopenAt(94);
    expect(await db.getVersion(), 95);
    expect(await pulseEpTablesPresent(db), kPulseEpTables.toSet());
    expect(await pulseRows(db, 'pulse_ep_upgrade'), hasLength(1));
  });

  // WHY: an older record that arrives after the upgrade is NEW even though its
  // timestamp precedes the newest pre-upgrade record; a cutoff would swallow it.
  test('an older missing record committed after the upgrade is novel; a stored one is not', () async {
    final first = await LocalDb.instance;
    await seedRr(first, '', 2000, 2);
    final db = await reopenAt(92);
    final old = pulseRecord(1500, [800, 820]); // older than 2000, key absent
    final held = pulseRecord(2000, [800, 810]); // key present at upgrade
    await commitRecords([old, held]);
    final rows = await pulseRows(db, 'pulse_ep_admission');
    expect(rows, hasLength(1));
    expect(rows.single['source'], '');
    expect(rows.single['records'], 2);
    expect(rows.single['novel'], 1);
    expect(rows.single['start_ms'], 1500000);
    expect(rows.single['end_ms'], 2001000);
    expect(rows.single['origin'], 'recentSync');
  });

  // WHY: an empty install never recaptures: capture runs once, at the rung.
  test('syncing after the upgrade and reopening leaves the membership alone', () async {
    final db = await LocalDb.instance;
    await commitRecords([pulseRecord(3000, [800, 810])]);
    expect(await pulseRows(db, 'pulse_ep_upgrade_record'), isEmpty);
    await LocalDb.close();
    final again = await LocalDb.instance;
    expect(await pulseRows(again, 'pulse_ep_upgrade_record'), isEmpty);
    expect(await pulseRows(again, 'pulse_ep_upgrade'), hasLength(1));
  });

  // WHY: a replay of the same range must neither grow the table nor look new.
  test('replaying a committed range adds no admission row and no novelty', () async {
    final db = await LocalDb.instance;
    final recs = [pulseRecord(4000, [800, 810]), pulseRecord(4001, [790])];
    await commitRecords(recs);
    await commitRecords(recs);
    final rows = await pulseRows(db, 'pulse_ep_admission');
    expect(rows, hasLength(1));
    expect(rows.single['novel'], 2);
  });

  // WHY/CLAIM(pulse-admission-bound): a replacement carrying new beat values
  // for a stored key is not recent-sync authority.
  test('a replacement of a stored key is historical, not recent-sync', () async {
    final db = await LocalDb.instance;
    await commitRecords([pulseRecord(5000, [800, 810])]);
    await commitRecords([pulseRecord(5000, [801, 811])]);
    final rows = await pulseRows(db, 'pulse_ep_admission', orderBy: 'admitted_ms');
    expect(rows, hasLength(2));
    final replacement = rows.firstWhere((r) => r['novel'] == 0);
    expect(replacement['historical'], 1);
  });

  // WHY: bulk and import paths announce in one summary; the origin the commit
  // carries is stored, and nothing but a recent sync can be individual.
  test('a historical commit stores historical origin and status', () async {
    final db = await LocalDb.instance;
    await commitRecords([pulseRecord(6000, [800, 810])],
        origin: ProcessingOrigin.historical);
    final row = (await pulseRows(db, 'pulse_ep_admission')).single;
    expect(row['origin'], 'historical');
    expect(row['historical'], 1);
  });

  // WHY/CLAIM(pulse-evidence-atomic): the provenance row is part of the ACK
  // transaction. If it cannot be written the decoded rows must not commit, or
  // the band trims data whose provenance was lost.
  test('an admission write failure rolls back the decoded rows before the ACK', () async {
    final db = await LocalDb.instance;
    expect(await pulseEpTablesPresent(db), contains('pulse_ep_admission'));
    await db.execute('DROP TABLE pulse_ep_admission');
    await expectLater(
      commitRecords([pulseRecord(7000, [800, 810])]),
      throwsA(anything),
    );
    expect(await db.query('decoded_rr'), isEmpty);
    expect(await db.query('decoded_onehz'), isEmpty);
  });

  // WHY: records without beats carry nothing Pulse can read; no row, no bound.
  test('records without beats admit nothing', () async {
    final db = await LocalDb.instance;
    await commitRecords([pulseRecord(8000, const [])]);
    expect(await pulseRows(db, 'pulse_ep_admission'), isEmpty);
  });

  // WHY: every commit path, not only the sync drain, carries its provenance in
  // its own transaction; a path that skipped the hook would admit nothing.
  test('the live-insert path and a chest-strap commit are admitted too', () async {
    final db = await LocalDb.instance;
    final rec = pulseRecord(9000, [800, 810]);
    await LocalDb.insertRecordsBatch([rec.$1], [rec.$2],
        processingOrigin: ProcessingOrigin.historical);
    final strap = NeutralSample(
        anchor: TimeAnchor.arrival, tsEpoch: 9100, rrMs: const [790, 800, 810]);
    await LocalDb.commitSyncBatch(const [], const [],
        neutrals: [strap], deviceFamily: 'hrs', deviceId: 'chest-1');
    final rows = await pulseRows(db, 'pulse_ep_admission', orderBy: 'source');
    expect([for (final r in rows) '${r['source']}|${r['start_ms']}|${r['records']}'],
        ['|9000000|1', 'chest-1|9100000|1']);
  });

  // WHY/CLAIM(pulse-admission-bound): the batches go with decoded retention,
  // through the existing prune owner, not a parallel timer.
  test('the decoded prune removes admission batches older than its cutoff', () async {
    final db = await LocalDb.instance;
    await commitRecords([pulseRecord(10000, [800, 810])]);
    await commitRecords([pulseRecord(900000, [800, 810])]);
    expect(await pulseRows(db, 'pulse_ep_admission'), hasLength(2));
    await LocalDb.pruneDecodedBeforeRecTs(500000, hardFloorSec: 400000);
    final left = await pulseRows(db, 'pulse_ep_admission');
    expect([for (final r in left) r['start_ms']], [900000000]);
  });
  // WHY/R2: a rollout membership failure must preserve the live file, rather
  // than replacing it via the general quarantine/salvage recovery path.
  // catches: treating a failed capture as an ordinary unopenable database.
  test('R2 capture failure escapes LocalDb.instance without rebuilding', () async {
    final db = await LocalDb.instance;
    final path = db.path;
    final beforeRebuild = LocalDb.lastRebuild;
    final quarantines = Directory(env.dbDir).listSync()
        .where((f) => f.path.contains('${LocalDb.dbName}.unopenable-'))
        .map((f) => f.path).toSet();
    for (final t in kPulseEpTables.reversed) {
      await db.execute('DROP TABLE IF EXISTS $t');
    }
    await db.execute('DROP TABLE decoded_rr');
    await db.execute('CREATE TABLE decoded_rr (sentinel TEXT)');
    await db.insert('decoded_rr', {'sentinel': 'original unreadable history'});
    await db.setVersion(92);
    await LocalDb.close();
    await expectLater(LocalDb.instance, throwsA(anything));
    expect(LocalDb.lastRebuild, beforeRebuild);
    final raw = await openDatabase(path, singleInstance: false);
    try {
      expect(await raw.getVersion(), 92);
      expect(await raw.query('decoded_rr'), [
        {'sentinel': 'original unreadable history'},
      ]);
      expect(await pulseEpTablesPresent(raw), isEmpty);
      expect(Directory(env.dbDir).listSync().where((f) =>
          f.path.contains('${LocalDb.dbName}.unopenable-'))
          .map((f) => f.path).toSet(), quarantines);
    } finally {
      await raw.close();
    }
  });

}
