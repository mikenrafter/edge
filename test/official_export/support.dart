// Shared helpers for the official-export profile tests.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/prune_cursor.dart' show LocalCalendar;
import 'package:openstrap_edge/data/official_export/schema_catalog.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TempPaths extends PathProviderPlatform {
  TempPaths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Opens a brand-new fork database through its real creators and reopens it so
/// the on-open repair has run, then hands the catalog to [body].
Future<T> withFreshForkDb<T>(
  Future<T> Function(Database db, String path) body,
) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final root = await Directory.systemTemp.createTemp('official_fork_');
  PathProviderPlatform.instance = TempPaths(root.path);
  LocalDb.dbName = '${root.path}/fork.db';
  try {
    await LocalDb.instance;
    await LocalDb.close();
    final db = await LocalDb.instance;
    return await body(db, LocalDb.dbName);
  } finally {
    await LocalDb.close();
    await root.delete(recursive: true);
  }
}

/// A frozen probe capture committed under test/official_export/fixtures.
SchemaCatalog loadCapture(String name, {String key = 'reopened'}) {
  final json =
      jsonDecode(File('test/official_export/fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return SchemaCatalog.fromProbe((json[key] as Map).cast<String, Object?>());
}

/// A one-table catalog built from literal DDL, for shape controls.
Future<SchemaCatalog> catalogOf(List<String> ddl) async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  try {
    for (final s in ddl) {
      await db.execute(s);
    }
    return await SchemaCatalog.read(db);
  } finally {
    await db.close();
  }
}

/// The `objects` list of a frozen capture's reopened catalog.
List<Map<String, Object?>> readCaptureObjects(String name) {
  final json =
      jsonDecode(File('test/official_export/fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return ((json['reopened'] as Map)['objects'] as List)
      .map((e) => (e as Map).cast<String, Object?>())
      .toList();
}

/// A fixed-offset zone for tests: independent of the host process zone.
/// `FixedOffsetCalendar(0)` is UTC.
class FixedOffsetCalendar implements LocalCalendar {
  const FixedOffsetCalendar(this.offsetSec);
  final int offsetSec;
  @override
  int midnightAtOrAfter(int sec) => ((sec + offsetSec + 86399) ~/ 86400) * 86400 - offsetSec;
  @override
  String dayLabel(int sec) => _label(DateTime.fromMillisecondsSinceEpoch((sec + offsetSec) * 1000, isUtc: true));
  @override
  int? dayStartSec(String label) => _utcMidnight(label, 0);
  @override
  int? dayEndSec(String label) => _utcMidnight(label, 1);
  int? _utcMidnight(String label, int plusDays) {
    final p = label.split('-').map(int.tryParse).toList();
    if (p.length != 3 || p.contains(null)) { return null; }
    return DateTime.utc(p[0]!, p[1]!, p[2]! + plusDays).millisecondsSinceEpoch ~/ 1000 - offsetSec;
  }
  static String _label(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
