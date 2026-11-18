// WHY: CLAIM(official-export-independent-kept-rules) [P2 review N3]. A mapper
// cannot hide a forbidden kept row behind a matching target and a mapped label.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'archive_fixture.dart';
import 'conservation.dart';
import 'support.dart';

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 for(final c in [
  (table:'decoded_onehz',reason:'deleted input window',row:parent(1792670400,70)),
  (table:'decoded_rr',reason:'orphan live beat',row:beat(1792670400,0)),
  (table:'strength_set',reason:'omitted or missing parent',row:<String,Object?>{
   'session_id':'missing','seq':0,'exercise_key':'squat','set_index':0,'note':''}),
  (table:'workout_route',reason:'omitted or missing workout parent',row:<String,Object?>{
   'session_id':'missing','seq':0,'ts_ms':1792670400000,'lat':40.0,'lng':-105.0}),
 ]) {
  test('oracle rejects a kept ${c.table} row that violates ${c.reason}',() async {
   await withFreshForkDb((db,path) async {
    if(c.reason=='deleted input window') {
     await db.insert('compute_freshness',{'key':'redrive_excluded_windows','payload_json':'[[1792670400,1792670401]]','updated_at':1});
    }
    await db.insert(c.table,c.row);
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');await LocalDb.close();
    final report=await mapOfficialSnapshot(snapshotPath:path,outputPath:'${File(path).parent.path}/mapped.db',factory:databaseFactoryFfi,
      calendar:const FixedOffsetCalendar(0));
    await verifyConservation(path,report); // The honest omission must pass.
    final tables=(jsonDecode(jsonEncode(report.tables)) as Map).cast<String,Object?>();
    final ranges=(tables[c.table] as Map)['rowid_ranges'] as Map;
    final omitted=ranges.keys.single;
    expect(omitted,startsWith(c.reason));
    ranges['mapped; columns=']=ranges.remove(omitted);
    final out=await databaseFactoryFfi.openDatabase(report.path);
    try {await out.insert(c.table,c.row);} finally {await out.close();}
    final lie=OfficialMapReport(report.path,report.cursor,tables,report.targetCounts,report.days);
    await expectLater(verifyConservation(path,lie),throwsA(isA<TestFailure>()));
   });
  });
 }
}
