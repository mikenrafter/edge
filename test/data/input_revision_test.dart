// Design 06 phase 1c: every input has a revision, bumped when it changes.
//
//  * every catalogued table input bumps `input_revision` on insert, update and
//    delete, for the affected day only (global inputs: scope '');
//  * `decoded` is the existing `input_rev` buckets, exposed per day;
//  * setter inputs (profile, policy) bump through `bumpInputRev`, and the
//    setter files call it (a source grep, since a setter is not a table);
//  * the v76 -> v77 step creates the table and triggers, idempotently, and
//    `_repairOpenSchema` (every open) heals a missing set;
//  * wipe and merge never lower a revision: the rule is "bumped, never reset"
//    (`wipeAll` deletes rows, so the delete triggers bump; the revision table
//    itself is not emptied, or a later write would reuse an old number).
//
// Real sqflite_ffi, the same idiom as test/db_day_checkpoint_schema_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/input_catalogue.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/input_revision_store.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _d1 = '2026-03-10';
const String _d2 = '2026-03-11';
const String _d3 = '2026-03-12';

int _noon(String day) {
  final d = DateTime.parse(day);
  return DateTime(d.year, d.month, d.day, 12).millisecondsSinceEpoch ~/ 1000;
}

/// One row's worth of SQL per table input: how to insert, update and delete a
/// row that belongs to a day. A catalogue entry with no fixture fails.
class _Fx {
  const _Fx(this.insert, this.update, this.delete, {this.setup = const []});
  final List<Object?> Function(String day) insert;
  final List<Object?> Function(String day) update;
  final List<Object?> Function(String day) delete;

  /// Statements the input's row needs first (a session for its mask).
  final List<List<Object?>> setup;
}

// Each entry is [sql, args]; the day is bound where a `?` for it appears.
List<Object?> _s(String sql, List<Object?> args) => [sql, args];

final Map<String, _Fx> _fixtures = {
  'step_coverage': _Fx(
    (d) => _s('INSERT INTO live_coverage(start_ts,end_ts,steps,day) '
        'VALUES(?,?,?,?)', [_noon(d), _noon(d) + 60, 10, d]),
    (d) => _s('UPDATE live_coverage SET steps = 99 WHERE day = ?', [d]),
    (d) => _s('DELETE FROM live_coverage WHERE day = ?', [d]),
  ),
  'wearing': _Fx(
    (d) => _s('INSERT INTO device(id,first_seen,last_seen) VALUES(?,1,1)',
        ['fx-$d']),
    (d) => _s('UPDATE device SET wearing = 0 WHERE id = ?', ['fx-$d']),
    (d) => _s('DELETE FROM device WHERE id = ?', ['fx-$d']),
  ),
  'step_calibration': _Fx(
    (d) => _s('INSERT INTO step_calibration(device_family,wearing,factor,'
        'n_days,version,updated_ts) VALUES(?,1,1.0,1,1,1)', ['fx-$d']),
    (d) => _s('UPDATE step_calibration SET factor = 2.0 '
        'WHERE device_family = ?', ['fx-$d']),
    (d) => _s('DELETE FROM step_calibration WHERE device_family = ?',
        ['fx-$d']),
  ),
  'step_calibration_day': _Fx(
    (d) => _s('INSERT INTO step_calibration_day(day,device_family,wearing,'
        'reference_steps,counter_ticks) VALUES(?,\'fx\',1,10,10)', [d]),
    (d) => _s('UPDATE step_calibration_day SET reference_steps = 20 '
        'WHERE day = ?', [d]),
    (d) => _s('DELETE FROM step_calibration_day WHERE day = ?', [d]),
  ),
  'device_coverage': _Fx(
    (d) => _s('INSERT INTO device_coverage(device_id,signal,start_ts,end_ts) '
        'VALUES(?,\'hr\',?,?)', ['fx-$d', _noon(d), _noon(d) + 60]),
    (d) => _s('UPDATE device_coverage SET end_ts = end_ts + 1 '
        'WHERE device_id = ?', ['fx-$d']),
    (d) => _s('DELETE FROM device_coverage WHERE device_id = ?', ['fx-$d']),
  ),
  'events': _Fx(
    (d) => _s('INSERT INTO events(hex,event_id,ts,captured_at) '
        'VALUES(?,9,?,1)', ['fx-$d', _noon(d)]),
    (d) => _s('UPDATE events SET event_id = 10 WHERE hex = ?', ['fx-$d']),
    (d) => _s('DELETE FROM events WHERE hex = ?', ['fx-$d']),
  ),
  'sleep_override': _Fx(
    (d) => _s('INSERT INTO sleep_override(day_id,onset_ts,offset_ts,source,'
        'created_at) VALUES(?,1,2,\'manual\',1)', [d]),
    (d) => _s('UPDATE sleep_override SET offset_ts = 3 WHERE day_id = ?', [d]),
    (d) => _s('DELETE FROM sleep_override WHERE day_id = ?', [d]),
  ),
  'wake_confirmation': _Fx(
    (d) => _s('INSERT INTO wake_confirmation(day_id,at_sec,basis,created_at) '
        'VALUES(?,1,\'x\',1)', [d]),
    (d) => _s('UPDATE wake_confirmation SET at_sec = 2 WHERE day_id = ?', [d]),
    (d) => _s('DELETE FROM wake_confirmation WHERE day_id = ?', [d]),
  ),
  'vendor_sleep_epoch': _Fx(
    (d) => _s('INSERT INTO vendor_sleep_epoch(device_id,night_onset_ts,'
        'start_ts,end_ts,stage,source,decoded_at) '
        'VALUES(\'fx\',?,?,?,\'deep\',\'t\',1)',
        [_noon(d), _noon(d), _noon(d) + 30]),
    (d) => _s('UPDATE vendor_sleep_epoch SET stage = \'rem\' '
        'WHERE night_onset_ts = ?', [_noon(d)]),
    (d) => _s('DELETE FROM vendor_sleep_epoch WHERE night_onset_ts = ?',
        [_noon(d)]),
  ),
  'sessions': _Fx(
    (d) => _s('INSERT INTO sessions(id,start_ts,type,status,created_at) '
        'VALUES(?,?,\'run\',\'done\',1)', ['fx-$d', _noon(d)]),
    (d) => _s('UPDATE sessions SET type = \'walk\' WHERE id = ?', ['fx-$d']),
    (d) => _s('DELETE FROM sessions WHERE id = ?', ['fx-$d']),
  ),
  'session_score_mask': _Fx(
    (d) => _s('INSERT INTO session_score_mask(session_id) VALUES(?)',
        ['fxm-$d']),
    (d) => _s('UPDATE session_score_mask SET session_id = session_id '
        'WHERE session_id = ?', ['fxm-$d']),
    (d) => _s('DELETE FROM session_score_mask WHERE session_id = ?',
        ['fxm-$d']),
    // The mask's day is its session's day.
    setup: [
      for (final d in [_d1, _d2, _d3])
        _s('INSERT OR REPLACE INTO sessions(id,start_ts,type,status,created_at) '
            'VALUES(?,?,\'run\',\'done\',1)', ['fxm-$d', _noon(d)]),
    ],
  ),
  'sleep_nap': _Fx(
    (d) => _s('INSERT INTO sleep_nap(day_id,start_ts,end_ts,source,'
        'created_at) VALUES(?,1,2,\'manual\',1)', [d]),
    (d) => _s('UPDATE sleep_nap SET end_ts = 3 WHERE day_id = ?', [d]),
    (d) => _s('DELETE FROM sleep_nap WHERE day_id = ?', [d]),
  ),
  'baselines': _Fx(
    (d) => _s('INSERT INTO baselines(key,payload_json,updated_at) '
        'VALUES(?,\'{}\',1)', ['fx-$d']),
    (d) => _s('UPDATE baselines SET payload_json = \'{"a":1}\' WHERE key = ?',
        ['fx-$d']),
    (d) => _s('DELETE FROM baselines WHERE key = ?', ['fx-$d']),
  ),
  'metric_series': _Fx(
    (d) => _s('INSERT INTO metric_series(date,key,value) VALUES(?,\'fx\',1)',
        [d]),
    (d) => _s('UPDATE metric_series SET value = 2 WHERE date = ?', [d]),
    (d) => _s('DELETE FROM metric_series WHERE date = ?', [d]),
  ),
  'cycle_log': _Fx(
    (d) => _s('INSERT INTO cycle_log(date,kind) VALUES(?,\'period\')', [d]),
    (d) => _s('UPDATE cycle_log SET kind = \'spotting\' WHERE date = ?', [d]),
    (d) => _s('DELETE FROM cycle_log WHERE date = ?', [d]),
  ),
  'journal': _Fx(
    (d) => _s('INSERT INTO journal(date,updated_at) VALUES(?,1)', [d]),
    (d) => _s('UPDATE journal SET note = \'n\' WHERE date = ?', [d]),
    (d) => _s('DELETE FROM journal WHERE date = ?', [d]),
  ),
  'cycle_symptom': _Fx(
    (d) => _s('INSERT INTO cycle_symptom(date,symptoms_json) '
        'VALUES(?,\'[]\')', [d]),
    (d) => _s('UPDATE cycle_symptom SET symptoms_json = \'["a"]\' '
        'WHERE date = ?', [d]),
    (d) => _s('DELETE FROM cycle_symptom WHERE date = ?', [d]),
  ),
};

Future<void> _run(Database db, List<Object?> stmt) =>
    db.execute(stmt[0] as String, (stmt[1] as List).cast<Object?>());

Future<int> _rev(String source, String scope) async {
  final snap = await inputRevSnapshot([source], fromDay: _d1, toDay: _d3);
  return snap[source]?[scope] ?? 0;
}

Future<int> _userVersion(Database db) async =>
    ((await db.rawQuery('PRAGMA user_version')).first.values.first as num)
        .toInt();

Future<List<String>> _triggers(Database db) async => [
      for (final r in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger' "
          "AND sql LIKE '%input_revision%' ORDER BY name"))
        r['name'] as String
    ];

Future<bool> _hasTable(Database db) async => (await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' "
        "AND name='input_revision'"))
    .isNotEmpty;

Future<Database> _open(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  expect(LocalDb.lastRebuild, isNull,
      reason: 'the open fell back to quarantine-and-rebuild: '
          '${LocalDb.lastRebuild?.cause}');
  return db;
}

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

void main() {
  const name = 'input_revision_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _path(name));
    await _open(name);
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _path(name));
    await databaseFactory.deleteDatabase(await _path('input_revision_fx.db'));
  });

  test('schema version is 77 and the table exists after a plain open',
      () async {
    final db = await LocalDb.instance;
    expect(LocalDb.schemaVersion, 77);
    expect(await _userVersion(db), 77);
    expect(await _hasTable(db), isTrue);
    final cols = {
      for (final c in await db.rawQuery('PRAGMA table_info(input_revision)'))
        c['name'] as String: c
    };
    expect(cols.keys.toSet(), {'source', 'scope', 'rev'});
    expect(cols['source']!['pk'], 1);
    expect(cols['scope']!['pk'], 2);
    expect(cols['rev']!['notnull'], 1);
  });

  test('every table input in the catalogue has a fixture here', () {
    final tables = [
      for (final s in kInputCatalogue)
        if (s.kind == InputKind.table) s.id
    ];
    expect(tables, isNotEmpty);
    expect(_fixtures.keys.toSet(), tables.toSet());
  });

  group('table inputs bump on insert, update and delete', () {
    for (final spec in kInputCatalogue.where((s) => s.kind == InputKind.table)) {
      final fx = _fixtures[spec.id];
      if (fx == null) continue; // reported by the test above
      final global = spec.granularity == InputGranularity.global;
      // The scope this input's change must land in, and one it must not.
      String hit(String d) => global ? '' : d;

      Future<void> expectBumpOnly(
        String what,
        List<Object?> Function(String) stmt,
      ) async {
        final db = await LocalDb.instance;
        final before = <String, int>{
          for (final s in ['', _d1, _d2, _d3]) s: await _rev(spec.id, s)
        };
        await _run(db, stmt(_d2));
        final after = <String, int>{
          for (final s in ['', _d1, _d2, _d3]) s: await _rev(spec.id, s)
        };
        expect(after[hit(_d2)]!, greaterThan(before[hit(_d2)]!),
            reason: '${spec.id}: $what did not bump scope "${hit(_d2)}"');
        for (final s in ['', _d1, _d2, _d3]) {
          if (s == hit(_d2)) continue;
          expect(after[s], before[s],
              reason: '${spec.id}: $what bumped unrelated scope "$s"');
        }
      }

      test('${spec.id}: insert', () async {
        final db = await LocalDb.instance;
        for (final s in fx.setup) {
          await _run(db, s);
        }
        await expectBumpOnly('insert', fx.insert);
      });
      test('${spec.id}: update', () async {
        await expectBumpOnly('update', fx.update);
      });
      test('${spec.id}: delete', () async {
        await expectBumpOnly('delete', fx.delete);
      });
    }
  });

  group('decoded', () {
    test('a decoded row bumps its own day only, through input_rev', () async {
      final b1 = await _rev('decoded', _d1);
      final b2 = await _rev('decoded', _d2);
      final ts = _noon(_d1);
      await LocalDb.insertRecord(
        RawRecord(
            counter: 7000,
            packetType: 47,
            hex: 'rev7000',
            capturedAt: ts * 1000,
            recTs: ts),
        Sample(
            tsEpoch: ts,
            counter: 7000,
            hr: 60,
            rrIntervalsMs: const [],
            ax: 0,
            ay: 0,
            az: 1,
            spo2RedRaw: 1,
            spo2IrRaw: 1,
            skinTempRaw: 3000),
      );
      expect(await _rev('decoded', _d1), greaterThan(b1));
      expect(await _rev('decoded', _d2), b2);
    });

    test('input_rev itself is untouched by the new table', () async {
      final db = await LocalDb.instance;
      final cols = {
        for (final c in await db.rawQuery('PRAGMA table_info(input_rev)'))
          c['name'] as String
      };
      expect(cols, {'bucket', 'rev'});
    });
  });

  group('setter inputs', () {
    test('bumpInputRev adds one per call, per scope', () async {
      final g0 = await _rev('profile', '');
      await bumpInputRev('profile', '');
      await bumpInputRev('profile', '');
      expect(await _rev('profile', ''), g0 + 2);

      final d0 = await _rev('policy', _d1);
      await bumpInputRev('policy', _d1);
      expect(await _rev('policy', _d1), d0 + 1);
      expect(await _rev('policy', _d2), 0);
    });

    test('each setter file calls bumpInputRev for its input', () {
      final setters =
          kInputCatalogue.where((s) => s.kind == InputKind.setter).toList();
      expect(setters, isNotEmpty);
      for (final s in setters) {
        expect(s.setterFiles, isNotEmpty, reason: s.id);
        for (final f in s.setterFiles) {
          final src = File(f).readAsStringSync();
          expect(src.contains("bumpInputRev('${s.id}'"), isTrue,
              reason: '$f never calls bumpInputRev(\'${s.id}\', ...)');
        }
      }
    });
  });

  group('migration v76 -> v77', () {
    /// Tamper a closed store back to what v76 left: no revision table, no
    /// revision triggers, user_version 76.
    Future<void> toV76() async {
      await LocalDb.close();
      final raw = await databaseFactory.openDatabase(await _path(name));
      for (final t in await _triggers(raw)) {
        await raw.execute('DROP TRIGGER $t');
      }
      await raw.execute('DROP TABLE IF EXISTS input_revision');
      await raw.execute('PRAGMA user_version = 76');
      await raw.close();
    }

    test('an upgrade creates the table and a trigger set per input table',
        () async {
      await toV76();
      final db = await _open(name);
      expect(await _userVersion(db), 77,
          reason: 'the ladder step did not run (schemaVersion is '
              '${LocalDb.schemaVersion})');
      expect(await _hasTable(db), isTrue);
      final tr = await _triggers(db);
      // Insert, update and delete per catalogued table.
      final tables = <String>{
        for (final s in kInputCatalogue)
          if (s.kind == InputKind.table)
            for (final t in s.tables) t.name
      };
      expect(tr.length, greaterThanOrEqualTo(tables.length * 3));
    });

    test('running the creator twice and reopening changes nothing', () async {
      final db = await LocalDb.instance;
      await createInputRevision(db);
      final once = await _triggers(db);
      await createInputRevision(db);
      expect(await _triggers(db), once);
      expect(once, isNotEmpty);
      final db2 = await _open(name); // _repairOpenSchema runs again
      expect(await _triggers(db2), once);
      expect(await _userVersion(db2), 77);
    });

    test('a missing trigger set is healed by the open-time repair', () async {
      await LocalDb.close();
      final raw = await databaseFactory.openDatabase(await _path(name));
      for (final t in await _triggers(raw)) {
        await raw.execute('DROP TRIGGER $t');
      }
      await raw.close();
      final db = await _open(name);
      expect(await _triggers(db), isNotEmpty);
    });

    test('an upgrade does not backfill: existing rows start at revision 0',
        () async {
      final db = await LocalDb.instance;
      await db.execute('DELETE FROM journal');
      await toV76();
      final raw = await databaseFactory.openDatabase(await _path(name));
      await raw.execute(
          "INSERT INTO journal(date,updated_at) VALUES('2026-03-15',1)");
      await raw.close();
      await _open(name);
      expect(await _rev('journal', '2026-03-15'), 0);
    });
  });

  group('wipe and merge', () {
    test('wipeAll bumps and never resets a revision', () async {
      final db = await LocalDb.instance;
      await db.execute(
          "INSERT OR REPLACE INTO journal(date,updated_at) VALUES(?,1)",
          [_d1]);
      final before = await _rev('journal', _d1);
      expect(before, greaterThan(0));
      await LocalDb.wipeAll();
      final wiped = await _rev('journal', _d1);
      expect(wiped, greaterThan(before),
          reason: 'wipe deletes the row; that delete is a change');
      // The next write must not reuse a number a stamp may already hold.
      await db.execute(
          "INSERT INTO journal(date,updated_at) VALUES(?,1)", [_d1]);
      expect(await _rev('journal', _d1), greaterThan(wiped));
      final snap = await inputRevSnapshot(['journal', 'profile'],
          fromDay: _d1, toDay: _d3);
      expect(snap['profile']?[''] ?? 0, greaterThan(0),
          reason: 'global setter revisions survive a wipe');
    });

    test('input_revision is not a restore table', () {
      // Restore (importFromDbFile -> _ldbImportPlain) must never copy a
      // foreign file's revisions; the merged rows bump ours via the triggers.
      expect(LocalDb.restoreTablesForTest, isNot(contains('input_revision')));
    });

    test('importFromDbFile bumps through the triggers and does not copy '
        'foreign revisions', () async {
      final srcPath = await _path('input_revision_fx.db');
      await databaseFactory.deleteDatabase(srcPath);
      final src = await databaseFactory.openDatabase(srcPath);
      await src.execute('CREATE TABLE journal (date TEXT PRIMARY KEY, '
          "tags_json TEXT NOT NULL DEFAULT '[]', note TEXT NOT NULL "
          "DEFAULT '', updated_at INTEGER NOT NULL)");
      await src.execute(
          "INSERT INTO journal(date,updated_at) VALUES('2026-03-20',1)");
      await src.execute('CREATE TABLE input_revision (source TEXT, '
          'scope TEXT, rev INTEGER NOT NULL, PRIMARY KEY(source, scope))');
      await src.execute("INSERT INTO input_revision VALUES "
          "('journal','2026-03-20',9999)");
      await src.close();

      final before = await _rev('journal', '2026-03-20');
      await LocalDb.importFromDbFile(srcPath);
      final after = await _rev('journal', '2026-03-20');
      expect(after, greaterThan(before), reason: 'the merge wrote a row');
      expect(after, lessThan(9999),
          reason: 'a foreign revision must not be copied in');
    });
  });
}
