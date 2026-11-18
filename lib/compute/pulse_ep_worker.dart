// Owner: the Pulse episode worker. Detection, evidence building/encoding and
// evidence decoding are heavy work (cost grows with stored beats): they run in
// registered worker entries, never on the UI isolate. The coordinator reads
// bounded committed beats, runs those entries, and hands the result to
// PulseEpisodeStore in one publication. It has NO scheduler: production
// scheduling stays disabled until phase 3 (PulseEpisodeStore.schedulingEnabled).
import 'dart:convert';
import 'dart:isolate';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:sqflite/sqflite.dart';

import '../data/day_label.dart';
import 'derivation_engine.dart' show kAlgoVersion;
import '../data/pulse_ep/pulse_ep_codec.dart';
import '../data/pulse_ep/pulse_ep_store.dart';
import '../data/pulse_ep/pulse_ep_types.dart';
import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_init.dart';

const WorkerInputs _kPulseWorker = WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en');

@SendableShape('Raw decoded_rr row maps and ints; sendable_detectPulseEpisodesHeavy_test')
class PulseDetectInput {
  const PulseDetectInput({
    required this.source,
    required this.rows,
    required this.completeThroughMs,
    required this.sourceStartMs,
    this.sourceEndMs,
    this.evaluateFromMs,
    this.evaluateToMs,
  });
  final String source;

  /// `ts_ms, beat_index, beat_ts_ms, rr_ts_ms, rr_ms` rows in time order.
  final List<Map<String, Object?>> rows;
  final int completeThroughMs, sourceStartMs;
  final int? sourceEndMs, evaluateFromMs, evaluateToMs;
}

@SendableShape('The immutable analytics detection; sendable_detectPulseEpisodesHeavy_test')
class PulseDetected {
  const PulseDetected(this.detection, {this.support = const []});
  final ana.PulseDetection detection;
  final List<PulseWindowSupport> support;
}

@heavy
PulseDetected detectPulseEpisodesHeavy(PulseDetectInput input) {
  WorkerInit.ensure(_kPulseWorker);
  assertWorker();
  WorkerAudit.entered('detectPulseEpisodesHeavy');
  final detection = _detectPulseRowsHeavy(input, input.rows);
  final capturedRows = [for (final r in input.rows) if (r['pre_upgrade'] == 1) r];
  final capturedKeys = {for (final r in capturedRows) r['ts_ms'] as int};
  final before = _detectPulseRowsHeavy(input, capturedRows);
  final beforeWindows = {for (final w in before.windows) w.startMs: w};
  return PulseDetected(detection, support: [
    for (final w in detection.windows)
      PulseWindowSupport(startMs: w.startMs, endMs: w.endMs,
          qualified: !w.pending && w.qualified,
          preUpgradeQualified: beforeWindows[w.startMs]?.qualified ?? false,
          novelRecords: {
            for (final b in w.beats)
              if (b.featureUse && pulseBeatKeyOf(b.id) != null &&
                  !capturedKeys.contains(pulseBeatKeyOf(b.id)!.recordTsMs))
                pulseBeatKeyOf(b.id)!.recordTsMs,
          }.length),
  ]);
}

@heavy
ana.PulseDetection _detectPulseRowsHeavy(PulseDetectInput input, List<Map<String, Object?>> rows) {
  final beats = <ana.PulseBeatInput>[];
  for (final r in rows) {
    final ts = (r['ts_ms'] as num).toInt(), bi = (r['beat_index'] as num).toInt();
    final modeled = (r['beat_ts_ms'] as num?)?.toInt();
    beats.add(ana.PulseBeatInput(
      id: '${input.source}:$ts:$bi',
      source: input.source,
      index: beats.length,
      timeMs: modeled ?? (r['rr_ts_ms'] as num).toInt(),
      rawMs: (r['rr_ms'] as num).toDouble(),
      // No modeled position means no honest beat time: refuse, never guess.
      timestampValid: modeled != null,
    ));
  }
  return ana.detectPulseEpisodes(
    beats,
    completeThroughMs: input.completeThroughMs,
    sourceStartMs: input.sourceStartMs,
    sourceEndMs: input.sourceEndMs,
    evaluateFromMs: input.evaluateFromMs,
    evaluateToMs: input.evaluateToMs,
  );
}

@SendableShape('Immutable analytics detection and primitive heart-rate bins; sendable_preparePulseEvidenceHeavy_test')
class PulsePrepareInput {
  const PulsePrepareInput(this.detection, {this.hr = const [], this.fromMs, this.toMs, this.support = const []});
  final ana.PulseDetection detection;
  final List<PulseHrBin> hr;
  final int? fromMs, toMs;
  final List<PulseWindowSupport> support;
}

@SendableShape('Encoded recordings keyed by episode id; sendable_preparePulseEvidenceHeavy_test')
class PulsePrepared {
  const PulsePrepared(this.episodes, {this.refusedJson = '[]', this.support = const {}, this.summaries = const {}});
  final Map<String, PulseEncodeResult> episodes;
  final String refusedJson;
  final Map<String, List<PulseWindowSupport>> support;
  final Map<String, String> summaries;
}

@heavy
PulsePrepared preparePulseEvidenceHeavy(PulsePrepareInput input) {
  WorkerInit.ensure(_kPulseWorker);
  assertWorker();
  WorkerAudit.entered('preparePulseEvidenceHeavy');
  final refused = <Map<String, Object?>>[];
  if (input.fromMs != null && input.toMs != null) {
    final windows = {for (final w in input.detection.windows) w.startMs: w};
    for (var at = (input.fromMs! ~/ 300000) * 300000; at < input.toMs!; at += 300000) {
      final w = windows[at];
      final reason = w == null ? 'unsupported' : w.pending ? 'pending' :
          w.qualityReasons.isEmpty ? null : w.qualityReasons.join(',');
      if (reason != null) refused.add({
        'start': at < input.fromMs! ? input.fromMs : at,
        'end': at + 300000 > input.toMs! ? input.toMs : at + 300000,
        'reason': reason,
      });
    }
  }
  final byStart = {for (final w in input.support) w.startMs: w};
  final support = {
    for (final e in input.detection.episodes) e.id: [
      for (final w in e.windows) if (byStart[w.startMs] != null) byStart[w.startMs]!,
    ],
  };
  return PulsePrepared({
    for (final e in input.detection.episodes)
      e.id: encodePulseEvidence(buildPulseEvidenceHeavy(e, input.detection, hr: input.hr)),
  }, refusedJson: jsonEncode(refused), support: support, summaries: {
    for (final e in input.detection.episodes) e.id: jsonEncode({
      'windows': e.windows.length,
      'support': [for (final w in support[e.id]!) w.toJson()],
    }),
  });
}

@SendableShape('Compressed bytes and a checksum string; sendable_decodePulseEvidenceHeavy_test')
class PulseDecodeInput {
  const PulseDecodeInput(this.bytes, this.checksum, {this.importMeta});
  final List<int> bytes;
  final String checksum;
  final Map<String, Object?>? importMeta;
}

@SendableShape('A sealed read result; sendable_decodePulseEvidenceHeavy_test')
class PulseDecoded {
  const PulseDecoded(this.read, {this.imported});
  final PulseEvidenceRead read;
  final PulseImportedRecording? imported;
}

@heavy
PulseDecoded decodePulseEvidenceHeavy(PulseDecodeInput input) {
  WorkerInit.ensure(_kPulseWorker);
  assertWorker();
  WorkerAudit.entered('decodePulseEvidenceHeavy');
  final meta = input.importMeta;
  var read = decodePulseEvidence(input.bytes, checksum: input.checksum,
      expectedExpandedBytes: meta == null ? null : (meta['expanded_bytes'] as num?)?.toInt() ?? -1);
  if (meta == null) return PulseDecoded(read);
  if (meta['encoded_bytes'] != input.bytes.length) {
    read = const PulseEvidenceCorrupt('encoded size mismatch');
  }
  final evidence = switch (read) {
    PulseEvidenceAvailable(:final evidence) || PulseEvidencePartial(:final evidence) => evidence,
    _ => null,
  };
  if (evidence != null && evidence.episodeId != meta['episode_id']) {
    read = const PulseEvidenceCorrupt('recording identity mismatch');
  }
  final status = switch (read) {
    PulseEvidenceAvailable() => PulseEvidenceStatus.available,
    PulseEvidencePartial() => PulseEvidenceStatus.partial,
    PulseEvidenceUnsupported() => PulseEvidenceStatus.unsupported,
    _ => PulseEvidenceStatus.corrupt,
  };
  final reason = switch (read) {
    PulseEvidenceCorrupt(:final reason) || PulseEvidenceUnsupported(:final reason) => reason,
    _ => null,
  };
  return PulseDecoded(read, imported: PulseImportedRecording({
    ...meta,
    if (reason == null) ...{
      'payload': input.bytes,
      'encoded_bytes': input.bytes.length,
      'retained_json': jsonEncode([[evidence!.startMs, evidence.endMs]]),
      'omitted_json': jsonEncode([for (final r in evidence.omitted) [r.startMs, r.endMs, r.reason]]),
    },
  }, status, reason));
}

/// Beat id convention shared with [PulseEpisodeWorker]: `source:recordTsMs:beatIndex`.
({int recordTsMs, int beatIndex})? pulseBeatKeyOf(String id) {
  final b = id.lastIndexOf(':');
  if (b <= 0) return null;
  final a = id.lastIndexOf(':', b - 1);
  if (a < 0) return null;
  final ts = int.tryParse(id.substring(a + 1, b));
  final i = int.tryParse(id.substring(b + 1));
  return ts == null || i == null ? null : (recordTsMs: ts, beatIndex: i);
}

/// The typed recording of one episode from the analytics result.
@heavy
PulseEvidence buildPulseEvidenceHeavy(
  ana.PulseEpisode episode,
  ana.PulseDetection detection, {
  List<PulseHrBin> hr = const [],
}) {
  final beats = <PulseBeat>[];
  for (final b in episode.beats) {
    final key = pulseBeatKeyOf(b.id);
    if (key == null) continue; // an id this store did not issue is not evidence
    beats.add(PulseBeat(
      recordTsMs: key.recordTsMs,
      beatIndex: key.beatIndex,
      ordinal: b.index,
      timeMs: b.timeMs,
      originalTimeMs: b.originalTimeMs,
      rawMs: b.rawMs,
      correctedMs: b.correctedMs,
      flags: (b.plausible ? PulseBeat.plausible : 0) |
          (b.retained ? PulseBeat.retained : 0) |
          (b.corrected ? PulseBeat.corrected : 0) |
          (b.dropped ? PulseBeat.dropped : 0) |
          (b.featureUse ? PulseBeat.featureUse : 0) |
          (b.validAdjacent ? PulseBeat.validAdjacent : 0),
      labels: b.labels,
    ));
  }
  // Overview: 30-second bins over plausible raw intervals, dropped beats out.
  final byBin = <int, List<double>>{};
  for (final b in beats) {
    if (!b.has(PulseBeat.plausible) || b.has(PulseBeat.dropped)) continue;
    (byBin[(b.timeMs ~/ 30000) * 30000] ??= []).add(b.rawMs);
  }
  final overview = [
    for (final e in (byBin.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
      () {
        final v = e.value..sort();
        return PulseOverviewBin(e.key, v.length, pulseQuantile(v, 0.1)!, pulseQuantile(v, 0.5)!, pulseQuantile(v, 0.9)!);
      }(),
  ];
  // Up to five largest sudden adjacent jumps: |change| desc, time, id.
  final jumps = [
    for (final b in episode.beats)
      if (b.changeMs != null && b.validAdjacent && b.labels.any((l) => l == 'suddenLong' || l == 'suddenShort')) b,
  ]..sort((a, b) {
      final c = b.changeMs!.abs().compareTo(a.changeMs!.abs());
      if (c != 0) return c;
      final t = a.timeMs.compareTo(b.timeMs);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
  final chosen = jumps.take(5).toList()..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  // The nearest preceding closed, quality-qualified, nonflagged window ending
  // within ten minutes is the comparison; none means "unavailable".
  final prior = [
    for (final w in detection.windows)
      if (w.source == episode.source && !w.pending && w.reasons.isEmpty &&
          w.endMs <= episode.startMs && w.endMs >= episode.startMs - 600000 && !w.qualified) w,
  ];
  return PulseEvidence(
    episodeId: episode.id,
    source: episode.source,
    startMs: episode.startMs,
    endMs: episode.endMs,
    ongoing: episode.ongoing,
    beats: beats,
    windows: [for (final w in episode.windows) w.toJson(evidence: false)],
    overview: overview,
    hr: hr,
    comparisonRrMs: prior.isEmpty
        ? const []
        : [for (final b in prior.last.beats) if (b.plausible && !b.dropped) b.rawMs],
    jumps: [for (final b in chosen) b.id],
  );
}

/// A deterministic observation point for tests that admit data after preparation.
abstract interface class PulseEvaluationProbe {
  Future<void> beforeCommit();
}

/// Reads bounded committed beats and evaluates one source range. Not scheduled.
class PulseEpisodeWorker {
  PulseEpisodeWorker._();

  /// Raw `decoded_rr` rows of [source] in `[fromMs, toMs)`, paged so one cursor
  /// window never holds more than a few thousand small rows. The rows go to the
  /// detection worker as they are; nothing here walks them.
  static Future<List<Map<String, Object?>>> readBeatRows(
    Database db, {
    required String source,
    required int fromMs,
    required int toMs,
  }) async {
    final out = <Map<String, Object?>>[];
    var tsAfter = fromMs - 1, idxAfter = -1;
    while (true) {
      final page = await db.rawQuery(
        'SELECT r.ts_ms, r.beat_index, r.beat_ts_ms, r.rr_ts_ms, r.rr_ms, '
        'EXISTS(SELECT 1 FROM pulse_ep_upgrade_record u WHERE u.source = r.device_id AND u.ts_ms = r.ts_ms) AS pre_upgrade '
        'FROM decoded_rr r '
        'WHERE device_id = ? AND ts_ms < ? AND (ts_ms > ? OR (ts_ms = ? AND beat_index > ?)) '
        'ORDER BY ts_ms, beat_index LIMIT 4000',
        [source, toMs, tsAfter, tsAfter, idxAfter],
      );
      out.addAll(page);
      if (page.length < 4000) return out;
      tsAfter = (page.last['ts_ms'] as num).toInt();
      idxAfter = (page.last['beat_index'] as num).toInt();
    }
  }

  /// Decodes a stored recording in a worker; the caller sees a sealed result.
  static Future<PulseEvidenceRead> decode(List<int> bytes, String checksum) async {
    final input = PulseDecodeInput(bytes, checksum);
    return (await Isolate.run(() => decodePulseEvidenceHeavy(input))).read;
  }

  /// Import validation stays in the registered decoder entry, before a main
  /// database transaction is opened. Invalid bytes never become stored evidence.
  static Future<PulseImportedRecording> prepareImportedRecording(
      Map<String, Object?> row, List<int> bytes) async {
    final input = PulseDecodeInput(bytes, row['checksum'] as String? ?? '', importMeta: row);
    return (await Isolate.run(() => decodePulseEvidenceHeavy(input))).imported!;
  }

  /// Detect, prepare, publish and advance the checkpoint for one range. The
  /// caller supplies the certified completeness watermark; this does not infer
  /// it. Returns what was published.
  static Future<List<PulseApply>> evaluate(
    Database db, {
    required String source,
    required int fromMs,
    required int toMs,
    required int sourceStartMs,
    required int completeThroughMs,
    required String origin,
    required int nowMs,
    List<PulseHrBin> hr = const [],
    PulseEvaluationProbe? probe,
  }) async {
    const pad = 600000;
    final stamp = await PulseEpisodeStore.readStamp(db,
        source: source, fromMs: fromMs - pad, toMs: toMs + pad);
    final rows = await readBeatRows(db, source: source, fromMs: fromMs - pad, toMs: toMs + pad);
    final detectInput = PulseDetectInput(
      source: source,
      rows: rows,
      completeThroughMs: completeThroughMs,
      sourceStartMs: sourceStartMs,
      evaluateFromMs: fromMs,
      evaluateToMs: toMs,
    );
    final detected = await Isolate.run(() => detectPulseEpisodesHeavy(detectInput));
    final detection = detected.detection;
    final prepareInput = PulsePrepareInput(detection, hr: hr, fromMs: fromMs, toMs: toMs,
        support: detected.support);
    final prepared = await Isolate.run(() => preparePulseEvidenceHeavy(prepareInput));
    await probe?.beforeCommit();
    final results = <PulseApply>[];
    for (final e in detection.episodes) {
      final enc = prepared.episodes[e.id];
      results.add(await PulseEpisodeStore.publish(
        db,
        PulsePublication(
          episodeId: e.id,
          source: e.source,
          seedStartMs: e.startMs,
          seedEndMs: e.windows.first.endMs,
          startMs: e.startMs,
          endMs: e.endMs,
          ongoing: e.ongoing,
          startDay: dayLabelOf(DateTime.fromMillisecondsSinceEpoch(e.startMs)),
          endDay: dayLabelOf(DateTime.fromMillisecondsSinceEpoch(e.endMs - 1)),
          detector: ana.pulseDetectorVersion,
          algo: kAlgoVersion,
          alertEligible: e.alertEligible,
          refusal: enc is PulseEncodeRefused ? 'evidence unavailable: ${enc.reason}' :
              e.alertEligible ? null : 'recording quality',
          origin: origin,
          summaryJson: prepared.summaries[e.id]!,
          windowSupport: prepared.support[e.id]!,
          evidence: enc is PulseEncoded ? enc : null,
          supportKeysMs: {
            for (final b in e.beats)
              if (pulseBeatKeyOf(b.id) != null) pulseBeatKeyOf(b.id)!.recordTsMs,
          }.toList(),
          nowMs: nowMs,
        ),
        expected: stamp,
      ));
    }
    if (results.every((r) => r is! PulseFailed && r is! PulseRefused)) {
      try {
        await PulseEpisodeStore.advanceCheckpoint(db,
            source: source, fromMs: fromMs, throughMs: toMs, stamp: stamp,
            refusedJson: prepared.refusedJson,
            detector: ana.pulseDetectorVersion, nowMs: nowMs);
      } on StateError catch (error) {
        results.add(PulseRefused(error.message.toString()));
      }
    }
    return results;
  }
}
