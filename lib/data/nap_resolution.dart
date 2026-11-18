// nap_resolution.dart — what keeping a nap does when it overlaps sleep.
//
// The merge a kept nap needs is decided by SleepSpacing (30-minute rule) and
// applied by SleepBlockWriter; this file keeps the shared block types and the
// one query that finds the live blocks near an interval.

import 'package:sqflite/sqflite.dart';

import '../compute/derivation_engine.dart' show kAlgoVersion;
import 'day_label.dart';

/// One block a kept nap overlaps. [kind] is 'main_sleep' or 'nap'; [day] is the
/// day_id that owns it.
typedef NapBlock = ({String kind, String day, int startTs, int endTs});

/// The bounds a kept nap ends up with (the union with every block it overlaps,
/// transitively; touching counts, a gap never does) and the blocks it extends.
typedef NapResolution = ({int startTs, int endTs, List<NapBlock> extended});

/// Told after a kept nap rewrote a main sleep (its override is committed), so
/// the owner of derivation can re-derive that night as a sleep edit does.
abstract class MainSleepExtendedListener {
  Future<void> mainSleepExtended(String day);
}

/// Told after an activity suggestion was answered, so the pending count and
/// queue are re-read.
abstract class ActivitiesChangedListener {
  Future<void> activitiesChanged();
}

/// The one place that decides which sleep blocks a nap at [s]..[e] reaches.
class NapResolver {
  /// Every live block within [margin] seconds of [s]..[e]: the one place the
  /// spacing rule asks "who is near this interval?".
  static Future<List<NapBlock>> near(
    DatabaseExecutor tx,
    int s,
    int e, {
    int margin = 0,
  }) => _blocks(tx, s - margin, e + margin);

  /// Candidates near [s]..[e]: naps that touch it, and the main sleeps owned by
  /// the calendar days around it (an evening interval can overlap the night
  /// owned by tomorrow's wake date). Reads window_json and scalars only.
  static Future<List<NapBlock>> _blocks(
    DatabaseExecutor tx,
    int s,
    int e,
  ) async {
    final out = <NapBlock>[];
    final naps = await tx.rawQuery(
      "SELECT day_id, start_ts, end_ts FROM sleep_nap "
      "WHERE source != 'rejected' AND start_ts <= ? AND end_ts >= ?",
      [e, s],
    );
    for (final r in naps) {
      out.add((
        kind: 'nap',
        day: r['day_id'] as String,
        startTs: (r['start_ts'] as num).toInt(),
        endTs: (r['end_ts'] as num).toInt(),
      ));
    }
    final first = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(s * 1000));
    final endDt = DateTime.fromMillisecondsSinceEpoch(e * 1000);
    final last = dayLabelOf(DateTime(endDt.year, endDt.month, endDt.day + 1));
    final overrides = await tx.rawQuery(
      'SELECT day_id, onset_ts, offset_ts, source FROM sleep_override '
      'WHERE day_id BETWEEN ? AND ?',
      [first, last],
    );
    final overridden = <String>{};
    for (final r in overrides) {
      overridden.add(r['day_id'] as String);
      if (r['source'] == 'rejected') continue;
      out.add((
        kind: 'main_sleep',
        day: r['day_id'] as String,
        startTs: (r['onset_ts'] as num).toInt(),
        endTs: (r['offset_ts'] as num).toInt(),
      ));
    }
    final detected = await tx.rawQuery(
      '''SELECT d.day_id,
        CASE WHEN json_valid(d.window_json)
          THEN json_extract(d.window_json, '\$.value.onset_ms') END AS on_ms,
        CASE WHEN json_valid(d.window_json)
          THEN json_extract(d.window_json, '\$.value.offset_ms') END AS off_ms
      FROM day_result d
      WHERE d.day_id BETWEEN ? AND ? AND d.algo_version =
        (SELECT MAX(r.algo_version) FROM day_result r WHERE r.day_id = d.day_id AND r.algo_version <= ?)''',
      [first, last, kAlgoVersion],
    );
    for (final r in detected) {
      final day = r['day_id'] as String;
      if (overridden.contains(day)) continue;
      // Absent metric envelopes store '—', not a window object: NULL here.
      final on = r['on_ms'] as num?, off = r['off_ms'] as num?;
      if (on == null || off == null) continue;
      out.add((
        kind: 'main_sleep',
        day: day,
        startTs: on.toInt() ~/ 1000,
        endTs: off.toInt() ~/ 1000,
      ));
    }
    return out;
  }
}
