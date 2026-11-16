import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';

import 'backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('pilot-schema-upgrade.db'));
  setUp(() => env.wipe());
  tearDownAll(() => env.dispose());

  for (final oldVersion in [88, 89]) {
    // WHY/CLAIM(pilot-schema-union): the prior pulse phone has no sleep-edit
    // jobs. Reopening must add them without replacing its immutable watermark.
    test('schema $oldVersion preserves pulse ancestry and accepts sleep edits', () async {
      var db = await LocalDb.instance;
      await PulseEpisodeStore.captureUpgrade(db, nowMs: 1234);
      final watermark = await db.query('pulse_upgrade');
      await db.execute('DROP TABLE sleep_edit_job');
      await db.setVersion(oldVersion);
      await LocalDb.close();

      db = await LocalDb.instance;
      await db.transaction((txn) => SleepEditStore.enqueue(txn, '2026-11-15'));
      expect(await db.query('sleep_edit_job'), contains(containsPair('revision', 1)));
      expect(await db.query('pulse_upgrade'), watermark);
      expect(await db.getVersion(), LocalDb.schemaVersion);

      await LocalDb.close();
      db = await LocalDb.instance;
      expect(await db.query('sleep_edit_job'), hasLength(1));
      expect(await db.query('pulse_upgrade'), watermark);
    });
  }
}
