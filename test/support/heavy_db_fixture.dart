// Heavy real-database fixture for the layout-shift load-time measurements.
//
// GATED. Everything built on this runs only when LAYOUT_SHIFT_HEAVY=1 and
// LAYOUT_SHIFT_HEAVY_DB points at a real OpenStrap export (.db). CI sets
// neither. The export stays outside the repo and is never modified: it is
// copied, re-dated, and cached under the system temp dir.
//
// What it builds
//   * The export's latest day becomes YESTERDAY (whole-day shift of every
//     day-keyed row and every epoch column the measured screens read), so the
//     screens' "today" / "yesterday" logic finds real data.
//   * `weeks: n` clones the newest day_result/metric_series rows backwards to
//     about n weeks with gaps (a 3-day hole, every 7th day missing), partial
//     days (partial=1, most metric keys absent), jittered values (so the
//     clones are not byte-identical) and out-of-order insertion.
//   * The prepared file is PRE-migration (the export's schema), so every run
//     measures the real migration to the current schema through LocalDb.
//
// Clock note: no DateTime.now / wall-clock reads here. "Today" comes from
// `todayLabel()` (the app's own day-label helper); elapsed time is a
// Stopwatch (monotonic), the accepted exception for these gated heavy tests.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';

const _envFlag = 'LAYOUT_SHIFT_HEAVY';
const _envDb = 'LAYOUT_SHIFT_HEAVY_DB';

/// Null when the heavy tests should run, else the skip reason.
String? heavySkipReason() {
  if (Platform.environment[_envFlag] != '1') {
    return 'heavy real-DB load measurement: set $_envFlag=1 and $_envDb=<export.db>';
  }
  final path = Platform.environment[_envDb];
  if (path == null || path.isEmpty) {
    return '$_envFlag=1 but $_envDb is not set';
  }
  if (!File(path).existsSync()) {
    return '$_envFlag=1 but $_envDb does not exist: $path';
  }
  return null;
}

String _exportPath() => Platform.environment[_envDb]!;

// ── date and epoch shifting ────────────────────────────────────────────────

DateTime _parse(String label) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(label)!;
  return DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

String _fmt(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String shiftLabel(String label, int days) {
  final d = _parse(label);
  return _fmt(DateTime.utc(d.year, d.month, d.day + days));
}

/// The re-dated export's newest day.
String yesterdayLabel() => shiftLabel(todayLabel(), -1);

int daysBetween(String from, String to) =>
    _parse(to).difference(_parse(from)).inDays;

final _dateLike = RegExp(r'^\d{4}-\d{2}-\d{2}');

/// Shifts every date string and plausible epoch number (seconds or ms) in a
/// decoded JSON tree by [days] whole days (86400 s each: the heavy runs use
/// TZ=UTC, so there is no DST day to be 23 or 25 hours long).
Object? shiftJson(Object? v, int days) {
  if (days == 0) return v;
  if (v is String) {
    if (_dateLike.hasMatch(v)) {
      return shiftLabel(v.substring(0, 10), days) + v.substring(10);
    }
    return v;
  }
  if (v is num) return shiftEpoch(v, days);
  if (v is List) return [for (final e in v) shiftJson(e, days)];
  if (v is Map) {
    return {
      for (final e in v.entries)
        (e.key is String ? shiftJson(e.key, days) : e.key): shiftJson(e.value, days),
    };
  }
  return v;
}

num shiftEpoch(num v, int days) {
  final a = v.abs();
  if (a >= 1.6e9 && a < 2.1e9) return v + days * 86400;
  if (a >= 1.6e12 && a < 2.1e12) return v + days * 86400000;
  return v;
}

String _shiftJsonText(String? text, int days) {
  if (text == null || text.isEmpty) return text ?? '';
  try {
    return jsonEncode(shiftJson(jsonDecode(text), days));
  } catch (_) {
    return text;
  }
}

// ── preparation ────────────────────────────────────────────────────────────

/// One-shot preparation, keyed by export mtime + variant + yesterday's label
/// (the shift depends on which day it is).
Future<File> _prepared({required int weeks}) async {
  final src = File(_exportPath());
  final mtime = src.lastModifiedSync().millisecondsSinceEpoch;
  final yesterday = yesterdayLabel();
  final dir = Directory(p.join(Directory.systemTemp.path, 'openstrap_ls_heavy'))
    ..createSync(recursive: true);
  final out = File(p.join(dir.path, 'prep_${mtime}_w${weeks}_$yesterday.db'));
  if (out.existsSync()) return out;

  final tmp = File('${out.path}.part');
  if (tmp.existsSync()) tmp.deleteSync();
  src.copySync(tmp.path);
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(tmp.path);
  try {
    await db.execute('PRAGMA journal_mode=DELETE');
    await _redate(db, yesterday);
    if (weeks > 0) await _cloneBackwards(db, yesterday, weeks);
  } finally {
    await db.close();
  }
  for (final s in const ['-wal', '-shm']) {
    final f = File('${tmp.path}$s');
    if (f.existsSync()) f.deleteSync();
  }
  tmp.renameSync(out.path);
  return out;
}

Future<void> _redate(Database db, String yesterday) async {
  final latest = (await db.rawQuery('SELECT MAX(day_id) AS d FROM day_result'))
      .single['d'] as String;
  final d = daysBetween(latest, yesterday);
  if (d == 0) return;
  final sec = d * 86400, ms = d * 86400000;
  String? sh(Object? v) => v == null ? null : shiftLabel(v as String, d);

  await db.transaction((tx) async {
    // Small tables: read, transform, reinsert (an in-place UPDATE of a date
    // primary key can collide with a row not yet moved).
    Future<void> small(
      String table,
      Map<String, Object?> Function(Map<String, Object?>) f,
    ) async {
      final rows = await tx.query(table);
      final b = tx.batch()..delete(table);
      for (final r in rows) {
        b.insert(table, f(Map.of(r)));
      }
      await b.commit(noResult: true);
    }

    await small('day_result', (r) => r
      ..['day_id'] = sh(r['day_id'])
      ..['payload_json'] = _shiftJsonText(r['payload_json'] as String?, d)
      ..['window_json'] = _shiftJsonText(r['window_json'] as String?, d)
      ..['computed_at'] = (r['computed_at'] as int) + ms);
    for (final t in const ['wake_day_features', 'sleep_session_candidates']) {
      await small(t, (r) => r
        ..['day_id'] = sh(r['day_id'])
        ..['payload_json'] = _shiftJsonText(r['payload_json'] as String?, d)
        ..['computed_at'] = (r['computed_at'] as int) + ms);
    }
    await small('metric_series', (r) => r..['date'] = sh(r['date']));
    await small('metric_series_version', (r) => r..['date'] = sh(r['date']));
    await small('journal', (r) => r
      ..['date'] = sh(r['date'])
      ..['updated_at'] = (r['updated_at'] as int) + ms);
    await small('sleep_override', (r) => r
      ..['day_id'] = sh(r['day_id'])
      ..['onset_ts'] = (r['onset_ts'] as int) + sec
      ..['offset_ts'] = (r['offset_ts'] as int) + sec
      ..['created_at'] = (r['created_at'] as int) + sec);
    await small('baselines', (r) => r
      ..['payload_json'] = _shiftJsonText(r['payload_json'] as String?, d)
      ..['updated_at'] = (r['updated_at'] as int) + ms);

    // Large tables: epoch columns only, shifted with a two-step negate so a
    // moved row can never collide with one that has not moved yet.
    Future<void> epoch(String table, Map<String, int> unitOf) async {
      final cols = unitOf.keys.toList();
      await tx.execute(
          'UPDATE $table SET ${cols.map((c) => '$c = -$c').join(', ')}');
      await tx.execute('UPDATE $table SET ${cols.map((c) => '$c = -$c + ${unitOf[c]! * d}').join(', ')}');
    }

    await epoch('decoded_onehz', {'ts_ms': 86400000, 'rec_ts': 86400});
    await epoch('decoded_rr', {
      'ts_ms': 86400000,
      'rec_ts': 86400,
      'rr_ts_ms': 86400000,
    });
    await tx.execute(
        'UPDATE decoded_rr SET beat_ts_ms = beat_ts_ms + $ms WHERE beat_ts_ms IS NOT NULL');
    await epoch('samples', {'ts_ms': 86400000, 'ts': 86400});
    await tx.execute('UPDATE band_events SET ts = ts + $sec, captured_at = captured_at + $ms');
    await tx.execute('UPDATE events SET ts = ts + $sec, captured_at = captured_at + $ms');
    await tx.execute('UPDATE band_battery SET ts = ts + $sec');
    await tx.execute('UPDATE device_coverage SET start_ts = start_ts + $sec, end_ts = end_ts + $sec');
    await tx.execute('UPDATE raw_archive SET rec_ts = rec_ts + $sec WHERE rec_ts IS NOT NULL');
  });
}

int _hash(String s) {
  var h = 17;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}

Future<void> _cloneBackwards(Database db, String yesterday, int weeks) async {
  // Source: the newest row of every present day.
  final src = await db.rawQuery('SELECT r.* FROM day_result r JOIN '
      '(SELECT day_id, MAX(algo_version) v FROM day_result GROUP BY day_id) m '
      'ON m.day_id = r.day_id AND m.v = r.algo_version ORDER BY r.day_id');
  if (src.isEmpty) return;
  final total = weeks * 7;
  final firstClone = 8; // days below yesterday are already taken by the export
  final ops = <int>[];
  for (var i = 0; i < total - firstClone; i++) {
    if (i % 7 == 6) continue; // every 7th day missing
    if (i >= 14 && i <= 16) continue; // a 3-day hole
    ops.add(i);
  }
  // Out of order: a deterministic shuffle, never ascending or descending.
  ops.sort((a, b) => ((a * 17) % 29).compareTo((b * 17) % 29));

  final batch = db.batch();
  for (final i in ops) {
    final target = shiftLabel(yesterday, -(firstClone + i));
    final row = src[(i * 3) % src.length];
    final from = row['day_id'] as String;
    final d = daysBetween(from, target);
    final partial = i % 5 == 2;
    batch.insert('day_result', {
      ...row,
      'day_id': target,
      'payload_json': _shiftJsonText(row['payload_json'] as String?, d),
      'window_json': _shiftJsonText(row['window_json'] as String?, d),
      'computed_at': (row['computed_at'] as int) + d * 86400000,
      'partial': partial ? 1 : 0,
    });
    final series = await db.query('metric_series', where: 'date = ?', whereArgs: [from]);
    for (final s in series) {
      final key = s['key'] as String;
      // A partial day lost most of its keys.
      if (partial && _hash('$key$i') % 5 >= 2) continue;
      final v = s['value'] as num?;
      final jitter = 1 + ((_hash('$key$i') % 21) - 10) / 100;
      batch.insert('metric_series', {
        'date': target,
        'key': key,
        'value': v == null ? null : v * jitter,
      });
    }
    final ver = await db.query('metric_series_version', where: 'date = ?', whereArgs: [from]);
    for (final v in ver) {
      batch.insert('metric_series_version', {...v, 'date': target});
    }
    if (i.isEven) {
      final j = await db.query('journal', where: 'date = ?', whereArgs: [from]);
      for (final r in j) {
        batch.insert('journal', {
          ...r,
          'date': target,
          'updated_at': (r['updated_at'] as int) + d * 86400000,
        });
      }
    }
  }
  await batch.commit(noResult: true);
}

// ── opening ────────────────────────────────────────────────────────────────

class HeavyDb {
  HeavyDb._(this.name, this.dir, this.migrationMs, this.dayResults,
      this.metricRows, this.fileBytes);
  final String name;
  final Directory dir;

  /// Wall time of `LocalDb.instance` on the copy: schema migration from the
  /// export's version to the current schema, plus the open itself.
  final int migrationMs;
  final int dayResults;
  final int metricRows;
  final int fileBytes;

  String describe() => 'db "$name": ${(fileBytes / 1e6).toStringAsFixed(1)} MB, '
      '$dayResults day_result rows, $metricRows metric_series rows, '
      'open+migrate $migrationMs ms';

  Future<void> dispose() async {
    await LocalDb.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// Copies the prepared file to a private temp dir, points LocalDb at it, and
/// opens it (migrations run on the copy). Call from `setUpAll`, never from a
/// test body under fake time.
Future<HeavyDb> openHeavyDb({int weeks = 0, required String name}) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final prepared = await _prepared(weeks: weeks);
  await LocalDb.close();
  final dir = await Directory.systemTemp.createTemp('openstrap_ls_work_');
  prepared.copySync(p.join(dir.path, name));
  await databaseFactoryFfi.setDatabasesPath(dir.path);
  LocalDb.dbName = name;
  LocalDb.lastRebuild = null;
  final sw = Stopwatch()..start();
  final db = await LocalDb.instance;
  final ms = sw.elapsedMilliseconds;
  Future<int> count(String t) async =>
      (await db.rawQuery('SELECT COUNT(*) AS n FROM $t')).single['n'] as int;
  final dr = await count('day_result');
  final mr = await count('metric_series');
  return HeavyDb._(name, dir, ms, dr, mr, File(p.join(dir.path, name)).lengthSync());
}
