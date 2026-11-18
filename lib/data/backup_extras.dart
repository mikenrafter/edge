export '../settings/settings_repository.dart' show settingsRestoredSignal;
import 'dart:convert';
import '../notify/notification_prefs.dart';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../compute/derivation_engine.dart' show kAlgoVersion;
import 'db.dart' show LocalDb;
import 'import_reentry_store.dart';
import 'dart:collection';
import '../coach/coach_config.dart' show CoachConfig;
import '../settings/settings_repository.dart' show SettingsRepository;
import '../haptics/pattern_store.dart' show HapticPatternStore;
import '../notify/notification_prefs.dart' show NotificationPrefs;

// backup_extras.dart — what a full-database export carries besides SQL tables.
//
// A full-database export also carries the owner's settings and saved
// recordings ("I exported the whole DB, it should transfer gestures, haptics
// presets, everything", decision D37).
//
// Contract:
//  * [writeBackupExtras] runs on the EXPORTED COPY only (never the live DB),
//    after VACUUM INTO, and creates [kBackupPrefsTable]
//    (key TEXT PRIMARY KEY, type TEXT, value TEXT) from every SharedPreferences
//    key that [prefsKeyBackedUp] accepts, and [kBackupFilesTable]
//    (rel_path TEXT PRIMARY KEY, bytes BLOB) from `<docs>/device_lab/imu/*`.
//    These tables are not part of the live schema (no version bump).
//  * [restoreBackupExtras] puts back every backed-up key absent on this
//    install; for keys already present the backup wins only when
//    [freshInstall]. Files are restored only when absent.
//  * Secrets in FlutterSecureStorage never enter the backup. A restore that
//    finds the backup said such a secret was set reports it in
//    [BackupExtrasResult.needsReentry] so the screen after the import can say
//    "re-enter these" rather than letting the feature quietly stop working.
//  * The completeness audit lives in test/backup/settings_audit_guard_test.dart:
//    every place the app keeps state (preferences, file roots, secure storage,
//    native stores) is carried or listed below with a reason.



const String kBackupPrefsTable = 'backup_prefs';
const String kBackupFilesTable = 'backup_files';

/// Exact preference keys that stay on the device, each with the reason.
const Map<String, String> kPrefsNotBackedUp = {
  'device_alerts.charge_pending_ts': 'Local pending hardware notice; re-evaluate live band state after restore.',
  'notif_critical_override': 'Retired quiet-hours override; accepted from old storage but ignored.',
  'developer.load_timings.v1': 'local performance diagnostics for this install',
  'developer.load_timings_enabled.v1': 'switch for those diagnostics on this install',
  'install_device_id': 'identifies THIS install; a restore must not clone it',
  'paired_remote_id': 'BLE address of the band bonded to this phone',
  'consent_telemetry': 'consent is asked again on each install',
  'consent_health_data': 'consent is asked again on each install',
  'consent_chosen': 'says the consent question was answered; it is asked '
      'again on each install, so a restore must not mark it answered',
  'import_reentry_pending': 'secrets an import could not restore and the '
      'user has not acknowledged, kept per import run; a fact about THIS '
      'install, so a restore must not carry it to another one',
  'coach_api_key_present': 'marks a key in this phone\'s keychain; the key '
      'is not carried (kSecretsNotBackedUp), so the marker would be false',
  'backup.folder': 'a storage-access URI/permission that is not valid elsewhere',
  'backup.last_run_ms': 'status of this install\'s auto-backup',
  'backup.last_error': 'status of this install\'s auto-backup',
  'alarm_schedule_cleared': 'records that Cancel-all ran on this phone, so an '
      'import cannot bring a cancelled alarm back',
  'alarm_probe_pending': 'transient: an in-flight alarm check on this phone',
  'ble.ask_add_pending': 'transient: a pairing prompt waiting on this phone',
  'health_upload_last_ts': 'telemetry upload cursor of this install',
  'settings_recovery_journal_v1': 'transient write-ahead journal',
  'import_summary_v1': 'record of the last import on this install',
  'import_run_v1': 'bookkeeping of the import running on this install',
  'paired_serial': 'identity mirror of the band paired to this phone',
  'paired_generation': 'hardware generation of the band paired to this phone',
  'paired_worn_on': 'wearing mirror includes a BLE handle; the device-row merge restores the choice',
  'coach_chatgpt_present': 'the secure sign-in session does not travel; '
      'sign in to ChatGPT again on this phone',
  'coach_chatgpt_client_id': 'OAuth client registered for this installation; '
      'a new sign-in registers its own client',
  'coach_chatgpt_host_id': 'identifies this phone to the sign-in service',
  'coach_chatgpt_welcomed': 'the new sign-in must show its welcome on this phone',
  'coach_base_url': 'a custom server address can carry an access key; '
      'a non-default one is reported for re-entry',
  'companion_url': 'a server address a restored file must not be able to set; '
      'it redirects announcements, updates and uploads',
  'live.session_draft': 'unfinished workout entries, including private sessions, stay local',
  'live_session_checkpoint': 'write-ahead step recovery for this phone; replay could duplicate steps',
  'telemetry_outbox': 'queued diagnostics belong to this install and its consent',
  'device_alerts.low_armed': 'low-battery latch belongs to the old band; '
      'the new band must establish its own battery state',
  'alarm_epoch': 'arm belongs to the old band; the restored schedule must arm again',
  'alarm_remote_id': 'identifies the band that received this phone’s alarm; restored schedules arm again',
  'alarm_epoch_confirmed': 'confirmation belongs to an arm on the old band',
  'alarm_set_at_ms': 'confirmation replay floor for the old band arm',
  'alarm_pending_until': 'pending confirmation window for the old band arm',
  'alarm_latch_alert': 'pending latch alert for the old band arm',
  'alarm_fired_at': 'last fire event from the old band, not the chosen schedule',
  'smart_wake_fired_epoch': 'records that the early buzz fired for one arm on the old band; '
      'a restored latch would suppress the buzz on the next night\'s arm',
  'health_weight_perm_asked': 'WEIGHT write access is asked per install; '
      'the new install has not asked yet',
  'health_weight_grant_seen': 'the WEIGHT grant is per install; the new '
      'install observes its own',
};

/// Key prefixes that stay on the device, each with the reason. Empty on
/// purpose: a prefix once swept up `backup.cadence`, a setting the owner chose
/// (daily/weekly), so the device-only `backup.*` keys are listed by name above.
const Map<String, String> kPrefsNotBackedUpPrefixes = {
  'ui.home_ring_details.': 'Secondary Home presentation snapshots, not portable health data',
  'ui.load_memory.': 'Local presentation estimates, not portable health data',
};

/// Secrets that stay in the platform keystore, keyed by the lib file that owns
/// them, each with why and what the owner does after a restore. A plain
/// export is a file that gets copied and shared, so a credential does not
/// belong in it.
const Map<String, String> kSecretsNotBackedUp = {
  'lib/coach/coach_config.dart': 'BYOK coach API key (secure storage '
      '"coach_api_key"): a credential; the owner pastes it again '
      '(reported as $kNeedsReentryCoachKey)',
  'lib/ble/miband_link.dart': 'Mi Band pairing key per band: a credential '
      'that only works with the band it was issued for; pair the band again',
  'lib/ble/oura_link.dart': 'Oura ring pairing key per ring: a credential '
      'that only works with the ring it was issued for; pair the ring again',
  'lib/coach/coach_chatgpt.dart': 'ChatGPT access and refresh tokens stay in '
      'secure storage; sign in again on the new phone',
};

/// The [BackupExtrasResult.needsReentry] name for the coach API key.
const String kNeedsReentryCoachKey = 'coach_api_key';

/// Native (Kotlin/Swift) stores the Dart preference export cannot see, each
/// with why it is not carried. `FlutterSharedPreferences` is the Dart
/// preferences themselves and is carried.
const Map<String, String> kNativeStateNotBackedUp = {
  'openstrap_runtime': 'Android: a pending boot/Tasker buzz flag (transient) '
      'and the Tasker auth token, a credential generated per install; paste '
      'the new token into Tasker',
  'openstrap_steps': 'Android: raw step-counter baseline of THIS phone\'s '
      'sensor and its boot clock; false on another phone',
  'FlutterSharedPreferences': 'CARRIED: this is the Dart preference store '
      '(backup_prefs)',
};

/// Dart files that open a folder the app keeps data in (documents, support,
/// external, databases), and whether that folder is carried. Temporary and
/// cache folders are cleared by the OS and are not listed.
const Map<String, String> kFileRootsBackedUp = {
  'lib/gestures/imu_recording_store.dart': 'device_lab/imu recordings '
      '(backup_files)',
  'lib/coach/coach_engine.dart': 'coach chat sessions coach_s_*/coach_idx_* '
      '(backup_files)',
  'lib/data/backup_extras.dart': 'the carrier itself',
};

const Map<String, String> kFileRootsNotBackedUp = {
  'lib/data/disk_space.dart': 'reads the database volume free-space counter; writes no files',
  'lib/data/auto_backup.dart': 'the automatic backups themselves; they are '
      'what an import reads',
  'lib/sync/dev_log.dart': 'diagnostic log; not a setting, rotates',
  'lib/data/db.dart': 'the live database; its tables are carried by the '
      'restore tables',
  'lib/data/db/schema.dart': 'the live database; its tables are carried by '
      'the restore tables',
  'lib/coach/coach_db.dart': 'a read-only handle on the live database',
  'lib/data/import_journal.dart': 'staged copy for a resumable import on this '
      'install',
};

/// Keys that ride in the backup file only as a signal: the restore reads them
/// (to tell the owner a secret needs re-entering) but never writes them back.
const Set<String> kPrefsSignalOnly = {'coach_api_key_present'};

/// Whether [key] belongs in a backup.
bool prefsKeyBackedUp(String key) {
  if (kPrefsNotBackedUp.containsKey(key)) return false;
  for (final p in kPrefsNotBackedUpPrefixes.keys) {
    if (key.startsWith(p)) return false;
  }
  return true;
}

/// What an export writes into the copy beyond the SQL tables.
enum BackupExtras {
  /// Nothing: telemetry uploads and support reports leave the phone and have
  /// no business carrying settings or recordings.
  none,

  /// Settings only. Automatic backups: the prefs are a few KB, while the
  /// recordings can be megabytes and five rotating copies are kept.
  prefsOnly,

  /// Settings and recordings: the manual (plain and encrypted) export.
  all,
}

/// Where the device-lab IMU recordings live, relative to the documents folder.
const String kBackupRecordingsDir = 'device_lab/imu';

final RegExp _safeRecordingName = RegExp(r'^[A-Za-z0-9_-]{1,80}\.jsonl$');

/// Coach chat sessions sit directly in the documents folder (CoachEngine).
/// The per-user key and the session id are a name and a millisecond stamp.
final RegExp _safeCoachName =
    RegExp(r'^coach_(s|idx)_[A-Za-z0-9_-]{1,120}\.json$');

Future<Directory> _recordingsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory(p.joinAll([docs.path, ...kBackupRecordingsDir.split('/')]));
}

/// Adds [kBackupPrefsTable] (and, for [BackupExtras.all], [kBackupFilesTable])
/// to the exported copy at [copyPath]. Never touches the live database.
Future<void> writeBackupExtras(
  String copyPath, {
  SharedPreferences? prefs,
  BackupExtras extras = BackupExtras.all,
}) async {
  if (extras == BackupExtras.none) return;
  final SharedPreferences sp;
  try {
    sp = prefs ?? await SharedPreferences.getInstance();
    if (prefs == null) await sp.reload();
  } on Object {
    // No preference store on this platform (a bare test host): nothing to
    // carry, and the export itself is still whole.
    return;
  }
  final copy = await openDatabase(copyPath, singleInstance: false);
  try {
    await copy.execute('CREATE TABLE IF NOT EXISTS backup_prefs '
        '(key TEXT PRIMARY KEY, type TEXT, value TEXT)');
    await copy.execute('CREATE TABLE IF NOT EXISTS backup_secrets (key TEXT PRIMARY KEY)');
    await copy.transaction((txn) async {
      await txn.delete('backup_secrets');
      for (final key in ['coach_api_key', 'coach_chatgpt']) {
        if (sp.get('${key}_present') == true) {
          await txn.insert('backup_secrets', {'key': key});
        }
      }
      final server = sp.get('coach_base_url');
      if (server is String && server.isNotEmpty && server != CoachConfig.defaultBaseUrl) {
        await txn.insert('backup_secrets', {'key': 'coach_base_url'});
      }
      for (final key in sp.getKeys()) {
        if (!prefsKeyBackedUp(key) && !kPrefsSignalOnly.contains(key)) continue;
        var value = sp.get(key);
        if (key == NotificationPrefs.storageKey && value is String) {
          try {
            final decoded = jsonDecode(value);
            if (decoded is Map && decoded['preferences'] is Map) {
              (decoded['preferences'] as Map).remove('criticalOverridesQuiet');
              value = jsonEncode(decoded);
            }
          } on FormatException { /* Preserve existing malformed-value policy. */ }
        }
        final row = _encodePref(value);
        if (row == null) continue;
        await txn.insert(
            'backup_prefs', {'key': key, 'type': row.$1, 'value': row.$2},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    if (extras == BackupExtras.all) {
      await copy.execute('CREATE TABLE IF NOT EXISTS backup_files '
          '(rel_path TEXT PRIMARY KEY, bytes BLOB)');
      final dir = await _recordingsDir();
      if (await dir.exists()) {
        await for (final e in dir.list(followLinks: false)) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (!_safeRecordingName.hasMatch(name)) continue; // e.g. *.part
          // One file per statement: never every recording in memory at once.
          await copy.insert('backup_files', {
            'rel_path': '$kBackupRecordingsDir/$name',
            'bytes': await e.readAsBytes(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      final docs = await getApplicationDocumentsDirectory();
      if (await docs.exists()) {
        await for (final e in docs.list(followLinks: false)) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (!_safeCoachName.hasMatch(name)) continue;
          await copy.insert('backup_files', {
            'rel_path': name,
            'bytes': await e.readAsBytes(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }
  } finally {
    await copy.close();
  }
}

(String, String)? _encodePref(Object? v) => switch (v) {
      bool b => ('bool', '$b'),
      int i => ('int', '$i'),
      double d => ('double', '$d'),
      String s => ('string', s),
      List l => ('stringList', jsonEncode(l.map((e) => '$e').toList())),
      _ => null,
    };

class BackupExtrasResult {
  const BackupExtrasResult({
    this.prefsRestored = 0,
    this.prefsKept = 0,
    this.filesRestored = 0,
    this.refusedPrefs = const [],
    this.unreadableSecrets = const [],
    this.keysWritten = const {},
    this.needsReentry = const [],
  });
  final int prefsRestored, prefsKept, filesRestored;
  final List<String> refusedPrefs;

  /// Secrets the backup's owner had set that this install does not hold, by
  /// the names in [kNeedsReentryCoachKey]: the restore cannot bring them back.
  final List<String> needsReentry;
  final List<String> unreadableSecrets;

  /// The pref keys this restore wrote, for the live settings reload.
  final Set<String> keysWritten;
}

Future<bool> _hasTable(Database db, String name) async => (await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [name]))
    .isNotEmpty;

// Reads both export carriers. Old fork exports used one signal-only pref;
// reviewed main exports use backup_secrets. Neither marker is a credential.
Future<({List<String> needs, List<String> unreadable})> _secretReentry(Database src) async {
  final present = <String>{};
  if (await _hasTable(src, 'backup_secrets')) {
    present.addAll((await src.query('backup_secrets')).map((r) => '${r['key']}'));
  }
  if (await _hasTable(src, kBackupPrefsTable)) {
    final marker = await src.query(kBackupPrefsTable, columns: ['value'],
        where: 'key = ?', whereArgs: ['coach_api_key_present']);
    if (marker.any((r) => r['value'] == 'true')) present.add('coach_api_key');
  }
  final needs = <String>[], unreadable = <String>[];
  if (present.contains('coach_api_key')) {
    try {
      final key = await const FlutterSecureStorage().read(key: 'coach_api_key')
          .timeout(const Duration(seconds: 6));
      if (key == null || key.isEmpty) needs.add('coach_api_key');
    } catch (_) { unreadable.add('coach_api_key'); }
  }
  if (present.contains('coach_base_url') || present.contains('coach_chatgpt')) {
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    if (present.contains('coach_base_url') && _needsServerReentry(sp.getString('coach_base_url'))) {
      needs.add('coach_base_url');
    }
    if (present.contains('coach_chatgpt') && sp.get('coach_chatgpt_present') != true) {
      needs.add('coach_chatgpt');
    }
  }
  return (needs: needs, unreadable: unreadable);
}

/// Restores prefs and files from the backup at [srcPath].
///
/// Prefs: [freshInstall] writes every backed-up key; otherwise only keys this
/// install lacks. A key on the device-only list is never written, whatever an
/// old or foreign file carries. Files: only those absent here, and only a
/// name that stays inside the recordings folder.
Future<BackupExtrasResult> restoreBackupExtras(
  String srcPath, {
  required bool freshInstall,
}) async {
  final src = await openDatabase(srcPath, readOnly: true, singleInstance: false);
  try {
    var restored = 0, kept = 0, files = 0;
    final written = <String>{};
    final refused = <String>[];
    if (await _hasTable(src, kBackupPrefsTable)) {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      for (final r in await src.query(kBackupPrefsTable)) {
        final key = '${r['key']}';
        if (!prefsKeyBackedUp(key)) continue;
        if (!freshInstall && sp.containsKey(key)) {
          kept++;
          continue;
        }
        try {
          final want = expectedPrefType(key);
          if (want != null && r['type'] != want) { refused.add(key); continue; }
          if (!await _write(sp, key, '${r['type']}', '${r['value']}')) {
            throw StateError('Could not restore preference $key');
          }
          restored++;
          written.add(key);
        } on FormatException {
          refused.add(key);
        }
      }
    }
    if (await _hasTable(src, kBackupFilesTable)) {
      final dir = await _recordingsDir();
      final docs = await getApplicationDocumentsDirectory();
      final prefix = '$kBackupRecordingsDir/';
      for (final r in await src.query(kBackupFilesTable,
          columns: ['rel_path'])) {
        final rel = '${r['rel_path']}';
        final Directory home;
        final String name;
        if (rel.startsWith(prefix)) {
          home = dir;
          name = rel.substring(prefix.length);
          if (!_safeRecordingName.hasMatch(name)) continue; // escapes, odd names
        } else if (_safeCoachName.hasMatch(rel)) {
          home = docs;
          name = rel;
        } else {
          continue;
        }
        final target = File(p.join(home.path, name));
        if (!p.isWithin(home.path, target.path) || await target.exists()) {
          continue;
        }
        final row = await src.query(kBackupFilesTable,
            columns: ['bytes'], where: 'rel_path = ?', whereArgs: [rel]);
        final bytes = row.isEmpty ? null : row.first['bytes'];
        if (bytes is! List<int>) continue;
        await home.create(recursive: true);
        // Whole or not at all, like the store's own save.
        final part = File('${target.path}.part');
        try {
          await part.writeAsBytes(bytes, flush: true);
          await part.rename(target.path);
          files++;
        } catch (_) {
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {}
        }
      }
    }
    final secrets = await _secretReentry(src);
    return BackupExtrasResult(
        refusedPrefs: refused,
        prefsRestored: restored,
        prefsKept: kept,
        filesRestored: files,
        keysWritten: written,
        needsReentry: secrets.needs, unreadableSecrets: secrets.unreadable);
  } finally {
    await src.close();
  }
}

/// Startup defaults alone do not establish an install; setup and user history do.
Future<bool> isFreshInstall() async =>
    LocalDb.backupPrefsFreshInstall();

/// What the last import did, for the screen that follows it.
class ImportSummary with MapMixin<String, int> {
  final Map<String, int> tables;
  const ImportSummary({
    this.tables = const {},
    this.keysWritten = const {},
    this.unreadableSecrets = const [],
    this.refusedPrefs = const [],
    this.daysWithRaw = 0,
    this.daysDerived = 0,
    this.archiveBucketsSkipped = 0,
    this.sourceDaysAboveCeiling = 0,
    this.prefsRestored = 0,
    this.prefsKept = 0,
    this.filesRestored = 0,
    this.interruptedAndResumed = 0,
    this.needsReentry = const [],
  });

  @override
  int? operator [](Object? key) => tables[key];
  @override
  void operator []=(String key, int value) => throw UnsupportedError('import summary is read-only');
  @override
  Iterable<String> get keys => tables.keys;
  @override
  int? remove(Object? key) => throw UnsupportedError('import summary is read-only');
  @override
  void clear() => throw UnsupportedError('import summary is read-only');

  /// Secrets the owner must enter again ([kNeedsReentryCoachKey]); empty when
  /// nothing was lost. Band pairing keys are not listed: the paired band is
  /// not carried either, so the pairing flow asks for them anyway.
  final List<String> needsReentry;

  /// Days with raw (decoded) data in the source.
  final int daysWithRaw;

  /// Days with a derived result this build serves in this database now. Read
  /// live, so it climbs while the post-import derive runs.
  final int daysDerived;

  /// substrate_archive buckets skipped for an unknown codec.
  final int archiveBucketsSkipped;

  /// Distinct source days whose every day_result is above this build's
  /// kAlgoVersion.
  final int sourceDaysAboveCeiling;
  final int prefsRestored, prefsKept, filesRestored;

  /// Times this import was interrupted and resumed (D38).
  final int interruptedAndResumed;


  final Set<String> keysWritten;
  /// Read failed or timed out; absence is unknown. A later import retries it.
  final List<String> unreadableSecrets;
  /// Rows in the backup that could not be read; skipped, the rest restored.
  final List<String> refusedPrefs;
}

/// Kept in `compute_freshness`, not in the preferences: it is a record of this
/// install's last import, which is neither a setting nor part of a backup, and
/// a preference written by every import would make a repeated import change
/// the settings it is meant to leave alone. The name stays on the device-only
/// list in case an older build wrote it as a preference.
const String kImportSummaryKey = 'import_summary_v1';

/// Counts from the source file that the summary keeps. Local days, as the
/// data-history screen groups them.
Future<(int, int)> _sourceFacts(String srcPath) async {
  final src = await openDatabase(srcPath, readOnly: true, singleInstance: false);
  try {
    var raw = 0, above = 0;
    if (await _hasTable(src, 'decoded_onehz')) {
      raw = Sqflite.firstIntValue(await src.rawQuery(
              'SELECT COUNT(*) FROM (SELECT 1 FROM decoded_onehz '
              "WHERE rec_ts > 0 GROUP BY strftime('%Y-%m-%d', rec_ts, "
              "'unixepoch', 'localtime'))")) ??
          0;
    }
    if (await _hasTable(src, 'day_result')) {
      above = Sqflite.firstIntValue(await src.rawQuery(
              'SELECT COUNT(*) FROM (SELECT day_id FROM day_result '
              'GROUP BY day_id HAVING MIN(algo_version) > ?)',
              [kAlgoVersion])) ??
          0;
    }
    return (raw, above);
  } finally {
    await src.close();
  }
}

/// Persists the summary of the import just finished. The items to enter again
/// are saved FIRST, before the journal is marked done, and a save that fails
/// throws: the import then stays unfinished and the next start retries, rather
/// than a warning being lost. The summary row itself is best effort: a failure
/// there drops the previous summary and never fails the import.
Future<void> recordImportSummary(
  String srcPath, {
  required int archiveBucketsSkipped,
  required BackupExtrasResult extras,
  int interruptedAndResumed = 0,
  required String runId,
}) async {
  // Before the journal is marked done, through the one owner. A refused write
  // throws: the import stays unfinished and the next start retries.
  await ImportReentryStore.current.add(extras.needsReentry, runId: runId);
  try {
    final (raw, above) = await _sourceFacts(srcPath);
    await LocalDb.putComputeFreshness(
        kImportSummaryKey,
        // Fixed order, versioned: daysWithRaw, archiveBucketsSkipped,
        // sourceDaysAboveCeiling, prefsRestored, prefsKept, filesRestored,
        // interruptedAndResumed (absent in summaries written before D38),
        // needsReentry bitmask (bit 0 = coach key; absent before then).
        'v1:$raw,$archiveBucketsSkipped,$above,${extras.prefsRestored},'
        '${extras.prefsKept},${extras.filesRestored},$interruptedAndResumed,'
        '${extras.needsReentry.contains(kNeedsReentryCoachKey) ? 1 : 0}');
  } catch (_) {
    // The previous row describes an EARLIER import. Keeping it would hand its
    // re-entry warnings to this one, so an unknown summary is no summary.
    try {
      await LocalDb.deleteComputeFreshness(kImportSummaryKey);
    } catch (_) {}
  }
}

/// The summary of the last import on this install, or null.
Future<ImportSummary?> lastImportSummary() async {
  final db = await LocalDb.instance;
  final rows = await db.query('compute_freshness',
      columns: ['payload_json'],
      where: 'key = ?',
      whereArgs: [kImportSummaryKey]);
  if (rows.isEmpty) return null;
  try {
    final text = '${rows.first['payload_json']}';
    if (!text.startsWith('v1:')) return null;
    final v = [for (final x in text.substring(3).split(',')) int.parse(x)];
    if (v.length < 6 || v.length > 8) return null;
    int n(int i) => v[i];
    final derived = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(DISTINCT day_id) FROM day_result '
            'WHERE algo_version <= ?',
            [kAlgoVersion])) ??
        0;
    return ImportSummary(
      daysWithRaw: n(0),
      daysDerived: derived,
      archiveBucketsSkipped: n(1),
      sourceDaysAboveCeiling: n(2),
      prefsRestored: n(3),
      prefsKept: n(4),
      filesRestored: n(5),
      interruptedAndResumed: v.length > 6 ? n(6) : 0,
      needsReentry: [if (v.length > 7 && n(7) & 1 != 0) kNeedsReentryCoachKey],
    );
  } on FormatException {
    return null;
  }
}


/// The app root reloads presentation controllers after AppState adopts prefs.


/// The stored type of each backed-up key the app reads with a typed getter.
/// A row of another type is refused, not written: the getter throws on a cast
/// mismatch (int vs double included), on every launch after the restore. A
/// backed-up key missing here is written as-is; the guard test keeps this
/// table complete. Keys in [kPrefsNotBackedUp] need no entry.
const Map<String, String> kPrefTypes = {
  'activity.nap_auto_log_since_sec': 'int',
  'ai.journal_done_day': 'string',
  'ai_evening_enabled': 'bool',
  'ai_evening_min': 'int',
  'ai_journal_enabled': 'bool',
  'ai_journal_min': 'int',
  'ai_morning_enabled': 'bool',
  'ai_morning_min': 'int',
  'backup.cadence': 'string',
  'band.strap_name': 'string',
  'clock_format': 'string',
  'coach_api': 'string',
  'coach_model': 'string',
  'coach_timeout_seconds': 'int',
  'coach_use_chatgpt': 'bool',
  'cycle_tracking_enabled': 'bool',
  'dev.mode': 'bool',
  'device_alerts.charge_shown_day': 'int',
  'device_alerts.last_charge_event_ts': 'int',
  'device_alerts.last_charge_wall_sec': 'int',
  'gesture_double_tap': 'string',
  'health_auto_import_last_ms': 'int',
  'health_auto_import_workouts': 'bool',
  'health_import_profile_at': 'int',
  'health_import_workouts_at': 'int',
  'health_sync': 'bool',
  'health_workout_import_deleted': 'stringList',
  'issue_reports_sent': 'string',
  'last_inactivity_ms': 'int',
  'last_recovery_notif_day': 'string',
  'last_staleness_notified_ms': 'int',
  'last_stepgoal_day': 'string',
  'local_profile_json': 'string',
  'locale_override': 'string',
  'notif_alarm_latch_failed': 'bool',
  'notif_alarm_night_check': 'bool',
  'notif_auto_detect': 'bool',
  'notif_battery_pct': 'int',
  'notif_checkin': 'bool',
  'notif_critical_override': 'bool', // Legacy import type.
  'notif_fallback_destination': 'string',
  'notif_device': 'bool',
  'notif_fired_keys': 'stringList',
  'notif_health': 'bool',
  'notif_meds': 'bool',
  'notif_movement': 'bool',
  'notif_nap_detect': 'bool',
  'notif_quiet_enabled': 'bool',
  'notif_quiet_end': 'int',
  'notif_quiet_start': 'int',
  'notif_recovery': 'bool',
  'notif_relay_enabled': 'bool',
  'notif_relay_packages': 'stringList',
  'notif_relay_seen': 'stringList',
  'notif_reminders': 'bool',
  'notif_stepgoal': 'bool',
  'notif_water': 'bool',
  'notif_water_interval': 'int',
  'notif_winddown': 'bool',
  'nutrition.barcode_lookup': 'bool',
  'onboard.completed': 'bool',
  'onboard.saw_profile_setup': 'bool',
  'onboard.skipped_pairing': 'bool',
  'onboarding_choice': 'string',
  'phone_steps': 'bool',
  'phone_steps_healthstore_purged': 'bool',
  'rough_night.ask': 'string',
  'rough_night.dismissed': 'string',
  'share.map_tiles': 'bool',
  'theme_choice': 'string',
  'ui.shell_tab': 'int',
  'ui.shell_tab.v2': 'int',
  'ui.wearable_show_estimates': 'bool',
  'ui.wearable_side_by_side': 'bool',
  'units_system': 'string',
  'update_checks_enabled': 'bool',
  'whoop_import_deleted_workouts': 'stringList',
  'workout.rpe_skips': 'int',
  'workout.zone_alert_enabled': 'bool',
  'workout.zone_alert_target_zone': 'int',
  'calc_power_mode': 'string',
  'demo.mode_enabled': 'bool',
  'ecg_keep_waveform': 'bool',
  'expected_sleep_schedule_v1': 'string',
  'gesture_failures': 'string',
  HapticPatternStore.prefsKey: 'string',
  'haptics_editor_mode': 'string',
  'haptics_gesture_cue_assign': 'string',
  NotificationPrefs.storageKey: 'string',
  SettingsRepository.channelsKey: 'string',
  'notif_relay_only_worn': 'bool',
  'resolved_window_days': 'int',
  'ui.device_lab_tab': 'string',
  'ui.explore_intraday': 'string',
  'ui.explore_metrics': 'string',
  'ui.explore_range': 'string',
  'ui.explore_scale': 'string',
  'ui.explore_z': 'string',
  'ui.gestures_tab': 'string',
  'ui.haptics_tab': 'string',
  'ui.load_memory.v1': 'string',
  'wake_acked_epoch': 'int',
  'workout.stop_pending': 'string',
  'alerts.zone_pref_migrated': 'bool',
  'gesture_double_tap_actions': 'int',
  'gesture_follow_up_moments': 'bool',
  'gesture_follow_up_moments_since_ms': 'int',
  'gesture_repeat_lab': 'bool',
  'gesture_repeat_window_ms': 'int',
  'gesture_time_buzz_mode': 'string',
  'moment_review.queue': 'string',
  'typical_large_meals_v1': 'string',
  'ui.home_ring_details.v1': 'string',
};

/// Dated or per-item key families: (prefix, suffix, stored type).
const List<(String, String, String)> kPrefTypeFamilies = [
  ('ff.', '', 'bool'),
  ('accordion_', '', 'bool'),
  ('gesture_replay_', '', 'bool'),
  ('gesture_slot_options_', '', 'string'),
  ('gesture_tap_actions_', '', 'int'),
  ('ai.briefing.', '', 'string'),
  ('ecg.guard.', '', 'bool'),
  ('ecg.wrist.', '', 'string'),
  ('ecg.maverick.', '', 'bool'),
  ('notif_fired:', '', 'bool'),
  ('notif_osid:', '', 'int'),
  ('notif_osslot:', '', 'string'),
  ('notif_osnext:', '', 'int'),
  ('nudge.', '.dismissed', 'bool'),
  ('nudge.', '.last_shown_ms', 'int'),
  // Per-scale weighing export state. Travels: the Health store usually
  // survives a restore, and re-sending every weighing would stack duplicates.
  ('health_weight_exported:', '', 'string'),
  ('health_weight_attempts:', '', 'string'),
  ('health_weight_maybe_landed:', '', 'string'),
  ('health_weight_trimmed:', '', 'string'),
];

/// The stored type the app reads [key] with, or null when it is not known.
String? expectedPrefType(String key) {
  final exact = kPrefTypes[key];
  if (exact != null) return exact;
  for (final (prefix, suffix, type) in kPrefTypeFamilies) {
    if (key.startsWith(prefix) && key.endsWith(suffix)) return type;
  }
  return null;
}

Future<void> writeBackupPrefs(String path) =>
    writeBackupExtras(path, extras: BackupExtras.prefsOnly);

Future<bool> _write(SharedPreferences prefs, String key,
    String type, String value) async {
  if (key == 'notif_fallback_destination' &&
      (type != 'string' || !const {'phone', 'band'}.contains(value))) {
    throw const FormatException('invalid fallback destination');
  }
  switch (type) {
    case 'bool':
      if (value != 'true' && value != 'false') {
        throw const FormatException('invalid preference boolean');
      }
      return prefs.setBool(key, value == 'true');
    case 'int':
      return prefs.setInt(key, int.parse(value));
    case 'double':
      final d = double.parse(value);
      if (!d.isFinite) throw const FormatException('invalid preference number');
      return prefs.setDouble(key, d);
    case 'string':
      return prefs.setString(key, value);
    case 'stringList':
      final list = jsonDecode(value);
      if (list is! List || list.any((v) => v is! String)) {
        throw const FormatException('invalid preference list');
      }
      return prefs.setStringList(key, list.cast<String>());
    default:
      throw FormatException('unknown preference type $type');
  }
}

/// This phone has no server of its own: unset, blank, or the default saved
/// explicitly. Either way the user would silently stay on the default.
bool _needsServerReentry(String? saved) {
  final v = saved?.trim() ?? '';
  return v.isEmpty || v == CoachConfig.defaultBaseUrl;
}

Future<ImportSummary> restoreBackupPrefs(String path, Map<String, int> counts, {
  required bool freshInstall,
}) async {
  final extras = await restoreBackupExtras(path, freshInstall: freshInstall);
  return ImportSummary(tables: counts, keysWritten: extras.keysWritten,
      needsReentry: extras.needsReentry, unreadableSecrets: extras.unreadableSecrets,
      refusedPrefs: extras.refusedPrefs, prefsRestored: extras.prefsRestored,
      prefsKept: extras.prefsKept, filesRestored: extras.filesRestored);
}
