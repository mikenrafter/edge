// WHY: transfer cannot turn computed fork scores into target measurements, or
// relabel actual measured observations as absent. [spec §4.3]
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/mapping_worker.dart';
void main() {
 test('completed sessions carry facts and clear unsupported computed values',() async {
  final mapped=await runMappingWorker(const MappingInput('page','sessions',[
   {'__export_rowid':1,'id':'w1','start_ts':100,'end_ts':200,'end_ts_fabricated':0,
    'status':'done','type':'run','source':'manual','created_at':100000,'rpe':7.0,
    'calories':400.0,'strain':12.0,'avg_hr':140,'steps':500,'cadence_spm':100.0},
   {'__export_rowid':2,'id':'w2','start_ts':100,'end_ts':200,'end_ts_fabricated':1,
    'status':'done','type':'run','source':'manual','created_at':100000},
  ]));
  expect(mapped.rows.single['id'],'w1');expect(mapped.rows.single['rpe'],7.0);
  for(final c in ['calories','strain','avg_hr','steps','cadence_spm']) {expect(mapped.rows.single[c],isNull);}
  expect(mapped.notes.last['reason'],'unfinished or fabricated session end');
 });
 test('race distance retains gps/user provenance without deriving a distance',() async {
  final mapped=await runMappingWorker(const MappingInput('page','hyrox_segment',[
   {'__export_rowid':1,'session_id':'h1','idx':0,'kind':'hyrox_round','station':'rowing',
    'distance_m':123.0,'distance_source':'gps','hr_source':'strap'},
   {'__export_rowid':2,'session_id':'h1','idx':1,'kind':'hyrox_round','station':'rowing',
    'distance_m':1000.0,'distance_source':'plan','planned_distance_m':1000.0},
  ]));
  expect(mapped.rows[0]['distance_m'],123.0);expect(mapped.rows[0]['distance_source'],'gps');
  expect(mapped.rows[0]['hr_source'],'strap');expect(mapped.rows[1]['distance_m'],isNull);
  expect(mapped.rows[1]['planned_distance_m'],1000.0);
 });
 test('unsupported wake methods never become a different alarm',() async {
  final rows=await runMappingWorker(const MappingInput('page','alarm_schedule',[
   {'__export_rowid':1,'weekday':1,'hour':8,'minute':0,'enabled':1,'smart_window_minutes':0,'natural_window_minutes':30,'gradual_window_minutes':0},
   {'__export_rowid':2,'weekday':2,'hour':8,'minute':0,'enabled':1,'smart_window_minutes':20,'natural_window_minutes':0,'gradual_window_minutes':0},
  ]));
  expect(rows.rows.single['weekday'],2);expect(rows.rows.single['smart_window_minutes'],20);
  expect(rows.notes.first['reason'],'Natural or Gradual wake choice unsupported');
 });
 test('portable preference types and presence markers are closed',() async {
  final prefs=await runMappingWorker(const MappingInput('page','backup_prefs',[
   {'__export_rowid':1,'key':'clock_format','type':'string','value':'24h'},
   {'__export_rowid':2,'key':'notif_health','type':'bool','value':'true'},
   {'__export_rowid':3,'key':'update_checks_enabled','type':'bool','value':'true'},
   {'__export_rowid':4,'key':'cycle_tracking_enabled','type':'bool','value':'yes'},
  ]));
  expect(prefs.rows.map((r)=>r['key']).toList(),['clock_format']);
  expect(prefs.notes.where((n)=>n['omitted']==true).length,3);
 });
 // WHY: the target parser ignores unknown JSON fields. Keeping a new fork
 // choice would silently turn it into the older plan when opened there.
 test('race plans with unsupported nested choices stay in the snapshot',() async {
  final mapped=await runMappingWorker(const MappingInput('page','hyrox_session',[
   {'__export_rowid':1,'id':'supported','status':'finished',
    'plan_json':'{"v":1,"preset":"custom","segments":[{"kind":"hyrox_round","station":"rowing","goal_sec":300}]}'},
   {'__export_rowid':2,'id':'new-choice','status':'finished',
    'plan_json':'{"v":1,"preset":"custom","segments":[{"kind":"hyrox_round","station":"rowing","repeat":3}]}'},
   {'__export_rowid':3,'id':'unsupported-type','status':'finished',
    'plan_json':'{"v":1,"preset":"custom","segments":[{"kind":"hyrox_round","station":"rowing","goal_sec":"300"}]}'},
  ]));
  expect(mapped.rows.map((r)=>r['id']).toList(),['supported']);
  expect(mapped.notes.where((n)=>n['omitted']==true).length,2);
 });
}
