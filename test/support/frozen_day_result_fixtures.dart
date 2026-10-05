// Shared fixtures for the frozen-day-result tests (finalized day_result rows are frozen).
//
// RULE UNDER TEST. A provisional row (finalized = 0) stays replaceable on
// re-derive. Once (day, V) is finalized it is never rewritten for the same V,
// except by (1) an explicit user override re-derive or (3) a payload re-encode
// that keeps every value bit-identical. A new kAlgoVersion writes a NEW sibling
// row (day, V+1), as today. The guard lives in ONE place: LocalDb.putDayResult.
//
// ASSUMED NEW API (the only new symbol these tests reference, and only from
// `db_override_write_test.dart`):
//
//   enum DayResultWrite { derive, userOverride }       // in lib/data/db.dart
//   LocalDb.putDayResult(..., DayResultWrite reason = DayResultWrite.derive)
//
// `derive` (the default) refuses to replace a finalized row of the SAME
// (day_id, algo_version) and does nothing else: no day_result write, no
// metric_series / metric_series_version write, no blankKeys delete, and it does
// not throw. `userOverride` writes exactly like today. `putDayResult` keeps
// returning void, so this file and every test that does not pass `reason:`
// compile against today's code and fail (or pass) on behaviour alone.
//
// This file references NO symbol that does not exist today.

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';

/// The computed_at every seeded row carries. `putDayResult` stamps the wall
/// clock, so a real write can never equal this; "changed" and "unchanged" are
/// then decided without sleeping or racing a clock.
const int kSeedComputedAt = 1000;

const String kDay = '2026-03-10';

/// A fresh, empty database file for [name] (one name per test file).
Future<Database> freshDb(String name) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.close();
  LocalDb.dbName = name;
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, name));
  return LocalDb.instance;
}

Future<void> dropDb() async {
  await LocalDb.close();
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
}

/// A payload whose [tag] identifies which write produced it.
String payloadOf(String tag, {String day = kDay, double rhr = 50.0}) =>
    jsonEncode({
      'date': day,
      'tag': tag,
      'scalars': {'rhr': rhr, 'rmssd': 60.0, 'readiness': 70.0},
    });

/// Insert a `day_result` row directly (bypassing `putDayResult`, so the seed is
/// independent of the guard under test), with a fixed `computed_at`, plus the
/// `metric_series` rows the real writer would have left beside it.
Future<void> seedRow(
  Database db,
  String day, {
  int version = kAlgoVersion,
  bool finalized = false,
  bool partial = false,
  bool skipped = false,
  String tag = 'seed',
  String? payload,
  double rhr = 50.0,
  Map<String, double?>? series,
  int computedAt = kSeedComputedAt,
}) async {
  await db.insert('day_result', {
    'day_id': day,
    'algo_version': version,
    'payload_json': payload ?? payloadOf(tag, day: day, rhr: rhr),
    'window_json': '{"seed":true}',
    'computed_at': computedAt,
    'finalized': finalized ? 1 : 0,
    'skipped': skipped ? 1 : 0,
    'partial': partial ? 1 : 0,
    'rhr': rhr,
    'rmssd': 60.0,
    'readiness': 70.0,
  });
  for (final e in (series ?? {'rhr': rhr, 'readiness': 70.0}).entries) {
    await db.insert('metric_series', {
      'date': day,
      'key': e.key,
      'value': e.value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

Future<Map<String, Object?>?> rowOf(
  Database db,
  String day, {
  int version = kAlgoVersion,
}) async {
  final rows = await db.query(
    'day_result',
    where: 'day_id = ? AND algo_version = ?',
    whereArgs: [day, version],
  );
  return rows.isEmpty ? null : rows.first;
}

Future<double?> seriesOf(Database db, String day, String key) async {
  final rows = await db.query(
    'metric_series',
    where: 'date = ? AND key = ?',
    whereArgs: [day, key],
  );
  return rows.isEmpty ? null : (rows.first['value'] as num?)?.toDouble();
}

Future<List<Map<String, Object?>>> seriesVersionRows(
  Database db,
  String day,
) => db.query('metric_series_version', where: 'date = ?', whereArgs: [day]);

/// A production write through the one seam. Defaults mirror a band derive.
Future<void> deriveWrite(
  String day, {
  int version = kAlgoVersion,
  String tag = 'derive',
  bool finalized = false,
  bool partial = false,
  bool skipped = false,
  double rhr = 61.0,
  Map<String, double?>? series,
  Set<String> blankKeys = const {},
  String source = 'band',
}) => LocalDb.putDayResult(
  dayId: day,
  algoVersion: version,
  payloadJson: payloadOf(tag, day: day, rhr: rhr),
  windowJson: '{"derive":true}',
  finalized: finalized,
  partial: partial,
  skipped: skipped,
  rhr: rhr,
  rmssd: 33.0,
  readiness: 44.0,
  source: source,
  series: series ?? {'rhr': rhr, 'readiness': 44.0},
  blankKeys: blankKeys,
);
