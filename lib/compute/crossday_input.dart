// The per-day records the cross-day rollup reads (`crossday_input` artifact),
// kept between passes so only a day whose stored result changed is read and
// decoded again. Pure Dart: the engine does the database reads and passes rows
// in.
//
// A stored record is valid for as long as its day's `day_result` row is the
// same row: same algo version, same `computed_at`, same `finalized`
// (`crossDayRowKey`). `is_today` / `unsettled` are NOT part of a stored record's
// identity. They describe the day the artifact is read on, so they are stripped
// from a reused record and stamped again from the current row and today's date,
// exactly as a from-scratch build stamps them.
//
// A rebuild from nothing and a reuse of every unchanged day produce the same
// records in the same order, so the encoded artifact is the same string.

import '../data/series_codec.dart';

/// Which `day_result` row a record was built from.
String crossDayRowKey(Map<String, dynamic> row) =>
    '${row['algo_version']}:${row['computed_at']}:${row['finalized']}';

/// A record kept from an earlier pass: the key of the row it came from, and the
/// record itself (null when that row yielded none — a skip marker, an
/// unreadable payload — so the row is not read again every pass).
typedef CrossDayKept = ({String key, Map<String, dynamic>? rec});

/// What an earlier artifact lets this pass keep, by day. Empty when it carries
/// no row keys (written before they existed), so such an artifact is rebuilt
/// once.
Map<String, CrossDayKept> keptCrossDayInput(Object? decoded) {
  if (decoded is! Map) return const {};
  final keys = decoded['row_keys'];
  final days = decoded['days'];
  if (keys is! Map || days is! List) return const {};
  final recs = <String, Map<String, dynamic>>{
    for (final d in days)
      if (d is Map && d['date'] is String)
        d['date'] as String: d.cast<String, dynamic>(),
  };
  return {
    for (final e in keys.entries)
      if (e.key is String && e.value is String)
        e.key as String: (key: e.value as String, rec: recs[e.key]),
  };
}

/// The days (newest first, as read) whose row differs from what [kept] holds,
/// so their full rows have to be read.
List<String> crossDayDaysToRead(
  List<Map<String, dynamic>> meta,
  Map<String, CrossDayKept> kept,
) => [
  for (final row in meta)
    if (kept[row['day_id']]?.key != crossDayRowKey(row)) row['day_id'] as String,
];

/// True when every row in [meta] is exactly what [decoded] was built from and
/// no other day is in it: the stored artifact is then what a rebuild would
/// write, so nothing is read, encoded or written.
bool crossDayInputCurrent(Object? decoded, List<Map<String, dynamic>> meta) {
  final kept = keptCrossDayInput(decoded);
  if (kept.length != meta.length) return false;
  for (final row in meta) {
    if (kept[row['day_id']]?.key != crossDayRowKey(row)) return false;
  }
  return true;
}

/// The artifact's records and row keys, oldest day first.
///
/// [meta] is the served rows newest first (payload-free); [full] holds the full
/// row of every day in [crossDayDaysToRead]; [makeRecord] is the engine's
/// record builder. A day in [meta] that is neither kept nor in [full] (its row
/// went away between the two reads) is left out; the next pass sees it again.
({List<Map<String, dynamic>> days, Map<String, String> keys})
assembleCrossDayInput({
  required List<Map<String, dynamic>> meta,
  required String today,
  required Map<String, CrossDayKept> kept,
  required Map<String, Map<String, dynamic>> full,
  required Map<String, dynamic>? Function(
    Map<String, dynamic> row,
    Map<String, dynamic> payload,
  )
  makeRecord,
}) {
  final days = <Map<String, dynamic>>[];
  final keys = <String, String>{};
  for (final m in meta.reversed) {
    final day = m['day_id'] as String;
    final metaKey = crossDayRowKey(m);
    Map<String, dynamic>? rec;
    String key;
    final k = kept[day];
    if (k != null && k.key == metaKey) {
      key = k.key;
      rec = k.rec == null ? null : (Map.of(k.rec!)
        ..remove('unsettled')
        ..remove('is_today'));
    } else {
      final row = full[day];
      if (row == null) continue;
      key = crossDayRowKey(row);
      final payload = SeriesCodec.decodePayloadJson(row['payload_json']);
      rec = payload == null || payload['skipped'] == true
          ? null
          : makeRecord(row, payload);
    }
    keys[day] = key;
    if (rec == null) continue;
    // Today's own row updates on every derive pass while the night is still
    // settling: FLAG it (never drop it) so the alert inputs can stand down.
    if (day == today && (m['finalized'] as num?) != 1) rec['unsettled'] = true;
    // Explicit identity for TODAY-scoped reads; `unsettled` is only set while
    // today is unfinalized.
    if (day == today) rec['is_today'] = true;
    days.add(rec);
  }
  return (days: days, keys: keys);
}
