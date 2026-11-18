// Schema probe, run in BOTH packages: the fork (repaired schema 92+) and the
// unchanged tagged v0.12.2 source (schema 62). It is not named `_test.dart`, so
// the fork's suite never picks it up; `harness/*.sh` copies it into place.
//
// WHY: the profile (assets/official_export/v0.12.2.json) must describe what the
// code actually creates AFTER its on-open repair, not what a CREATE literal in a
// source file says. A fresh create and a reopen are both captured because the
// open repair adds tables, columns and indexes that the creators do not.
// CLAIM(official-export-actual-receiver).
//
// Env: OFFICIAL_PROBE_OUT = output directory (default build/official_probe),
//      OFFICIAL_PROBE_SOURCE_DB = optional path to a DISPOSABLE db copy to open
//      and upgrade instead of creating a fresh one (the owner-DB harness).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ProbePaths extends PathProviderPlatform {
  _ProbePaths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Future<Map<String, Object?>> _catalog(Database db) async {
  final objects = await db.rawQuery(
    "SELECT type,name,tbl_name,sql FROM sqlite_master "
    "WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY type,name",
  );
  final tables = <String, Object?>{};
  for (final row in objects.where((r) => r['type'] == 'table')) {
    final name = row['name'] as String;
    tables[name] = {
      // table_xinfo also reports hidden/generated columns that table_info hides.
      'columns': await db.rawQuery('PRAGMA table_xinfo("$name")'),
      'indexes': await db.rawQuery('PRAGMA index_list("$name")'),
      'foreign_keys': await db.rawQuery('PRAGMA foreign_key_list("$name")'),
    };
  }
  return {
    'user_version': Sqflite.firstIntValue(
      await db.rawQuery('PRAGMA user_version'),
    ),
    'objects': objects,
    'tables': tables,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('capture repaired runtime schema', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('official_schema_');
    PathProviderPlatform.instance = _ProbePaths(root.path);
    final out = Directory(
      Platform.environment['OFFICIAL_PROBE_OUT'] ?? 'build/official_probe',
    )..createSync(recursive: true);
    final disposable = Platform.environment['OFFICIAL_PROBE_SOURCE_DB'];
    LocalDb.dbName = disposable ?? '${root.path}/probe.db';
    try {
      // First open: creators (fresh) or the migration ladder (disposable copy).
      var db = await LocalDb.instance;
      final opened = await _catalog(db);
      await LocalDb.close();
      // Second open runs only the on-open repair over a settled file.
      db = await LocalDb.instance;
      final reopened = await _catalog(db);
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
      expect(LocalDb.lastRebuild, isNull);
      final label = disposable == null ? 'fresh' : 'upgraded';
      await File('${out.path}/schema-${LocalDb.schemaVersion}-$label.json')
          .writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'fork_head': Platform.environment['OFFICIAL_FORK_HEAD'],
              'fork_status_porcelain': Platform.environment['OFFICIAL_FORK_STATUS'],
              'schemaVersion': LocalDb.schemaVersion,
              'opened': opened,
              'reopened': reopened,
            }),
          );
    } finally {
      await LocalDb.close();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
