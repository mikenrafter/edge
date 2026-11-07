part of '../db.dart';

/// One batch of curve re-encodes: for each input bundle, the compacted
/// replacement, or null when the row must be left exactly as it is.
///
/// TOP-LEVEL and pure so it can be handed to `Isolate.run` — it touches nothing
/// but `SeriesCodec`, which has no I/O, no plugins and no Flutter. The null
/// cases are all "leave it legacy": already encoded, not provably lossless
/// (see `verifyLossless` — this OVERWRITES durable user data, and a day past
/// `rawRetentionDays` has no substrate left to re-derive from), or an encode
/// that did not actually shrink the row.
List<String?> _reencodeBatch(List<String> payloads) {
  final out = <String?>[];
  for (final pj in payloads) {
    if (pj.isEmpty ||
        !SeriesCodec.needsReencode(pj) ||
        !SeriesCodec.verifyLossless(pj)) {
      out.add(null);
      continue;
    }
    final encoded = SeriesCodec.encodePayloadJson(pj);
    out.add(encoded.length < pj.length ? encoded : null);
  }
  return out;
}
