// A real (sqflite_ffi) LocalDb under a private file name, emptied before use.
// References only symbols that exist today.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

/// Point LocalDb at an empty database called [name]. Call in `setUp` inside
/// `tester.runAsync` for widget tests (sqflite_ffi completes on real time).
Future<void> g1FreshDb(String name) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
}

Future<void> g1DropDb(String name) async {
  await LocalDb.close();
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
}

/// Every row of `last_result`, oldest first. Throws when the table is missing,
/// which is the intended failure until the schema lands.
Future<List<Map<String, Object?>>> g1LastResultRows() async {
  final db = await LocalDb.instance;
  return db.rawQuery(
      'SELECT key, computed_at, payload_json FROM last_result '
      'ORDER BY computed_at ASC, key ASC');
}
