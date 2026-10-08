// Shared fixtures for the design-04 phase 1 (cardio transparency) tests.
// Test-only. Fixed dates, injected clocks: nothing here reads the real time.

import 'dart:io';
import 'dart:typed_data';

import 'package:openstrap_edge/ecg/ecg_export.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_outcome.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// 2026-08-31T12:02:34Z. The first reading's start.
const int kC0 = 1787823754;

/// A saved reading with every phase-1 field spelled out. Defaults: a complete
/// sinus-rhythm 30 s reading at [kC0], mask 0, nothing recorded for the new
/// columns (a legacy-shaped row) unless a field is given.
EcgReading cardioReading({
  String id = 'ecg_1',
  EcgReadingStatus status = EcgReadingStatus.completed,
  EcgCategory category = EcgCategory.sinusRhythm,
  int startTs = kC0,
  int? endTs,
  int resultCode = 1,
  int? avgHr = 77,
  int? quality = 3,
  int unreadableMask = 0,
  int interruptions = 0,
  int sampleCount = 3000,
  String? stopReason,
  int? maskAny,
  String? supersededBy,
  String? attemptGroup,
  int? attempt,
  int? liveHr,
  int? variabilityRaw,
  String? firmwareVersion,
  String? captureAppVersion,
  int? captureTableVersion,
  int? startOffsetMin,
}) => EcgReading(
  id: id,
  deviceId: '',
  wrist: EcgWrist.right,
  startTs: startTs,
  endTs: endTs ?? startTs + 30,
  strapTerminalTs: null,
  strapTerminalSubsec: null,
  resultCode: resultCode,
  category: category,
  avgHr: avgHr,
  quality: quality,
  unreadableMask: unreadableMask,
  interruptions: interruptions,
  sampleCount: sampleCount,
  minUv: -500,
  maxUv: 700,
  rmsUv: 120.5,
  missingSegments: 0,
  status: status,
  notes: null,
  createdAt: (endTs ?? startTs + 30) * 1000,
  stopReason: stopReason,
  maskAny: maskAny,
  supersededBy: supersededBy,
  attemptGroup: attemptGroup,
  attempt: attempt,
  liveHr: liveHr,
  variabilityRaw: variabilityRaw,
  firmwareVersion: firmwareVersion,
  captureAppVersion: captureAppVersion,
  captureTableVersion: captureTableVersion,
  startOffsetMin: startOffsetMin,
);

/// A reading the band called unreadable (result 2): status completed,
/// category unreadable, ended at [endTs].
EcgReading unreadableEndingAt(int endTs, {String id = 'ecg_unr', int mask = 2}) =>
    cardioReading(
      id: id,
      category: EcgCategory.unreadable,
      resultCode: 2,
      startTs: endTs - 30,
      endTs: endTs,
      unreadableMask: mask,
    );

/// A first/second inconclusive (result 6) that ended at [endTs].
EcgReading inconclusiveAt(int endTs, {String id = 'ecg_inc'}) => cardioReading(
  id: id,
  status: EcgReadingStatus.inconclusive,
  category: EcgCategory.inconclusive,
  resultCode: 6,
  startTs: endTs - 30,
  endTs: endTs,
);

/// A partial reading (stopped early) that ended at [endTs].
EcgReading partialAt(int endTs, {String id = 'ecg_part'}) => cardioReading(
  id: id,
  status: EcgReadingStatus.partial,
  category: EcgCategory.inconclusive,
  resultCode: 0,
  startTs: endTs - 12,
  endTs: endTs,
  avgHr: null,
  quality: null,
  sampleCount: 1200,
  stopReason: 'paused',
);

/// One kept packet row with an exactly-known inner hex (not 2b11...), so an
/// export can be checked byte for byte.
Map<String, Object?> cardioPacketRow(int seq, {int n = 100}) {
  final bytes = Uint8List(n * 2);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < n; i++) {
    bd.setInt16(2 * i, i - 50 + seq, Endian.little);
  }
  return {
    'sequence': seq,
    'strap_seconds': kC0 + seq,
    'strap_subsec': 0,
    'sample_count': n,
    'samples': bytes,
    'inner_hex': 'ab${seq.toRadixString(16).padLeft(2, '0')}cdef01',
    'is_placeholder': 0,
  };
}

EcgAcceptedPacket cardioPacket(int seq, {int n = 100}) =>
    EcgPacketCodec.fromRow(cardioPacketRow(seq, n: n));

/// A live R17 packet with every byte the phase-1 tests care about settable.
/// [variability] null = the wire's 0xffff "unavailable".
LabradorR17 r17({
  required int seq,
  int progress = 3,
  bool presence = true,
  bool s2One = true,
  int s2State = 1,
  int result = 0,
  int liveHr = 70,
  int avgHr = 0,
  int unreadable = 0,
  int quality = 2,
  int? variability,
}) {
  final inner = Uint8List(26 + 200);
  final v = ByteData.sublistView(inner);
  inner[0] = 0x2B;
  inner[1] = 17;
  v.setUint32(3, seq, Endian.little);
  v.setUint32(7, 1787823700 + seq, Endian.little);
  inner[13] = quality;
  inner[14] = (presence ? 0x08 : 0) | (s2One ? 0x02 : 0);
  inner[15] = result;
  inner[16] = s2State;
  inner[17] = progress;
  inner[18] = unreadable;
  inner[19] = avgHr;
  inner[20] = liveHr;
  v.setUint16(21, variability ?? 0xffff, Endian.little);
  v.setUint16(24, 100, Endian.little);
  for (var i = 0; i < 100; i++) {
    v.setInt16(26 + 2 * i, i - 50, Endian.little);
  }
  return LabradorR17.parse(inner)!;
}

/// A terminal packet (progress 100, S2 state 2).
LabradorR17 r17Terminal({
  required int seq,
  int result = 1,
  int avgHr = 77,
  int liveHr = 78,
  int unreadable = 0,
  int quality = 3,
  int? variability,
}) => r17(
  seq: seq,
  progress: 100,
  s2State: 2,
  s2One: false,
  result: result,
  avgHr: avgHr,
  liveHr: liveHr,
  unreadable: unreadable,
  quality: quality,
  variability: variability,
);

/// The fixed export header the tests compare against.
final EcgExportHeader kHeader = EcgExportHeader(
  appVersion: '9.9.9+99',
  analyticsPin: 'a' * 40,
  protocolPin: 'b' * 40,
  algoVersion: 102,
  outcomeTableVersion: kEcgOutcomeTableVersion,
  exportedAt: DateTime.utc(2026, 10, 8, 12, 0, 0),
);

/// An in-memory [EcgReadingSource]. [pageCalls] records every page request so
/// a test can prove the export paged through everything.
class FakeEcgSource implements EcgReadingSource {
  FakeEcgSource(this.all, {Map<String, List<EcgAcceptedPacket>>? packets})
    : _packets = packets ?? {};
  final List<EcgReading> all;
  final Map<String, List<EcgAcceptedPacket>> _packets;
  final pageCalls = <({String? afterId, int limit})>[];

  int _cmp(EcgReading a, EcgReading b) {
    final c = a.startTs.compareTo(b.startTs);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  @override
  Future<List<EcgReading>> page({EcgReading? after, required int limit}) async {
    pageCalls.add((afterId: after?.id, limit: limit));
    final sorted = [...all]..sort(_cmp);
    final rest = after == null
        ? sorted
        : [for (final r in sorted) if (_cmp(r, after) > 0) r];
    return rest.take(limit).toList();
  }

  @override
  Future<List<EcgAcceptedPacket>> packets(String readingId) async =>
      _packets[readingId] ?? const [];

  @override
  Future<List<EcgReading>> attempts(String readingId) async {
    final me = all.firstWhere((r) => r.id == readingId);
    final g = me.attemptGroup;
    if (g == null) return [me];
    return [for (final r in all) if (r.attemptGroup == g) r]
      ..sort((a, b) => (a.attempt ?? 0).compareTo(b.attempt ?? 0));
  }
}

/// The source of [path] without whole-line `//` comments, so a guard on code
/// is not tripped by prose that names the thing it forbids.
String codeOf(String path) => File(path)
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');
