// spectral_archive.dart — EXPERIMENT (branch explore/spectral-archive): the
// side table `spectral_archive` and the one writer that fills it before raw
// pruning.
//
// RED PHASE: throwing stubs; test/spectral/ pins the contract.
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
// Heavy work (reading a day's rows, DCT, error search) runs in `Isolate.run`
// (invariant 10). Day labels are LOCAL (`localDayStartSec`/`localDayLengthSec`,
// invariant 7); `nowSec` is injected, never read from the clock here.

import 'dart:typed_data';

import 'spectral_codec.dart' show SpectralLevel;

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

  /// Archive every local day that has at least one `decoded_onehz` row with
  /// `rec_ts < cutoffSec` (so the day straddling the cutoff is archived whole,
  /// while its later seconds still exist). Returns the number of
  /// (day, signal) rows written. Never overwrites a row with one built from
  /// FEWER valid samples (a half-pruned day re-archived later must not clobber
  /// the full one). A signal with zero valid samples that day gets no row.
  static Future<int> archiveBefore(int cutoffSec, {required int nowSec}) =>
      throw UnimplementedError('SpectralArchiver.archiveBefore');

  /// One local day, same rules as [archiveBefore].
  static Future<int> archiveDay(String dayId, {required int nowSec}) =>
      throw UnimplementedError('SpectralArchiver.archiveDay');

  /// Stored rows for [dayId], ordered by signal.
  static Future<List<SpectralArchiveRow>> rows(String dayId) =>
      throw UnimplementedError('SpectralArchiver.rows');

  /// The reconstruction of one signal of one day (null elements = absent), or
  /// null when no archive row exists. For display/export only.
  static Future<List<double?>?> reconstruct(String dayId, String signal,
          {int? maxOrder}) =>
      throw UnimplementedError('SpectralArchiver.reconstruct');

  /// The LOD pyramid of one signal of one day straight from the stored blob (no
  /// coefficient decode), so a week / month / year chart can draw from
  /// summaries. Null when no archive row exists.
  static Future<List<SpectralLevel>?> summary(String dayId, String signal) =>
      throw UnimplementedError('SpectralArchiver.summary');
}
