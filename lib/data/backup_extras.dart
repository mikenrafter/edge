// backup_extras.dart — what a full-database export carries besides SQL tables.
//
// RED-PHASE STUBS (design: owner's "I exported the whole DB, it should
// transfer gestures, haptics presets, everything"). The declarations below are
// the seams the green phase fills in; the bodies do nothing yet.
//
// Green contract:
//  * [writeBackupExtras] runs on the EXPORTED COPY only (never the live DB),
//    after VACUUM INTO, and creates [kBackupPrefsTable]
//    (key TEXT PRIMARY KEY, type TEXT, value TEXT) from every SharedPreferences
//    key that [prefsKeyBackedUp] accepts, and [kBackupFilesTable]
//    (rel_path TEXT PRIMARY KEY, bytes BLOB) from `<docs>/device_lab/imu/*`.
//    These tables are not part of the live schema (no version bump).
//  * [restoreBackupExtras] puts back every backed-up key absent on this
//    install; for keys already present the backup wins only when
//    [freshInstall]. Files are restored only when absent.
//  * Secrets in FlutterSecureStorage never enter the backup.
import 'package:shared_preferences/shared_preferences.dart';

const String kBackupPrefsTable = 'backup_prefs';
const String kBackupFilesTable = 'backup_files';

/// Exact preference keys that stay on the device, each with the reason.
const Map<String, String> kPrefsNotBackedUp = {
  'install_device_id': 'identifies THIS install; a restore must not clone it',
  'paired_remote_id': 'BLE address of the band bonded to this phone',
  'consent_telemetry': 'consent is asked again on each install',
  'backup.folder': 'a storage-access URI/permission that is not valid elsewhere',
  'backup.last_run_ms': 'status of this install\'s auto-backup',
  'backup.last_error': 'status of this install\'s auto-backup',
  'alarm_probe_pending': 'transient: an in-flight alarm check on this phone',
  'ble.ask_add_pending': 'transient: a pairing prompt waiting on this phone',
  'health_upload_last_ts': 'telemetry upload cursor of this install',
  'settings_recovery_journal_v1': 'transient write-ahead journal',
  'import_summary_v1': 'record of the last import on this install',
};

/// Key prefixes that stay on the device, each with the reason.
const Map<String, String> kPrefsNotBackedUpPrefixes = {
  'backup.': 'auto-backup state of this install',
};

/// Whether [key] belongs in a backup.
bool prefsKeyBackedUp(String key) {
  if (kPrefsNotBackedUp.containsKey(key)) return false;
  for (final p in kPrefsNotBackedUpPrefixes.keys) {
    if (key.startsWith(p)) return false;
  }
  return true;
}

/// STUB. Adds [kBackupPrefsTable] and [kBackupFilesTable] to the exported copy
/// at [copyPath].
Future<void> writeBackupExtras(String copyPath, {SharedPreferences? prefs}) async {}

class BackupExtrasResult {
  const BackupExtrasResult({
    this.prefsRestored = 0,
    this.prefsKept = 0,
    this.filesRestored = 0,
  });
  final int prefsRestored, prefsKept, filesRestored;
}

/// STUB. Restores prefs and files from the backup at [srcPath].
Future<BackupExtrasResult> restoreBackupExtras(
  String srcPath, {
  required bool freshInstall,
}) async => const BackupExtrasResult();

/// STUB. True when this install holds no decoded rows and no day_result.
Future<bool> isFreshInstall() async => false;

/// What the last import did, for the screen that follows it.
class ImportSummary {
  const ImportSummary({
    this.daysWithRaw = 0,
    this.daysDerived = 0,
    this.archiveBucketsSkipped = 0,
    this.sourceDaysAboveCeiling = 0,
    this.prefsRestored = 0,
    this.prefsKept = 0,
    this.filesRestored = 0,
  });

  /// Days with raw (decoded) data in the source.
  final int daysWithRaw;

  /// Days with a derived result in this database after the import.
  final int daysDerived;

  /// substrate_archive buckets skipped for an unknown codec.
  final int archiveBucketsSkipped;

  /// Distinct source days whose every day_result is above this build's
  /// kAlgoVersion.
  final int sourceDaysAboveCeiling;
  final int prefsRestored, prefsKept, filesRestored;
}

/// STUB. The summary of the last import on this install, or null.
Future<ImportSummary?> lastImportSummary() async => null;
