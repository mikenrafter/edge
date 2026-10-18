// Shared fixtures for the ECG-features tests. Test-only.

import 'dart:typed_data';

import 'package:openstrap_edge/ecg/ecg_models.dart';

const int kT0 = 1787823754; // epoch seconds, the first reading's start

/// A saved reading. Defaults: a complete sinus-rhythm 30 s reading at [kT0].
EcgReading fixtureReading({
  String id = 'ecg_1',
  EcgReadingStatus status = EcgReadingStatus.completed,
  EcgCategory category = EcgCategory.sinusRhythm,
  int startTs = kT0,
  int? endTs,
  int resultCode = 1,
  int? avgHr = 77,
  int? quality = 3,
  int interruptions = 0,
  int sampleCount = 3000,
  String? stopReason,
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
  unreadableMask: 0,
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
);

/// An inconclusive reading that ended at [endTs].
EcgReading inconclusiveEndingAt(int endTs, {String id = 'ecg_inc'}) =>
    fixtureReading(
      id: id,
      status: EcgReadingStatus.inconclusive,
      category: EcgCategory.inconclusive,
      resultCode: 6,
      startTs: endTs - 30,
      endTs: endTs,
    );

/// A partial reading (stopped early) that ended at [endTs].
EcgReading partialEndingAt(int endTs, {String id = 'ecg_part'}) =>
    fixtureReading(
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

/// 100 samples of a flat-ish test wave, as a DB packet row.
Map<String, Object?> packetRow(int seq) {
  final bytes = Uint8List(200);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < 100; i++) {
    bd.setInt16(2 * i, i - 50, Endian.little);
  }
  return {
    'sequence': seq,
    'strap_seconds': kT0 + seq,
    'strap_subsec': 0,
    'sample_count': 100,
    'samples': bytes,
    'inner_hex': '2b11${seq.toRadixString(16)}',
    'is_placeholder': 0,
  };
}
