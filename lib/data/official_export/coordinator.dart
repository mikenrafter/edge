// Owns the UI-engine export guard, passphrase, receipts and private files.
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../backup_storage.dart';
import 'session.dart';
import 'space_budget.dart';

class OfficialExportCoordinator extends ChangeNotifier {
  ExportProgress progress = const ExportProgress(ExportStage.ready);
  OfficialExportOutcome? outcome;
  void cancel() {}
  Future<OfficialExportOutcome> export({
    required OfficialSnapshotSource snapshot, required Directory privateRoot,
    required CipherBackupStorage destination, required ExportSpaceBudget space,
    required Future<String?> Function() askPassphrase,
    required Future<bool> Function(OfficialExportSaved) askRecovery,
  }) async => const OfficialExportRefused('stub');
  static Future<void> cleanupAbandoned(Directory root) async {}
}
