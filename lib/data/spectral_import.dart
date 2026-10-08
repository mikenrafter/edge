// spectral_import.dart - coverage bookkeeping shared by the archiver and the
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
//     uncovered come in (SpectralCodec.restrict), as a new part. Seconds in a
//     boundary cell that is only partly covered are not imported - the price of
//     carving a coded blob without the raw.
// Parts of one device-signal stay pairwise disjoint in absolute time.
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'spectral_codec.dart';
import 'spectral_zone.dart';

Uint8List spectralBytes(Object? v) =>
    v is Uint8List ? v : Uint8List.fromList((v as List).cast<int>());

/// Per signal, which seconds of [start, end) are already covered by archived
/// parts of [device] (any day label), as a 0/1 mask indexed from [start].
/// Unreadable parts are ignored.
Future<Map<String, Uint8List>> spectralCoverage(
  DatabaseExecutor ex, {
  required String device,
  required int version,
  required int start,
  required int end,
  String? signal,
  String? legacyDay,
}) async {
  final out = <String, Uint8List>{};
  final rows = await ex.query(
    'spectral_archive',
    columns: const ['day_id', 'signal', 'blob', 'origin_sec'],
    where: 'device_id = ? AND codec_version = ?'
        '${signal == null ? '' : ' AND signal = ?'} '
        'AND ((origin_sec IS NOT NULL AND origin_sec < ? '
        'AND origin_sec + n_slots * slot_sec > ?) '
        'OR (origin_sec IS NULL AND day_id = ?))',
    whereArgs: [
      device,
      version,
      ?signal,
      end,
      start,
      legacyDay ?? '',
    ],
  );
  for (final r in rows) {
    final o = (r['origin_sec'] as num?)?.toInt() ??
        SpectralZone.current.startOf(r['day_id'] as String);
    final mask = out.putIfAbsent(
        r['signal'] as String, () => Uint8List(end - start));
    try {
      for (final (a, b) in SpectralCodec.validRuns(spectralBytes(r['blob']))) {
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
Future<int> spectralNextPart(DatabaseExecutor ex, String day, String device,
    String signal, int version) async {
  final r = await ex.rawQuery(
      'SELECT MAX(part) AS m FROM spectral_archive WHERE day_id = ? '
      'AND device_id = ? AND signal = ? AND codec_version = ?',
      [day, device, signal, version]);
  final m = (r.first['m'] as num?)?.toInt();
  return m == null ? 0 : m + 1;
}

/// Reconcile one incoming `spectral_archive` row with what [ex] holds. Returns
/// true when a row was written.
Future<bool> importSpectralPart(DatabaseExecutor ex, Map<String, Object?> row,
    {void Function(String)? log}) async {
  final day = row['day_id'] as String;
  final dev = (row['device_id'] as String?) ?? '';
  final sig = row['signal'] as String;
  final ver = (row['codec_version'] as num).toInt();
  final blob = spectralBytes(row['blob']);
  final origin = (row['origin_sec'] as num?)?.toInt() ??
      SpectralZone.current.startOf(day);

  late final SpectralHeader h;
  late final List<(int, int)> runs;
  try {
    h = SpectralCodec.readHeader(blob);
    if (ver == SpectralCodec.codecVersion) {
      runs = SpectralCodec.validRuns(blob);
    } else {
      runs = const [];
    }
  } on FormatException catch (e) {
    log?.call('spectral import: unreadable part $day/$dev/$sig skipped: $e');
    return false;
  }

  Future<bool> insert(Uint8List b, int nValid, double rms, double max,
      int nSlots) async {
    await ex.insert('spectral_archive', {
      'day_id': day,
      'device_id': dev,
      'signal': sig,
      'codec_version': ver,
      'part': await spectralNextPart(ex, day, dev, sig, ver),
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
  if (ver != SpectralCodec.codecVersion) {
    // An opaque blob of another codec version: coverage cannot be read, so it
    // is kept as its own part rather than guessed at.
    return insert(blob, (row['n_valid'] as num?)?.toInt() ?? 0, num0('rms_err'),
        num0('max_err'), h.length);
  }

  final cover = (await spectralCoverage(ex,
          device: dev,
          version: ver,
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
  final enc = SpectralCodec.restrict(blob, (m) => !coveredMinute.contains(m));
  if (enc == null) return false;
  final spec = SpectralCodec.specs[sig];
  double rms, max;
  switch (h.mode) {
    case SpectralMode.pyramidOnly:
      rms = 0;
      max = 0;
    case SpectralMode.losslessAtQuantum:
      rms = num0('rms_err');
      max = num0('max_err');
    case SpectralMode.adaptive:
    case SpectralMode.staticBlocks:
      // Second generation: vs the original raw the error is at most the first
      // generation's (every segment met the spec) plus this re-encode's.
      rms = (spec?.maxRms ?? num0('rms_err')) + enc.stats.rmsErr;
      max = num0('max_err') + enc.stats.maxErr;
  }
  return insert(enc.blob, enc.stats.nValid, rms, max, h.length);
}
