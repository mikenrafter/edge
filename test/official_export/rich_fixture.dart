// A rich synthetic fork database, made through the fork's REAL creators and
// open repair and populated with at least one row in every table, plus the
// specific shapes the official-export proof needs (spec §6.1).
//
// All instants are UTC and the declared export zone is UTC: the literal epochs
// below were computed with an independent zone database, not by the code under
// test. Day labels are 2026-10-20 (d1) … 2026-10-29 (d10). DST behavior is
// proven by prune_cursor_test.dart in America/Denver; the receiver harness
// requires a UTC process zone and fails loudly otherwise.
//
// P1 has no archive expansion, so "restored exact history" below the fork's
// live prune cursor is simulated by decoded rows that already sit there. P2
// replaces that with real `substrate_archive` buckets.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/payload_requirements.dart';
import 'package:openstrap_edge/data/official_export/schema_catalog.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart';
import 'target/scenario.dart';

int dayStart(int n) => dayStartEpoch(n);
final int forkCursor = fixtureForkCursor;
final int oldestExact = fixtureOldestExact;
final int edgeD4 = fixtureExpectedCursor;

class RichFixture {
  RichFixture._(this._root, this.forkPath, this.unfilled);

  final Directory _root;

  /// The fork database file (closed, consistent).
  final String forkPath;

  /// Tables the generic filler could not insert into (must stay empty).
  final List<String> unfilled;

  int get expectedPrunedBefore => edgeD4;

  static Future<RichFixture> build() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('official_rich_');
    PathProviderPlatform.instance = TempPaths(root.path);
    final path = '${root.path}/fork.db';
    LocalDb.dbName = path;
    final db = await LocalDb.instance;
    final unfilled = <String>[];
    try {
      final catalog = await SchemaCatalog.read(db);
      final specific = _specificRows();
      for (final e in specific.entries) {
        final shape = catalog.tables[e.key]!;
        for (final row in e.value) {
          // Literal columns win; required columns the scenario does not care
          // about get the generic filler so the row is valid.
          await db.insert(
            e.key,
            {..._filler(shape), ...row},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      // Generic filler: one row in every table the specifics did not reach.
      for (final shape in catalog.tables.values) {
        if ((Sqflite.firstIntValue(
                  await db.rawQuery('SELECT count(*) FROM "${shape.name}"'),
                ) ??
                0) >
            0) {
          continue;
        }
        try {
          await db.insert(shape.name, _filler(shape));
        } catch (_) {
          unfilled.add(shape.name);
        }
      }
      // The export-carrier tables a snapshot gains from BackupExtras.all, with an
      // attachment larger than Android's ~2 MiB cursor window (chunked reads,
      // never SELECT *). Created only in the fixture copy of the live schema.
      await db.execute('CREATE TABLE backup_prefs (key TEXT PRIMARY KEY, type TEXT NOT NULL, value TEXT NOT NULL)');
      await db.execute('CREATE TABLE backup_secrets (key TEXT PRIMARY KEY)');
      await db.execute('CREATE TABLE backup_files (rel_path TEXT PRIMARY KEY, bytes BLOB)');
      await db.insert('backup_prefs', {'key': 'clock_format', 'type': 'string', 'value': '24h'});
      await db.insert('backup_secrets', {'key': 'coach_api_key'});
      await db.insert('backup_files', {'rel_path': 'recordings/big.bin', 'bytes': Uint8List(3 * 1024 * 1024)});
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await LocalDb.close();
    }
    return RichFixture._(root, path, unfilled);
  }

  /// Reads a candidate file's inventory (opens it read-only).
  Future<PayloadInventory> inventoryOf(String path) async {
    final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(readOnly: true));
    try {
      return await PayloadInventory.read(db);
    } finally {
      await db.close();
    }
  }

  Future<void> dispose() => _root.delete(recursive: true);
}

Map<String, Object?> _filler(TableShape shape) => {
  for (final c in shape.columns)
    if (c.pk > 0 || (c.notNull && c.defaultValue == null))
      c.name: switch (c.type.toUpperCase()) {
        'INTEGER' || '' => 1,
        'REAL' => 1.0,
        'BLOB' => Uint8List.fromList([1]),
        _ => 'x',
      },
};

/// The scenario rows (everything else is filler). See the file header.
Map<String, List<Map<String, Object?>>> _specificRows() {
  final oneHz = <Map<String, Object?>>[
    // Two devices, same timestamp, NULL channels on the second.
    for (final dev in ['', 'ring-A'])
      {
        'device_id': dev,
        'ts_ms': (dayStart(5) + 3600) * 1000,
        'rec_ts': dayStart(5) + 3600,
        'counter': 1,
        'hr': dev.isEmpty ? 61 : null,
      },
    // Hourly exact history from d3 12:00 through d8 (the archive-restored span).
    for (var h = 0; h <= 5 * 24 - 12; h++)
      {
        'device_id': '',
        'ts_ms': (oldestExact + h * 3600) * 1000,
        'rec_ts': oldestExact + h * 3600,
        'counter': 100 + h,
        'hr': 55,
      },
  ];
  return {
    'decoded_onehz': oneHz,
    'device': [
      {'id': '', 'adapter_id': 'whoop', 'remote_id': 'fork-primary-handle',
       'role': 'primary', 'wearing': 2, 'wearing_set_ts': 1, 'first_seen': 1, 'last_seen': 1},
      {'id': 'ring-A', 'remote_id': 'fork-secondary-handle',
       'wearing': 1, 'wearing_set_ts': 1, 'first_seen': 1, 'last_seen': 1},
    ],
    'live_step_calibration_run': [
      {'category': 'brisk', 'run_ts': 1, 'reference': 'wearerCount',
       'expected_steps': 100, 'raw_steps': 97, 'cadence_spm': 98.0,
       'p2p_g': 1.2, 'confidence': 0.83, 'counter_version': 2},
    ],
    'observation': [
      {
        'device_id': 'vendor-A', 'ts_ms': (dayStart(5) + 60) * 1000,
        'date': '2026-10-24', 'source_kind': 'vendor', 'vendor_key': 'oura',
        'key': 'readiness', 'value': 71.0, 'unit': 'score', 'attribution': 'original vendor',
      },
    ],
    'day_result': [
      for (final v in [120, 124, 125])
        {
          'day_id': '2026-10-2${v == 120 ? 5 : v == 124 ? 6 : 7}',
          'algo_version': v,
          'payload_json': '{"fork":true}',
          'computed_at': 1,
          'rhr': 50.0,
        },
    ],
    'day_checkpoint': [
      {
        'day_id': '2026-10-26', 'algo_version': 125, 'fmt': 5, 'ctx_sig': 'fork',
        'cp_rec_ts': 1, 'rev_vec': Uint8List.fromList([1]),
        'state': Uint8List.fromList([2]), 'computed_at': 1,
      },
    ],
    'sync_cursor': [
      {'name': 'decoded_pruned_before', 'value': '$forkCursor', 'updated_at': 1},
      {'name': 'band_cursor', 'value': '77', 'updated_at': 1},
    ],
    'compute_freshness': [
      {'key': 'substrate_archive_policy', 'payload_json': '{"keepDays":null}', 'updated_at': 1},
      {'key': 'day_algo', 'payload_json': '{"v":125}', 'updated_at': 1},
    ],
    // Same label, different unit than the populated official target's mg
    // definition (proof D of the unit-key rule; the target side adds mg).
    'journal_field_def': [
      {
        'key': 'custom_caffeine', 'label': 'Caffeine', 'kind': 'dose',
        'unit': 'g', 'max_value': 10.0, 'step': 0.1, 'created_at': 1,
      },
    ],
    'journal_metric': [
      {'date': '2026-10-21', 'field': 'custom_caffeine', 'value': 0.2, 'updated_at': 1},
    ],
    // Migration overlap: the legacy hex table repeats one frame already in the
    // BLOB table (exact identity) and adds one only it holds.
    'raw_archive_legacy': [
      {'device_id': '', 'hex': 'AA01', 'counter': 5, 'packet_type': 36, 'rec_ts': dayStart(5), 'captured_at': dayStart(5), 'reason': 'unknown-version'},
      {'device_id': '', 'hex': 'BB01', 'counter': 6, 'packet_type': 36, 'rec_ts': dayStart(5), 'captured_at': dayStart(5), 'reason': 'unknown-version'},
    ],
    // A finished outdoor workout with a recorded route, fork-computed fields set.
    'sessions': [
      {
        'id': 'w${dayStart(6) * 1000}', 'start_ts': dayStart(6) + 7 * 3600, 'end_ts': dayStart(6) + 8 * 3600,
        'type': 'run', 'status': 'completed', 'calories': 410.0, 'strain': 9.1, 'max_hr': 171,
        'avg_hr': 148, 'rpe': 7.0, 'private': 0, 'created_at': dayStart(6),
      },
    ],
    'workout_route': [
      for (var i = 0; i < 3; i++)
        {'session_id': 'w${dayStart(6) * 1000}', 'seq': i, 'ts_ms': (dayStart(6) + 7 * 3600 + i * 60) * 1000, 'lat': 40.1 + i / 1000, 'lng': -105.2},
    ],
    'ecg_reading': [
      {'id': 'ecg-1', 'category': 'sinusRhythm', 'status': 'completed', 'wrist': 'left', 'notes': 'My exact ECG note', 'created_at': dayStart(5)},
    ],
    'ecg_reading_packet': [
      {'reading_id': 'ecg-1', 'ordinal': 0, 'sequence': 1, 'sample_count': 2, 'samples': Uint8List.fromList([1, 0, 2, 0]), 'inner_hex': 'AA'},
    ],
    'hyrox_session': [
      {'id': 'hy-1', 'kind': 'race', 'preset': 'open', 'status': 'completed', 'plan_json': '{}', 'created_at': dayStart(6), 'updated_at': dayStart(6)},
    ],
    'hyrox_segment': [
      {'session_id': 'hy-1', 'idx': 0, 'kind': 'run'},
    ],
    'sleep_override': [
      {'day_id': '2026-10-24', 'onset_ts': dayStart(4) + 23 * 3600, 'offset_ts': dayStart(5) + 6 * 3600, 'source': 'manual', 'created_at': dayStart(5)},
    ],
    // Fork-only user records the official file must omit but recovery keeps.
    'track_event': [
      {'id': 'tr-1', 'track_id': 'caffeine', 'date': '2026-10-24', 'source_kind': 'manual', 'source_id': 'x'},
    ],
    'water_moment': [
      {'id': 'wm-1', 'date': '2026-10-24', 'at_min': 600, 'ml': 250},
    ],
    // Distinct frames sharing a counter, plus a second device.
    'raw_archive_frames': [
      for (final (dev, hex) in [('', 'AA01'), ('', 'AA02'), ('ring-A', 'AA01')])
        {
          'device_id': dev, 'hash': Uint8List.fromList(hex.codeUnits),
          'counter': 5, 'packet_type': 36, 'rec_ts': dayStart(5),
          'captured_at': dayStart(5), 'reason': 'unknown-version', 'hex': hex,
        },
    ],
  };
}
