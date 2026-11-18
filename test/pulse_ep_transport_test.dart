// Pulse structural phase 2: every pulse_ep table has a transport, slice and
// deletion policy, proved through the real export, import and delete paths.
// CLAIM(pulse-transport) CLAIM(pulse-no-realert)
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_ep_worker.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_codec.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
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

class _StopBeforePulseAdmission implements ImportTableProbe {
  @override
  Future<void> beforeTable(String table) async {
    if (table == 'pulse_ep_admission') throw StateError('interrupted after pulse evidence/outbox');
  }
}

class _StopBeforeRevisions implements ImportTableProbe {
  @override
  Future<void> beforeTable(String table) async {
    if (table == 'pulse_ep_revision') throw StateError('interrupted after episodes');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('pulse-ep-transport.db'));
  tearDownAll(() async => env.dispose());
  tearDown(() {
    ImportHooks.reset();
    PulseEpisodeStore.importBudgetBytesForTest = null;
  });
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
    await seedPortableEpisode(db, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day);
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
    await seedPortableEpisode(db, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000,
        startDay: _day, state: 'sent');
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
    final recording = (await pulseRows(got, 'pulse_ep_evidence')).single;
    final read = await PulseEpisodeWorker.decode(recording['payload'] as List<int>, recording['checksum'] as String);
    expect(read, isA<PulseEvidenceAvailable>());
    expect((read as PulseEvidenceAvailable).evidence.beats.single.rawMs, 800);
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
    await seedPortableEpisode(db, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'sent');
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
      (s) => seedPortableEpisode(s, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'sent'),
      (d) => seedPortableEpisode(d, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'owed'),
    );
    expect((await pulseRows(a, 'pulse_ep_outbox')).single['state'], 'sent');
    final b = await exportThenImport(
      (s) => seedPortableEpisode(s, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'owed'),
      (d) => seedPortableEpisode(d, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'sent'),
    );
    expect((await pulseRows(b, 'pulse_ep_outbox')).single['state'], 'sent');
  });

  // WHY: another phone's claim token is meaningless here; a pending claim may
  // have shown an alert, so it becomes unknown (never retried).
  test('imported pending becomes unknown with no token; imported owed becomes historical', () async {
    final db = await exportThenImport(
      (s) async {
        await seedPortableEpisode(s, id: 'a:$_t0', source: 'a', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'pending');
        await s.update('pulse_ep_outbox', {'token': 'foreign'}, where: 'episode_id = ?', whereArgs: ['a:$_t0']);
        await seedPortableEpisode(s, id: 'b:$_t0', source: 'b', startMs: _t0, endMs: _t0 + 600000, startDay: _day, state: 'owed');
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
      (s) => seedPortableEpisode(s, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day,
          state: 'sent', rr: 900),
      (d) => seedPortableEpisode(d, id: ':$_t0', startMs: _t0, endMs: _t0 + 600000, startDay: _day,
          state: 'sent', rr: 800),
    );
    final literal = literalPulseRecording(':$_t0', '', _t0, _t0 + 600000);
    expect((await pulseRows(db, 'pulse_ep_revision')).single['checksum'], literal.checksum);
    expect((await pulseRows(db, 'pulse_ep_evidence')).single['payload'], literal.bytes);
  });

  // WHY: deleting a day removes the recording and its numbers; only an opaque
  // consumed tombstone and the membership keys stay so a re-import cannot
  // re-alert. A cross-midnight episode goes whole.
  test('deleteDays removes evidence for every intersecting episode and keeps a tombstone', () async {
    final db = await LocalDb.instance;
    await env.seedData();
    await seedPortableEpisode(db, id: 'x:1', source: 'x', startMs: _t0, endMs: _t0 + 600000,
        startDay: '2026-11-10', endDay: '2026-11-11', state: 'sent');
    await seedPortableEpisode(db, id: 'x:2', source: 'x', startMs: _t0 + 9 * 86400000,
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
    await seedPortableEpisode(db, id: 'x:1', source: 'x', startMs: _t0, endMs: _t0 + 600000,
        startDay: '2026-11-10', state: 'owed');
    await LocalDb.deleteDays({'2026-11-10'});
    final out = (await pulseRows(db, 'pulse_ep_outbox')).single;
    expect(out['state'], 'deleted');
    expect((await pulseRows(db, 'pulse_ep_upgrade')).single['generation'], 1,
        reason: 'a deletion fences any preparation still in flight');
  });

  // WHY: a selected-day export claims only what those days depend on.
  test('a selected-day export carries intersecting episodes and no local state', () async {
    final db = await LocalDb.instance;
    await env.seedData();
    await seedPortableEpisode(db, id: 'x:1', source: 'x', startMs: _t0, endMs: _t0 + 600000, startDay: '2026-11-10');
    await seedPortableEpisode(db, id: 'x:2', source: 'x', startMs: _t0 + 9 * 86400000,
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
  // WHY/R1: deletion must survive backups taken before deletion, in either
  // merge direction, including a process death between parent and child tables.
  // catches: merging revision/evidence rows independently of tombstone status.
  for (final direction in ['local deletion', 'imported deletion', 'resume']) {
    test('R1 tombstone removes measurements during $direction', () async {
      var db = await LocalDb.instance;
      await env.seedData();
      await seedPortableEpisode(db, id: ':$_t0', startMs: _t0,
          endMs: _t0 + 600000, startDay: _day);
      final live = await LocalDb.exportCopy();
      await LocalDb.deleteDays({_day});
      final deleted = await LocalDb.exportCopy();
      if (direction == 'imported deletion') {
        await env.wipe();
        await LocalDb.importFromDbFile(live);
        await LocalDb.importFromDbFile(deleted);
      } else if (direction == 'resume') {
        ImportHooks.table = _StopBeforeRevisions();
        await expectLater(LocalDb.importFromDbFile(live), throwsStateError);
        ImportHooks.reset();
        await LocalDb.close();
        expect((await ImportJournal.resumeIfUnfinished()).resumed, isTrue);
      } else {
        await LocalDb.importFromDbFile(live);
      }
      db = await LocalDb.instance;
      expect((await pulseRows(db, 'pulse_ep_episode')).single['status'], 'deleted');
      expect(await pulseRows(db, 'pulse_ep_revision'), isEmpty);
      expect(await pulseRows(db, 'pulse_ep_evidence'), isEmpty);
      expect((await pulseRows(db, 'pulse_ep_outbox')).single['state'], 'deleted');
    });
  }

  // WHY/R6: checksum labels alone cannot authenticate a recording. These
  // independent compressed fixtures travel through the actual paged importer.
  // catches: accepting matching header labels without bounded decode/schema checks.
  test('R6 importer validates mixed valid corrupt unsupported and oversized recordings', () async {
    final db = await LocalDb.instance;
    await env.seedData();
    for (final id in ['valid', 'tampered', 'bogus', 'bomb', 'unsupported', 'size']) {
      await seedPortableEpisode(db, id: id, startMs: _t0, endMs: _t0 + 600000, startDay: _day);
    }
    await db.update('pulse_ep_evidence', {'payload': Uint8List.fromList([9, 8, 7]), 'encoded_bytes': 3},
        where: 'episode_id = ?', whereArgs: ['tampered']);
    for (final table in ['pulse_ep_revision', 'pulse_ep_evidence']) {
      await db.update(table, {'checksum': 'f' * 64}, where: 'episode_id = ?', whereArgs: ['bogus']);
    }
    final bomb = ZLibCodec(level: 6).encode(List.filled(1024 * 1024 + 1, 32));
    await db.update('pulse_ep_evidence', {'payload': Uint8List.fromList(bomb),
        'encoded_bytes': bomb.length, 'expanded_bytes': 1},
        where: 'episode_id = ?', whereArgs: ['bomb']);
    final unknown = literalPulseRecording('unsupported', '', _t0, _t0 + 600000, version: 99);
    await db.update('pulse_ep_evidence', {'payload': Uint8List.fromList(unknown.bytes),
        'encoded_bytes': unknown.bytes.length, 'expanded_bytes': unknown.expanded, 'checksum': unknown.checksum},
        where: 'episode_id = ?', whereArgs: ['unsupported']);
    await db.update('pulse_ep_revision', {'checksum': unknown.checksum},
        where: 'episode_id = ?', whereArgs: ['unsupported']);
    await db.update('pulse_ep_evidence', {'expanded_bytes': 1}, where: 'episode_id = ?', whereArgs: ['size']);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    final result = await LocalDb.importFromDbFile(path);
    final got = await LocalDb.instance;
    expect((await pulseRows(got, 'pulse_ep_evidence')).map((r) => r['episode_id']), ['valid']);
    final revisions = {for (final r in await pulseRows(got, 'pulse_ep_revision')) r['episode_id']: r['evidence_status']};
    expect(revisions, {'valid': 'available', 'tampered': 'corrupt', 'bogus': 'corrupt',
        'bomb': 'corrupt', 'unsupported': 'unsupported', 'size': 'corrupt'});
    final debts = {for (final r in await pulseRows(got, 'pulse_ep_outbox')) r['episode_id']: r['state']};
    expect(debts, {'valid': 'owed', 'tampered': 'not_sent', 'bogus': 'not_sent',
        'bomb': 'not_sent', 'unsupported': 'not_sent', 'size': 'not_sent'});
    expect(result['_pulse_evidence_corrupt'], 4);
    expect(result['_pulse_evidence_unsupported'], 1);
  });

  // WHY/R7: independently bounded backups may exceed the retained byte budget
  // when merged. Check actual aggregate bytes after each real import.
  // catches: admitting imported blobs without global budget reconciliation.
  test('R7 aggregate import budget and local pending pins are enforced', () async {
    var db = await LocalDb.instance;
    await seedPortableEpisode(db, id: 'a', startMs: _t0, endMs: _t0 + 600000, startDay: _day);
    final a = await LocalDb.exportCopy();
    final sizeA = (await pulseRows(db, 'pulse_ep_evidence')).single['encoded_bytes'] as int;
    await env.wipe();
    db = await LocalDb.instance;
    await seedPortableEpisode(db, id: 'b', startMs: _t0, endMs: _t0 + 600000, startDay: _day);
    final b = await LocalDb.exportCopy();
    final sizeB = (await pulseRows(db, 'pulse_ep_evidence')).single['encoded_bytes'] as int;
    await env.wipe();
    PulseEpisodeStore.importBudgetBytesForTest = sizeA > sizeB ? sizeA : sizeB;
    await LocalDb.importFromDbFile(a);
    db = await LocalDb.instance;
    await db.update('pulse_ep_outbox', {'state': 'pending', 'token': 'local-claim'},
        where: 'episode_id = ?', whereArgs: ['a']);
    final result = await LocalDb.importFromDbFile(b);
    final blobs = await pulseRows(db, 'pulse_ep_evidence');
    expect(blobs.map((r) => r['episode_id']), ['a']);
    expect(blobs.fold<int>(0, (sum, r) => sum + (r['encoded_bytes'] as int)), lessThanOrEqualTo(PulseEpisodeStore.importBudgetBytesForTest!));
    expect((await pulseRows(db, 'pulse_ep_outbox', where: 'episode_id = ?', whereArgs: ['a'])).single['token'], 'local-claim');
    expect((await pulseRows(db, 'pulse_ep_outbox', where: 'episode_id = ?', whereArgs: ['b'])).single['state'], 'not_sent');
    expect(result['_pulse_evidence_budget_refused'], 1);
  });

  // WHY/R7: current and actually delivered evidence are the only retained
  // revisions. Reconciliation must also run after copied-table resume markers.
  // catches: accumulating every imported revision and skipping final resume repair.
  for (final resume in [false, true]) {
    test('R7 retains current and delivered revisions${resume ? ' after resume' : ''}', () async {
      var db = await LocalDb.instance;
      await seedPortableEpisode(db, id: 'r', startMs: _t0, endMs: _t0 + 600000,
          startDay: _day, state: 'sent', revision: 3);
      final header = (await pulseRows(db, 'pulse_ep_revision')).single;
      final blob = (await pulseRows(db, 'pulse_ep_evidence')).single;
      for (final revision in [1, 2]) {
        await db.insert('pulse_ep_revision', {...header, 'revision': revision});
        await db.insert('pulse_ep_evidence', {...blob, 'revision': revision});
      }
      await db.update('pulse_ep_outbox', {'revision': 1});
      final path = await LocalDb.exportCopy();
      await env.wipe();
      if (resume) {
        ImportHooks.table = _StopBeforePulseAdmission();
        await expectLater(LocalDb.importFromDbFile(path), throwsStateError);
        ImportHooks.reset();
        await LocalDb.close();
        expect((await ImportJournal.resumeIfUnfinished()).resumed, isTrue);
      } else {
        await LocalDb.importFromDbFile(path);
      }
      db = await LocalDb.instance;
      expect((await pulseRows(db, 'pulse_ep_evidence', orderBy: 'revision')).map((r) => r['revision']), [1, 3]);
      expect((await pulseRows(db, 'pulse_ep_revision', where: 'revision = 2')).single['evidence_status'], 'expired');
    });
  }

  // WHY/R7: expiration is terminal for a retained revision, and imported
  // creation age cannot be refreshed to make an old recording look new.
  // catches: restoring payload under an expired local revision or resetting age.
  test('R7 expired local and aged imported recordings cannot be revived', () async {
    var db = await LocalDb.instance;
    await seedPortableEpisode(db, id: 'expired', startMs: _t0, endMs: _t0 + 600000, startDay: _day);
    await seedPortableEpisode(db, id: 'aged', startMs: _t0, endMs: _t0 + 600000, startDay: _day,
        createdMs: DateTime.now().millisecondsSinceEpoch - 366 * 86400000);
    final path = await LocalDb.exportCopy();
    await db.delete('pulse_ep_evidence');
    await db.update('pulse_ep_revision', {'evidence_status': 'expired'});
    await db.delete('pulse_ep_episode', where: 'id = ?', whereArgs: ['aged']);
    await db.delete('pulse_ep_revision', where: 'episode_id = ?', whereArgs: ['aged']);
    await db.delete('pulse_ep_outbox', where: 'episode_id = ?', whereArgs: ['aged']);
    await LocalDb.importFromDbFile(path);
    expect(await pulseRows(db, 'pulse_ep_evidence'), isEmpty);
    expect((await pulseRows(db, 'pulse_ep_revision')).map((r) => r['evidence_status']), everyElement('expired'));
    expect((await pulseRows(db, 'pulse_ep_outbox')).map((r) => r['state']), everyElement('not_sent'));
  });

  // WHY/R9: preserve local valid bytes and conservative consumed history while
  // exposing that the imported handoff names different recording content.
  // catches: IGNORE treating divergent revisions as unchanged duplicates.
  test('R9 divergent consumed import reports conflict and preserves handoff checksum', () async {
    var db = await LocalDb.instance;
    await seedPortableEpisode(db, id: 'conflict', startMs: _t0,
        endMs: _t0 + 600000, startDay: _day, state: 'sent', rr: 900);
    final foreign = literalPulseRecording('conflict', '', _t0, _t0 + 600000, rr: 900);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    db = await LocalDb.instance;
    await seedPortableEpisode(db, id: 'conflict', startMs: _t0,
        endMs: _t0 + 600000, startDay: _day, state: 'owed', rr: 800);
    final local = literalPulseRecording('conflict', '', _t0, _t0 + 600000);
    final result = await LocalDb.importFromDbFile(path);
    expect((await pulseRows(db, 'pulse_ep_evidence')).single['payload'], local.bytes);
    expect((await pulseRows(db, 'pulse_ep_revision')).single['checksum'], local.checksum);
    expect(result['_pulse_conflicts'], 1);
    final outcome = (await pulseRows(db, 'pulse_ep_outbox')).single;
    expect(outcome['state'], 'sent');
    expect(outcome['recording_checksum'], foreign.checksum);
    expect(outcome['reason'], 'imported delivered recording conflicts with local revision');
    final again = await LocalDb.importFromDbFile(path);
    expect(again['_pulse_conflicts'], 1);
    expect(await pulseRows(db, 'pulse_ep_outbox'), [outcome]);
  });

}
