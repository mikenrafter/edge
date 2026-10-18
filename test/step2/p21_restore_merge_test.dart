// P2.1 restore and merge, design 02 step 2, sections 4.1 and 4.2.
//
// ASSUMED: both merge paths, `importFromDbFile` (user restore) and the
// `_openOrRebuild` tolerant salvage, go through `_mergeFromDbFile`, which writes
// `day_result` and `baselines` with a raw `batch.insert(..., replace)`. The
// insert triggers therefore give every copied row a fresh LOCAL revision.
//
//   * A foreign export carries no revision we can trust, so `row_rev` and
//     `store_rev` are NOT in the restore table list: a v71 source whose own
//     `row_rev` is populated contributes none of it. Its revisions are a
//     different device's sequence and would collide with, or even exceed, ours.
//   * Rows the merge skips (a locally FINALIZED `day_result` row is never
//     overwritten by an import) keep their revision.
//   * A salvage in which one table fails leaves `row_rev` consistent with the
//     rows that DID land.
//
// The foreign files use revisions from 9000 up (`p21ForeignRevBase`), far above
// anything the local sequence reaches here, so a copied revision is recognisable.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

import 'support/p21_support.dart';

const _name = 'p21_restore_merge.db';
const _foreign = 'p21_restore_merge_foreign.db';
const _x = '2026-03-10'; // local, provisional: the import replaces it
const _y = '2026-03-11'; // local, FINALIZED: the import must skip it
const _z = '2026-03-12'; // only in the export

Future<int> _dayCount(Database db) async =>
    (await db.rawQuery('SELECT COUNT(*) AS c FROM day_result')).single['c']
        as int;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async => db = await p21Fresh(_name));
  tearDown(() async {
    await p21Drop(_name);
    await databaseFactory.deleteDatabase(await p21Path(_foreign));
  });

  group('importFromDbFile', () {
    late int xBefore;
    late int yBefore;
    late int kBefore;
    late int highestBefore;

    Future<String> seedAndExport() async {
      await LocalDb.putDayResult(
        dayId: _x,
        algoVersion: p21Version,
        payloadJson: p21Payload('local-x', day: _x),
        windowJson: '{}',
      );
      await LocalDb.putDayResult(
        dayId: _y,
        algoVersion: p21Version,
        payloadJson: p21Payload('local-y', day: _y),
        windowJson: '{}',
        finalized: true,
      );
      await LocalDb.putBaseline('k', '{"from":"local"}');
      xBefore = await p21DayRev(db, _x);
      yBefore = await p21DayRev(db, _y);
      kBefore = await p21BaseRev(db, 'k');
      highestBefore = (await p21AllRevs(db)).values.reduce((a, b) => a > b ? a : b);
      expect(highestBefore, lessThan(p21ForeignRevBase));
      return p21MakeForeignExport(
        _foreign,
        days: [
          (day: _x, version: p21Version, tag: 'foreign-x', finalized: false),
          (day: _y, version: p21Version, tag: 'foreign-y', finalized: false),
          (day: _z, version: p21Version, tag: 'foreign-z', finalized: false),
        ],
        baselines: [
          (key: 'k', payload: '{"from":"foreign"}'),
          (key: 'k2', payload: '{"from":"foreign"}'),
        ],
      );
    }

    test('replaced rows get fresh LOCAL revisions, newer than everything before',
        () async {
      final src = await seedAndExport();

      await LocalDb.importFromDbFile(src);

      final x = await p21DayRev(db, _x);
      final z = await p21DayRev(db, _z);
      final k = await p21BaseRev(db, 'k');
      final k2 = await p21BaseRev(db, 'k2');
      for (final r in [x, z, k, k2]) {
        expect(r, greaterThan(highestBefore), reason: 'a fresh local revision');
        expect(r, lessThan(p21ForeignRevBase), reason: 'not the export\'s number');
      }
      expect(x, greaterThan(xBefore));
      expect(k, greaterThan(kBefore));
      expect({x, z, k, k2}, hasLength(4), reason: 'revisions are unique');
      // And the replacement really is the foreign payload.
      expect(
        (await db.query('day_result', where: 'day_id = ?', whereArgs: [_x]))
            .single['payload_json'],
        contains('foreign-x'),
      );
      expect((await LocalDb.baseline('k'))!['payload_json'], '{"from":"foreign"}');
    });

    test('row_rev is not copied: no foreign number and no orphan key lands',
        () async {
      final src = await seedAndExport();

      await LocalDb.importFromDbFile(src);

      final revs = await p21AllRevs(db);
      expect(
        revs.values.where((r) => r >= p21ForeignRevBase),
        isEmpty,
        reason: 'a foreign revision reached row_rev: $revs',
      );
      expect(revs.containsKey('day_result|2001-01-01|$p21Version'), isFalse,
          reason: 'the export\'s revision row for a day it does not contain');
      await p21ExpectRevsConsistent(db);
    });

    test('a locally finalized row the merge skips keeps its revision and its '
        'payload', () async {
      final src = await seedAndExport();

      await LocalDb.importFromDbFile(src);

      expect(await p21DayRev(db, _y), yBefore);
      expect(
        (await db.query('day_result', where: 'day_id = ?', whereArgs: [_y]))
            .single['payload_json'],
        contains('local-y'),
      );
      expect(await _dayCount(db), 3);
    });

    test('importing the same file twice moves the revisions again, never back',
        () async {
      final src = await seedAndExport();
      await LocalDb.importFromDbFile(src);
      final first = await p21AllRevs(db);

      await LocalDb.importFromDbFile(src);
      final second = await p21AllRevs(db);

      expect(second.keys.toSet(), first.keys.toSet());
      for (final k in first.keys) {
        if (k == 'day_result|$_y|$p21Version') {
          expect(second[k], first[k], reason: 'the skipped row never moves');
        } else {
          expect(second[k], greaterThan(first[k]!), reason: k);
        }
      }
    });

    test('a source with no row_rev at all (an export from a v70 build) merges '
        'the same way', () async {
      await LocalDb.putDayResult(
        dayId: _x,
        algoVersion: p21Version,
        payloadJson: p21Payload('local-x', day: _x),
        windowJson: '{}',
      );
      final before = await p21DayRev(db, _x);
      final src = await p21MakeForeignExport(
        _foreign,
        withRowRev: false,
        days: [
          (day: _x, version: p21Version, tag: 'foreign-x', finalized: false),
          (day: _z, version: p21Version, tag: 'foreign-z', finalized: false),
        ],
      );

      await LocalDb.importFromDbFile(src);

      expect(await p21DayRev(db, _x), greaterThan(before));
      expect(await p21DayRev(db, _z), greaterThan(0));
      await p21ExpectRevsConsistent(db);
    });
  });

  group('the _openOrRebuild salvage', () {
    const bricked = 'p21_restore_merge_bricked.db';

    tearDown(() async {
      await p21Drop(bricked);
      for (final f in Directory(await databaseFactory.getDatabasesPath())
          .listSync()) {
        if (f is File && f.path.contains('$bricked.unopenable')) f.deleteSync();
      }
    });

    /// A schema-2 file whose `metric_series` has the wrong shape (so the ladder
    /// throws and the open is quarantined), holding v71-style revision data.
    /// With [breakBaselines], its `baselines` table cannot be merged: it lacks
    /// the NOT NULL `payload_json` the live table demands.
    Future<void> seedBricked({bool breakBaselines = false}) async {
      await LocalDb.close();
      final path = await p21Path(bricked);
      await databaseFactory.deleteDatabase(path);
      final seed = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (d, _) async {
            await d.execute('CREATE TABLE metric_series (bogus INTEGER)');
            await d.execute('''
              CREATE TABLE day_result (
                day_id TEXT NOT NULL, algo_version INTEGER NOT NULL,
                payload_json TEXT NOT NULL,
                window_json TEXT NOT NULL DEFAULT '{}',
                computed_at INTEGER NOT NULL,
                finalized INTEGER NOT NULL DEFAULT 0,
                rhr REAL, rmssd REAL, readiness REAL,
                skipped INTEGER NOT NULL DEFAULT 0,
                partial INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (day_id, algo_version))
            ''');
            await d.execute(
              breakBaselines
                  ? 'CREATE TABLE baselines (key TEXT PRIMARY KEY)'
                  : 'CREATE TABLE baselines (key TEXT PRIMARY KEY, '
                      'payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)',
            );
            await d.execute(
              'CREATE TABLE store_rev (id INTEGER PRIMARY KEY AUTOINCREMENT)',
            );
            await d.execute('''
              CREATE TABLE row_rev (
                kind TEXT NOT NULL, k1 TEXT NOT NULL,
                k2 INTEGER NOT NULL DEFAULT 0, rev INTEGER NOT NULL,
                PRIMARY KEY (kind, k1, k2)) WITHOUT ROWID
            ''');
          },
        ),
      );
      var rev = p21ForeignRevBase;
      for (final d in [_x, _y]) {
        await seed.insert('day_result', {
          'day_id': d,
          'algo_version': p21Version,
          'payload_json': p21Payload('salvaged-$d', day: d),
          'window_json': '{}',
          'computed_at': 5000,
          'finalized': 1,
        });
        await seed.insert('row_rev', {
          'kind': 'day_result',
          'k1': d,
          'k2': p21Version,
          'rev': ++rev,
        });
      }
      if (breakBaselines) {
        await seed.insert('baselines', {'key': 'k'});
      } else {
        await seed.insert('baselines', {
          'key': 'k',
          'payload_json': '{"salvaged":true}',
          'updated_at': 5000,
        });
      }
      await seed.insert('row_rev', {
        'kind': 'baselines',
        'k1': 'k',
        'k2': 0,
        'rev': ++rev,
      });
      await seed.close();
    }

    Future<Database> rebuild() async {
      LocalDb.lastRebuild = null;
      LocalDb.dbName = bricked;
      final d = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNotNull, reason: 'the open really bricked');
      return d;
    }

    test('salvaged rows get fresh local revisions and the quarantined row_rev '
        'is not copied', () async {
      await seedBricked();

      final d = await rebuild();

      expect(LocalDb.lastRebuild!.salvaged['day_result'], 2);
      expect(LocalDb.lastRebuild!.salvaged['baselines'], 1);
      final revs = await p21AllRevs(d);
      expect(revs.values.where((r) => r >= p21ForeignRevBase), isEmpty,
          reason: '$revs');
      expect(revs.keys.toSet(), {
        'day_result|$_x|$p21Version',
        'day_result|$_y|$p21Version',
        'baselines|k|0',
      });
      expect(revs.values.toSet(), hasLength(3), reason: 'unique');
      await p21ExpectRevsConsistent(d);
    });

    test('a salvage in which one table fails leaves the others consistent',
        () async {
      await seedBricked(breakBaselines: true);

      final d = await rebuild();

      expect(LocalDb.lastRebuild!.salvaged['day_result'], 2);
      expect(LocalDb.lastRebuild!.salvaged['baselines'] ?? 0, 0,
          reason: 'the broken table is lost, tolerantly');
      expect(await d.query('baselines'), isEmpty);
      final revs = await p21AllRevs(d);
      expect(revs.keys.toSet(), {
        'day_result|$_x|$p21Version',
        'day_result|$_y|$p21Version',
      }, reason: 'no revision row for a baseline that did not land');
      expect(revs.values.where((r) => r >= p21ForeignRevBase), isEmpty);
      await p21ExpectRevsConsistent(d);
    });
  });
}
