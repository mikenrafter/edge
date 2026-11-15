// WHY: freeze runtime schemas after creators AND on-open repairs, rather than
// trusting stale CREATE literals. Proves CLAIM(export-real-target).
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ProbePaths extends PathProviderPlatform {
  ProbePaths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('capture repaired runtime schema', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('official_schema_');
    PathProviderPlatform.instance = ProbePaths(root.path);
    LocalDb.dbName = '${root.path}/probe.db';
    var db = await LocalDb.instance;
    await LocalDb.close();
    db = await LocalDb.instance;
    final schema = await db.rawQuery(
      "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type,name",
    );
    final tables = <String, Object?>{};
    for (final row in schema.where((r) => r['type'] == 'table')) {
      final name = row['name'] as String;
      tables[name] = await db.rawQuery('PRAGMA table_info("$name")');
    }
    await Directory('build/official_probe').create(recursive: true);
    await File('build/official_probe/schema.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': LocalDb.schemaVersion,
        'objects': schema,
        'tables': tables,
      }),
    );
    expect(
      (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
      'ok',
    );
    await LocalDb.close();
    await root.delete(recursive: true);
  });
}
