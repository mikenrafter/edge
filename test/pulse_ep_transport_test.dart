// Pulse structural phase 2: every pulse_ep table has a transport, slice and
// deletion policy, proved through the real export, import and delete paths.
// CLAIM(pulse-transport) CLAIM(pulse-no-realert)
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/data/restore_classification.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backup/backup_support.dart';
import 'pulse_ep_support.dart';

const _portable = [
  'pulse_ep_episode', 'pulse_ep_revision', 'pulse_ep_evidence',
  'pulse_ep_outbox', 'pulse_ep_admission', 'pulse_ep_upgrade_record',
];
const _local = ['pulse_ep_checkpoint', 'pulse_ep_complete', 'pulse_ep_upgrade'];

// 2026-11-10 02:00 local-day labels are literal strings; the instants only need
// to be consistent with them for these tests.
const _day = '2026-11-10';
const _t0 = 1794000000000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('pulse-ep-transport.db'));
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    SharedPreferences.setMockInitialValues({});
  });

  // WHY: a table in no list silently falls out of export -> import (S10/T3).
  test('every pulse_ep table is restored, or classified local with a reason', () {
    for (final t in _portable) {
      expect(LocalDb.restoredTableNames, contains(t), reason: t);
      expect(LocalDb.salvageTablesForTest, contains(t), reason: '$t salvage');
    }
    for (final t in _local) {
      expect(kTablesNotRestored[t], isNotNull, reason: '$t needs a reason');
      expect(kTablesNotRestored[t], isNotEmpty);
      expect(LocalDb.restoredTableNames, isNot(contains(t)));
    }
  });

  // WHY: the issue-report slice must say what it keeps for every table.
  test('every pulse_ep table has a slice policy; the key list is never sliced whole', () {
    for (final t in [..._portable, ..._local]) {
      expect(kSliceTables, contains(t), reason: t);
    }
    expect(kSliceTables['pulse_ep_upgrade_record']!.$1, SliceKeep.none,
        reason: 'membership can be a quarter million keys');
    expect(kSliceTables['pulse_ep_evidence']!.$1, SliceKeep.recent);
  });

  // WHY: "delete everything" empties every table, then the marker comes back so
  // the next sync is not classified as an unbounded pre-upgrade history.
  test('wipeAll clears every pulse_ep row and re-initializes an empty marker', () async {
    final db = await LocalDb.instance;
    await seedEpisode(db, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day);
    await db.insert('pulse_ep_upgrade_record', {'source': '', 'ts_ms': 5});
    await LocalDb.wipeAll();
    final after = await LocalDb.instance;
    for (final t in kPulseEpTables) {
      final rows = await pulseRows(after, t);
      expect(rows, t == 'pulse_ep_upgrade' ? hasLength(1) : isEmpty, reason: t);
    }
  });

  // WHY: a full backup carries history, evidence, delivery outcomes and
  // admission provenance; the receiver's own marker and certificates stay local.
  test('a full export and import carries portable rows and not local state', () async {
    final db = await LocalDb.instance;
    await env.seedData();
    await seedEpisode(db, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000,
        startDay: _day, state: 'sent', payload: [9, 8, 7]);
    await db.insert('pulse_ep_admission', {
      'source': '', 'start_ms': _t0, 'end_ms': _t0 + 1000, 'digest': 'd',
      'records': 1, 'novel': 1, 'origin': 'recentSync', 'admitted_ms': 1, 'historical': 0,
    });
    await db.insert('pulse_ep_upgrade_record', {'source': '', 'ts_ms': 77000});
    await db.insert('pulse_ep_checkpoint', {
      'source': '', 'through_ms': _t0, 'detector': 4, 'stamp': 'x',
      'refused_json': '[]', 'updated_ms': 1,
    });
    final path = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.instance;
    await LocalDb.importFromDbFile(path);
    final got = await LocalDb.instance;
    expect((await pulseRows(got, 'pulse_ep_episode')).single['id'], ':$_t0');
    expect((await pulseRows(got, 'pulse_ep_outbox')).single['state'], 'sent');
    expect((await pulseRows(got, 'pulse_ep_evidence')).single['payload'], [9, 8, 7]);
    expect(await pulseRows(got, 'pulse_ep_admission'), hasLength(1));
    expect((await pulseRows(got, 'pulse_ep_upgrade_record')).single['ts_ms'], 77000);
    expect(await pulseRows(got, 'pulse_ep_checkpoint'), isEmpty,
        reason: 'a checkpoint is local authority and never travels');
    expect(await pulseRows(got, 'pulse_ep_upgrade'), hasLength(1));
  });

  // WHY: re-import must be idempotent and never shrink local data (R2-1).
  test('importing the same file twice converges', () async {
    final db = await LocalDb.instance;
    await env.seedData();
    await seedEpisode(db, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'sent');
    final path = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.importFromDbFile(path);
    final once = await pulseRows(await LocalDb.instance, 'pulse_ep_outbox');
    await LocalDb.importFromDbFile(path);
    expect(await pulseRows(await LocalDb.instance, 'pulse_ep_outbox'), once);
    expect(await pulseRows(await LocalDb.instance, 'pulse_ep_episode'), hasLength(1));
  });

  Future<Database> exportThenImport(
    Future<void> Function(Database db) source,
    Future<void> Function(Database db) local,
  ) async {
    await env.wipe();
    final src = await LocalDb.instance;
    await env.seedData();
    await source(src);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    final dst = await LocalDb.instance;
    await local(dst);
    await LocalDb.importFromDbFile(path);
    return LocalDb.instance;
  }

  // WHY/CLAIM(pulse-no-realert): a consumed outcome beats an owed one in both
  // directions; otherwise a restore re-announces what was already announced.
  test('consumed delivery state wins over owed, whichever side holds it', () async {
    final a = await exportThenImport(
      (s) => seedEpisode(s, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'sent'),
      (d) => seedEpisode(d, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'owed'),
    );
    expect((await pulseRows(a, 'pulse_ep_outbox')).single['state'], 'sent');
    final b = await exportThenImport(
      (s) => seedEpisode(s, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'owed'),
      (d) => seedEpisode(d, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'sent'),
    );
    expect((await pulseRows(b, 'pulse_ep_outbox')).single['state'], 'sent');
  });

  // WHY: another phone's claim token is meaningless here; a pending claim may
  // have shown an alert, so it becomes unknown (never retried).
  test('imported pending becomes unknown with no token; imported owed becomes historical', () async {
    final db = await exportThenImport(
      (s) async {
        await seedEpisode(s, id: 'a:$_t0', source: 'a', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'pending');
        await s.update('pulse_ep_outbox', {'token': 'foreign'}, where: 'episode_id = ?', whereArgs: ['a:$_t0']);
        await seedEpisode(s, id: 'b:$_t0', source: 'b', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'owed');
      },
      (d) async {},
    );
    final rows = {for (final r in await pulseRows(db, 'pulse_ep_outbox')) r['episode_id'] as String: r};
    expect(rows['a:$_t0']!['state'], 'unknown');
    expect(rows['a:$_t0']!['token'], isNull);
    expect(rows['b:$_t0']!['state'], 'owed');
    expect(rows['b:$_t0']!['origin'], 'historical',
        reason: 'imported debt can only be announced in a silent summary');
  });

  // WHY: equal identity with different content must not be replaced by an
  // arbitrary newer-looking row; local valid evidence stays.
  test('a divergent revision with the same identity keeps the local evidence', () async {
    final db = await exportThenImport(
      (s) => seedEpisode(s, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day,
          state: 'sent', checksum: 'foreign', payload: [6, 6, 6]),
      (d) => seedEpisode(d, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day,
          state: 'sent', checksum: 'local', payload: [1, 1, 1]),
    );
    expect((await pulseRows(db, 'pulse_ep_revision')).single['checksum'], 'local');
    expect((await pulseRows(db, 'pulse_ep_evidence')).single['payload'], [1, 1, 1]);
  });

  // WHY: deleting a day removes the recording and its numbers; only an opaque
  // consumed tombstone and the membership keys stay so a re-import cannot
  // re-alert. A cross-midnight episode goes whole.
  test('deleteDays removes evidence for every intersecting episode and keeps a tombstone', () async {
    final db = await LocalDb.instance;
    await env.seedData();
    await seedEpisode(db, id: 'x:1', source: 'x', startMs: _t0, endMs: _t0 + 600000,
        startDay: '2026-11-10', endDay: '2026-11-11', state: 'sent');
    await seedEpisode(db, id: 'x:2', source: 'x', startMs: _t0 + 9 * 86400000,
        endMs: _t0 + 9 * 86400000 + 600000, startDay: '2026-11-19', state: 'owed');
    await db.insert('pulse_ep_upgrade_record', {'source': 'x', 'ts_ms': _t0});
    await LocalDb.deleteDays({'2026-11-11'});
    final ep = {for (final r in await pulseRows(db, 'pulse_ep_episode')) r['id'] as String: r};
    expect(ep['x:1']!['status'], 'deleted');
    expect(ep['x:2']!['status'], 'active');
    final revs = await pulseRows(db, 'pulse_ep_revision');
    expect([for (final r in revs) r['episode_id']], ['x:2']);
    expect([for (final r in await pulseRows(db, 'pulse_ep_evidence')) r['episode_id']], ['x:2']);
    expect((await pulseRows(db, 'pulse_ep_outbox', where: 'episode_id = ?', whereArgs: ['x:1'])).single['state'], 'sent');
    expect(await pulseRows(db, 'pulse_ep_upgrade_record'), hasLength(1));
  });

  // WHY: an unclaimed alert for a deleted recording is cancelled, and the
  // cancellation itself blocks a later re-import from owing it again.
  test('deleteDays cancels unclaimed debt as a consumed deletion', () async {
    final db = await LocalDb.instance;
    await env.seedData();
    await seedEpisode(db, id: 'x:1', source: 'x', startMs: _t0, endMs: _t0 + 600000,
        startDay: '2026-11-10', state: 'owed');
    await LocalDb.deleteDays({'2026-11-10'});
    final out = (await pulseRows(db, 'pulse_ep_outbox')).single;
    expect(out['state'], 'deleted');
  });

  // WHY: a selected-day export claims only what those days depend on.
  test('a selected-day export carries intersecting episodes and no local state', () async {
    final db = await LocalDb.instance;
    await env.seedData();
    await seedEpisode(db, id: 'x:1', source: 'x', startMs: _t0, endMs: _t0 + 600000, startDay: '2026-11-10');
    await seedEpisode(db, id: 'x:2', source: 'x', startMs: _t0 + 9 * 86400000,
        endMs: _t0 + 9 * 86400000 + 600000, startDay: '2026-11-19');
    await db.insert('pulse_ep_checkpoint', {
      'source': 'x', 'through_ms': _t0, 'detector': 4, 'stamp': 's',
      'refused_json': '[]', 'updated_ms': 1,
    });
    final path = await LocalDb.exportDaysDb({'2026-11-10'});
    final out = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      expect([for (final r in await pulseRows(out, 'pulse_ep_episode')) r['id']], ['x:1']);
      expect([for (final r in await pulseRows(out, 'pulse_ep_evidence')) r['episode_id']], ['x:1']);
      expect(await pulseRows(out, 'pulse_ep_checkpoint'), isEmpty);
    } finally {
      await out.close();
    }
  });
}
