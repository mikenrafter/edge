// CLAIM(official-export-accounted-identities), CLAIM(official-export-unit-keys),
// CLAIM(official-export-no-fork-results): drive the file builder, not a test copy.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/payload_requirements.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
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
          outputPath: path, factory: databaseFactoryFfi);
      expect(File(path).existsSync(), isTrue, reason: 'must publish a real file');
      final inventory = await fx.inventoryOf(path);
      expect(checkPayload(inventory, officialProfile,
          target: loadCapture('target_schema_62.json'),
          expectedPrunedBefore: fx.expectedPrunedBefore), isEmpty);
      expect(report.cursor.sec, fx.expectedPrunedBefore);
      expect(report.tables.keys, contains('decoded_onehz'));
      await verifyConservation(fx.forkPath,report);
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
