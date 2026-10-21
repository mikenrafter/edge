// `alarm_schedule` is `PRIMARY KEY (weekday)` on an INTEGER column, so the
// weekday IS the rowid. The per-row restore pages with `WHERE rowid > ?`
// starting at 0, which never reads weekday 0 (Monday's alarm lost on every
// restore).
//
// Contract: a restore reads every row whatever its rowid, 0 and negatives
// included.
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';

import 'backup_support.dart';

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_alarm_weekday_zero.db'));
  tearDownAll(() async => env.dispose());

  test('all seven weekdays of alarm_schedule arrive, 0 included', () async {
    await env.wipe();
    final db = await LocalDb.instance;
    for (var w = 0; w < 7; w++) {
      await db.insert('alarm_schedule', {
        'weekday': w, 'hour': 6, 'minute': w, 'enabled': 1,
        'smart_window_minutes': 0, 'natural_window_minutes': 0,
        'gradual_window_minutes': 0, 'gradual_pattern': 'ramp',
        'gradual_cadence_sec': 180,
      });
    }
    await env.seedData();
    final path = await LocalDb.exportCopy();

    await env.wipe();
    await LocalDb.instance;
    await LocalDb.importFromDbFile(path);
    final rows = await (await LocalDb.instance)
        .query('alarm_schedule', orderBy: 'weekday');
    expect([for (final r in rows) r['weekday']], [0, 1, 2, 3, 4, 5, 6]);
    expect([for (final r in rows) r['minute']], [0, 1, 2, 3, 4, 5, 6]);
  });
}
