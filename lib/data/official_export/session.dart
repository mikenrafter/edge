// Owns value types for the UI-engine export session. File ownership stays with
// OfficialExportCoordinator; receipts never contain a passphrase.
import 'dart:io';
import '../backup_storage.dart';
import 'mapper.dart';
import 'space_budget.dart';

class ExportCancelled implements Exception { const ExportCancelled(); }
class ExportCancellation {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  void check() { if (_cancelled) throw const ExportCancelled(); }
}

enum ExportStage { ready, preparing, mapping, encrypting, verifying, publishing, recoveryChoice, complete, interrupted, failed, cancelled }
enum ExportArtifact { official, recovery }
class ExportProgress {
  const ExportProgress(this.stage, {this.artifact = ExportArtifact.official, this.done = 0, this.total, this.family, this.elapsed = Duration.zero});
  final ExportStage stage;
  final ExportArtifact artifact;
  final int done;
  final int? total;
  final String? family;
  final Duration elapsed;
}
class ExportEstimate {
  const ExportEstimate(this.sqlBytes, this.exactArchiveBytes, this.extrasBytes);
  final int sqlBytes, exactArchiveBytes, extrasBytes;
  // Snapshot + mapped file (3x SQL + 2x expanded archive) + two provider
  // ciphertext copies during publication + bounded buffers. No verify file.
  int get peakBytes => sqlBytes + extrasBytes + 3 * (sqlBytes * 3 + exactArchiveBytes * 2 + extrasBytes + 54) + 8 * 1024 * 1024;
}
class SnapshotReceipt {
  const SnapshotReceipt(this.path, this.sha256, this.schema, this.startedMs, this.finishedMs, {this.omissions = const []});
  final String path, sha256;
  final int schema, startedMs, finishedMs;
  final List<Map<String,Object?>> omissions;
  Map<String,Object?> toJson() => {'sha256':sha256,'schema':schema,'started_ms':startedMs,'finished_ms':finishedMs,'extras_omissions':omissions};
}
abstract interface class OfficialSnapshotSource {
  Future<ExportEstimate> estimate();
  Future<SnapshotReceipt> capture(Directory session, ExportSpaceBudget space, ExportCancellation cancellation);
}
abstract interface class PartialExportSnapshotSource implements OfficialSnapshotSource {
  Future<ExportEstimate> estimateWithoutSavedFiles();
}
class VerifiedExportFile {
  const VerifiedExportFile(this.file, this.folder, this.plainSha256, this.bytes);
  final BackupFile file;
  final String folder, plainSha256;
  final int bytes;
}
enum RecoveryStatus { awaitingChoice, saved, declined, failed, cancelled }
sealed class OfficialExportOutcome {
  const OfficialExportOutcome();
  VerifiedExportFile? get official => null;
}
class OfficialExportSaved extends OfficialExportOutcome {
  const OfficialExportSaved(this.receipt, this.report, this.recoveryStatus, {this.recovery, this.recoveryError});
  final VerifiedExportFile receipt;
  final OfficialMapReport report;
  final RecoveryStatus recoveryStatus;
  final VerifiedExportFile? recovery;
  final Object? recoveryError;
  @override VerifiedExportFile get official => receipt;
}
class OfficialExportRefused extends OfficialExportOutcome {
  const OfficialExportRefused(this.reason);
  final Object reason;
}
class OfficialExportFailed extends OfficialExportOutcome {
  const OfficialExportFailed(this.stage,this.reason,{this.receipt});
  final ExportStage stage;
  final Object reason;
  final VerifiedExportFile? receipt;
  @override VerifiedExportFile? get official => receipt;
}
class OfficialExportCancelled extends OfficialExportOutcome {
  const OfficialExportCancelled({this.receipt});
  final VerifiedExportFile? receipt;
  @override VerifiedExportFile? get official => receipt;
}

class OfficialExportSavedWithOmissions extends OfficialExportSaved {
  const OfficialExportSavedWithOmissions(super.receipt,super.report,super.recoveryStatus,{super.recovery,super.recoveryError});
}
