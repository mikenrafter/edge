// Independent projection oracle for spec §1.3. Production never imports this.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

Future<void> projectionMatches(DatabaseExecutor db, String day) async {
  final blocks = List<Map<String,Object?>>.of(await db.query(
    'sleep_block', where:'owner_day = ?', whereArgs:[day]));
  const rank = {'live':0, 'removed':1, 'merged':2};
  blocks.sort((a,b) {
    final state = rank[a['state']]!.compareTo(rank[b['state']]!);
    if (state != 0) return state;
    final time = (b['updated_at'] as int).compareTo(a['updated_at'] as int);
    return time != 0 ? time : (a['id'] as String).compareTo(b['id'] as String);
  });
  String source(Map<String,Object?> b) => b['state'] != 'live' ? 'rejected'
      : b['source'] == 'detected' ? 'confirmed' : b['source'] as String;
  final naps = <int,Map<String,Object?>>{};
  final mains = <Map<String,Object?>>[];
  for (final b in blocks) {
    if (b['kind'] == 'nap') {
      naps.putIfAbsent(b['start_ts'] as int, () => {
        'day_id':day, 'start_ts':b['start_ts'], 'end_ts':b['end_ts'],
        'source':source(b), 'created_at':b['created_at'], 'payload_json':b['payload_json'],
      });
    } else if (mains.isEmpty) {
      mains.add({'day_id':day, 'onset_ts':b['start_ts'], 'offset_ts':b['end_ts'],
        'source':source(b), 'created_at':b['created_at'], 'payload_json':null});
    }
  }
  final expectedNaps = naps.values.toList()..sort((a,b) => (a['start_ts'] as int).compareTo(b['start_ts'] as int));
  expect(await db.query('sleep_nap',where:'day_id = ?',whereArgs:[day],orderBy:'start_ts'),expectedNaps);
  expect(await db.query('sleep_override',where:'day_id = ?',whereArgs:[day]),mains);
}
