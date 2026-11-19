// Literal legacy layout from bcf215490 schema.dart, _createEcgTables.
// Fresh creators retire these objects; upgraded SQLite files retain them.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const retiredGestureDdl='''CREATE TABLE ecg_gesture_session (
  device_id TEXT NOT NULL, created_at INTEGER NOT NULL, strap_start INTEGER,
  strap_end INTEGER, final_count INTEGER, outcome TEXT NOT NULL, reason TEXT,
  PRIMARY KEY (device_id,created_at))''';

Future<void> addRetiredEcg(Database db) async {
  await db.execute(retiredGestureDdl);
  await db.execute('ALTER TABLE ecg_raw_packet ADD COLUMN origin TEXT');
  await db.insert('ecg_gesture_session',{'device_id':'legacy','created_at':1,'outcome':'paused'});
}
