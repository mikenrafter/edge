// Return path proof. The unchanged official receiver writes the return file;
// the current fork's real importer merges it into the still-populated fixture.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'rich_fixture.dart';
void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 test('official return keeps the qualified definition beside the original',() async {
  final fx=await RichFixture.build();
  try {
   LocalDb.dbName=fx.forkPath;final db=await LocalDb.instance;
   await LocalDb.importFromDbFile('${Platform.environment['CANDIDATES_DIR']}/official-return.db');
   final defs=await db.query('journal_field_def',where:"key LIKE 'custom_%'",orderBy:'key');
   expect(defs.singleWhere((r)=>r['key']=='custom_caffeine')['unit'],'mg');
   expect(defs.singleWhere((r)=>r['key']=='custom_u1_637573746f6d5f6361666665696e65_67')['unit'],'g');
   final note=(await db.query('journal',where:"date='2026-10-21'")).single;
   expect(note['note'],'Later official edit');
   final metrics=await db.query('journal_metric',where:"date='2026-10-21'");
   final out=Directory(Platform.environment['OFFICIAL_PROBE_OUT']!)..createSync(recursive:true);
   File('${out.path}/return-fork.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
     'definitions':defs,'date_metric_set':metrics,'journal':note,
     'limitation':'Return import uses the fork receiver natural-key precedence: the official mg definition can replace the original unqualified g definition; the qualified g definition remains separate. Equal-timestamp whole-day journal sets remain local. This is not a universal safe merge.'}));
  } finally {await LocalDb.close();await fx.dispose();}
 },timeout:const Timeout(Duration(minutes:15)));
}
