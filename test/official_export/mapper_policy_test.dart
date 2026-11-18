// WHY: CLAIM(official-export-unit-keys) keeps exact units, including arbitrary
// source spellings. CLAIM(official-export-accounted-identities) lists omissions.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/compute/step_calibration_fit.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/mapping_worker.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support.dart';
class FreeSpace implements ExportFreeSpace {
 FreeSpace(this.bytes);
 int bytes;
 @override
 Future<int> readAvailableBytes() async => bytes;
}
class FallingSpace extends FreeSpace {
 FallingSpace(this.output):super(1<<40);
 final String output;
 var calls=0,sawPrivateOutput=false;
 @override
 Future<int> readAvailableBytes() async {
  sawPrivateOutput|=File(output).existsSync();
  return ++calls>=5 ? 64:bytes;
 }
}
void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 test('calibration mapping accepts the certified live counter', () {expect(kLiveStepCounterVersion,2);});
 test('unit keys preserve exact bytes, builtins and empty units', () {
   expect(qualifiedCustomKey('custom_é','μg'),'custom_u1_637573746f6d5fc3a9_cebc67');
   expect(qualifiedCustomKey('custom_x',''),'custom_x');
   expect(qualifiedCustomKey('caffeine','mg'),'caffeine');
   expect(qualifiedCustomKey('custom_x',' g'),isNot(qualifiedCustomKey('custom_x','g')));
 });
 test('a hash match never equates different exact frame content', () {
   final a={'hash':Uint8List(20),'hex':null,'frame':Uint8List.fromList([1])};
   expect(sameRawFrame(a,{'hash':a['hash'],'hex':null,'frame':Uint8List.fromList([1])}),isTrue);
   expect(sameRawFrame(a,{'hash':a['hash'],'hex':null,'frame':Uint8List.fromList([2])}),isFalse);
   expect(sameRawFrame({'hex':'AA','frame':null},{'hex':'aa','frame':null}),isFalse);
 });
 test('pilot tables and unknown columns are exact omissions, safe rows still export', () async {
  await withFreshForkDb((db,path) async {
   const pilotTables=['pulse_episode','pulse_episode_alias','pulse_episode_outbox',
    'pulse_episode_revision','pulse_evidence_chunk','pulse_input_arrival',
    'pulse_source_complete','pulse_upgrade','pulse_upgrade_record'];
   for(final name in pilotTables) {
    await db.execute('CREATE TABLE $name(id TEXT PRIMARY KEY,blob BLOB)');
    await db.insert(name,{'id':'pilot-only','blob':Uint8List.fromList([9])});
   }
   await db.insert('journal',{'date':'2026-11-01','note':'retained','tags_json':'[]','updated_at':1});
   await db.execute('ALTER TABLE food_entry ADD COLUMN new_semantics TEXT');
   await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)'); await LocalDb.close();
   final report=await mapOfficialSnapshot(snapshotPath:path,outputPath:'${File(path).parent.path}/out.db',factory:databaseFactoryFfi);
   for(final name in pilotTables) {
    final omission=report.tables[name] as Map;
    expect(omission['source_count'],1);
    expect(omission['reason'],'pilot Pulse table; recovery only');
   }
   expect((report.tables['food_entry'] as Map)['reason'],'unsupported source shape');
   final out=await databaseFactoryFfi.openDatabase(report.path);
   try {expect((await out.query('journal')).single['note'],'retained');}
   finally {await out.close();}
  });
 },timeout:const Timeout(Duration(minutes:8)));
 test('low space refuses before file creation and preserves snapshot', () async {
  await withFreshForkDb((db,path) async {
   await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');await LocalDb.close();
   final out='${File(path).parent.path}/out.db';
   await expectLater(mapOfficialSnapshot(snapshotPath:path,outputPath:out,factory:databaseFactoryFfi,
    space:ExportSpaceBudget(source:FreeSpace(64),liveFloorBytes:64)),throwsA(isA<ExportSpaceExhausted>()));
   expect(File(out).existsSync(),isFalse);expect(File(path).existsSync(),isTrue);
  });
 },timeout:const Timeout(Duration(minutes:8)));
 // WHY: the mapper must discard only its partial file when the live-data
 // reserve becomes unavailable after preflight, without modifying the source.
 test('mid-write space exhaustion deletes the private output and keeps source bytes',() async {
  await withFreshForkDb((db,path) async {
   await db.insert('journal',{'date':'2026-11-01','note':'retained source','tags_json':'[]','updated_at':1});
   await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');await LocalDb.close();
   final original=await File(path).readAsBytes();
   final output='${File(path).parent.path}/out.db';
   final free=FallingSpace(output);
   await expectLater(mapOfficialSnapshot(snapshotPath:path,outputPath:output,factory:databaseFactoryFfi,
    space:ExportSpaceBudget(source:free,liveFloorBytes:64)),throwsA(isA<ExportSpaceExhausted>()));
   expect(free.sawPrivateOutput,isTrue);expect(File(output).existsSync(),isFalse);
   expect(await File(path).readAsBytes(),original);
  });
 },timeout:const Timeout(Duration(minutes:8)));
 // WHY: SQLite can hold a BLOB in a TEXT column. One corrupt reference must
 // become a named omission while the valid remainder remains exportable.
 test('unsupported reference storage type omits one row, retaining safe input',() async {
  await withFreshForkDb((db,path) async {
   await db.insert('journal_metric',{'date':'2026-11-01','field':Uint8List.fromList([1]),'value':7.0,'updated_at':1});
   await db.insert('journal',{'date':'2026-11-01','note':'safe input','tags_json':'[]','updated_at':1});
   await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');await LocalDb.close();
   final mapping=mapOfficialSnapshot(snapshotPath:path,outputPath:'${File(path).parent.path}/out.db',factory:databaseFactoryFfi);
   await expectLater(mapping,completes,reason:'a corrupt reference must not refuse the safe remainder');
   final report=await mapping;
   final out=await databaseFactoryFfi.openDatabase(report.path);
   try {
    expect(await out.query('journal_metric'),isEmpty);
    expect((await out.query('journal')).single['note'],'safe input');
    expect((report.tables['journal_metric'] as Map)['rowid_ranges'].toString(),contains('unsupported reference storage type'));
   } finally {await out.close();}
  });
 },timeout:const Timeout(Duration(minutes:8)));
}
