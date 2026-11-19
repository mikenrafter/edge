// why: removing the ECG counter must also remove its schema and transfer paths.
// Existing pilot rows stay untouched; the owner repairs that database by hand.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'retired_ecg_gestures_guard.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(LocalDb.close);

  test('fresh schema and transfer policies omit the retired gesture data', () async {
    final db = await LocalDb.instance;
    expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name = 'ecg_gesture_session'"), isEmpty);
    final columns = await db.rawQuery('PRAGMA table_info(ecg_raw_packet)');
    expect(columns.map((c) => c['name']), isNot(contains('origin')));
    expect(LocalDb.restoredTableNames, isNot(contains('ecg_gesture_session')));
    expect(kSliceTables, isNot(contains('ecg_gesture_session')));
    expect(officialProfile.tables, isNot(contains('ecg_gesture_session')));
  });

  // A whole-library ban is a backstop for an accidental new runtime reader.
  // Positive control: the scanner must detect the original table spelling.
  test('runtime code contains no ECG counter or retired table access', () {
    final forbidden = RegExp(r'ecg_gesture_session|ecg_tap_counter|ecg_tap_session|ecgTouchTaps');
    expect(forbidden.hasMatch('ecg_gesture_session'), isTrue);
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.dart') && forbidden.hasMatch(file.readAsStringSync())) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
