// Owner: pulse episode worker. Reads committed decoded beats after sync/ACK;
// never writes raw, decoded, daily output or the BLE cursor.
import 'dart:convert';
import 'dart:isolate';
import 'package:sqflite/sqflite.dart';
import 'package:crypto/crypto.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../data/db.dart';
import '../data/pulse_episode_store.dart';
import '../util/heavy.dart';
import '../util/worker_init.dart';
import 'processing_context.dart';
import 'pulse_episode_delivery.dart';

class PulseEpisodeWorker {
  static Future<void> run(
    Iterable<String> days, {
    required ProcessingContext processingContext,
  }) async {
    final db = await LocalDb.instance;
    final store = PulseEpisodeStore(db);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final day in days.toList()..sort()) {
      final date = DateTime.tryParse(day);
      if (date == null) continue;
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
      final rows = await db.rawQuery(
        '''SELECT device_id,ts_ms,rec_ts,beat_index,beat_ts_ms,rr_ms
        FROM decoded_rr WHERE rec_ts>=? AND rec_ts<? AND ${derivableSourceSql()}
        ORDER BY device_id,ts_ms,beat_index''',
        [lo ~/ 1000, hi ~/ 1000],
      );
      if (rows.isEmpty) continue;
      final latest = await db.rawQuery(
        'SELECT MAX(rec_ts) AS t FROM decoded_rr',
      );
      final watermark = (latest.first['t'] as int) * 1000;
      final digest = sha256
          .convert(utf8.encode(jsonEncode([rows, watermark])))
          .toString();
      final checkpoint = await db.query(
        'pulse_input_arrival',
        where: 'source=? AND start_ms=? AND end_ms=? AND digest=?',
        whereArgs: ['all:v${ana.pulseDetectorVersion}', lo, hi, digest],
      );
      if (checkpoint.isNotEmpty) continue;
      final inputs = <ana.PulseBeatInput>[];
      var index = 0;
      for (final r in rows) {
        final source = r['device_id'] as String;
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
      // The latest committed recording is a watermark, not a chunk boundary;
      // the detector still withholds the extra 5 minutes of cleaning support.
      final detection = await Isolate.run(
        () => detectPulseEpisodesHeavy(inputs, watermark, lo),
      );
      final hrRows = await db.rawQuery(
        '''SELECT rec_ts/60*60000 AS time,AVG(hr) AS bpm,COUNT(*) AS count
        FROM decoded_onehz WHERE rec_ts>=? AND rec_ts<? AND hr BETWEEN 25 AND 230
        GROUP BY rec_ts/60 ORDER BY rec_ts LIMIT 960''',
        [(start - 8 * 3600000) ~/ 1000, (start + 8 * 3600000) ~/ 1000],
      );
      await store.reconcile(
        detection,
        origin: processingContext.individualDays.contains(day)
            ? 'sync'
            : 'bulk',
        nowMs: now,
        heartRate: [for (final r in hrRows) Map<String, dynamic>.from(r)],
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
    await store.retain(nowMs: now);
    await PulseEpisodeDelivery.run();
  }
}

@heavy
ana.PulseDetection detectPulseEpisodesHeavy(
  List<ana.PulseBeatInput> beats,
  int watermark,
  int start,
) {
  WorkerInit.ensure(
    const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'),
  );
  assertWorker();
  return ana.detectPulseEpisodes(
    beats,
    completeThroughMs: watermark,
    sourceStartMs: start,
  );
}
