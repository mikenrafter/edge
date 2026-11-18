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
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
import 'package:openstrap_edge/data/official_export/schema_catalog.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart';

const d1 = 1792454400; // 2026-10-20T00:00:00Z
const day = 86400;
int dayStart(int n) => d1 + (n - 1) * day;

/// The fork's live prune cursor: everything below d9 was pruned from live rows.
final int forkCursor = dayStart(9);

/// Oldest exact second in the mapped decoded rows: d3 12:00 (an archive-
/// restored, partial first day).
final int oldestExact = dayStart(3) + 12 * 3600;

/// First UTC midnight at or after [oldestExact], below the fork cursor: d4.
final int edgeD4 = dayStart(4);

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
        for (final row in e.value) {
          await db.insert(e.key, row, conflictAlgorithm: ConflictAlgorithm.replace);
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
