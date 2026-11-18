// WHY: CLAIM(official-export-independent-oracle) [P2 review F2]. The value
// oracle must not trust the mapper's own report. These negative controls plant
// the defects a broken mapper could hide behind a plausible omission: valid
// rows reported as refused, a carried table reported as unsupported, and rows
// in the target that no source row or verified archive claim explains.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'conservation.dart';
import 'rich_fixture.dart';

OfficialMapReport _withTables(OfficialMapReport r, void Function(Map<String,Object?>) edit, {String? path}) {
  final tables=(jsonDecode(jsonEncode(r.tables)) as Map).cast<String,Object?>();
  edit(tables);
  return OfficialMapReport(path ?? r.path,r.cursor,tables,r.targetCounts,r.days);
}

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 late RichFixture fx;
 late OfficialMapReport report;
 setUpAll(() async {
  fx=await RichFixture.build();
  report=await mapOfficialSnapshot(snapshotPath:fx.forkPath,
    outputPath:'${File(fx.forkPath).parent.path}/mapped.db',factory:databaseFactoryFfi);
 });
 tearDownAll(() async {await fx.dispose();});
 test('control: the honest mapper output conserves',() async {
  await verifyConservation(fx.forkPath,report,literalOmitted:richFixtureLiteralOmissions);
 },timeout:const Timeout(Duration(minutes:8)));
 test('valid rows reported as refused are caught, not just counted',() async {
  final lie=_withTables(report,(t) {
   final ranges=((t['sessions'] as Map)['rowid_ranges'] as Map);
   final mapped=ranges.keys.firstWhere((k)=>(k as String).startsWith('mapped;'));
   ranges['unfinished or fabricated session end; columns=']=ranges.remove(mapped);
  });
  await expectLater(verifyConservation(fx.forkPath,lie,literalOmitted:richFixtureLiteralOmissions),throwsA(isA<TestFailure>()));
 },timeout:const Timeout(Duration(minutes:8)));
 test('a carried table reported as omitted entirely is caught',() async {
  final lie=_withTables(report,(t) {
   t['journal']={'source_count':(t['journal'] as Map)['source_count'],'omitted_all':true,
     'reason':'unsupported source shape','columns':const <String>[]};
  });
  await expectLater(verifyConservation(fx.forkPath,lie,literalOmitted:richFixtureLiteralOmissions),throwsA(isA<TestFailure>()));
 },timeout:const Timeout(Duration(minutes:8)));
 for(final plant in const {
  'journal':"INSERT INTO journal(date,tags_json,note,updated_at) VALUES('2031-01-01','[]','invented',1)",
  'decoded_onehz':"INSERT INTO decoded_onehz(device_id,ts_ms,rec_ts,counter,hr) VALUES('',4102444800000,4102444800,7,99)",
 }.entries) {
  test('an invented ${plant.key} row in the target is caught (target to source direction)',() async {
   final copy='${File(fx.forkPath).parent.path}/invented_${plant.key}.db';
   await File(report.path).copy(copy);
   final db=await databaseFactoryFfi.openDatabase(copy);
   try {await db.execute(plant.value);} finally {await db.close();}
   await expectLater(verifyConservation(fx.forkPath,_withTables(report,(_){},path:copy),literalOmitted:richFixtureLiteralOmissions),throwsA(isA<TestFailure>()));
  },timeout:const Timeout(Duration(minutes:8)));
 }
}
