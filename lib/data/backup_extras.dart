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
//  * Secrets in FlutterSecureStorage never enter the backup.
import 'dart:convert';
import 'dart:io';

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
        if (!prefsKeyBackedUp(key)) continue;
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
  });
  final int prefsRestored, prefsKept, filesRestored;

  /// The pref keys this restore wrote, for the live settings reload.
  final Set<String> keysWritten;
}

Future<bool> _hasTable(Database db, String name) async => (await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [name]))
    .isNotEmpty;

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
      for (final r in await src.query(kBackupFilesTable,
          columns: ['rel_path'])) {
        final rel = '${r['rel_path']}';
        final prefix = '$kBackupRecordingsDir/';
        if (!rel.startsWith(prefix)) continue;
        final name = rel.substring(prefix.length);
        if (!_safeRecordingName.hasMatch(name)) continue; // escapes, odd names
        final target = File(p.join(dir.path, name));
        if (!p.isWithin(dir.path, target.path) || await target.exists()) {
          continue;
        }
        final row = await src.query(kBackupFilesTable,
            columns: ['bytes'], where: 'rel_path = ?', whereArgs: [rel]);
        final bytes = row.isEmpty ? null : row.first['bytes'];
        if (bytes is! List<int>) continue;
        await dir.create(recursive: true);
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
    return BackupExtrasResult(
        prefsRestored: restored,
        prefsKept: kept,
        filesRestored: files,
        keysWritten: written);
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
  });

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

  /// Times this import was interrupted and resumed (D38). Stub: always 0.
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
/// here leaves the previous summary and never fails the import.
Future<void> recordImportSummary(
  String srcPath, {
  required int archiveBucketsSkipped,
  required BackupExtrasResult extras,
}) async {
  try {
    final (raw, above) = await _sourceFacts(srcPath);
    await LocalDb.putComputeFreshness(
        kImportSummaryKey,
        // Fixed order, versioned: daysWithRaw, archiveBucketsSkipped,
        // sourceDaysAboveCeiling, prefsRestored, prefsKept, filesRestored.
        'v1:$raw,$archiveBucketsSkipped,$above,${extras.prefsRestored},'
        '${extras.prefsKept},${extras.filesRestored}');
  } catch (_) {}
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
    if (v.length != 6) return null;
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
    );
  } on FormatException {
    return null;
  }
}
