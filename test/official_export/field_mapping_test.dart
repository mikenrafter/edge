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
 // WHY: spec §6.2 l.168 carries weekday/hour/minute/enabled; only the wake
 // METHOD is an omission. A fork Natural/Gradual window must not become Smart
 // Wake, so the row exports as a plain alarm (smart_window_minutes 0), which the
 // tagged target rings at the set time. [P2 review F9; v0.12.2 alarm_schedule.dart:152-155]
 test('unsupported wake methods export a plain alarm, never a different wake method',() async {
  final rows=await runMappingWorker(const MappingInput('page','alarm_schedule',[
   {'__export_rowid':1,'weekday':1,'hour':8,'minute':0,'enabled':1,'smart_window_minutes':0,'natural_window_minutes':30,'gradual_window_minutes':0},
   {'__export_rowid':2,'weekday':2,'hour':8,'minute':5,'enabled':1,'smart_window_minutes':20,'natural_window_minutes':0,'gradual_window_minutes':0},
   {'__export_rowid':3,'weekday':3,'hour':7,'minute':15,'enabled':0,'smart_window_minutes':25,'natural_window_minutes':25,'gradual_window_minutes':0,'gradual_pattern':'ramp','gradual_cadence_sec':30},
   {'__export_rowid':4,'weekday':4,'hour':6,'minute':45,'enabled':1,'smart_window_minutes':0,'natural_window_minutes':0,'gradual_window_minutes':15},
  ]));
  expect(rows.rows.map((r)=>[r['weekday'],r['hour'],r['minute'],r['enabled'],r['smart_window_minutes']]).toList(),
   [[1,8,0,1,0],[2,8,5,1,20],[3,7,15,0,0],[4,6,45,1,0]]);
  expect(rows.notes.every((n)=>n['omitted']!=true),isTrue);
  final n1=rows.notes[0]['columns'] as List,n3=rows.notes[2]['columns'] as List,n4=rows.notes[3]['columns'] as List;
  expect(n1,contains('natural_window_minutes'));
  expect(n3,containsAll(['natural_window_minutes','gradual_pattern','gradual_cadence_sec','smart_window_minutes']));
  expect(n4,contains('gradual_window_minutes'));
  expect(rows.notes[1]['columns'] as List,isNot(contains('smart_window_minutes')));
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
