// P2.1 schema 71, design 02 step 2, section 4.1.
//
// ASSUMED (lib/data/db.dart):
//
//   * `LocalDb.schemaVersion == 71`, with an `if (oldV < 71)` rung.
//   * ONE creator, `_ensureStoreRevisions(db)` (all `IF NOT EXISTS`: the two
//     tables and the five triggers), called from the rung, from `onCreate` and
//     from `_repairOpenSchema` on every open, so a same-version merged build
//     self-heals (invariant 11). It is private; it is tested through reopens.
//   * No backfill. Rows that exist when the rung runs get no `row_rev` row and
//     read revision 0 until their first accepted write. No `kAlgoVersion` bump:
//     nothing derived reads the revision.
//   * Cheap and idempotent: running the rung over an already-71 shape, or the
//     repair over a complete one, changes nothing, loses nothing and keeps
//     every revision.
//
// The v70 fixture is a current-schema database taken back to exactly what
// schema 70 left (`p21DowngradeToV70`), so it is true to whatever the ladder
// has accumulated rather than a hand-copied DDL that drifts.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

import 'support/p21_support.dart';

const _d1 = '2026-03-10';
const _d2 = '2026-03-11';

final _created = <String>[];

/// Build a v70-shaped file holding real rows, then close it.
Future<void> _seedV70(String name) async {
  _created.add(name);
  final db = await p21Fresh(name);
  await p21RawDay(db, _d1, finalized: true, payload: p21Payload('one', day: _d1));
  await p21RawDay(db, _d2, payload: p21Payload('two', day: _d2));
  await p21RawDay(db, _d1, version: p21Version - 2, payload: p21Payload('old'));
  await p21RawBaseline(db, 'crossday', '{"v":1}');
  await p21RawBaseline(db, 'sleep_user_profile', '{"v":2}');
  await p21DowngradeToV70(db);
  await LocalDb.close();
}

Future<Database> _open(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  expect(
    LocalDb.lastRebuild,
    isNull,
    reason: 'the upgrade bricked and fell back to quarantine-and-rebuild: '
        '${LocalDb.lastRebuild?.cause}',
  );
  return db;
}

Future<void> _expectRevObjects(Database db) async {
  await p21ExpectRevTables(db);
  final t = await p21Triggers(db);
  expect(t.length, 5, reason: '$t');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();
  setUpAll(p21InitFfi);

  tearDownAll(() async {
    for (final n in _created) {
      await p21Drop(n);
    }
  });

  test('schemaVersion is 71', () {
    expect(LocalDb.schemaVersion, 71);
  });

  group('oldV < 71 rung on a v70 database holding rows', () {
    test('reaches 71, creates the objects, keeps every row byte for byte',
        () async {
      const name = 'p21_mig_v70_rows.db';
      await _seedV70(name);

      // Sanity: the fixture really is v70-shaped.
      final raw = await databaseFactory.openDatabase(await p21Path(name));
      expect(await p21UserVersion(raw), 70);
      expect(await p21TableExists(raw, 'row_rev'), isFalse);
      expect(await p21Triggers(raw), isEmpty);
      final before = {
        'dr': await raw.query('day_result', orderBy: 'day_id, algo_version'),
        'bl': await raw.query('baselines', orderBy: 'key'),
      };
      await raw.close();

      final db = await _open(name);

      expect(await p21UserVersion(db), 71);
      await _expectRevObjects(db);
      expect(await db.query('day_result', orderBy: 'day_id, algo_version'),
          before['dr']);
      expect(await db.query('baselines', orderBy: 'key'), before['bl']);
    });

    test('no backfill: pre-existing rows read revision 0 until written',
        () async {
      const name = 'p21_mig_v70_zero.db';
      await _seedV70(name);
      final db = await _open(name);
      await p21ExpectRevTables(db);

      expect(await db.query('row_rev'), isEmpty,
          reason: 'the rung is two tables and five triggers, nothing scanned');
      expect(await p21DayRev(db, _d1), 0);
      expect(await p21BaseRev(db, 'crossday'), 0);
      expect((await LocalDb.dayResultMeta(_d1))!['rev'], 0);

      // The first accepted write gives the row a real revision.
      await LocalDb.putDayResult(
        dayId: _d2,
        algoVersion: p21Version,
        payloadJson: p21Payload('two-again', day: _d2),
        windowJson: '{}',
      );
      expect(await p21DayRev(db, _d2), greaterThan(0));
      await LocalDb.putBaseline('crossday', '{"v":9}');
      expect(await p21BaseRev(db, 'crossday'), greaterThan(0));
      expect(await p21DayRev(db, _d1), 0, reason: 'untouched rows stay at 0');
    });

    test('the rung is idempotent: running it again over a 71 shape neither '
        'throws nor loses a revision', () async {
      const name = 'p21_mig_rerun.db';
      await _seedV70(name);
      var db = await _open(name);
      await p21ExpectRevTables(db);
      await LocalDb.putDayResult(
        dayId: _d2,
        algoVersion: p21Version,
        payloadJson: p21Payload('w', day: _d2),
        windowJson: '{}',
      );
      await LocalDb.putBaseline('crossday', '{"v":3}');
      final revs = await p21AllRevs(db);
      final sql = await p21RevObjectSql(db);
      final seq = await db.rawQuery(
        "SELECT seq FROM sqlite_sequence WHERE name = 'store_rev'",
      );
      expect(revs, isNotEmpty);

      // Stamp it back to 70 WITHOUT undoing anything: the rung runs over a
      // database that already has every object ("already exists" would roll
      // the whole ladder back and quarantine the file).
      await db.execute('PRAGMA user_version = 70');
      db = await _open(name);

      expect(await p21UserVersion(db), 71);
      expect(await p21AllRevs(db), revs);
      expect(await p21RevObjectSql(db), sql);
      expect(
        await db.rawQuery(
          "SELECT seq FROM sqlite_sequence WHERE name = 'store_rev'",
        ),
        seq,
        reason: 'the sequence must survive: revisions are never reused',
      );
    });

    test('a database upgraded from an old version never saw the triggers: its '
        'migrated day_result rows read revision 0', () async {
      // A v6 database holds derived_day; the ladder copies it into day_result
      // at rung 9, long before schema 71 and its triggers exist. The raw tables
      // are the shape v6 had (the same fixture db_migration_ladder_test uses).
      const name = 'p21_mig_from_v6.db';
      _created.add(name);
      await LocalDb.close();
      final path = await p21Path(name);
      await databaseFactory.deleteDatabase(path);
      final seed = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 6,
          onCreate: (d, _) async {
            await d.execute('''
              CREATE TABLE raw_records (
                hex TEXT PRIMARY KEY, counter INTEGER, packet_type INTEGER,
                captured_at INTEGER NOT NULL, rec_ts INTEGER NOT NULL DEFAULT 0,
                uploaded INTEGER NOT NULL DEFAULT 0)
            ''');
            await d.execute('''
              CREATE TABLE samples (
                counter INTEGER PRIMARY KEY, ts INTEGER NOT NULL, hr INTEGER)
            ''');
            await d.execute('''
              CREATE TABLE events (
                hex TEXT PRIMARY KEY, event_id INTEGER, ts INTEGER,
                captured_at INTEGER NOT NULL)
            ''');
            await d.execute('''
              CREATE TABLE derived_day (
                date TEXT PRIMARY KEY, payload_json TEXT NOT NULL,
                version INTEGER NOT NULL, last_raw_ts INTEGER NOT NULL,
                computed_at INTEGER NOT NULL, rhr REAL, rmssd REAL,
                readiness REAL)
            ''');
            await d.execute('''
              CREATE TABLE baselines (
                key TEXT PRIMARY KEY, payload_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL)
            ''');
            await d.execute('''
              CREATE TABLE metric_series (
                date TEXT NOT NULL, key TEXT NOT NULL, value REAL,
                PRIMARY KEY (date, key))
            ''');
          },
        ),
      );
      await seed.insert('derived_day', {
        'date': '2026-05-05',
        'payload_json': jsonEncode({'legacy': true}),
        'version': 1,
        'last_raw_ts': 1780000000,
        'computed_at': 1,
        'rhr': 55.0,
      });
      await seed.insert('baselines', {
        'key': 'old',
        'payload_json': '{}',
        'updated_at': 1,
      });
      await seed.close();

      final db = await _open(name);

      expect(await p21UserVersion(db), 71);
      await _expectRevObjects(db);
      expect((await LocalDb.dayResult('2026-05-05'))!['payload_json'],
          jsonEncode({'legacy': true}));
      expect(await db.query('row_rev'), isEmpty,
          reason: 'the legacy copy ran before the triggers existed');
      expect((await LocalDb.dayResultMeta('2026-05-05'))!['rev'], 0);
    });
  });

  group('_ensureStoreRevisions through the open path', () {
    test('a fresh database has the objects (onCreate)', () async {
      const name = 'p21_mig_fresh.db';
      _created.add(name);
      final db = await p21Fresh(name);
      expect(await p21UserVersion(db), 71);
      await _expectRevObjects(db);
    });

    test('reopening a complete 71 database changes nothing', () async {
      const name = 'p21_mig_reopen.db';
      _created.add(name);
      var db = await p21Fresh(name);
      await LocalDb.putDayResult(
        dayId: _d1,
        algoVersion: p21Version,
        payloadJson: p21Payload('a'),
        windowJson: '{}',
      );
      await LocalDb.putBaseline('k', '{}');
      final sql = await p21RevObjectSql(db);
      final revs = await p21AllRevs(db);
      expect(sql, isNotEmpty);

      for (var i = 0; i < 3; i++) {
        db = await _open(name);
        expect(await p21RevObjectSql(db), sql, reason: 'reopen #${i + 1}');
        expect(await p21AllRevs(db), revs, reason: 'reopen #${i + 1}');
      }
    });
  });

  group('_repairOpenSchema self-heals a 71 database', () {
    test('dropped triggers come back on the next open and work again',
        () async {
      const name = 'p21_mig_repair_triggers.db';
      _created.add(name);
      var db = await p21Fresh(name);
      await _expectRevObjects(db);
      final sql = await p21RevObjectSql(db);
      await p21DropRevTriggers(db);
      expect(await p21Triggers(db), isEmpty);
      // While they are gone a write leaves no revision, which is the hole the
      // repair closes.
      await p21RawDay(db, _d1);
      expect(await p21DayRev(db, _d1), 0);

      db = await _open(name);

      expect(await p21UserVersion(db), 71);
      expect(await p21RevObjectSql(db), sql);
      await p21RawDay(db, _d2);
      expect(await p21DayRev(db, _d2), greaterThan(0));
    });

    test('dropped tables and triggers are recreated empty, with no backfill',
        () async {
      const name = 'p21_mig_repair_tables.db';
      _created.add(name);
      var db = await p21Fresh(name);
      await p21RawDay(db, _d1);
      await p21DropRevTriggers(db);
      await db.execute('DROP TABLE IF EXISTS row_rev');
      await db.execute('DROP TABLE IF EXISTS store_rev');

      db = await _open(name);

      await _expectRevObjects(db);
      expect(await db.query('row_rev'), isEmpty);
      expect(await p21DayRev(db, _d1), 0);
      await p21RawDay(db, _d2);
      expect(await p21DayRev(db, _d2), greaterThan(0));
    });

    test('a missing row_rev alone is recreated and the triggers keep working',
        () async {
      const name = 'p21_mig_repair_rowrev.db';
      _created.add(name);
      var db = await p21Fresh(name);
      await db.execute('DROP TABLE IF EXISTS row_rev');
      db = await _open(name);
      await _expectRevObjects(db);
      await p21RawDay(db, _d1);
      expect(await p21DayRev(db, _d1), greaterThan(0));
    });
  });

  group('the triggers survive a day_result rebuild path', () {
    test('rebuilding the table drops its triggers; the next open recreates '
        'them and revisions carry on', () async {
      const name = 'p21_mig_rebuild_day_result.db';
      _created.add(name);
      var db = await p21Fresh(name);
      await p21RawDay(db, _d1, finalized: true);
      await p21RawDay(db, _d2);
      await p21ExpectRevTables(db);
      final revs = await p21AllRevs(db);
      final sql = await p21RevObjectSql(db);

      // The shape of a table rebuild: park the rows, drop the table (and its
      // triggers with it; views that name it dangle until it is back), create
      // it again from its own DDL, copy the rows back.
      final ddl = (await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type = 'table' "
        "AND name = 'day_result'",
      )).single['sql'] as String;
      await db.execute('CREATE TABLE day_result_parked AS SELECT * FROM day_result');
      await db.execute('DROP TABLE day_result');
      await db.execute(ddl);
      await db.execute('INSERT INTO day_result SELECT * FROM day_result_parked');
      await db.execute('DROP TABLE day_result_parked');
      expect(
        (await p21Triggers(db)).keys.where((k) => k.startsWith('day_result:')),
        isEmpty,
        reason: 'dropping the table dropped its triggers',
      );

      db = await _open(name);

      await _expectRevObjects(db);
      expect(await p21RevObjectSql(db), sql);
      expect(await p21AllRevs(db), revs,
          reason: 'row_rev is a separate table: the rebuild did not touch it');
      final before = await p21DayRev(db, _d1);
      await LocalDb.putDayResult(
        dayId: _d2,
        algoVersion: p21Version,
        payloadJson: p21Payload('post-rebuild', day: _d2),
        windowJson: '{}',
      );
      expect(await p21DayRev(db, _d2), greaterThan(before));
      expect(await p21DayRev(db, _d1), before);
    });
  });
}
