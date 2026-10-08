// spectral_archive.dart — EXPERIMENT (branch explore/spectral-archive): the
// side table `spectral_archive` and the one writer that fills it before raw
// pruning.
//
//   spectral_archive(day_id TEXT, signal TEXT, codec_version INTEGER,
//                    blob BLOB, n_valid INTEGER, rms_err REAL, max_err REAL,
//                    created_at INTEGER, PRIMARY KEY (day_id, signal,
//                    codec_version))
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
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'day_label.dart';
import 'db.dart';
import 'spectral_codec.dart';

class SpectralArchiveRow {
  const SpectralArchiveRow({
    required this.dayId,
    required this.signal,
    required this.codecVersion,
    required this.blob,
    required this.nValid,
    required this.rmsErr,
    required this.maxErr,
    required this.createdAt,
  });

  final String dayId;
  final String signal;
  final int codecVersion;
  final Uint8List blob;
  final int nValid;
  final double rmsErr;
  final double maxErr;
  final int createdAt;
}

class SpectralArchiver {
  SpectralArchiver._();

  /// The `decoded_onehz` columns archived, in table order.
  static const List<String> signals = ['hr', 'ax', 'ay', 'az', 'skin_temp_c'];

  /// Rows are read in windows this long (seconds) so one day is never one
  /// 86 400-row result on the calling isolate.
  static const int _chunkSeconds = 3 * 3600;

  /// Archive every local day that has at least one `decoded_onehz` row with
  /// `rec_ts < cutoffSec` (so the day straddling the cutoff is archived whole,
  /// while its later seconds still exist). Returns the number of
  /// (day, signal) rows written. Never overwrites a row with one built from
  /// FEWER valid samples (a half-pruned day re-archived later must not clobber
  /// the full one). A signal with zero valid samples that day gets no row.
  ///
  /// A day that fails to archive is skipped (reported through [log]) and the
  /// rest still run: the caller's raw prune is not held hostage to one bad day.
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
        written += await archiveDay(day, nowSec: nowSec);
      } catch (e) {
        log?.call('spectral archive of $day skipped: $e');
      }
      from = localDayEndSec(day)!;
    }
    return written;
  }

  /// One local day, same rules as [archiveBefore].
  static Future<int> archiveDay(String dayId, {required int nowSec}) async {
    final start = localDayStartSec(dayId);
    final end = localDayEndSec(dayId);
    if (start == null || end == null) {
      throw ArgumentError.value(dayId, 'dayId', 'not a YYYY-MM-DD label');
    }
    final len = end - start;
    final db = await LocalDb.instance;
    final series = {
      for (final s in signals) s: Float64List(len)..fillRange(0, len, double.nan)
    };
    final counts = {for (final s in signals) s: 0};
    for (var lo = start; lo < end; lo += _chunkSeconds) {
      final hi = lo + _chunkSeconds < end ? lo + _chunkSeconds : end;
      final rows = await db.query(
        'decoded_onehz',
        columns: const ['rec_ts', 'hr', 'ax', 'ay', 'az', 'skin_temp_c'],
        where: 'rec_ts >= ? AND rec_ts < ?',
        whereArgs: [lo, hi],
      );
      for (final r in rows) {
        final i = (r['rec_ts'] as int) - start;
        for (final s in signals) {
          final v = r[s] as num?;
          // hr <= 0 is the off-skin sentinel: absent, not 0 bpm.
          if (v == null || (s == 'hr' && v <= 0)) continue;
          if (series[s]![i].isNaN) counts[s] = counts[s]! + 1;
          series[s]![i] = v.toDouble();
        }
      }
    }
    final existing = {
      for (final r in await db.query('spectral_archive',
          columns: const ['signal', 'n_valid'],
          where: 'day_id = ? AND codec_version = ?',
          whereArgs: [dayId, SpectralCodec.codecVersion]))
        r['signal'] as String: r['n_valid'] as int
    };
    final todo = [
      for (final s in signals)
        if (counts[s]! > 0 && counts[s]! > (existing[s] ?? -1)) s
    ];
    if (todo.isEmpty) return 0;

    // Off the calling isolate (invariant 10): the transform is the heavy part.
    final work = {for (final s in todo) s: series[s]!};
    final encoded = await Isolate.run(() {
      final out = <String, (Uint8List, int, double, double)>{};
      for (final e in work.entries) {
        final samples = <double?>[
          for (final v in e.value) v.isNaN ? null : v
        ];
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
    final batch = db.batch();
    for (final e in encoded.entries) {
      batch.insert(
        'spectral_archive',
        {
          'day_id': dayId,
          'signal': e.key,
          'codec_version': SpectralCodec.codecVersion,
          'blob': e.value.$1,
          'n_valid': e.value.$2,
          'rms_err': e.value.$3,
          'max_err': e.value.$4,
          'created_at': nowSec,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    return encoded.length;
  }

  /// Stored rows for [dayId], ordered by signal.
  static Future<List<SpectralArchiveRow>> rows(String dayId) async {
    final db = await LocalDb.instance;
    return [
      for (final r in await db.query('spectral_archive',
          where: 'day_id = ?', whereArgs: [dayId], orderBy: 'signal ASC'))
        SpectralArchiveRow(
          dayId: r['day_id'] as String,
          signal: r['signal'] as String,
          codecVersion: r['codec_version'] as int,
          blob: Uint8List.fromList((r['blob'] as List).cast<int>()),
          nValid: r['n_valid'] as int,
          rmsErr: (r['rms_err'] as num).toDouble(),
          maxErr: (r['max_err'] as num).toDouble(),
          createdAt: r['created_at'] as int,
        )
    ];
  }

  static Future<Uint8List?> _blob(String dayId, String signal) async {
    final db = await LocalDb.instance;
    final r = await db.query('spectral_archive',
        columns: const ['blob'],
        where: 'day_id = ? AND signal = ? AND codec_version = ?',
        whereArgs: [dayId, signal, SpectralCodec.codecVersion]);
    if (r.isEmpty) return null;
    return Uint8List.fromList((r.first['blob'] as List).cast<int>());
  }

  /// The reconstruction of one signal of one day (null elements = absent), or
  /// null when no archive row exists. With [maxOrder] a coarse view (still
  /// null in every gap). For display/export only.
  static Future<List<double?>?> reconstruct(String dayId, String signal,
      {int? maxOrder}) async {
    final blob = await _blob(dayId, signal);
    if (blob == null) return null;
    return Isolate.run(() => maxOrder == null
        ? SpectralCodec.decode(blob)
        : SpectralCodec.decodeCoarse(blob, maxOrder: maxOrder));
  }

  /// The LOD pyramid of one signal of one day straight from the stored blob (no
  /// coefficient decode), so a week / month / year chart can draw from
  /// summaries. Null when no archive row exists.
  static Future<List<SpectralLevel>?> summary(
      String dayId, String signal) async {
    final blob = await _blob(dayId, signal);
    return blob == null ? null : SpectralCodec.summary(blob);
  }
}
