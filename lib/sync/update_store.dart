// Owns install-local update consent, cache, leases and permanent release
// claims in `release-checks-v1.db` under Android's noBackupFilesDir. Separate
// from LocalDb: updates never write health tables or enter an export, and no
// code here opens the health database.
import 'package:sqflite/sqflite.dart';

import '../notify/event_claim_ledger.dart';
import 'update_models.dart';

/// One batch's right to write. A stale holder (older token, older generation)
/// is refused on every write.
class UpdateLease {
  const UpdateLease(this.token, this.generation);
  final int token, generation;
}

/// What [UpdateStore.beginRelease] hands the one delivering owner.
class ReleaseTicket {
  const ReleaseTicket(this.identity, this.osId, this.token);
  final String identity;
  final int osId, token;
}

/// The store file cannot be used by this build (a newer schema).
class UpdateStoreException implements Exception {
  const UpdateStoreException(this.message);
  final String message;
  @override
  String toString() => 'UpdateStoreException: $message';
}

class UpdateStore {
  UpdateStore(this.db);
  final Database db;

  /// Independent of LocalDb's schema; bumped only with an additive migration.
  static const schemaVersion = 1;
  static const busyTimeout = Duration(seconds: 2);

  /// Manifest cache rows kept (positive and negative together).
  static const manifestRetention = 64;

  /// The production file under Android's noBackupFilesDir (or the app support
  /// directory off Android), shared by the UI and the background worker.
  static Future<UpdateStore> open() => throw UnimplementedError();

  /// [open] for a given path and factory; tests and [open] use it.
  static Future<UpdateStore> openFile(
    String path, {
    DatabaseFactory? factory,
  }) async => UpdateStore(await (factory ?? databaseFactory).openDatabase(path));

  Future<void> initialize() async {}
  Future<UpdateSnapshot> read() async => const UpdateSnapshot();
  Future<void> setEnabled(bool enabled) async {}
  Future<void> setOfficialPrereleases(bool enabled) async {}
  Future<UpdateLease?> claim(
    DateTime now, {
    required bool manual,
    Duration jitter = Duration.zero,
  }) async => null;
  Future<bool> save(
    UpdateLease lease,
    ReleaseSource source,
    SourceUpdate result,
  ) async => false;
  Future<Map<String, dynamic>?> manifest(String key) async => null;
  Future<bool> saveManifest(
    UpdateLease lease,
    String key,
    Map<String, dynamic> metadata,
  ) async => false;
  Future<bool> valid(UpdateLease lease) async => false;
  Future<bool> renew(UpdateLease lease, DateTime now) async => false;
  Future<void> release(UpdateLease lease) async {}
  Future<void> acknowledgeReset() async {}

  Future<ReleaseTicket?> beginRelease(String identity, DateTime now) async =>
      null;
  Future<void> settleRelease(ReleaseTicket ticket, ClaimOutcome outcome) async {}
  Future<List<String>> heldReleases() async => const [];
  Future<void> discardHeld() async {}
  Future<bool> claimTarget(String identity, String target) async => false;
  Future<void> releaseTarget(String identity, String target) async {}
}
