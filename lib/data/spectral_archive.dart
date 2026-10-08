// spectral_archive.dart — EXPERIMENT (branch explore/spectral-archive): the
// side table `spectral_archive` and the one writer that fills it before raw
// pruning.
//
//   spectral_archive(day_id, device_id, signal, codec_version, part, blob,
//                    n_valid, rms_err, max_err, created_at,
//                    PRIMARY KEY (day_id, device_id, signal, codec_version,
//                    part))
//   spectral_archive_status(day_id, device_id, outcome, reason, updated_at)
//
// DEVICES ARE NEVER MERGED: every row is one device's readings (the live table
// is keyed by device_id too). A day's archive for a (device, signal) is a set
// of append-only PARTS with disjoint coverage: a pass encodes only the slots
// that are valid in `decoded_onehz` and NOT already covered by an earlier part,
// so a partial prune followed by a late backfill can never cost an archived
// slot, and each part's error is certified against the raw it was built from
// (re-encoding a reconstruction would stack approximations).
//
// READ-ONLY TO DERIVATION. A reconstruction is an approximation, so nothing in
// `lib/compute` reads this table or calls `SpectralCodec.decode` (invariant 3;
// `spectral_guard_test`). The ONE symbol `lib/compute` may name is
// `SpectralArchiver.archiveBefore`, called by `_pruneOldDecoded` immediately
// before `pruneDecodedBeforeRecTs` with the same cutoff.
//
// Heavy work (the DCT and error search) runs in `Isolate.run` (invariant 10);
// rows are read in 3-hour windows so no single result is a whole day. Day labels are LOCAL
// (`localDayStartSec`/`localDayLengthSec`, invariant 7); `nowSec` is injected, never read from the clock here.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';

import 'day_label.dart';
import 'db.dart';
import 'spectral_codec.dart';

class SpectralArchiveRow {
  const SpectralArchiveRow({
    required this.dayId,
    this.deviceId = '',
    this.part = 0,
    required this.signal,
    required this.codecVersion,
    required this.blob,
    required this.nValid,
    required this.rmsErr,
    required this.maxErr,
    required this.createdAt,
  });

  final String dayId;
  final String deviceId;
  final int part;
  final String signal;
  final int codecVersion;
  final Uint8List blob;
  final int nValid;
  final double rmsErr;
  final double maxErr;
  final int createdAt;
}

/// How the last archive attempt for one (day, device) went. A day with no
/// decoded rows at all has NO status row: failed is distinguishable from
/// absent input.
class SpectralDayStatus {
  const SpectralDayStatus(
      this.dayId, this.deviceId, this.outcome, this.reason, this.updatedAt);
  final String dayId, deviceId;

  /// `ok`, `empty` (rows existed, no archived signal had a valid sample) or
  /// `failed` ([reason] says why).
  final String outcome;
  final String? reason;
  final int updatedAt;
}

class SpectralArchiver {
  SpectralArchiver._();

  /// The `decoded_onehz` columns archived, in table order.
  static const List<String> signals = ['hr', 'ax', 'ay', 'az', 'skin_temp_c'];

  /// Rows are read in windows this long (seconds) so one day is never one
  /// 86 400-row result on the calling isolate.
  static const int _chunkSeconds = 3 * 3600;

  /// Test seam: runs on the calling isolate right before a signal is encoded
  /// (a closure cannot cross into the encoding isolate).
  @visibleForTesting
  static void Function(String signal)? debugBeforeEncode;

  /// Archive every local day that has at least one `decoded_onehz` row with
  /// `rec_ts < cutoffSec` (so the day straddling the cutoff is archived whole,
  /// while its later seconds still exist). Returns the number of parts
  /// written. Existing coverage is never touched: only slots not yet archived
  /// are encoded (see [archiveDay]).
  ///
  /// A day or device that fails is skipped, recorded in the status table and
  /// reported through [log]; the rest still run.
  static Future<int> archiveBefore(int cutoffSec,
      {required int nowSec, void Function(String)? log}) async {
    final db = await LocalDb.instance;
    var written = 0;
    var from = 1; // rec_ts <= 0 is not a real record time
    while (from < cutoffSec) {
      final m = (await db.rawQuery(
              'SELECT MIN(rec_ts) AS m FROM decoded_onehz '
              'WHERE rec_ts >= ? AND rec_ts < ?',
              [from, cutoffSec]))
          .first['m'] as int?;
      if (m == null) break;
      final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(m * 1000));
      try {
        written += await archiveDay(day, nowSec: nowSec, log: log);
      } catch (e) {
        log?.call('spectral archive of $day skipped: $e');
        await _setStatus(db, day, '', 'failed', '$e', nowSec);
      }
      from = localDayEndSec(day)!;
    }
    return written;
  }

  /// One local day, every device that has rows in it. Per (device, signal) it
  /// encodes only the slots valid in `decoded_onehz` and not already covered
  /// by an earlier part, as one NEW part. Returns the number of parts written.
  /// A device that fails is recorded (`failed` + reason) and does not stop the
  /// others; nothing is thrown for it.
  static Future<int> archiveDay(String dayId,
      {required int nowSec, void Function(String)? log}) async {
    final start = localDayStartSec(dayId);
    final end = localDayEndSec(dayId);
    if (start == null || end == null) {
      throw ArgumentError.value(dayId, 'dayId', 'not a YYYY-MM-DD label');
    }
    final db = await LocalDb.instance;
    final devices = [
      for (final r in await db.rawQuery(
          'SELECT DISTINCT device_id AS d FROM decoded_onehz '
          'WHERE rec_ts >= ? AND rec_ts < ? ORDER BY device_id',
          [start, end]))
        (r['d'] as String?) ?? ''
    ];
    var written = 0;
    for (final dev in devices) {
      try {
        written += await _archiveDevice(db, dayId, dev, start, end, nowSec);
      } catch (e) {
        log?.call('spectral archive of $dayId/"$dev" failed: $e');
        await _setStatus(db, dayId, dev, 'failed', '$e', nowSec);
      }
    }
    return written;
  }

  static Future<int> _archiveDevice(Database db, String dayId, String dev,
      int start, int end, int nowSec) async {
    final len = end - start;
    final series = {
      for (final s in signals) s: Float64List(len)..fillRange(0, len, double.nan)
    };
    final rawValid = {for (final s in signals) s: 0};
    for (var lo = start; lo < end; lo += _chunkSeconds) {
      final hi = lo + _chunkSeconds < end ? lo + _chunkSeconds : end;
      final rows = await db.query(
        'decoded_onehz',
        columns: const ['rec_ts', 'hr', 'ax', 'ay', 'az', 'skin_temp_c'],
        where: 'rec_ts >= ? AND rec_ts < ? AND device_id = ?',
        whereArgs: [lo, hi, dev],
      );
      for (final r in rows) {
        final i = (r['rec_ts'] as int) - start;
        for (final s in signals) {
          final v = r[s] as num?;
          if (v == null) continue;
          final d = v.toDouble();
          // hr <= 0 is the off-skin sentinel: absent, not 0 bpm. A non-finite
          // stored value is not a measurement either.
          if (!d.isFinite || (s == 'hr' && d <= 0)) continue;
          if (series[s]![i].isNaN) rawValid[s] = rawValid[s]! + 1;
          series[s]![i] = d;
        }
      }
    }

    // What earlier parts already hold, per signal.
    final covered = <String, Uint8List>{};
    final nextPart = <String, int>{};
    for (final r in await db.query('spectral_archive',
        columns: const ['signal', 'part', 'blob'],
        where: 'day_id = ? AND device_id = ? AND codec_version = ?',
        whereArgs: [dayId, dev, SpectralCodec.codecVersion])) {
      final sig = r['signal'] as String;
      final mask = covered.putIfAbsent(sig, () => Uint8List(len));
      for (final (a, b) in SpectralCodec.validRuns(_bytes(r['blob']))) {
        for (var i = a; i < b && i < len; i++) {
          mask[i] = 1;
        }
      }
      nextPart[sig] = math.max(nextPart[sig] ?? 0, (r['part'] as int) + 1);
    }

    final todo = <String>[];
    final work = <String, Float64List>{};
    for (final s in signals) {
      if (rawValid[s]! == 0) continue;
      final cov = covered[s];
      final fresh = Float64List(len)..fillRange(0, len, double.nan);
      var n = 0;
      for (var i = 0; i < len; i++) {
        if (series[s]![i].isNaN || (cov != null && cov[i] == 1)) continue;
        fresh[i] = series[s]![i];
        n++;
      }
      if (n > 0) {
        todo.add(s);
        work[s] = fresh;
      }
    }

    if (todo.isEmpty) {
      final anyRaw = rawValid.values.any((n) => n > 0);
      await _setStatus(db, dayId, dev,
          anyRaw || covered.isNotEmpty ? 'ok' : 'empty', null, nowSec);
      return 0;
    }
    for (final s in todo) {
      debugBeforeEncode?.call(s);
    }

    // Off the calling isolate (invariant 10): the transform is the heavy part.
    final encoded = await Isolate.run(() {
      final out = <String, (Uint8List, int, double, double)>{};
      for (final e in work.entries) {
        final samples = <double?>[for (final v in e.value) v.isNaN ? null : v];
        final enc = SpectralCodec.encode(e.key, samples);
        out[e.key] = (
          enc.blob,
          enc.stats.nValid,
          enc.stats.rmsErr,
          enc.stats.maxErr,
        );
      }
      return out;
    });
    await db.transaction((txn) async {
      for (final e in encoded.entries) {
        await txn.insert(
          'spectral_archive',
          {
            'day_id': dayId,
            'device_id': dev,
            'signal': e.key,
            'codec_version': SpectralCodec.codecVersion,
            'part': nextPart[e.key] ?? 0,
            'blob': e.value.$1,
            'n_valid': e.value.$2,
            'rms_err': e.value.$3,
            'max_err': e.value.$4,
            'created_at': nowSec,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await _setStatus(txn, dayId, dev, 'ok', null, nowSec);
    });
    return encoded.length;
  }

  static Future<void> _setStatus(DatabaseExecutor db, String dayId, String dev,
      String outcome, String? reason, int nowSec) async {
    try {
      await db.insert(
        'spectral_archive_status',
        {
          'day_id': dayId,
          'device_id': dev,
          'outcome': outcome,
          'reason': reason,
          'updated_at': nowSec,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // The ledger is advisory; never let it fail an archive pass.
    }
  }

  static Uint8List _bytes(Object? v) =>
      v is Uint8List ? v : Uint8List.fromList((v as List).cast<int>());

  /// The last archive outcome per device for [dayId], ordered by device.
  static Future<List<SpectralDayStatus>> status(String dayId) async {
    final db = await LocalDb.instance;
    return [
      for (final r in await db.query('spectral_archive_status',
          where: 'day_id = ?', whereArgs: [dayId], orderBy: 'device_id ASC'))
        SpectralDayStatus(
          r['day_id'] as String,
          r['device_id'] as String,
          r['outcome'] as String,
          r['reason'] as String?,
          r['updated_at'] as int,
        )
    ];
  }

  /// Stored rows for [dayId] (every device), ordered by device, signal, part.
  static Future<List<SpectralArchiveRow>> rows(String dayId) async {
    final db = await LocalDb.instance;
    return [
      for (final r in await db.query('spectral_archive',
          where: 'day_id = ?',
          whereArgs: [dayId],
          orderBy: 'device_id ASC, signal ASC, part ASC'))
        SpectralArchiveRow(
          dayId: r['day_id'] as String,
          deviceId: r['device_id'] as String,
          part: r['part'] as int,
          signal: r['signal'] as String,
          codecVersion: r['codec_version'] as int,
          blob: _bytes(r['blob']),
          nValid: r['n_valid'] as int,
          rmsErr: (r['rms_err'] as num).toDouble(),
          maxErr: (r['max_err'] as num).toDouble(),
          createdAt: r['created_at'] as int,
        )
    ];
  }

  static Future<List<Uint8List>> _blobs(
      String dayId, String deviceId, String signal) async {
    final db = await LocalDb.instance;
    final r = await db.query('spectral_archive',
        columns: const ['blob'],
        where: 'day_id = ? AND device_id = ? AND signal = ? '
            'AND codec_version = ?',
        whereArgs: [dayId, deviceId, signal, SpectralCodec.codecVersion],
        orderBy: 'part ASC');
    return [for (final x in r) _bytes(x['blob'])];
  }

  /// The reconstruction of one signal of one device-day (null elements =
  /// absent): every part overlaid (parts never overlap), or null when no
  /// archive exists. With [maxOrder] a coarse view (still null in every gap).
  /// For display/export only - an approximation, never a measurement.
  static Future<List<double?>?> reconstruct(String dayId, String signal,
      {String deviceId = '', int? maxOrder}) async {
    final blobs = await _blobs(dayId, deviceId, signal);
    if (blobs.isEmpty) return null;
    return Isolate.run(() {
      List<double?>? out;
      for (final b in blobs) {
        final d = maxOrder == null
            ? SpectralCodec.decode(b)
            : SpectralCodec.decodeCoarse(b, maxOrder: maxOrder);
        if (out == null) {
          out = d;
          continue;
        }
        if (d.length != out.length) {
          throw StateError('spectral parts of one day differ in length');
        }
        for (var i = 0; i < d.length; i++) {
          out[i] ??= d[i];
        }
      }
      return out;
    });
  }

  /// The LOD pyramid of one signal of one device-day straight from the stored
  /// blobs (no coefficient decode), parts merged: counts add, min/max are the
  /// extremes, the mean is count-weighted. Null when no archive exists.
  static Future<List<SpectralLevel>?> summary(String dayId, String signal,
      {String deviceId = ''}) async {
    final blobs = await _blobs(dayId, deviceId, signal);
    if (blobs.isEmpty) return null;
    final all = [for (final b in blobs) SpectralCodec.summary(b)];
    if (all.length == 1) return all.single;
    final out = <SpectralLevel>[];
    for (var li = 0; li < all.first.length; li++) {
      final cells = <LodCell>[];
      for (var ci = 0; ci < all.first[li].cells.length; ci++) {
        var count = 0;
        double? lo, hi;
        var sum = 0.0;
        for (final a in all) {
          final c = a[li].cells[ci];
          if (c.count == 0) continue;
          count += c.count;
          sum += c.mean! * c.count;
          lo = lo == null ? c.min : math.min(lo, c.min!);
          hi = hi == null ? c.max : math.max(hi, c.max!);
        }
        cells.add(count == 0
            ? const LodCell(0, null, null, null)
            : LodCell(count, lo, sum / count, hi));
      }
      out.add(SpectralLevel(all.first[li].cellSeconds, cells));
    }
    return out;
  }
}
