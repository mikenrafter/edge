// Owner: pulse episode worker. Reads committed decoded beats after sync/ACK;
// never writes raw, decoded, daily output or the BLE cursor.
import 'dart:isolate';
import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../data/db.dart';
import '../data/pulse_episode_store.dart';
import '../util/heavy.dart';
import '../util/worker_init.dart';
import '../util/worker_audit.dart';
import 'processing_context.dart';
import 'pulse_episode_delivery.dart';

@visibleForTesting
abstract interface class PulseWorkerProbe {
  Future<void> afterRead(String day);
}

/// What a worker run could not finish. Never an error the caller must handle:
/// [PulseEpisodeWorker.run] always returns.
class PulseRunResult {
  /// Days whose input moved between the read and the commit; the next pass
  /// reads them again.
  final Set<String> retryDays;

  /// Days that failed with an error, and the error.
  final Map<String, String> failedDays;
  const PulseRunResult(this.retryDays, this.failedDays);
  static const clean = PulseRunResult({}, {});

  /// Days no pulse decision exists for yet. Raw beats of these are not pruned.
  Set<String> get unevaluatedDays => {...retryDays, ...failedDays.keys};
}

class PulseEpisodeWorker {
  /// Test seam: called after a day's rows were read and before it is
  /// reconciled, where a live record can land.
  @visibleForTesting
  static PulseWorkerProbe? probe;

  /// A detection window reads this far either side of itself.
  static const _support = ana.pulseWindowMs;
  // A record's beats sit up to a few seconds before its second; the read is
  // widened so every beat whose time is in range is also in the rows.
  static const _slack = 10000;

  /// Never throws: a pulse failure must not end the derive pass that called it.
  /// Each day is contained on its own, and retention and delivery always run, so
  /// episodes saved earlier in the pass still alert.
  static Future<PulseRunResult> run(
    Iterable<String> days, {
    required ProcessingContext processingContext,
  }) async {
    final retry = <String>{}, failed = <String, String>{};
    final ordered = days.toList()..sort();
    try {
      final db = await LocalDb.instance;
      final store = PulseEpisodeStore(db);
      final now = DateTime.now().millisecondsSinceEpoch;
      await store.initializeUpgrade(nowMs: now);
      for (final day in ordered) {
        try {
          await _day(db, store, day, processingContext, now);
        } on PulseInputChanged {
          retry.add(day);
        } catch (e) {
          failed[day] = '$e';
        }
      }
      try {
        await store.retain(nowMs: now);
      } catch (e) {
        failed['retention'] = '$e';
      }
    } catch (e) {
      for (final day in ordered) {
        failed.putIfAbsent(day, () => '$e');
      }
    }
    try {
      await PulseEpisodeDelivery.run();
    } catch (e) {
      failed['delivery'] = '$e';
    }
    return PulseRunResult(retry, failed);
  }

  static Future<void> _day(
    Database db,
    PulseEpisodeStore store,
    String day,
    ProcessingContext processingContext,
    int now,
  ) async {
    final date = DateTime.tryParse(day);
    if (date == null) return;
    final start = DateTime(
      date.year,
      date.month,
      date.day,
    ).millisecondsSinceEpoch;
    final end = DateTime(
      date.year,
      date.month,
      date.day + 1,
    ).millisecondsSinceEpoch;
    // First arrival by band sync, recorded at commit time of the pass that
    // carried it: windows only close later, under a pass that may not name this
    // day, and the alert still follows how the data arrived.
    if (processingContext.individualDays.contains(day)) {
      await db.insert('pulse_input_arrival', {
        'source': _arrivalSource,
        'start_ms': start,
        'end_ms': end,
        'digest': day,
        'origin': ProcessingOrigin.recentSync.name,
        'admitted_ms': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    // Include context and an adjacent day's join. Existing overlapping episodes
    // expand this range so replay cannot split a long episode at midnight.
    var lo = start - 900000, hi = end + 900000;
    final overlapping = await db.rawQuery(
      'SELECT MIN(start_ms) AS lo,MAX(end_ms) AS hi FROM pulse_episode WHERE start_ms < ? AND end_ms > ?',
      [hi, lo],
    );
    final oldLo = overlapping.first['lo'] as int?,
        oldHi = overlapping.first['hi'] as int?;
    if (oldLo != null && oldLo - 600000 < lo) lo = oldLo - 600000;
    if (oldHi != null && oldHi + 600000 > hi) hi = oldHi + 600000;
    // Windows start in [lo, hi); each one decides on its whole five-minute
    // context, so the rows reach that far past both ends and the verdict does
    // not depend on which day's run looks at the window.
    final readLo = lo - _support - _slack, readHi = hi + _support + _slack;
    final startBucket = readLo ~/ 900000, endBucket = (readHi - 1) ~/ 900000;
    final revisions = await db.rawQuery(
      'SELECT COALESCE(SUM(rev),0) AS rev FROM input_rev WHERE bucket BETWEEN ? AND ?',
      [startBucket, endBucket],
    );
    final revision = revisions.first['rev'] as int;
    final rows = await db.rawQuery(
      '''SELECT device_id,ts_ms,rec_ts,beat_index,beat_ts_ms,rr_ms,
        EXISTS(SELECT 1 FROM pulse_upgrade_record u
          WHERE u.source=decoded_rr.device_id AND u.ts_ms=decoded_rr.ts_ms) AS before_version
        FROM decoded_rr WHERE rec_ts>=? AND rec_ts<? AND ${derivableSourceSql()}
        ORDER BY device_id,ts_ms,beat_index''',
      [readLo ~/ 1000, readHi ~/ 1000],
    );
    if (rows.isEmpty) return;
    final latest = await db.rawQuery('SELECT MAX(rec_ts) AS t FROM decoded_rr');
    final watermark = (latest.first['t'] as int) * 1000;
    final certificates = await db.query(
      'pulse_source_complete',
      orderBy: 'source',
    );
    final digest =
        'upgrade:1:rev:$revision:complete:$watermark:cert:${jsonEncode(certificates)}';
    final checkpoint = await db.query(
      'pulse_input_arrival',
      where: 'source=? AND start_ms=? AND end_ms=? AND digest=?',
      whereArgs: ['all:v${ana.pulseDetectorVersion}', lo, hi, digest],
    );
    if (checkpoint.isNotEmpty) return;
    // The real start of each source: the cleaning context is clipped there and
    // nowhere else, never at this query's edge.
    final sources = await db.rawQuery(
      'SELECT DISTINCT device_id FROM decoded_rr WHERE rec_ts>=? AND rec_ts<? AND ${derivableSourceSql()}',
      [readLo ~/ 1000, readHi ~/ 1000],
    );
    final sourceStarts = <String, int>{};
    // A handful of devices, not rows: indexed on purpose, so this is not a loop
    // over a raw table's result (heavy guard rawTableRowLoopOutsideHeavy).
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i]['device_id'] as String;
      final first = await db.rawQuery(
        'SELECT MIN(ts_ms) AS t FROM decoded_rr WHERE device_id=?',
        [source],
      );
      sourceStarts[source] =
          (first.first['t'] as int) ~/ ana.pulseWindowMs * ana.pulseWindowMs;
    }
    final input = PulseDetectionInput(
      rows,
      watermark,
      lo,
      evaluateTo: hi,
      sourceStarts: sourceStarts,
      sourceCompletions: certificates,
      requireCertified: processingContext.origin == ProcessingOrigin.recentSync,
    );
    await probe?.afterRead(day);
    final result = await Isolate.run(() => detectPulseEpisodesHeavy(input));
    final detection = result.detection;
    final hrRows = await db.rawQuery(
      '''SELECT device_id AS source,rec_ts/60*60000 AS time,AVG(hr) AS bpm,COUNT(*) AS count
        FROM decoded_onehz WHERE rec_ts>=? AND rec_ts<? AND hr BETWEEN 25 AND 230 AND ${derivableSourceSql()}
        GROUP BY device_id,rec_ts/60 ORDER BY rec_ts LIMIT 4096''',
      [(lo - 8 * 3600000) ~/ 1000, (hi + 8 * 3600000) ~/ 1000],
    );
    final syncDays = {
      for (final r in await db.query(
        'pulse_input_arrival',
        columns: ['digest'],
        where: 'source=? AND origin=?',
        whereArgs: [_arrivalSource, ProcessingOrigin.recentSync.name],
      ))
        r['digest'] as String,
    };
    await store.reconcile(
      detection,
      beforeVersion: result.beforeVersion,
      origin: 'bulk',
      syncDays: syncDays,
      nowMs: now,
      heartRate: hrRows,
      inputStamp: PulseInputStamp(startBucket, endBucket, revision),
    );
    // Explicit checkpoint even on refusal: no fabricated trace or notification.
    await db.insert('pulse_input_arrival', {
      'source': 'all:v${ana.pulseDetectorVersion}',
      'start_ms': lo,
      'end_ms': hi,
      'digest': digest,
      'origin': processingContext.origin.name,
      'admitted_ms': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}

/// `pulse_input_arrival.source` of a first-arrival provenance row (day label in
/// `digest`); `all:v<detector>` rows are evaluation checkpoints.
const _arrivalSource = 'arrival';

@SendableShape(
  'Committed primitive RR row maps; sendable_detectPulseEpisodesHeavy_test',
)
class PulseDetectionInput {
  final List<Map<String, Object?>> rows;

  /// [start] and [evaluateTo] bound the window starts decided; [rows] reach
  /// five minutes further on both sides. [sourceStarts] holds each source's real
  /// first instant (absent: the source starts at [start]).
  final int watermark, start;
  final int? evaluateTo;
  final Map<String, int> sourceStarts;
  final List<Map<String, Object?>> sourceCompletions;
  final bool requireCertified;
  const PulseDetectionInput(
    this.rows,
    this.watermark,
    this.start, {
    this.evaluateTo,
    this.sourceStarts = const {},
    this.sourceCompletions = const [],
    this.requireCertified = false,
  });
}

@SendableShape(
  'Immutable analytics window and beat evidence; sendable_detectPulseEpisodesHeavy_test',
)
class PulseDetectionResult {
  final ana.PulseDetection detection;
  final Set<String> beforeVersion;
  const PulseDetectionResult(this.detection, this.beforeVersion);
}

@heavy
PulseDetectionResult detectPulseEpisodesHeavy(PulseDetectionInput input) {
  WorkerInit.ensure(
    const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'),
  );
  assertWorker();
  WorkerAudit.entered('detectPulseEpisodesHeavy');
  final rows = input.rows;
  final inputs = <ana.PulseBeatInput>[];
  final historicalBeats = <String>{};
  var index = 0;
  for (final r in rows) {
    final source = r['device_id'] as String;
    if (r['before_version'] == 1) {
      historicalBeats.add('$source:${r['ts_ms']}:${r['beat_index']}');
    }
    // Identity uses the durable record key, never the resettable counter.
    inputs.add(
      ana.PulseBeatInput(
        id: '$source:${r['ts_ms']}:${r['beat_index']}',
        source: source,
        index: index++,
        timeMs: (r['beat_ts_ms'] as int?) ?? (r['rec_ts'] as int) * 1000,
        rawMs: (r['rr_ms'] as num).toDouble(),
        timestampValid: r['beat_ts_ms'] != null,
      ),
    );
  }

  final certificates = {
    for (final c in input.sourceCompletions)
      c['source'] as String: c['through_ms'] as int,
  };
  final sources = inputs.map((b) => b.source).toSet().toList()..sort();
  final windows = <ana.PulseWindow>[], episodes = <ana.PulseEpisode>[];
  for (final source in sources) {
    if (input.requireCertified && !certificates.containsKey(source)) continue;
    final result = ana.detectPulseEpisodes(
      inputs.where((b) => b.source == source).toList(),
      completeThroughMs: input.requireCertified
          ? certificates[source]!
          : input.watermark,
      sourceStartMs: input.sourceStarts[source] ?? input.start,
      evaluateFromMs: input.start,
      evaluateToMs: input.evaluateTo,
    );
    windows.addAll(result.windows);
    episodes.addAll(result.episodes);
  }
  return PulseDetectionResult(ana.PulseDetection(windows, episodes), {
    for (final e in episodes)
      if (e.beats.isNotEmpty &&
          e.beats.every((b) => historicalBeats.contains(b.id)))
        e.id,
  });
}
