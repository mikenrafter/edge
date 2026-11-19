// CLAIM(official-export-accounted-identities), CLAIM(official-export-unit-keys),
// CLAIM(official-export-no-fork-results): drive the file builder, not a test copy.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/payload_requirements.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'rich_fixture.dart';
import 'support.dart';
import 'conservation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('mapper produces a verified file without fork results or checkpoints', () async {
    final fx = await RichFixture.build();
    try {
      final path = '${File(fx.forkPath).parent.path}/mapped.db';
      final report = await mapOfficialSnapshot(snapshotPath: fx.forkPath,
          outputPath: path, factory: databaseFactoryFfi,
          calendar: const FixedOffsetCalendar(0)); // the fixture's literals are UTC epochs
      expect(File(path).existsSync(), isTrue, reason: 'must publish a real file');
      final inventory = await fx.inventoryOf(path);
      expect(checkPayload(inventory, officialProfile,
          target: loadCapture('target_schema_62.json'),
          expectedPrunedBefore: fx.expectedPrunedBefore), isEmpty);
      expect(report.cursor.sec, fx.expectedPrunedBefore);
      expect(report.tables.keys, contains('decoded_onehz'));
      await verifyConservation(fx.forkPath,report,literalOmitted:richFixtureLiteralOmissions);
      final db = await databaseFactoryFfi.openDatabase(path);
      try {
        final def = (await db.query('journal_field_def', where: "unit='g'")).single;
        // Literal UTF-8 hex fixtures, independently transcribed from ASCII.
        expect(def['key'], 'custom_u1_637573746f6d5f6361666665696e65_67');
        expect((await db.query('journal_metric', where: 'field=?', whereArgs: [def['key']])).single['value'], 0.2);
        expect((await db.query('device', where: "id=''")).single['wearing'], 2);
        expect((await db.query('device', where: "id=''")).single['remote_id'], isNull);
        expect((await db.query('compute_freshness',where:"key='substrate_archive_policy'")).single['payload_json'],
          '{"keepDays":null}',reason:'archive policy bytes transfer verbatim');
      } finally { await db.close(); }
    } finally { await fx.dispose(); }
  }, timeout: const Timeout(Duration(minutes: 8)));

  // WHY: a retired nullable provenance column must not withhold surviving ECG
  // bytes, and legacy-only records must be counted. CLAIM(official-export-accounted-identities).
  for(final legacy in [true,false]) {
    test('retired ECG objects export safely with legacy layout $legacy',()async {
      final fx=await RichFixture.build();
      try {
        final db=await databaseFactoryFfi.openDatabase(fx.forkPath);
        late int packets;
        try {
          if(legacy) {
            await db.execute("UPDATE ecg_raw_packet SET origin='gesture'");
          } else {
            await db.execute('DROP TABLE ecg_gesture_session');
            await db.execute('ALTER TABLE ecg_raw_packet DROP COLUMN origin');
          }
          packets=Sqflite.firstIntValue(await db.rawQuery('SELECT count(*) FROM ecg_raw_packet'))!;
        }finally{await db.close();}
        expect(packets,greaterThan(0));
        final path='${File(fx.forkPath).parent.path}/retired.db';
        final report=await mapOfficialSnapshot(snapshotPath:fx.forkPath,outputPath:path,
          factory:databaseFactoryFfi,calendar:const FixedOffsetCalendar(0));
        final out=await databaseFactoryFfi.openDatabase(path);
        try {
          expect(Sqflite.firstIntValue(await out.rawQuery('SELECT count(*) FROM ecg_raw_packet')),packets);
          expect(await out.rawQuery("SELECT name FROM sqlite_master WHERE name='ecg_gesture_session'"),isEmpty);
          expect((await out.rawQuery('PRAGMA table_info(ecg_raw_packet)')).map((r)=>r['name']),isNot(contains('origin')));
        }finally{await out.close();}
        if(legacy) {
          expect((report.tables['ecg_gesture_session'] as Map)['omitted_all'],isTrue);
          expect((report.tables['ecg_gesture_session'] as Map)['source_count'],greaterThan(0));
          expect(((report.tables['ecg_raw_packet'] as Map)['rowid_ranges'] as Map).keys,contains('mapped; columns=origin'));
        }else {
          expect(report.tables, isNot(contains('ecg_gesture_session')));
          expect(((report.tables['ecg_raw_packet'] as Map)['rowid_ranges'] as Map).keys,contains('mapped; columns='));
        }
      }finally{await fx.dispose();}
    });
  }

  // WHY: the retired column is an omitted schema object even with zero values;
  // an empty legacy database still needs an explicit omission ledger.
  test('empty retired ECG objects remain named in the omission ledger',()async {
    final fx=await RichFixture.build();
    try {
      final db=await databaseFactoryFfi.openDatabase(fx.forkPath);
      try {
        await db.delete('ecg_gesture_session');await db.delete('ecg_raw_packet');
      }finally{await db.close();}
      final path='${File(fx.forkPath).parent.path}/empty-retired.db';
      final report=await mapOfficialSnapshot(snapshotPath:fx.forkPath,outputPath:path,
        factory:databaseFactoryFfi,calendar:const FixedOffsetCalendar(0));
      final table=report.tables['ecg_gesture_session'] as Map;
      expect(table['source_count'],0);expect(table['omitted_all'],isTrue);
      final packet=report.tables['ecg_raw_packet'] as Map;
      expect(packet['source_count'],0);
      expect(packet['omitted_columns'],['origin']);
    }finally{await fx.dispose();}
  });

  test('oldest mapped exact input uses positive rec_ts across both tables', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    try {
      for (final table in ['decoded_onehz', 'decoded_rr']) {
        await db.execute('CREATE TABLE $table(rec_ts INTEGER,ts_ms INTEGER)');
      }
      await db.execute('INSERT INTO decoded_onehz VALUES(NULL,1),(0,2),(-1,3),(200,0)');
      await db.execute('INSERT INTO decoded_rr VALUES(100,99999999999)');
      expect(await oldestMappedExactSec(db), 100);
    } finally { await db.close(); }
  });
}
