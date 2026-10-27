import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('learning state, audit and explicit absences survive same-version reopen', () async {
    final env = await BackupEnv.create('tracks_learning_storage_t2.db');
    addTearDown(env.dispose);
    var db = await LocalDb.instance;
    await db.insert('track_learning', {
      'track_id': 'caffeine', 'started_ms': 1,
      'state_json': '{}', 'last_step_date': null,
    });
    await db.insert('track_learning_log', {
      'track_id': 'caffeine', 'date': '2026-10-27', 'field': 'half_life_hours',
      'before_value': 5, 'after_value': 5.1, 'reason': 'matched_observations',
    });
    await db.insert('track_absence', {'track_id': 'caffeine', 'date': '2026-10-27'});
    await LocalDb.close();
    db = await LocalDb.instance;
    expect(await db.query('track_learning'), hasLength(1));
    expect((await db.query('track_learning_log')).single['after_value'], 5.1);
    expect(await db.query('track_absence'), hasLength(1));
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(83));
  });
}
