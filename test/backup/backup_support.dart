// Shared setup for the full-export tests: a throwaway live DB, fake
// path_provider dirs, and helpers to read what an export carries.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.tmp, this.docs);
  final String tmp, docs;
  @override
  Future<String?> getTemporaryPath() async => tmp;
  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
  @override
  Future<String?> getApplicationSupportPath() async => docs;
  @override
  Future<String?> getApplicationCachePath() async => tmp;
}

class BackupEnv {
  BackupEnv._(this.root, this.dbDir);
  final Directory root;
  final String dbDir;

  Directory get docs => Directory(p.join(root.path, 'docs'));
  Directory get imuDir =>
      Directory(p.join(docs.path, 'device_lab', 'imu'));

  static Future<BackupEnv> create(String dbName) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final root = await Directory.systemTemp.createTemp('openstrap_bkx_');
    await Directory(p.join(root.path, 'tmp')).create();
    await Directory(p.join(root.path, 'docs')).create();
    PathProviderPlatform.instance =
        _FakePaths(p.join(root.path, 'tmp'), p.join(root.path, 'docs'));
    LocalDb.dbName = dbName;
    final env = BackupEnv._(root, await databaseFactory.getDatabasesPath());
    await env.wipe();
    return env;
  }

  /// A brand-new install: empty DB, empty prefs, no recordings.
  Future<void> wipe() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
    SharedPreferences.setMockInitialValues({});
    if (await imuDir.exists()) await imuDir.delete(recursive: true);
  }

  Future<void> dispose() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
    if (await root.exists()) await root.delete(recursive: true);
  }

  File imuFile(String name) => File(p.join(imuDir.path, name));

  Future<void> writeImu(String name, List<int> bytes) async {
    await imuDir.create(recursive: true);
    await imuFile(name).writeAsBytes(bytes);
  }

  /// One hour-ish of 1 Hz rows + a derived day, so the install is "not fresh".
  Future<void> seedData({int t0 = 1790000000}) async {
    final db = await LocalDb.instance;
    for (var i = 0; i < 30; i++) {
      await db.insert('decoded_onehz', {
        'device_id': '', 'ts_ms': (t0 + i) * 1000, 'rec_ts': t0 + i,
        'counter': i + 1, 'hr': 60,
      });
    }
    await db.insert('day_result', {
      'day_id': '2026-09-21', 'algo_version': 100, 'payload_json': '{}',
      'computed_at': 1, 'finalized': 1,
    });
  }
}

/// The tables of the database at [path].
Future<Set<String>> tablesOf(String path) async {
  final db = await databaseFactoryFfi.openDatabase(path, options:
      OpenDatabaseOptions(readOnly: true, singleInstance: false));
  try {
    return {
      for (final r in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'"))
        r['name'] as String,
    };
  } finally {
    await db.close();
  }
}

/// `backup_prefs` of an export as key -> (type, value); null when the table
/// does not exist.
Future<Map<String, (String, String)>?> exportedPrefs(String path) async {
  if (!(await tablesOf(path)).contains('backup_prefs')) return null;
  final db = await databaseFactoryFfi.openDatabase(path, options:
      OpenDatabaseOptions(readOnly: true, singleInstance: false));
  try {
    return {
      for (final r in await db.query('backup_prefs'))
        r['key'] as String: ('${r['type']}', '${r['value']}'),
    };
  } finally {
    await db.close();
  }
}

/// `backup_files` of an export as rel_path -> bytes; null when absent.
Future<Map<String, List<int>>?> exportedFiles(String path) async {
  if (!(await tablesOf(path)).contains('backup_files')) return null;
  final db = await databaseFactoryFfi.openDatabase(path, options:
      OpenDatabaseOptions(readOnly: true, singleInstance: false));
  try {
    return {
      for (final r in await db.query('backup_files'))
        r['rel_path'] as String: (r['bytes'] as List<int>),
    };
  } finally {
    await db.close();
  }
}

/// Every pref as a plain map (keys sorted).
Future<Map<String, Object>> allPrefs() async {
  final sp = await SharedPreferences.getInstance();
  await sp.reload();
  return {for (final k in sp.getKeys().toList()..sort()) k: sp.get(k)!};
}

/// Sets [values] as this install's prefs.
Future<void> setPrefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  await SharedPreferences.getInstance().then((sp) => sp.reload());
}

void expectNoSecretIn(String path, Iterable<String> secrets) {
  final bytes = File(path).readAsBytesSync();
  final text = String.fromCharCodes(bytes);
  for (final s in secrets) {
    expect(text.contains(s), isFalse, reason: 'secret "$s" leaked into export');
  }
}
