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
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../compute/derivation_engine.dart' show kAlgoVersion;
import 'db.dart' show LocalDb;

const String kBackupPrefsTable = 'backup_prefs';
const String kBackupFilesTable = 'backup_files';

/// Exact preference keys that stay on the device, each with the reason.
const Map<String, String> kPrefsNotBackedUp = {
  'install_device_id': 'identifies THIS install; a restore must not clone it',
  'paired_remote_id': 'BLE address of the band bonded to this phone',
  'consent_telemetry': 'consent is asked again on each install',
  'consent_health_data': 'consent is asked again on each install',
  'consent_chosen': 'says the consent question was answered; it is asked '
      'again on each install, so a restore must not mark it answered',
  'import_reentry_pending': 'secrets the last import could not restore and '
      'the user has not acknowledged; a fact about THIS install, so a restore '
      'must not carry it to another one',
  'coach_api_key_present': 'marks a key in this phone\'s keychain; the key '
      'is not carried (kSecretsNotBackedUp), so the marker would be false',
  'backup.folder': 'a storage-access URI/permission that is not valid elsewhere',
  'backup.last_run_ms': 'status of this install\'s auto-backup',
  'backup.last_error': 'status of this install\'s auto-backup',
  'alarm_probe_pending': 'transient: an in-flight alarm check on this phone',
  'ble.ask_add_pending': 'transient: a pairing prompt waiting on this phone',
  'health_upload_last_ts': 'telemetry upload cursor of this install',
  'settings_recovery_journal_v1': 'transient write-ahead journal',
  'import_summary_v1': 'record of the last import on this install',
  'import_run_v1': 'bookkeeping of the import running on this install',
};

/// Key prefixes that stay on the device, each with the reason. Empty on
/// purpose: a prefix once swept up `backup.cadence`, a setting the owner chose
/// (daily/weekly), so the device-only `backup.*` keys are listed by name above.
const Map<String, String> kPrefsNotBackedUpPrefixes = {};

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
    await copy.transaction((txn) async {
      for (final key in sp.getKeys()) {
        if (!prefsKeyBackedUp(key) && !kPrefsSignalOnly.contains(key)) continue;
        final row = _encodePref(sp.get(key));
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

Future<void> _writePref(
    SharedPreferences sp, String key, String type, String value) async {
  switch (type) {
    case 'bool':
      await sp.setBool(key, value == 'true');
    case 'int':
      await sp.setInt(key, int.parse(value));
    case 'double':
      await sp.setDouble(key, double.parse(value));
    case 'string':
      await sp.setString(key, value);
    case 'stringList':
      await sp.setStringList(
          key, [for (final e in jsonDecode(value) as List) '$e']);
    default:
      throw FormatException('unknown pref type $type');
  }
}

class BackupExtrasResult {
  const BackupExtrasResult({
    this.prefsRestored = 0,
    this.prefsKept = 0,
    this.filesRestored = 0,
    this.keysWritten = const {},
    this.needsReentry = const [],
  });
  final int prefsRestored, prefsKept, filesRestored;

  /// Secrets the backup's owner had set that this install does not hold, by
  /// the names in [kNeedsReentryCoachKey]: the restore cannot bring them back.
  final List<String> needsReentry;

  /// The pref keys this restore wrote, for the live settings reload.
  final Set<String> keysWritten;
}

Future<bool> _hasTable(Database db, String name) async => (await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [name]))
    .isNotEmpty;

/// True when the backup says a coach key was set and this install holds none.
/// An unreadable keystore counts as none: the owner is told, never left to
/// find a silent gap.
Future<bool> _coachKeyLost(Database src) async {
  final marker = await src.query(kBackupPrefsTable,
      columns: ['value'], where: 'key = ?', whereArgs: ['coach_api_key_present']);
  if (marker.isEmpty || '${marker.first['value']}' != 'true') return false;
  try {
    final have = await const FlutterSecureStorage().read(key: kNeedsReentryCoachKey);
    return have == null || have.isEmpty;
  } on Object {
    return true;
  }
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
          await _writePref(sp, key, '${r['type']}', '${r['value']}');
          restored++;
          written.add(key);
        } on FormatException {
          // One unreadable row loses that setting only.
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
    final reenter = <String>[];
    if (await _hasTable(src, kBackupPrefsTable) && await _coachKeyLost(src)) {
      reenter.add(kNeedsReentryCoachKey);
    }
    return BackupExtrasResult(
        prefsRestored: restored,
        prefsKept: kept,
        filesRestored: files,
        keysWritten: written,
        needsReentry: reenter);
  } finally {
    await src.close();
  }
}

/// True when this install holds no decoded rows and no day_result.
Future<bool> isFreshInstall() async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery(
      'SELECT EXISTS(SELECT 1 FROM decoded_onehz) AS a, '
      'EXISTS(SELECT 1 FROM day_result) AS b');
  return r.first['a'] == 0 && r.first['b'] == 0;
}

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
    this.interruptedAndResumed = 0,
    this.needsReentry = const [],
  });

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

/// Persists the summary of the import just finished. Best effort: a failure
/// here drops the previous summary and never fails the import.
Future<void> recordImportSummary(
  String srcPath, {
  required int archiveBucketsSkipped,
  required BackupExtrasResult extras,
  int interruptedAndResumed = 0,
}) async {
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
