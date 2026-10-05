// `gesture:` claims carry no date, so LocalDb.pruneNotifFired expires them by
// fired_at (90 days) while leaving dated and other undated keys alone.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dbName = 'gesture_claim_prune_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = dbName;
    await databaseFactory
        .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory
        .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), dbName));
  });

  test('old gesture claims are pruned; recent, dated and other keys stay',
      () async {
    final now = DateTime.utc(2026, 6, 1).millisecondsSinceEpoch;
    const day = 24 * 3600 * 1000;
    await LocalDb.claimNotifFired('gesture:d:14:1:0:log_water',
        firedAtMs: now - 91 * day);
    await LocalDb.claimNotifFired('gesture:d:14:2:0:log_water',
        firedAtMs: now - 89 * day);
    await LocalDb.claimNotifFired('alarm_fired:123', firedAtMs: now - 400 * day);
    await LocalDb.claimNotifFired('2026-05-30:illness',
        firedAtMs: now - 2 * day);

    await LocalDb.pruneNotifFired('2026-05-18', nowMs: now);

    expect(await LocalDb.notifFiredExists('gesture:d:14:1:0:log_water'), isFalse);
    expect(await LocalDb.notifFiredExists('gesture:d:14:2:0:log_water'), isTrue);
    expect(await LocalDb.notifFiredExists('alarm_fired:123'), isTrue);
    expect(await LocalDb.notifFiredExists('2026-05-30:illness'), isTrue);
  });
}
