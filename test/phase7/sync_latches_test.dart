// Phase 7 failure injection — the sync presentation and the derive scheduler
// (8M). A callback that throws, a derive that throws and a database that fails
// must end with every latch cleared and nobody left awaiting forever.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/control_operations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncCoordinator', () {
    SyncCoordinator make(
      Future<void> Function(void Function(String)) run, {
      void Function(String)? log,
    }) =>
        SyncCoordinator(
          run: run,
          isConnected: () => true,
          reloadLocal: () async {},
          timeout: const Duration(milliseconds: 200),
          retireGrace: const Duration(milliseconds: 20),
          log: log,
        );

    test('a timing log that throws cannot leave syncNow() awaiting forever',
        () async {
      final c = make((_) async {}, log: (_) => throw StateError('log sink'));
      final result = await c.syncNow().timeout(const Duration(seconds: 2));
      expect(result.success, isTrue);
      expect(c.presentation.busy, isFalse);
      // The latch is clear: another sync starts.
      expect((await c.syncNow().timeout(const Duration(seconds: 2))).success, isTrue);
    });

    test('a run that throws ends not-busy, with the reason, and the next '
        'sync starts', () async {
      var n = 0;
      final c = make((_) async {
        if (n++ == 0) throw StateError('link dropped');
      });
      final first = await c.syncNow();
      expect(first.success, isFalse);
      expect(c.presentation.busy, isFalse);
      expect((await c.syncNow()).success, isTrue);
    });

    test('a run that never returns times out, cancels its token, and frees '
        'the latch', () async {
      final c = make((_) => Completer<void>().future);
      final out = await c.syncNow().timeout(const Duration(seconds: 3));
      expect(out.success, isFalse);
      expect(c.presentation.busy, isFalse);
    });
  });

  group('DeriveScheduler', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'phase7_derive_scheduler_test.db';
    });
    setUp(() async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
    });
    tearDownAll(LocalDb.close);

    test('a derive that throws marks the job failed, clears running and '
        'raises no uncaught async error', () async {
      final uncaught = <Object>[];
      final ran = Completer<void>();
      await runZonedGuarded(() async {
        final s = DeriveScheduler(
          run: ({required DeriveJobKind kind}) async {
            if (!ran.isCompleted) ran.complete();
            throw StateError('derive blew up');
          },
          log: (_) {},
          onChanged: () {},
          lightSettle: const Duration(milliseconds: 10),
        );
        await s.init();
        s.markStoredData();
        await ran.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(s.running, isFalse);
        final failed = await LocalDb.computeJobs(state: 'failed', limit: 10);
        expect(failed, isNotEmpty);
        s.dispose();
      }, (e, _) => uncaught.add(e));
      expect(uncaught, isEmpty, reason: '$uncaught');
    });

    test('a manual sync hold is always released, even when dropping the '
        'absorbed job fails', () async {
      final s = DeriveScheduler(
        run: ({required DeriveJobKind kind}) async {},
        log: (_) {},
        onChanged: () {},
      );
      await s.init();
      final hold = s.beginManualSync();
      expect(s.snapshot()['manual_sync_hold'], isTrue);
      await LocalDb.close(); // the database goes away under the hold
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
      await s.endManualSync(hold, absorb: true);
      expect(s.snapshot()['manual_sync_hold'], isFalse);
      s.dispose();
    });
  });
}
