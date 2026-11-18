// WHY: CLAIM(official-export-active-smart-wake) [P2 review N1]. The receiver
// must carry a running legacy window, and must never activate a stale one.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support.dart';

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 for(final c in const [
  (name:'pending upgrade carries its live window despite the migration copy',upgrade:'pending',flag:'true',readable:true,natural:30,expected:20),
  (name:'acknowledged Natural on clears a stale window',upgrade:'acknowledged',flag:'true',readable:true,natural:0,expected:0),
  (name:'Natural flag off carries the legacy window',upgrade:'acknowledged',flag:'false',readable:true,natural:30,expected:20),
  (name:'unreadable prefs clear the window even during a pending upgrade',upgrade:'pending',flag:'true',readable:false,natural:0,expected:0),
  (name:'missing override defaults to Natural on and clears a stale window',upgrade:'acknowledged',flag:'',readable:true,natural:0,expected:0),
 ]) {
  test(c.name,() async {
   await withFreshForkDb((db,path) async {
    await db.insert('wake_meta',{'key':'upgrade_explanation','value':c.upgrade},conflictAlgorithm:ConflictAlgorithm.replace);
    if(c.readable) {
     await db.execute('CREATE TABLE backup_prefs(key TEXT PRIMARY KEY,type TEXT NOT NULL,value TEXT NOT NULL)');
     if(c.flag.isNotEmpty) {await db.insert('backup_prefs',{'key':'ff.natural_wake','type':'bool','value':c.flag});}
    }
    await db.execute('DELETE FROM alarm_schedule');
    await db.insert('alarm_schedule',{'weekday':2,'hour':8,'minute':5,'enabled':1,
      'smart_window_minutes':20,'natural_window_minutes':c.natural,'gradual_window_minutes':0});
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    await LocalDb.close();
    final report=await mapOfficialSnapshot(snapshotPath:path,outputPath:'${File(path).parent.path}/mapped.db',factory:databaseFactoryFfi,
      calendar:const FixedOffsetCalendar(0));
    final out=await databaseFactoryFfi.openDatabase(report.path,options:OpenDatabaseOptions(readOnly:true));
    try {
     expect((await out.query('alarm_schedule')).map((r)=>[r['weekday'],r['hour'],r['minute'],r['enabled'],r['smart_window_minutes']]).toList(),[[2,8,5,1,c.expected]]);
     final ledger=(report.tables['alarm_schedule'] as Map)['rowid_ranges'] as Map;
     expect(ledger.keys.single,contains('natural_window_minutes'));
     expect(ledger.keys.single.contains('smart_window_minutes'),c.expected==0,reason:'changed legacy window named in the ledger');
    } finally {await out.close();}
   });
  });
 }
}
