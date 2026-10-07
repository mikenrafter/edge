// `day_checkpoint`, schema 60 -> 61: the scratch table the incremental day
// derive resumes from. Additive, idempotent, no backfill (an empty table means
// "no checkpoint: run the full pass"), and disposable: nothing reads it for
// anything but speed.
//
// Real sqflite_ffi, same idiom as test/db_last_result_input_sig_schema_test.dart.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// A database as schema 60 left it: the last rung's column present, no
/// `day_checkpoint`, one unrelated row that must survive.
Future<void> _seedV60(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 60,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE last_result ('
                'key TEXT PRIMARY KEY, computed_at INTEGER NOT NULL, '
                'payload_json TEXT NOT NULL, input_sig TEXT)');
            await db.insert('last_result',
                {'key': 'k', 'computed_at': 7, 'payload_json': '{}'});
          }));
  await db.close();
}

Future<Database> _open(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  expect(LocalDb.lastRebuild, isNull,
      reason: 'the upgrade bricked and fell back to quarantine-and-rebuild: '
          '${LocalDb.lastRebuild?.cause}');
  return db;
}

Future<int> _userVersion(Database db) async =>
    ((await db.rawQuery('PRAGMA user_version')).first.values.first as num)
        .toInt();

Future<Map<String, Map<String, Object?>>> _cols(Database db) async => {
      for (final c in await db.rawQuery('PRAGMA table_info(day_checkpoint)'))
        c['name'] as String: c,
    };

void _expectShape(Map<String, Map<String, Object?>> cols) {
  expect(cols.keys.toSet(), {
    'day_id',
    'algo_version',
    'fmt',
    'ctx_sig',
    'cp_rec_ts',
    'rev_vec',
    'state',
    'night_ref',
    'computed_at',
  });
  for (final k in ['day_id', 'algo_version', 'fmt', 'ctx_sig', 'cp_rec_ts',
      'rev_vec', 'state', 'computed_at']) {
    expect(cols[k]!['notnull'], 1, reason: k);
  }
  expect(cols['night_ref']!['notnull'], 0);
  expect(cols['rev_vec']!['type'], 'BLOB');
  expect(cols['state']!['type'], 'BLOB');
  expect(cols['day_id']!['pk'], 1);
  expect(cols['algo_version']!['pk'], 2);
}

DayCheckpoint _cp(String day, int v,
        {int at = 100, List<int> state = const [1, 2, 3]}) =>
    DayCheckpoint(
      dayId: day,
      algoVersion: v,
      fmt: 1,
      ctxSig: 'sig-$day',
      cpRecTs: at,
      revVec: Uint8List.fromList([0, 0, 0, 5]),
      state: Uint8List.fromList(state),
      nightRef: null,
      computedAt: 9,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _path(n));
    }
  });

  test('schemaVersion is at least 61', () {
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(61));
  });

  test('upgrade from v60 creates the table, empty, and keeps other rows',
      () async {
    const name = 'openstrap_day_checkpoint_60.db';
    created.add(name);
    await _seedV60(name);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    expect(await db.query('day_checkpoint'), isEmpty,
        reason: 'no backfill: nothing to compute under the iOS watchdog');
    expect((await db.query('last_result')).single['computed_at'], 7);
  });

  test('the rung is idempotent over an already-61 shape', () async {
    const name = 'openstrap_day_checkpoint_rerun.db';
    created.add(name);
    await _seedV60(name);
    var db = await _open(name);
    await LocalDb.putDayCheckpoint(_cp('2026-10-06', 101));
    await db.execute('PRAGMA user_version = 60');
    db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    expect(await LocalDb.dayCheckpoint('2026-10-06', 101), isNotNull,
        reason: 'the rerun neither threw nor emptied the table');
  });

  test('self-heal: a current-version database without the table gets it on open',
      () async {
    const name = 'openstrap_day_checkpoint_heal.db';
    created.add(name);
    await _seedV60(name);
    var db = await _open(name);
    await db.execute('DROP TABLE day_checkpoint');
    db = await _open(name);
    _expectShape(await _cols(db));
  });

  test('a fresh install has it too', () async {
    const name = 'openstrap_day_checkpoint_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    _expectShape(await _cols(db));
  });

  group('accessors', () {
    setUp(() async {
      const name = 'openstrap_day_checkpoint_io.db';
      if (!created.contains(name)) created.add(name);
      await databaseFactory.deleteDatabase(await _path(name));
      await _open(name);
    });

    test('a checkpoint round-trips byte for byte', () async {
      final cp = _cp('2026-10-06', 101, state: List.generate(300, (i) => i % 256));
      await LocalDb.putDayCheckpoint(cp);
      final back = (await LocalDb.dayCheckpoint('2026-10-06', 101))!;
      expect(back.dayId, '2026-10-06');
      expect(back.algoVersion, 101);
      expect(back.fmt, 1);
      expect(back.ctxSig, 'sig-2026-10-06');
      expect(back.cpRecTs, 100);
      expect(back.revVec, cp.revVec);
      expect(back.state, cp.state);
      expect(back.nightRef, isNull);
      expect(back.computedAt, 9);
    });

    test('keyed by (day, algo version): a bump is a sibling, not an overwrite',
        () async {
      await LocalDb.putDayCheckpoint(_cp('2026-10-06', 101, at: 1));
      await LocalDb.putDayCheckpoint(_cp('2026-10-06', 102, at: 2));
      expect((await LocalDb.dayCheckpoint('2026-10-06', 101))!.cpRecTs, 1);
      expect((await LocalDb.dayCheckpoint('2026-10-06', 102))!.cpRecTs, 2);
      expect(await LocalDb.dayCheckpoint('2026-10-06', 103), isNull);
      expect(await LocalDb.dayCheckpoint('2026-10-05', 101), isNull);
    });

    test('writing the same key replaces it', () async {
      await LocalDb.putDayCheckpoint(_cp('2026-10-06', 101, at: 1));
      await LocalDb.putDayCheckpoint(_cp('2026-10-06', 101, at: 5, state: [9]));
      final back = (await LocalDb.dayCheckpoint('2026-10-06', 101))!;
      expect(back.cpRecTs, 5);
      expect(back.state, [9]);
      final db = await LocalDb.instance;
      expect(await db.query('day_checkpoint'), hasLength(1));
    });

    test('deleteDayCheckpoints drops every version of one day only', () async {
      await LocalDb.putDayCheckpoint(_cp('2026-10-06', 101));
      await LocalDb.putDayCheckpoint(_cp('2026-10-06', 102));
      await LocalDb.putDayCheckpoint(_cp('2026-10-05', 101));
      await LocalDb.deleteDayCheckpoints('2026-10-06');
      expect(await LocalDb.dayCheckpoint('2026-10-06', 101), isNull);
      expect(await LocalDb.dayCheckpoint('2026-10-06', 102), isNull);
      expect(await LocalDb.dayCheckpoint('2026-10-05', 101), isNotNull);
    });

    test('pruneDayCheckpoints keeps only the named days', () async {
      for (final d in ['2026-10-04', '2026-10-05', '2026-10-06']) {
        await LocalDb.putDayCheckpoint(_cp(d, 101));
      }
      await LocalDb.pruneDayCheckpoints(keepDays: {'2026-10-06'});
      expect(await LocalDb.dayCheckpoint('2026-10-04', 101), isNull);
      expect(await LocalDb.dayCheckpoint('2026-10-05', 101), isNull);
      expect(await LocalDb.dayCheckpoint('2026-10-06', 101), isNotNull);
    });
  });
}
