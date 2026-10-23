// nap_resolution.dart — what keeping a nap does when it overlaps sleep.
//
// A kept nap that overlaps the main sleep or another nap EXTENDS that block to
// the union instead of being refused. [NapResolution] is the preview the user
// sees; a commit re-resolves inside its transaction and throws
// [NapResolutionChanged] (writing nothing) when the result no longer matches.

import 'package:sqflite/sqflite.dart';

import '../compute/derivation_engine.dart' show kAlgoVersion;
import '../compute/nap_edits.dart';
import '../models/activity_suggestion.dart' show ActivityReviewException;
import 'day_label.dart';

/// One block a kept nap overlaps. [kind] is 'main_sleep' or 'nap'; [day] is the
/// day_id that owns it.
typedef NapBlock = ({String kind, String day, int startTs, int endTs});

/// The bounds a kept nap ends up with (the union with every block it overlaps,
/// transitively; touching counts, a gap never does) and the blocks it extends.
typedef NapResolution = ({int startTs, int endTs, List<NapBlock> extended});

/// Thrown by a keep path when the re-resolved result differs from the one the
/// caller previewed. [now] is the current resolution; nothing was written.
class NapResolutionChanged implements Exception {
  NapResolutionChanged(this.now);
  final NapResolution now;
}

/// Told after a kept nap rewrote a main sleep (its override is committed), so
/// the owner of derivation can re-derive that night as a sleep edit does.
abstract class MainSleepExtendedListener {
  Future<void> mainSleepExtended(String day);
}

/// The one place that decides which sleep blocks a nap at [s]..[e] reaches.
class NapResolver {
  /// [grow] after checking the input is a 5 min..6 h nap.
  static Future<NapResolution> resolve(DatabaseExecutor tx, int s, int e) async {
    if (!manualNapWindowIsValid(s, e)) {
      throw const ActivityReviewException(
        'A nap must last between 5 minutes and 6 hours.',
      );
    }
    return grow(tx, s, e);
  }

  /// The transitive union of [s]..[e] with every non-rejected nap and main sleep
  /// it overlaps or touches. A gap is never bridged.
  static Future<NapResolution> grow(DatabaseExecutor tx, int s, int e) async {
    var start = s, end = e;
    final found = <NapBlock>[];
    var changed = true;
    while (changed) {
      changed = false;
      for (final b in await _blocks(tx, start, end)) {
        if (b.startTs > end || b.endTs < start) continue;
        if (!found.contains(b)) found.add(b);
        if (b.startTs < start) {
          start = b.startTs;
          changed = true;
        }
        if (b.endTs > end) {
          end = b.endTs;
          changed = true;
        }
      }
    }
    found.sort((a, b) => a.startTs.compareTo(b.startTs));
    return (startTs: start, endTs: end, extended: found);
  }

  /// Whether two resolutions mean the same write.
  static bool same(NapResolution a, NapResolution b) =>
      a.startTs == b.startTs &&
      a.endTs == b.endTs &&
      a.extended.length == b.extended.length &&
      a.extended.every(b.extended.contains);

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
