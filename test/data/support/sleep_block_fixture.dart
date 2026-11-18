// Literal upstream/release shapes from phase2_5-spec §2.1, not pilot data.
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;

const fixtureDay = '2026-11-01';
const napPayload = '{ "start":1000,"end":1600,"duration_min":10,"confidence":0.8,"odd":"kept" }';
const rejectedPayload = '{"start":2000,"end":2900,"duration_min":15}';

Map<String, Object?> napRow(int start, int end, String source, {String? payload, String day = fixtureDay}) => {
  'day_id':day, 'start_ts':start, 'end_ts':end, 'source':source,
  'payload_json':payload, 'created_at':17,
};
Map<String, Object?> mainRow(String day, String source, int start, int end) => {
  'day_id':day, 'onset_ts':start, 'offset_ts':end, 'source':source,
  'payload_json':null, 'created_at':11,
};
Future<void> seedDay(DatabaseExecutor db, String day, {Object window = const {},
    List<Map<String, Object?>> naps = const [], int? version, int skipped = 0}) => db.insert('day_result', {
  'day_id':day, 'algo_version':version ?? kAlgoVersion, 'computed_at':31,
  'payload_json':jsonEncode({'date':day, 'naps':{'value':naps}, 'scalars':{}}),
  'window_json':window is String ? window : jsonEncode(window),
  'finalized':1, 'partial':0, 'skipped':skipped,
});
Future<void> seedLegacy(DatabaseExecutor db) async {
  for (final r in [mainRow('2026-10-30','manual',100,200),
    mainRow('2026-10-31','confirmed',300,400), mainRow(fixtureDay,'rejected',500,501)]) {
    await db.insert('sleep_override',r);
  }
  for (final r in [
    napRow(1100,1700,'confirmed',payload:napPayload),
    napRow(1800,1900,'confirmed'),
    napRow(2000,2100,'manual'),
    napRow(3000,3600,'legacy',payload:'{"duration_min":10}'),
    napRow(2200,2800,'rejected',payload:rejectedPayload),
    napRow(4000,4600,'rejected'),
  ]) { await db.insert('sleep_nap',r); }
  await db.update('activity_review_meta', {'activated_at':20000});
  await seedDay(db, fixtureDay, window:{'onset_ms':100000,'offset_ms':200000}, naps:[
    {'start':5000,'end':5600,'duration_min':10},
    {'start':1100,'end':1700,'duration_min':10}, // stored edit wins
    {'start':6000,'end':6600,'source':'manual'}, // no pre-review capture
    {'start':21000,'end':22000}, // later than activation
  ]);
  await seedDay(db,'2026-10-31',window:{'value':{'onset_ms':300000,'offset_ms':400000}});
  await seedDay(db,'2026-10-30',window:'—');
}
Map<String,Object?> blockRow(String id, {String kind = 'nap', String day = fixtureDay,
    int start = 1000, int end = 1600, String source = 'manual', String state = 'live',
    String history = 'unavailable', int? detectedStart, int? detectedEnd,
    String? detectedDay, String? mergedInto, String? payload, int updatedAt = 17}) => {
  'id':id, 'kind':kind, 'owner_day':day, 'owner_rule':0, 'start_ts':start, 'end_ts':end,
  'source':source, 'state':state, 'merged_into':mergedInto, 'history':history,
  'detected_start':detectedStart, 'detected_end':detectedEnd, 'detected_day':detectedDay,
  'payload_json':payload, 'revision':0, 'created_at':17, 'updated_at':updatedAt,
};
Future<Map<String,Object?>> snapshot(DatabaseExecutor db) async => {
  for (final t in ['sleep_block','sleep_nap','sleep_override','sleep_edit_job','input_revision','sync_cursor'])
    t:await db.query(t, orderBy:t == 'sleep_block' ? 'id' : null),
};
