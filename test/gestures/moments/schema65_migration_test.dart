// Schema 64 -> 65: `assumed_water` and `symptom_entry` (RED).
//
// ASSUMED (lib/data/db.dart), one rung for both features:
//   * `LocalDb.schemaVersion == 65` (was 64 when this was written).
//   * assumed_water(date TEXT NOT NULL, at_min INTEGER NOT NULL,
//                   ml REAL NOT NULL, state TEXT NOT NULL DEFAULT 'assumed',
//                   logged_at INTEGER NOT NULL, PRIMARY KEY (date, at_min))
//     state: assumed | kept | removed (removed rows are tombstones).
//   * symptom_entry(date TEXT NOT NULL, hhmm TEXT NOT NULL,
//                   severity TEXT NOT NULL, side TEXT, kind TEXT NOT NULL,
//                   kind_other TEXT, area TEXT NOT NULL, area_other TEXT,
//                   note TEXT, created_at INTEGER NOT NULL,
//                   PRIMARY KEY (date, hhmm))
//   * Both created from the `if (oldV < 65)` rung AND `_repairOpenSchema`
//     (invariant 11: additive, idempotent, no backfill, cheap under the iOS
//     watchdog). No kAlgoVersion bump: nothing derived moves.
//
// Real sqflite_ffi, same idiom as label_migration_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// A database as schema 64 left the parts this touches.
Future<void> _seedV64(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 64,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE journal ('
                'date TEXT PRIMARY KEY, tags_json TEXT NOT NULL DEFAULT \'[]\', '
                'note TEXT NOT NULL DEFAULT \'\', updated_at INTEGER NOT NULL)');
            await db.execute('CREATE TABLE journal_metric ('
                'date TEXT NOT NULL, field TEXT NOT NULL, value REAL NOT NULL, '
                'at_min INTEGER, updated_at INTEGER NOT NULL, '
                'PRIMARY KEY (date, field))');
            await db.execute('CREATE TABLE moment_label ('
                'date TEXT NOT NULL, hhmm TEXT NOT NULL, label TEXT, note TEXT, '
                'answered_at INTEGER NOT NULL, PRIMARY KEY (date, hhmm))');
            await db.insert('journal', {
              'date': '2026-10-06',
              'tags_json': '["moment 10:15"]',
              'note': 'n',
              'updated_at': 1,
            });
            await db.insert('journal_metric', {
              'date': '2026-10-06',
              'field': 'water_ml',
              'value': 500,
              'at_min': 480,
              'updated_at': 1,
            });
            await db.insert('moment_label', {
              'date': '2026-10-06',
              'hhmm': '10:15',
              'label': 'symptom',
              'note': null,
              'answered_at': 2,
            });
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

Future<Map<String, Map<String, Object?>>> _cols(Database db, String t) async => {
      for (final c in await db.rawQuery('PRAGMA table_info($t)'))
        c['name'] as String: c,
    };

Future<void> _expectShapes(Database db) async {
  final a = await _cols(db, 'assumed_water');
  expect(a.keys.toSet(), {'date', 'at_min', 'ml', 'state', 'logged_at'});
  expect(a['date']!['type'], 'TEXT');
  expect(a['date']!['pk'], 1);
  expect(a['at_min']!['type'], 'INTEGER');
  expect(a['at_min']!['pk'], 2);
  expect(a['ml']!['type'], 'REAL');
  expect(a['ml']!['notnull'], 1);
  expect(a['state']!['notnull'], 1);
  expect(a['state']!['dflt_value'], "'assumed'");
  expect(a['logged_at']!['notnull'], 1);

  final s = await _cols(db, 'symptom_entry');
  expect(s.keys.toSet(), {
    'date', 'hhmm', 'severity', 'side', 'kind', 'kind_other', 'area',
    'area_other', 'note', 'created_at',
  });
  expect(s['date']!['pk'], 1);
  expect(s['hhmm']!['pk'], 2);
  for (final k in ['severity', 'kind', 'area', 'created_at']) {
    expect(s[k]!['notnull'], 1, reason: k);
  }
  for (final k in ['side', 'kind_other', 'area_other', 'note']) {
    expect(s[k]!['notnull'], 0, reason: '$k is optional');
  }
}

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

  test('schemaVersion is at least 65 (66 since the ECG result column)', () {
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(65));
  });

  test('upgrade from v64 reaches 65, adds both tables empty, keeps every '
      'existing row', () async {
    const name = 'openstrap_schema65_up.db';
    created.add(name);
    await _seedV64(name);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    await _expectShapes(db);
    expect(await db.query('assumed_water'), isEmpty,
        reason: 'no backfill: no row means nothing was assumed');
    expect(await db.query('symptom_entry'), isEmpty);
    expect((await db.query('journal')).single['note'], 'n');
    expect((await db.query('journal_metric')).single['value'], 500);
    expect((await db.query('moment_label')).single['label'], 'symptom');
  });

  test('the rung is idempotent: re-running it over existing tables loses '
      'nothing', () async {
    const name = 'openstrap_schema65_rerun.db';
    created.add(name);
    await _seedV64(name);
    var db = await _open(name);
    await db.insert('assumed_water', {
      'date': '2026-10-06',
      'at_min': 600,
      'ml': 250,
      'state': 'kept',
      'logged_at': 5,
    });
    await db.insert('symptom_entry', {
      'date': '2026-10-06',
      'hhmm': '10:15',
      'severity': 'mild',
      'side': null,
      'kind': 'pain',
      'kind_other': null,
      'area': 'neck',
      'area_other': null,
      'note': null,
      'created_at': 6,
    });
    await db.execute('PRAGMA user_version = 64');
    db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    await _expectShapes(db);
    expect((await db.query('assumed_water')).single['state'], 'kept');
    expect((await db.query('symptom_entry')).single['area'], 'neck');
  });

  test('self-heal: a v65 database that lost either table gets it back on '
      'open', () async {
    const name = 'openstrap_schema65_heal.db';
    created.add(name);
    await _seedV64(name);
    var db = await _open(name);
    await db.execute('DROP TABLE assumed_water');
    await db.execute('DROP TABLE symptom_entry');
    db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    await _expectShapes(db);
  });

  test('a fresh install has both tables (onCreate path)', () async {
    const name = 'openstrap_schema65_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    await _expectShapes(db);
  });

  test('one row per slot and per moment: a duplicate key is refused by the '
      'table itself', () async {
    const name = 'openstrap_schema65_pk.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    final glass = {
      'date': '2026-10-06',
      'at_min': 600,
      'ml': 250,
      'state': 'assumed',
      'logged_at': 1,
    };
    await db.insert('assumed_water', glass);
    await expectLater(db.insert('assumed_water', glass), throwsA(anything));
    final symptom = {
      'date': '2026-10-06',
      'hhmm': '10:15',
      'severity': 'mild',
      'kind': 'pain',
      'area': 'neck',
      'created_at': 1,
    };
    await db.insert('symptom_entry', symptom);
    await expectLater(db.insert('symptom_entry', symptom), throwsA(anything));
  });
}
