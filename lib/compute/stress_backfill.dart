// ONE-SHOT BACKFILL — stored stress scores onto the recalibrated floor (#631).
//
// The Baevsky SI → 0-100 map used to floor at SI 20, so every genuinely low
// night (Baevsky's own "low" band is SI < 50) read as a flat 0 and high-HRV
// sleepers saw 0 every single night. The floor is now `kStressScoreFloorSi`.
// Every day derived before that change carries a score on the old scale, so the
// stress trend and the day-detail screen would show a step at the release date
// rather than a real change.
//
// WHY NOT JUST RE-DERIVE: raw 1 Hz substrate is pruned `rawRetentionDays` behind
// the data edge, so a kAlgoVersion bump alone can only fix the last few days.
//
// It does not need raw. The new score is a PURE function of the Baevsky index,
// and each stored day_result already carries its own `stress.si`.
//
// IN PLACE, NOT A NEW VERSION ROW. The rescale rewrites only the stress score
// (`stress.score`/`value`, `scalars.stress`, the `stress` trend point) of the
// rows that exist, at the version they already have. It does not stamp a day
// current, so:
//   * a day that still has raw is still re-derived by the version gate (no
//     guess at where the raw window ends is needed);
//   * the strain and readiness one-shots, which key on the row's version,
//     still see every day they are owed;
//   * provenance (device family, coverage, method stamps, naps) is untouched.
// The rewrite is idempotent (score = f(stored si)), so a row a fresh derive
// already wrote is a no-op.
//
// ONE source for the mapping: `stressScoreFromSi`, the same function the live
// derive calls.

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../data/bundle_store.dart';
import '../data/db.dart';
import '../data/series_codec.dart';
import '../util/callable.dart';
import '../util/heavy.dart';
import '../util/worker_init.dart';
import 'onehz_pipeline.dart' show stressScoreFromSi;

/// Test seam invoked after a day's worker rescale completes and before the DB
/// commit, to simulate a concurrent derive publishing a newer stress score.
@visibleForTesting
Call1<String, Future<void>>? debugStressBackfillBeforeCommit;

/// `compute_freshness` key marking the rescale as applied. Bumped with the algo
/// version so a later recalibration is a new one-shot rather than a no-op.
const String kStressRescaleKey = 'stress_rescale_v125';

class StressBackfillResult {
  /// Days whose `metric_series` stress score was rewritten (trend / v_daily).
  final int seriesDays;

  /// `day_result` rows whose stress score was rewritten in place.
  final int bundleDays;

  /// Rows left exactly as they were: no usable index, imported, or unreadable.
  final int skipped;

  const StressBackfillResult({
    required this.seriesDays,
    required this.bundleDays,
    required this.skipped,
  });

  bool get didWork => seriesDays > 0 || bundleDays > 0;
}

/// Pure per-row JSON decode, stress rescale, and re-encode run off the UI isolate.
@heavy
({bool skipped, bool imported, double? nextScore, String? encodedPayload})
    rescaleStressRowHeavy(WorkerInputs inputs, String payloadJson) {
  WorkerInit.ensure(inputs);
  final payload = _decode(payloadJson);
  final blk = payload?['stress'];
  final si = blk is Map ? _finite(blk['si']) : null;
  final next = stressScoreFromSi(si);
  final imported = payload?['imported'] == true;
  if (payload == null || next == null || imported) {
    return (
      skipped: true,
      imported: imported,
      nextScore: imported ? null : next,
      encodedPayload: null,
    );
  }
  final rounded = _round1(next);
  final scalars = payload['scalars'];
  if ((blk as Map)['score'] == rounded &&
      blk['value'] == rounded &&
      (scalars is! Map || scalars['stress'] == next)) {
    return (
      skipped: false,
      imported: false,
      nextScore: next,
      encodedPayload: null,
    );
  }
  blk['score'] = rounded;
  blk['value'] = rounded;
  if (scalars is Map) scalars['stress'] = next;
  return (
    skipped: false,
    imported: false,
    nextScore: next,
    encodedPayload: SeriesCodec.encodePayloadJson(jsonEncode(payload)),
  );
}

Future<({bool skipped, bool imported, double? nextScore, String? encodedPayload})>
    _rescaleOneStressRow(WorkerInputs inputs, String payloadJson) =>
        Isolate.run(() => rescaleStressRowHeavy(inputs, payloadJson));

/// Rescale every stored stress score in place. A one-shot once it has walked a
/// non-empty store; an empty store is not marked, so rows a restore merges in
/// later are still rescaled. Set [force] to re-run.
Future<StressBackfillResult> backfillStressScale({bool force = false}) async {
  const none = StressBackfillResult(seriesDays: 0, bundleDays: 0, skipped: 0);
  if (!force && await LocalDb.computeFreshness(kStressRescaleKey) != null) {
    return none;
  }

  final db = await LocalDb.instance;
  final days = [
    for (final r in await db.rawQuery(
        'SELECT DISTINCT day_id FROM day_result WHERE day_id IS NOT NULL '
        'ORDER BY day_id'))
      r['day_id'] as String,
  ];
  if (days.isEmpty) return none;

  final workerInputs = WorkerInputs(
    nowEpochMs: DateTime.now().millisecondsSinceEpoch,
    zoneId: 'UTC',
    localeTag: 'en',
  );
  var seriesDays = 0;
  var bundleDays = 0;
  var skipped = 0;
  var anyRaced = false;
  final touchedDays = <String>{};

  for (final day in days) {
    final rows = await db.query('day_result',
        columns: ['algo_version', 'payload_json', 'partial'],
        where: 'day_id = ?',
        whereArgs: [day],
        orderBy: 'algo_version DESC');
    // The build that last wrote this day's series, when stamped.
    final stampRow = (await db.query('metric_series_version',
            columns: ['algo_version', 'source'],
            where: 'date = ?',
            whereArgs: [day]))
        .firstOrNull;
    final stamp = (stampRow?['algo_version'] as num?)?.toInt();
    final maxObservedComplete = rows
        .where((r) => (r['partial'] as num?)?.toInt() != 1)
        .map((r) => (r['algo_version'] as num?)?.toInt())
        .whereType<int>()
        .fold<int?>(null, (a, b) => a == null || b > a ? b : a);
    double? seriesScore;
    var seriesPicked = false;
    int? writerVer;
    String? writerRaw;
    var writerNeedsUpdate = false;
    final updates = <({int ver, String raw, String encoded})>[];
    for (final row in rows) {
      final ver = (row['algo_version'] as num).toInt();
      final raw = row['payload_json'];
      final res = raw is String
          ? await _rescaleOneStressRow(workerInputs, raw)
          : (skipped: true, imported: false, nextScore: null, encodedPayload: null);
      // The trend point comes ONLY from the row that wrote it: the stamped
      // writer, else the newest complete row (a partial row never writes the
      // series). If that row has no usable score the trend stays as it is.
      if (!seriesPicked &&
          (row['partial'] as num?)?.toInt() != 1 &&
          (stamp == null || ver == stamp)) {
        seriesPicked = true;
        if (!res.imported && res.nextScore != null && raw is String) {
          seriesScore = res.nextScore;
          writerVer = ver;
          writerRaw = raw;
          writerNeedsUpdate = res.encodedPayload != null;
        }
      }
      // No usable index, or another source's day: a rescaled day must not
      // become 0 (a score, not an absence), and an imported score is not
      // ours to re-price.
      if (res.skipped) {
        skipped++;
        continue;
      }
      final encoded = res.encodedPayload;
      if (encoded == null) continue; // already on the new scale
      updates.add((ver: ver, raw: raw as String, encoded: encoded));
    }
    if (updates.isEmpty && seriesScore == null) continue;
    await debugStressBackfillBeforeCommit?.call(day);
    // One transaction per day: re-verify the observed series writer and apply
    // every bundle CAS + the trend point atomically through LocalDb's P2.1
    // write seam. If a derive replaced a row or published a newer writer while
    // the worker ran, the trend point stays untouched and this pass does not
    // stamp done so the next pass revisits.
    await db.transaction((txn) async {
      final curStampRow = (await txn.query('metric_series_version',
              columns: ['algo_version', 'source'],
              where: 'date = ?',
              whereArgs: [day]))
          .firstOrNull;
      final curStamp = (curStampRow?['algo_version'] as num?)?.toInt();
      final curSource = (curStampRow?['source'] as String?) ?? 'band';
      final curTopComplete = ((await txn.rawQuery(
                  'SELECT MAX(algo_version) AS v FROM day_result '
                  'WHERE day_id = ? AND COALESCE(partial, 0) != 1',
                  [day]))
              .firstOrNull?['v'] as num?)
          ?.toInt();
      var dayRaced = curStamp != stamp ||
          (stamp == null && curTopComplete != maxObservedComplete);
      var writerStillMatches = !dayRaced && curSource == 'band';
      for (final u in updates) {
        final wrote = await LocalDb.rewriteDayPayload(
          day,
          u.ver,
          u.encoded,
          expectedPayloadJson: u.raw,
          executor: txn,
        );
        if (wrote) {
          bundleDays++;
          touchedDays.add(day);
        } else {
          dayRaced = true;
          if (u.ver == writerVer) writerStillMatches = false;
        }
      }
      if (writerStillMatches && writerVer != null && !writerNeedsUpdate) {
        final check = await txn.query('day_result',
            columns: ['algo_version'],
            where: 'day_id = ? AND algo_version = ? AND payload_json = ?',
            whereArgs: [day, writerVer, writerRaw],
            limit: 1);
        if (check.isEmpty) {
          dayRaced = true;
          writerStillMatches = false;
        }
      }
      if (dayRaced) anyRaced = true;
      if (seriesScore == null || !writerStillMatches) return;
      // UPDATE only: never create a trend point the derive did not write, and
      // leave a day whose series another source produced alone.
      final n = await txn.rawUpdate(
        "UPDATE metric_series SET value = ? WHERE date = ? AND key = 'stress' "
        'AND (value IS NULL OR value <> ?) AND NOT EXISTS (SELECT 1 FROM '
        'metric_series_version v WHERE v.date = ? AND COALESCE(v.source, \'band\') '
        "<> 'band')",
        [seriesScore, day, seriesScore, day],
      );
      if (n > 0) seriesDays++;
    });
  }

  if (touchedDays.isNotEmpty) BundleStore.shared.invalidateDays(touchedDays);
  if (!anyRaced) {
    await LocalDb.putComputeFreshness(kStressRescaleKey, '{"done":true}');
  }
  return StressBackfillResult(
    seriesDays: seriesDays,
    bundleDays: bundleDays,
    skipped: skipped,
  );
}

/// A finite number, or null — a wrong-typed index is skipped, not thrown on.
double? _finite(Object? v) {
  if (v is! num) return null;
  final d = v.toDouble();
  return d.isFinite ? d : null;
}

double _round1(double v) => (v * 10).round() / 10;

Map<String, dynamic>? _decode(Object? json) {
  if (json is! String) return null;
  try {
    final v = jsonDecode(json);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}
