// P8a item 1, storage side: schema v85 adds the daily-intake columns to
// track_setup_history. Additive migration, full backup restore, rebuild
// salvage, selected-day export and deleteDays must all carry or keep them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import '../backup/backup_support.dart';

// The shipped v84 shape of the table, copied from git (tracks_schema.dart at
// bd0b7cd8), NOT from the new code, so the migration test starts from the real
// previous head.
const _v84Table =
    'CREATE TABLE track_setup_history ('
    'id TEXT PRIMARY KEY, track_id TEXT NOT NULL, start_date TEXT NOT NULL, '
    'end_date TEXT NOT NULL, done INTEGER NOT NULL CHECK (done IN (0,1)), '
    'CHECK (start_date <= end_date))';

Map<String, Object?> _row(
  String id,
  String start,
  String end, {
  int done = 1,
  int? minute,
  double? amount,
  String? unit,
}) => {
  'id': id,
  'track_id': 'med:x',
  'start_date': start,
  'end_date': end,
  'done': done,
  'approx_minute': minute,
  'amount': amount,
  'amount_unit': unit,
};

Future<Set<String>> _columns(Database db) async => {
  for (final c in await db.rawQuery('PRAGMA table_info(track_setup_history)'))
    c['name'] as String,
};

Future<int> _userVersion(Database db) async =>
    (await db.rawQuery('PRAGMA user_version')).first.values.first as int;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async => env = await BackupEnv.create('tracks_history_schema_p8a.db'));
  tearDown(() async {
    await env.dispose();
    for (final f in Directory(env.dbDir).listSync()) {
      if (f is File &&
          p.basename(f.path).startsWith('tracks_history_schema_p8a.db.')) {
        f.deleteSync();
      }
    }
  });

  Future<void> rewindToV84(List<Map<String, Object?>> oldRows) async {
    await LocalDb.close();
    final legacy = await databaseFactory.openDatabase(
      p.join(env.dbDir, LocalDb.dbName),
    );
    await legacy.execute('DROP TABLE track_setup_history');
    await legacy.execute(_v84Table);
    for (final r in oldRows) {
      await legacy.insert('track_setup_history', r);
    }
    await legacy.execute('PRAGMA user_version = 84');
    await legacy.close();
  }

  group('migration', () {
    // why: schema 85 must be the next free version and purely additive. The
    // v84 rows (the only history that exists in the field) keep every value.
    // proves: CLAIM(range-columns), additive idempotent migrations (AGENTS 3)
    test('v84 history gains three nullable columns and keeps its rows', () async {
      await LocalDb.instance;
      await rewindToV84([
        {
          'id': 'old-yes',
          'track_id': 'med:x',
          'start_date': '2026-01-01',
          'end_date': '2026-01-31',
          'done': 1,
        },
        {
          'id': 'old-no',
          'track_id': 'med:x',
          'start_date': '2026-02-01',
          'end_date': '2026-02-10',
          'done': 0,
        },
      ]);
      final db = await LocalDb.instance;
      expect(LocalDb.schemaVersion, greaterThanOrEqualTo(85));
      expect(await _userVersion(db), LocalDb.schemaVersion);
      expect(
        await _columns(db),
        containsAll(['approx_minute', 'amount', 'amount_unit']),
      );
      expect(
        await db.query('track_setup_history', orderBy: 'start_date'),
        [
          _row('old-yes', '2026-01-01', '2026-01-31'),
          _row('old-no', '2026-02-01', '2026-02-10', done: 0),
        ],
        reason: 'old rows keep their values; new columns are NULL (unknown)',
      );
      // The table-level CHECK survives the migration: it is still enforced.
      await expectLater(
        db.insert('track_setup_history', _row('bad', '2026-03-05', '2026-03-01')),
        throwsA(anything),
      );
      // Positive control: the new columns and the ongoing end are writable.
      await db.insert(
        'track_setup_history',
        _row('new', '2026-03-01', '9999-12-31', minute: 480, amount: 50, unit: 'mg'),
      );
      expect(await db.query('track_setup_history'), hasLength(3));
    });

    test('reopening after the migration changes nothing', () async {
      await LocalDb.instance;
      await rewindToV84([
        {
          'id': 'old',
          'track_id': 'med:x',
          'start_date': '2026-01-01',
          'end_date': '2026-01-31',
          'done': 1,
        },
      ]);
      final first = await (await LocalDb.instance).query('track_setup_history');
      await LocalDb.close();
      final again = await LocalDb.instance;
      expect(await again.query('track_setup_history'), first);
      expect(await _userVersion(again), LocalDb.schemaVersion);
    });

    test('a fresh install has the columns from the start', () async {
      final db = await LocalDb.instance;
      expect(
        await _columns(db),
        containsAll(['approx_minute', 'amount', 'amount_unit']),
      );
    });
  });

  group('carried by every data path', () {
    final ongoing = _row(
      'ongoing',
      '2026-10-20',
      '9999-12-31',
      minute: 495,
      amount: 2.5,
      unit: 'mg',
    );
    final notDone = _row('stopped', '2026-09-01', '2026-09-30', done: 0);

    // why: R2-7/S9 lesson: a table that restores without its new columns turns
    // a timed 50 mg history back into an unknown one. proves: restore parity.
    test('full backup restore returns every column, ongoing end included', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await db.insert('track_setup_history', notDone);
      await env.seedData();
      final backup = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(backup);
      expect(
        await (await LocalDb.instance).query(
          'track_setup_history',
          orderBy: 'start_date',
        ),
        [notDone, ongoing],
      );
    });

    // why: a backup written by the previous release has no intake columns. It
    // must restore as ranges with unknown time and amount, not fail.
    test('a v84 backup file restores with unknown intake', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', _row('old', '2026-01-01', '2026-01-31'));
      await env.seedData();
      final backup = await LocalDb.exportCopy();
      final file = await databaseFactory.openDatabase(backup);
      await file.execute('DROP TABLE track_setup_history');
      await file.execute(_v84Table);
      await file.insert('track_setup_history', {
        'id': 'old',
        'track_id': 'med:x',
        'start_date': '2026-01-01',
        'end_date': '2026-01-31',
        'done': 1,
      });
      await file.close();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(backup);
      expect(
        await (await LocalDb.instance).query('track_setup_history'),
        [_row('old', '2026-01-01', '2026-01-31')],
      );
    });

    // why: a rebuild after a failed migration salvages hand-entered rows; the
    // wearer's "taken daily" history is the only copy of that knowledge.
    test('rebuild salvage keeps the intake columns', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await LocalDb.close();
      final raw = await databaseFactory.openDatabase(
        p.join(env.dbDir, LocalDb.dbName),
      );
      // Same brick the recovery suite plants: the ladder throws on next open.
      await raw.execute('CREATE TABLE _raw_old (hex TEXT)');
      await raw.execute('PRAGMA user_version = 2');
      await raw.close();
      LocalDb.lastRebuild = null;
      final rebuilt = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNotNull, reason: 'the brick must trip a rebuild');
      expect(LocalDb.lastRebuild!.salvaged['track_setup_history'], 1);
      expect(await rebuilt.query('track_setup_history'), [ongoing]);
    });

    // why: S9 again. A selected-day export carries the ranges that cover the
    // day. An ongoing range covers every later day, so it must ride along with
    // its intake; one that starts after the day must not.
    test('selected-day export carries an ongoing range and its intake', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await db.insert(
        'track_setup_history',
        _row('future', '2026-11-05', '9999-12-31', minute: 60),
      );
      await db.insert('track_setup_history', notDone);
      await env.seedData();
      final days = await LocalDb.exportDaysDb({'2026-10-26'});
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(days);
      expect(await (await LocalDb.instance).query('track_setup_history'), [
        ongoing,
      ]);
    });

    // why: CLAIM(learning-keep) family. Setup history is not per-day evidence;
    // deleting days must not erase a range (or its intake), which nothing can
    // rebuild.
    test('deleteDays leaves setup history, intake included', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await db.insert('track_setup_history', notDone);
      await LocalDb.deleteDays({'2026-10-26', '2026-09-15'});
      expect(
        await db.query('track_setup_history', orderBy: 'start_date'),
        [notDone, ongoing],
      );
    });
  });
}
