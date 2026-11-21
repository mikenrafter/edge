// WHY: emulator 2026-11-20, the failing step of "Export for the official app".
// Android's SQLiteDatabase adds `android_metadata` (one locale row) to every
// database it opens, including the private target file. The final payload
// check counted that row as fork data in a dropped table and refused the file
// after the whole mapping: "unverified payload: [droppedTableHasRows:
// android_metadata]". Desktop SQLite never adds the table, so Boat runs passed.
// catches: refusing the platform's own locale table; letting a real dropped
// table's rows through with it.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/payload_requirements.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'rich_fixture.dart';
import 'support.dart';

/// Opens like Android: every writable open gains android_metadata(locale).
class AndroidLikeFactory implements DatabaseFactory {
  @override Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async {
    final db = await databaseFactoryFfi.openDatabase(path, options: options);
    if (options?.readOnly != true) {
      await db.execute('CREATE TABLE IF NOT EXISTS android_metadata (locale TEXT)');
      if ((await db.rawQuery('SELECT 1 FROM android_metadata')).isEmpty) {
        await db.insert('android_metadata', {'locale': 'en_US'});
      }
    }
    return db;
  }
  @override Future<String> getDatabasesPath() => databaseFactoryFfi.getDatabasesPath();
  @override Future<void> setDatabasesPath(String path) => databaseFactoryFfi.setDatabasesPath(path);
  @override Future<void> deleteDatabase(String path) => databaseFactoryFfi.deleteDatabase(path);
  @override Future<bool> databaseExists(String path) => databaseFactoryFfi.databaseExists(path);
  @override Future<void> writeDatabaseBytes(String path, Uint8List bytes) => databaseFactoryFfi.writeDatabaseBytes(path, bytes);
  @override Future<Uint8List> readDatabaseBytes(String path) => databaseFactoryFfi.readDatabaseBytes(path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a target that Android gave its locale table still verifies and keeps only that row', () async {
    final fx = await RichFixture.build();
    try {
      final path = '${File(fx.forkPath).parent.path}/mapped.db';
      final report = await mapOfficialSnapshot(snapshotPath: fx.forkPath, outputPath: path,
          factory: AndroidLikeFactory(), calendar: const FixedOffsetCalendar(0));
      expect(report.targetCounts['android_metadata'], anyOf(isNull, 1));
      final inventory = await fx.inventoryOf(path);
      expect(checkPayload(inventory, officialProfile, target: loadCapture('target_schema_62.json'),
          expectedPrunedBefore: fx.expectedPrunedBefore), isEmpty);
    } finally { await fx.dispose(); }
  });
  test('another dropped table with rows is still refused', () async {
    final fx = await RichFixture.build();
    try {
      final path = '${File(fx.forkPath).parent.path}/mapped.db';
      await mapOfficialSnapshot(snapshotPath: fx.forkPath, outputPath: path,
          factory: databaseFactoryFfi, calendar: const FixedOffsetCalendar(0));
      final db = await databaseFactoryFfi.openDatabase(path);
      await db.execute('CREATE TABLE assumed_water (date TEXT)');
      await db.insert('assumed_water', {'date': '2026-11-20'});
      await db.close();
      final violations = checkPayload(await fx.inventoryOf(path), officialProfile,
          target: loadCapture('target_schema_62.json'), expectedPrunedBefore: fx.expectedPrunedBefore);
      expect(violations.map((v) => v.toString()), contains('droppedTableHasRows: assumed_water'));
    } finally { await fx.dispose(); }
  });
  // [review r1 F5] The exception is for the platform's own table only: its
  // single ordinary `locale TEXT` column and at most one row. Anything else
  // under that name is payload, whatever layout the scratch open reported.
  Future<List<String>> violationsAfter(RichFixture fx, Future<void> Function(Database db) tamper) async {
    final path = '${File(fx.forkPath).parent.path}/mapped.db';
    await mapOfficialSnapshot(snapshotPath: fx.forkPath, outputPath: path,
        factory: databaseFactoryFfi, calendar: const FixedOffsetCalendar(0));
    final db = await databaseFactoryFfi.openDatabase(path);
    await tamper(db);
    await db.close();
    return [for (final v in checkPayload(await fx.inventoryOf(path), officialProfile,
        target: loadCapture('target_schema_62.json'), expectedPrunedBefore: fx.expectedPrunedBefore)) v.toString()];
  }
  test('a second row in android_metadata is refused', () async {
    final fx = await RichFixture.build();
    try {
      final violations = await violationsAfter(fx, (db) async {
        await db.execute('CREATE TABLE android_metadata (locale TEXT)');
        await db.insert('android_metadata', {'locale': 'en_US'});
        await db.insert('android_metadata', {'locale': 'fr_FR'});
      });
      expect(violations.where((v) => v.contains('android_metadata')), isNotEmpty, reason: '$violations');
    } finally { await fx.dispose(); }
  });
  test('android_metadata with extra or differently typed columns is refused', () async {
    for (final ddl in [
      'CREATE TABLE android_metadata (locale TEXT, owner_note TEXT)',
      'CREATE TABLE android_metadata (locale INTEGER)',
      'CREATE TABLE android_metadata (note TEXT)',
      'CREATE TABLE android_metadata (locale TEXT NOT NULL)',
    ]) {
      final fx = await RichFixture.build();
      try {
        final violations = await violationsAfter(fx, (db) async {
          await db.execute(ddl);
          final column = ddl.contains('(note') ? 'note' : 'locale';
          await db.rawInsert('INSERT INTO android_metadata ($column) VALUES (?)', [ddl.contains('INTEGER') ? 1 : 'en_US']);
        });
        expect(violations.where((v) => v.contains('android_metadata')), isNotEmpty, reason: '$ddl -> $violations');
      } finally { await fx.dispose(); }
    }
  });
  test('the platform shape with no row, or one, is accepted', () async {
    for (final rows in [0, 1]) {
      final fx = await RichFixture.build();
      try {
        final violations = await violationsAfter(fx, (db) async {
          await db.execute('CREATE TABLE android_metadata (locale TEXT)');
          for (var i = 0; i < rows; i++) {
            await db.insert('android_metadata', {'locale': 'en_US'});
          }
        });
        expect(violations, isEmpty, reason: '$rows rows: $violations');
      } finally { await fx.dispose(); }
    }
  });
}
