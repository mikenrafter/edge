// Owner: PulseEpisodeStore. STUB (red phase): bodies are deliberately inert so
// the store tests fail on assertions, not on missing symbols.
import 'package:sqflite/sqflite.dart';

import '../../compute/processing_context.dart';
import 'pulse_ep_codec.dart';
import 'pulse_ep_types.dart';

const int kPulseEvidenceBudgetBytes = 128 * 1024 * 1024;
const int kPulseEvidenceDays = 365;

class PulseAdmittedRecord {
  const PulseAdmittedRecord(this.tsMs, this.rr);
  final int tsMs;
  final List<int> rr;
}

class PulseAdmission {
  const PulseAdmission({required this.records, required this.novel});
  final int records, novel;
}

class PulseStamp {
  const PulseStamp({required this.inputRev, required this.context, required this.generation});
  final int inputRev, generation;
  final String context;
  String get encoded => '$inputRev|$context|$generation';
  @override
  bool operator ==(Object other) => other is PulseStamp && other.encoded == encoded;
  @override
  int get hashCode => encoded.hashCode;
}

class PulsePublication {
  const PulsePublication({
    required this.episodeId,
    required this.source,
    required this.seedStartMs,
    required this.seedEndMs,
    required this.startMs,
    required this.endMs,
    required this.ongoing,
    required this.startDay,
    required this.endDay,
    required this.detector,
    required this.algo,
    required this.alertEligible,
    required this.origin,
    required this.summaryJson,
    required this.evidence,
    required this.supportKeysMs,
    required this.nowMs,
    this.refusal,
  });
  final String episodeId, source, startDay, endDay, origin, summaryJson;
  final int seedStartMs, seedEndMs, startMs, endMs, detector, algo, nowMs;
  final bool ongoing, alertEligible;
  final String? refusal;
  final PulseEncoded? evidence;
  final List<int> supportKeysMs;
}

class PulseEpisodeStore {
  PulseEpisodeStore._();
  static const bool schedulingEnabled = false;

  static Future<void> createTables(DatabaseExecutor db) async {}

  static Future<void> captureUpgrade(DatabaseExecutor db, {required int nowMs}) async {}

  static Future<PulseAdmission> recordAdmission(
    DatabaseExecutor txn, {
    required String source,
    required List<PulseAdmittedRecord> records,
    required ProcessingOrigin origin,
    required int nowMs,
  }) async => const PulseAdmission(records: 0, novel: 0);

  static Future<PulseStamp> readStamp(DatabaseExecutor db,
          {required String source, required int fromMs, required int toMs}) async =>
      const PulseStamp(inputRev: 0, context: '', generation: 0);

  static Future<PulseApply> publish(Database db, PulsePublication p,
          {required PulseStamp expected}) async =>
      const PulseRefused('stub');

  static Future<PulseApply> retract(Database db, String episodeId,
          {required String reason, required int nowMs}) async =>
      const PulseRefused('stub');

  static Future<PulseApply> recordRefusal(Database db, String episodeId,
          {required String reason}) async =>
      const PulseRefused('stub');

  static Future<int> advanceCheckpoint(Database db,
          {required String source,
          required int throughMs,
          required PulseStamp stamp,
          required int detector,
          required int nowMs}) async =>
      0;

  static Future<int> pruneAdmissions(DatabaseExecutor txn,
          {required int cutoffMs, required int hardFloorMs, bool holdEnabled = schedulingEnabled}) async =>
      0;

  static Future<int> enforceRetention(Database db,
          {required int nowMs, int budgetBytes = kPulseEvidenceBudgetBytes}) async =>
      0;
}
