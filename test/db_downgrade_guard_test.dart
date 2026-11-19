// Item #54: a build whose schema is older than the file must refuse to open it.
// sqflite stamps `user_version` to the build's version after every open that
// ran no callback for the difference, so an older APK would rewind the stamp and
// the next newer build would skip the rungs (sleep_block stayed stale).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';

const _name = 'db_downgrade_guard.db';

Map<String, int> _siblings(String dir) => {
      for (final f in Directory(dir).listSync().whereType<File>())
        if (p.basename(f.path).startsWith(_name)) p.basename(f.path): f.lengthSync(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_name));
  tearDown(() => deriveDbTearDown(_name));

  test('a database stamped newer than this build is refused, byte for byte untouched',
      () async {
    final dir = await databaseFactory.getDatabasesPath();
    final path = p.join(dir, _name);
    await LocalDb.instance; // create at the current schema, then close cleanly
    await LocalDb.close();
    final newer = LocalDb.schemaVersion + 1;
    final raw = await openDatabase(path, singleInstance: false);
    await raw.rawQuery('PRAGMA user_version = $newer');
    await raw.close();

    final bytesBefore = File(path).readAsBytesSync();
    final filesBefore = _siblings(dir);

    await expectLater(
      LocalDb.instance,
      throwsA(isA<DbNewerThanBuild>()
          .having((e) => e.found, 'found', newer)
          .having((e) => e.supported, 'supported', LocalDb.schemaVersion)
          .having((e) => e.toString(), 'message', contains('newer'))),
    );

    expect(File(path).readAsBytesSync(), bytesBefore,
        reason: 'the refused open must not write a byte');
    expect(_siblings(dir), filesBefore,
        reason: 'no quarantine copy, no fresh database beside it');
    expect(LocalDb.lastRebuild, isNull);
    final check = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      expect(await check.getVersion(), newer, reason: 'the stamp is not rewound');
    } finally {
      await check.close();
    }
  });

  // The refusal must be visible: AppRoute.failed prints initError verbatim.
  test('start-up lands on the failed route and says the database is newer', () async {
    await LocalDb.instance;
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    final raw = await openDatabase(p.join(dir, _name), singleInstance: false);
    await raw.rawQuery('PRAGMA user_version = ${LocalDb.schemaVersion + 1}');
    await raw.close();

    final app = AppState();
    await until(() => app.initialized || app.initError != null,
        what: 'start-up settled');
    await settleMs(300);
    expect(app.initialized, isFalse);
    expect(app.route, AppRoute.failed);
    expect(app.initError, contains('newer'));
    expect(app.initError, contains('${LocalDb.schemaVersion + 1}'));
    expect(LocalDb.lastRebuild, isNull);
  });

  test('the same schema version still opens', () async {
    final db = await LocalDb.instance;
    expect(await db.getVersion(), LocalDb.schemaVersion);
  });
}
