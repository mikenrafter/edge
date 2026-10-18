// cardio_rows_blob.dart — the engine's cardio feature rows as encoded text, and
// the worker-side steps that read and write it.
//
// The UI isolate holds the rows it reuses across stagings ONLY as UTF-8 JSON
// chunks (`CardioRowCache.toJson`, jsonEncode'd) with their time bounds as plain
// ints. It never parses, merges, filters or encodes them: a staging or
// checkpoint worker is handed the chunks that overlap its window, does all of
// that, and hands back one encoded chunk (AGENTS.md 3.10).

import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../util/heavy.dart';

/// One encoded run of cache rows: [json] holds rows whose `startSec` all lie in
/// [loSec, hiSec] (inclusive). Plain data, so it crosses to a worker as is.
class CardioRowsChunk {
  const CardioRowsChunk(this.json, this.loSec, this.hiSec);
  final Uint8List json;
  final int loSec, hiSec;

  /// True when this chunk may hold a row with a start in [lo, hi].
  bool overlaps(int lo, int hi) => hiSec >= lo && loSec <= hi;
}

/// The union of the rows in [chunks]. A chunk that cannot be read (damage, an
/// unknown version) is skipped whole: its rows recompute, they are never
/// guessed.
@heavy
ana.CardioRowCache mergeCardioRowChunksHeavy(List<Uint8List> chunks) {
  final all = ana.CardioRowCache();
  for (final c in chunks) {
    try {
      all.merge(ana.CardioRowCache.fromJson(
          (jsonDecode(utf8.decode(c)) as Map).cast<String, dynamic>()));
    } catch (_) {
      // refuse, never guess
    }
  }
  return all;
}

/// [rows] as the UTF-8 JSON text chunks and checkpoints store.
@heavy
Uint8List encodeCardioRowsHeavy(ana.CardioRowCache rows) =>
    Uint8List.fromList(utf8.encode(jsonEncode(rows.toJson())));
