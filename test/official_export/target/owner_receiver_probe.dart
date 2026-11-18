// Imports the owner-DB candidates through the UNCHANGED v0.12.2 receiver
// (`LocalDb.importFromDbFile`, plain-DB entry point) into a fresh target and
// records per-table counts, timings and integrity. A measurement, not a pass
// criterion on content: the naive candidate is EXPECTED to carry fork results.
// Copied into the tagged package as owner_receiver_test.dart by
// harness/run_owner_harness.sh. Env: OWNER_WORK, OFFICIAL_PROBE_OUT.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
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
  final report = <String, Object?>{};
  tearDownAll(() {
    final out = Directory(Platform.environment['OFFICIAL_PROBE_OUT'] ?? 'build/official_probe')
      ..createSync(recursive: true);
    File('${out.path}/owner-receiver.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  });

  for (final name in ['naive', 'policy']) {
    test('import the $name candidate into a fresh v0.12.2 target', () async {
      final work = Platform.environment['OWNER_WORK']!;
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('owner_receiver_');
      PathProviderPlatform.instance = _Paths(root.path);
      LocalDb.dbName = '${root.path}/official.db';
      final r = <String, Object?>{};
      try {
        final sw = Stopwatch()..start();
        final db = await LocalDb.instance;
        r['t_fresh_open_ms'] = sw.elapsedMilliseconds;
        sw.reset();
        final summary = await LocalDb.importFromDbFile('$work/$name.db');
        r['t_import_ms'] = sw.elapsedMilliseconds;
        r['summary'] = {for (final e in summary.entries) e.key: e.value};
        r['schema'] = await db.getVersion();
        r['rebuild'] = LocalDb.lastRebuild?.toString();
        r['integrity'] = (await db.rawQuery('PRAGMA integrity_check')).single.values.single;
        r['cursor'] = await LocalDb.getCursorInt(LocalDb.kDecodedPrunedBeforeCursor);
        final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name");
        final counts = <String, int>{};
        for (final t in tables) {
          final n = t['name'] as String;
          counts[n] = Sqflite.firstIntValue(await db.rawQuery('SELECT count(*) FROM "$n"')) ?? 0;
        }
        r['row_counts'] = counts;
        r['db_bytes'] = File('${root.path}/official.db').lengthSync();
        expect(r['integrity'], 'ok');
        expect(LocalDb.lastRebuild, isNull);
      } finally {
        report[name] = r;
        await LocalDb.close();
        await root.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 40)));
  }
}
