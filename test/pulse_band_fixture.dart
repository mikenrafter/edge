// Pulse fixtures in the shape the band writes: device_id '', one record per
// second holding the 0-4 beats that ended in it, beat times from the
// production `beatTimesMs` (last beat at the record's stamp, earlier beats
// walked back by their intervals), and the occasional anchor that puts a
// record's first beat before the previous record's last one. The older fixtures
// put one beat in each record and could not show any of this.
import 'dart:math';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'package:openstrap_edge/compute/substrate.dart' show beatTimesMs;
import 'package:sqflite/sqflite.dart';

/// Irregular (rr 750-1250 ms, independent) beats for [minutes] from [startMs].
/// [regressAtMs] puts the beat nearest that instant 6 s before the one it
/// follows: a clock that really went backwards, beyond any record overlap.
List<Map<String, Object?>> bandRows(
  int startMs,
  int minutes, {
  int seed = 17,
  String device = '',
  double overlapRate = 0.3,
  int? regressAtMs,
}) {
  final random = Random(seed);
  final truth = <int>[], rrs = <int>[];
  var t = startMs.toDouble();
  while (t < startMs + minutes * 60000) {
    final rr = 750 + random.nextInt(500);
    t += rr;
    truth.add(t.round());
    rrs.add(rr);
  }
  // One record per second: the beats that ended in it and where in the second
  // its stamp falls (close to the last beat, as the band's own stamp is).
  final records = <({int second, List<int> ids, int within})>[];
  var k = 0;
  while (k < truth.length) {
    final second = truth[k] ~/ 1000;
    final ids = <int>[];
    while (k < truth.length && truth[k] ~/ 1000 == second) {
      ids.add(k++);
    }
    final within = (truth[ids.last] % 1000 + random.nextInt(60) - 30)
        .clamp(0, 999)
        .toInt();
    records.add((second: second, ids: ids, within: within));
  }
  // The overlaps real rows have: a record holding several beats whose stamp
  // sits early in its second, after a record stamped late in its own, walks its
  // first beat back to before that record's last beat.
  final early = <int>{};
  for (var i = 1; i < records.length; i++) {
    if (records[i].ids.length > 1 && random.nextDouble() < overlapRate) {
      early.add(i);
    }
  }
  final rows = <Map<String, Object?>>[];
  for (var i = 0; i < records.length; i++) {
    final r = records[i];
    final within = early.contains(i)
        ? random.nextInt(30)
        : early.contains(i + 1)
            ? 960 + random.nextInt(39)
            : r.within;
    final subsec = (within * 32768 / 1000).ceil();
    final times = beatTimesMs(r.second, subsec, [for (final j in r.ids) rrs[j]]);
    for (var j = 0; j < r.ids.length; j++) {
      rows.add({
        'device_id': device,
        'ts_ms': r.second * 1000,
        'rec_ts': r.second,
        'beat_index': j,
        'rr_ts_ms': r.second * 1000,
        'beat_ts_ms': times[j],
        'rr_ms': rrs[r.ids[j]],
      });
    }
  }
  if (regressAtMs != null) {
    final i = rows.indexWhere((r) => (r['beat_ts_ms'] as int) >= regressAtMs);
    rows[i]['beat_ts_ms'] = (rows[i - 1]['beat_ts_ms'] as int) - 6000;
  }
  return rows;
}

/// How many beats sit at or before the beat that precedes them in row order.
int stepsBack(List<Map<String, Object?>> rows) {
  var n = 0;
  for (var i = 1; i < rows.length; i++) {
    if ((rows[i]['beat_ts_ms'] as int) <= (rows[i - 1]['beat_ts_ms'] as int)) {
      n++;
    }
  }
  return n;
}

Future<void> insertRows(Database db, List<Map<String, Object?>> rows) async {
  final batch = db.batch();
  for (final r in rows) {
    batch.insert('decoded_rr', r, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

/// A [PulseWorkerProbe] that runs [fn] where a live record could land.
class ProbeFn implements PulseWorkerProbe {
  const ProbeFn(this.fn);
  final Future<void> Function(String day) fn;
  @override
  Future<void> afterRead(String day) => fn(day);
}
