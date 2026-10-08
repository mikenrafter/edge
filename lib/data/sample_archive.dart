// sample_archive.dart — EXPERIMENT (branch explore/spectral-archive): the
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
// `lib/compute` reads this table or calls `SampleCodec.decode` (invariant 3;
// `sample_guard_test`). The ONE symbol `lib/compute` may name is
// `SampleArchiver.archiveBefore`, called by `_pruneOldDecoded` immediately
// before `pruneDecodedBeforeRecTs` with the same cutoff.
//
// Heavy work (the encode and its error measurement) runs in `Isolate.run` (invariant 10);
// rows are read in 3-hour windows so no single result is a whole day. Day labels are LOCAL
// (`localDayStartSec`/`localDayLengthSec`, invariant 7); `nowSec` is injected, never read from the clock here.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'sample_codec.dart';
import 'sample_import.dart';
import 'sample_lock.dart';
import 'sample_zone.dart';

export 'sample_zone.dart' show SampleZone;

class SampleArchiveRow {
  const SampleArchiveRow({
    required this.dayId,
    this.deviceId = '',
    this.part = 0,
    this.originSec = 0,
    this.nSlots = 0,
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
  final int originSec;
  final int nSlots;
  final String signal;
  final int codecVersion;
  final Uint8List blob;
  final int nValid;
  final double rmsErr;
  final double maxErr;
  final int createdAt;

  /// How this part was encoded (read from the blob header).
  SampleMode get mode => SampleCodec.readHeader(blob).mode;
}

/// How the last archive attempt for one (day, device) went. A day with no
/// decoded rows at all has NO status row: failed is distinguishable from
/// absent input.
class SampleDayStatus {
  const SampleDayStatus(
      this.dayId, this.deviceId, this.outcome, this.reason, this.updatedAt);
  final String dayId, deviceId;

  /// `ok`, `empty` (rows existed, no archived signal had a valid sample) or
  /// `failed` ([reason] says why).
  final String outcome;
  final String? reason;
  final int updatedAt;
}

class SampleArchiver {
  SampleArchiver._();

  /// The `decoded_onehz` columns archived, in table order.
  static const List<String> signals = ['hr', 'ax', 'ay', 'az', 'skin_temp_c'];

  /// Rows are read in windows this long (seconds) so one day is never one
  /// 86 400-row result on the calling isolate.
  static const int _chunkSeconds = 3 * 3600;

  /// Which codec each archived signal gets. hr and skin temperature are
  /// quantized to a step (error at most step / 2); the accelerometer axes are
  /// the owner's choice between lossless at their quantum and pyramid-only.
  static const Map<String, SampleMode> defaultModes = {
    'hr': SampleMode.quantized,
    'skin_temp_c': SampleMode.quantized,
    'ax': SampleMode.pyramidOnly,
    'ay': SampleMode.pyramidOnly,
    'az': SampleMode.pyramidOnly,
  };

  /// True when every part of this device-day signal that carries samples is
  /// [SampleMode.losslessAtQuantum] (so it may be shown without the
  /// approximation label).
  static Future<bool> isExact(String dayId, String signal,
      {String deviceId = ''}) async {
    var any = false;
    for (final b in await _blobs(dayId, deviceId, signal)) {
      final mode = SampleCodec.readHeader(b).mode;
      if (mode == SampleMode.pyramidOnly) continue;
      if (mode != SampleMode.losslessAtQuantum) return false;
      any = true;
    }
    return any;
  }

  /// The calendar in use (a seam: tests fix a zone, e.g. Denver then New York).
  @visibleForTesting
  static SampleZone get zone => SampleZone.current;
  @visibleForTesting
  static set zone(SampleZone z) => SampleZone.current = z;

  /// Test seam: runs on the calling isolate right before a signal is encoded
  /// (a closure cannot cross into the encoding isolate).
  @visibleForTesting
  static void Function(String signal)? debugBeforeEncode;

  /// Test seam: awaited after the off-isolate encode and before the insert
  /// transaction opens - the window in which a restore can land.
  @visibleForTesting
  static Future<void> Function()? debugBeforeWrite;

  /// Archive every local day that has at least one `decoded_onehz` row with
  /// `rec_ts < cutoffSec` (so the day straddling the cutoff is archived whole,
  /// while its later seconds still exist). Returns the number of parts
  /// written. Existing coverage is never touched: only slots not yet archived
  /// are encoded (see [archiveDay]).
  ///
  /// A day or device that fails is skipped, recorded in the status table and
  /// reported through [log]; the rest still run.
  static Future<int> archiveBefore(int cutoffSec,
      {required int nowSec,
      void Function(String)? log,
      Map<String, SampleMode>? modes}) async {
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
      final day = zone.dayOf(m);
      try {
        written += await archiveDay(day,
            nowSec: nowSec, log: log, modes: modes);
      } catch (e) {
        log?.call('sample archive of $day skipped: $e');
        await _setStatus(db, day, '', 'failed', '$e', nowSec);
      }
      from = zone.endOf(day);
    }
    return written;
  }

  /// One local day, every device that has rows in it. Per (device, signal) it
  /// encodes only the slots valid in `decoded_onehz` and not already covered
  /// by an earlier part, as one NEW part. Returns the number of parts written.
  /// A device that fails is recorded (`failed` + reason) and does not stop the
  /// others; nothing is thrown for it.
  static Future<int> archiveDay(String dayId,
      {required int nowSec,
      void Function(String)? log,
      Map<String, SampleMode>? modes}) async {
    final int start, end;
    try {
      start = zone.startOf(dayId);
      end = zone.endOf(dayId);
    } catch (_) {
      throw ArgumentError.value(dayId, 'dayId', 'not a YYYY-MM-DD label');
    }
    return SampleLock.run(() => _archiveDayLocked(
        dayId, start, end, nowSec, log, modes));
  }

  static Future<int> _archiveDayLocked(String dayId, int start, int end,
      int nowSec, void Function(String)? log,
      Map<String, SampleMode>? modes) async {
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
        written += await _archiveDevice(
            db, dayId, dev, start, end, nowSec, modes ?? defaultModes);
      } catch (e) {
        log?.call('sample archive of $dayId/"$dev" failed: $e');
        await _setStatus(db, dayId, dev, 'failed', '$e', nowSec);
      }
    }
    return written;
  }

  static Future<int> _archiveDevice(Database db, String dayId, String dev,
      int start, int end, int nowSec, Map<String, SampleMode> modes) async {
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

    // What earlier parts already hold, per signal, by ABSOLUTE second and
    // across day labels (a part archived in another zone, or under the
    // neighbouring label, covers the same instants).
    final covered = await sampleCoverage(db,
        device: dev, start: start, end: end, legacyDay: dayId);

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
        final enc = SampleCodec.encode(e.key, samples,
            mode: modes[e.key] ??
                defaultModes[e.key] ??
                SampleMode.pyramidOnly);
        out[e.key] = (
          enc.blob,
          enc.stats.nValid,
          enc.stats.rmsErr,
          enc.stats.maxErr,
        );
      }
      return out;
    });
    await debugBeforeWrite?.call();
    // Coverage and part numbers were read BEFORE the encode; a restore can
    // have landed since. So the write reconciles again, inside this one
    // transaction: [importSamplePart] re-reads coverage, allocates MAX + 1
    // and plain-INSERTs, carving or skipping what is no longer free.
    var written = 0;
    await db.transaction((txn) async {
      for (final e in encoded.entries) {
        final wrote = await importSamplePart(txn, {
          'day_id': dayId,
          'device_id': dev,
          'signal': e.key,
          'codec_version': SampleCodec.codecVersion,
          'origin_sec': start,
          'n_slots': len,
          'slot_sec': 1,
          'blob': e.value.$1,
          'n_valid': e.value.$2,
          'rms_err': e.value.$3,
          'max_err': e.value.$4,
          'created_at': nowSec,
        });
        if (wrote) written++;
      }
      await _setStatus(txn, dayId, dev, 'ok', null, nowSec);
    });
    return written;
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

  static Uint8List _bytes(Object? v) => sampleBytes(v);

  /// The last archive outcome per device for [dayId], ordered by device.
  static Future<List<SampleDayStatus>> status(String dayId) async {
    final db = await LocalDb.instance;
    return [
      for (final r in await db.query('spectral_archive_status',
          where: 'day_id = ?', whereArgs: [dayId], orderBy: 'device_id ASC'))
        SampleDayStatus(
          r['day_id'] as String,
          r['device_id'] as String,
          r['outcome'] as String,
          r['reason'] as String?,
          r['updated_at'] as int,
        )
    ];
  }

  /// Stored rows for [dayId] (every device), ordered by device, signal, part.
  static Future<List<SampleArchiveRow>> rows(String dayId) async {
    final db = await LocalDb.instance;
    return [
      for (final r in await db.query('spectral_archive',
          where: 'day_id = ?',
          whereArgs: [dayId],
          orderBy: 'device_id ASC, signal ASC, part ASC'))
        SampleArchiveRow(
          dayId: r['day_id'] as String,
          deviceId: r['device_id'] as String,
          part: r['part'] as int,
          originSec: (r['origin_sec'] as num?)?.toInt() ??
              zone.startOf(r['day_id'] as String),
          nSlots: (r['n_slots'] as num?)?.toInt() ??
              SampleCodec.readHeader(_bytes(r['blob'])).length,
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

  /// The parts of one device-day signal at any readable codec version, with their
  /// absolute origins, in part order. Throws [StateError] if two parts cover
  /// the same second: parts are disjoint by construction (archive and import
  /// both guarantee it), so an overlap means a corrupt table and summing it
  /// would double count.
  static Future<List<({int originSec, Uint8List blob})>> _parts(
      String dayId, String deviceId, String signal) async {
    final db = await LocalDb.instance;
    final r = await db.query('spectral_archive',
        columns: const ['blob', 'origin_sec'],
        where: 'day_id = ? AND device_id = ? AND signal = ? '
            'AND codec_version IN '
            '(${SampleCodec.readableVersions.join(',')})',
        whereArgs: [dayId, deviceId, signal],
        orderBy: 'codec_version ASC, part ASC');
    final parts = [
      for (final x in r)
        (
          originSec:
              (x['origin_sec'] as num?)?.toInt() ?? zone.startOf(dayId),
          blob: _bytes(x['blob']),
        )
    ];
    final spans = <(int, int)>[
      for (final p in parts)
        for (final (a, b) in SampleCodec.validRuns(p.blob))
          (p.originSec + a, p.originSec + b)
    ]..sort((x, y) => x.$1.compareTo(y.$1));
    for (var i = 1; i < spans.length; i++) {
      if (spans[i].$1 < spans[i - 1].$2) {
        throw StateError('sample archive: parts of $dayId/$deviceId/$signal overlap '
            'at ${spans[i].$1}');
      }
    }
    return parts;
  }

  static Future<List<Uint8List>> _blobs(
          String dayId, String deviceId, String signal) async =>
      [for (final p in await _parts(dayId, deviceId, signal)) p.blob];

  /// The reconstruction of one signal of one device-day (null elements =
  /// absent): every part overlaid at its absolute position, or null when no
  /// archive with samples exists (a signal archived pyramid-only has none).
  /// Slot 0 is the earliest contributing part's origin; use
  /// [reconstructWithOrigin] when parts from different zones may be present.
  /// With [maxOrder] a coarse view (still null in every gap). For
  /// display/export only. A lossy part is an approximation, never a
  /// measurement; a [SampleMode.losslessAtQuantum] part is exact relative to
  /// its quantum (see [isExact]).
  static Future<List<double?>?> reconstruct(String dayId, String signal,
          {String deviceId = '', int? maxOrder}) async =>
      (await reconstructWithOrigin(dayId, signal,
              deviceId: deviceId, maxOrder: maxOrder))
          ?.samples;

  /// [reconstruct] plus the absolute epoch second of its slot 0.
  static Future<({int originSec, List<double?> samples})?> reconstructWithOrigin(
      String dayId, String signal,
      {String deviceId = '', int? maxOrder}) async {
    // A pyramid-only part holds no samples: skipped, never decoded to nulls.
    final parts = [
      for (final p in await _parts(dayId, deviceId, signal))
        if (SampleCodec.hasSamples(p.blob)) p
    ];
    if (parts.isEmpty) return null;
    return Isolate.run(() {
      final decoded = [
        for (final p in parts)
          maxOrder == null
              ? SampleCodec.decode(p.blob)
              : SampleCodec.decodeCoarse(p.blob, maxOrder: maxOrder)
      ];
      var o0 = parts.first.originSec, end = 0;
      for (var i = 0; i < parts.length; i++) {
        o0 = math.min(o0, parts[i].originSec);
        end = math.max(end, parts[i].originSec + decoded[i].length);
      }
      final out = List<double?>.filled(end - o0, null);
      for (var i = 0; i < parts.length; i++) {
        final base = parts[i].originSec - o0;
        final d = decoded[i];
        for (var j = 0; j < d.length; j++) {
          final v = d[j];
          if (v != null) out[base + j] = v;
        }
      }
      return (originSec: o0, samples: out);
    });
  }

  /// The LOD pyramid of one signal of one device-day straight from the stored
  /// blobs (no coefficient decode), parts merged: counts add, min/max are the
  /// extremes, the mean is count-weighted. Null when no archive exists.
  static Future<List<SampleLevel>?> summary(String dayId, String signal,
      {String deviceId = ''}) async {
    final parts = await _parts(dayId, deviceId, signal);
    if (parts.isEmpty) return null;
    return SampleCodec.mergeSummaries([
      for (final p in parts)
        SamplePartSummary(p.originSec, SampleCodec.summary(p.blob))
    ]);
  }
}
