// ECG log export (design 04 R7' / R7''): ONE formatter for a reading, used by
// the per-reading export and by "Export ECG logs" (every reading, superseded
// attempts included). The file leaves through logFileName + saveLogFileResult
// (invariant 16); never the clipboard.
//
// RED STUB (design 04 phase 1): the types are real, the functions throw.

import 'ecg_models.dart';

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

/// [EcgReadingSource] over LocalDb.
class LocalDbEcgSource implements EcgReadingSource {
  const LocalDbEcgSource();
  @override
  Future<List<EcgReading>> page({EcgReading? after, required int limit}) =>
      throw UnimplementedError('design 04 phase 1: LocalDbEcgSource.page');
  @override
  Future<List<EcgAcceptedPacket>> packets(String readingId) =>
      throw UnimplementedError('design 04 phase 1: LocalDbEcgSource.packets');
  @override
  Future<List<EcgReading>> attempts(String readingId) =>
      throw UnimplementedError('design 04 phase 1: LocalDbEcgSource.attempts');
}

/// What the screens need to build an [EcgExportHeader] (the pins and versions
/// come from kAnalyticsPin / kProtocolPin / kAlgoVersion /
/// kEcgOutcomeTableVersion, not from the screen).
class EcgExportEnv {
  const EcgExportEnv({required this.appVersion, required this.now});
  final Future<String> Function() appVersion;
  final DateTime Function() now;
}

/// The header block (one `key: value` per line).
String formatEcgHeader(EcgExportHeader h) =>
    throw UnimplementedError('design 04 phase 1: formatEcgHeader');

/// One reading block + its packets (or `packets: not kept` when [packets] is
/// empty). THE formatter: per-reading and bulk both call it.
String formatEcgReading(EcgReading r, List<EcgAcceptedPacket> packets) =>
    throw UnimplementedError('design 04 phase 1: formatEcgReading');

/// Header + every reading in [source], oldest -> newest, paged ([pageSize]
/// rows per [EcgReadingSource.page] call) until exhausted - no 200 cap.
Future<String> buildEcgLogAll({
  required EcgExportHeader header,
  required EcgReadingSource source,
  int pageSize = 200,
}) => throw UnimplementedError('design 04 phase 1: buildEcgLogAll');

/// Header + the attempt group of [readingId] (oldest attempt first), each block
/// formatted by [formatEcgReading].
Future<String> buildEcgLogFor({
  required EcgExportHeader header,
  required EcgReadingSource source,
  required String readingId,
}) => throw UnimplementedError('design 04 phase 1: buildEcgLogFor');
