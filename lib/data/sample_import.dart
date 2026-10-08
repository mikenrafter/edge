// sample_import.dart - coverage bookkeeping shared by the archiver and the
// backup-restore path, and the coverage-aware import of one archive part.
//
// PARTS ARE POSITIONAL, ORIGINS ARE ABSOLUTE. A part's slots are seconds from
// its `origin_sec` (the epoch second of slot 0); the day id is only the LOCAL
// label at archive time. Coverage therefore compares absolute seconds, across
// day labels and across time zones, never slot indices. A row with no origin
// (written before schema 68, or by an older backup) is placed at the start of
// its day id in the current zone - the documented assumption.
//
// IMPORT NEVER OVERWRITES. Part numbers are local allocation order, so a
// matching key says nothing about matching bytes. An incoming part is
//   * skipped when every second it holds is already covered (idempotent);
//   * inserted verbatim under a FRESH local part number when none is;
//   * carved otherwise: only the 60 s pyramid cells whose valid seconds are all
//     uncovered come in (SampleCodec.restrict), as a new part. Seconds in a
//     boundary cell that is only partly covered are not imported - the price of
//     carving a coded blob without the raw.
// The carve (a decode + re-encode) runs in a worker isolate; the reads and the
// insert stay on the calling transaction.
// Parts of one device-signal stay pairwise disjoint in absolute time.
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'sample_codec.dart';
import 'sample_zone.dart';

/// Where the carve runs. [Isolate.run] in production; a test swaps it to
/// record that the work is handed off.
Future<R> Function<R>(FutureOr<R> Function()) sampleCarveRunner = Isolate.run;

Uint8List sampleBytes(Object? v) =>
    v is Uint8List ? v : Uint8List.fromList((v as List).cast<int>());

/// Per signal, which seconds of [start, end) are already covered by archived
/// parts of [device] (any day label, any readable codec version), as a 0/1 mask
/// indexed from [start]. Unreadable parts are ignored.
Future<Map<String, Uint8List>> sampleCoverage(
  DatabaseExecutor ex, {
  required String device,
  required int start,
  required int end,
  String? signal,
  String? legacyDay,
}) async {
  final out = <String, Uint8List>{};
  final rows = await ex.query(
    'spectral_archive',
    columns: const ['day_id', 'signal', 'blob', 'origin_sec'],
    where: 'device_id = ? AND codec_version IN '
        '(${SampleCodec.readableVersions.join(',')})'
        '${signal == null ? '' : ' AND signal = ?'} '
        'AND ((origin_sec IS NOT NULL AND origin_sec < ? '
        'AND origin_sec + n_slots * slot_sec > ?) '
        'OR (origin_sec IS NULL AND day_id = ?))',
    whereArgs: [
      device,
      ?signal,
      end,
      start,
      legacyDay ?? '',
    ],
  );
  for (final r in rows) {
    final o = (r['origin_sec'] as num?)?.toInt() ??
        SampleZone.current.startOf(r['day_id'] as String);
    final mask = out.putIfAbsent(
        r['signal'] as String, () => Uint8List(end - start));
    try {
      for (final (a, b) in SampleCodec.validRuns(sampleBytes(r['blob']))) {
        final lo = o + a < start ? start : o + a;
        final hi = o + b > end ? end : o + b;
        for (var t = lo; t < hi; t++) {
          mask[t - start] = 1;
        }
      }
    } on FormatException {
      continue;
    }
  }
  return out;
}

/// The next free local part number of a (day, device, signal, version) key.
Future<int> sampleNextPart(DatabaseExecutor ex, String day, String device,
    String signal, int version) async {
  final r = await ex.rawQuery(
      'SELECT MAX(part) AS m FROM spectral_archive WHERE day_id = ? '
      'AND device_id = ? AND signal = ? AND codec_version = ?',
      [day, device, signal, version]);
  final m = (r.first['m'] as num?)?.toInt();
  return m == null ? 0 : m + 1;
}

/// Reconcile one incoming `spectral_archive` row with what [ex] holds. Returns
/// true when a row was written. Run it INSIDE the transaction that writes: the
/// coverage it reads and the part number it allocates (MAX + 1, plain INSERT)
/// are then the ones the insert sees.
Future<bool> importSamplePart(DatabaseExecutor ex, Map<String, Object?> row,
    {void Function(String)? log}) async {
  final day = row['day_id'] as String;
  final dev = (row['device_id'] as String?) ?? '';
  final sig = row['signal'] as String;
  final ver = (row['codec_version'] as num).toInt();
  final blob = sampleBytes(row['blob']);
  final origin = (row['origin_sec'] as num?)?.toInt() ??
      SampleZone.current.startOf(day);
  final readable = SampleCodec.readableVersions.contains(ver);

  late final SampleHeader h;
  late final List<(int, int)> runs;
  try {
    h = SampleCodec.readHeader(blob);
    runs = readable ? SampleCodec.validRuns(blob) : const [];
  } on FormatException catch (e) {
    log?.call('sample import: unreadable part $day/$dev/$sig skipped: $e');
    return false;
  }

  Future<bool> insert(Uint8List b, int nValid, double rms, double max,
      int nSlots) async {
    await ex.insert('spectral_archive', {
      'day_id': day,
      'device_id': dev,
      'signal': sig,
      'codec_version': ver,
      'part': await sampleNextPart(ex, day, dev, sig, ver),
      'blob': b,
      'n_valid': nValid,
      'rms_err': rms,
      'max_err': max,
      'created_at': (row['created_at'] as num?)?.toInt() ?? 0,
      'origin_sec': origin,
      'n_slots': nSlots,
      'slot_sec': (row['slot_sec'] as num?)?.toInt() ?? 1,
    });
    return true;
  }

  double num0(String k) => (row[k] as num?)?.toDouble() ?? 0;
  if (!readable) {
    // An opaque blob of a version this build cannot read: coverage cannot be
    // read, so it is kept as its own part rather than guessed at - once. The
    // same (device, signal, origin, bytes) arriving again is the same part.
    if (await _held(ex, day, dev, sig, ver, origin, blob)) return false;
    return insert(blob, (row['n_valid'] as num?)?.toInt() ?? 0, num0('rms_err'),
        num0('max_err'), h.length);
  }

  final cover = (await sampleCoverage(ex,
          device: dev,
          start: origin,
          end: origin + h.length,
          signal: sig,
          legacyDay: day))[sig] ??
      Uint8List(h.length);
  var valid = 0, overlapped = 0;
  final coveredMinute = <int>{};
  for (final (a, b) in runs) {
    for (var i = a; i < b; i++) {
      valid++;
      if (cover[i] == 1) {
        overlapped++;
        coveredMinute.add(i ~/ 60);
      }
    }
  }
  if (valid == 0 || overlapped == valid) return false; // nothing new
  if (overlapped == 0) {
    return insert(blob, h.nValid, num0('rms_err'), num0('max_err'), h.length);
  }
  if (ver != SampleCodec.codecVersion) {
    // An older generation (the lossy DCT) is read, never re-encoded: carving
    // it would be a silent re-encode. Part-covered, so it is left out.
    log?.call('sample import: version $ver part $day/$dev/$sig overlaps '
        'archived seconds and cannot be carved; skipped');
    return false;
  }
  final carved = await carveSamplePart(blob, coveredMinute,
      valid: valid,
      rmsErr: row['rms_err'],
      maxErr: row['max_err']);
  if (carved == null) return false;
  return insert(
      carved.blob, carved.nValid, carved.rmsErr, carved.maxErr, h.length);
}

/// Whether [ex] already holds a part with exactly these bytes for this device,
/// signal, codec version and absolute origin.
Future<bool> _held(DatabaseExecutor ex, String day, String dev, String sig,
    int ver, int origin, Uint8List blob) async {
  final rows = await ex.query('spectral_archive',
      columns: const ['blob'],
      where: 'device_id = ? AND signal = ? AND codec_version = ? AND '
          '((origin_sec IS NOT NULL AND origin_sec = ?) OR '
          '(origin_sec IS NULL AND day_id = ?))',
      whereArgs: [dev, sig, ver, origin, day]);
  for (final r in rows) {
    final b = sampleBytes(r['blob']);
    if (b.length != blob.length) continue;
    var same = true;
    for (var i = 0; i < b.length; i++) {
      if (b[i] != blob[i]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}

/// A carved part, ready to insert. Plain data, so it crosses isolates.
class SampleCarved {
  const SampleCarved(this.blob, this.nValid, this.rmsErr, this.maxErr);
  final Uint8List blob;
  final int nValid;
  final double rmsErr;
  final double maxErr;
}

/// Carve [blob] without the minute cells in [coveredMinutes], off the calling
/// isolate (invariant 10: the re-encode is the heavy part). Takes and returns
/// sendable values only; the closure captures nothing else, so no database
/// handle is dragged across. [valid] is the incoming part's valid-slot count
/// and [rmsErr] / [maxErr] its stored bounds (absent reads as 0).
Future<SampleCarved?> carveSamplePart(
  Uint8List blob,
  Set<int> coveredMinutes, {
  required int valid,
  Object? rmsErr,
  Object? maxErr,
}) {
  final rms = (rmsErr as num?)?.toDouble() ?? 0;
  final max = (maxErr as num?)?.toDouble() ?? 0;
  return sampleCarveRunner(() => carveSamplePartSync(
      blob, coveredMinutes, valid: valid, rmsErr: rms, maxErr: max));
}

/// The carve itself (also what the worker runs).
///
/// Error bounds, against the ORIGINAL raw, which is not available here:
///   * max: the incoming part's max (every kept sample was within it) plus this
///     re-encode's own max error (0 for lossless and pyramid-only), so never
///     below the incoming bound.
///   * rms: the kept samples are a subset, whose sum of squares is at most the
///     whole's, so rms_subset <= rms_whole * sqrt(valid_whole / valid_kept),
///     and never above the max; plus this re-encode's rms (Minkowski). The
///     whole's rms is NOT copied: the subset can be rougher than the whole.
SampleCarved? carveSamplePartSync(
  Uint8List blob,
  Set<int> coveredMinutes, {
  required int valid,
  required double rmsErr,
  required double maxErr,
}) {
  final enc = SampleCodec.restrict(blob, (m) => !coveredMinutes.contains(m));
  if (enc == null) return null;
  final kept = enc.stats.nValid;
  final subsetRms = kept == 0 || valid == 0
      ? 0.0
      : math.min(rmsErr * math.sqrt(valid / kept), maxErr);
  return SampleCarved(enc.blob, kept, subsetRms + enc.stats.rmsErr,
      maxErr + enc.stats.maxErr);
}
