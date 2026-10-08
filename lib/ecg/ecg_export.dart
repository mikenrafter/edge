// ECG log export (design 04 R7' / R7''): ONE formatter for a reading, used by
// the per-reading export and by "Export ECG logs" (every reading, superseded
// attempts included). The file leaves through logFileName + saveLogFileResult
// (invariant 16); never the clipboard.
//
// UTF-8 text of `key: value` lines. A value the row does not hold prints
// `not recorded`, never a guess; the fixed key order below is the contract the
// tests pin. The outcome is decided by [ecgOutcome], the same function the
// screens read, so a log and a screen cannot disagree (AGENTS 3.8).

import '../data/db.dart';
import 'ecg_models.dart';
import 'ecg_outcome.dart';

/// The one header block at the top of an export.
class EcgExportHeader {
  const EcgExportHeader({
    required this.appVersion,
    required this.analyticsPin,
    required this.protocolPin,
    required this.algoVersion,
    required this.outcomeTableVersion,
    required this.exportedAt,
  });
  final String appVersion;
  final String analyticsPin;
  final String protocolPin;
  final int algoVersion;
  final int outcomeTableVersion;

  /// From the INJECTED clock, never DateTime.now() in the formatter.
  final DateTime exportedAt;
}

/// What an export reads. The default is [LocalDbEcgSource]; tests hand in a
/// fake.
abstract class EcgReadingSource {
  /// Every reading (superseded included) oldest -> newest by start_ts, then
  /// id; at most [limit] rows strictly after [after] in that order.
  Future<List<EcgReading>> page({EcgReading? after, required int limit});

  /// The kept packets of [readingId] in ordinal order; EMPTY = not kept.
  Future<List<EcgAcceptedPacket>> packets(String readingId);

  /// Every attempt in [readingId]'s group, ordered by attempt (the reading
  /// itself for a legacy row).
  Future<List<EcgReading>> attempts(String readingId);
}

/// [EcgReadingSource] over LocalDb. A stored row that no longer parses (an
/// unknown category or status) is skipped rather than failing the whole log.
class LocalDbEcgSource implements EcgReadingSource {
  const LocalDbEcgSource();

  static List<EcgReading> _parse(List<Map<String, Object?>> rows) => [
    for (final r in rows) ?EcgReading.fromRow(r),
  ];

  @override
  Future<List<EcgReading>> page({EcgReading? after, required int limit}) async =>
      _parse(
        await LocalDb.ecgReadingsForExport(
          limit: limit,
          afterStartTs: after?.startTs,
          afterId: after?.id,
        ),
      );

  @override
  Future<List<EcgAcceptedPacket>> packets(String readingId) async => [
    for (final r in await LocalDb.ecgReadingPackets(readingId))
      EcgPacketCodec.fromRow(r),
  ];

  @override
  Future<List<EcgReading>> attempts(String readingId) async =>
      _parse(await LocalDb.ecgAttempts(readingId));
}

/// What the screens need to build an [EcgExportHeader] (the pins and versions
/// come from kAnalyticsPin / kProtocolPin / kAlgoVersion /
/// kEcgOutcomeTableVersion, not from the screen).
class EcgExportEnv {
  const EcgExportEnv({required this.appVersion, required this.now});
  final Future<String> Function() appVersion;
  final DateTime Function() now;
}

const String _kNotRecorded = 'not recorded';

String _opt(Object? v) => v == null ? _kNotRecorded : '$v';

String _iso(int epochS) {
  final s = DateTime.fromMillisecondsSinceEpoch(
    epochS * 1000,
    isUtc: true,
  ).toIso8601String();
  // Whole seconds: the readings carry no sub-second start.
  return s.replaceFirst('.000Z', 'Z');
}

/// The header block (one `key: value` per line).
String formatEcgHeader(EcgExportHeader h) =>
    'OpenStrap ECG log\n'
    'app_version: ${h.appVersion}\n'
    'analytics_pin: ${h.analyticsPin}\n'
    'protocol_pin: ${h.protocolPin}\n'
    'algo_version: ${h.algoVersion}\n'
    'outcome_table_version: ${h.outcomeTableVersion}\n'
    'exported_at: ${h.exportedAt.toUtc().toIso8601String().replaceFirst('.000Z', 'Z')}\n';

/// One reading block + its packets (or `packets: not kept` when [packets] is
/// empty). THE formatter: per-reading and bulk both call it.
String formatEcgReading(EcgReading r, List<EcgAcceptedPacket> packets) {
  final o = ecgOutcome(r);
  final b = StringBuffer()
    ..writeln('id: ${r.id}')
    ..writeln('attempt_group: ${_opt(r.attemptGroup)}')
    ..writeln('attempt: ${_opt(r.attempt)}')
    // A current reading is superseded by nothing: `none` is a fact; a legacy
    // row's missing group above is the "not recorded".
    ..writeln('superseded_by: ${r.supersededBy ?? 'none'}')
    ..writeln('start: ${_iso(r.startTs)}')
    ..writeln('end: ${_iso(r.endTs)}')
    ..writeln('start_offset_min: ${_opt(r.startOffsetMin)}')
    ..writeln('outcome_kind: ${o.kind.name}')
    ..writeln(
      'reasons: ${o.reasons.isEmpty ? 'none' : o.reasons.join(', ')}',
    )
    ..writeln(
      'caveats: ${o.caveats.isEmpty ? 'none' : o.caveats.map((c) => c.name).join(', ')}',
    )
    ..writeln('result_code: ${r.resultCode}')
    ..writeln('category: ${r.category.name}')
    ..writeln('avg_hr: ${_opt(r.avgHr)}')
    ..writeln('live_hr: ${_opt(r.liveHr)}')
    ..writeln('quality: ${_opt(r.quality)}')
    ..writeln('unreadable_mask: ${r.unreadableMask}')
    ..writeln('mask_any: ${_opt(r.maskAny)}')
    ..writeln('variability_raw: ${_opt(r.variabilityRaw)}')
    ..writeln('min_uv: ${_opt(r.minUv)}')
    ..writeln('max_uv: ${_opt(r.maxUv)}')
    ..writeln('rms_uv: ${_opt(r.rmsUv)}')
    ..writeln('sample_count: ${r.sampleCount}')
    ..writeln('missing_segments: ${r.missingSegments}')
    ..writeln('interruptions: ${r.interruptions}')
    ..writeln('stop_reason: ${_opt(r.stopReason)}')
    ..writeln('firmware_version: ${_opt(r.firmwareVersion)}')
    ..writeln('capture_app_version: ${_opt(r.captureAppVersion)}')
    ..writeln('capture_table_version: ${_opt(r.captureTableVersion)}');
  if (packets.isEmpty) {
    b.writeln('packets: not kept');
  } else {
    b.writeln('packets: ${packets.length}');
    for (var i = 0; i < packets.length; i++) {
      final p = packets[i];
      // A placeholder second is a gap the band never sent: no strap time is
      // invented for it.
      b.writeln(
        'packet: ordinal=$i sequence=${p.sequence} '
        'strap_seconds=${p.placeholder ? _kNotRecorded : p.strapSeconds} '
        'strap_subsec=${p.placeholder ? _kNotRecorded : p.strapSubsec} '
        'sample_count=${p.samples.length}'
        '${p.placeholder ? ' placeholder=1' : ''} '
        'inner_hex=${EcgPacketCodec.hex(p.inner)} '
        'samples=${p.samples.join(',')}',
      );
    }
  }
  return b.toString();
}

/// Header + every reading in [source], oldest -> newest, paged ([pageSize]
/// rows per [EcgReadingSource.page] call) until exhausted - no 200 cap.
Future<String> buildEcgLogAll({
  required EcgExportHeader header,
  required EcgReadingSource source,
  int pageSize = 200,
}) async {
  final out = StringBuffer(formatEcgHeader(header));
  EcgReading? after;
  while (true) {
    final page = await source.page(after: after, limit: pageSize);
    if (page.isEmpty) break;
    for (final r in page) {
      out
        ..writeln()
        ..write(formatEcgReading(r, await source.packets(r.id)));
    }
    after = page.last;
  }
  return out.toString();
}

/// Header + the attempt group of [readingId] (oldest attempt first), each block
/// formatted by [formatEcgReading].
Future<String> buildEcgLogFor({
  required EcgExportHeader header,
  required EcgReadingSource source,
  required String readingId,
}) async {
  final out = StringBuffer(formatEcgHeader(header));
  for (final r in await source.attempts(readingId)) {
    out
      ..writeln()
      ..write(formatEcgReading(r, await source.packets(r.id)));
  }
  return out.toString();
}
