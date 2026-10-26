import 'dart:io';

import 'package:openstrap_edge/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Directory> openWakeDb() async {
  await LocalDb.close();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await Directory.systemTemp.createTemp('wake_red_');
  LocalDb.dbName = '${dir.path}/edge.db';
  LocalDb.lastRebuild = null;
  await LocalDb.instance;
  return dir;
}

Future<void> closeWakeDb(Directory dir) async {
  await LocalDb.close();
  await dir.delete(recursive: true);
  LocalDb.dbName = 'openstrap.db';
}
