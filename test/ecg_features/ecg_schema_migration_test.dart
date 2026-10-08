// ECG features, phase 1 (RED): the additive, idempotent migration for the
// ECG result store, schema 65 -> 66.
//
// ASSUMED (lib/data/db.dart):
//   * LocalDb.schemaVersion >= 66. The ECG rung is `if (oldV < 66)`. This
//     branch's cumulative base is 65 (assumed_water + symptom_entry); if
//     another feature merges first and takes 66 the ECG rung moves up and
//     nothing else here changes: the assertions below are on the column, not
//     on the number.
//   * One new nullable column, `ecg_reading.stop_reason TEXT` (why a partial
//     stopped: 'paused' | 'timeout'). NO new table: a result is an
//     `ecg_reading` row, its state is the existing `status` column (now also
//     'partial'), its metrics are the existing nullable `avg_hr` / `quality`.
//     The waveform is the existing `ecg_reading_packet` rows, present only when
//     kept.
//   * Added through `_createEcgTables` (CREATE ... IF NOT EXISTS +
//     `_addColumnIfMissing`), so the `oldV < 66` rung and `_repairOpenSchema`
//     share one definition and a re-run is a no-op (invariant 11). No backfill,
//     nothing read: cheap under iOS's CPU watchdog. No kAlgoVersion bump:
//     nothing derived moves.
//
// Real sqflite_ffi, same idiom as test/gestures/moments/label_migration_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

// ecg_reading exactly as schema 65 left it: no stop_reason.
const _legacyReading = '''
CREATE TABLE ecg_reading (
  id TEXT PRIMARY KEY, device_id TEXT NOT NULL, source TEXT NOT NULL,
  wrist TEXT NOT NULL, start_ts INTEGER NOT NULL, end_ts INTEGER NOT NULL,
  strap_terminal_ts INTEGER, strap_terminal_subsec INTEGER,
  result_code INTEGER NOT NULL, category TEXT NOT NULL, avg_hr INTEGER,
  quality INTEGER, unreadable_mask INTEGER NOT NULL DEFAULT 0,
  interruptions INTEGER NOT NULL DEFAULT 0,
  sample_rate_hz INTEGER NOT NULL DEFAULT 100,
  sample_unit TEXT NOT NULL DEFAULT 'filtered_input_referred_uv',
  sample_count INTEGER NOT NULL, min_uv INTEGER, max_uv INTEGER, rms_uv REAL,
  missing_segments INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL,
  notes TEXT, created_at INTEGER NOT NULL)''';

Future<void> _seed(String name, {required int version, bool withColumn = false}) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        await db.execute(_legacyReading);
        if (withColumn) {
          await db.execute('ALTER TABLE ecg_reading ADD COLUMN stop_reason TEXT');
        }
        await db.insert('ecg_reading', {
          'id': 'legacy1', 'device_id': '', 'source': 'mg_labrador',
          'wrist': 'left', 'start_ts': 1787823754, 'end_ts': 1787823784,
          'result_code': 1, 'category': 'sinusRhythm', 'avg_hr': 77,
          'quality': 3, 'sample_count': 3000, 'status': 'completed',
          'created_at': 1787823784000,
        });
      },
    ),
  );
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

Future<List<Map<String, Object?>>> _stopReasonCols(Database db) async => [
  for (final c in await db.rawQuery('PRAGMA table_info(ecg_reading)'))
    if (c['name'] == 'stop_reason') c,
];

void _expectShape(List<Map<String, Object?>> cols) {
  expect(cols, hasLength(1), reason: 'exactly one stop_reason column');
  expect(cols.single['type'], 'TEXT');
  expect(cols.single['notnull'], 0, reason: 'NULL = not a partial');
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

  test('schemaVersion is at least 66', () {
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(66));
  });

  test('upgrade from v65 reaches the live version, adds stop_reason, keeps '
      'the legacy reading readable', () async {
    const name = 'openstrap_ecg_result_65.db';
    created.add(name);
    await _seed(name, version: 65);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _stopReasonCols(db));
    final row = (await LocalDb.ecgReading('legacy1'))!;
    expect(row['stop_reason'], isNull, reason: 'no backfill');
    final back = EcgReading.fromRow(row)!;
    expect(back.status, EcgReadingStatus.completed);
    expect(back.avgHr, 77);
    expect(back.stopReason, isNull);
  });

  test('a database that ALREADY has the column (a same-version merged build) '
      'upgrades without error and still has exactly one', () async {
    const name = 'openstrap_ecg_result_65_has_col.db';
    created.add(name);
    await _seed(name, version: 65, withColumn: true);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _stopReasonCols(db));
    expect(await db.query('ecg_reading'), hasLength(1));
  });

  test('re-opening at the live version (the every-open repair) is a no-op: '
      'one column, the row untouched, every time', () async {
    const name = 'openstrap_ecg_result_reopen.db';
    created.add(name);
    await _seed(name, version: 65);
    for (var i = 0; i < 3; i++) {
      final db = await _open(name);
      _expectShape(await _stopReasonCols(db));
      expect(await db.query('ecg_reading'), hasLength(1), reason: 'open #$i');
      expect((await LocalDb.ecgReading('legacy1'))!['avg_hr'], 77);
    }
  });

  test('a fresh install has the column and the three ECG tables too', () async {
    const name = 'openstrap_ecg_result_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    _expectShape(await _stopReasonCols(db));
    expect(await LocalDb.tableNames(),
        containsAll(['ecg_reading', 'ecg_reading_packet', 'ecg_raw_packet']));
    expect((await LocalDb.schemaHealth())['ok'], isTrue);
  });
}
