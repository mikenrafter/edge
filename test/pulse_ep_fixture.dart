// Deterministic irregular beats for the Pulse worker tests: independent
// intervals of 600-1300 ms qualify under the fixed floors (SD1/SD2 near 1,
// pNN70 well above 30%). Rows are in the shape decoded_rr stores them.
import 'dart:math';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:sqflite/sqflite.dart';

typedef PulseRow = ({int tsMs, int beatIndex, int beatTsMs, int rrMs});

List<PulseRow> irregularRows(int startMs, int minutes, {int seed = 17}) {
  final random = Random(seed);
  final rows = <PulseRow>[];
  var t = startMs;
  var lastSecond = -1, index = 0;
  while (t < startMs + minutes * 60000) {
    final rr = 600 + random.nextInt(700);
    t += rr;
    final second = (t ~/ 1000) * 1000;
    index = second == lastSecond ? index + 1 : 0;
    lastSecond = second;
    rows.add((tsMs: second, beatIndex: index, beatTsMs: t, rrMs: rr));
  }
  return rows;
}

List<ana.PulseBeatInput> beatInputs(String source, List<PulseRow> rows) => [
  for (var i = 0; i < rows.length; i++)
    ana.PulseBeatInput(
      id: '$source:${rows[i].tsMs}:${rows[i].beatIndex}',
      source: source,
      index: i,
      timeMs: rows[i].beatTsMs,
      rawMs: rows[i].rrMs.toDouble(),
    ),
];

Future<void> insertRows(Database db, String source, List<PulseRow> rows) async {
  final batch = db.batch();
  for (final r in rows) {
    batch.insert('decoded_rr', {
      'device_id': source,
      'ts_ms': r.tsMs,
      'rec_ts': r.tsMs ~/ 1000,
      'beat_index': r.beatIndex,
      'rr_ts_ms': r.tsMs,
      'beat_ts_ms': r.beatTsMs,
      'rr_ms': r.rrMs,
    });
  }
  await batch.commit(noResult: true);
}

/// The same rows as the maps `PulseEpisodeWorker.readBeatRows` returns.
List<Map<String, Object?>> rowMaps(List<PulseRow> rows) => [
  for (final r in rows)
    {'ts_ms': r.tsMs, 'beat_index': r.beatIndex, 'beat_ts_ms': r.beatTsMs, 'rr_ts_ms': r.tsMs, 'rr_ms': r.rrMs},
];
