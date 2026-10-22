// manifest_codec.dart — the publication manifest as a value, and its
// `day_manifest` row (design 06 phase 1e).
//
// Pure: no database. A manifest names, for one day, the revision of every
// group that makes up a published bundle, the bundle's key order, the hashes
// of the bundle text and of the scalar projection written with it, and the
// freshness of the very write it describes. Encoding is deterministic (maps
// are written key-sorted; `keyOrder` keeps its order, which IS the payload
// order), so equal manifests make equal rows.
//
// `compat` is the layout version of the row. A reader serves the latest
// manifest at or below its own [kManifestCompat] and skips a newer build's
// rows without decoding them, mirroring `_servedAlgoCeiling`.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

/// The manifest layout this build writes and reads. Bump only when a reader
/// of the old layout would misread a new row.
const int kManifestCompat = 1;

class Manifest {
  const Manifest({
    required this.dayId,
    required this.manifestSeq,
    required this.compat,
    required this.registryVersion,
    required this.selected,
    required this.keyOrder,
    required this.bundleSha,
    required this.seriesSha,
    required this.freshness,
    required this.publishedAt,
  });

  final String dayId;
  final int manifestSeq;
  final int compat;
  final int registryVersion;

  /// Group id -> the revision of that group this publication names.
  final Map<String, int> selected;

  /// Bundle paths in payload order (top-level keys, `block.key` inside mixed
  /// blocks).
  final List<String> keyOrder;

  /// sha-256 of the stored `payload_json` text.
  final String bundleSha;

  /// [seriesSha] of the scalar projection written with the bundle.
  final String seriesSha;

  /// What the write was: algo_version, finalized, partial, computed_at.
  final Map<String, Object?> freshness;

  final int publishedAt;
}

/// Same value, key-sorted at every depth.
Object? _sorted(Object? v) {
  if (v is Map) {
    return {
      for (final k in (v.keys.map((e) => '$e').toList()..sort())) k: _sorted(v[k]),
    };
  }
  if (v is List) return [for (final e in v) _sorted(e)];
  return v;
}

Map<String, Object?> manifestToRow(Manifest m) => {
      'day_id': m.dayId,
      'manifest_seq': m.manifestSeq,
      'compat': m.compat,
      'registry_version': m.registryVersion,
      'selected_json': jsonEncode(_sorted(m.selected)),
      'key_order_json': jsonEncode(m.keyOrder),
      'bundle_sha': m.bundleSha,
      'series_sha': m.seriesSha,
      'freshness_json': jsonEncode(_sorted(m.freshness)),
      'published_at': m.publishedAt,
    };

/// Throws (a cast or format error) on a row that is not a manifest.
Manifest manifestFromRow(Map<String, Object?> row) {
  final selected = jsonDecode(row['selected_json'] as String) as Map;
  final order = jsonDecode(row['key_order_json'] as String) as List;
  final fresh = jsonDecode(row['freshness_json'] as String) as Map;
  return Manifest(
    dayId: row['day_id'] as String,
    manifestSeq: (row['manifest_seq'] as num).toInt(),
    compat: (row['compat'] as num).toInt(),
    registryVersion: (row['registry_version'] as num).toInt(),
    selected: {for (final e in selected.entries) e.key as String: (e.value as num).toInt()},
    keyOrder: [for (final p in order) p as String],
    bundleSha: row['bundle_sha'] as String,
    seriesSha: row['series_sha'] as String,
    freshness: Map<String, Object?>.from(fresh),
    publishedAt: (row['published_at'] as num).toInt(),
  );
}

/// [manifestFromRow] that never throws: null for a compat above [maxCompat]
/// (not even parsed: a newer layout may not be JSON this build understands)
/// and for a row that does not decode.
Manifest? tryDecodeManifest(Map<String, Object?> row,
    {int maxCompat = kManifestCompat}) {
  try {
    final compat = row['compat'];
    if (compat is! num || compat.toInt() > maxCompat) return null;
    return manifestFromRow(row);
  } catch (_) {
    return null;
  }
}

/// sha-256 (hex) of the UTF-8 bytes of [text].
String sha256Hex(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();

/// Hash of a scalar projection: key-sorted, null kept as null, so the same
/// map in any insertion order hashes the same and a blanked key differs from
/// an absent one.
String seriesSha(Map<String, double?> series) => sha256Hex(jsonEncode({
      for (final k in (series.keys.toList()..sort())) k: series[k],
    }));
