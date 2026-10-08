// `moment_label`, schema 63 -> 64.
//
// ASSUMED (lib/data/db.dart):
//   * `LocalDb.schemaVersion` was 64 when this rung was added (66 since the ECG result column).
//   * A new table
//       moment_label(date TEXT NOT NULL, hhmm TEXT NOT NULL, label TEXT,
//                    note TEXT, answered_at INTEGER NOT NULL,
//                    PRIMARY KEY (date, hhmm))
//     label is NULL for a skip. Additive: the journal and everything else is
//     untouched.
//   * Created from BOTH the `if (oldV < 64)` rung AND `_repairOpenSchema`
//     (invariant 11: idempotent, same-version merged builds self-heal).
//
// Real sqflite_ffi, same idiom as test/db_last_result_input_sig_schema_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/moment_label.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// A database exactly as schema 63 left the part this touches: a journal day
/// holding a marked-moment tag, and no `moment_label`.
Future<void> _seedV63(String name) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
          version: 63,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE journal ('
                'date TEXT PRIMARY KEY, tags_json TEXT NOT NULL DEFAULT \'[]\', '
                'note TEXT NOT NULL DEFAULT \'\', updated_at INTEGER NOT NULL)');
            await db.insert('journal', {
              'date': '2026-10-06',
              'tags_json': '["moment 10:15"]',
              'note': 'n',
              'updated_at': 1,
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

Future<Map<String, Map<String, Object?>>> _cols(Database db) async => {
      for (final c in await db.rawQuery('PRAGMA table_info(moment_label)'))
        c['name'] as String: c,
    };

void _expectShape(Map<String, Map<String, Object?>> cols) {
  expect(cols.keys.toSet(), {'date', 'hhmm', 'label', 'note', 'answered_at'});
  expect(cols['date']!['type'], 'TEXT');
  expect(cols['date']!['notnull'], 1);
  expect(cols['date']!['pk'], 1);
  expect(cols['hhmm']!['type'], 'TEXT');
  expect(cols['hhmm']!['notnull'], 1);
  expect(cols['hhmm']!['pk'], 2);
  expect(cols['label']!['notnull'], 0, reason: 'NULL label = skipped');
  expect(cols['note']!['notnull'], 0);
  expect(cols['answered_at']!['type'], 'INTEGER');
  expect(cols['answered_at']!['notnull'], 1);
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

  test('schemaVersion is at least 64 (66 since the ECG result column)', () {
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(64));
  });

  test('upgrade from v63 reaches 64, adds moment_label empty, keeps the '
      'journal', () async {
    const name = 'openstrap_moment_label_63.db';
    created.add(name);
    await _seedV63(name);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    expect(await db.query('moment_label'), isEmpty,
        reason: 'no backfill: no row means unanswered');
    final j = await db.query('journal');
    expect(j.single['tags_json'], '["moment 10:15"]');
    expect(j.single['note'], 'n');
  });

  test('the rung is idempotent: running 63 -> 64 over an already-64 shape '
      'neither throws nor loses the answers', () async {
    const name = 'openstrap_moment_label_rerun.db';
    created.add(name);
    await _seedV63(name);
    var db = await _open(name);
    await db.insert('moment_label', {
      'date': '2026-10-06',
      'hhmm': '10:15',
      'label': 'nap',
      'note': null,
      'answered_at': 5,
    });
    // Stamp it back WITHOUT undoing anything: the rung runs again over a table
    // that already exists.
    await db.execute('PRAGMA user_version = 63');
    db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    final rows = await db.query('moment_label');
    expect(rows.single['label'], 'nap', reason: 'data survived the rerun');
  });

  test('self-heal: a v64 database that lost the table gets it back on open',
      () async {
    const name = 'openstrap_moment_label_heal.db';
    created.add(name);
    await _seedV63(name);
    var db = await _open(name);
    await db.execute('DROP TABLE moment_label');
    db = await _open(name); // same version: onOpen repair only
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
  });

  test('a fresh install has the table (onCreate path)', () async {
    const name = 'openstrap_moment_label_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    expect(await db.query('moment_label'), isEmpty);
  });

  test('one row per moment: a second answer for the same (date, hhmm) is '
      'not a second row', () async {
    const name = 'openstrap_moment_label_pk.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    const a = MomentLabel(
        date: '2026-10-06', hhmm: '10:15', label: 'nap', answeredAtMs: 1);
    await LocalDb.putMomentLabel(a);
    await LocalDb.putMomentLabel(a);
    expect(await db.query('moment_label'), hasLength(1));
  });

  test('momentLabels reads back what was put, by day and since', () async {
    const name = 'openstrap_moment_label_read.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    await _open(name);
    await LocalDb.putMomentLabel(const MomentLabel(
        date: '2026-10-05', hhmm: '08:00', label: 'meal', answeredAtMs: 1));
    await LocalDb.putMomentLabel(const MomentLabel(
        date: '2026-10-06', hhmm: '10:15',
        label: 'other', note: 'x', answeredAtMs: 2));
    await LocalDb.putMomentLabel(const MomentLabel(
        date: '2026-10-06', hhmm: '11:00', answeredAtMs: 3));
    expect(await LocalDb.momentLabels(), hasLength(3));
    final day = await LocalDb.momentLabels(date: '2026-10-06');
    expect([for (final l in day) l.hhmm], ['10:15', '11:00']);
    expect(day.first.note, 'x');
    expect(day.last.label, isNull);
    expect(await LocalDb.momentLabels(sinceDate: '2026-10-06'), hasLength(2));
  });
}
