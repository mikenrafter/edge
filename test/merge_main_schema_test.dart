// WHY: fork users already ran migrations 59..88. Main's 59..62 must arrive
// above 88 without replacing a day checkpoint with a night checkpoint.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:openstrap_edge/compute/night_rr_state.dart';
import 'package:openstrap_edge/compute/night_checkpoint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/data/restore_classification.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backup/backup_support.dart';

const _checkpointDdl = '('
    'day_id TEXT NOT NULL, algo_version INTEGER NOT NULL, '
    'fmt INTEGER NOT NULL, ctx_sig TEXT NOT NULL, cp_rec_ts INTEGER NOT NULL, '
    'rev_vec BLOB NOT NULL, state BLOB NOT NULL, night_ref TEXT, '
    'computed_at INTEGER NOT NULL, PRIMARY KEY(day_id, algo_version))';
Map<String, Object?> _nightRow() {
  const from = 1794700800, boundary = from + 1800;
  final state = NightRrState();
  state.correctHeavy([for (var i = 0; i < 2000; i++) 950 + 15 * math.sin(i * .13)],
      [for (var i = 0; i < 2000; i++) (from + i) * 1000.0],
      day: '2026-11-15', onsetSec: from);
  final revisions = checkpointRevisions(const {}, from, boundary);
  final encoded = encodeNightCheckpointHeavy(state, const [], '2026-11-15',
      kAlgoVersion, 'official-night-context', from, boundary, revisions)!;
  final row = <String, Object?>{
    'day_id': '2026-11-15', 'algo_version': kAlgoVersion,
    'fmt': nightCheckpointFormat, 'ctx_sig': 'official-night-context',
    'cp_rec_ts': boundary, 'rev_vec': revisions,
    'state': encoded, 'night_ref': null, 'computed_at': 7,
  };
  expect(decodeNightCheckpointHeavy(row, '2026-11-15', kAlgoVersion,
      'official-night-context', from, from + 1999, const {}).rejection, isNull,
      reason: 'the foreign fixture is a valid SHA-256 protected NIGHT blob');
  return row;
}

Future<void> _expectMainObjects(Database db) async {
  final tables = {for (final r in await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'")) r['name']};
  expect(tables, containsAll([
    'triathlon_session', 'triathlon_segment', 'hyrox_session', 'hyrox_segment',
    'input_rev', 'session_ceiling_rev', 'store_identity', 'day_checkpoint',
    'night_checkpoint',
  ]));
  final expected = {
    'day_id', 'algo_version', 'fmt', 'ctx_sig', 'cp_rec_ts', 'rev_vec',
    'state', 'night_ref', 'computed_at',
  };
  for (final table in ['day_checkpoint', 'night_checkpoint']) {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    expect({for (final c in cols) c['name']}, expected);
    expect(cols.singleWhere((c) => c['name'] == 'day_id')['pk'], 1);
    expect(cols.singleWhere((c) => c['name'] == 'algo_version')['pk'], 2);
  }
  final triggers = {for (final r in await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'trigger'")) r['name']};
  expect(triggers, containsAll([
    'decoded_onehz_rev_ai', 'decoded_rr_rev_ai',
    'sessions_ceiling_ai', 'sessions_ceiling_au', 'sessions_ceiling_ad',
  ]));
  final id = await LocalDb.storeIdentity();
  expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
  expect(kTablesNotRestored, contains('night_checkpoint'));
  expect(kSliceTables['night_checkpoint']!.$1, SliceKeep.none);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('merge_main_schema.db'));
  setUp(() async => env.wipe());
  tearDownAll(() async => env.dispose());

  test('fresh install has main 59..62 objects and independent night scratch', () async {
    final db = await LocalDb.instance;
    await _expectMainObjects(db);
    final row = _nightRow();
    await db.insert('night_checkpoint', row);
    expect(await LocalDb.dayCheckpoint('2026-11-15', kAlgoVersion), isNull);
    expect((await LocalDb.nightCheckpointRow('2026-11-15', kAlgoVersion,
      maxBytes: maxNightCheckpointBytes))!['state'], row['state']);
  });

  test('fork 88 upgrades additively, then same-version repair is idempotent', () async {
    final path = p.join(env.dbDir, LocalDb.dbName);
    final old = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(
      version: 88, onCreate: (db, _) async {
        await db.execute('CREATE TABLE day_checkpoint $_checkpointDdl');
        await db.insert('day_checkpoint', {..._nightRow(),
          'fmt': kDayCheckpointFmt, 'ctx_sig': 'fork-day-sentinel'});
      }));
    await old.close();
    LocalDb.lastRebuild = null;
    var db = await LocalDb.instance;
    expect(LocalDb.lastRebuild, isNull);
    await _expectMainObjects(db);
    expect((await LocalDb.dayCheckpoint('2026-11-15', kAlgoVersion))!.ctxSig,
      'fork-day-sentinel');
    final id = await LocalDb.storeIdentity();
    await db.execute('DROP TABLE night_checkpoint');
    await LocalDb.close();
    db = await LocalDb.instance;
    await _expectMainObjects(db);
    expect(await LocalDb.storeIdentity(), id);
  });

  // WHY: a sparse table fixture cannot prove ordering against the installed
  // fork's actual schema. This DDL was captured by running parent 9eb11d27e.
  test('real fork-88 schema upgrades without rebuilding or changing fork tables', () async {
    final fixture = jsonDecode(await File('test/fixtures/merge/fork88-schema.json')
        .readAsString()) as Map<String, dynamic>;
    expect(fixture['version'], 88);
    final objects = (fixture['objects'] as List).cast<Map<String, dynamic>>();
    final path = p.join(env.dbDir, LocalDb.dbName);
    final old = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(
      version: 88, onCreate: (db, _) async {
        for (final object in objects) { await db.execute(object['sql'] as String); }
        await db.insert('journal', {'date': '2026-11-15', 'note': 'fork-88 sentinel',
          'updated_at': 7});
        await db.insert('day_checkpoint', {..._nightRow(), 'fmt': kDayCheckpointFmt,
          'ctx_sig': 'real-fork-day-sentinel'});
      }));
    final before = <String, List<Map<String, Object?>>>{};
    for (final object in objects.where((o) => o['type'] == 'table')) {
      final table = object['name'] as String;
      before[table] = await old.rawQuery('PRAGMA table_info("$table")');
    }
    await old.close();
    LocalDb.lastRebuild = null;
    var db = await LocalDb.instance;
    expect(LocalDb.lastRebuild, isNull, reason: 'a real fork store must never be quarantined');
    await _expectMainObjects(db);
    expect((await db.query('journal')).single['note'], 'fork-88 sentinel');
    expect((await LocalDb.dayCheckpoint('2026-11-15', kAlgoVersion))!.ctxSig,
        'real-fork-day-sentinel');
    for (final entry in before.entries) {
      // Main's archive layout intentionally retains the old table under this
      // name; its rows migrate outside the open callback, in bounded pages.
      final table = entry.key == 'raw_archive' ? 'raw_archive_legacy' : entry.key;
      final after = await db.rawQuery('PRAGMA table_info("$table")');
      for (final column in entry.value) {
        expect(after.singleWhere((c) => c['name'] == column['name']), column,
            reason: 'existing fork column $table.${column['name']} is preserved');
      }
    }
    final id = await LocalDb.storeIdentity();
    await LocalDb.close();
    db = await LocalDb.instance;
    expect(LocalDb.lastRebuild, isNull);
    expect(await LocalDb.storeIdentity(), id);
    await _expectMainObjects(db);
  });

  test('official schema-62 import never admits its night blob as fork day state', () async {
    final path = p.join(env.root.path, 'official62.db');
    final source = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(
      version: 62, onCreate: (db, _) async {
        await db.execute('CREATE TABLE day_checkpoint $_checkpointDdl');
        await db.insert('day_checkpoint', _nightRow());
        // cd64eaa89 lib/data/db.dart:5935–5940: official schema includes this.
        await db.execute("CREATE TABLE journal (date TEXT PRIMARY KEY, "
          "tags_json TEXT NOT NULL DEFAULT '[]', note TEXT NOT NULL DEFAULT '', "
          'updated_at INTEGER NOT NULL)');
        await db.insert('journal', {'date': '2026-11-15', 'note': 'official sentinel', 'updated_at': 7});
        await db.execute('CREATE TABLE day_result ('
          'day_id TEXT NOT NULL, algo_version INTEGER NOT NULL, '
          'payload_json TEXT NOT NULL, window_json TEXT NOT NULL, '
          'computed_at INTEGER NOT NULL, finalized INTEGER NOT NULL DEFAULT 0, '
          'imported INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day_id, algo_version))');
        for (final suffix in ['ins', 'upd']) {
          await db.execute('CREATE TRIGGER trg_day_result_imported_$suffix '
            '${suffix == 'ins' ? 'AFTER INSERT' : 'AFTER UPDATE OF payload_json'} ON day_result BEGIN '
            'UPDATE day_result SET imported = (NEW.payload_json LIKE \'%"imported":true%\') '
            'WHERE rowid = NEW.rowid; END');
        }
        await db.insert('day_result', {'day_id': '2026-11-15', 'algo_version': kAlgoVersion,
          'payload_json': '{"imported":true,"source":"official"}', 'window_json': '{}',
          'computed_at': 7, 'finalized': 1});
        expect((await db.query('day_result')).single['imported'], 1);

      }));
    await source.close();
    await LocalDb.importFromDbFile(path);
    final db = await LocalDb.instance;
    expect((await db.query('journal')).single['note'], 'official sentinel');
    expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND name LIKE 'trg_day_result_imported_%'"), isEmpty);
    expect(await LocalDb.finalizedDayIds(kAlgoVersion), isNot(contains('2026-11-15')),
      reason: 'source materialized flag and fork expression agree for official imports');

    expect(await LocalDb.dayCheckpoint('2026-11-15', kAlgoVersion), isNull,
      reason: 'foreign scratch is not in the restore or bulk-restore lists');
    expect(await db.query('night_checkpoint'), isEmpty);
    // Also cover opening a foreign DB in place: its row can already exist
    // locally, bypassing the restore table allowlist. Format must refuse it.
    await db.insert('day_checkpoint', _nightRow());
    expect(await LocalDb.dayCheckpoint('2026-11-15', kAlgoVersion), isNull);
    final miss = decideResume(cp: null, algoVersion: kAlgoVersion,
      ctxSig: 'official-night-context', liveRevs: const {});
    expect(miss.resume, isFalse);
    expect(miss.reason, 'none');
  });
}
