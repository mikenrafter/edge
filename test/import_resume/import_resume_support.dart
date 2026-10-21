// Shared fixture for the D38 red tests: a small source export, an import
// snapshot, and a recording foreground-service fake.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';

const kRows = 60; // decoded_onehz rows in the source (rowids 1..60)
const kChunk = 10; // rows per chunk in these tests
const kSourceDays = {'2026-09-21', '2026-09-22'};
const kT0 = 1790000000;

/// A plain export: 60 1 Hz rows, 20 beats, two derived days, two metrics.
Future<String> buildSource(Directory dir) async {
  final path = p.join(dir.path, 'resume_src.db');
  await databaseFactoryFfi.deleteDatabase(path);
  final s = await databaseFactoryFfi.openDatabase(path);
  await s.execute('CREATE TABLE decoded_onehz (device_id TEXT, ts_ms INTEGER, '
      'rec_ts INTEGER, counter INTEGER, hr INTEGER)');
  await s.execute('CREATE TABLE decoded_rr (device_id TEXT, ts_ms INTEGER, '
      'rec_ts INTEGER, beat_index INTEGER, rr_ts_ms INTEGER, rr_ms INTEGER)');
  await s.execute('CREATE TABLE day_result (day_id TEXT, algo_version INTEGER, '
      'payload_json TEXT, computed_at INTEGER, finalized INTEGER)');
  await s.execute(
      'CREATE TABLE metric_series (date TEXT, key TEXT, value REAL)');
  final b = s.batch();
  for (var i = 0; i < kRows; i++) {
    b.insert('decoded_onehz', {
      'device_id': '', 'ts_ms': (kT0 + i * 1800) * 1000,
      'rec_ts': kT0 + i * 1800, 'counter': i + 1, 'hr': 60 + i % 5,
    });
  }
  for (var i = 0; i < 20; i++) {
    b.insert('decoded_rr', {
      'device_id': '', 'ts_ms': (kT0 + i) * 1000, 'rec_ts': kT0 + i,
      'beat_index': 0, 'rr_ts_ms': (kT0 + i) * 1000, 'rr_ms': 800 + i,
    });
  }
  for (final d in kSourceDays) {
    b.insert('day_result', {
      'day_id': d, 'algo_version': 100, 'payload_json': '{"d":"$d"}',
      'computed_at': 1, 'finalized': 1,
    });
    b.insert('metric_series', {'date': d, 'key': 'rhr', 'value': 55.0});
  }
  await b.commit(noResult: true);
  await s.close();
  return path;
}

const _tables = ['decoded_onehz', 'decoded_rr', 'day_result', 'metric_series'];

/// Every imported table as sorted row literals, plus the per-day onehz counts.
Future<Map<String, List<String>>> snapshot() async {
  final db = await LocalDb.instance;
  final out = <String, List<String>>{};
  for (final t in _tables) {
    final cols = [
      for (final c in await db.rawQuery('PRAGMA table_info("$t")'))
        c['name'] as String,
    ]..remove('computed_at');
    final rows = await db.rawQuery(
        'SELECT ${cols.map((c) => 'quote("$c")').join(" || '|' || ")} AS r '
        'FROM "$t"');
    out[t] = [for (final r in rows) r['r'] as String]..sort();
  }
  out['onehz_per_day'] = [
    for (final r in await db.rawQuery(
        "SELECT strftime('%Y-%m-%d', rec_ts, 'unixepoch', 'localtime') AS d, "
        'COUNT(*) AS n FROM decoded_onehz GROUP BY d ORDER BY d'))
      '${r['d']}:${r['n']}',
  ];
  return out;
}

Future<int> count(String table) async {
  final db = await LocalDb.instance;
  return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM "$table"')) ??
      0;
}

class FakeService implements ImportForegroundService {
  final events = <String>[];
  @override
  Future<void> request(String stage) async => events.add('request');
  @override
  Future<void> release() async => events.add('release');
}

/// Fails the chunk with [index] of [table] (after its journal write).
void crashAt(String table, int index, {List<ImportChunk>? log}) {
  ImportHooks.chunkRows = kChunk;
  ImportHooks.chunk = (txn, c) async {
    log?.add(c);
    if (c.table == table && c.index == index) throw StateError('crash');
  };
}
