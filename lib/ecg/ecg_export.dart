// ECG log export (design 04 R7' / R7''): ONE formatter for a reading, used by
// the per-reading export and by "Export ECG logs" (every reading, superseded
// attempts included). The file leaves through logFileName + saveLogFileResult
// (invariant 16); never the clipboard.
//
// UTF-8 text of `key: value` lines. A value the row does not hold prints
// `not recorded`, never a guess; the fixed key order below is the contract the
// tests pin. The outcome is decided by [ecgOutcome], the same function the
// screens read, so a log and a screen cannot disagree (AGENTS 3.8).
//
// Evidence is never dropped: a stored row the app cannot parse (an unknown
// status, category or wrist) is exported with its raw columns and an
// `outcome: unparseable (reason)` line, and paging runs on the RAW key
// (start_ts, id) so rows the app cannot read can neither end the walk early nor
// vanish from it.
//
// "Export ECG logs" is unbounded, so it is paged and streamed: the calling
// isolate reads one page of raw rows (plus each reading's kept packets) from
// the database, a registered worker ([ecgFormatPageHeavy], design 02) formats
// the page, and the text leaves as chunks that are appended to the log file as
// they arrive. The worker calls the same [formatEcgRow] the per-reading export
// calls on the calling isolate, so there is one formatter.

import 'dart:isolate';

import '../data/db.dart';
import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_entries.dart';
import '../util/worker_init.dart';
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

/// Where a page of the export ends: the RAW key of its last row.
typedef EcgPageCursor = ({int startTs, String id});

/// What an export reads: raw table rows (what is stored, parseable or not).
/// The default is [LocalDbEcgSource]; tests hand in a fake.
abstract class EcgReadingSource {
  /// Every reading row (superseded included) oldest -> newest by start_ts, then
  /// id; at most [limit] rows strictly after [after] in that order.
  Future<List<Map<String, Object?>>> pageRows({
    EcgPageCursor? after,
    required int limit,
  });

  /// The kept packet rows of [readingId] in ordinal order; EMPTY = not kept.
  Future<List<Map<String, Object?>>> packetRows(String readingId);

  /// Every attempt row in [readingId]'s group, ordered by attempt (the reading
  /// itself for a legacy row).
  Future<List<Map<String, Object?>>> attemptRows(String readingId);
}

/// [EcgReadingSource] over LocalDb. Rows are copied to plain maps so a page can
/// be sent to a worker isolate.
class LocalDbEcgSource implements EcgReadingSource {
  const LocalDbEcgSource();

  static List<Map<String, Object?>> _plain(List<Map<String, Object?>> rows) => [
    for (final r in rows) Map<String, Object?>.of(r),
  ];

  @override
  Future<List<Map<String, Object?>>> pageRows({
    EcgPageCursor? after,
    required int limit,
  }) async => _plain(
    await LocalDb.ecgReadingsForExport(
      limit: limit,
      afterStartTs: after?.startTs,
      afterId: after?.id,
    ),
  );

  @override
  Future<List<Map<String, Object?>>> packetRows(String readingId) async =>
      _plain(await LocalDb.ecgReadingPackets(readingId));

  @override
  Future<List<Map<String, Object?>>> attemptRows(String readingId) async =>
      _plain(await LocalDb.ecgAttempts(readingId));
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
  _writePackets(b, packets);
  return b.toString();
}

void _writePackets(StringBuffer b, List<EcgAcceptedPacket> packets) {
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
}

/// Why [EcgReading.fromRow] refuses [row], in words; empty when it parses.
String _unparseableWhy(Map<String, Object?> row) {
  String quoted(Object? v) => v == null ? 'missing' : "'$v'";
  return [
    if (row['id'] is! String) 'id ${quoted(row['id'])}',
    if (EcgWrist.parse(row['wrist'] as String?) == null)
      'unknown wrist ${quoted(row['wrist'])}',
    if (EcgCategory.parse(row['category'] as String?) == null)
      'unknown category ${quoted(row['category'])}',
    if (EcgReadingStatus.parse(row['status'] as String?) == null)
      'unknown status ${quoted(row['status'])}',
  ].join(', ');
}

/// One STORED row + its kept packet rows as a block: [formatEcgReading] when
/// the row parses, else the row's raw columns under an
/// `outcome: unparseable (reason)` line. THE formatter of stored rows: the
/// per-reading export and the bulk worker both call it.
String formatEcgRow(
  Map<String, Object?> row,
  List<Map<String, Object?>> packetRows,
) {
  final packets = [for (final r in packetRows) EcgPacketCodec.fromRow(r)];
  final reading = EcgReading.fromRow(row);
  if (reading != null) return formatEcgReading(reading, packets);
  final b = StringBuffer()
    ..writeln('id: ${_opt(row['id'])}')
    ..writeln('outcome: unparseable (${_unparseableWhy(row)})');
  for (final e in row.entries) {
    if (e.key != 'id') b.writeln('${e.key}: ${_opt(e.value)}');
  }
  _writePackets(b, packets);
  return b.toString();
}

/// A page of raw rows and each row's kept packet rows (same order), as sent to
/// the formatting worker. sqlite cells are int / double / String / null /
/// Uint8List, which cross an isolate as they are; a map of `Object?` is outside
/// the closed sendable grammar, hence the shape annotation and its round-trip
/// test (test/ecg_transparency/sendable_ecgFormatPageHeavy_test.dart).
@SendableShape('sqlite row maps: int, double, String, null and Uint8List cells')
class EcgRawPage {
  const EcgRawPage(this.rows, this.packetRows);
  final List<Map<String, Object?>> rows;
  final List<List<Map<String, Object?>>> packetRows;
}

/// WORKER ENTRY (registered in kWorkerEntries): the text of one page, each
/// block preceded by the blank line the log puts between readings. Decoding the
/// kept waveform bytes and formatting every sample is work that grows with the
/// store, so it runs here, not on the UI isolate. A pure function of
/// [inputs] and [page].
@heavy
String ecgFormatPageHeavy(WorkerInputs inputs, EcgRawPage page) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('ecgFormatPageHeavy');
  final out = StringBuffer();
  for (var i = 0; i < page.rows.length; i++) {
    out
      ..writeln()
      ..write(formatEcgRow(page.rows[i], page.packetRows[i]));
  }
  return out.toString();
}

Future<String> _formatPageInWorker(
  EcgExportHeader header,
  EcgRawPage page,
) {
  // The clock is the injected export time; the formatter reads no zone (all
  // times print UTC) and no locale.
  final inputs = WorkerInputs(
    nowEpochMs: header.exportedAt.millisecondsSinceEpoch,
    zoneId: 'UTC',
    localeTag: 'en',
  );
  WorkerAudit.dispatched(Dispatcher.run, 'ecg export page');
  // Null in production; a test's port so the worker reports its entry.
  final auditPort = WorkerAudit.auditPort;
  return Isolate.run(() {
    WorkerAudit.adopt(auditPort);
    return ecgFormatPageHeavy(inputs, page);
  });
}

EcgPageCursor _cursorOf(Map<String, Object?> lastRow) {
  final ts = lastRow['start_ts'];
  final id = lastRow['id'];
  if (ts is! num || id is! String) {
    // Not silently stopped: a row that cannot be paged past would otherwise cut
    // the log short and still report success.
    throw StateError(
      'a stored ECG row has no readable start_ts / id (start_ts: $ts, id: $id); '
      'the log cannot page past it',
    );
  }
  return (startTs: ts.toInt(), id: id);
}

/// The bulk log as chunks: the header, then one chunk per page of [pageSize]
/// rows (no 200 cap, no unbounded read), oldest -> newest. Each page is read on
/// this isolate and formatted in a worker; the caller appends each chunk to the
/// file as it arrives. The walk follows the RAW (start_ts, id) key of the last
/// row of a page, so rows that cannot be parsed neither end it nor are skipped.
Stream<String> ecgLogChunksAll({
  required EcgExportHeader header,
  required EcgReadingSource source,
  int pageSize = 200,
}) async* {
  yield formatEcgHeader(header);
  EcgPageCursor? after;
  while (true) {
    final rows = await source.pageRows(after: after, limit: pageSize);
    if (rows.isEmpty) return;
    final next = _cursorOf(rows.last);
    if (next == after) {
      throw StateError('the ECG export did not advance past ${next.id}');
    }
    final packets = [
      for (final r in rows)
        r['id'] is String
            ? await source.packetRows(r['id']! as String)
            : const <Map<String, Object?>>[],
    ];
    yield await _formatPageInWorker(header, EcgRawPage(rows, packets));
    after = next;
  }
}

/// Header + the attempt group of [readingId] (oldest attempt first), each block
/// formatted by [formatEcgRow]. A group is a handful of readings, so this stays
/// on the calling isolate.
Future<String> buildEcgLogFor({
  required EcgExportHeader header,
  required EcgReadingSource source,
  required String readingId,
}) async {
  final out = StringBuffer(formatEcgHeader(header));
  for (final row in await source.attemptRows(readingId)) {
    final id = row['id'];
    out
      ..writeln()
      ..write(
        formatEcgRow(row, id is String ? await source.packetRows(id) : const []),
      );
  }
  return out.toString();
}
