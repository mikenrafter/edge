// Owner: pulse episode worker. Reads committed decoded beats after sync/ACK;
// never writes raw, decoded, daily output or the BLE cursor.
import 'dart:isolate';
import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import '../data/db.dart';
import '../data/day_label.dart';
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
    // Windows start in [lo, hi). Read both spectral neighbors and each one's
    // correction support, so the day's evaluation range cannot change a verdict.
    final readLo = lo - ana.pulseBaselineLookbackMs - 2 * _support - _slack,
        readHi = hi + 2 * _support + _slack;
    final startBucket = readLo ~/ 900000, endBucket = (readHi - 1) ~/ 900000;
    final revisions = await db.rawQuery(
      'SELECT COALESCE(SUM(rev),0) AS rev FROM input_rev WHERE bucket BETWEEN ? AND ?',
      [startBucket, endBucket],
    );
    final revision = revisions.first['rev'] as int;
    final contextRevision = await pulseContextRevision(db);
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
    final certificateStamp = certificates
        .map((c) {
          final source = c['source'] as String;
          return '${source.length}:$source:${c['through_ms']}';
        })
        .join(';');
    final digest =
        'upgrade:1:rev:$revision:context:$contextRevision:complete:$watermark:cert:$certificateStamp';
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
    final contextRows = await db.rawQuery(
      """SELECT device_id AS source,rec_ts/300*300000 AS start_ms,
        COUNT(*) AS samples,
        COUNT(dyn_accel_g) AS motion_samples,
        SUM(CASE WHEN dyn_accel_g > ${ana.pulseMotionThresholdG} THEN 1 ELSE 0 END) AS moving_samples,
        MIN(on_wrist) AS wrist,COUNT(on_wrist) AS wear_samples,
        SUM(CASE WHEN band_sleep_state=2 THEN 1 ELSE 0 END) AS sleep_samples,
        SUM(CASE WHEN band_sleep_state BETWEEN 0 AND 3 THEN 1 ELSE 0 END) AS sleep_known
        FROM decoded_onehz WHERE rec_ts>=? AND rec_ts<? AND ${derivableSourceSql()}
        GROUP BY device_id,rec_ts/300 ORDER BY device_id,rec_ts/300""",
      [readLo ~/ 1000, readHi ~/ 1000],
    );
    final labels = <String>[];
    var dateCursor = DateTime.fromMillisecondsSinceEpoch(readLo);
    final lastDate = DateTime.fromMillisecondsSinceEpoch(readHi);
    while (!dateCursor.isAfter(lastDate)) {
      labels.add(dayLabelOf(dateCursor));
      dateCursor = DateTime(
        dateCursor.year,
        dateCursor.month,
        dateCursor.day + 1,
      );
    }
    final sleepRows = await LocalDb.sleepWindowRowsFor(labels);
    final wearEvents = <Map<String, Object?>>[];
    final offSpans = <String, List<List<int>>>{};
    final chargingSpans = <String, List<List<int>>>{};
    for (final source in sourceStarts.keys) {
      wearEvents.addAll(
        await db.rawQuery(
          'SELECT device_id AS source,ts,event_id FROM band_events WHERE device_id=? '
          'AND ts<? AND event_id IN (?,?) ORDER BY ts DESC,event_id LIMIT 1',
          [
            source,
            readLo ~/ 1000,
            proto.EventId.wristOn,
            proto.EventId.wristOff,
          ],
        ),
      );
      wearEvents.addAll(
        await db.rawQuery(
          'SELECT device_id AS source,ts,event_id FROM band_events WHERE device_id=? '
          'AND ts>=? AND ts<? AND event_id IN (?,?) ORDER BY ts,event_id',
          [
            source,
            readLo ~/ 1000,
            readHi ~/ 1000,
            proto.EventId.wristOn,
            proto.EventId.wristOff,
          ],
        ),
      );
      offSpans[source] = await LocalDb.wristOffSpans(
        readLo ~/ 1000,
        readHi ~/ 1000,
        deviceId: source,
      );
      chargingSpans[source] = await LocalDb.chargingSpans(
        readLo ~/ 1000,
        readHi ~/ 1000,
        deviceId: source,
      );
    }
    final baselineEpisodes = await db.rawQuery(
      'SELECT source,start_ms,end_ms FROM pulse_episode WHERE end_ms>? AND start_ms<?',
      [readLo - 1800000, readHi + 1800000],
    );
    final input = PulseDetectionInput(
      rows,
      watermark,
      lo,
      evaluateTo: hi,
      sourceStarts: sourceStarts,
      sourceCompletions: certificates,
      contextRows: contextRows,
      wearEvents: wearEvents,
      sleepWindows: [
        for (final row in sleepRows.values) row['window_json'] as String,
      ],
      offSpans: offSpans,
      chargingSpans: chargingSpans,
      baselineEpisodes: baselineEpisodes,
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
      inputStamp: PulseInputStamp(
        startBucket,
        endBucket,
        revision,
        contextRevision: contextRevision,
      ),
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
  /// fourteen days earlier for baseline history and five minutes further on
  /// both sides for cleaning. [sourceStarts] holds each source's real
  /// first instant (absent: the source starts at [start]).
  final int watermark, start;
  final int? evaluateTo;
  final Map<String, int> sourceStarts;
  final List<Map<String, Object?>> sourceCompletions;
  final bool requireCertified;
  final List<Map<String, Object?>> contextRows, baselineEpisodes, wearEvents;
  final List<List<int>> sleepSpans;
  final List<String> sleepWindows;
  final Map<String, List<List<int>>> offSpans, chargingSpans;
  const PulseDetectionInput(
    this.rows,
    this.watermark,
    this.start, {
    this.evaluateTo,
    this.sourceStarts = const {},
    this.sourceCompletions = const [],
    this.requireCertified = false,
    this.contextRows = const [],
    this.wearEvents = const [],
    this.sleepSpans = const [],
    this.sleepWindows = const [],
    this.offSpans = const {},
    this.chargingSpans = const {},
    this.baselineEpisodes = const [],
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

  final sleepSpans = [...input.sleepSpans];
  for (final encoded in input.sleepWindows) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) continue;
    final window = decoded['value'] is Map ? decoded['value'] as Map : decoded;
    final onset = window['onset_ms'], offset = window['offset_ms'];
    if (onset is num && offset is num && offset > onset) {
      sleepSpans.add([onset.toInt(), offset.toInt()]);
    }
  }
  final contexts = <String, Map<int, ana.PulseWindowContext>>{};
  final knownWorn = <String, List<List<int>>>{};
  for (final source in inputs.map((b) => b.source).toSet()) {
    final events = input.wearEvents.where((e) => e['source'] == source).toList()
      ..sort((a, b) {
        final time = (a['ts'] as int).compareTo(b['ts'] as int);
        // A contradictory same-time OFF wins conservatively.
        return time != 0
            ? time
            : a['event_id'] == proto.EventId.wristOff
            ? 1
            : -1;
      });
    int? wornStart;
    for (final e in events) {
      final t = (e['ts'] as int) * 1000;
      if (e['event_id'] == proto.EventId.wristOn) {
        wornStart ??= t;
      } else if (wornStart != null) {
        (knownWorn[source] ??= []).add([wornStart, t]);
        wornStart = null;
      }
    }
    if (wornStart != null) {
      (knownWorn[source] ??= []).add([
        wornStart,
        input.evaluateTo ?? input.watermark,
      ]);
    }
  }
  bool overlaps(List<List<int>> spans, int start, int end, {int scale = 1}) =>
      spans.any((s) => s[0] * scale < end && s[1] * scale > start);
  for (final r in input.contextRows) {
    final source = r['source'] as String, start = r['start_ms'] as int;
    final end = start + ana.pulseWindowMs;
    final motionSamples = r['motion_samples'] as int;
    final movingSamples = r['moving_samples'] as int;
    final isOff = overlaps(
      input.offSpans[source] ?? const [],
      start,
      end,
      scale: 1000,
    );
    final charging = overlaps(
      input.chargingSpans[source] ?? const [],
      start,
      end,
      scale: 1000,
    );
    final canonicalSleep =
        source.isEmpty &&
        sleepSpans.any(
          (s) =>
              (s[1].clamp(start, end) - s[0].clamp(start, end)) >=
              ana.pulseContextMinSamples * 1000,
        );
    (contexts[source] ??= {})[start] = ana.PulseWindowContext(
      day: dayLabelOf(DateTime.fromMillisecondsSinceEpoch(start)),
      asleep:
          canonicalSleep ||
              (r['sleep_samples'] as int) >= ana.pulseContextMinSamples
          ? true
          : (r['sleep_known'] as int) >= ana.pulseContextMinSamples
          ? false
          : null,
      motion: movingSamples >= ana.pulseMovingMinSamples
          ? true
          : motionSamples >= ana.pulseContextMinSamples
          ? false
          : null,
      wear: isOff || r['wrist'] == 0
          ? false
          : ((r['wear_samples'] as int) >= ana.pulseContextMinSamples &&
                    r['wrist'] == 1) ||
                (knownWorn[source] ?? const []).any(
                  (s) => s[0] <= start && s[1] >= end,
                )
          ? true
          : null,
      charging: charging ? true : null,
    );
  }
  // Toggle evidence can exist without a single 1 Hz sample. It still vetoes.
  for (final source in inputs.map((b) => b.source).toSet()) {
    for (
      var start = input.start - ana.pulseBaselineLookbackMs;
      start < (input.evaluateTo ?? input.watermark) + ana.pulseWindowMs;
      start += ana.pulseWindowMs
    ) {
      final end = start + ana.pulseWindowMs;
      final off = overlaps(
        input.offSpans[source] ?? const [],
        start,
        end,
        scale: 1000,
      );
      final charging = overlaps(
        input.chargingSpans[source] ?? const [],
        start,
        end,
        scale: 1000,
      );
      if (!off && !charging) continue;
      final prior = contexts[source]?[start];
      (contexts[source] ??= {})[start] = ana.PulseWindowContext(
        day: dayLabelOf(DateTime.fromMillisecondsSinceEpoch(start)),
        asleep: prior?.asleep,
        motion: prior?.motion,
        wear: off ? false : prior?.wear,
        charging: charging ? true : prior?.charging,
      );
    }
  }
  final exclusions = <String, List<List<int>>>{};
  for (final e in input.baselineEpisodes) {
    (exclusions[e['source'] as String] ??= []).add([
      e['start_ms'] as int,
      e['end_ms'] as int,
    ]);
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
      context: contexts[source] ?? const {},
      baselineExclusions: exclusions,
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
