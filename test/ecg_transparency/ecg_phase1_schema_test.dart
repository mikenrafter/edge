// Design 04 phase 1 (RED) - item 3: the additive, idempotent migration for the
// ECG attempt groups and provenance. The cumulative branch is at schema 69
// (the sample archive took 67-69), so this is rung 70; the assertions are on
// the columns and on LocalDb.schemaVersion, never on a literal that will drift.
//
// ASSUMED (lib/data/db.dart):
//   * LocalDb.schemaVersion >= 70, rung `if (oldV < 70)`.
//   * ten nullable columns on ecg_reading: mask_any INTEGER, superseded_by
//     TEXT, attempt_group TEXT, attempt INTEGER, live_hr INTEGER,
//     variability_raw INTEGER (NULL for the wire's 0xffff), firmware_version
//     TEXT, capture_app_version TEXT, capture_table_version INTEGER,
//     start_offset_min INTEGER; and an index over (attempt_group, attempt).
//   * ONE idempotent creator `_ensureEcgPhase1Columns`, called from the rung
//     AND from `_repairOpenSchema` (invariant 11): same-version merged builds
//     self-heal, a repeated open is a no-op, no backfill (cheap under iOS's
//     CPU watchdog), no kAlgoVersion bump.
//   * legacy rows and their packets are untouched; their new columns are NULL
//     ("not recorded"), never inferred.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

const _newCols = <String, String>{
  'mask_any': 'INTEGER',
  'superseded_by': 'TEXT',
  'attempt_group': 'TEXT',
  'attempt': 'INTEGER',
  'live_hr': 'INTEGER',
  'variability_raw': 'INTEGER',
  'firmware_version': 'TEXT',
  'capture_app_version': 'TEXT',
  'capture_table_version': 'INTEGER',
  'start_offset_min': 'INTEGER',
};

// ecg_reading exactly as schema 69 left it (66 added stop_reason).
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
  notes TEXT, created_at INTEGER NOT NULL, stop_reason TEXT)''';

const _legacyPacket = '''
CREATE TABLE ecg_reading_packet (
  reading_id TEXT NOT NULL, ordinal INTEGER NOT NULL, sequence INTEGER NOT NULL,
  strap_seconds INTEGER, strap_subsec INTEGER, sample_count INTEGER NOT NULL,
  samples BLOB NOT NULL, inner_hex TEXT NOT NULL,
  is_placeholder INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (reading_id, ordinal))''';

Future<void> _seed(
  String name, {
  required int version,
  Iterable<String> withColumns = const [],
}) async {
  final path = await _path(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        await db.execute(_legacyReading);
        await db.execute(_legacyPacket);
        for (final c in withColumns) {
          await db.execute('ALTER TABLE ecg_reading ADD COLUMN $c ${_newCols[c]}');
        }
        await db.insert('ecg_reading', {
          'id': 'legacy1', 'device_id': '', 'source': 'mg_labrador',
          'wrist': 'left', 'start_ts': 1787823754, 'end_ts': 1787823784,
          'result_code': 1, 'category': 'sinusRhythm', 'avg_hr': 77,
          'quality': 3, 'sample_count': 3000, 'status': 'completed',
          'created_at': 1787823784000,
        });
        await db.insert('ecg_reading_packet', {
          'reading_id': 'legacy1', 'ordinal': 0, 'sequence': 1,
          'strap_seconds': 1787823755, 'strap_subsec': 0, 'sample_count': 2,
          'samples': Uint8List.fromList([1, 0, 2, 0]), 'inner_hex': 'deadbeef',
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
    ((await db.rawQuery('PRAGMA user_version')).first.values.first as num).toInt();

Future<Map<String, Map<String, Object?>>> _cols(Database db) async => {
  for (final c in await db.rawQuery('PRAGMA table_info(ecg_reading)'))
    c['name']! as String: c,
};

void _expectShape(Map<String, Map<String, Object?>> cols) {
  for (final e in _newCols.entries) {
    final c = cols[e.key];
    expect(c, isNotNull, reason: 'column ${e.key} exists');
    expect(c!['type'], e.value, reason: e.key);
    expect(c['notnull'], 0, reason: '${e.key}: NULL = not recorded');
  }
  expect(cols.keys.where(_newCols.containsKey).length, _newCols.length,
      reason: 'each exactly once');
}

Future<void> _expectIndex(Database db) async {
  final idx = await db.rawQuery("PRAGMA index_list('ecg_reading')");
  var found = false;
  for (final i in idx) {
    final info = await db.rawQuery("PRAGMA index_info('${i['name']}')");
    final names = [for (final c in info) c['name']];
    if (names.length == 2 && names[0] == 'attempt_group' && names[1] == 'attempt') {
      found = true;
    }
  }
  expect(found, isTrue, reason: 'an index on (attempt_group, attempt)');
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

  test('schemaVersion is at least 70', () {
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(70));
  });

  test('upgrade from 69 reaches the live version, adds all ten columns and '
      'the index, and keeps the legacy reading AND its packets', () async {
    const name = 'openstrap_ecg_phase1_69.db';
    created.add(name);
    await _seed(name, version: 69);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    await _expectIndex(db);
    final row = (await LocalDb.ecgReading('legacy1'))!;
    for (final k in _newCols.keys) {
      expect(row[k], isNull, reason: '$k: no backfill, never inferred');
    }
    final back = EcgReading.fromRow(row)!;
    expect(back.avgHr, 77);
    expect(back.maskAny, isNull);
    expect(back.captureTableVersion, isNull);
    final pk = await LocalDb.ecgReadingPackets('legacy1');
    expect(pk, hasLength(1));
    expect(pk.single['inner_hex'], 'deadbeef');
  });

  test('a legacy row is shown as a group of one by the default history',
      () async {
    const name = 'openstrap_ecg_phase1_69_hist.db';
    created.add(name);
    await _seed(name, version: 69);
    await _open(name);
    final ids = [for (final r in await LocalDb.listEcgReadings()) r['id']];
    expect(ids, ['legacy1']);
  });

  test('a database that ALREADY has some of the columns (a same-version merged '
      'build) upgrades without error and ends with exactly one of each',
      () async {
    const name = 'openstrap_ecg_phase1_69_partial.db';
    created.add(name);
    await _seed(name, version: 69, withColumns: ['mask_any', 'attempt_group']);
    final db = await _open(name);
    expect(await _userVersion(db), LocalDb.schemaVersion);
    _expectShape(await _cols(db));
    expect(await db.query('ecg_reading'), hasLength(1));
  });

  test('SAME-VERSION repair: a database already at the live version but missing '
      'the columns is healed on open by _repairOpenSchema', () async {
    const name = 'openstrap_ecg_phase1_samever.db';
    created.add(name);
    await _seed(name, version: LocalDb.schemaVersion);
    final db = await _open(name);
    _expectShape(await _cols(db));
    await _expectIndex(db);
    expect((await LocalDb.ecgReading('legacy1'))!['avg_hr'], 77);
  });

  test('re-opening at the live version is a no-op: ten columns, one index, the '
      'row untouched, every time', () async {
    const name = 'openstrap_ecg_phase1_reopen.db';
    created.add(name);
    await _seed(name, version: 69);
    for (var i = 0; i < 3; i++) {
      final db = await _open(name);
      _expectShape(await _cols(db));
      expect(await db.query('ecg_reading'), hasLength(1), reason: 'open #$i');
      expect((await LocalDb.ecgReading('legacy1'))!['avg_hr'], 77);
      final idx = await db.rawQuery("PRAGMA index_list('ecg_reading')");
      final grouped = [
        for (final i in idx)
          if ((await db.rawQuery("PRAGMA index_info('${i['name']}')"))
                  .map((c) => c['name'])
                  .contains('attempt_group'))
            i['name'],
      ];
      expect(grouped, hasLength(1), reason: 'open #$i: one attempt index');
    }
  });

  test('a fresh install has the columns, the index and a healthy schema',
      () async {
    const name = 'openstrap_ecg_phase1_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    final db = await _open(name);
    _expectShape(await _cols(db));
    await _expectIndex(db);
    expect(await LocalDb.tableNames(),
        containsAll(['ecg_reading', 'ecg_reading_packet', 'ecg_raw_packet']));
    expect((await LocalDb.schemaHealth())['ok'], isTrue);
  });

  test('the new columns are written and read back by a save', () async {
    const name = 'openstrap_ecg_phase1_fresh2.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _path(name));
    await _open(name);
    await LocalDb.saveEcgResult({
      'id': 'x1', 'device_id': '', 'source': 'mg_labrador', 'wrist': 'left',
      'start_ts': 1787823754, 'end_ts': 1787823784, 'result_code': 1,
      'category': 'sinusRhythm', 'avg_hr': 77, 'quality': 3,
      'unreadable_mask': 0, 'interruptions': 0, 'sample_count': 3000,
      'missing_segments': 0, 'status': 'completed', 'created_at': 1,
      'mask_any': 0, 'live_hr': 78, 'variability_raw': null,
      'firmware_version': '5.2.1', 'capture_app_version': '1.0+1',
      'capture_table_version': 2, 'start_offset_min': 0,
    }, const []);
    final r = (await LocalDb.ecgReading('x1'))!;
    expect(r['mask_any'], 0);
    expect(r['live_hr'], 78);
    expect(r['variability_raw'], isNull, reason: 'the 0xffff sentinel is NULL');
    expect(r['firmware_version'], '5.2.1');
    expect(r['capture_table_version'], 2);
    expect(r['start_offset_min'], 0);
  });

  group('source guard (invariant 11)', () {
    final src = File('lib/data/db.dart').readAsStringSync();

    test('one creator, called from the rung and from _repairOpenSchema', () {
      final calls = RegExp(r'_ensureEcgPhase1Columns\(').allMatches(src).length;
      expect(calls, greaterThanOrEqualTo(3),
          reason: 'its definition, the `oldV < 70` rung, _repairOpenSchema');
      final rung = RegExp(r'if \(oldV < 70\) \{[^}]*_ensureEcgPhase1Columns\(db\)');
      expect(rung.hasMatch(src), isTrue);
      final repair = src.substring(src.indexOf('static Future<void> _repairOpenSchema'));
      expect(repair.contains('_ensureEcgPhase1Columns(db)'), isTrue);
    });

    test('no backfill UPDATE in the creator (cheap under the iOS watchdog)', () {
      final i = src.indexOf('static Future<void> _ensureEcgPhase1Columns');
      expect(i, greaterThan(0), reason: 'the creator exists');
      final body = src.substring(i, src.indexOf('\n  }\n', i));
      expect(body.contains('UPDATE '), isFalse);
      expect(body.contains('ALTER TABLE') || body.contains('_addColumnIfMissing'),
          isTrue);
    });
  });
}
