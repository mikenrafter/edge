// Design 06 phase 1c, Sol r1 findings 1, 2 and 4: input revisions under
// REPLACE writes and over-the-day spans.
//
//  1. SQLite applies the OUTER statement's conflict policy to statements run
//     by a trigger, so a trigger's `INSERT OR IGNORE ... rev = 0` becomes a
//     REPLACE under `INSERT OR REPLACE` and resets the counter. A revision
//     never goes down and every write goes up, whatever the writer.
//  2. REPLACE's implicit delete fires no DELETE trigger: a row replaced onto
//     another day must still bump the day it left.
//  4. A wrist-off/charging transition holds until the next one
//     (`_ldbPrivToggleSpans` reads the last transition BEFORE its window), so
//     a change to it moves every derived day up to that next transition.
//
// Real sqflite_ffi, the same idiom as test/data/input_revision_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/input_revision_store.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _d1 = '2026-03-10';
const String _d2 = '2026-03-11';
const String _d3 = '2026-03-12';
const String _d4 = '2026-03-13';

int _noon(String day) {
  final d = DateTime.parse(day);
  return DateTime(d.year, d.month, d.day, 12).millisecondsSinceEpoch ~/ 1000;
}

Future<int> _rev(String source, String scope) async {
  final snap =
      await inputRevSnapshot([source], fromDay: _d1, toDay: '2026-03-31');
  return snap[source]?[scope] ?? 0;
}

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Map<String, Object?> _session(String id, String day) => {
      'id': id,
      'start_ts': _noon(day),
      'end_ts': _noon(day) + 600,
      'type': 'run',
      'status': 'done',
      'created_at': 1,
    };

Future<void> _bandEvent(String hex, int eventId, String day,
    {int hour = 12}) async {
  final db = await LocalDb.instance;
  final d = DateTime.parse(day);
  final ts =
      DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch ~/ 1000;
  await db.insert('band_events', {
    'hex': hex,
    'event_id': eventId,
    'name': 'x',
    'ts': ts,
    'captured_at': 1,
  });
}

Future<void> _deleteBandEvent(String hex) async {
  final db = await LocalDb.instance;
  await db.delete('band_events', where: 'hex = ?', whereArgs: [hex]);
}

Future<void> _derivedDays(List<String> days) async {
  final db = await LocalDb.instance;
  for (final d in days) {
    await db.insert(
        'day_result',
        {
          'day_id': d,
          'algo_version': 1,
          'payload_json': '{}',
          'computed_at': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

void main() {
  const name = 'input_revision_replace_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _path(name));
    LocalDb.dbName = name;
    await LocalDb.instance;
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _path(name));
    await databaseFactory.deleteDatabase(await _path('input_revision_rp.db'));
  });

  group('finding 1: REPLACE never lowers a revision', () {
    test('repeated putSession of one session raises the day every time',
        () async {
      var last = await _rev('sessions', _d1);
      for (var i = 0; i < 4; i++) {
        await LocalDb.putSession(_session('rp-same', _d1));
        final now = await _rev('sessions', _d1);
        expect(now, greaterThan(last), reason: 'write ${i + 1} did not bump');
        last = now;
      }
    });

    test('a REPLACE over a high revision keeps climbing from it', () async {
      for (var i = 0; i < 7; i++) {
        await bumpInputRev('journal', _d2);
      }
      final before = await _rev('journal', _d2);
      expect(before, greaterThanOrEqualTo(7));
      final db = await LocalDb.instance;
      await db.execute(
          'INSERT OR REPLACE INTO journal(date,updated_at) VALUES(?,1)', [_d2]);
      expect(await _rev('journal', _d2), before + 1);
    });

    test('setCursor (INSERT OR REPLACE) over a global input keeps climbing',
        () async {
      for (var i = 0; i < 3; i++) {
        await bumpInputRev('baselines', '');
      }
      final before = await _rev('baselines', '');
      final db = await LocalDb.instance;
      await db.execute(
          "INSERT OR REPLACE INTO baselines(key,payload_json,updated_at) "
          "VALUES('rp-k','{}',1)");
      expect(await _rev('baselines', ''), before + 1);
    });

    test('a bulk restore (INSERT OR REPLACE ... SELECT) over a nonzero '
        'revision never lowers it', () async {
      final src = await _path('input_revision_rp.db');
      await databaseFactory.deleteDatabase(src);
      final s = await databaseFactory.openDatabase(src);
      await s.execute('CREATE TABLE journal (date TEXT PRIMARY KEY, '
          "tags_json TEXT NOT NULL DEFAULT '[]', note TEXT NOT NULL "
          'DEFAULT \'\', updated_at INTEGER NOT NULL)');
      await s.execute(
          "INSERT INTO journal(date,updated_at) VALUES('2026-03-20',9)");
      await s.close();
      final db = await LocalDb.instance;
      await db.execute(
          "INSERT OR REPLACE INTO journal(date,updated_at) VALUES('2026-03-20',1)");
      for (var i = 0; i < 5; i++) {
        await bumpInputRev('journal', '2026-03-20');
      }
      final before = await _rev('journal', '2026-03-20');
      await LocalDb.importFromDbFile(src);
      final after = await _rev('journal', '2026-03-20');
      expect(after, greaterThan(before),
          reason: 'the merge replaced a row; the counter must go up');
    });
  });

  test('a v77 database with the old trigger bodies is healed on open',
      () async {
    await LocalDb.close();
    final raw = await databaseFactory.openDatabase(await _path(name));
    await raw.execute('DROP TRIGGER ir_sessions_sessions_ai');
    await raw.execute('DROP TRIGGER ir_sessions_sessions_bi');
    await raw.execute('CREATE TRIGGER ir_sessions_sessions_ai AFTER INSERT ON '
        'sessions BEGIN INSERT OR IGNORE INTO input_revision(source, scope, '
        "rev) VALUES('sessions', '', 0); END");
    await raw.close();
    await LocalDb.instance;
    final db = await LocalDb.instance;
    final sql = (await db.rawQuery("SELECT name, sql FROM sqlite_master "
            "WHERE name IN ('ir_sessions_sessions_ai', "
            "'ir_sessions_sessions_bi')"))
        .map((r) => '${r['sql']}')
        .join('\n');
    expect(sql, isNot(contains('OR IGNORE')));
    expect(sql, contains('BEFORE INSERT'), reason: 'the missing one is back');
  });

  group('finding 2: a REPLACE that moves a row bumps the day it left', () {
    test('putSession of the same id on another day bumps both days',
        () async {
      await LocalDb.putSession(_session('rp-move', _d1));
      final old = await _rev('sessions', _d1);
      final neu = await _rev('sessions', _d3);
      await LocalDb.putSession(_session('rp-move', _d3));
      expect(await _rev('sessions', _d1), greaterThan(old),
          reason: 'the day the session left was not bumped');
      expect(await _rev('sessions', _d3), greaterThan(neu));
    });

    test('the bulk restore moving a session bumps the day it left', () async {
      await LocalDb.putSession(_session('rp-rmove', _d1));
      final src = await _path('input_revision_rp.db');
      await databaseFactory.deleteDatabase(src);
      final s = await databaseFactory.openDatabase(src);
      await s.execute('CREATE TABLE sessions (id TEXT PRIMARY KEY, '
          'start_ts INTEGER NOT NULL, end_ts INTEGER, type TEXT, '
          'status TEXT, created_at INTEGER NOT NULL)');
      await s.insert('sessions', _session('rp-rmove', _d4));
      await s.close();
      final old = await _rev('sessions', _d1);
      await LocalDb.importFromDbFile(src);
      final db = await LocalDb.instance;
      final row = await db.query('sessions',
          where: 'id = ?', whereArgs: ['rp-rmove']);
      expect(row.single['start_ts'], _noon(_d4), reason: 'restore moved it');
      expect(await _rev('sessions', _d1), greaterThan(old),
          reason: 'the day the restored session left was not bumped');
    });
  });

  group('finding 4: a transition holds until the next one', () {
    setUpAll(() => _derivedDays([_d1, _d2, _d3, _d4]));

    test('a wrist-off persisting across midnights bumps every day it holds '
        'through, when it changes', () async {
      await _bandEvent('rp-off', proto.EventId.wristOff, _d1);
      // Nothing else: the strap stays off wrist for days.
      final before = {for (final d in [_d1, _d2, _d3, _d4]) d: await _rev('events', d)};
      await _deleteBandEvent('rp-off');
      for (final d in [_d1, _d2, _d3, _d4]) {
        expect(await _rev('events', d), greaterThan(before[d]!),
            reason: 'deleting the wrist-off did not bump $d, which it covered');
      }
    });

    test('the bump stops at the next transition of the same kind', () async {
      await _bandEvent('rp-off2', proto.EventId.wristOff, _d1);
      await _bandEvent('rp-on2', proto.EventId.wristOn, _d2);
      final before = {for (final d in [_d1, _d2, _d3, _d4]) d: await _rev('events', d)};
      await _deleteBandEvent('rp-off2');
      expect(await _rev('events', _d1), greaterThan(before[_d1]!));
      expect(await _rev('events', _d2), greaterThan(before[_d2]!),
          reason: 'the day of the next transition is still covered');
      expect(await _rev('events', _d3), before[_d3],
          reason: 'past the next transition the span is closed');
      expect(await _rev('events', _d4), before[_d4]);
      await _deleteBandEvent('rp-on2');
    });

    test('a charging transition does not close a wrist span', () async {
      await _bandEvent('rp-off3', proto.EventId.wristOff, _d1);
      await _bandEvent('rp-chg3', proto.EventId.chargingOn, _d2);
      final before = {for (final d in [_d1, _d2, _d3]) d: await _rev('events', d)};
      await _deleteBandEvent('rp-off3');
      expect(await _rev('events', _d3), greaterThan(before[_d3]!),
          reason: 'charging is another kind: the wrist span runs on');
      await _deleteBandEvent('rp-chg3');
    });
  });
}
