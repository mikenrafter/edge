// Owner: the Pulse evidence codec. STUB (red phase): behaviour is deliberately
// wrong so the codec tests fail on assertions, not on missing symbols.
import 'dart:typed_data';

import 'pulse_ep_types.dart';

const int kPulseEvidenceSchema = 1;
const int kPulseEvidenceMaxBytes = 1024 * 1024;
const int kPulseMaxBeats = 20000;
const int kPulseMaxOverviewBins = 4096;
const int kPulseMaxWindowRows = 4096;

/// One retained beat. Identity is `source:recordTsMs:beatIndex`.
class PulseBeat {
  const PulseBeat({
    required this.recordTsMs,
    required this.beatIndex,
    required this.ordinal,
    required this.timeMs,
    required this.originalTimeMs,
    required this.rawMs,
    this.correctedMs,
    this.flags = 0,
    this.labels = const [],
  });
  final int recordTsMs, beatIndex, ordinal, timeMs, originalTimeMs;
  final double rawMs;
  final double? correctedMs;
  final int flags;
  final List<String> labels;

  static const plausible = 1,
      retained = 2,
      corrected = 4,
      dropped = 8,
      featureUse = 16,
      validAdjacent = 32;
  bool has(int flag) => flags & flag != 0;
  String idIn(String source) => '$source:$recordTsMs:$beatIndex';
}

class PulseOverviewBin {
  const PulseOverviewBin(this.startMs, this.n, this.p10, this.median, this.p90);
  final int startMs, n;
  final double p10, median, p90;
}

class PulseHrBin {
  const PulseHrBin(this.startMs, this.bpm);
  final int startMs;
  final double bpm;
}

class PulseEvidence {
  const PulseEvidence({
    required this.episodeId,
    required this.source,
    required this.startMs,
    required this.endMs,
    required this.ongoing,
    required this.beats,
    this.windows = const [],
    this.overview = const [],
    this.hr = const [],
    this.comparisonRrMs = const [],
    this.jumps = const [],
    this.omitted = const [],
  });
  final String episodeId, source;
  final int startMs, endMs;
  final bool ongoing;
  final List<PulseBeat> beats;
  final List<Map<String, Object?>> windows;
  final List<PulseOverviewBin> overview;
  final List<PulseHrBin> hr;
  final List<double> comparisonRrMs;
  final List<String> jumps;
  final List<PulseRange> omitted;
  bool get partial => omitted.isNotEmpty;
}

sealed class PulseEncodeResult {
  const PulseEncodeResult();
}

final class PulseEncoded extends PulseEncodeResult {
  const PulseEncoded({
    required this.bytes,
    required this.checksum,
    required this.expandedBytes,
    required this.evidence,
  });
  final Uint8List bytes;
  final String checksum;
  final int expandedBytes;
  final PulseEvidence evidence;
  int get encodedBytes => bytes.length;
}

final class PulseEncodeRefused extends PulseEncodeResult {
  const PulseEncodeRefused(this.reason);
  final String reason;
}

sealed class PulseEvidenceRead {
  const PulseEvidenceRead();
}

final class PulseEvidenceAvailable extends PulseEvidenceRead {
  const PulseEvidenceAvailable(this.evidence);
  final PulseEvidence evidence;
}

final class PulseEvidencePartial extends PulseEvidenceRead {
  const PulseEvidencePartial(this.evidence);
  final PulseEvidence evidence;
}

final class PulseEvidenceUnsupported extends PulseEvidenceRead {
  const PulseEvidenceUnsupported(this.reason);
  final String reason;
}

final class PulseEvidenceCorrupt extends PulseEvidenceRead {
  const PulseEvidenceCorrupt(this.reason);
  final String reason;
}

PulseEncodeResult encodePulseEvidence(PulseEvidence evidence) =>
    const PulseEncodeRefused('stub');

PulseEvidenceRead decodePulseEvidence(List<int> bytes, {required String checksum}) =>
    const PulseEvidenceCorrupt('stub');

/// Sorted-index quantile: `floor((n - 1) * p)`. Empty populations have none.
double? pulseQuantile(List<double> sorted, double p) => null;
